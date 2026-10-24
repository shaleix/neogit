-- Lua port of spec/buffers/refs_buffer_spec.rb (E2E).
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

describe("Refs Buffer", function()
  before_each(function()
    boot()
  end)

  after_each(function()
    if nvim then
      nvim:teardown()
      nvim = nil
    end
  end)

  it("renders, raising no errors", function()
    nvim:keys("y")
    assert.equals(0, #nvim:errors(), vim.inspect(nvim:errors()))
    assert.equals("NeogitRefsView", nvim:filetype())
  end)
end)
