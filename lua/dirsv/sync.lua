--- Editor sync: sends cursor/scroll/selection events to dirsv server.
---
--- Uses a persistent TCP connection with HTTP/1.1 keep-alive to POST
--- JSON payloads to /api/editor. Events are debounced at 80ms to avoid
--- flooding the server during rapid cursor movement.
local M = {}

local uv = vim.uv or vim.loop
local log = require("dirsv.log")

---@class dirsv.SyncState
---@field tcp uv_tcp_t|nil
---@field timer uv_timer_t|nil
---@field host string
---@field port integer
---@field root string
---@field connected boolean
---@field connecting boolean
---@field pending string|nil buffered payload to send after connect
---@field augroup integer|nil
---@field last_connect_fail integer|nil uv.now() timestamp of last failed connect

---@type dirsv.SyncState|nil
local st = nil

local DEBOUNCE_MS = 80
---@type string|nil concatenated payloads from last flush, for dedup
local last_sent = nil
local RECONNECT_COOLDOWN_MS = 2000

--- Safely close a libuv handle if it's open and not already closing.
---@param handle userdata|nil
local function safe_close(handle)
	if handle and not handle:is_closing() then
		handle:close()
	end
end

--- Build an HTTP/1.1 POST request string.
---@param host string
---@param body string JSON payload
---@return string
local function http_post(host, body)
	return string.format(
		"POST /api/editor HTTP/1.1\r\nHost: %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: keep-alive\r\n\r\n%s",
		host,
		#body,
		body
	)
end

--- Send raw bytes over the TCP socket. Reconnects on failure.
---@param data string
local function tcp_send(data)
	if not st then
		return
	end
	if not st.connected then
		st.pending = data
		if not st.connecting then
			M._connect()
		end
		return
	end
	st.tcp:write(data, function(err)
		if err then
			log.append("ERR", "tcp write: " .. tostring(err))
			st.connected = false
			if st.tcp then
				safe_close(st.tcp)
				st.tcp = nil
			end
			st.pending = data
			M._connect()
		end
	end)
end

--- Parse host and port from a base URL like "http://127.0.0.1:8080".
---@param base_url string
---@return string host, integer port
local function parse_host_port(base_url)
	local host, port = base_url:match("https?://([%w%.%-]+):(%d+)")
	return host or "127.0.0.1", tonumber(port) or 8080
end

--- Get the relative path of a buffer file under root.
---@param bufnr integer
---@return string|nil relative path (forward slashes)
local function buf_rel_path(bufnr)
	if not st then
		return nil
	end
	local name = vim.api.nvim_buf_get_name(bufnr)
	if name == "" then
		return nil
	end
	local r = st.root
	if r:sub(-1) ~= "/" then
		r = r .. "/"
	end
	if not vim.startswith(name, r) then
		return nil
	end
	return name:sub(#r + 1)
end

--- Build JSON payloads for the current editor state.
--- Returns a single-element table with cursor/selection merged with scroll data.
---@return string[] payloads
local function build_payloads()
	local bufnr = vim.api.nvim_get_current_buf()
	local rel = buf_rel_path(bufnr)
	if not rel then
		return {}
	end

	local total = vim.api.nvim_buf_line_count(bufnr)
	local top_line = vim.fn.line("w0")
	local mode = vim.fn.mode()

	-- Visual mode: send selection with scroll data. \22 = CTRL-V (visual block).
	if mode == "v" or mode == "V" or mode == "\22" then
		local vstart = vim.fn.getpos("v")
		local vend = vim.fn.getpos(".")
		local start_line = vstart[2]
		local end_line = vend[2]
		local payload = vim.json.encode({
			type = "selection",
			path = rel,
			startLine = math.min(start_line, end_line),
			endLine = math.max(start_line, end_line),
			topLine = top_line,
			total = total,
		})
		return { payload }
	end

	-- Normal/insert mode: send cursor with scroll data.
	local cursor = vim.api.nvim_win_get_cursor(0)
	local payload = vim.json.encode({
		type = "cursor",
		path = rel,
		line = cursor[1],
		topLine = top_line,
		total = total,
	})
	return { payload }
end

--- Flush current editor state to the server. Skips if identical to last send.
local function flush_payloads()
	if not st then
		return
	end
	local payloads = build_payloads()
	if #payloads == 0 then
		return
	end
	local fingerprint = table.concat(payloads, "\n")
	if fingerprint == last_sent then
		return
	end
	last_sent = fingerprint
	local host_port = st.host .. ":" .. st.port
	for _, payload in ipairs(payloads) do
		log.append("SEND", payload)
		tcp_send(http_post(host_port, payload))
	end
end

--- Schedule a throttled send of the current editor state.
--- Sends immediately on the first event, then at most once per DEBOUNCE_MS
--- while events keep firing. This avoids the trailing-edge delay that made
--- held j/k feel laggy.
local function schedule_send()
	if not st or not st.timer then
		return
	end
	-- Timer already running — a send is already scheduled, nothing to do.
	if st.timer:is_active() then
		return
	end
	-- Send now, then start a cooldown window.
	vim.schedule(flush_payloads)
	st.timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(flush_payloads))
end

--- Send a clear event for the current buffer.
local function send_clear()
	if not st then
		return
	end
	local bufnr = vim.api.nvim_get_current_buf()
	local rel = buf_rel_path(bufnr)
	if not rel then
		return
	end
	local payload = vim.json.encode({ type = "clear", path = rel })
	log.append("SEND", payload)
	tcp_send(http_post(st.host .. ":" .. st.port, payload))
end

--- Connect (or reconnect) the TCP socket.
function M._connect()
	if not st or st.connecting then
		return
	end
	-- Cooldown after a failed connect to avoid flooding.
	if st.last_connect_fail then
		local elapsed = uv.now() - st.last_connect_fail
		if elapsed < RECONNECT_COOLDOWN_MS then
			return
		end
	end
	st.connecting = true

	local tcp = uv.new_tcp()
	if not tcp then
		st.connecting = false
		return
	end

	log.append("CONN", "connecting " .. st.host .. ":" .. st.port)

	tcp:connect(st.host, st.port, function(err)
		if not st then
			safe_close(tcp)
			return
		end
		st.connecting = false
		if err then
			log.append("ERR", "connect: " .. tostring(err))
			safe_close(tcp)
			st.last_connect_fail = uv.now()
			return
		end
		st.tcp = tcp
		st.connected = true
		st.last_connect_fail = nil
		log.append("CONN", "connected " .. st.host .. ":" .. st.port)

		-- Start reading to detect server close (EOF = data is nil).
		tcp:read_start(function(read_err, data)
			if read_err then
				log.append("ERR", "tcp read: " .. tostring(read_err))
			elseif data then
				local first_line = data:match("^[^\r\n]*")
				if first_line and first_line ~= "" then
					log.append("RECV", first_line)
				end
			end
			if read_err or data == nil then
				if st and st.tcp == tcp then
					st.connected = false
					safe_close(tcp)
					st.tcp = nil
				end
			end
		end)

		-- Flush any pending payload.
		if st.pending then
			local data = st.pending
			st.pending = nil
			tcp_send(data)
		end
	end)
end

--- Start editor sync.
---@param base_url string dirsv server base URL
---@param sync_root string project root directory
function M.start(base_url, sync_root)
	if st then
		M.stop()
	end

	local host, port = parse_host_port(base_url)
	local timer = uv.new_timer()
	if not timer then
		return
	end

	st = {
		tcp = nil,
		timer = timer,
		host = host,
		port = port,
		root = sync_root,
		connected = false,
		connecting = false,
		pending = nil,
		augroup = nil,
	}

	M._connect()

	local group = vim.api.nvim_create_augroup("dirsv_sync", { clear = true })
	st.augroup = group

	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "ModeChanged" }, {
		group = group,
		callback = schedule_send,
	})
	-- /query<CR> and ?query<CR>: with incsearch the cursor is already at the
	-- match when cmdline exits, so CursorMoved may not fire.
	vim.api.nvim_create_autocmd("CmdlineLeave", {
		group = group,
		pattern = { "/", "?" },
		callback = schedule_send,
	})
	vim.api.nvim_create_autocmd("WinScrolled", {
		group = group,
		callback = function()
			-- Only react when the current window actually scrolled.
			-- Prevents feedback loop: log buffer auto-scroll fires WinScrolled
			-- for the log window, which would re-trigger schedule_send.
			local curwin = tostring(vim.api.nvim_get_current_win())
			if vim.v.event[curwin] then
				schedule_send()
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufLeave", {
		group = group,
		callback = send_clear,
	})
end

--- Stop editor sync.
function M.stop()
	if not st then
		return
	end

	local s = st
	st = nil -- prevent callbacks from using stale state
	last_sent = nil

	if s.augroup then
		vim.api.nvim_del_augroup_by_id(s.augroup)
	end

	if s.timer then
		s.timer:stop()
		safe_close(s.timer)
	end

	if s.tcp then
		safe_close(s.tcp)
		s.tcp = nil
	end
end

--- Exposed for testing.
M._test = {
	parse_host_port = parse_host_port,
	build_payloads = build_payloads,
	http_post = http_post,
	get_state = function()
		return st
	end,
}

return M
