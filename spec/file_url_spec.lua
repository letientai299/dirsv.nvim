local dirsv = require('dirsv')
local file_url = dirsv._test.file_url
local set_state = dirsv._test.set_state

describe('file_url', function()
  after_each(function()
    set_state(nil)
  end)

  it('returns correct URL for file under root', function()
    set_state({ root = '/project', port = 8080 })
    assert.are.equal('http://localhost:8080/readme.md', file_url('/project/readme.md'))
  end)

  it('falls back to root URL for file outside root', function()
    set_state({ root = '/project', port = 8080 })
    assert.are.equal('http://localhost:8080/', file_url('/other/readme.md'))
  end)

  it('falls back to root URL for empty file path', function()
    set_state({ root = '/project', port = 8080 })
    assert.are.equal('http://localhost:8080/', file_url(''))
  end)

  it('handles nested paths', function()
    set_state({ root = '/project', port = 8080 })
    assert.are.equal('http://localhost:8080/docs/guide/intro.md', file_url('/project/docs/guide/intro.md'))
  end)

  it('handles root with trailing slash', function()
    set_state({ root = '/project/', port = 9000 })
    assert.are.equal('http://localhost:9000/readme.md', file_url('/project/readme.md'))
  end)
end)
