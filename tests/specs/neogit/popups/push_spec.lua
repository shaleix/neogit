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

---Fixture where the push cannot succeed: a peer moved the remote ahead
---while the local side has its own diverging commit.
local function workdir_diverged()
  local dir, remote = workdir()

  local function run(...)
    local r = vim.system({ "git", "-C", dir, ... }):wait()
    assert(r.code == 0, tostring(r.stderr))
  end

  local peer = dir .. "-peer"
  vim.system({ "git", "clone", "-q", remote, peer }):wait()
  local function run_peer(...)
    local r = vim.system({ "git", "-C", peer, ... }):wait()
    assert(r.code == 0, tostring(r.stderr))
  end

  run_peer("config", "user.email", "t@t")
  run_peer("config", "user.name", "t")

  -- move the remote ahead by one commit
  local fd = assert(io.open(peer .. "/f.txt", "a"))
  fd:write("peer\n")
  fd:close()
  run_peer("add", "f.txt")
  run_peer("commit", "-qm", "peer")
  run_peer("push", "-q", "origin", "main")

  -- diverge locally from the new remote head
  local fd2 = assert(io.open(dir .. "/f.txt", "a"))
  fd2:write("local\n")
  fd2:close()
  run("add", "f.txt")
  run("commit", "-qm", "local")

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
    assert.truthy(
      vim.wait(15000, function()
        local r = vim.system({ "git", "-C", remote, "log", "-1", "--pretty=%s" }):wait()
        return vim.trim(r.stdout or "") == "second"
      end),
      "push never landed on the remote"
    )

    -- the banner settles into the success state (the async continuation
    -- may resume a tick after the push process itself finishes)
    assert.truthy(
      vim.wait(5000, function()
        return loading.internal.state.result ~= nil
      end),
      "banner must settle after the push"
    )
    assert.truthy(loading.is_active(), "result banner must linger after settling")
    assert.equal("NeogitSpinnerSuccess", loading.internal.state.result.hl)

    -- ... and auto-dismisses after the linger
    assert.truthy(
      vim.wait(5000, function()
        return not loading.is_active()
      end),
      "banner must auto-dismiss"
    )
  end)

  ---Runs the failure assertions once the banner settled: red state, and the
  ---banner text must carry one of git's own wording fragments.
  local function assert_failure_banner(label, expected_patterns)
    local loading = require("neogit.lib.loading")
    assert.truthy(
      vim.wait(20000, function()
        return loading.internal.state.result ~= nil
      end),
      label .. ": banner must settle"
    )
    assert.equal("NeogitSpinnerError", loading.internal.state.result.hl, label .. ": banner must be red")

    local text = loading.internal.settled_text()
    local matched = false
    for _, frag in ipairs(expected_patterns) do
      if text:find(frag, 1, true) then
        matched = true
      end
    end
    assert.truthy(matched, label .. (": banner text must carry git's wording, got %q"):format(text))
  end

  it("settles red with the rejection reason on a non-fast-forward push", function()
    local original_prompt = config.values.prompt_force_push
    config.values.prompt_force_push = false

    local dir, remote = workdir_diverged()
    vim.cmd.cd(dir)
    Repo.instance(dir, { autorefresh = false })

    neogit.action("push", "to_upstream", {})()

    assert_failure_banner(
      "non-fast-forward",
      { "(fetch first)", "failed to push some refs", "Updates were rejected" }
    )

    -- the local commit must NOT have landed on the remote
    local r = vim.system({ "git", "-C", remote, "log", "-1", "--pretty=%s" }):wait()
    assert.equal("peer", vim.trim(r.stdout or ""), "rejected push must not land on the remote")

    config.values.prompt_force_push = original_prompt
  end)

  it("settles red with the hook's wording when pre-receive declines", function()
    -- the push must be otherwise acceptable (fast-forwardable), so the
    -- remote is actually contacted and its hook gets to reject it
    local dir, remote = workdir()
    vim.fn.mkdir(remote .. "/hooks", "p")
    local h = assert(io.open(remote .. "/hooks/pre-receive", "w"))
    h:write("#!/bin/sh\necho 'rejected by policy' >&2\nexit 1\n")
    h:close()
    vim.uv.fs_chmod(remote .. "/hooks/pre-receive", 493)

    vim.cmd.cd(dir)
    Repo.instance(dir, { autorefresh = false })

    neogit.action("push", "to_upstream", {})()

    assert_failure_banner("pre-receive hook", { "pre-receive hook declined", "rejected by policy" })
  end)

  it("settles red with git's fatal wording when the remote is unreachable", function()
    local dir = workdir()
    vim.system({ "git", "-C", dir, "remote", "set-url", "origin", dir .. "/nope.git" }):wait()
    vim.cmd.cd(dir)
    Repo.instance(dir, { autorefresh = false })

    neogit.action("push", "to_upstream", {})()

    assert_failure_banner("unreachable remote", { "fatal:" })
  end)

  it("settles red when the force-push confirmation is declined", function()
    local original_prompt = config.values.prompt_force_push
    config.values.prompt_force_push = true

    local input = require("neogit.lib.input")
    local original_permission = input.get_permission
    local asked = 0
    input.get_permission = function()
      asked = asked + 1
      return false
    end

    local dir = workdir_diverged()
    vim.cmd.cd(dir)
    Repo.instance(dir, { autorefresh = false })

    neogit.action("push", "to_upstream", {})()

    assert_failure_banner(
      "declined force push",
      { "(fetch first)", "failed to push some refs", "Updates were rejected" }
    )
    assert.equal(1, asked, "the force-push prompt must have been offered exactly once")

    input.get_permission = original_permission
    config.values.prompt_force_push = original_prompt
  end)
end)
