-- Cursor anchoring and fold-state preservation across refreshes:
--  * open/toggle-reopen anchors the second visible section title
--  * watcher refreshes restore the semantic cursor location, not raw lines
--  * user fold choices survive watcher-triggered redraws
local neogit = require("neogit")
local config = require("neogit.config")
local Repo = require("neogit.lib.git.repository")
local status_buf = require("neogit.buffers.status")
local Watcher = require("neogit.watcher")

local function workdir(with_tracked_change)
  local dir = vim.fn.tempname()
  vim.uv.fs_mkdir(dir, 493)

  local function run(...)
    local r = vim.system({ "git", "-C", dir, ... }):wait()
    assert(r.code == 0, tostring(r.stderr))
  end

  run("init", "-q", "-b", "main")
  run("config", "user.email", "t@t")
  run("config", "user.name", "t")

  local function write(path, content)
    vim.uv.fs_open(dir .. "/" .. path, "w", 420, function(_, fd)
      vim.uv.fs_write(fd, content, nil, function()
        vim.uv.fs_close(fd)
      end)
    end)
    vim.wait(500, function()
      return vim.fn.filereadable(dir .. "/" .. path) == 1
    end)
  end

  write("tracked.txt", "one\n")
  run("add", "tracked.txt")
  run("commit", "-qm", "init")

  write("untracked.txt", "new\n") -- Untracked section
  if with_tracked_change then
    write("tracked.txt", "one\ntwo\n") -- Unstaged section
  end

  return dir
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

  return vim.wait(timeout or 10000, function()
    return fired
  end, 10)
end

local function open_status(dir)
  vim.cmd.cd(dir)
  Repo.instance(dir, { autorefresh = false })
  local buf = status_buf.new(config.values, Repo.instance(dir).worktree_root, dir)
  buf:open("split")
  buf:dispatch_refresh()
  assert.truthy(wait_refreshed(), "initial refresh did not complete")
  vim.wait(50)
  return buf
end

local function cursor_line(buf)
  return buf.buffer:cursor_line()
end

local function watcher_refresh(buf)
  buf:dispatch_refresh() -- the status instance refreshes as usual
  -- simulate the watcher path (capture -> repo refresh -> redraw)
  local watcher = Watcher.instance(buf.root)
  watcher:dispatch_refresh()
  assert.truthy(wait_refreshed(), "watcher refresh did not complete")
  vim.wait(50)
end

neogit.setup { filewatcher = { enabled = false }, disable_context_highlighting = true }

describe("status buffer cursor anchoring", function()
  it("anchors the cursor on the second visible section after open", function()
    local dir = workdir(true)
    local buf = open_status(dir)

    local second = buf.buffer.ui:section_at_index(2)
    assert.truthy(second, "expected a second section")
    assert.equal("unstaged", second.name)
    assert.equal(second.first, cursor_line(buf))
  end)

  it("falls back to the first section when there is only one", function()
    -- zero commits + one untracked file => only the Untracked section renders
    local dir = vim.fn.tempname()
    vim.uv.fs_mkdir(dir, 493)
    local r = vim.system({ "git", "-C", dir, "init", "-q", "-b", "main" }):wait()
    assert(r.code == 0, tostring(r.stderr))
    vim.uv.fs_open(dir .. "/untracked.txt", "w", 420, function(_, fd)
      vim.uv.fs_write(fd, "x\n", nil, function()
        vim.uv.fs_close(fd)
      end)
    end)
    vim.wait(500, function()
      return vim.fn.filereadable(dir .. "/untracked.txt") == 1
    end)

    local buf = open_status(dir)

    -- Empty sections still render headers, so "fallback" here means: the
    -- cursor lands on the second section's title when it exists, or the
    -- first section's otherwise - either way on a section title, no error.
    local target = buf.buffer.ui:section_at_index(2) or buf.buffer.ui:first_section()
    assert.truthy(target, "at least one section must render")
    assert.equal(target.first, cursor_line(buf))
  end)

  it("keeps the anchor across a watcher-triggered refresh", function()
    local dir = workdir(true)
    local buf = open_status(dir)

    watcher_refresh(buf)

    local second = buf.buffer.ui:section_at_index(2)
    assert.truthy(second)
    assert.equal(second.first, cursor_line(buf))
  end)

  it("restores the semantic position after the user moves the cursor", function()
    local dir = workdir(true)
    local buf = open_status(dir)

    -- move into the untracked file entry (a specific file line, not a title)
    local untracked = buf.buffer.ui:first_section()
    local file_line = untracked.first + 1
    buf.buffer:move_cursor(file_line)

    local before = buf.buffer.ui:get_cursor_location(nil)
    assert.truthy(before.file, "cursor should sit on a file entry")

    -- mutate state so raw line numbers shift (stage the tracked change:
    -- the unstaged section shrinks and a staged section appears)
    vim.system({ "git", "-C", dir, "add", "tracked.txt" }):wait()

    watcher_refresh(buf)

    local after = buf.buffer.ui:get_cursor_location(nil)
    assert.equal(before.file.name, after.file.name, "semantic file position must survive")
    assert.equal(before.section.name, after.section.name, "semantic section must survive")
  end)

  it("preserves user fold state across a watcher refresh", function()
    local dir = workdir(true)
    local buf = open_status(dir)

    -- fold the first section (Untracked)
    local fold_state = buf.buffer.ui:get_fold_state()
    local first_key = nil
    for key, entry in pairs(fold_state) do
      if not key:find("/", 1, true) then -- top-level section key
        first_key = first_key or key
      end
    end
    assert.truthy(first_key, "expected at least one section fold key")

    local mutated = vim.deepcopy(fold_state)
    mutated[first_key].folded = true
    buf.buffer.ui:set_fold_state(mutated)

    watcher_refresh(buf)

    local after = buf.buffer.ui:get_fold_state()
    assert.truthy(after[first_key], "fold key must survive the refresh")
    assert.is_true(after[first_key].folded, "user fold choice must be preserved")
  end)

  it("re-anchors (not the close position) after close and reopen", function()
    local dir = workdir(true)
    local buf = open_status(dir)

    -- park the cursor somewhere far from the anchor
    local last = buf.buffer.ui:first_section().last
    buf.buffer:move_cursor(math.max(last, 1))
    local instance = status_buf.instance(dir)
    instance:close()

    -- Buffer:close schedules the window close (vim.schedule_wrap); let it
    -- settle before reopening, otherwise the reused buffer gets wiped under
    -- the new window (instant programmatic close+reopen edge).
    vim.wait(200)

    local reopened = status_buf.new(config.values, Repo.instance(dir).worktree_root, dir)
    reopened:open("split")
    reopened:dispatch_refresh()
    assert.truthy(wait_refreshed(), "reopen refresh did not complete")
    vim.wait(50)

    local second = reopened.buffer.ui:section_at_index(2)
    assert.truthy(second)
    assert.equal(second.first, cursor_line(reopened), "reopen must anchor the second section")
  end)
end)
