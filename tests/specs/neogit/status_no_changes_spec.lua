-- The "No changes" placeholder: a clean worktree renders an explicit marker
-- in the file-sections slot instead of the untracked/unstaged/staged sections
-- silently vanishing. Any file change replaces the marker, and
-- status.show_no_changes = false restores the old empty look.
local neogit = require("neogit")
local config = require("neogit.config")
local Repo = require("neogit.lib.git.repository")
local status_buf = require("neogit.buffers.status")

local function run(dir, ...)
  local r = vim.system({ "git", "-C", dir, ... }):wait()
  assert(r.code == 0, tostring(r.stderr))
end

-- A repository with one commit and a completely clean worktree.
local function clean_workdir()
  local dir = vim.fn.tempname()
  vim.uv.fs_mkdir(dir, 493)

  run(dir, "init", "-q", "-b", "main")
  run(dir, "config", "user.email", "t@t")
  run(dir, "config", "user.name", "t")

  local path = dir .. "/tracked.txt"
  vim.fn.writefile({ "one" }, path)
  run(dir, "add", "tracked.txt")
  run(dir, "commit", "-qm", "init")

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

neogit.setup { filewatcher = { enabled = false }, disable_context_highlighting = true }

describe("status buffer no-changes placeholder", function()
  after_each(function()
    config.values.status.show_no_changes = true
    vim.cmd("silent! %bwipeout!")
  end)

  it("shows a No changes placeholder on a clean worktree", function()
    local dir = clean_workdir()
    local buf = open_status(dir)

    assert.truthy(buffer_contains(buf, "No changes"), "clean worktree must render the placeholder")

    -- No file sections may render alongside the placeholder.
    assert.falsy(buffer_contains(buf, "Untracked files"))
    assert.falsy(buffer_contains(buf, "Unstaged changes"))
    assert.falsy(buffer_contains(buf, "Staged changes"))
  end)

  it("replaces the placeholder once a change appears", function()
    local dir = clean_workdir()
    local buf = open_status(dir)
    assert.truthy(buffer_contains(buf, "No changes"))

    vim.fn.writefile({ "new" }, dir .. "/untracked.txt")
    buf:dispatch_refresh()
    assert.truthy(wait_refreshed(), "refresh after change did not complete")
    vim.wait(50)

    assert.falsy(buffer_contains(buf, "No changes"), "placeholder must disappear when files change")
    assert.truthy(buffer_contains(buf, "Untracked files"), "untracked section must render instead")
  end)

  it("restores the placeholder after the last change is gone", function()
    local dir = clean_workdir()
    vim.fn.writefile({ "new" }, dir .. "/untracked.txt")
    local buf = open_status(dir)
    assert.falsy(buffer_contains(buf, "No changes"))

    run(dir, "clean", "-qfd")
    buf:dispatch_refresh()
    assert.truthy(wait_refreshed(), "refresh after clean did not complete")
    vim.wait(50)

    assert.truthy(buffer_contains(buf, "No changes"), "placeholder must return on a clean worktree")
  end)

  it("honors status.show_no_changes = false", function()
    config.values.status.show_no_changes = false
    local dir = clean_workdir()
    local buf = open_status(dir)

    assert.falsy(buffer_contains(buf, "No changes"), "the placeholder must respect the config switch")
  end)
end)
