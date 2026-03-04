local M = {}

---@class dirsv.State
---@field pid integer|nil
---@field base_url string
---@field root string
---@field job_id integer|nil
---@field stderr string[]

---@type dirsv.State|nil
local state = nil

local LOG_PREFIX = "dirsv: "

--- Find git root by walking up from `path`, or return cwd.
---@param path string
---@return string
local function find_root(path)
  local dir = vim.fn.fnamemodify(path, ":p:h")
  local root = vim.fs.root(dir, ".git")
  return root or vim.fn.getcwd()
end

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

--- Build the URL for a file or directory.
--- Falls back to root URL when file is empty or outside the served root.
---@param file string absolute path of the file (may be empty)
---@return string
local function file_url(file)
  local base = state.base_url
  if file == "" then
    return base .. "/"
  end
  local root = state.root
  -- Ensure root ends with / for prefix matching.
  if root:sub(-1) ~= "/" then
    root = root .. "/"
  end
  if not vim.startswith(file, root) then
    return base .. "/"
  end
  local rel = file:sub(#root + 1)
  return base .. "/" .. rel
end

--- Resolve the target path from an optional argument or the current buffer.
--- When `base` is given, relative `arg` paths resolve against it instead of
--- Neovim's CWD (which may have drifted via `:cd`).
---@param arg string|nil optional file/dir path from :Dirsv <arg>
---@param base string|nil directory to resolve relative args against
---@return string absolute path (may be empty if no arg and no buffer name)
local function resolve_target(arg, base)
  if arg and arg ~= "" then
    if base and vim.fn.fnamemodify(arg, ":p") ~= arg then
      -- arg is relative — resolve against base, not CWD.
      return vim.fn.fnamemodify(base .. "/" .. arg, ":p")
    end
    return vim.fn.fnamemodify(arg, ":p")
  end
  return vim.api.nvim_buf_get_name(0)
end

---@param arg string|nil optional file/dir path
function M.start(arg)
  -- Already running — resolve against the serve root, not CWD.
  if state and state.job_id then
    local target = resolve_target(arg, state.root)
    local url = file_url(target)
    open_browser(url)
    vim.notify(LOG_PREFIX .. "opened: " .. url, vim.log.levels.INFO)
    return
  end

  local target = resolve_target(arg)
  local root = target ~= "" and find_root(target) or vim.fn.getcwd()

  local stderr_chunks = {}
  local opened = false

  local cmd = { "dirsv", root, "--no-open" }
  vim.notify(LOG_PREFIX .. "starting: " .. table.concat(cmd, " "), vim.log.levels.DEBUG)

  local job_id = vim.fn.jobstart(cmd, {
    detach = false,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if opened or not data then
        return
      end
      for _, line in ipairs(data) do
        local base_url = parse_serve_url(line)
        if base_url and state then
          opened = true
          state.base_url = base_url
          vim.schedule(function()
            if state then
              local url = file_url(target)
              open_browser(url)
              vim.notify(LOG_PREFIX .. "opened: " .. url, vim.log.levels.INFO)
            end
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
    on_exit = function(_, code)
      local was_running = state and state.job_id
      if was_running then
        state = nil
      end
      if code ~= 0 and code ~= 143 then -- 143 = SIGTERM
        vim.schedule(function()
          local msg = LOG_PREFIX .. "exited with code " .. code
          if #stderr_chunks > 0 then
            msg = msg .. "\n" .. table.concat(stderr_chunks, "\n")
          end
          vim.notify(msg, vim.log.levels.ERROR)
        end)
      end
    end,
  })

  if job_id <= 0 then
    vim.notify("dirsv: failed to start (is dirsv in PATH?)", vim.log.levels.ERROR)
    return
  end

  local pid = vim.fn.jobpid(job_id)

  state = {
    pid = pid,
    base_url = "",
    root = root,
    job_id = job_id,
    stderr = stderr_chunks,
  }
end

function M.stop()
  if not state or not state.job_id then
    vim.notify("dirsv: not running", vim.log.levels.INFO)
    return
  end
  vim.fn.jobstop(state.job_id)
  state = nil
end

--- Register autocmd to kill dirsv on VimLeavePre.
local function setup_cleanup()
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("dirsv_cleanup", { clear = true }),
    callback = function()
      if state and state.job_id then
        vim.fn.jobstop(state.job_id)
        state = nil
      end
    end,
  })
end

setup_cleanup()

M._test = {
  find_root = find_root,
  parse_serve_url = parse_serve_url,
  file_url = file_url,
  resolve_target = resolve_target,
  get_state = function() return state end,
  set_state = function(s) state = s end,
}

return M
