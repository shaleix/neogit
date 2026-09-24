-- Runtime backend degradation (migration spec §7): a libgit2 twin that
-- fails mid-session must not empty or abort the refresh - Repo:tasks logs
-- the failure (traceback, forced file logging, one-time notification) and
-- re-runs the module on the CLI backend. Query dispatchers must fall back
-- to the CLI when a twin cannot serve. Skip-friendly when no usable
-- libgit2 is present.
local git2 = require("neogit.lib.git2")
local backend = require("neogit.lib.git.backend")
local config = require("neogit.config")
local logger = require("neogit.logger")

local function workdir()
  local dir = vim.fn.tempname()
  vim.uv.fs_mkdir(dir, 493)
  local function run(...)
    local r = vim.system({ ... }, { cwd = dir }):wait()
    assert(r.code == 0, r.stderr)
  end

  run("git", "init", "-q", "-b", "main")
  run("git", "config", "user.email", "t@t")
  run("git", "config", "user.name", "Tester")

  local fd = assert(io.open(dir .. "/tracked.txt", "w"))
  fd:write("one\n")
  fd:close()
  run("git", "add", "tracked.txt")
  run("git", "commit", "-qm", "init")
  run("git", "branch", "feature/x")

  fd = assert(io.open(dir .. "/tracked.txt", "a"))
  fd:write("two\n")
  fd:close()

  return dir
end

describe("backend runtime degradation", function()
  local probe_ok = git2.probe().available
  local dir
  local original_git
  local original_use_file

  before_each(function()
    dir = workdir()
    vim.cmd.cd(dir)
    original_git = config.values.git_executable
    original_use_file = logger.config.use_file
  end)

  after_each(function()
    config.values.git_backend = "auto"
    config.values.git_executable = original_git
    logger.config.use_file = original_use_file
    backend.reset()
  end)

  it("falls back to the CLI and logs when a refresh twin raises", function()
    if not probe_ok then
      return
    end

    config.values.git_backend = "libgit2"
    backend.reset()
    assert.equal("libgit2", backend.current())

    local Repo = require("neogit.lib.git.repository")
    local repo = Repo.instance(dir, { autorefresh = false })
    local original_twin = repo.libgit2_updates.update_status
    assert.truthy(original_twin, "update_status twin must be registered under libgit2")

    -- capture the degradation signals
    local errors_logged = {}
    local original_error = logger.error
    logger.error = function(msg)
      table.insert(errors_logged, tostring(msg))
    end

    local notified = 0
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      if tostring(msg):find("update_status", 1, true) then
        notified = notified + 1
        assert.equal(vim.log.levels.WARN, level)
      end
    end

    repo.libgit2_updates.update_status = function()
      error("injected twin failure")
    end

    local ok, err = pcall(function()
      local task = repo:dispatch_refresh { source = "degrade-spec" }
      assert.truthy(task:wait(10000), "refresh must complete despite the failing twin")
    end)

    logger.error = original_error
    vim.notify = original_notify
    repo.libgit2_updates.update_status = original_twin

    assert.truthy(ok, "refresh must not propagate the twin failure: " .. tostring(err))

    -- the notification is delivered via vim.schedule: let it land
    vim.wait(500, function()
      return notified >= 1
    end)

    -- the CLI backend served the module: the modified file is present
    local found = false
    for _, item in ipairs(repo.state.unstaged.items) do
      if item.name == "tracked.txt" then
        found = true
      end
    end
    assert.truthy(found, "CLI fallback must have filled unstaged items")

    -- the failure was recorded for post-mortem analysis: ERROR level,
    -- message and traceback in one entry
    local recorded = false
    for _, msg in ipairs(errors_logged) do
      if msg:find("update_status", 1, true) and msg:find("injected twin failure", 1, true) then
        recorded = true
        assert.truthy(msg:find("stack traceback", 1, true), "error log must carry the traceback")
      end
    end
    assert.truthy(recorded, "twin failure must be logged at ERROR with the message")

    -- long-running diagnostics: file logging was forced on and the user
    -- was notified once
    assert.equal(true, logger.config.use_file)
    assert.equal(1, notified)
  end)

  it("keeps an explicit refs.list sortby on the CLI (the twin ignores it)", function()
    if not probe_ok then
      return
    end

    config.values.git_backend = "libgit2"
    backend.reset()
    assert.equal("libgit2", backend.current())

    -- logging git wrapper: records every CLI invocation
    local log = vim.fn.tempname()
    local wrapper = vim.fn.tempname()
    local fd = assert(io.open(wrapper, "w"))
    fd:write(([[
#!/bin/sh
echo "$@" >> %s
exec %s "$@"
]]):format(log, vim.fn.exepath("git")))
    fd:close()
    vim.fn.setfperm(wrapper, "rwxr-xr-x")
    config.values.git_executable = wrapper

    local Repo = require("neogit.lib.git.repository")
    Repo.instance(dir, { autorefresh = false })
    local git = require("neogit.lib.git")

    local function count_for_each_ref()
      local f = io.open(log, "r")
      if not f then
        return 0
      end

      local n = 0
      for line in f:lines() do
        if line:find("for-each-ref", 1, true) then
          n = n + 1
        end
      end
      f:close()
      return n
    end

    -- default listing: served by the twin, zero spawns
    local names = git.refs.list { "^refs/heads/" }
    assert.truthy(vim.tbl_contains(names, "main"), "twin listing must return main")
    assert.equal(0, count_for_each_ref(), "twin path must not spawn for-each-ref")

    -- explicit sortby: must stay on the CLI (the twin cannot honor it)
    local sorted = git.refs.list({ "^refs/heads/" }, nil, "refname")
    assert.truthy(vim.tbl_contains(sorted, "feature/x"), "CLI listing must return feature/x")
    assert.equal(1, count_for_each_ref(), "explicit sortby must spawn for-each-ref exactly once")
  end)
end)
