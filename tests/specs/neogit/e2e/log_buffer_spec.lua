-- Lua port of spec/buffers/log_buffer_spec.rb (E2E).
--
-- Parity note: rspec's nvim.screen[1] is 0-based; this harness is
-- 1-based, so row 0 in ruby is screen()[2] here.
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

describe("Log Buffer", function()
  before_each(function()
    boot()
  end)

  after_each(function()
    if nvim then
      nvim:teardown()
      nvim = nil
    end
  end)

  it("renders current, raising no errors", function()
    nvim:keys("ll")
    assert.equals(0, #nvim:errors(), vim.inspect(nvim:errors()))
    assert.equals("NeogitLogView", nvim:filetype())
    assert.equals("Commits in master", vim.trim(nvim:screen()[2]))
  end)

  it("renders HEAD, raising no errors", function()
    nvim:keys("lh")
    assert.equals(0, #nvim:errors(), vim.inspect(nvim:errors()))
    assert.equals("NeogitLogView", nvim:filetype())
    assert.equals("Commits in HEAD", vim.trim(nvim:screen()[2]))
  end)

  it("renders related, raising no errors", function()
    nvim:keys("lu")
    assert.equals(0, #nvim:errors(), vim.inspect(nvim:errors()))
    assert.equals("NeogitLogView", nvim:filetype())
    assert.equals("Commits in master", vim.trim(nvim:screen()[2]))
  end)

  it("renders other, raising no errors", function()
    nvim:keys("lo<cr>")
    assert.equals(0, #nvim:errors(), vim.inspect(nvim:errors()))
    assert.equals("NeogitLogView", nvim:filetype())
    assert.equals("Commits in master", vim.trim(nvim:screen()[2]))
  end)

  it("renders local branches, raising no errors", function()
    nvim:keys("lL")
    assert.equals(0, #nvim:errors(), vim.inspect(nvim:errors()))
    assert.equals("NeogitLogView", nvim:filetype())
    assert.equals("Commits in --branches", vim.trim(nvim:screen()[2]))
  end)

  it("renders all branches, raising no errors", function()
    nvim:keys("lb")
    assert.equals(0, #nvim:errors(), vim.inspect(nvim:errors()))
    assert.equals("NeogitLogView", nvim:filetype())
    assert.equals("Commits in --branches --remotes", vim.trim(nvim:screen()[2]))
  end)

  it("renders all references, raising no errors", function()
    nvim:keys("la")
    assert.equals(0, #nvim:errors(), vim.inspect(nvim:errors()))
    assert.equals("NeogitLogView", nvim:filetype())
    assert.equals("Commits in --all", vim.trim(nvim:screen()[2]))
  end)

  it("can open CommitView", function()
    nvim:keys("ll<enter>")
    assert.equals(0, #nvim:errors(), vim.inspect(nvim:errors()))
    assert.equals("NeogitCommitView", nvim:filetype())
  end)
end)
