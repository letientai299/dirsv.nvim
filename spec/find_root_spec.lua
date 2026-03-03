local find_root = require('dirsv')._test.find_root

describe('find_root', function()
  local tmpdir

  before_each(function()
    tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, 'p')
  end)

  after_each(function()
    vim.fn.delete(tmpdir, 'rf')
  end)

  it('returns git root when .git exists in ancestor', function()
    local git_dir = tmpdir .. '/.git'
    vim.fn.mkdir(git_dir)
    local nested = tmpdir .. '/a/b/c'
    vim.fn.mkdir(nested, 'p')
    local file = nested .. '/test.md'

    assert.are.equal(tmpdir, find_root(file))
  end)

  it('falls back to cwd when no .git found', function()
    local file = tmpdir .. '/test.md'
    local cwd = vim.fn.getcwd()

    assert.are.equal(cwd, find_root(file))
  end)
end)
