-- Pull actions surface the bottom loading banner: shows while pulling,
-- settles green on success, red on failure, and auto-dismisses.
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
  fd:write("one\n")
  fd:close()
  run("add", "f.txt")
  run("commit", "-qm", "init")

  -- bare remote as origin with upstream tracking
  local remote = dir .. "-origin.git"
  run("init", "-q", "--bare", "-b", "main", remote)
  run("remote", "add", "origin", remote)
  run("push", "-q", "-u", "origin", "main")

  -- a second clone pushes a commit to the remote so the workdir has
  -- something to pull
  local peer = dir .. "-peer"
  vim.system({ "git", "clone", "-q", remote, peer }):wait()
  local function run_peer(...)
    local r = vim.system({ "git", "-C", peer, ... }):wait()
    assert(r.code == 0, tostring(r.stderr))
  end

  run_peer("config", "user.email", "t@t")
  run_peer("config", "user.name", "t")

  local fd2 = assert(io.open(peer .. "/f.txt", "a"))
  fd2:write("two\n")
  fd2:close()
  run_peer("add", "f.txt")
  run_peer("commit", "-qm", "second")
  run_peer("push", "-q", "origin", "main")

  return dir
end

neogit.setup { filewatcher = { enabled = false }, disable_context_highlighting = true }

describe("pull loading banner", function()
  local loading = require("neogit.lib.loading")

  after_each(function()
    loading.close()
  end)

  it("shows the banner and settles green after a successful pull", function()
    local dir = workdir()
    vim.cmd.cd(dir)
    Repo.instance(dir, { autorefresh = false })

    assert.is_not_true(loading.is_active())

    neogit.action("pull", "from_upstream", {})()

    -- the pulled commit lands locally
    assert.truthy(
      vim.wait(15000, function()
        local r = vim.system({ "git", "-C", dir, "log", "-1", "--pretty=%s" }):wait()
        return vim.trim(r.stdout or "") == "second"
      end),
      "pull never landed locally"
    )

    -- the banner settles into the success state (the async continuation
    -- may resume a tick after the pull process itself finishes)
    assert.truthy(
      vim.wait(5000, function()
        return loading.internal.state.result ~= nil
      end),
      "banner must settle after the pull"
    )
    assert.truthy(loading.is_active(), "result banner must linger after settling")
    assert.equal("NeogitSpinnerSuccess", loading.internal.state.result.hl)
    assert.truthy(
      loading.internal.settled_text():find("Pulled from", 1, true) ~= nil,
      ("banner text must report the pull: %q"):format(loading.internal.settled_text())
    )

    -- ... and auto-dismisses after the linger
    assert.truthy(
      vim.wait(5000, function()
        return not loading.is_active()
      end),
      "banner must auto-dismiss"
    )
  end)

  it("settles red when the pull fails", function()
    local dir = workdir()
    vim.cmd.cd(dir)
    Repo.instance(dir, { autorefresh = false })

    -- point the remote at a nonexistent repository
    vim.system({ "git", "-C", dir, "remote", "set-url", "origin", dir .. "/nope.git" }):wait()

    neogit.action("pull", "from_upstream", {})()

    assert.truthy(
      vim.wait(15000, function()
        return loading.internal.state.result ~= nil
      end),
      "banner must settle after the failed pull"
    )
    assert.equal("NeogitSpinnerError", loading.internal.state.result.hl)
    assert.truthy(
      loading.internal.settled_text():find("Failed to pull from", 1, true) ~= nil,
      ("banner text must report the failure: %q"):format(loading.internal.settled_text())
    )
  end)
end)
