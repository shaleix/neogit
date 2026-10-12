-- Background auto-fetch: opening the status buffer fetches from the remote
-- in the background, so the Head line's ↓N behind counter reflects an
-- advanced remote without a manual fetch. A fetch that moves the upstream
-- ref triggers one refresh; the fetch never pulls/merges anything.
local neogit = require("neogit")
local config = require("neogit.config")
local backend = require("neogit.lib.git.backend")
local Repo = require("neogit.lib.git.repository")
local status_buf = require("neogit.buffers.status")

local function run(dir, ...)
  local r = vim.system({ "git", "-C", dir, ... }):wait()
  assert(r.code == 0, tostring(r.stderr))
end

local function write(dir, path, content)
  local fd = assert(io.open(dir .. "/" .. path, "w"))
  fd:write(content)
  fd:close()
end

local function rev_parse(dir, rev)
  local r = vim.system({ "git", "-C", dir, "rev-parse", rev }, { text = true }):wait()
  assert(r.code == 0, tostring(r.stderr))
  return vim.trim(r.stdout or "")
end

---Bare origin advanced by two commits ("remote1", "remote2") after the
---target repo was cloned at "base" and NEVER fetched again. Ground truth
---(server-side): origin/main is 2 commits ahead of the target's HEAD.
local function diverged_dir()
  local dir = vim.fn.tempname()
  vim.uv.fs_mkdir(dir, 493)

  local origin = dir .. "-origin.git"
  run(dir, "init", "-q", "--bare", "-b", "main", origin)

  -- clone1 pushes base
  local remote1 = dir .. "-remote1"
  run(dir, "clone", "-q", origin, remote1)
  run(remote1, "config", "user.email", "t@t")
  run(remote1, "config", "user.name", "t")
  write(remote1, "base.txt", "base\n")
  run(remote1, "add", "-A")
  run(remote1, "commit", "-q", "-m", "base")
  run(remote1, "push", "-q", "-u", "origin", "main")

  -- the repo under test: cloned at base, never fetched after
  local target = dir .. "-target"
  run(dir, "clone", "-q", origin, target)
  run(target, "config", "user.email", "t@t")
  run(target, "config", "user.name", "t")

  -- advance origin by two commits (remote1 from clone1, remote2 from clone2)
  write(remote1, "r1.txt", "r1\n")
  run(remote1, "add", "-A")
  run(remote1, "commit", "-q", "-m", "remote1")
  run(remote1, "push", "-q")

  local remote2 = dir .. "-remote2"
  run(dir, "clone", "-q", origin, remote2)
  run(remote2, "config", "user.email", "t@t")
  run(remote2, "config", "user.name", "t")
  write(remote2, "r2.txt", "r2\n")
  run(remote2, "add", "-A")
  run(remote2, "commit", "-q", "-m", "remote2")
  run(remote2, "push", "-q")

  -- server-side ground truth: origin/main is 2 commits ahead of the target,
  -- while the target's local origin/main ref is still at base (never fetched)
  local target_head = rev_parse(target, "HEAD")
  local r = vim
    .system({
      "git",
      "-C",
      origin,
      "rev-list",
      "--count",
      "main",
      "^" .. target_head,
    }, { text = true })
    :wait()
  assert(r.code == 0, tostring(r.stderr))
  assert.equal("2", vim.trim(r.stdout or ""), "origin/main must be 2 commits ahead of the target")

  return target
end

local function buffer_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf.buffer.handle, 0, -1, false), "\n")
end

local function open_status(dir)
  vim.cmd.cd(dir)
  Repo.instance(dir, { autorefresh = false })
  local buf = status_buf.new(config.values, Repo.instance(dir).worktree_root, dir)
  buf:open("split")
  local fired = false
  vim.api.nvim_create_autocmd("User", {
    pattern = "NeogitStatusRefreshed",
    once = true,
    callback = function()
      fired = true
    end,
  })
  buf:dispatch_refresh()
  assert.truthy(
    vim.wait(10000, function()
      return fired
    end, 10),
    "initial refresh did not complete"
  )
  vim.wait(50)
  return buf
end

---Wait for the auto-fetch to land and the post-fetch refresh to re-render
---the Head line with the behind counter.
local function wait_for_behind(buf, count)
  assert.truthy(
    vim.wait(15000, function()
      return buffer_text(buf):find("↓" .. count, 1, true) ~= nil
    end, 50),
    "Head line must show ↓" .. count .. " after the auto fetch:\n" .. buffer_text(buf)
  )
end

---Number of plain `git fetch` executions recorded by the process runner
---(the builder prepends the executable and -c flags, so the subcommand is
---matched as the trailing word of the command line).
local function fetch_count()
  local n = 0
  for _, job in ipairs(require("neogit.runner").history) do
    if job.cmd and job.cmd:match(" fetch$") then
      n = n + 1
    end
  end
  return n
end

neogit.setup { filewatcher = { enabled = false }, disable_context_highlighting = true }

describe("background auto-fetch", function()
  local saved_backend

  before_each(function()
    saved_backend = config.values.git_backend
    config.values.auto_fetch = { enabled = true }
  end)

  after_each(function()
    config.values.git_backend = saved_backend
    backend.reset()
    config.values.auto_fetch = nil
  end)

  local function behind_test()
    local dir = diverged_dir()
    local base_oid = rev_parse(dir, "HEAD")
    local buf = open_status(dir)
    wait_for_behind(buf, 2)

    -- the fetch was real: the local upstream ref moved
    assert.not_equal(base_oid, rev_parse(dir, "@{upstream}"), "upstream ref must have moved")
  end

  it("shows behind after opening the status buffer without a manual fetch (cli backend)", function()
    config.values.git_backend = "cli"
    backend.reset()
    behind_test()
  end)

  it("shows behind after opening the status buffer without a manual fetch (libgit2 backend)", function()
    config.values.git_backend = "libgit2"
    backend.reset()
    behind_test()
  end)

  it("fails silently when the remote is unreachable", function()
    config.values.git_backend = "cli"
    backend.reset()

    local dir = diverged_dir()
    run(dir, "remote", "set-url", "origin", "/nonexistent/neogit-test-remote")

    local autofetch = require("neogit.lib.git.autofetch")
    local buf = open_status(dir)

    -- the fetch fails fast (GIT_TERMINAL_PROMPT=0); nothing surfaces to the
    -- user and the single-flight flag clears
    assert.truthy(
      vim.wait(10000, function()
        return not autofetch.is_fetching()
      end, 20),
      "in-flight flag must clear after a failed fetch"
    )
    assert.truthy(
      buffer_text(buf):find("main", 1, true),
      "status must render normally:\n" .. buffer_text(buf)
    )
  end)

  it("skips cleanly when no remote is configured", function()
    config.values.git_backend = "cli"
    backend.reset()

    local dir = vim.fn.tempname()
    vim.uv.fs_mkdir(dir, 493)
    run(dir, "init", "-q", "-b", "main")
    run(dir, "config", "user.email", "t@t")
    run(dir, "config", "user.name", "t")
    write(dir, "a.txt", "one\n")
    run(dir, "add", "-A")
    run(dir, "commit", "-q", "-m", "base")

    local autofetch = require("neogit.lib.git.autofetch")
    local before = fetch_count()
    local buf = open_status(dir)

    assert.truthy(
      vim.wait(5000, function()
        return not autofetch.is_fetching()
      end, 20),
      "in-flight flag must clear after skipping"
    )
    assert.equal(before, fetch_count(), "no fetch may run without a remote")
    assert.truthy(
      buffer_text(buf):find("main", 1, true),
      "status must render normally:\n" .. buffer_text(buf)
    )
  end)

  it("skips a second trigger while a fetch is in flight", function()
    config.values.git_backend = "cli"
    backend.reset()

    local dir = diverged_dir()
    local autofetch = require("neogit.lib.git.autofetch")
    local buf = open_status(dir)

    -- let the open-triggered fetch settle
    assert.truthy(
      vim.wait(10000, function()
        return not autofetch.is_fetching()
      end, 20),
      "open-triggered fetch must settle"
    )

    local before = fetch_count()
    autofetch.trigger(buf)
    assert.truthy(autofetch.is_fetching(), "the first trigger must mark the fetch in flight")
    autofetch.trigger(buf) -- must be skipped, not queued

    assert.truthy(
      vim.wait(10000, function()
        return not autofetch.is_fetching()
      end, 20),
      "fetch must settle"
    )
    assert.equal(before + 1, fetch_count(), "two triggers while one is in flight must run exactly one fetch")
  end)
end)
