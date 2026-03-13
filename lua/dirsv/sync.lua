--- Editor sync: sends cursor/scroll/selection events to dirsv server(s).
---
--- Uses WebSocket connections to /api/editor/ws. Events are debounced at
--- 16ms (~60fps) with leading-edge flush to avoid lag during rapid cursor
--- movement. Supports multiple targets via a resolver function that maps
--- buffers to their server's host:port and root.
local M = {}

local uv = vim.uv or vim.loop
local log = require("dirsv.log")
local ws = require("dirsv.ws")

---@class dirsv.ConnState
---@field handle dirsv.WSHandle|nil
---@field connecting boolean
---@field pending string[] buffered payloads to send after connect
---@field last_connect_fail integer|nil uv.now() timestamp of last failed connect

---@class dirsv.SyncTarget
---@field host string
---@field port integer
---@field root string

---@class dirsv.SyncState
---@field conns table<string, dirsv.ConnState>
---@field timer uv_timer_t|nil
---@field resolver fun(bufnr: integer): dirsv.SyncTarget|nil
---@field augroup integer|nil

---@type dirsv.SyncState|nil
local st = nil

local DEBOUNCE_MS = 16
local RECONNECT_COOLDOWN_MS = 2000
---@type string|nil last addr for dedup
local last_addr = nil
---@type string|nil last payload for dedup
local last_payload = nil

--- Safely close a libuv handle if it's open and not already closing.
---@param handle userdata|nil
local function safe_close(handle)
	if handle and not handle:is_closing() then
		handle:close()
	end
end

--- Return the relative path of file under root_dir, or nil if not contained.
---@param file string absolute path
---@param root_dir string absolute root directory
---@return string|nil relative path (forward slashes)
local function rel_path(file, root_dir)
	local r = root_dir
	if r:sub(-1) ~= "/" then
		r = r .. "/"
	end
	if not vim.startswith(file, r) then
		return nil
	end
	return file:sub(#r + 1)
end

--- Get the relative path of a buffer file under a given root.
---@param bufnr integer
---@param root string
---@return string|nil relative path (forward slashes)
local function buf_rel_path(bufnr, root)
	local name = vim.api.nvim_buf_get_name(bufnr)
	if name == "" then
		return nil
	end
	return rel_path(name, root)
end

--- Send a payload to a specific address via WebSocket.
---@param addr string "host:port"
---@param payload string JSON payload
local function ws_send(addr, payload)
	if not st then
		return
	end
	local conn = st.conns[addr]
	if not conn then
		-- Create a new connection entry.
		conn = { handle = nil, connecting = false, pending = {}, last_connect_fail = nil }
		st.conns[addr] = conn
	end

	if conn.handle and conn.handle.upgraded then
		ws.send(conn.handle, payload, function(err)
			if err then
				log.append("ERR", "ws write: " .. tostring(err))
				if conn.handle then
					ws.close(conn.handle)
					conn.handle = nil
				end
				table.insert(conn.pending, payload)
				M._connect(addr)
			end
		end)
		return
	end

	table.insert(conn.pending, payload)
	if not conn.connecting then
		M._connect(addr)
	end
end

--- Connect (or reconnect) a WebSocket to a target address.
---@param addr string "host:port"
function M._connect(addr)
	if not st then
		return
	end
	local conn = st.conns[addr]
	if not conn or conn.connecting then
		return
	end
	-- Cooldown after a failed connect to avoid flooding.
	if conn.last_connect_fail then
		local elapsed = uv.now() - conn.last_connect_fail
		if elapsed < RECONNECT_COOLDOWN_MS then
			return
		end
	end
	conn.connecting = true

	local host, port_str = addr:match("^(.+):(%d+)$")
	local port = tonumber(port_str)
	if not host or not port then
		conn.connecting = false
		return
	end

	log.append("CONN", "ws connecting " .. addr)

	ws.connect(host, port, "/api/editor/ws", function(handle, err)
		local c = st and st.conns[addr]
		if not c then
			if handle then ws.close(handle) end
			return
		end
		c.connecting = false
		if err then
			log.append("ERR", "ws connect: " .. tostring(err))
			c.last_connect_fail = uv.now()
			return
		end
		c.handle = handle
		c.last_connect_fail = nil
		log.append("CONN", "ws connected " .. addr)

		-- Flush pending payloads. libuv callbacks run on Neovim's main
		-- thread, so accessing st and calling ws.send is safe here.
		if #c.pending > 0 then
			local queue = c.pending
			c.pending = {}
			for _, data in ipairs(queue) do
				ws_send(addr, data)
			end
		end
	end)
end

--- Resolve the current buffer to its sync target address, relative path, and bufnr.
---@return string|nil addr, string|nil rel, integer|nil bufnr
local function resolve_current_buf()
	if not st or not st.resolver then
		return nil, nil, nil
	end
	local bufnr = vim.api.nvim_get_current_buf()
	local target = st.resolver(bufnr)
	if not target then
		return nil, nil, nil
	end
	local rel = buf_rel_path(bufnr, target.root)
	if not rel then
		return nil, nil, nil
	end
	return target.host .. ":" .. target.port, rel, bufnr
end

--- Build a JSON payload for the current editor state and resolve the target.
---@return string|nil payload, string|nil addr "host:port"
local function build_payload()
	local addr, rel, bufnr = resolve_current_buf()
	if not addr then
		return nil, nil
	end
	local viewport = {
		path = rel,
		topLine = vim.fn.line("w0"),
		bottomLine = vim.fn.line("w$"),
		total = vim.api.nvim_buf_line_count(bufnr),
	}

	local mode = vim.fn.mode()
	-- Visual mode: send selection. \22 = CTRL-V (visual block).
	if mode == "v" or mode == "V" or mode == "\22" then
		local vstart = vim.fn.getpos("v")
		local vend = vim.fn.getpos(".")
		viewport.type = "selection"
		viewport.startLine = math.min(vstart[2], vend[2])
		viewport.endLine = math.max(vstart[2], vend[2])
		return vim.json.encode(viewport), addr
	end

	-- Normal/insert mode: send cursor.
	viewport.type = "cursor"
	viewport.line = vim.api.nvim_win_get_cursor(0)[1]
	return vim.json.encode(viewport), addr
end

--- Flush current editor state to the server. Skips if identical to last send.
local function flush_payloads()
	if not st then
		return
	end
	local payload, addr = build_payload()
	if not payload or not addr then
		return
	end
	if addr == last_addr and payload == last_payload then
		return
	end
	last_addr = addr
	last_payload = payload
	log.append("SEND", payload)
	ws_send(addr, payload)
end

--- Schedule a throttled send of the current editor state.
--- Sends immediately on the first event, then at most once per DEBOUNCE_MS
--- while events keep firing.
local function schedule_send()
	if not st or not st.timer then
		return
	end
	-- Timer already running — a send is already scheduled, nothing to do.
	if st.timer:is_active() then
		return
	end
	-- Send now (autocmd callbacks run on main thread), then start cooldown.
	flush_payloads()
	st.timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(flush_payloads))
end

--- Send a clear event for the current buffer.
local function send_clear()
	local addr, rel = resolve_current_buf()
	if not addr then
		return
	end
	local payload = vim.json.encode({ type = "clear", path = rel })
	log.append("SEND", payload)
	ws_send(addr, payload)
end

--- Start editor sync with a resolver that maps buffers to targets.
--- Idempotent — if already started, updates the resolver.
---@param resolver fun(bufnr: integer): dirsv.SyncTarget|nil
function M.start(resolver)
	if st then
		-- Already running — just update the resolver.
		st.resolver = resolver
		return
	end

	local timer = uv.new_timer()
	if not timer then
		return
	end

	st = {
		conns = {},
		timer = timer,
		resolver = resolver,
		augroup = nil,
	}

	local group = vim.api.nvim_create_augroup("dirsv_sync", { clear = true })
	st.augroup = group

	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufEnter" }, {
		group = group,
		callback = schedule_send,
	})
	-- Only fire on visual mode entry/exit — other mode transitions don't
	-- change the payload type (cursor vs selection).
	vim.api.nvim_create_autocmd("ModeChanged", {
		group = group,
		pattern = { "*:[vV\x16]*", "[vV\x16]*:*" },
		callback = schedule_send,
	})
	-- /query<CR> and ?query<CR>: with incsearch the cursor is already at the
	-- match when cmdline exits, so CursorMoved may not fire.
	vim.api.nvim_create_autocmd("CmdlineLeave", {
		group = group,
		pattern = { "/", "?" },
		callback = schedule_send,
	})
	-- WinScrolled fires for any window (including the log buffer).
	-- Filter to current window to prevent feedback loops.
	vim.api.nvim_create_autocmd("WinScrolled", {
		group = group,
		callback = function()
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
	last_addr = nil
	last_payload = nil

	if s.augroup then
		vim.api.nvim_del_augroup_by_id(s.augroup)
	end

	if s.timer then
		s.timer:stop()
		safe_close(s.timer)
	end

	for _, conn in pairs(s.conns) do
		if conn.handle then
			ws.close(conn.handle)
			conn.handle = nil
		end
	end
end

--- Send a close event to dismiss existing browser tabs for the given path.
---@param host string
---@param port integer
---@param root_dir string server root directory
---@param file string absolute file path (or empty for root)
function M.send_close(host, port, root_dir, file)
	local rel = file ~= "" and rel_path(file, root_dir) or ""
	local addr = host .. ":" .. port
	local payload = vim.json.encode({ type = "close", path = rel or "" })
	log.append("SEND", payload)
	ws_send(addr, payload)
end

--- Exposed for testing.
M._test = {
	build_payload = build_payload,
	get_state = function()
		return st
	end,
}

return M
