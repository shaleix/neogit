-- Integration spec: cold open starts the fade-in,
-- the first refresh completes it, and the group definitions land back on
-- hl.setup's values.
local neogit = require("neogit")
local config = require("neogit.config")
local Repo = require("neogit.lib.git.repository")
local status_buf = require("neogit.buffers.status")
local transition = require("neogit.lib.banner_transition")
local hl = require("neogit.lib.hl")

local function run(dir, ...)
  local r = vim.system({ "git", "-C", dir, ... }):wait()
  assert(r.code == 0, tostring(r.stderr))
end

local function workdir()
  local dir = vim.fn.tempname()
  vim.uv.fs_mkdir(dir, 493)
  run(dir, "init", "-q", "-b", "main")
  run(dir, "config", "user.email", "t@t")
  run(dir, "config", "user.name", "t")
  vim.fn.writefile({ "one" }, dir .. "/tracked.txt")
  run(dir, "add", "tracked.txt")
  run(dir, "commit", "-qm", "init")
  return dir
end

neogit.setup { filewatcher = { enabled = false }, disable_context_highlighting = true }

describe("cold open integration", function()
  after_each(function()
    vim.cmd("silent! %bwipeout!")
  end)

  it("animates on cold open and finishes on first refresh", function()
    vim.o.termguicolors = true
    local dir = workdir()
    vim.cmd.cd(dir)
    Repo.instance(dir, { autorefresh = false })

    local expected = vim.api.nvim_get_hl(0, { name = "NeogitStatusBanner1" })

    local buf = status_buf.new(config.values, Repo.instance(dir).worktree_root, dir)
    buf:open("split")

    assert.truthy(transition.is_active(), "cold open must start the fade-in")
    -- Loading render leads with the banner.
    local lines = buf.buffer:get_lines(0, -1, false)
    assert.truthy(lines[1]:find("╔╗ ╦ ╔═╗", 1, true), "banner tops the loading render")
    local loading_line = nil
    for i, line in ipairs(lines) do
      if line:find("Loading repository state", 1, true) then
        loading_line = i
        break
      end
    end
    assert.truthy(loading_line and loading_line > 1, "loading line sits below the banner")

    buf:dispatch_refresh()
    assert.truthy(
      vim.wait(10000, function()
        return not transition.is_active()
      end, 10),
      "refresh must finish the animation"
    )
    assert.are.same(expected, vim.api.nvim_get_hl(0, { name = "NeogitStatusBanner1" }))
  end)

  it("does not animate on a warm open", function()
    local dir = workdir()
    vim.cmd.cd(dir)
    Repo.instance(dir, { autorefresh = false })
    local buf = status_buf.new(config.values, Repo.instance(dir).worktree_root, dir)
    buf:open("split")
    buf:dispatch_refresh()
    assert.truthy(vim.wait(10000, function()
      return Repo.instance(dir)._refreshed
    end, 10))

    -- Re-open (toggle path focuses; force a fresh window by closing first).
    buf:close()
    local buf2 = status_buf.new(config.values, Repo.instance(dir).worktree_root, dir)
    buf2:open("split")
    assert.falsy(transition.is_active(), "warm open must not start the fade-in")
  end)
end)
