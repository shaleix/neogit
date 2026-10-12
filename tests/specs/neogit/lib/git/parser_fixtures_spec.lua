-- Fixture specs for the CLI-side parsers. Each scenario builds a real
-- throwaway repository, runs the parser against live git output, and locks
-- the resulting item tables in place - so backend refactors (libgit2 twin
-- parity, parser rewrites) cannot silently change what lands in each
-- section. Section placement, modes and identity fields are asserted
-- exactly.
--
-- NOTE: status.internal.update_status shells out to
-- `git status --porcelain=v2 -z --untracked-files=all` itself (no --branch,
-- so branch header lines never reach the parser), and branch/reflog/refs
-- parsers are only reachable through their public (spawning) wrappers. The
-- fixtures below therefore drive the parsers through real repositories
-- rather than hand-written stdout strings.
local util = require("tests.util.util")
local ItemFilter = require("neogit.lib.item_filter")
local Repo = require("neogit.lib.git.repository")
local backend = require("neogit.lib.git.backend")

local status = require("neogit.lib.git.status")
local branch = require("neogit.lib.git.branch")
local reflog = require("neogit.lib.git.reflog")
local refs = require("neogit.lib.git.refs")

---Write a file inside `dir` (mkdir -p semantics for nested paths).
local function write(dir, path, content)
  local full = dir .. "/" .. path
  vim.fn.mkdir(vim.fs.dirname(full), "p")
  vim.fn.writefile(vim.split(content, "\n"), full)
end

---Create a throwaway git repository, hand it to `build` for fixtures, and
---return its path. `run` executes git commands with -C dir; pass true as
---second argument to ignore non-zero exits (conflicted merges).
local function repo(build)
  local dir = util.create_temp_dir("parser-fixture")

  local function run(args, ignore_err)
    return util.system(vim.list_extend({ "git", "-C", dir }, args), ignore_err)
  end

  run { "init", "-q", "-b", "master" }
  run { "config", "user.email", "test@neogit-test.test" }
  run { "config", "user.name", "Neogit Test" }

  build(run, dir)

  return dir
end

---Point the repo singleton at `dir` (same dance as status_spec.lua).
local function focus_repo(dir)
  vim.cmd.cd(dir)

  local instance = Repo.instance()
  instance.worktree_root = dir
  instance.state.worktree_root = dir
end

---Run the CLI status parser against `dir` and return the fresh state.
local function parse_status(dir)
  focus_repo(dir)

  local state = {
    worktree_root = dir,
    staged = { items = {} },
    unstaged = { items = {} },
    untracked = { items = {} },
  }

  status.internal.update_status(state, ItemFilter.create { "*:*" })

  return state
end

---name -> mode map of one section's items.
local function modes(section_items)
  local by_name = {}
  for _, item in ipairs(section_items) do
    by_name[item.name] = item.mode
  end
  return by_name
end

---Sorted key list of a keyed table (for order-insensitive comparisons).
local function sorted_keys(tbl)
  local keys = vim.tbl_keys(tbl)
  table.sort(keys)
  return keys
end

-- § status.internal.update_status ------------------------------------------------

describe("lib.git.status update_status fixtures", function()
  after_each(function()
    backend.reset()
  end)

  -- Each entry builds a repo, then expects exact name -> mode maps for the
  -- three status sections. `detail` optionally asserts identity fields on
  -- the produced items.
  local scenarios = {
    ["clean worktree produces no items"] = {
      build = function(run, dir)
        write(dir, "a.txt", "a\n")
        run { "add", "." }
        run { "commit", "-q", "-m", "init" }
      end,
      expect = { staged = {}, unstaged = {}, untracked = {} },
    },

    ["staged modification lands in staged with mode M"] = {
      build = function(run, dir)
        write(dir, "a.txt", "a\n")
        run { "add", "." }
        run { "commit", "-q", "-m", "init" }
        write(dir, "a.txt", "a\nb\n")
        run { "add", "a.txt" }
      end,
      expect = { staged = { ["a.txt"] = "M" }, unstaged = {}, untracked = {} },
      detail = function(state)
        local item = state.staged.items[1]
        assert.are.same({ head = "100644", index = "100644", worktree = "100644" }, item.file_mode)
        assert.is_nil(item.submodule, "ordinary entries carry no submodule status")
        assert.is_nil(item.original_name)
        assert.truthy(item.absolute_path:match("a%.txt$"), "absolute_path points at the file")
      end,
    },

    ["unstaged modification lands in unstaged with mode M"] = {
      build = function(run, dir)
        write(dir, "a.txt", "a\n")
        run { "add", "." }
        run { "commit", "-q", "-m", "init" }
        write(dir, "a.txt", "a\nb\n")
      end,
      expect = { staged = {}, unstaged = { ["a.txt"] = "M" }, untracked = {} },
    },

    ["the same file can be staged and unstaged at once"] = {
      build = function(run, dir)
        write(dir, "a.txt", "a\n")
        run { "add", "." }
        run { "commit", "-q", "-m", "init" }
        write(dir, "a.txt", "a\nb\n")
        run { "add", "a.txt" }
        write(dir, "a.txt", "a\nb\nc\n")
      end,
      expect = { staged = { ["a.txt"] = "M" }, unstaged = { ["a.txt"] = "M" }, untracked = {} },
      detail = function(state)
        assert.equal(1, #state.staged.items)
        assert.equal(1, #state.unstaged.items)
        assert.are.same(
          { head = "100644", index = "100644", worktree = "100644" },
          state.staged.items[1].file_mode
        )
      end,
    },

    ["untracked files (nested too) land in untracked with mode ?"] = {
      build = function(run, dir)
        write(dir, "a.txt", "a\n")
        run { "add", "." }
        run { "commit", "-q", "-m", "init" }
        write(dir, "new.txt", "new\n")
        write(dir, "newdir/nested.txt", "nested\n")
      end,
      expect = {
        staged = {},
        unstaged = {},
        untracked = { ["new.txt"] = "?", ["newdir/nested.txt"] = "?" },
      },
      detail = function(state)
        local item = state.untracked.items[1]
        assert.is_nil(item.file_mode, "untracked entries carry no file modes")
        assert.is_nil(item.submodule)
      end,
    },

    ["staged rename records the original name"] = {
      build = function(run, dir)
        write(dir, "a.txt", "a\n")
        run { "add", "." }
        run { "commit", "-q", "-m", "init" }
        run { "mv", "a.txt", "b.txt" }
      end,
      expect = { staged = { ["b.txt"] = "R" }, unstaged = {}, untracked = {} },
      detail = function(state)
        local item = state.staged.items[1]
        assert.equal("a.txt", item.original_name)
        assert.is_nil(modes(state.staged.items)["a.txt"], "old name must not appear alongside the rename")
      end,
    },

    ["both-modified conflict (UU) lands in unstaged"] = {
      build = function(run, dir)
        write(dir, "shared.txt", "base\n")
        run { "add", "." }
        run { "commit", "-q", "-m", "init" }
        run { "checkout", "-q", "-b", "side" }
        write(dir, "shared.txt", "side\n")
        run { "commit", "-q", "-am", "side" }
        run { "checkout", "-q", "master" }
        write(dir, "shared.txt", "master\n")
        run { "commit", "-q", "-am", "master" }
        run({ "merge", "side" }, true) -- conflicts, exit 1
      end,
      expect = { staged = {}, unstaged = { ["shared.txt"] = "UU" }, untracked = {} },
      detail = function(state)
        local item = state.unstaged.items[1]
        assert.is_nil(item.file_mode, "unmerged entries carry no file modes")
        assert.is_nil(item.submodule)
      end,
    },

    ["both-added conflict (AA) lands in unstaged"] = {
      build = function(run, dir)
        write(dir, "a.txt", "a\n")
        run { "add", "." }
        run { "commit", "-q", "-m", "init" }
        run { "checkout", "-q", "-b", "side" }
        write(dir, "conflict.txt", "side\n")
        run { "add", "conflict.txt" }
        run { "commit", "-q", "-m", "side adds" }
        run { "checkout", "-q", "master" }
        write(dir, "conflict.txt", "master\n")
        run { "add", "conflict.txt" }
        run { "commit", "-q", "-m", "master adds" }
        run({ "merge", "side" }, true) -- conflicts, exit 1
      end,
      expect = { staged = {}, unstaged = { ["conflict.txt"] = "AA" }, untracked = {} },
    },

    ["both-deleted conflict (DD) lands in unstaged"] = {
      build = function(run, dir)
        write(dir, "a.txt", "a\n")
        run { "add", "." }
        run { "commit", "-q", "-m", "init" }

        -- Real "both deleted" index state: an unmerged entry carrying only
        -- the stage-1 (base) blob, no worktree file, no HEAD entry.
        local sha = vim.trim(run { "hash-object", "-w", "--stdin", "-t", "blob" })
        vim.fn.writefile({ ("100644 %s 1\tf.txt"):format(sha) }, dir .. "/.git/dd-info")
        util.system {
          "bash",
          "-c",
          ("git -C %q update-index --index-info < %q"):format(dir, dir .. "/.git/dd-info"),
        }
      end,
      expect = { staged = {}, unstaged = { ["f.txt"] = "DD" }, untracked = {} },
      detail = function(state)
        local item = state.unstaged.items[1]
        assert.is_nil(item.file_mode)
        assert.is_nil(item.submodule)
      end,
    },
  }

  for name, scenario in pairs(scenarios) do
    it(name, function()
      local dir = repo(scenario.build)
      local state = parse_status(dir)

      for section, expected in pairs(scenario.expect) do
        assert.are.same(expected, modes(state[section].items), section .. " section mismatch")
      end

      if scenario.detail then
        scenario.detail(state)
      end
    end)
  end
end)

-- § lib.git.branch parse ---------------------------------------------------------

describe("lib.git.branch parse (via public listings)", function()
  local dir

  after_each(function()
    backend.reset()
  end)

  before_each(function()
    dir = repo(function(run, d)
      write(d, "a.txt", "a\n")
      run { "add", "." }
      run { "commit", "-q", "-m", "init" }
      run { "branch", "feature/deep" }

      local bare = d .. "-bare.git"
      run { "clone", "-q", "--bare", d, bare }
      run { "remote", "add", "origin", bare }
      run { "fetch", "-q", "--no-tags", "origin" }
      run { "remote", "set-head", "origin", "-a" }
    end)

    focus_repo(dir)
  end)

  it("local listings honor include_current and keep nested names", function()
    table.sort(branch.get_local_branches(true))
    assert.are.same({ "feature/deep", "master" }, branch.get_local_branches(true))

    table.sort(branch.get_local_branches(false))
    assert.are.same({ "feature/deep" }, branch.get_local_branches(false))
  end)

  it("remote listings are remote-qualified and omit the HEAD symref", function()
    local remotes = branch.get_remote_branches()
    table.sort(remotes)
    assert.are.same({ "origin/feature/deep", "origin/master" }, remotes)
  end)

  it("--contains listings strip the current-branch marker", function()
    write(dir, "b.txt", "b\n")
    util.system { "git", "-C", dir, "add", "." }
    util.system { "git", "-C", dir, "commit", "-q", "-m", "diverge" }

    assert.are.same({ "master" }, branch.list_containing_branches("master"))

    local base = vim.trim(util.system { "git", "-C", dir, "rev-list", "--max-parents=0", "HEAD" })
    local containing = branch.list_containing_branches(base)
    table.sort(containing)
    assert.are.same({ "feature/deep", "master" }, containing)
  end)
end)

-- § lib.git.reflog parse ---------------------------------------------------------

describe("lib.git.reflog parse (via reflog.list)", function()
  local dir, entries, head_oid, root_oid

  after_each(function()
    backend.reset()
  end)

  before_each(function()
    dir = repo(function(run, d)
      write(d, "a.txt", "a\n")
      run { "add", "." }
      run { "commit", "-q", "-m", "initial commit" }
      run { "checkout", "-q", "-b", "feature" }
      write(d, "feature.txt", "feature\n")
      run { "add", "." }
      run { "commit", "-q", "-m", "feature work" }
      run { "checkout", "-q", "master" }
      write(d, "master.txt", "master\n")
      run { "add", "." }
      run { "commit", "-q", "-m", "master work" }
      run { "merge", "-q", "-m", "merge feature", "feature" }
      run { "commit", "-q", "--amend", "-m", "master work v2" }
    end)

    focus_repo(dir)

    entries = reflog.list("HEAD", {})
    head_oid = vim.trim(util.system { "git", "-C", dir, "rev-parse", "HEAD" })
    root_oid = vim.trim(util.system { "git", "-C", dir, "rev-list", "--max-parents=0", "HEAD" })
  end)

  it("produces one typed entry per reflog record, newest first", function()
    local types = vim.tbl_map(function(entry)
      return entry.type
    end, entries)

    assert.are.same({ "amend", "merge", "commit", "checkout", "commit", "checkout", "initial" }, types)
  end)

  it("rewrites command subjects into typed messages", function()
    assert.equal("amend", entries[1].type)
    assert.equal("master work v2", entries[1].ref_subject)

    assert.equal("merge", entries[2].type)
    assert.truthy(
      entries[2].ref_subject:match("^feature: Merge made by"),
      "merge subject keeps the merged ref: " .. tostring(entries[2].ref_subject)
    )

    assert.equal("commit", entries[3].type)
    assert.equal("master work", entries[3].ref_subject)

    assert.equal("checkout", entries[4].type)
    assert.equal("moving from feature to master", entries[4].ref_subject)

    assert.equal("checkout", entries[6].type)
    assert.equal("moving from master to feature", entries[6].ref_subject)

    assert.equal("initial", entries[7].type)
    assert.equal("initial commit", entries[7].ref_subject)
  end)

  it("attaches oid, index, ref_name and author to every entry", function()
    assert.equal(head_oid, entries[1].oid)
    assert.equal(root_oid, entries[7].oid)
    -- %gd renders absolute-time selectors under the raw date format
    -- (HEAD@{<unixtime> <tz>}); lock the shape, not the timestamp.
    assert.truthy(entries[1].ref_name:match("^HEAD@%{%d+"), entries[1].ref_name)
    assert.truthy(entries[7].ref_name:match("^HEAD@%{%d+"), entries[7].ref_name)

    for i, entry in ipairs(entries) do
      assert.equal(i - 1, entry.index)
      assert.equal("Neogit Test", entry.author_name)
      assert.truthy(type(entry.rel_date) == "string" and #entry.rel_date > 0)
      assert.truthy(type(entry.commit_date) == "string" and #entry.commit_date > 0)
    end
  end)
end)

-- § lib.git.refs.list_parsed -----------------------------------------------------

describe("lib.git.refs.list_parsed", function()
  local dir, parsed

  after_each(function()
    backend.reset()
  end)

  before_each(function()
    dir = repo(function(run, d)
      write(d, "a.txt", "a\n")
      run { "add", "." }
      run { "commit", "-q", "-m", "init" }
      run { "branch", "feature/deep" }
      run { "tag", "v1.0.0" }

      local bare = d .. "-bare.git"
      run { "clone", "-q", "--bare", d, bare }
      run { "remote", "add", "origin", bare }
      run { "fetch", "-q", "--no-tags", "origin" }
      run { "remote", "set-head", "origin", "-a" }
    end)

    focus_repo(dir)

    parsed = refs.list_parsed()
  end)

  local function by_name(list)
    local out = {}
    for _, ref in ipairs(list) do
      out[ref.name] = ref
    end
    return out
  end

  it("classifies local branches and marks HEAD", function()
    local locals = by_name(parsed.local_branch)
    assert.are.same({ "feature/deep", "master" }, sorted_keys(locals))

    assert.equal("local_branch", locals["master"].type)
    assert.is_true(locals["master"].head)
    assert.equal("local_branch", locals["feature/deep"].type)
    assert.is_false(locals["feature/deep"].head)

    for _, ref in pairs(locals) do
      assert.equal(ref.name, ref.unambiguous_name)
    end
  end)

  it("groups remote branches under their remote", function()
    local origin = parsed.remote_branch.origin or {}
    assert.are.same({ "HEAD", "feature/deep", "master" }, sorted_keys(by_name(origin)))

    for _, ref in pairs(origin) do
      assert.equal("remote_branch", ref.type)
      assert.equal("origin", ref.remote)
      assert.equal("origin/" .. ref.name, ref.unambiguous_name)
    end
  end)

  it("classifies tags", function()
    assert.equal(1, #parsed.tag)

    local tag = parsed.tag[1]
    assert.equal("v1.0.0", tag.name)
    assert.equal("tag", tag.type)
    assert.equal("tags/v1.0.0", tag.unambiguous_name)
    assert.is_false(tag.head)
  end)
end)
