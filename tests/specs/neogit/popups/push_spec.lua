-- Push actions surface the bottom loading banner: shows while pushing,
-- settles green on success, and auto-dismisses.
local neogit = require("neogit")
local config = require("neogit.config")
local Repo = require("neogit.lib.git.repository")

local function workdir()
  local dir = vim.fn.tempname()
  vim.uv.fs_mkdir(dir, 493)
  local function run(...)
    local r = vim.system({ "git", "-C", dir, ... }):wait()
    assert(r.code == 0, tostring(r.stderr))
  end

  run("init", "-q", "-b", "main")
  run("config", "user.email", "t@t")
  run("config", "user.name", "t")

  local fd = assert(io.open(dir .. "/f.txt", "w"))
  fd:write("one\n")
  fd:close()
  run("add", "f.txt")
  run("commit", "-qm", "init")

  -- bare remote as origin with upstream tracking
  local remote = dir .. "-origin.git"
  run("init", "-q", "--bare", "-b", "main", remote)
  run("remote", "add", "origin", remote)
  run("push", "-q", "-u", "origin", "main")

  -- local-only commit to push
  local fd2 = assert(io.open(dir .. "/f.txt", "a"))
  fd2:write("two\n")
  fd2:close()
  run("add", "f.txt")
  run("commit", "-qm", "second")

  return dir, remote
end

neogit.setup { filewatcher = { enabled = false }, disable_context_highlighting = true }

describe("push loading banner", function()
  after_each(function()
    require("neogit.lib.loading").close()
  end)

  it("shows the banner and settles green after a successful push", function()
    local dir, remote = workdir()
    vim.cmd.cd(dir)
    Repo.instance(dir, { autorefresh = false })

    local loading = require("neogit.lib.loading")
    assert.is_not_true(loading.is_active())

    neogit.action("push", "to_upstream", {})()

    -- push lands on the remote
    assert.truthy(vim.wait(15000, function()
      local r = vim.system({ "git", "-C", remote, "log", "-1", "--pretty=%s" }):wait()
      return vim.trim(r.stdout or "") == "second"
    end), "push never landed on the remote")

    -- the banner settles into the success state (the async continuation
    -- may resume a tick after the push process itself finishes)
    assert.truthy(vim.wait(5000, function()
      return loading.internal.state.result ~= nil
    end), "banner must settle after the push")
    assert.truthy(loading.is_active(), "result banner must linger after settling")
    assert.equal("NeogitSpinnerSuccess", loading.internal.state.result.hl)

    -- ... and auto-dismisses after the linger
    assert.truthy(vim.wait(5000, function()
      return not loading.is_active()
    end), "banner must auto-dismiss")
  end)
end)
