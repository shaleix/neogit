-- Progressive status rendering: skeleton section headers appear at open,
-- each module's data becomes visible as its refresh task lands.
local neogit = require("neogit")
local config = require("neogit.config")
local Repo = require("neogit.lib.git.repository")
local status_buf = require("neogit.buffers.status")

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

  vim.uv.fs_open(dir .. "/untracked.txt", "w", 420, function(_, fd)
    vim.uv.fs_write(fd, "x\n", nil, function()
      vim.uv.fs_close(fd)
    end)
  end)
  vim.wait(500, function()
    return vim.fn.filereadable(dir .. "/untracked.txt") == 1
  end)

  return dir
end

local function buffer_text(buf)
  local lines = vim.api.nvim_buf_get_lines(buf.buffer.handle, 0, -1, false)
  return table.concat(lines, "\n")
end

local function wait_refreshed()
  local fired = false
  vim.api.nvim_create_autocmd("User", {
    pattern = "NeogitStatusRefreshed",
    once = true,
    callback = function()
      fired = true
    end,
  })
  assert.truthy(vim.wait(10000, function()
    return fired
  end, 10), "refresh did not complete")
  vim.wait(50)
end

neogit.setup({ filewatcher = { enabled = false }, disable_context_highlighting = true })

describe("progressive status rendering", function()
  it("renders skeleton headers at open, before any refresh", function()
    local dir = workdir()
    vim.cmd.cd(dir)

    local repo = Repo.instance(dir, { autorefresh = false })
    assert.is_true(repo.state.loading)

    local buf = status_buf.new(config.values, repo.worktree_root, dir)
    buf:open("split")

    local text = buffer_text(buf)
    assert.truthy(text:find("Untracked files", 1, true), "untracked skeleton header missing")
    assert.truthy(text:find("Unstaged changes", 1, true), "unstaged skeleton header missing")
    assert.truthy(text:find("Staged changes", 1, true), "staged skeleton header missing")
    assert.is_nil(text:find("untracked%.txt", 1, true), "items must not be present before refresh")
  end)

  it("fills sections as modules land and drops the skeleton when done", function()
    local dir = workdir()
    vim.cmd.cd(dir)

    Repo.instance(dir, { autorefresh = false })
    local buf = status_buf.new(config.values, Repo.instance(dir).worktree_root, dir)
    buf:open("split")
    buf:dispatch_refresh()
    wait_refreshed()

    local text = buffer_text(buf)
    assert.truthy(text:find("untracked.txt", 1, true), "untracked item must appear after refresh")
    assert.is_nil(Repo.instance(dir).state.loading, "loading flag must clear after completion")

    -- genuinely empty sections hide again once loading is over
    assert.is_nil(text:find("Stashes", 1, true), "empty stash section must hide when loaded")
  end)

  it("notifies per-module progress and commits state progressively", function()
    local dir = workdir()
    vim.cmd.cd(dir)

    local repo = Repo.instance(dir, { autorefresh = false })
    local seen = {}
    local loading_seen_while_progress = false

    repo:refresh {
      source = "test",
      progress = function(name)
        seen[name] = true
        if repo.state.loading then
          loading_seen_while_progress = true
        end
      end,
    }

    vim.wait(10000, function()
      return repo._refresh_task ~= nil and repo._refresh_task:done()
    end, 10)
    vim.wait(50)

    assert.truthy(seen.update_status, "progress must report update_status")
    assert.truthy(seen.update_recent or seen.update_branch_information, "progress must report read modules")
    assert.is_nil(repo.state.loading, "loading must clear on completion")
    assert.is_true(loading_seen_while_progress, "state stays loading (skeleton) during progress")
  end)

  it("keeps the second-section anchor on the filled header after refresh", function()
    local dir = workdir()
    vim.cmd.cd(dir)

    -- tracked modification so the Unstaged section has an item
    vim.uv.fs_open(dir .. "/tracked.txt", "w", 420, function(_, fd)
      vim.uv.fs_write(fd, "a\n", nil, function()
        vim.uv.fs_close(fd)
      end)
    end)
    vim.wait(500, function()
      return vim.fn.filereadable(dir .. "/tracked.txt") == 1
    end)
    vim.system({ "git", "-C", dir, "add", "tracked.txt" }):wait()
    vim.system({ "git", "-C", dir, "commit", "-qm", "init" }):wait()
    vim.uv.fs_open(dir .. "/tracked.txt", "a", 420, function(_, fd)
      vim.uv.fs_write(fd, "b\n", nil, function()
        vim.uv.fs_close(fd)
      end)
    end)
    vim.wait(500, function()
      return true
    end)

    Repo.instance(dir, { autorefresh = false })
    local buf = status_buf.new(config.values, Repo.instance(dir).worktree_root, dir)
    buf:open("split")
    buf:dispatch_refresh()
    wait_refreshed()

    local second = buf.buffer.ui:section_at_index(2)
    assert.truthy(second)
    assert.equal("unstaged", second.name)
    assert.equal(second.first, buf.buffer:cursor_line())
  end)
end)
