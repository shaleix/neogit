local git2 = require("neogit.lib.git2")
local backend = require("neogit.lib.git.backend")
local config = require("neogit.config")

describe("lib.git2 (libgit2 binding overlay)", function()
  describe("vendored loading", function()
    it("loads the binding without polluting the global fugit2 namespace", function()
      local git2mod = git2.binding.git2()
      assert.truthy(git2mod)
      assert.truthy(git2mod.Repository)
      assert.truthy(git2mod.Error)

      assert.is_nil(package.loaded["fugit2.core.git2"])
      assert.is_nil(package.loaded["fugit2.core.libgit2"])
    end)

    it("returns the cached module on repeated loads", function()
      assert.equal(git2.binding.git2(), git2.binding.git2())
    end)
  end)

  describe("probe (version gate)", function()
    local probe = git2.probe()

    it("never errors and always reports a reason or a version", function()
      assert.truthy(probe)
      if probe.available then
        assert.matches("^1%.%d+%.%d+$", probe.version)
        assert.is_true(probe.major == 1)
        assert.is_true(probe.minor >= git2.MINIMUM[2])
      else
        assert.truthy(probe.reason)
      end
    end)

    it("applies per-version enum overrides on success", function()
      if not probe.available then
        return
      end

      local lg2 = git2.binding.libgit2()

      if probe.minor >= 9 then
        -- 1.9 reordered checkout strategies (stale NONE=0 would mean SAFE)
        assert.equal(0, lg2.GIT_CHECKOUT.SAFE)
        assert.equal(bit.lshift(1, 30), lg2.GIT_CHECKOUT.NONE)
      end

      if probe.minor >= 8 then
        assert.equal(6, lg2.GIT_CONFIG_LEVEL.WORKTREE)
        assert.equal(7, lg2.GIT_CONFIG_LEVEL.APP)
      end

      assert.equal(probe.minor < 9, git2.feature_flags.blame_boundary)
      assert.equal(probe.minor >= 8, git2.feature_flags.config_entry_level)
    end)

    it("respects libgit2_path config when set to a bogus value", function()
      local saved = config.values.libgit2_path
      config.values.libgit2_path = "/nonexistent/libgit2.so.99"
      git2.probe { force = true }
      local probe_bad = git2.probe()
      config.values.libgit2_path = saved

      if not probe_bad.available then
        assert.truthy(probe_bad.reason)
        assert.is_true(vim.tbl_contains(probe_bad.tried, "/nonexistent/libgit2.so.99"))
      end
      -- A bogus explicit path must not be fatal: the soname sequence follows it.
      assert.equal(git2.probe({ force = true }).available, probe.available)
    end)
  end)

  describe("repository + error mapping", function()
    it("fails cleanly on a non-repository path", function()
      local repo, err = git2.open_repo("/nonexistent/repo")
      assert.is_nil(repo)
      assert.truthy(err and err < 0)

      local result = git2.git_result(err, "open: ")
      assert.is_true(result:failure())
      assert.is_false(result.ok)
      assert.truthy(#result.message > 0)
    end)

    it("opens a real repository and reads structured status", function()
      if not git2.probe().available then
        return
      end

      local dir = vim.fn.tempname()
      vim.uv.fs_mkdir(dir, 493)
      assert.equal(0, vim.system({ "git", "-C", dir, "init", "-q" }):wait().code)
      assert.equal(0, vim.system({ "git", "-C", dir, "config", "user.email", "t@t" }):wait().code)
      assert.equal(0, vim.system({ "git", "-C", dir, "config", "user.name", "t" }):wait().code)
      vim.uv.fs_open(dir .. "/f.txt", "w", 420, function(_, fd)
        vim.uv.fs_write(fd, "hello\n", nil, function()
          vim.uv.fs_close(fd)
        end)
      end)
      vim.wait(200, function()
        return vim.fn.filereadable(dir .. "/f.txt") == 1
      end)

      local repo = git2.open_repo(dir, true)
      assert.truthy(repo)
      local items = repo:status()
      assert.truthy(items)
      assert.equal(1, #items) -- one untracked file
    end)
  end)
end)

describe("lib.git.backend (selection policy)", function()
  after_each(function()
    backend.reset()
    config.values.git_backend = "auto"
  end)

  it("resolves to cli when git_backend = cli (no probe involved)", function()
    config.values.git_backend = "cli"
    assert.equal("cli", backend.current())
  end)

  it("auto mode matches probe availability, with graceful degrade", function()
    config.values.git_backend = "auto"
    local expected = git2.probe().available and "libgit2" or "cli"
    assert.equal(expected, backend.current())
  end)

  it("hard-errors in libgit2 mode when the binding is unavailable", function()
    if git2.probe().available then
      return -- cannot simulate absence on this machine without stubbing probe
    end

    config.values.git_backend = "libgit2"
    assert.error_matches(backend.current, "git_backend")
  end)

  it("capability table defaults to cli and flips per module only when available", function()
    assert.equal("cli", backend.capability("update_status"))
    backend.mark_migrated("update_status")
    assert.equal("cli", backend.capability("update_unpulled"))

    if git2.probe().available then
      assert.equal("libgit2", backend.capability("update_status"))
    else
      assert.equal("cli", backend.capability("update_status"))
    end
  end)
end)
