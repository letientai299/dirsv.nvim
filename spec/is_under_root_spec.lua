local dirsv = require('dirsv')
local is_under_root = dirsv._test.is_under_root
local set_root = dirsv._test.set_root
local get_root = dirsv._test.get_root

describe('is_under_root', function()
  local original_root

  before_each(function()
    original_root = get_root()
    set_root('/project')
  end)

  after_each(function()
    set_root(original_root)
  end)

  it('returns true for path under root', function()
    assert.is_true(is_under_root('/project/src/main.go'))
  end)

  it('returns false for path outside root', function()
    assert.is_false(is_under_root('/tmp/foo.md'))
  end)

  it('returns false for path that shares prefix but is not under root', function()
    assert.is_false(is_under_root('/project-other/file.md'))
  end)

  it('returns true for path directly under root', function()
    assert.is_true(is_under_root('/project/file.md'))
  end)
end)
