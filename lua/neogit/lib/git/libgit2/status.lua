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

local M = {}

local function worktree_root()
  return require("neogit.lib.git").repo.worktree_root
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
  ADDED = "N", -- new in index; porcelain "A" with zero head oid renders as "N"
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
    return "UU"
  end

  return conflict_letter(ancestor[0] ~= nil, ours[0] ~= nil)
    .. conflict_letter(ancestor[0] ~= nil, theirs[0] ~= nil)
end

---update_status twin. Signature matches the update_* contract plus ctx.
---@param state NeogitRepoState
---@param filter table
---@param ctx { repo: table? }?
function M.update_status(state, filter, ctx)  local status = require("neogit.lib.git.status")
  local old_files = {
    staged_files = status.internal.item_collection(state, "staged", filter),
    unstaged_files = status.internal.item_collection(state, "unstaged", filter),
    untracked_files = status.internal.item_collection(state, "untracked", filter),
  }

  state.staged.items = {}
  state.untracked.items = {}
  state.unstaged.items = {}

  git2.run(function()
    local repo = (ctx and ctx.repo) or git2.open_repo(worktree_root(), true)
    if not repo then
      return
    end

    local lg2 = git2.binding.libgit2()
    local ffi = require("ffi")

    -- Worktree file modes for file_mode pairing (porcelain gives mH/mI/mW per path).
    local opts = ffi.new("git_status_options[1]", lg2.GIT_STATUS_OPTIONS_INIT)
    opts[0].show = lg2.GIT_STATUS_SHOW.INDEX_AND_WORKDIR
    opts[0].flags = bit.bor(
      lg2.GIT_STATUS_OPT.INCLUDE_UNTRACKED,
      lg2.GIT_STATUS_OPT.RENAMES_HEAD_TO_INDEX,
      lg2.GIT_STATUS_OPT.RENAMES_INDEX_TO_WORKDIR,
      lg2.GIT_STATUS_OPT.SORT_CASE_SENSITIVELY
    )

    local list = ffi.new("git_status_list*[1]")
    if lg2.C.git_status_list_new(list, repo.repo, opts) ~= 0 then
      return
    end

    local delta_names = {}
    for k, v in pairs(lg2.GIT_DELTA) do
      delta_names[tonumber(v)] = k
    end

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
            status.internal.update_file("unstaged", state.worktree_root, old_files.unstaged_files[name], mode, name)
          )
        else
          local orig = nil
          local dm = delta_names[tonumber(i2w.status)]
          if dm == "RENAMED" then
            orig = ffi.string(i2w.old_file.path)
          end

          local mode = DELTA_TO_MODE[dm] or "M"
          if mode == "N" then
            mode = "M" -- worktree additions arrive as untracked, never "N"
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
                nil,
                nil
              )
            )
          end
        end
      end
    end

    lg2.C.git_status_list_free(list[0])
  end)
end

-- Quick checks replacing the porcelain scans in anything_staged/unstaged.
local function any_worktree_change(repo, staged)
  local lg2 = git2.binding.libgit2()
  local ffi = require("ffi")
  local bit_ = require("bit")

  local opts = ffi.new("git_status_options[1]", lg2.GIT_STATUS_OPTIONS_INIT)
  opts[0].show = lg2.GIT_STATUS_SHOW.INDEX_AND_WORKDIR

  local list = ffi.new("git_status_list*[1]")
  if lg2.C.git_status_list_new(list, repo.repo, opts) ~= 0 then
    return false
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

---@return boolean
function M.anything_staged()
  return git2.with_repo(worktree_root(), function(repo)
    return any_worktree_change(repo, true)
  end) == true
end

---@return boolean
function M.anything_unstaged()
  return git2.with_repo(worktree_root(), function(repo)
    return any_worktree_change(repo, false)
  end) == true
end

return M
