if vim.g.loaded_dirsv then
  return
end
vim.g.loaded_dirsv = true

vim.api.nvim_create_user_command("Dirsv", function(opts)
  require("dirsv").start(opts.args ~= "" and opts.args or nil)
end, { nargs = "?", complete = "file", desc = "Start dirsv and open file preview in browser" })

vim.api.nvim_create_user_command("DirsvStop", function()
  require("dirsv").stop()
end, { desc = "Stop the dirsv preview server" })
