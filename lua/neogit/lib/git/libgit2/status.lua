-- libgit2 twin of git.status.update_status: fills state.{staged,unstaged,untracked}
-- from one git_status_list_new pass, matching porcelain-v2 item semantics.
--
-- Divergences from the CLI backend (by design, migration spec §3.2):
--   * worktree renames are reported as a single "R" item with original_name
--     (rich model); the CLI backend shows "D" + "?" as two items
--   * submodule flags (item.submodule) are not populated (submodules stay
--     out of scope)
local git2 = require("neogit.lib.git2")
local bit = require("bit")
local ffi = require("ffi")
local logger = require("neogit.logger")
local config = require("neogit.config")

local M = {}

local function worktree_root()
  return require("neogit.lib.git").repo.worktree_root
end

---Per-file +N/-M counts for one git_diff, keyed by the delta's new path
---(what numstat prints for adds/modifies/renames; deleted files keep the
---same path on both sides). Binary deltas are skipped to match `git diff
-----numstat`, which prints "-" for them. Assumes rename detection has
---already run on the diff (find_similar below).
---@param lg2 table vendored libgit2 binding module
---@param diff ffi.cdata* git_diff*
---@return table<string, {additions: number, deletions: number}>
local function diff_numstat(lg2, diff)
  local counts = {}
  local n = tonumber(lg2.C.git_diff_num_deltas(diff)) or 0

  for i = 0, n - 1 do
    local delta = lg2.C.git_diff_get_delta(diff, i)
    if delta ~= nil and bit.band(delta.flags, lg2.GIT_DIFF_FLAG.BINARY) == 0 then
      local patch = ffi.new("git_patch*[1]")
      if lg2.C.git_patch_from_diff(patch, diff, i) == 0 then
        local add, del = ffi.new("size_t[1]"), ffi.new("size_t[1]")
        if lg2.C.git_patch_line_stats(nil, add, del, patch[0]) == 0 then
          local path = delta.new_file.path
          if path == nil or path[0] == 0 then
            path = delta.old_file.path
          end
          counts[ffi.string(path)] = { additions = tonumber(add[0]), deletions = tonumber(del[0]) }
        end
        lg2.C.git_patch_free(patch[0])
      end
    end
  end

  return counts
end

---Both numstat maps in-process: staged = HEAD-tree <-> index, unstaged =
---index <-> workdir. Rename detection runs on both diffs so renamed paths
---key the same new path (with 0/0 counts for pure renames) as the CLI's
---numstat output. An unborn HEAD (no HEAD^{tree}) diffs against the empty
---tree, which is what `git diff --cached` does too.
---@param repo table git2 repository wrapper
---@param lg2 table vendored libgit2 binding module
---@return table unstaged map
---@return table staged map
local function numstat_maps(repo, lg2)
  local head_tree = ffi.new("git_object*[1]")
  local have_head = lg2.C.git_revparse_single(head_tree, repo.repo, "HEAD^{tree}") == 0

  local opts = ffi.new("git_diff_options[1]", lg2.GIT_DIFF_OPTIONS_INIT)
  local find = ffi.new("git_diff_find_options[1]", lg2.GIT_DIFF_FIND_OPTIONS_INIT)
  find[0].flags = lg2.GIT_DIFF_FIND.FIND_RENAMES

  local staged_counts, unstaged_counts = {}, {}

  local diff = ffi.new("git_diff*[1]")
  local head_tree_ptr = have_head and ffi.cast("git_tree*", head_tree[0]) or nil
  if lg2.C.git_diff_tree_to_index(diff, repo.repo, head_tree_ptr, nil, opts) == 0 then
    lg2.C.git_diff_find_similar(diff[0], find)
    staged_counts = diff_numstat(lg2, diff[0])
    lg2.C.git_diff_free(diff[0])
  end

  if lg2.C.git_diff_index_to_workdir(diff, repo.repo, nil, opts) == 0 then
    lg2.C.git_diff_find_similar(diff[0], find)
    unstaged_counts = diff_numstat(lg2, diff[0])
    lg2.C.git_diff_free(diff[0])
  end

  if have_head then
    lg2.C.git_object_free(head_tree[0])
  end

  return unstaged_counts, staged_counts
end

-- porcelain letter for one side of an unmerged path
-- side present -> base ? "U" : "A" ; side absent -> base ? "D" : "U"
local function conflict_letter(has_base, has_side)
  if has_side then
    return has_base and "U" or "A"
  end
  return has_base and "D" or "U"
end

local DELTA_TO_MODE = {
  ADDED = "A", -- new in index; porcelain "A" (previously rewritten to "N")
  MODIFIED = "M",
  DELETED = "D",
  RENAMED = "R",
  TYPECHANGE = "T",
  COPIED = "C",
}

---@param repo table git2.Repository wrapper
---@param index table git2.Index wrapper
---@param path string
---@return string mode two-character porcelain unmerged code
local function conflict_mode(index, path)
  local lg2 = git2.binding.libgit2()
  local ffi = require("ffi")

  local ancestor = ffi.new("const git_index_entry*[1]")
  local ours = ffi.new("const git_index_entry*[1]")
  local theirs = ffi.new("const git_index_entry*[1]")

  local ok = pcall(function()
    lg2.C.git_index_conflict_get(ancestor, ours, theirs, index.index, path)
  end)

  if not ok then
    logger.debug(("[LG2:STATUS]: git_index_conflict_get failed for %q - assuming UU"):format(path))
    return "UU"
  end

  return conflict_letter(ancestor[0] ~= nil, ours[0] ~= nil)
    .. conflict_letter(ancestor[0] ~= nil, theirs[0] ~= nil)
end

local SUBMODULE_MODE = 57344 -- 0o160000 (gitlink)

-- git_submodule_status bits (git_submodule.h; stable since 0.x)
local SM_INDEX_MODIFIED = 64 -- 1 << 6: index commit differs from HEAD
local SM_WD_INDEX_MODIFIED = 2048 -- 1 << 11: wd commit differs from index
local SM_WD_WD_MODIFIED = 4096 -- 1 << 12: modified tracked content inside
local SM_WD_UNTRACKED = 8192 -- 1 << 13: untracked files inside

local function submodule_flags(repo, path)
  local lg2 = git2.binding.libgit2()
  local ffi = require("ffi")

  local out = ffi.new("unsigned int[1]")
  local ok = pcall(function()
    lg2.C.git_submodule_status(out, repo.repo, path, 0)
  end)

  if not ok then
    logger.debug(("[LG2:STATUS]: git_submodule_status failed for %q - dropping submodule flags"):format(path))
    return nil
  end

  local st = tonumber(out[0]) or 0
  return {
    commit_changed = bit.band(st, SM_INDEX_MODIFIED) ~= 0 or bit.band(st, SM_WD_INDEX_MODIFIED) ~= 0,
    has_tracked_changes = bit.band(st, SM_WD_WD_MODIFIED) ~= 0,
    has_untracked_changes = bit.band(st, SM_WD_UNTRACKED) ~= 0,
  }
end

---update_status twin. Signature matches the update_* contract plus ctx.
---
---Failure contract: every fallible call (repo open, status list) happens
---BEFORE any state mutation and raises on failure, so Repo:tasks can log
---the error and re-run this module on the CLI backend with the previous
---state (and its diff caches) intact.
---@param state NeogitRepoState
---@param filter table
---@param ctx { repo: table? }?
function M.update_status(state, filter, ctx)
  local status = require("neogit.lib.git.status")

  -- Populated inside the git2.run callback below; applied to items after
  -- the executor returns (see the attach comment at the end of the twin).
  local numstat = { enabled = false }

  git2.run(function()
    local repo = (ctx and ctx.repo) or git2.open_repo(worktree_root(), true)
    if not repo then
      error(("libgit2: cannot open repository at %q"):format(worktree_root()))
    end

    local lg2 = git2.binding.libgit2()
    local ffi = require("ffi")

    -- Worktree file modes for file_mode pairing (porcelain gives mH/mI/mW per path).
    local opts = ffi.new("git_status_options[1]", lg2.GIT_STATUS_OPTIONS_INIT)
    opts[0].show = lg2.GIT_STATUS_SHOW.INDEX_AND_WORKDIR
    opts[0].flags = bit.bor(
      lg2.GIT_STATUS_OPT.INCLUDE_UNTRACKED,
      lg2.GIT_STATUS_OPT.RECURSE_UNTRACKED_DIRS,
      lg2.GIT_STATUS_OPT.RENAMES_HEAD_TO_INDEX,
      lg2.GIT_STATUS_OPT.RENAMES_INDEX_TO_WORKDIR,
      lg2.GIT_STATUS_OPT.SORT_CASE_SENSITIVELY
    )

    local list = ffi.new("git_status_list*[1]")
    if lg2.C.git_status_list_new(list, repo.repo, opts) ~= 0 then
      error(git2.git_result(nil, "libgit2: git_status_list_new failed: ").message)
    end

    -- Past every fallible boundary: only now start mutating state, so a
    -- mid-loop surprise still leaves the CLI fallback with coherent data.
    local old_files = {
      staged_files = status.internal.item_collection(state, "staged", filter),
      unstaged_files = status.internal.item_collection(state, "unstaged", filter),
      untracked_files = status.internal.item_collection(state, "untracked", filter),
    }

    state.staged.items = {}
    state.untracked.items = {}
    state.unstaged.items = {}

    local delta_names = {}
    for k, v in pairs(lg2.GIT_DELTA) do
      delta_names[tonumber(v)] = k
    end

    -- HEAD modes by path (for file_mode pairing on unstaged items).
    local head_modes = {}
    local index = nil
    local function ensure_index()
      if index == nil then
        index = repo:index()
      end
      return index
    end

    local count = tonumber(lg2.C.git_status_list_entrycount(list[0])) or 0
    for i = 0, count - 1 do
      local entry = lg2.C.git_status_byindex(list[0], i)

      if entry.head_to_index ~= nil then
        head_modes[ffi.string(entry.head_to_index.new_file.path)] = ("%o"):format(
          tonumber(entry.head_to_index.old_file.mode) or 0
        )
      end
    end

    for i = 0, count - 1 do
      local entry = lg2.C.git_status_byindex(list[0], i)
      local flags = tonumber(entry.status)

      local h2i = entry.head_to_index
      local i2w = entry.index_to_workdir

      local function mode_of(delta_file)
        return ("%o"):format(tonumber(delta_file.mode) or 0)
      end

      -- staged side (head -> index)
      if h2i ~= nil then
        local name = ffi.string(h2i.new_file.path)
        local orig = nil
        local dm = delta_names[tonumber(h2i.status)]
        if dm == "RENAMED" or dm == "COPIED" then
          orig = ffi.string(h2i.old_file.path)
        end

        local file_mode = {
          head = mode_of(h2i.old_file),
          index = mode_of(h2i.new_file),
          worktree = mode_of(h2i.new_file),
        }

        table.insert(
          state.staged.items,
          status.internal.update_file(
            "staged",
            state.worktree_root,
            old_files.staged_files[name],
            DELTA_TO_MODE[dm] or "M",
            name,
            orig,
            file_mode,
            nil
          )
        )
      end

      -- worktree side (index -> workdir)
      if i2w ~= nil then
        local name = ffi.string(i2w.new_file.path)

        -- file_mode triple like porcelain mH/mI/mW (for the mode-change display)
        local wt_file_mode = {
          head = head_modes[name] or mode_of(i2w.old_file),
          index = mode_of(i2w.old_file),
          worktree = mode_of(i2w.new_file),
        }

        -- submodule rows: porcelain's S<cmu> flags
        local submodule = nil
        local old_mode = tonumber(i2w.old_file.mode) or 0
        local new_mode = tonumber(i2w.new_file.mode) or 0
        if old_mode == SUBMODULE_MODE or new_mode == SUBMODULE_MODE then
          submodule = submodule_flags(repo, name)
        end

        if bit.band(flags, lg2.GIT_STATUS.WT_NEW) ~= 0 then
          table.insert(
            state.untracked.items,
            status.internal.update_file(
              "untracked",
              state.worktree_root,
              old_files.untracked_files[name],
              "?",
              name
            )
          )
        elseif bit.band(flags, lg2.GIT_STATUS.CONFLICTED) ~= 0 then
          local idx = ensure_index()
          local mode = idx and conflict_mode(idx, name) or "UU"
          table.insert(
            state.unstaged.items,
            status.internal.update_file(
              "unstaged",
              state.worktree_root,
              old_files.unstaged_files[name],
              mode,
              name,
              nil,
              wt_file_mode,
              submodule
            )
          )
        else
          local orig = nil
          local dm = delta_names[tonumber(i2w.status)]
          if dm == "RENAMED" then
            orig = ffi.string(i2w.old_file.path)
          end

          local mode = DELTA_TO_MODE[dm] or "M"
          if mode == "N" or mode == "A" then
            mode = "M" -- worktree additions arrive as untracked, never "N"/"A"
          end

          if mode ~= nil then
            table.insert(
              state.unstaged.items,
              status.internal.update_file(
                "unstaged",
                state.worktree_root,
                old_files.unstaged_files[name],
                mode,
                name,
                orig,
                wt_file_mode,
                submodule
              )
            )
          end
        end
      end
    end

    lg2.C.git_status_list_free(list[0])

    -- Per-file +N/-M counts in-process (replaces the two `git diff
    -- --numstat` spawns the CLI attach makes): build the same two diffs
    -- (HEAD-tree <-> index, index <-> workdir), run rename detection to
    -- match the status deltas, then take whole-patch line stats. Binary
    -- deltas are skipped (CLI numstat prints "-" for them). Failure is
    -- tolerated: nil maps leave item.stats unset, like a failed CLI numstat.
    if config.values.status.file_line_counts then
      numstat.enabled = true
      local ok, unstaged_counts, staged_counts = pcall(numstat_maps, repo, lg2)
      if ok then
        numstat.unstaged = unstaged_counts
        numstat.staged = staged_counts
      else
        numstat.failed = tostring(unstaged_counts)
      end
    end
  end)

  -- Attach per-file +N/-M line counts OUTSIDE the git2.run callback: the
  -- staged/unstaged item lists are final once the executor returns, and
  -- control is back in the caller's coroutine on the Neovim main loop. The
  -- git2.run seam (git2.lua, "Executor seam") currently executes its
  -- callback synchronously on the main thread, but reserves a uv.new_work
  -- replacement that would run the callback in a worker thread -- where
  -- neither vim APIs nor (now) any CLI numstat fallback would be safe.
  -- In-process counts computed inside the callback survive that move.
  if not numstat.enabled then
    return
  end

  if numstat.failed then
    status.attach_file_stats(state)
  else
    for _, item in ipairs(state.unstaged.items) do
      item.stats = numstat.unstaged[item.name]
    end
    for _, item in ipairs(state.staged.items) do
      item.stats = numstat.staged[item.name]
    end
  end
end

-- Quick checks replacing the porcelain scans in anything_staged/unstaged.
-- Returns nil (not false) when libgit2 cannot serve the query, so callers
-- can distinguish "no changes" from "unknown" and fall back to the CLI.
local function any_worktree_change(repo, staged)
  local lg2 = git2.binding.libgit2()
  local ffi = require("ffi")
  local bit_ = require("bit")

  local opts = ffi.new("git_status_options[1]", lg2.GIT_STATUS_OPTIONS_INIT)
  opts[0].show = lg2.GIT_STATUS_SHOW.INDEX_AND_WORKDIR

  local list = ffi.new("git_status_list*[1]")
  if lg2.C.git_status_list_new(list, repo.repo, opts) ~= 0 then
    logger.debug(
      ("[LG2:STATUS]: git_status_list_new failed in anything_%s: %s"):format(
        staged and "staged" or "unstaged",
        git2.git_result(nil, "").message
      )
    )
    return nil
  end

  local mask
  if staged then
    mask = bit_.bor(
      lg2.GIT_STATUS.INDEX_NEW,
      lg2.GIT_STATUS.INDEX_MODIFIED,
      lg2.GIT_STATUS.INDEX_DELETED,
      lg2.GIT_STATUS.INDEX_RENAMED,
      lg2.GIT_STATUS.INDEX_TYPECHANGE
    )
  else
    mask = bit_.bor(
      lg2.GIT_STATUS.WT_MODIFIED,
      lg2.GIT_STATUS.WT_DELETED,
      lg2.GIT_STATUS.WT_RENAMED,
      lg2.GIT_STATUS.WT_TYPECHANGE
    )
  end

  local found = false
  local count = tonumber(lg2.C.git_status_list_entrycount(list[0])) or 0
  for i = 0, count - 1 do
    if bit_.band(tonumber(lg2.C.git_status_byindex(list[0], i).status), mask) ~= 0 then
      found = true
      break
    end
  end

  lg2.C.git_status_list_free(list[0])
  return found
end

---nil when libgit2 could not serve the query (dispatcher falls back to CLI).
---@return boolean?
function M.anything_staged()
  return git2.with_repo(worktree_root(), function(repo)
    return any_worktree_change(repo, true)
  end)
end

---nil when libgit2 could not serve the query (dispatcher falls back to CLI).
---@return boolean?
function M.anything_unstaged()
  return git2.with_repo(worktree_root(), function(repo)
    return any_worktree_change(repo, false)
  end)
end

return M
