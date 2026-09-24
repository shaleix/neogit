-- libgit2 twins for index-writing operations (migration spec §3.4):
-- stage/unstage and `checkout -- file` become zero-spawn.
--
-- Divergence: reverse-applying a patch (hunk unstage / discard) has no
-- libgit2 equivalent — those fall back to the CLI backend by design.
--
-- Result contract: every operation returns a GitResult (same shape the CLI
-- dispatchers wrap ProcessResult into), or nil when the repository could
-- not be opened - the dispatcher then falls back to the CLI. FFI failures
-- are logged with the mapped libgit2 error message before being returned.
local git2 = require("neogit.lib.git2")
local GitResult = require("neogit.lib.git.result")
local logger = require("neogit.logger")
local bit = require("bit")

local M = {}

local function worktree_root()
  return require("neogit.lib.git").repo.worktree_root
end

local function c_strarray(files)
  local ffi = require("ffi")
  local array = ffi.new("const char*[?]", #files)
  for i, f in ipairs(files) do
    array[i - 1] = f
  end

  local sa = ffi.new("git_strarray_readonly")
  sa.strings = array
  sa.count = #files

  -- keep the backing array referenced for as long as the struct is in use
  return { strarray = sa, keep = array }
end

---@param files string[]
---@return GitResult
local function stage_paths(_repo, index, files)
  local lg2 = git2.binding.libgit2()

  local first_err = 0
  for _, path in ipairs(files) do
    local code
    if vim.fn.filereadable(worktree_root() .. "/" .. path) == 1 then
      code = lg2.C.git_index_add_bypath(index.index, path)
    else
      -- staging a deleted file removes it from the index (git add semantics)
      code = lg2.C.git_index_remove_bypath(index.index, path)
    end

    if code ~= 0 and first_err == 0 then
      first_err = code
      logger.error(("[LG2:INDEX]: staging %q failed: %s"):format(path, git2.git_result(code, "").message))
    end
  end

  local write_err = lg2.C.git_index_write(index.index)
  if write_err ~= 0 then
    -- the index was not persisted: nothing staged actually took effect
    logger.error(("[LG2:INDEX]: index write failed: %s"):format(git2.git_result(write_err, "").message))
    if first_err == 0 then
      first_err = write_err
    end
  end

  if first_err ~= 0 then
    return git2.git_result(first_err, "staging failed: ")
  end

  return GitResult.new(0)
end

---Collect paths with worktree changes (tracked only, or including untracked).
local function worktree_changed_paths(repo, include_untracked)
  local lg2 = git2.binding.libgit2()
  local ffi = require("ffi")

  local opts = ffi.new("git_status_options[1]", lg2.GIT_STATUS_OPTIONS_INIT)
  opts[0].show = lg2.GIT_STATUS_SHOW.INDEX_AND_WORKDIR
  local flags = 0
  if include_untracked then
    flags = bit.bor(flags, lg2.GIT_STATUS_OPT.INCLUDE_UNTRACKED)
  end
  opts[0].flags = flags

  local list = ffi.new("git_status_list*[1]")
  if lg2.C.git_status_list_new(list, repo.repo, opts) ~= 0 then
    logger.error(("[LG2:INDEX]: git_status_list_new failed: %s"):format(git2.git_result(nil, "").message))
    return nil
  end

  local paths = {}
  local count = tonumber(lg2.C.git_status_list_entrycount(list[0])) or 0
  for i = 0, count - 1 do
    local entry = lg2.C.git_status_byindex(list[0], i)
    local st = tonumber(entry.status)
    local changed = bit.band(st, lg2.GIT_STATUS.WT_MODIFIED) ~= 0
      or bit.band(st, lg2.GIT_STATUS.WT_DELETED) ~= 0
      or (include_untracked and bit.band(st, lg2.GIT_STATUS.WT_NEW) ~= 0)

    if changed and entry.index_to_workdir ~= nil then
      paths[#paths + 1] = ffi.string(entry.index_to_workdir.new_file.path)
    end
  end

  lg2.C.git_status_list_free(list[0])
  return paths
end

--------------------------------------------------------------------------------
-- stage / unstage
--------------------------------------------------------------------------------

-- Shared prologue: open repo + index, or report why we could not.
-- Returns (repo, index) or (nil, GitResult|nil) - nil result means the
-- repository itself could not be opened (dispatcher falls back to CLI).
local function with_index(fn)
  return git2.with_repo(worktree_root(), function(repo)
    local index = repo:index()
    if not index then
      return git2.git_result(-1, "libgit2: cannot read the index: ")
    end

    return fn(repo, index)
  end)
end

---@param files string[]
---@return GitResult? nil when the repository could not be opened
function M.stage(files)
  return with_index(function(repo, index)
    return stage_paths(repo, index, files)
  end)
end

---@param paths string[] tracked paths with worktree changes (git add -u)
---@return GitResult?
function M.stage_paths_modified(paths)
  return with_index(function(repo, index)
    return stage_paths(repo, index, paths)
  end)
end

---`git add -u`
---@return GitResult?
function M.stage_modified()
  return with_index(function(repo, index)
    local paths = worktree_changed_paths(repo, false)
    if not paths then
      return git2.git_result(-1, "libgit2: status list failed while collecting modified paths")
    end

    return stage_paths(repo, index, paths)
  end)
end

---`git add -A`
---@return GitResult?
function M.stage_all()
  return with_index(function(repo, index)
    local paths = worktree_changed_paths(repo, true)
    if not paths then
      return git2.git_result(-1, "libgit2: status list failed while collecting changed paths")
    end

    return stage_paths(repo, index, paths)
  end)
end

---`git reset -- <paths>`: reset index entries to HEAD.
---@param files string[]
---@return GitResult?
function M.reset_files(files)
  return git2.with_repo(worktree_root(), function(repo)
    local err = repo:reset_default(files)
    if err and err ~= 0 then
      logger.error(("[LG2:INDEX]: reset failed: %s"):format(git2.git_result(err, "").message))
      return git2.git_result(err, "reset failed: ")
    end

    return GitResult.new(0)
  end)
end

---`git reset`: reset the whole index to HEAD.
---@return GitResult?
function M.reset_all()
  return with_index(function(repo, index)
    local lg2 = git2.binding.libgit2()
    local ffi = require("ffi")

    local count = tonumber(lg2.C.git_index_entrycount(index.index)) or 0
    local paths = {}
    for i = 0, count - 1 do
      local entry = lg2.C.git_index_get_byindex(index.index, i)
      if entry ~= nil then
        paths[#paths + 1] = ffi.string(entry.path)
      end
    end

    if #paths == 0 then
      return GitResult.new(0)
    end

    local err = repo:reset_default(paths)
    if err and err ~= 0 then
      logger.error(("[LG2:INDEX]: reset failed: %s"):format(git2.git_result(err, "").message))
      return git2.git_result(err, "reset failed: ")
    end

    return GitResult.new(0)
  end)
end

--------------------------------------------------------------------------------
-- checkout -- <files> (restore worktree files from the index)
--------------------------------------------------------------------------------

---@param files string[]
---@return GitResult?
function M.checkout_files(files)
  return with_index(function(repo, index)
    local lg2 = git2.binding.libgit2()
    local ffi = require("ffi")

    local opts = ffi.new("git_checkout_options[1]", lg2.GIT_CHECKOUT_OPTIONS_INIT)
    opts[0].checkout_strategy = lg2.GIT_CHECKOUT.FORCE

    local paths_spec = c_strarray(files)
    opts[0].paths.strings = paths_spec.strarray.strings
    opts[0].paths.count = paths_spec.strarray.count

    local err = lg2.C.git_checkout_index(repo.repo, index.index, opts)
    if err ~= 0 then
      logger.error(("[LG2:INDEX]: checkout failed: %s"):format(git2.git_result(err, "").message))
      return git2.git_result(err, "checkout failed: ")
    end

    return GitResult.new(0)
  end)
end

--------------------------------------------------------------------------------
-- forward patch application (hunk stage etc.); reverse falls back to CLI
--------------------------------------------------------------------------------

---neogit's generate_patch emits bare traditional diffs (---/+++/@@ only),
---which `git apply` accepts but libgit2's git_diff_from_buffer does not;
---synthesize the git-style header when missing, and clamp hunk start lines
---of 0 to 1 (generate_patch prints "+0,N" for new files; git tolerates,
---libgit2 rejects).
local function normalize_patch(patch)
  -- hunk "@@ -a,b +c,d @@" with c == 0 and a non-empty count -> c = 1
  patch = patch:gsub("\n@@ (%-)(%d+)(,?%d*) (%+)(%d+)(,?%d*) @@", function(a, b, bc, p, c, cc)
    if c == "0" and cc ~= "" and cc ~= "0" then
      c = "1"
    end
    return "\n@@ " .. a .. b .. bc .. " " .. p .. c .. cc .. " @@"
  end)

  -- NB: "-" is a pattern quantifier; the literal header dashes must be escaped.
  if patch:match("^diff %-%-git ") then
    return patch
  end

  local old = patch:match("^%-%-%- ([^\n]+)") or patch:match("\n%-%-%- ([^\n]+)") or "/dev/null"
  local new = patch:match("^%+%+%+ ([^\n]+)") or patch:match("\n%+%+%+ ([^\n]+)") or "/dev/null"
  local path = new ~= "/dev/null" and (new:match("^b/(.+)$") or new) or (old:match("^a/(.+)$") or old)

  local header = { ("diff --git a/%s b/%s"):format(path, path) }
  if old == "/dev/null" then
    header[#header + 1] = "new file mode 100644"
  end
  if new == "/dev/null" then
    header[#header + 1] = "deleted file mode 100644"
  end

  return table.concat(header, "\n") .. "\n" .. patch
end

---A "@@ -0,0 ..." hunk means the old side is empty (new file), but
---generate_patch still prints "--- a/<path>"; libgit2 then parses the delta
---as a MODIFY of a path that is not in the index and fails. Canonicalize
---such patches to the /dev/null + "new file mode" shape.
local function canonicalize_new_file(patch)
  if not (patch:match("\n@@ %-0,0 ") or patch:match("^@@ %-0,0 ")) then
    return patch
  end

  if not patch:match("\nnew file mode %d+\n") then
    patch = patch:gsub("^(diff %-%-git [^\n]+)\n", "%1\nnew file mode 100644\n", 1)
  end
  patch = patch:gsub("\n%-%-%- a/[^\n]+\n", "\n--- /dev/null\n", 1)
  return patch
end

---@param patch string unified diff, as produced by neogit's hunk serializer
---@param opts? { cached?: boolean, index?: boolean }
---@return GitResult? nil when the repository could not be opened
function M.apply_patch(patch, opts)
  opts = opts or {}

  return git2.with_repo(worktree_root(), function(repo)
    local lg2 = git2.binding.libgit2()
    local git2mod = git2.binding.git2()
    local ffi = require("ffi")

    patch = normalize_patch(patch)
    patch = canonicalize_new_file(patch)

    local diff_out = ffi.new("git_diff*[1]")
    if lg2.C.git_diff_from_buffer(diff_out, patch, #patch) ~= 0 then
      local result = git2.git_result(nil, "libgit2: patch parse failed: ")
      logger.debug("[LG2:INDEX]: " .. result.message)
      return result
    end

    local diff = git2mod.Diff.new(diff_out[0])
    local err
    if opts.cached then
      err = repo:apply_index(diff)
    elseif opts.index then
      err = repo:apply_workdir_index(diff)
    else
      err = repo:apply_workdir(diff)
    end

    if err ~= 0 then
      local result = git2.git_result(err, "libgit2: patch application failed: ")
      logger.debug("[LG2:INDEX]: " .. result.message)
      return result
    end

    return GitResult.new(0)
  end)
end

return M
