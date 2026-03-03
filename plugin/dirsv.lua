if vim.g.loaded_dirsv then
  return
end
vim.g.loaded_dirsv = true

vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("dirsv_commands", { clear = true }),
  pattern = "markdown",
  callback = function(args)
    vim.api.nvim_buf_create_user_command(args.buf, "MarkdownPreview", function()
      require("dirsv").start()
    end, { desc = "Start dirsv and open markdown preview in browser" })

    vim.api.nvim_buf_create_user_command(args.buf, "MarkdownPreviewStop", function()
      require("dirsv").stop()
    end, { desc = "Stop the dirsv preview server" })
  end,
})
