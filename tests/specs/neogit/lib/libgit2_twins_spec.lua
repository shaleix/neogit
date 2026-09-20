-- libgit2 backend twins: query equivalence against the git CLI (skip-friendly
-- when no usable libgit2 is present; run with a libgit2 for full coverage).
local git2 = require("neogit.lib.git2")
local backend = require("neogit.lib.git.backend")
local config = require("neogit.config")

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
  vim.uv.fs_open(dir .. "/a.txt", "w", 420, function(_, fd)
    vim.uv.fs_write(fd, "one\n", nil, function()
      vim.uv.fs_close(fd)
    end)
  end)
  vim.wait(200, function()
    return vim.fn.filereadable(dir .. "/a.txt") == 1
  end)
  run("git", "add", "a.txt")
  run("git", "commit", "-qm", "subject one")
  run("git", "tag", "v1.0.0")
  run("git", "branch", "feature/x")

  return dir
end

describe("lib.git.libgit2 twins", function()
  local dir
  local probe_ok = git2.probe().available

  before_each(function()
    dir = workdir()
    vim.cmd.cd(dir)

    -- Point the repo singleton at the temp dir.
    local Repo = require("neogit.lib.git.repository")
    local repo = Repo.instance()
    repo.worktree_root = dir
    repo.state.worktree_root = dir
  end)

  after_each(function()
    config.values.git_backend = "auto"
    backend.reset()
  end)

  describe("relative_date formatting (git %cr)", function()
    local log_twin = require("neogit.lib.git.libgit2.log")

    it("formats spans like git does", function()
      local now = os.time()

      assert.equal("45 seconds ago", log_twin.relative_date(now - 45))
      assert.equal("2 minutes ago", log_twin.relative_date(now - 120))
      assert.equal("2 hours ago", log_twin.relative_date(now - 2 * 3600))
      assert.equal("2 days ago", log_twin.relative_date(now - 2 * 86400))
      assert.equal("3 weeks ago", log_twin.relative_date(now - 20 * 86400)) -- git: (20+3)/7
      assert.equal("2 months ago", log_twin.relative_date(now - 70 * 86400)) -- git: (70+15)/30
      assert.equal("1 year, 1 month ago", log_twin.relative_date(now - 400 * 86400))
      assert.equal("4 years, 11 months ago", log_twin.relative_date(now - 1800 * 86400)) -- <1825d
      assert.equal("11 years ago", log_twin.relative_date(now - 4000 * 86400)) -- >=1825d: plain years
    end)

    it("matches git for a commit with a fixed committer date", function()
      -- 3 hours ago, fixed (local time — git parses bare ISO dates as local).
      local fixed = os.time() - 3 * 3600
      local when = os.date("%Y-%m-%dT%H:%M:%S", fixed)
      local r = vim.system({ "git", "-C", dir, "commit", "--allow-empty", "-qm", "dated" }, {
        env = {
          PATH = os.getenv("PATH"),
          GIT_COMMITTER_DATE = when,
          GIT_AUTHOR_DATE = when,
        },
      }):wait()
      assert.equal(0, r.code, r.stderr)

      local cli = vim.trim(vim.system({ "git", "-C", dir, "log", "-1", "--format=%cr" }):wait().stdout)
      assert.equal(cli, log_twin.relative_date(fixed))
    end)
  end)

  describe("query twins (CLI equivalence)", function()
    local git

    before_each(function()
      git = require("neogit.lib.git")
      config.values.git_backend = "libgit2"
      backend.reset()
      assert.equal("libgit2", backend.current())
    end)

    it("rev_parse.oid matches the CLI", function()
      if not probe_ok then
        return
      end

      local cli = vim.trim(vim.system({ "git", "-C", dir, "rev-parse", "HEAD" }):wait().stdout)
      assert.equal(cli, git.rev_parse.oid("HEAD"))
      assert.truthy(git.rev_parse.oid("HEAD~1") == nil or #git.rev_parse.oid("HEAD~1") == 40)
    end)

    it("log.message matches the CLI %s", function()
      if not probe_ok then
        return
      end

      local cli = vim.trim(vim.system({ "git", "-C", dir, "log", "-1", "--format=%s" }):wait().stdout)
      assert.equal(cli, git.log.message("HEAD"))
    end)

    it("branch.current / current_full_name / exists", function()
      if not probe_ok then
        return
      end

      assert.equal("main", git.branch.current())
      assert.equal("refs/heads/main", git.branch.current_full_name())
      assert.is_true(git.branch.exists("main"))
      assert.is_true(git.branch.exists("feature/x"))
      assert.is_false(git.branch.exists("nope"))
    end)

    it("branch listings match the CLI set", function()
      if not probe_ok then
        return
      end

      local cli_locals = vim.trim(vim.system(
        { "git", "-C", dir, "for-each-ref", "--format=%(refname:short)", "refs/heads/" }
      ):wait().stdout)
      local twin_locals = table.concat(git.branch.get_local_branches(true), "\n")
      assert.equal(cli_locals, twin_locals)
    end)

    it("refs listings match the CLI", function()
      if not probe_ok then
        return
      end

      local cli_tags = vim.trim(vim.system({ "git", "-C", dir, "tag" }):wait().stdout)
      assert.equal(cli_tags, table.concat(git.refs.list_tags(), ","))

      local cli_locals = vim.trim(vim.system(
        { "git", "-C", dir, "for-each-ref", "--format=%(refname:short)", "refs/heads/" }
      ):wait().stdout)
      assert.equal(cli_locals, table.concat(git.refs.list_local_branches(), "\n"))
    end)

    it("log.list twin matches the CLI records", function()
      if not probe_ok then
        return
      end

      local twin = git.log.list({ "--max-count=10" }, nil, {}, true)
      assert.truthy(#twin >= 1)

      local cli_raw = vim.system(
        { "git", "-C", dir, "log", "--max-count=3", "--format=%H%x1F%s%x1F%aD%x1F%P%x1F%D" },
        {}
      ):wait().stdout
      local lines = vim.split(vim.trim(cli_raw), "\n")

      assert.equal(#lines, #twin, "commit count mismatch")
      for i, line in ipairs(lines) do
        local oid, subject, author_date, parent, ref_name = unpack(vim.split(line, "\31"))
        local entry = twin[i]

        assert.equal(oid, entry.oid, "oid mismatch at " .. i)
        assert.equal(subject, entry.subject, "subject mismatch at " .. i)
        assert.equal(author_date, entry.author_date, "author_date mismatch at " .. i)
        assert.equal(parent, entry.parent, "parents mismatch at " .. i)

        -- Decoration ORDER differs from git (foreach is refname-sorted); the
        -- consumer (branch_info) parses the set, so compare order-insensitively.
        local expected_parts = vim.split(ref_name or "", ", ")
        table.sort(expected_parts)
        local actual_parts = vim.split(entry.ref_name or "", ", ")
        table.sort(actual_parts)
        assert.equal(table.concat(expected_parts, "\31"), table.concat(actual_parts, "\31"), "decorations mismatch at " .. i)
      end
    end)

    it("log.list falls back to the CLI for unsupported filters", function()
      if not probe_ok then
        return
      end

      local filtered = git.log.list({ "--max-count=5", "--author=nobody" }, nil, {}, true)
      assert.equal(0, #filtered)
    end)
  end)
end)
