-- Untracked directory expansion: both status backends list individual files
-- inside untracked directories (git's --untracked-files=all /
-- GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS), never a collapsed "dir/" row.
local git2 = require("neogit.lib.git2")
local ItemFilter = require("neogit.lib.item_filter")

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
  run("commit", "-q", "--allow-empty", "-m", "init")

  -- an untracked directory with a nested subdirectory
  local function write(path, content)
    vim.fn.mkdir(vim.fs.dirname(dir .. "/" .. path), "p")
    vim.uv.fs_open(dir .. "/" .. path, "w", 420, function(_, fd)
      vim.uv.fs_write(fd, content, nil, function()
        vim.uv.fs_close(fd)
      end)
    end)
    vim.wait(500, function()
      return vim.fn.filereadable(dir .. "/" .. path) == 1
    end)
  end
  write("newdir/a.txt", "one\n")
  write("newdir/sub/b.txt", "two\n")

  return dir
end

local function fresh_state(dir)
  return {
    worktree_root = dir,
    staged = { items = {} },
    unstaged = { items = {} },
    untracked = { items = {} },
  }
end

local function untracked_names(state)
  local names = {}
  for _, item in ipairs(state.untracked.items) do
    table.insert(names, item.name)
  end
  return names
end

describe("lib.git.status untracked expansion", function()
  local dir

  before_each(function()
    dir = workdir()
    vim.cmd.cd(dir)

    -- Point the repo singleton at the temp dir (the libgit2 twin resolves
    -- its worktree through it).
    local Repo = require("neogit.lib.git.repository")
    local repo = Repo.instance()
    repo.worktree_root = dir
    repo.state.worktree_root = dir
  end)

  after_each(function()
    local backend = require("neogit.lib.git.backend")
    backend.reset()
  end)

  it("CLI backend lists files inside untracked directories", function()
    local status = require("neogit.lib.git.status")
    local state = fresh_state(dir)

    status.internal.update_status(state, ItemFilter.create { "*:*" })

    local names = untracked_names(state)
    assert.equal(2, #names, "expected the two files, got: " .. table.concat(names, ", "))
    assert.truthy(vim.tbl_contains(names, "newdir/a.txt"), "newdir/a.txt missing")
    assert.truthy(vim.tbl_contains(names, "newdir/sub/b.txt"), "newdir/sub/b.txt missing")
    for _, name in ipairs(names) do
      assert.is_not.equal("newdir/", name, "directory must not collapse into one row")
    end
  end)

  it("libgit2 twin lists files inside untracked directories", function()
    if not git2.probe().available then
      print("(libgit2 unavailable - skipping)")
      return
    end

    local twin = require("neogit.lib.git.libgit2.status")
    local state = fresh_state(dir)

    twin.update_status(state, ItemFilter.create { "*:*" })

    local names = untracked_names(state)
    assert.equal(2, #names, "expected the two files, got: " .. table.concat(names, ", "))
    assert.truthy(vim.tbl_contains(names, "newdir/a.txt"), "newdir/a.txt missing")
    assert.truthy(vim.tbl_contains(names, "newdir/sub/b.txt"), "newdir/sub/b.txt missing")
    for _, name in ipairs(names) do
      assert.is_not.equal("newdir/", name, "directory must not collapse into one row")
    end
  end)
end)
