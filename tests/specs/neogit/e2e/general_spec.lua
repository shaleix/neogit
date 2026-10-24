-- Lua port of spec/general_spec.rb (E2E: every popup opens standalone).
-- Reference baseline (rspec, cli backend): 21/21 passing.
local child_nvim = require("tests.util.child_nvim")
local e2e = require("tests.util.e2e")

describe("general things", function()
  local nvim

  local popups = {
    "bisect",
    "branch",
    "branch_config",
    "cherry_pick",
    "commit",
    "diff",
    "fetch",
    "help",
    "ignore",
    "log",
    "merge",
    "pull",
    "push",
    "rebase",
    "remote",
    "remote_config",
    "reset",
    "revert",
    "stash",
    "tag",
    "worktree",
  }

  after_each(function()
    if nvim then
      nvim:teardown()
      nvim = nil
    end
  end)

  for _, popup in ipairs(popups) do
    it(("can invoke %s popup without status buffer"):format(popup), function()
      local workdir = e2e.repo { remote_origin = true }
      nvim = child_nvim.new()
      nvim:setup(workdir)

      nvim:keys("q")
      nvim:lua(("require('neogit').open({ '%s' })"):format(popup))
      vim.wait(100) -- Allow popup to open

      assert.equals("NeogitPopup", nvim:filetype())
      assert.equals(0, #nvim:errors(), vim.inspect(nvim:errors()))
    end)
  end
end)
