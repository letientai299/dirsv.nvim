--- Minimal WebSocket client over libuv TCP.
---
--- Implements just enough of RFC 6455 for editor sync:
--- client-side text frames (≤65535 bytes), upgrade handshake, and close.
local M = {}

local uv = vim.uv or vim.loop
local ffi = require("ffi")

--- Generate a 16-byte random WebSocket key, base64-encoded.
---@return string
local function gen_ws_key()
	local bytes = {}
	for i = 1, 16 do
		bytes[i] = string.char(math.random(0, 255))
	end
	-- Neovim ships LuaJIT with base64 encode via bit ops, but the simplest
	-- portable approach is vim.base64.encode (available since nvim 0.9).
	return vim.base64.encode(table.concat(bytes))
end

--- Build the HTTP upgrade request.
---@param host string
---@param port integer
---@param path string e.g. "/api/editor/ws"
---@param key string base64-encoded WS key
---@return string
local function upgrade_request(host, port, path, key)
	return string.format(
		"GET %s HTTP/1.1\r\n"
			.. "Host: %s:%d\r\n"
			.. "Upgrade: websocket\r\n"
			.. "Connection: Upgrade\r\n"
			.. "Sec-WebSocket-Key: %s\r\n"
			.. "Sec-WebSocket-Version: 13\r\n"
			.. "\r\n",
		path,
		host,
		port,
		key
	)
end

-- Reusable mask key table — overwritten each frame, avoids 60 allocs/sec.
local mask = { 0, 0, 0, 0 }

local function refresh_mask()
	mask[1] = math.random(0, 255)
	mask[2] = math.random(0, 255)
	mask[3] = math.random(0, 255)
	mask[4] = math.random(0, 255)
end

-- Reusable ffi buffer for XOR masking — avoids per-byte string allocations.
local mask_buf_cap = 256
local mask_buf = ffi.new("uint8_t[?]", mask_buf_cap)

--- Frame a text payload as a masked WebSocket text frame (client→server).
--- Supports payloads up to 65535 bytes.
---@param payload string
---@return string frame bytes
function M.frame_text(payload)
	local len = #payload

	-- Header: FIN + text opcode
	local header = string.char(0x81)

	-- Payload length with mask bit set
	if len <= 125 then
		header = header .. string.char(0x80 + len)
	elseif len <= 65535 then
		header = header
			.. string.char(0x80 + 126)
			.. string.char(math.floor(len / 256))
			.. string.char(len % 256)
	else
		error("payload too large for ws.frame_text")
	end

	refresh_mask()
	header = header .. string.char(mask[1], mask[2], mask[3], mask[4])

	-- Grow buffer if needed (rare — payloads are typically ~200 bytes).
	if len > mask_buf_cap then
		mask_buf_cap = len
		mask_buf = ffi.new("uint8_t[?]", mask_buf_cap)
	end
	-- XOR-mask payload into ffi buffer. Unrolled 4x to avoid per-byte
	-- modulo and table lookups. Locals bypass global/upvalue indirection.
	local m1, m2, m3, m4 = mask[1], mask[2], mask[3], mask[4]
	local i = 0
	local bxor, byte = bit.bxor, string.byte
	while i + 4 <= len do
		mask_buf[i] = bxor(byte(payload, i + 1), m1)
		mask_buf[i + 1] = bxor(byte(payload, i + 2), m2)
		mask_buf[i + 2] = bxor(byte(payload, i + 3), m3)
		mask_buf[i + 3] = bxor(byte(payload, i + 4), m4)
		i = i + 4
	end
	while i < len do
		mask_buf[i] = bxor(byte(payload, i + 1), mask[(i % 4) + 1])
		i = i + 1
	end

	return header .. ffi.string(mask_buf, len)
end

--- Build a close frame (opcode 0x8) with mask.
---@return string
local function close_frame()
	refresh_mask()
	local status_hi = 0x03 -- 1000 >> 8
	local status_lo = 0xE8 -- 1000 & 0xFF
	return string.char(0x88) -- FIN + close
		.. string.char(0x80 + 2) -- masked, 2-byte payload
		.. string.char(mask[1], mask[2], mask[3], mask[4])
		.. string.char(bit.bxor(status_hi, mask[1]))
		.. string.char(bit.bxor(status_lo, mask[2]))
end

---@class dirsv.WSHandle
---@field tcp uv_tcp_t
---@field upgraded boolean

--- Connect to a WebSocket endpoint. Calls callback(handle, err).
--- On success, handle is a dirsv.WSHandle; on failure, handle is nil.
---@param host string
---@param port integer
---@param path string e.g. "/api/editor/ws"
---@param callback fun(handle: dirsv.WSHandle|nil, err: string|nil)
function M.connect(host, port, path, callback)
	local tcp = uv.new_tcp()
	if not tcp then
		callback(nil, "failed to create tcp")
		return
	end

	tcp:connect(host, port, function(err)
		if err then
			tcp:close()
			callback(nil, "connect: " .. tostring(err))
			return
		end

		local key = gen_ws_key()
		local req = upgrade_request(host, port, path, key)
		-- Guards against double-callback: both the write error handler and
		-- the read error handler could fire on the same failure. The first
		-- one to set done=true wins; the other becomes a no-op.
		local done = false

		-- Start reading before writing — libuv handles ordering.
		-- The server won't respond until it receives the full request.
		local buf = ""
		tcp:read_start(function(read_err, data)
			if done then
				return
			end
			if read_err then
				done = true
				tcp:read_stop()
				tcp:close()
				callback(nil, "read upgrade: " .. tostring(read_err))
				return
			end
			if data == nil then
				done = true
				tcp:read_stop()
				tcp:close()
				callback(nil, "connection closed during handshake")
				return
			end

			buf = buf .. data
			local header_end = buf:find("\r\n\r\n", 1, true)
			if not header_end then
				return -- wait for more data
			end

			local status_line = buf:match("^HTTP/1%.1 (%d+)")
			if status_line ~= "101" then
				done = true
				tcp:read_stop()
				tcp:close()
				callback(nil, "unexpected status: " .. (status_line or "nil"))
				return
			end

			done = true
			local handle = {
				tcp = tcp,
				upgraded = true,
			}

			-- Switch to a read handler that only detects disconnection.
			tcp:read_stop()
			tcp:read_start(function(rd_err, rd_data)
				if rd_err or rd_data == nil then
					handle.upgraded = false
				end
			end)

			callback(handle, nil)
		end)

		tcp:write(req, function(write_err)
			if write_err and not done then
				done = true
				tcp:read_stop()
				tcp:close()
				callback(nil, "write upgrade: " .. tostring(write_err))
			end
		end)
	end)
end

--- Send a text message over an established WS connection.
---@param handle dirsv.WSHandle
---@param payload string
---@param on_err fun(err: string)|nil
function M.send(handle, payload, on_err)
	if not handle or not handle.upgraded then
		if on_err then
			on_err("not connected")
		end
		return
	end
	local frame = M.frame_text(payload)
	handle.tcp:write(frame, function(err)
		if err then
			handle.upgraded = false
			if on_err then
				on_err(tostring(err))
			end
		end
	end)
end

--- Close the WebSocket connection gracefully.
---@param handle dirsv.WSHandle|nil
function M.close(handle)
	if not handle or handle.tcp:is_closing() then
		return
	end
	-- Mark as not upgraded first to prevent concurrent sends while
	-- the close frame is in flight.
	local was_upgraded = handle.upgraded
	handle.upgraded = false
	if was_upgraded then
		handle.tcp:write(close_frame(), function()
			if not handle.tcp:is_closing() then
				handle.tcp:close()
			end
		end)
	else
		handle.tcp:close()
	end
end

return M
