--- Buffer name utilities for resolving plugin-specific URI schemes.
local M = {}

--- Extract repo root and relative path from a git-object URI.
--- Covers diffview, gitsigns, and fugitive.
---@param name string
---@return string|nil repo, string|nil rel
local function match_git_uri(name)
  -- diffview.nvim: diffview:///repo/.git/:0:/relative/path
  local repo, rel = name:match("^diffview://(.+)/%.git/:%d+:/(.+)$")
  if repo then
    return repo, rel
  end
  -- gitsigns.nvim: gitsigns:///repo/.git//<rev>:<relpath>
  -- rev can be :0 (index), a commit hash, or HEAD.
  repo, rel = name:match("^gitsigns://(.+)/%.git//:?[^:]*:(.+)$")
  if repo then
    return repo, rel
  end
  -- fugitive.vim: fugitive:///repo/.git//<rev>/relpath
  -- rev is a stage number (0-3) or a hex commit hash (40+ chars).
  return name:match("^fugitive://(.+)/%.git//[%x]+/(.+)$")
end

--- Resolve a plugin buffer name to a real filesystem path.
--- Handles oil.nvim, copilot.lua, diffview.nvim, gitsigns.nvim, and fugitive.vim.
---@param name string buffer name
---@return string filesystem path (unchanged if no scheme matched)
function M.resolve_path(name)
  -- Fast path: normal filesystem paths (vast majority of calls).
  local b = name:byte(1)
  if not b or b == 47 --[[ / ]] then
    return name
  end
  -- oil.nvim: oil:///absolute/path/
  -- copilot.lua: copilot:///absolute/path
  local simple = name:match("^oil://(.+)$") or name:match("^copilot://(.+)$")
  if simple then
    return simple
  end
  local repo, rel = match_git_uri(name)
  if repo then
    return repo .. "/" .. rel
  end
  return name
end

return M
