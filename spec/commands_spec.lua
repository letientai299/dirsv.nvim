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

  it(':MarkdownPreview exists in markdown buffer', function()
    nvim_cmd('enew')
    nvim_cmd('setfiletype markdown')
    local exists = nvim_eval("exists(':MarkdownPreview')")
    assert.are.equal(2, exists)
  end)

  it(':MarkdownPreview does not exist in lua buffer', function()
    nvim_cmd('enew')
    nvim_cmd('setfiletype lua')
    local exists = nvim_eval("exists(':MarkdownPreview')")
    assert.are.equal(0, exists)
  end)

  it(':MarkdownPreviewStop exists in markdown buffer', function()
    nvim_cmd('enew')
    nvim_cmd('setfiletype markdown')
    local exists = nvim_eval("exists(':MarkdownPreviewStop')")
    assert.are.equal(2, exists)
  end)
end)
