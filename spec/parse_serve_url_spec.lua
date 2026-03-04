local parse_serve_url = require('dirsv')._test.parse_serve_url

describe('parse_serve_url', function()
  it('extracts URL from dirsv startup line', function()
    assert.are.equal('http://127.0.0.1:8084', parse_serve_url('serving . on http://127.0.0.1:8084'))
  end)

  it('extracts URL with different port', function()
    assert.are.equal('http://127.0.0.1:9123', parse_serve_url('serving /tmp on http://127.0.0.1:9123'))
  end)

  it('extracts URL with localhost hostname', function()
    assert.are.equal('http://localhost:3000', parse_serve_url('serving . on http://localhost:3000'))
  end)

  it('returns nil for unrelated line', function()
    assert.is_nil(parse_serve_url('some other output'))
  end)

  it('returns nil for empty string', function()
    assert.is_nil(parse_serve_url(''))
  end)
end)
