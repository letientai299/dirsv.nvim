local file_url = require('dirsv')._test.file_url

describe('file_url', function()
  local function srv(root, base_url)
    return { root = root, base_url = base_url }
  end

  it('returns correct URL for file under root', function()
    assert.are.equal('http://127.0.0.1:8080/readme.md', file_url('/project/readme.md', srv('/project', 'http://127.0.0.1:8080')))
  end)

  it('falls back to root URL for file outside root', function()
    assert.are.equal('http://127.0.0.1:8080/', file_url('/other/readme.md', srv('/project', 'http://127.0.0.1:8080')))
  end)

  it('falls back to root URL for empty file path', function()
    assert.are.equal('http://127.0.0.1:8080/', file_url('', srv('/project', 'http://127.0.0.1:8080')))
  end)

  it('handles nested paths', function()
    assert.are.equal('http://127.0.0.1:8080/docs/guide/intro.md', file_url('/project/docs/guide/intro.md', srv('/project', 'http://127.0.0.1:8080')))
  end)

  it('handles root with trailing slash', function()
    assert.are.equal('http://127.0.0.1:9000/readme.md', file_url('/project/readme.md', srv('/project/', 'http://127.0.0.1:9000')))
  end)

  it('preserves base_url host from dirsv', function()
    assert.are.equal('http://localhost:4567/readme.md', file_url('/project/readme.md', srv('/project', 'http://localhost:4567')))
  end)
end)
