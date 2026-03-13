--- Minimal WebSocket client over libuv TCP.
---
--- Implements just enough of RFC 6455 for editor sync:
--- client-side text frames (≤65535 bytes), upgrade handshake, and close.
local M = {}

local uv = vim.uv or vim.loop
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
		-- 2-byte extended length
		header = header
			.. string.char(0x80 + 126)
			.. string.char(math.floor(len / 256))
			.. string.char(len % 256)
	else
		error("payload too large for ws.frame_text")
	end

	-- 4-byte mask key
	local mask = {
		math.random(0, 255),
		math.random(0, 255),
		math.random(0, 255),
		math.random(0, 255),
	}
	header = header .. string.char(mask[1], mask[2], mask[3], mask[4])

	-- XOR-mask the payload
	local masked = {}
	for i = 1, len do
		masked[i] = string.char(bit.bxor(string.byte(payload, i), mask[((i - 1) % 4) + 1]))
	end

	return header .. table.concat(masked)
end

--- Build a close frame (opcode 0x8) with mask.
---@return string
local function close_frame()
	-- FIN + close opcode, masked, 2-byte status code (1000 = normal closure)
	local mask = {
		math.random(0, 255),
		math.random(0, 255),
		math.random(0, 255),
		math.random(0, 255),
	}
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
---@field buf string partial data from read_start

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
				buf = buf:sub(header_end + 4),
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
	if not handle then
		return
	end
	if handle.upgraded and not handle.tcp:is_closing() then
		-- Send close frame, then shut down.
		handle.tcp:write(close_frame(), function()
			if not handle.tcp:is_closing() then
				handle.tcp:close()
			end
		end)
	elseif not handle.tcp:is_closing() then
		handle.tcp:close()
	end
	handle.upgraded = false
end

return M
