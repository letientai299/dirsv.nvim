local find_free_port = require('dirsv')._test.find_free_port

describe('find_free_port', function()
  it('returns base port when free', function()
    local port = find_free_port(19800)
    assert.are.equal(19800, port)
  end)

  it('skips occupied port', function()
    local blocker = vim.uv.new_tcp()
    blocker:bind('127.0.0.1', 19900)
    blocker:listen(1, function() end)

    local port = find_free_port(19900)
    assert.are_not.equal(19900, port)
    assert.is_true(port > 19900 and port <= 19999)

    blocker:close()
  end)
end)
