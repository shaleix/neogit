-- Status HEAD lines: upstream divergence counters (↑N ↓M) render on the
-- Merge/Push lines when the branch is ahead/behind its remote, and stay
-- clean when in sync.
local neogit = require("neogit")
local config = require("neogit.config")
local Repo = require("neogit.lib.git.repository")
local status_buf = require("neogit.buffers.status")

local function run(dir, ...)
  local r = vim.system({ "git", "-C", dir, ... }):wait()
  assert(r.code == 0, tostring(r.stderr))
end

local function workdir()
  local dir = vim.fn.tempname()
  vim.uv.fs_mkdir(dir, 493)

  run(dir, "init", "-q", "-b", "main")
  run(dir, "config", "user.email", "t@t")
  run(dir, "config", "user.name", "t")

  local fd = assert(io.open(dir .. "/file.txt", "w"))
  fd:write("one\n")
  fd:close()
  run(dir, "add", "file.txt")
  run(dir, "commit", "-qm", "base")

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

local function buffer_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf.buffer.handle, 0, -1, false), "\n")
end

---Advance `ref` by one commit on top of HEAD~1 (a sibling of the local
---tip): the remote gains one commit the local side lacks, without sharing
---the local-only tip.
local function advance_ref(dir, ref)
  local base = vim.trim(vim.system({ "git", "-C", dir, "rev-parse", "HEAD~1" }):wait().stdout)
  local tree = vim.trim(vim.system({ "git", "-C", dir, "rev-parse", base .. "^{tree}" }):wait().stdout)
  local oid =
    vim.system({ "git", "-C", dir, "commit-tree", tree, "-p", base, "-m", "remote-only" }):wait().stdout
  run(dir, "branch", "-f", ref, vim.trim(oid))
end

neogit.setup { filewatcher = { enabled = false }, disable_context_highlighting = true }

describe("status HEAD divergence counters", function()
  it("shows ↑N ↓M on the Head line when ahead and behind", function()
    local dir = workdir()
    -- local-only commit => ahead
    local fd = assert(io.open(dir .. "/file.txt", "a"))
    fd:write("two\n")
    fd:close()
    run(dir, "add", "file.txt")
    run(dir, "commit", "-qm", "local-only")
    -- local branch as upstream, advanced by one => behind
    run(dir, "branch", "fake-remote")
    run(dir, "branch", "--set-upstream-to=fake-remote")
    advance_ref(dir, "fake-remote")

    local buf = open_status(dir)
    local text = buffer_text(buf)

    local head_line = text:match("[^\n]*Head:[^\n]*")
    assert.truthy(head_line and head_line:find("↑1", 1, true), "Head line must show ↑1:\n" .. text)
    assert.truthy(head_line and head_line:find("↓1", 1, true), "Head line must show ↓1:\n" .. text)
  end)

  it("keeps the counters visible on the Head line when the head block is folded", function()
    local dir = workdir()
    local fd = assert(io.open(dir .. "/file.txt", "a"))
    fd:write("two\n")
    fd:close()
    run(dir, "add", "file.txt")
    run(dir, "commit", "-qm", "local-only")
    run(dir, "branch", "fake-remote")
    run(dir, "branch", "--set-upstream-to=fake-remote")
    advance_ref(dir, "fake-remote")

    config.values.status.HEAD_folded = true
    local ok_open, buf = pcall(open_status, dir)
    if not ok_open then
      config.values.status.HEAD_folded = false
      error(buf)
    end
    config.values.status.HEAD_folded = false

    local text = buffer_text(buf)
    local head_line = text:match("[^\n]*Head:[^\n]*")
    assert.truthy(head_line and head_line:find("↑1", 1, true), "folded Head line must show ↑1:\n" .. text)

    -- display-level fold: the head block collapses to its first line, and
    -- that first (kept) line is where the counters live
    local head_lnum = vim.fn.search("Head:")
    local merge_lnum = vim.fn.search("Merge:", "n")
    assert.truthy(merge_lnum > 0, "Merge line must still exist in the buffer:\n" .. text)
    assert.equal(head_lnum, vim.fn.foldclosed(merge_lnum), "Merge line must sit inside the closed head fold")
  end)

  it("stays clean when the branch is in sync", function()
    local dir = workdir()
    run(dir, "branch", "fake-remote")
    run(dir, "branch", "--set-upstream-to=fake-remote")

    local buf = open_status(dir)
    local text = buffer_text(buf)

    local head_line = text:match("[^\n]*Head:[^\n]*")
    assert.truthy(head_line, "Head line must render:\n" .. text)
    assert.falsy(head_line:find("[↑↓]"), "in-sync Head line must not show counters:\n" .. text)
  end)

  it("shows Recent Commits even while the branch is ahead of upstream", function()
    local dir = workdir()
    local fd = assert(io.open(dir .. "/file.txt", "a"))
    fd:write("two\n")
    fd:close()
    run(dir, "add", "file.txt")
    run(dir, "commit", "-qm", "local-only")
    run(dir, "branch", "fake-remote")
    run(dir, "branch", "--set-upstream-to=fake-remote")

    local buf = open_status(dir)
    local text = buffer_text(buf)

    assert.truthy(text:find("Recent Commits", 1, true), "Recent Commits must render while ahead:\n" .. text)
    assert.truthy(text:match("%* %x+ t local%-only"), "the ahead commit must be listed:\n" .. text)
  end)
end)
