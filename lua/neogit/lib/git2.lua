-- neogit libgit2 binding overlay (migration spec §3.1, ADR-0001/0003/0004).
--
-- The vendored binding (lua/neogit/lib/vendor/fugit2/*) is a frozen verbatim
-- snapshot; everything neogit-specific lives HERE:
--   * namespace-isolated loading of the vendored modules (they internally
--     require "fugit2.*", which we redirect to our vendor dir so we never
--     touch the global module namespace — fugit2.nvim can coexist)
--   * soname candidate loading + runtime version gate (min 1.7, hard-reject
--     major ~= 1)
--   * per-version enum overrides (1.9 GIT_CHECKOUT reorder, 1.8
--     GIT_CONFIG_LEVEL insertion) — structure layout cannot be probed, so
--     the version number is the only authority
--   * the executor seam: every libgit2 call goes through M.run; the sync
--     implementation is first, a uv.new_work implementation can replace it
--     later without touching callers
local ffi = require("ffi")
local GitResult = require("neogit.lib.git.result")
local logger = require("neogit.logger")

local M = {}

-- The version probe is not declared by the vendored cdef; it is a
-- never-breaking API that has existed since 0.x, safe to call on any 1.x/2.x.
ffi.cdef([[ void git_libgit2_version(int *major, int *minor, int *rev); ]])

-- Additional public, ABI-stable APIs the vendored cdef omits are declared
-- lazily in ensure_extra_cdefs() (below the vendor loader) because they
-- reference the vendored typedefs.

--------------------------------------------------------------------------------
-- Namespace-isolated vendor loader
--------------------------------------------------------------------------------

local here = (debug.getinfo(1, "S").source:match("@(.*[/\\])") or "")
local VENDOR = here .. "vendor/fugit2"

local vendor_cache = {}

local function vendored_require(name)
  local cached = vendor_cache[name]
  if cached ~= nil then
    return cached
  end

  local rel = name:gsub("%.", "/")
  local path = ("%s/%s.lua"):format(VENDOR, rel)
  local chunk = assert(loadfile(path), "vendored module not found: " .. name)

  -- LuaJIT 5.1 semantics: give the chunk an environment whose `require`
  -- resolves fugit2.* against the vendor dir and falls back to real globals
  -- (ffi, bit, vim, table.new via global require) for everything else.
  local env
  env = setmetatable({
    require = function(modname)
      local inner = modname:match("^fugit2%.(.+)$")
      if inner then
        return vendored_require(inner)
      end
      return require(modname)
    end,
  }, {
    -- selene: allow(global_usage)
    __index = _G,
  })

  setfenv(chunk, env)

  local result = chunk()
  vendor_cache[name] = result
  return result
end

---Vendored binding modules (libgit2 cdef/enum layer and the OOP wrapper).
---@type table
M.binding = {
  libgit2 = function()
    return vendored_require("core.libgit2")
  end,
  git2 = function()
    return vendored_require("core.git2")
  end,
}

-- Additional public, ABI-stable APIs the vendored cdef omits (opaque types +
-- plain functions; declared here per ADR-0003's overlay-carries-changes
-- rule). Must run AFTER the vendored cdef, which owns the referenced
-- typedefs — hence lazy.
local extra_cdefs_done = false
local function ensure_extra_cdefs()
  if extra_cdefs_done then
    return
  end

  vendored_require("core.libgit2") -- registers git_repository/git_reference/git_object

  ffi.cdef([[
    typedef struct git_reference_iterator git_reference_iterator;
    void git_reference_iterator_free(git_reference_iterator *iter);

    typedef int (*git_reference_foreach_cb)(const char *name, void *payload);
    int git_reference_foreach_name(git_repository *repo, git_reference_foreach_cb callback, void *payload);

    int git_revparse_single(git_object **out, git_repository *repo, const char *spec);

    const git_index_entry *git_index_get_byindex(git_index *index, size_t n);

    int git_submodule_status(unsigned int *status, git_repository *repo, const char *name, unsigned int ignore);

    int git_object_short_id(git_buf *out, const git_object *obj);
  ]])

  extra_cdefs_done = true
end

--------------------------------------------------------------------------------
-- Version policy
--------------------------------------------------------------------------------

M.MINIMUM = { 1, 7 } -- lowest supported libgit2 (Ubuntu 24.04 LTS ships 1.7)
M.MAXIMUM_MAJOR = 1 -- 2.0 will change git_oid layout: hard-reject until adapted

local probed = nil
local original_lazy_loader = nil

local function soname_candidates()
  local config = require("neogit.config")
  local list = {}

  if config.values.libgit2_path then
    list[#list + 1] = config.values.libgit2_path
  end

  -- Explicit sonames depend only on the runtime package (no -dev needed).
  vim.list_extend(list, { "libgit2.so.1.9", "libgit2.so.1.8", "libgit2.so.1.7" })
  -- macOS (Homebrew keeps versioned dylibs in the cellar).
  vim.list_extend(list, { "libgit2.1.9.dylib", "libgit2.1.8.dylib", "libgit2.1.7.dylib" })
  -- Unversioned name: works on Arch / dev packages / brew default prefix.
  list[#list + 1] = "libgit2"

  return list
end

---Apply per-version corrections to the vendored enum tables.
---The vendor cdef is baseline 1.8; see .wayfinder/assets/libgit2-versions-report.md §3.2.
local function apply_version_overrides(minor)
  local lg2 = vendored_require("core.libgit2")

  if minor >= 9 then
    -- 1.9 reordered checkout strategies: SAFE is now 0 (was 1), NONE is
    -- 1u<<30 (was 0). Using the stale NONE=0 would silently select SAFE.
    lg2.GIT_CHECKOUT.SAFE = 0
    lg2.GIT_CHECKOUT.NONE = bit.lshift(1, 30)
  end

  if minor >= 8 then
    -- 1.8 inserted WORKTREE at level 6; APP moved to 7.
    lg2.GIT_CONFIG_LEVEL.WORKTREE = 6
    lg2.GIT_CONFIG_LEVEL.APP = 7
  end

  -- Known struct-layout caveats the consumers must respect (feature flags):
  --   blame_boundary: git_blame_hunk gained committer/summary fields in 1.9,
  --   so `boundary` reads garbage on >= 1.9 with the 1.8-baseline cdef.
  M.feature_flags = {
    blame_boundary = minor < 9,
    config_entry_level = minor >= 8, -- 1.7 layout differs at that offset
  }
end

---Probe for a usable system libgit2. Cached; pass { force = true } to retry.
---Never errors: failures are reported in the returned table.
---@param opts? { force?: boolean }
---@return { available: boolean, version?: string, major?: integer, minor?: integer, rev?: integer, path?: string, reason?: string, tried?: string[] }
function M.probe(opts)
  if probed and not (opts and opts.force) then
    return probed
  end

  local lg2 = vendored_require("core.libgit2")

  -- The vendored loader is lazy: M.C holds a self-metatable'd table whose
  -- __index ffi.loads M.library_path and rawsets the real handle onto M.C.
  -- To retry with another soname we must re-arm that lazy table (captured
  -- before any symbol access); nil-ing M.C would kill the loader entirely.
  if not original_lazy_loader then
    original_lazy_loader = lg2.C
  end

  local major, minor, rev = ffi.new("int[1]"), ffi.new("int[1]"), ffi.new("int[1]")
  local tried = {}
  local rejection = nil

  for _, candidate in ipairs(soname_candidates()) do
    tried[#tried + 1] = candidate
    lg2.C = original_lazy_loader
    lg2.libgit2_init_count = 0
    lg2.setup_lib(candidate)

    local ok = pcall(function()
      lg2.C.git_libgit2_version(major, minor, rev)
    end)

    if ok then
      if major[0] ~= M.MAXIMUM_MAJOR then
        rejection = ("libgit2 %d.%d.%d found at %q, but majors other than 1 are not supported (2.0 pending adaptation)"):format(
          major[0],
          minor[0],
          rev[0],
          candidate
        )
        -- another soname may still carry a 1.x — keep trying
      elseif minor[0] < M.MINIMUM[2] then
        rejection = ("libgit2 %d.%d.%d found at %q, but the minimum supported version is 1.%d"):format(
          major[0],
          minor[0],
          rev[0],
          candidate,
          M.MINIMUM[2]
        )
        -- an older soname will not help; keep trying anyway for a newer one
      else
        apply_version_overrides(minor[0])
        probed = {
          available = true,
          version = ("%d.%d.%d"):format(major[0], minor[0], rev[0]),
          major = major[0],
          minor = minor[0],
          rev = rev[0],
          path = candidate,
          tried = tried,
        }
        return probed
      end
    end
  end

  probed = {
    available = false,
    reason = rejection or ("no loadable libgit2 was found (tried: %s)"):format(table.concat(tried, ", ")),
    tried = tried,
  }
  return probed
end

--------------------------------------------------------------------------------
-- Executor seam + error mapping + repository access
--------------------------------------------------------------------------------

---Sync executor (P1). Every libgit2 call goes through here so a future
---uv.new_work implementation can replace it without touching callers.
---@param fn fun(): any
---@return any
function M.run(fn)
  return fn()
end

---Map a libgit2 return code / error into a backend-neutral GitResult,
---attaching the message from git_error_last() when available.
---@param err? integer libgit2 error code (non-zero)
---@param context? string
---@return GitResult
function M.git_result(err, context)
  local message
  local ok, git2 = pcall(vendored_require, "core.git2")
  if ok and git2.Error and git2.Error.last then
    local last = git2.Error.last()
    message = last and last.message
  end

  return GitResult.new(
    err or -1,
    ("%s%s"):format(context or "", message or ("libgit2 error " .. tostring(err)))
  )
end

---Open a repository handle. Callers own the handle's lifetime; see the
---refresh-cycle contract in migration spec §3.3 (open per cycle, share
---within, release at the end).
---@param path string
---@param search? boolean search parent directories for the git dir
---@return table? repository git2.Repository
---@return integer? err
function M.open_repo(path, search)
  ensure_extra_cdefs()
  local git2 = vendored_require("core.git2")
  local repo, err = git2.Repository.open(path, search)

  if not repo then
    -- Every libgit2 query and refresh path funnels through here, so an open
    -- failure is the root cause of most twin degradations: record the
    -- libgit2 error text (git_error_last) for post-mortem analysis.
    logger.warn(("[GIT2]: open_repo failed for %q: %s"):format(tostring(path), M.git_result(err, "").message))
  end

  return repo, err
end

---Run `fn` against a freshly opened repository (single-shot queries; the
---refresh path shares one handle per cycle instead — see libgit2/init.lua).
---@param path string
---@param fn fun(repo: table): any
---@return any
function M.with_repo(path, fn)
  local repo = M.open_repo(path, true)
  if not repo then
    return nil
  end

  return fn(repo)
end

---Resolve any revspec ("HEAD", "HEAD~2", branch name, oid) to a full hex oid.
---@param repo table git2.Repository wrapper
---@param spec string
---@return string? oid hex string, or nil when the spec does not resolve
function M.oid_of(repo, spec)
  ensure_extra_cdefs()
  local lg2 = vendored_require("core.libgit2")
  local obj = ffi.new("git_object*[1]")
  local err = lg2.C.git_revparse_single(obj, repo.repo, spec)
  if err ~= 0 then
    return nil
  end

  local oid_ptr = lg2.C.git_object_id(obj[0])
  local hex = ffi.string(lg2.C.git_oid_tostr_s(oid_ptr))
  lg2.C.git_object_free(obj[0])
  return hex
end

---Full hex string of a raw git_oid cdata.
---@param oid_cdata ffi.cdata
---@return string
function M.oid_hex(oid_cdata)
  local lg2 = vendored_require("core.libgit2")
  return ffi.string(lg2.C.git_oid_tostr_s(oid_cdata))
end

---Resolve a revspec and look up the resulting commit.
---@param repo table git2.Repository wrapper
---@param spec string revspec
---@return table? commit git2.Commit wrapper
function M.commit_of(repo, spec)
  local hex = M.oid_of(repo, spec)
  if not hex then
    return nil
  end

  local oid = M.binding.git2().ObjectId.from_string(hex)
  local commit = repo:commit_lookup(oid)
  return commit
end

---Iterate all reference names in the repository, calling `fn(name)`.
---Return false from `fn` to stop early. (libgit2 1.9 removed the iterator
---`next` calls, so foreach_name is the portable iteration API.)
---@param repo table git2.Repository wrapper
---@param fn fun(name: string): boolean?
function M.each_ref_name(repo, fn)
  ensure_extra_cdefs()
  local lg2 = vendored_require("core.libgit2")

  local cb = ffi.cast("git_reference_foreach_cb", function(name)
    if fn(ffi.string(name)) == false then
      return 1
    end
    return 0
  end)

  pcall(function()
    lg2.C.git_reference_foreach_name(repo.repo, cb, nil)
  end)

  cb:free()
end

return M
