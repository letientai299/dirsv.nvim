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

  it(':Dirsv does not bail on no-name buffer', function()
    nvim_cmd('enew')
    -- Collect notifications to check no "buffer has no file" warning.
    nvim_cmd([[
      lua _G._dirsv_notifs = {}
      vim.notify = function(msg, level)
        table.insert(_G._dirsv_notifs, { msg = msg, level = level })
      end
    ]])
    -- Will fail to spawn dirsv (not in PATH), but should not early-return.
    pcall(nvim_cmd, 'Dirsv')
    local notifs = vim.rpcrequest(child, 'nvim_exec_lua', 'return _G._dirsv_notifs', {})
    for _, n in ipairs(notifs) do
      assert.is_not.match('buffer has no file', n.msg)
    end
  end)
end)
