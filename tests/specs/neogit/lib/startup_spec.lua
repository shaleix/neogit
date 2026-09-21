-- Startup behavior: single first refresh on the status-open path, rev-parse
-- metadata reuse, and lazy submodule info. Uses a vim.system spy to count
-- spawned git processes.
local Repo = require("neogit.lib.git.repository")
local cli = require("neogit.lib.git").cli
local status_buf = require("neogit.buffers.status")
local config = require("neogit.config")

local function workdir()
  local dir = vim.fn.tempname()
  vim.uv.fs_mkdir(dir, 493)
  local r = vim.system({ "git", "-C", dir, "init", "-q" }):wait()
  assert(r.code == 0, r.stderr)
  vim.system({ "git", "-C", dir, "config", "user.email", "t@t" }):wait()
  vim.system({ "git", "-C", dir, "config", "user.name", "t" }):wait()
  vim.system({ "git", "-C", dir, "commit", "-qm", "init", "--allow-empty" }):wait()

  return dir
end

local function spy_git(fn)
  local real = vim.system
  local calls = {}

  vim.system = function(cmd, opts)
    if cmd and cmd[1] == "git" then
      calls[#calls + 1] = table.concat(cmd, " ")
    end
    return real(cmd, opts)
  end

  local ok, result = pcall(fn)
  vim.system = real

  assert(ok, result)
  return result, calls
end

describe("startup: repo metadata reuse (cli.repo_info)", function()
  it("answers all four queries with a single git process, then caches", function()
    local dir = workdir()

    local _, calls = spy_git(function()
      local info = cli.repo_info(dir)
      assert.truthy(info.worktree_root:match("[^/]+$"))
      assert.truthy(info.worktree_git_dir:match("%.git$"))
      assert.truthy(info.git_dir:match("%.git$"))
      assert.is_true(info.inside)

      -- cache hit: no further spawns for the same directory or the toplevel
      assert.equal(cli.repo_info(dir), info)
      assert.equal(cli.worktree_root(dir), info.worktree_root)
      assert.equal(cli.git_dir(dir), info.git_dir)
      assert.equal(cli.worktree_git_dir(dir), info.worktree_git_dir)
      assert.equal(cli.is_inside_worktree(dir), true)
    end)

    assert.equal(1, #calls, "expected exactly one git process, got: " .. vim.inspect(calls))
  end)

  it("aliases the cache under the worktree root for the neogit.open path", function()
    local dir = workdir()

    local _, calls = spy_git(function()
      local root = cli.worktree_root(dir) -- construct_opts does this
      local info = cli.repo_info(root) -- Repo.new does this
      assert.equal(root, info.worktree_root)
    end)

    assert.equal(1, #calls, "expected one process total, got: " .. vim.inspect(calls))
  end)
end)

describe("startup: first refresh on the status-open path", function()
  local dir

  before_each(function()
    dir = workdir()
    vim.cmd.cd(dir)
  end)

  it("Repo.instance dispatches a refresh by default (existing contract)", function()
    local repo = Repo.instance(dir)
    assert.truthy(repo._refresh_task, "default instance should auto-refresh")
    vim.wait(5000, function()
      return repo._refresh_task:done()
    end, 10)
  end)

  it("Repo.instance(dir, { autorefresh = false }) does not refresh", function()
    local repo = Repo.instance(dir, { autorefresh = false })
    assert.is_nil(repo._refresh_task, "autorefresh=false must not dispatch a refresh")
  end)

  it("the open path spawns zero git processes between instance and refresh", function()
    local repo, calls = spy_git(function()
      local r = Repo.instance(dir, { autorefresh = false })
      status_buf.new(config.values, r.worktree_root, dir) -- registers, must not spawn
      return r
    end)

    assert.is_nil(repo._refresh_task)
    for _, c in ipairs(calls) do
      assert.truthy(
        c:find("rev-parse", 1, true) or c:find("config", 1, true),
        "unexpected spawn during open path: " .. c
      )
    end
  end)
end)

describe("startup: lazy submodule info", function()
  it("computes submodule/parent data once, on first access, caching nils", function()
    local dir = workdir()
    local instance = status_buf.new(config.values, dir, dir)

    -- These run through the runner (jobstart), not vim.system, so count at
    -- the module boundary instead.
    local submodule = require("neogit.lib.git.submodule")
    local rev_parse = require("neogit.lib.git.rev_parse")
    local counts = { submodule = 0, parent = 0 }

    local real_list, real_parent = submodule.list, rev_parse.parent_repo
    submodule.list = function()
      counts.submodule = counts.submodule + 1
      return real_list()
    end
    rev_parse.parent_repo = function()
      counts.parent = counts.parent + 1
      return real_parent()
    end

    local ok, err = pcall(function()
      assert.equal(0, #instance:submodules(), "no submodules in a plain repo")
      assert.is_nil(instance:parent_repo(), "not a submodule")
      -- second access must hit the cache, nils included
      assert.equal(0, #instance:submodules())
      assert.is_nil(instance:parent_repo())
    end)

    submodule.list = real_list
    rev_parse.parent_repo = real_parent

    assert(ok, err)
    assert.equal(1, counts.submodule, "submodule list should be computed exactly once")
    assert.equal(1, counts.parent, "parent repo should be computed exactly once")
  end)
end)
