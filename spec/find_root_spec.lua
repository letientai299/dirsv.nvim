local git_toplevel = require('dirsv')._test.git_toplevel

describe('git_toplevel', function()
  local tmpdir

  before_each(function()
    tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, 'p')
    -- Resolve symlinks (macOS /var → /private/var) to match git rev-parse output.
    tmpdir = vim.uv.fs_realpath(tmpdir)
  end)

  after_each(function()
    vim.fn.delete(tmpdir, 'rf')
  end)

  it('returns toplevel when inside a git repo', function()
    vim.system({ 'git', 'init', tmpdir }):wait()
    local nested = tmpdir .. '/a/b/c'
    vim.fn.mkdir(nested, 'p')

    assert.are.equal(tmpdir, git_toplevel(nested))
  end)

  it('returns nil when not in a git repo', function()
    assert.is_nil(git_toplevel(tmpdir))
  end)
end)
