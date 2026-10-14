-- G (n_pop_stash): pops the stash under the cursor after confirmation, and
-- does nothing anywhere else. Guards the stash-row resolution contract:
-- stash rows' yankable is the stash OID (ui SectionItemStash), so the ref
-- must come from the selection's item, never get_yankable_under_cursor().
local neogit = require("neogit")
local config = require("neogit.config")
local Repo = require("neogit.lib.git.repository")
local status_buf = require("neogit.buffers.status")
local actions = require("neogit.buffers.status.actions")
local input = require("neogit.lib.input")

local function run(dir, ...)
  local r = vim.system({ "git", "-C", dir, ... }):wait()
  assert(r.code == 0, tostring(r.stderr))
end

local function stash_list(dir)
  local r = vim.system({ "git", "-C", dir, "stash", "list" }):wait()
  return vim.trim(r.stdout or "")
end

local function workdir()
  local dir = vim.fn.tempname()
  vim.uv.fs_mkdir(dir, 493)

  run(dir, "init", "-q", "-b", "main")
  run(dir, "config", "user.email", "t@t")
  run(dir, "config", "user.name", "t")

  local fd = assert(io.open(dir .. "/tracked.txt", "w"))
  fd:write("one\n")
  fd:close()
  local fd0 = assert(io.open(dir .. "/other.txt", "w"))
  fd0:write("aaa\n")
  fd0:close()
  run(dir, "add", "-A")
  run(dir, "commit", "-qm", "init")

  -- stash a change to tracked.txt; the later unstaged change goes to
  -- other.txt so `git stash pop` applies onto a clean-enough tree
  local fd2 = assert(io.open(dir .. "/tracked.txt", "w"))
  fd2:write("one\ntwo\n")
  fd2:close()
  run(dir, "stash", "push", "-qm", "wip thing")

  -- an unstaged change so an Unstaged row exists to test the no-op path
  local fd3 = assert(io.open(dir .. "/other.txt", "a"))
  fd3:write("three\n")
  fd3:close()

  return dir
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
    "refresh did not complete"
  )
  vim.wait(50)
  return buf
end

---Stub the confirmation; record_asked collects the prompts, answer decides
---confirm vs cancel. Returns the restore function.
local function stub_confirm(record_asked, answer)
  local original = input.get_permission
  input.get_permission = function(msg)
    table.insert(record_asked, msg)
    return answer
  end
  return function()
    input.get_permission = original
  end
end

---Capture vim.notify calls; returns the capture table and the restore fn.
local function capture_notify()
  local captured = {}
  local original = vim.notify
  vim.notify = function(msg, level)
    table.insert(captured, { msg = msg, level = level })
  end
  return captured, function()
    vim.notify = original
  end
end

neogit.setup { filewatcher = { enabled = false }, disable_context_highlighting = true }

describe("status stash pop (G)", function()
  it("pops the stash under the cursor after confirmation", function()
    local dir = workdir()
    local buf = open_status(dir)
    buf.buffer:focus()

    local asked = {}
    local restore = stub_confirm(asked, true)

    assert.truthy(vim.fn.search([[\Vstash@{]], "w") > 0, "stash row must render")
    actions.n_pop_stash(buf)()

    local popped = vim.wait(10000, function()
      return stash_list(dir) == ""
    end, 10)
    restore()

    assert.truthy(popped, "stash must be popped; stash list: " .. stash_list(dir))
    assert.equal(1, #asked, "confirmation must be asked exactly once; " .. vim.inspect(asked))
    assert.truthy(
      asked[1] and asked[1]:find("stash@{0}", 1, true),
      "confirmation must name the ref; got: " .. tostring(asked and asked[1])
    )
  end)

  it("cancelling the confirmation leaves the stash in place", function()
    local dir = workdir()
    local buf = open_status(dir)
    buf.buffer:focus()

    local asked = {}
    local restore = stub_confirm(asked, false)

    assert.truthy(vim.fn.search([[\Vstash@{]], "w") > 0, "stash row must render")
    actions.n_pop_stash(buf)()
    vim.wait(300)
    restore()

    assert.equal(1, #asked, "confirmation must be asked exactly once; " .. vim.inspect(asked))
    assert.truthy(stash_list(dir):find("stash@{0}", 1, true), "cancel must leave the stash in place")
  end)

  it("does nothing off a stash row", function()
    local dir = workdir()
    local buf = open_status(dir)
    buf.buffer:focus()

    local asked = {}
    local restore = stub_confirm(asked, true)

    assert.truthy(vim.fn.search([[\Vother.txt]], "w") > 0, "unstaged file row must render")
    actions.n_pop_stash(buf)()
    vim.wait(300)
    restore()

    assert.equal(0, #asked, "no confirmation may be asked off a stash row; " .. vim.inspect(asked))
    assert.truthy(stash_list(dir):find("stash@{0}", 1, true), "stash must survive when off a stash row")
  end)

  it("surfaces git's error and keeps the stash when the pop cannot apply", function()
    local dir = workdir()
    -- dirty the SAME file the stash touches: both apply attempts are refused
    local fd = assert(io.open(dir .. "/tracked.txt", "a"))
    fd:write("conflicting\n")
    fd:close()

    local buf = open_status(dir)
    buf.buffer:focus()

    local restore_confirm = stub_confirm({}, true)
    local captured, restore_notify = capture_notify()

    assert.truthy(vim.fn.search([[\Vstash@{]], "w") > 0, "stash row must render")
    actions.n_pop_stash(buf)()
    vim.wait(2000, function()
      return #captured > 0
    end, 10)
    restore_notify()

    restore_confirm()

    assert.truthy(stash_list(dir):find("stash@{0}", 1, true), "stash must be kept when apply fails")
    local errors = vim.tbl_filter(function(n)
      return n.level == vim.log.levels.ERROR
    end, captured)
    assert.truthy(
      #errors > 0,
      "an ERROR notification must surface the failure; got: " .. vim.inspect(captured)
    )
    assert.truthy(
      vim.inspect(errors):find("would be overwritten", 1, true),
      "the notification must carry git's wording; got: " .. vim.inspect(errors)
    )
  end)

  it("drops the stash when only the --index apply fails", function()
    local dir = workdir()
    -- stage a change to other.txt AFTER the stash: a dirty index refuses
    -- `apply --index` (it restores the full stashed index state) while the
    -- plain apply still succeeds on the clean tracked.txt worktree
    local fd = assert(io.open(dir .. "/other.txt", "a"))
    fd:write("staged-after-stash\n")
    fd:close()
    run(dir, "add", "other.txt")

    local buf = open_status(dir)
    buf.buffer:focus()

    local restore_confirm = stub_confirm({}, true)
    local captured, restore_notify = capture_notify()

    assert.truthy(vim.fn.search([[\Vstash@{]], "w") > 0, "stash row must render")
    actions.n_pop_stash(buf)()

    local popped = vim.wait(10000, function()
      return stash_list(dir) == ""
    end, 10)
    restore_notify()

    restore_confirm()

    assert.truthy(popped, "the fallback apply must pop (and drop) the stash; list: " .. stash_list(dir))

    local f = assert(io.open(dir .. "/tracked.txt", "r"))
    local content = f:read("*a")
    f:close()
    assert.truthy(
      content:find("two", 1, true),
      "the stashed worktree change must be restored; got: " .. vim.inspect(content)
    )

    local errors = vim.tbl_filter(function(n)
      return n.level == vim.log.levels.ERROR
    end, captured)
    assert.equal(
      0,
      #errors,
      "no ERROR notification on the fallback-success path; got: " .. vim.inspect(errors)
    )
  end)
end)
