--- Realtime communication log for dirsv.
---
--- Singleton module owning an in-memory line buffer and a scratch Neovim
--- buffer. Callers from uv/jobstart callbacks are safe — append() wraps
--- buffer writes in vim.schedule.
local M = {}

local MAX_LINES = 1000
local BUF_NAME = "dirsv://log"

---@type string[]
local lines = {}

---@type integer|nil scratch buffer number
local bufnr = nil

local enabled = false

--- Format a tag to fixed width (6 chars, right-padded).
---@param tag string
---@return string
local function fmt_tag(tag)
  return string.format("%-6s", tag)
end

--- Append a log line. Safe to call from uv/jobstart callbacks.
---@param tag string short tag (SPAWN, CONN, SEND, etc.)
---@param msg string message text
function M.append(tag, msg)
  if not enabled then
    return
  end
  local ms = vim.uv and vim.uv.now() or (vim.loop and vim.loop.now() or 0)
  local secs = math.floor(ms / 1000)
  local millis = ms % 1000
  local h = math.floor(secs / 3600) % 24
  local m = math.floor(secs / 60) % 60
  local s = secs % 60
  local ts = string.format("%02d:%02d:%02d.%03d", h, m, s, millis)
  local line = ts .. "  [" .. fmt_tag(tag) .. "]  " .. msg

  table.insert(lines, line)

  if #lines > MAX_LINES then
    table.remove(lines, 1)
  end

  vim.schedule(function()
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      bufnr = nil
      return
    end

    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { line })

    -- Auto-scroll any window showing the log buffer.
    local last = vim.api.nvim_buf_line_count(bufnr)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == bufnr then
        vim.api.nvim_win_set_cursor(win, { last, 0 })
      end
    end
  end)
end

--- Open the log split without stealing focus.
function M.open()
  -- Already visible — nothing to do.
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == bufnr then
        return
      end
    end
  end

  local prev_win = vim.api.nvim_get_current_win()

  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, BUF_NAME)
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile = false
    if #lines > 0 then
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    end
  end

  vim.cmd("botright 12split")
  vim.api.nvim_win_set_buf(0, bufnr)

  -- Window-local options.
  local log_win = vim.api.nvim_get_current_win()
  vim.wo[log_win].wrap = false
  vim.wo[log_win].number = false
  vim.wo[log_win].signcolumn = "no"

  vim.api.nvim_set_current_win(prev_win)
end

function M.enable()
  enabled = true
end

function M.disable()
  enabled = false
end

return M
