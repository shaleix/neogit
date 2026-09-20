-- libgit2 twins for index-writing operations (migration spec §3.4):
-- stage/unstage and `checkout -- file` become zero-spawn.
--
-- Divergence: reverse-applying a patch (hunk unstage / discard) has no
-- libgit2 equivalent — those fall back to the CLI backend by design.
local git2 = require("neogit.lib.git2")
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
local function stage_paths(repo, index, files)
  local lg2 = git2.binding.libgit2()
  local ffi = require("ffi")

  for _, path in ipairs(files) do
    if vim.fn.filereadable(worktree_root() .. "/" .. path) == 1 then
      lg2.C.git_index_add_bypath(index.index, path)
    else
      -- staging a deleted file removes it from the index (git add semantics)
      lg2.C.git_index_remove_bypath(index.index, path)
    end
  end

  lg2.C.git_index_write(index.index)
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
    return {}
  end

  local paths = {}
  local count = tonumber(lg2.C.git_status_list_entrycount(list[0])) or 0
  for i = 0, count - 1 do
    local entry = lg2.C.git_status_byindex(list[0], i)
    local st = tonumber(entry.status)
    local changed =
      bit.band(st, lg2.GIT_STATUS.WT_MODIFIED) ~= 0
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

---@param files string[]
function M.stage(files)
  git2.with_repo(worktree_root(), function(repo)
    local index, err = repo:index()
    if not index then
      return
    end

    stage_paths(repo, index, files)
  end)
end

---@param paths string[] tracked paths with worktree changes (git add -u)
function M.stage_paths_modified(paths)
  git2.with_repo(worktree_root(), function(repo)
    local index = repo:index()
    if not index then
      return
    end

    stage_paths(repo, index, paths)
  end)
end

---`git add -u`
function M.stage_modified()
  git2.with_repo(worktree_root(), function(repo)
    local index = repo:index()
    if not index then
      return
    end

    stage_paths(repo, index, worktree_changed_paths(repo, false))
  end)
end

---`git add -A`
function M.stage_all()
  git2.with_repo(worktree_root(), function(repo)
    local index = repo:index()
    if not index then
      return
    end

    stage_paths(repo, index, worktree_changed_paths(repo, true))
  end)
end

---`git reset -- <paths>`: reset index entries to HEAD.
---@param files string[]
function M.reset_files(files)
  git2.with_repo(worktree_root(), function(repo)
    repo:reset_default(files)
  end)
end

---`git reset`: reset the whole index to HEAD.
function M.reset_all()
  git2.with_repo(worktree_root(), function(repo)
    local lg2 = git2.binding.libgit2()
    local ffi = require("ffi")

    local index = repo:index()
    if not index then
      return
    end

    local count = tonumber(lg2.C.git_index_entrycount(index.index)) or 0
    local paths = {}
    for i = 0, count - 1 do
      local entry = lg2.C.git_index_get_byindex(index.index, i)
      if entry ~= nil then
        paths[#paths + 1] = ffi.string(entry.path)
      end
    end

    if #paths > 0 then
      repo:reset_default(paths)
    end
  end)
end

--------------------------------------------------------------------------------
-- checkout -- <files> (restore worktree files from the index)
--------------------------------------------------------------------------------

---@param files string[]
function M.checkout_files(files)
  git2.with_repo(worktree_root(), function(repo)
    local lg2 = git2.binding.libgit2()
    local ffi = require("ffi")

    local index = repo:index()
    if not index then
      return
    end

    local opts = ffi.new("git_checkout_options[1]", lg2.GIT_CHECKOUT_OPTIONS_INIT)
    opts[0].checkout_strategy = lg2.GIT_CHECKOUT.FORCE

    local paths_spec = c_strarray(files)
    opts[0].paths.strings = paths_spec.strarray.strings
    opts[0].paths.count = paths_spec.strarray.count

    lg2.C.git_checkout_index(repo.repo, index.index, opts)
  end)
end

--------------------------------------------------------------------------------
-- forward patch application (hunk stage etc.); reverse falls back to CLI
--------------------------------------------------------------------------------

---@param patch string unified diff, as produced by neogit's hunk serializer
---@param opts? { cached?: boolean, index?: boolean }
---@return boolean applied
function M.apply_patch(patch, opts)
  opts = opts or {}

  return git2.with_repo(worktree_root(), function(repo)
    local lg2 = git2.binding.libgit2()
    local git2mod = git2.binding.git2()
    local ffi = require("ffi")

    local diff_out = ffi.new("git_diff*[1]")
    if lg2.C.git_diff_from_buffer(diff_out, patch, #patch) ~= 0 then
      return false
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

    return err == 0
  end) == true
end

return M
