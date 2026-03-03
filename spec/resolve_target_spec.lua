local resolve_target = require('dirsv')._test.resolve_target

describe('resolve_target', function()
  it('returns absolute path when arg is given', function()
    local path = vim.fn.tempname() .. '.md'
    assert.are.equal(path, resolve_target(path))
  end)

  it('expands relative arg to absolute path', function()
    local result = resolve_target('foo.md')
    local expected = vim.fn.fnamemodify('foo.md', ':p')
    assert.are.equal(expected, result)
  end)

  it('falls back to buffer name when arg is nil', function()
    local name = vim.fn.tempname() .. '.md'
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_name(buf, name)
    -- nvim resolves symlinks on buf names, so compare against actual buf name.
    assert.are.equal(vim.api.nvim_buf_get_name(buf), resolve_target(nil))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it('falls back to buffer name when arg is empty string', function()
    local name = vim.fn.tempname() .. '.md'
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_name(buf, name)
    assert.are.equal(vim.api.nvim_buf_get_name(buf), resolve_target(''))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it('returns empty string for no-name buffer with no arg', function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    assert.are.equal('', resolve_target(nil))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
