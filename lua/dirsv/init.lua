local M = {}

---@class dirsv.State
---@field pid integer|nil
---@field base_url string
---@field root string
---@field job_id integer|nil
---@field stderr string[]

local LOG_PREFIX = "dirsv: "

-- Captured once at module load, before any :cd/:lcd/:tcd.
local vim_start_dir = vim.fn.getcwd()

local has_git = vim.fn.executable("git") == 1
local has_dirsv = vim.fn.executable("dirsv") == 1

--- Find git toplevel from a directory, or return nil.
---@param dir string absolute directory path
---@return string|nil
local function git_toplevel(dir)
  if not has_git then
    return nil
  end
  local result = vim.system(
    { "git", "-C", dir, "rev-parse", "--show-toplevel" },
    { text = true }
  ):wait()
  if result.code ~= 0 then
    return nil
  end
  return vim.trim(result.stdout)
end

-- Root is fixed for the entire session.
local root = git_toplevel(vim_start_dir) or vim_start_dir

---@type dirsv.State|nil
local state = nil

---@type table<integer, dirsv.State>
local buf_servers = {}

--- Extract the base URL from dirsv's startup line.
--- dirsv prints "serving <path> on http://<host>:<port>" to stdout.
---@param line string
---@return string|nil base URL (e.g. "http://127.0.0.1:8084")
local function parse_serve_url(line)
  return line:match("(https?://[%w%.%-]+:%d+)")
end

--- Open a URL in the system browser.
---@param url string
local function open_browser(url)
  local cmd
  if vim.fn.has("mac") == 1 then
    cmd = { "open", url }
  elseif vim.fn.has("unix") == 1 then
    cmd = { "xdg-open", url }
  elseif vim.fn.has("win32") == 1 then
    cmd = { "cmd", "/c", "start", url }
  end
  if cmd then
    vim.system(cmd, { detach = true })
  end
end

--- Build the URL for a file under a served root.
---@param file string absolute path
---@param srv dirsv.State server state to read base_url/root from
---@return string
local function file_url(file, srv)
  local base = srv.base_url
  if file == "" then
    return base .. "/"
  end
  local srv_root = srv.root
  if srv_root:sub(-1) ~= "/" then
    srv_root = srv_root .. "/"
  end
  if not vim.startswith(file, srv_root) then
    return base .. "/"
  end
  local rel = file:sub(#srv_root + 1)
  return base .. "/" .. rel
end

--- Resolve the target path from an optional argument or the current buffer.
---@param arg string|nil optional file/dir path from :Dirsv <arg>
---@param base string|nil directory to resolve relative args against
---@return string absolute path (may be empty if no arg and no buffer name)
local function resolve_target(arg, base)
  if arg and arg ~= "" then
    if base and vim.fn.fnamemodify(arg, ":p") ~= arg then
      return vim.fn.fnamemodify(base .. "/" .. arg, ":p")
    end
    return vim.fn.fnamemodify(arg, ":p")
  end
  return vim.api.nvim_buf_get_name(0)
end

--- Check if a path is under the session root.
---@param path string absolute path
---@return boolean
local function is_under_root(path)
  local r = root
  if r:sub(-1) ~= "/" then
    r = r .. "/"
  end
  return vim.startswith(path, r)
end

--- Spawn a dirsv server.
---@param cmd string[] command to run
---@param on_url fun(base_url: string) called when URL is parsed from stdout
---@param on_exit_clean fun() called when server exits cleanly
---@return dirsv.State|nil
local function spawn_server(cmd, on_url, on_exit_clean)
  local stderr_chunks = {}
  local url_parsed = false

  local job_id = vim.fn.jobstart(cmd, {
    detach = false,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if url_parsed or not data then
        return
      end
      for _, line in ipairs(data) do
        local base_url = parse_serve_url(line)
        if base_url then
          url_parsed = true
          vim.schedule(function()
            on_url(base_url)
          end)
          return
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stderr_chunks, line)
          end
        end
      end
    end,
    on_exit = function(id, code)
      vim.schedule(function()
        on_exit_clean()
        if code ~= 0 and code ~= 143 then
          local msg = LOG_PREFIX .. "exited with code " .. code
          if #stderr_chunks > 0 then
            msg = msg .. "\n" .. table.concat(stderr_chunks, "\n")
          end
          vim.notify(msg, vim.log.levels.ERROR)
        end
      end)
    end,
  })

  if job_id <= 0 then
    vim.notify(LOG_PREFIX .. "failed to start (is dirsv in PATH?)", vim.log.levels.ERROR)
    return nil
  end

  local pid = vim.fn.jobpid(job_id)
  return {
    pid = pid,
    base_url = "",
    root = "",
    job_id = job_id,
    stderr = stderr_chunks,
  }
end

--- Stop a server by its state, if running.
---@param srv dirsv.State|nil
local function stop_server(srv)
  if srv and srv.job_id then
    vim.fn.jobstop(srv.job_id)
  end
end

--- Start or reuse the global root-mode server, then open a URL.
---@param target string absolute path to open
local function start_root_mode(target)
  if state and state.job_id then
    local url = file_url(target, state)
    open_browser(url)
    vim.notify(LOG_PREFIX .. url, vim.log.levels.INFO)
    return
  end

  local captured_target = target
  local cmd = { "dirsv", root, "--no-open" }

  local srv = spawn_server(cmd, function(base_url)
    if not state then
      return
    end
    state.base_url = base_url
    local url = file_url(captured_target, state)
    open_browser(url)
    vim.notify(LOG_PREFIX .. url, vim.log.levels.INFO)
  end, function()
    -- on_exit: clear global state only if it's still ours.
    if state and state.job_id and srv and state.job_id == srv.job_id then
      state = nil
    end
  end)

  if not srv then
    return
  end
  srv.root = root
  state = srv
end

--- Start or reuse a single-file buffer server, then open a URL.
---@param target string absolute file path
local function start_single_file_mode(target)
  local bufnr = vim.fn.bufnr(target)
  if bufnr == -1 then
    vim.cmd("badd " .. vim.fn.fnameescape(target))
    bufnr = vim.fn.bufnr(target)
  end

  local existing = buf_servers[bufnr]
  if existing and existing.job_id then
    local url = existing.base_url .. "/" .. vim.fn.fnamemodify(target, ":t")
    open_browser(url)
    vim.notify(LOG_PREFIX .. url, vim.log.levels.INFO)
    return
  end

  local captured_bufnr = bufnr
  local basename = vim.fn.fnamemodify(target, ":t")
  local cmd = { "dirsv", target, "--no-open" }

  local srv = spawn_server(cmd, function(base_url)
    if not buf_servers[captured_bufnr] then
      return
    end
    buf_servers[captured_bufnr].base_url = base_url
    local url = base_url .. "/" .. basename
    open_browser(url)
    vim.notify(LOG_PREFIX .. url, vim.log.levels.INFO)
  end, function()
    -- on_exit: clear entry only if it's still ours.
    local entry = buf_servers[captured_bufnr]
    if entry and srv and entry.job_id == srv.job_id then
      buf_servers[captured_bufnr] = nil
    end
  end)

  if not srv then
    return
  end
  srv.root = vim.fn.fnamemodify(target, ":p:h")
  buf_servers[bufnr] = srv

  vim.api.nvim_create_autocmd("BufDelete", {
    buffer = bufnr,
    once = true,
    callback = function()
      local entry = buf_servers[bufnr]
      if entry then
        stop_server(entry)
        buf_servers[bufnr] = nil
      end
    end,
  })
end

---@param arg string|nil optional file/dir path
function M.start(arg)
  if not has_dirsv then
    vim.notify(LOG_PREFIX .. "dirsv not found in PATH", vim.log.levels.ERROR)
    return
  end

  -- Resolve against root when global server is running, else against CWD.
  local base = state and state.job_id and root or nil
  local target = resolve_target(arg, base)

  if target == "" then
    vim.notify(LOG_PREFIX .. "no file to preview", vim.log.levels.WARN)
    return
  end

  -- Validate explicit arg exists on disk.
  if arg and arg ~= "" and vim.fn.filereadable(target) == 0 and vim.fn.isdirectory(target) == 0 then
    vim.notify(LOG_PREFIX .. "path doesn't exist: " .. arg, vim.log.levels.WARN)
    return
  end

  if is_under_root(target) then
    start_root_mode(target)
  else
    start_single_file_mode(target)
  end
end

function M.stop()
  local had_any = false

  if state and state.job_id then
    stop_server(state)
    state = nil
    had_any = true
  end

  for bufnr, srv in pairs(buf_servers) do
    stop_server(srv)
    buf_servers[bufnr] = nil
    had_any = true
  end

  if not had_any then
    vim.notify(LOG_PREFIX .. "not running", vim.log.levels.INFO)
  end
end

local function setup_cleanup()
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("dirsv_cleanup", { clear = true }),
    callback = function()
      if state and state.job_id then
        vim.fn.jobstop(state.job_id)
        state = nil
      end
      for bufnr, srv in pairs(buf_servers) do
        stop_server(srv)
        buf_servers[bufnr] = nil
      end
    end,
  })
end

setup_cleanup()

M._test = {
  git_toplevel = git_toplevel,
  parse_serve_url = parse_serve_url,
  file_url = file_url,
  resolve_target = resolve_target,
  is_under_root = is_under_root,
  get_state = function() return state end,
  set_state = function(s) state = s end,
  get_root = function() return root end,
  set_root = function(r) root = r end,
  get_buf_servers = function() return buf_servers end,
  set_buf_servers = function(bs) buf_servers = bs end,
}

return M
