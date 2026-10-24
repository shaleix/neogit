-- Lua port of spec/buffers/git_command_history_buffer_spec.rb (E2E).
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

describe("Git Command History Buffer", function()
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
    nvim:keys("$")
    assert.equals(0, #nvim:errors(), vim.inspect(nvim:errors()))
    assert.equals("NeogitGitCommandHistory", nvim:filetype())
  end)
end)
