-- Lua port of spec/buffers/reflog_buffer_spec.rb (E2E).
local child_nvim = require("tests.util.child_nvim")
local e2e = require("tests.util.e2e")

local nvim
local workdir

local function boot(config)
  if nvim then
    nvim:teardown()
  end
  workdir = e2e.repo()
  nvim = child_nvim.new()
  nvim:setup(workdir, config)
end

describe("Reflog Buffer", function()
  before_each(function()
    boot()
  end)

  after_each(function()
    if nvim then
      nvim:teardown()
      nvim = nil
    end
  end)

  it("renders for current, raising no errors", function()
    nvim:keys("lr")
    assert.equals(0, #nvim:errors(), vim.inspect(nvim:errors()))
    assert.equals("NeogitReflogView", nvim:filetype())
  end)

  it("renders for HEAD, raising no errors", function()
    nvim:keys("lH")
    assert.equals(0, #nvim:errors(), vim.inspect(nvim:errors()))
    assert.equals("NeogitReflogView", nvim:filetype())
  end)

  it("renders for Other, raising no errors", function()
    nvim:keys("lO<cr>")
    assert.equals(0, #nvim:errors(), vim.inspect(nvim:errors()))
    assert.equals("NeogitReflogView", nvim:filetype())
  end)

  it("can open CommitView", function()
    nvim:keys("lr<enter>")
    assert.equals(0, #nvim:errors(), vim.inspect(nvim:errors()))
    assert.equals("NeogitCommitView", nvim:filetype())
  end)
end)
