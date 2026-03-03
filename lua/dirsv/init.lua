local M = {}

---@class dirsv.State
---@field pid integer|nil
---@field port integer
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

--- Find a free port starting from `base`.
--- Binds + listens to confirm the port is truly available, then closes.
---@param base integer
---@return integer
local function find_free_port(base)
  for port = base, base + 99 do
    local server = vim.uv.new_tcp()
    if server then
      local ret = server:bind("127.0.0.1", port)
      if ret == 0 then
        -- bind alone isn't enough — listen confirms no TIME_WAIT conflict.
        ret = server:listen(1, function() end)
      end
      server:close()
      if ret == 0 then
        return port
      end
    end
  end
  return base
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
  if file == "" then
    return string.format("http://localhost:%d/", state.port)
  end
  local root = state.root
  -- Ensure root ends with / for prefix matching.
  if root:sub(-1) ~= "/" then
    root = root .. "/"
  end
  if not vim.startswith(file, root) then
    return string.format("http://localhost:%d/", state.port)
  end
  local rel = file:sub(#root + 1)
  return string.format("http://localhost:%d/%s", state.port, rel)
end

function M.start()
  local file = vim.api.nvim_buf_get_name(0)

  -- Already running — just open the browser.
  if state and state.job_id then
    open_browser(file_url(file))
    return
  end

  local root = file ~= "" and find_root(file) or vim.fn.getcwd()
  local port = find_free_port(8080)

  local stderr_chunks = {}

  local cmd = { "dirsv", root, "--no-open", "-p", tostring(port) }
  vim.notify(LOG_PREFIX .. "starting: " .. table.concat(cmd, " "), vim.log.levels.DEBUG)

  local job_id = vim.fn.jobstart(cmd, {
    detach = false,
    stderr_buffered = false,
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
    port = port,
    root = root,
    job_id = job_id,
    stderr = stderr_chunks,
  }

  -- Give dirsv a moment to bind the port, then open browser.
  vim.defer_fn(function()
    if state then
      open_browser(file_url(file))
    end
  end, 300)
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
  find_free_port = find_free_port,
  file_url = file_url,
  get_state = function() return state end,
  set_state = function(s) state = s end,
}

return M
