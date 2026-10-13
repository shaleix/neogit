-- Two-phase optimistic :Neogit open: the status window shows instantly
-- (banner pulse + loading line, ZERO git processes launched synchronously),
-- repository discovery is exactly one async `git rev-parse` batch afterwards,
-- and the buffer ends up indistinguishable from a sync-opened one once the
-- first refresh lands.
local neogit = require("neogit")
local config = require("neogit.config")
local Repo = require("neogit.lib.git.repository")
local status_buf = require("neogit.buffers.status")
local transition = require("neogit.lib.banner_transition")

local function run(dir, ...)
  local r = vim.system({ "git", "-C", dir, ... }):wait()
  assert(r.code == 0, tostring(r.stderr))
end

-- A repository with one commit and one tracked file.
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

-- A plain directory: no .git anywhere.
local function plain_dir()
  local dir = vim.fn.tempname()
  vim.uv.fs_mkdir(dir, 493)
  return dir
end

local function spy_git(fn)
  local real = vim.system
  local calls = {}

  vim.system = function(cmd, opts, on_exit)
    if cmd and cmd[1] == "git" then
      calls[#calls + 1] = table.concat(cmd, " ")
    end
    return real(cmd, opts, on_exit)
  end

  local ok, result = pcall(fn)
  vim.system = real

  assert(ok, result)
  return result, calls
end

local function wait_refreshed(timeout)
  local fired = false
  vim.api.nvim_create_autocmd("User", {
    pattern = "NeogitStatusRefreshed",
    once = true,
    callback = function()
      fired = true
    end,
  })

  return vim.wait(timeout or 15000, function()
    return fired
  end, 10)
end

local function buffer_lines(buf)
  return buf.buffer:get_lines(0, -1, false)
end

local function buffer_contains(buf, needle)
  for _, line in ipairs(buffer_lines(buf)) do
    if line:find(needle, 1, true) then
      return true
    end
  end

  return false
end

local function count(calls, needle)
  local n = 0
  for _, c in ipairs(calls) do
    if c:find(needle, 1, true) then
      n = n + 1
    end
  end
  return n
end

neogit.setup { filewatcher = { enabled = false }, disable_context_highlighting = true }

describe("instant :Neogit open (two-phase)", function()
  after_each(function()
    transition.finish()
    vim.cmd("silent! %bwipeout!")
  end)

  it("opens with zero synchronous git, then binds and refreshes from one async discovery", function()
    -- The pulse guards on termguicolors; headless defaults it off.
    vim.o.termguicolors = true
    local dir = workdir()
    vim.cmd.cd(dir)

    local expected_banner = vim.api.nvim_get_hl(0, { name = "NeogitStatusBanner1" })

    -- Phase 1: open() must return with the buffer visible, the cold render
    -- (banner + loading line) on screen, the pulse running - and not a
    -- single git process launched.
    local buf
    local _, sync_calls = spy_git(function()
      neogit.open { kind = "split" }

      buf = status_buf.instance(dir)
      assert.truthy(buf and buf.buffer and buf.buffer:is_visible(), "status buffer must be visible")
      assert.truthy(
        buffer_lines(buf)[1]:find("╔╗ ╦ ╔═╗", 1, true),
        "banner must top the cold render"
      )
      assert.truthy(buffer_contains(buf, "Loading repository state…"), "loading line must render")
      assert.falsy(buffer_contains(buf, "Recent Commits"), "no file sections while unbound")
      assert.truthy(transition.is_active(), "banner pulse must run while discovery is in flight")
    end)

    assert.equal(
      0,
      #sync_calls,
      "no git process may run synchronously during open(), got: " .. table.concat(sync_calls, "\n")
    )

    -- Phase 2: discovery is exactly one git process, async; the refresh it
    -- triggers lands with real content.
    local _, discovery_calls = spy_git(function()
      assert.truthy(wait_refreshed(), "buffer must refresh after async discovery")
    end)
    assert.equal(
      1,
      count(discovery_calls, "rev-parse --show-toplevel"),
      "discovery must be exactly one metadata batch, got: " .. table.concat(discovery_calls, "\n")
    )

    -- The cache is warm now: no further metadata batches spawn.
    local _, after_calls = spy_git(function()
      vim.wait(50)
    end)
    assert.equal(0, count(after_calls, "rev-parse --show-toplevel"))

    -- Bound, refreshed, indistinguishable from a sync-opened buffer.
    local repo = Repo.instance(dir)
    assert.falsy(repo.provisional, "repo must be bound after discovery")
    assert.equal(dir, repo.worktree_root)
    assert.truthy(repo._refreshed, "repo must be refreshed")
    assert.truthy(buf.buffer and buf.buffer:is_visible(), "buffer must still be visible")
    assert.truthy(buffer_contains(buf, "Recent Commits"), "real content must render")
    assert.falsy(buffer_contains(buf, "Loading repository state…"), "loading line must be gone")
    assert.falsy(transition.is_active(), "pulse must be finished")
    assert.are.same(expected_banner, vim.api.nvim_get_hl(0, { name = "NeogitStatusBanner1" }))
    assert.equal(buf, status_buf.instance(), "the neogit.status singleton must be this buffer")
  end)

  it("declining the init prompt closes the buffer and notifies the error", function()
    local dir = plain_dir()
    vim.cmd.cd(dir)

    local input = require("neogit.lib.input")
    local notification = require("neogit.lib.notification")
    local prompted, notified = nil, nil
    local real_permission, real_error = input.get_permission, notification.error
    input.get_permission = function(msg)
      prompted = msg
      return false
    end
    notification.error = function(msg)
      notified = msg
    end

    neogit.open { kind = "split" }
    -- Discovery runs off the sync path; spin until the prompt was answered
    -- and its consequence landed.
    vim.wait(5000, function()
      return notified ~= nil
    end, 10)

    input.get_permission = real_permission
    notification.error = real_error

    assert.truthy(prompted and prompted:find("Initialize repository", 1, true), "must prompt for init")
    assert.truthy(
      notified and notified:find("not a git repository", 1, true),
      "must notify the not-a-repository error"
    )

    local buf = status_buf.instance(dir)
    assert.falsy(buf and buf.buffer and buf.buffer:is_visible(), "the just-opened buffer must be closed")
    assert.falsy(transition.is_active(), "pulse must be cleaned up with the buffer")
  end)

  it("accepting the init prompt creates the repository and refreshes the buffer", function()
    local dir = plain_dir()
    vim.cmd.cd(dir)

    local input = require("neogit.lib.input")
    local real_permission = input.get_permission
    -- Keep the stub installed until the async flow has used it: the prompt
    -- is answered from a scheduled discovery callback, not synchronously.
    local ok, err = pcall(function()
      input.get_permission = function()
        return true
      end

      neogit.open { kind = "split" }
      assert.truthy(wait_refreshed(), "buffer must refresh after git init + re-discovery")

      local repo = Repo.instance(dir)
      assert.falsy(repo.provisional, "repo must be bound after init")
      assert.equal(dir, repo.worktree_root)
      assert.truthy(repo._refreshed)

      local buf = status_buf.instance(dir)
      assert.truthy(buf.buffer and buf.buffer:is_visible(), "buffer must stay open")
      assert.falsy(buffer_contains(buf, "Loading repository state…"), "loading line must be gone")
      assert.falsy(transition.is_active(), "pulse must be finished")
    end)

    input.get_permission = real_permission
    assert(ok, err)
  end)
end)
