-- Rebase actions surface the bottom loading banner like pull/push: shows
-- while rebasing, settles green on success, red when the rebase stops on
-- conflicts, and auto-dismisses. Editor-opening rebase paths (interactive,
-- edit_todo) must NOT show the banner.
local neogit = require("neogit")
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
  fd:write("one\ntwo\nthree\n")
  fd:close()
  run("add", "f.txt")
  run("commit", "-qm", "init")

  -- bare remote as origin with upstream tracking
  local remote = dir .. "-origin.git"
  run("init", "-q", "--bare", "-b", "main", remote)
  run("remote", "add", "origin", remote)
  run("push", "-q", "-u", "origin", "main")

  -- a second clone pushes a commit so the workdir has something to rebase onto
  local peer = dir .. "-peer"
  vim.system({ "git", "clone", "-q", remote, peer }):wait()
  local function run_peer(...)
    local r = vim.system({ "git", "-C", peer, ... }):wait()
    assert(r.code == 0, tostring(r.stderr))
  end

  run_peer("config", "user.email", "t@t")
  run_peer("config", "user.name", "t")

  -- change the SAME line the local side will touch, to force a conflict
  local fd2 = assert(io.open(peer .. "/f.txt", "w"))
  fd2:write("one\nremote\nthree\n")
  fd2:close()
  run_peer("add", "f.txt")
  run_peer("commit", "-qm", "second")
  run_peer("push", "-q", "origin", "main")

  -- rebase targets the remote-tracking ref: fetch so origin/main is current
  run("fetch", "-q", "origin")

  return dir
end

local function last_subject(dir)
  local r = vim.system({ "git", "-C", dir, "log", "-1", "--pretty=%s" }):wait()
  return vim.trim(r.stdout or "")
end

neogit.setup { filewatcher = { enabled = false }, disable_context_highlighting = true }

describe("rebase loading banner", function()
  local loading = require("neogit.lib.loading")

  after_each(function()
    loading.close()
  end)

  it("shows the banner and settles green after a successful rebase onto upstream", function()
    local dir = workdir()
    vim.cmd.cd(dir)
    Repo.instance(dir, { autorefresh = false })

    assert.is_not_true(loading.is_active())

    neogit.action("rebase", "onto_upstream", {})()

    -- the rebased commit lands locally (fast-forward: local is behind)
    assert.truthy(
      vim.wait(15000, function()
        return last_subject(dir) == "second"
      end),
      "rebase never landed locally; last subject: " .. last_subject(dir)
    )

    assert.truthy(
      vim.wait(5000, function()
        return loading.internal.state.result ~= nil
      end),
      "banner must settle after the rebase"
    )
    assert.truthy(loading.is_active(), "result banner must linger after settling")
    assert.equal("NeogitSpinnerSuccess", loading.internal.state.result.hl)
    assert.truthy(
      loading.internal.settled_text():find("Rebased onto 'origin/main'", 1, true) ~= nil,
      ("banner text must report the rebase: %q"):format(loading.internal.settled_text())
    )

    assert.truthy(
      vim.wait(5000, function()
        return not loading.is_active()
      end),
      "banner must auto-dismiss"
    )
  end)

  it("settles red when the rebase stops on conflicts", function()
    local dir = workdir()

    -- diverge locally: touch the SAME line the remote changed
    local fd = assert(io.open(dir .. "/f.txt", "w"))
    fd:write("one\nlocal\nthree\n")
    fd:close()
    vim.system({ "git", "-C", dir, "add", "f.txt" }):wait()
    vim
      .system({ "git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "local" })
      :wait()

    vim.cmd.cd(dir)
    Repo.instance(dir, { autorefresh = false })

    neogit.action("rebase", "onto_upstream", {})()

    assert.truthy(
      vim.wait(15000, function()
        return loading.internal.state.result ~= nil
      end),
      "banner must settle after the conflicted rebase"
    )
    assert.equal("NeogitSpinnerError", loading.internal.state.result.hl)
    assert.truthy(
      loading.internal.settled_text():find("stopped", 1, true) ~= nil,
      ("banner text must report the stop: %q"):format(loading.internal.settled_text())
    )
  end)
end)
