describe('commands', function()
  local child

  local function nvim_cmd(cmd)
    vim.rpcrequest(child, 'nvim_command', cmd)
  end

  local function nvim_eval(expr)
    return vim.rpcrequest(child, 'nvim_eval', expr)
  end

  before_each(function()
    child = vim.fn.jobstart({ 'nvim', '--embed', '--headless', '-u', 'NONE' }, { rpc = true })
    assert.is_true(child > 0, 'failed to start embedded nvim')
    nvim_cmd('set rtp+=' .. vim.fn.getcwd())
    nvim_cmd('runtime plugin/dirsv.lua')
  end)

  after_each(function()
    if child and child > 0 then
      vim.fn.jobstop(child)
    end
  end)

  it(':Dirsv exists globally', function()
    nvim_cmd('enew')
    local exists = nvim_eval("exists(':Dirsv')")
    assert.are.equal(2, exists)
  end)

  it(':DirsvStop exists globally', function()
    nvim_cmd('enew')
    local exists = nvim_eval("exists(':DirsvStop')")
    assert.are.equal(2, exists)
  end)
end)
