local Path = require("neogit.lib.path")
local git = require("neogit.lib.git")
local util = require("neogit.lib.util")
local Collection = require("neogit.lib.collection")
local logger = require("neogit.logger")
local config = require("neogit.config")
local GitResult = require("neogit.lib.git.result")
local libgit2 = require("neogit.lib.git.libgit2")

---@class NeogitGitStatus
local M = {}

---@class StatusItem
---@field mode string
---@field diff Diff
---@field stats { additions: number, deletions: number }|nil Per-file +N/-M line counts from a bulk `git diff --numstat` call at refresh time (unstaged items: worktree diff; staged items: cached diff); nil for untracked/unmerged or when status.file_line_counts is off
---@field absolute_path string
---@field original_name string|nil
---@field file_mode {head: number, index: number, worktree: number}|nil
---@field submodule SubmoduleStatus|nil
---@field name string
---@field first number
---@field last number
---@field oid string|nil optional object id
---@field commit CommitLogEntry|nil optional object id
---@field folded boolean|nil
---@field hunks Hunk[]|nil

---@class SubmoduleStatus
---@field commit_changed boolean C
---@field has_tracked_changes boolean M
---@field has_untracked_changes boolean U

---@param status string
-- <sub>       A 4 character field describing the submodule state.
--             "N..." when the entry is not a submodule.
--             "S<c><m><u>" when the entry is a submodule.
--             <c> is "C" if the commit changed; otherwise ".".
--             <m> is "M" if it has tracked changes; otherwise ".".
--             <u> is "U" if there are untracked changes; otherwise ".".
local function parse_submodule_status(status)
  local a, b, c, d = status:match("(.)(.)(.)(.)")
  if a == "N" then
    return nil
  else
    return {
      commit_changed = b == "C",
      has_tracked_changes = c == "M",
      has_untracked_changes = d == "U",
    }
  end
end

---@return StatusItem
local function update_file(section, cwd, file, mode, name, original_name, file_mode, submodule)
  local absolute_path = Path:new(cwd, name):absolute()

  local item = { --[[@class StatusItem]]
    mode = mode,
    name = name,
    original_name = original_name,
    absolute_path = absolute_path,
    file_mode = file_mode,
    submodule = submodule,
  }

  if file and rawget(file, "diff") then
    item.diff = file.diff
  else
    git.diff.build(section, item)
  end

  return item
end

local match_kind = "(.) (.+)"
local match_u = "(..) (....) (%d+) (%d+) (%d+) (%d+) (%w+) (%w+) (%w+) (.+)"
local match_1 = "(.)(.) (....) (%d+) (%d+) (%d+) (%w+) (%w+) (.+)"
local match_2 = "(.)(.) (....) (%d+) (%d+) (%d+) (%w+) (%w+) (%a%d+) ([^\t]+)\t?(.+)"

local function item_collection(state, section, filter)
  local items = state[section].items or {}
  for _, item in ipairs(items) do
    if filter:accepts(section, item.name) then
      logger.debug(("[STATUS] Invalidating cached diff for: %s"):format(item.name))
      item.diff = nil
      git.diff.build(section, item)
    end
  end

  return Collection.new(items):key_by("name")
end

-- Parse `git diff --numstat` output ("added<TAB>deleted<TAB>path") into a
-- map keyed by path. Binary files report "-" for both counts and are
-- skipped. Renames print "old => new" and are keyed by the new path,
-- matching item.name: brace renames keep the surrounding path
-- ("src/{a => b}/c.txt" -> "src/b/c.txt"), plain renames take the final
-- segment ("old => new" -> "new").
local function parse_numstat(lines)
  local counts = {}
  for _, line in ipairs(lines or {}) do
    local added, deleted, path = line:match("^(%d+)%s+(%d+)%s+(.+)$")
    if added then
      -- Brace renames occur wherever the shared prefix/suffix differs, so
      -- rewrite them first, wherever they sit in the path.
      path = path:gsub("{(.-) => (.-)}", "%2")

      -- A plain full rename ("old => new") may remain: key by the path after
      -- the LAST separator (the greedy prefix guarantees that).
      if path:find(" => ", 1, true) then
        path = path:match(".* => (.+)$")
      end

      counts[path] = { additions = tonumber(added), deletions = tonumber(deleted) }
    end
  end

  return counts
end

-- Bulk per-file +N/-M counts for the status buffer's file rows: two numstat
-- calls cover both index states (worktree diff and cached diff). Wrapped in
-- pcall so a numstat failure never breaks the status refresh.
local function file_line_counts()
  local worktree, staged = {}, {}
  local ok, err = pcall(function()
    worktree = parse_numstat(git.cli.diff.no_ext_diff.args("--numstat").call({ hidden = true }).stdout)
    staged = parse_numstat(git.cli.diff.no_ext_diff.cached.args("--numstat").call({ hidden = true }).stdout)
  end)

  if not ok then
    logger.debug(("[STATUS] Failed to collect file line counts: %s"):format(tostring(err)))
  end

  return worktree, staged
end

---Attach per-file +N/-M line counts (bulk `git diff --numstat`) to the
---staged/unstaged items in `state`. Shared by both git backends; runs on
---the main thread; no-ops when status.file_line_counts is off or both
---numstat calls fail.
---@param state NeogitRepoState
M.attach_file_stats = function(state)
  if not config.values.status.file_line_counts then
    return
  end

  -- Per-file line counts, attached per SECTION: the same path can appear in
  -- both sections with different counts (worktree vs cached diff).
  -- Untracked and unmerged items get none.
  local worktree_counts, staged_counts = file_line_counts()
  for _, item in ipairs(state.unstaged.items) do
    item.stats = worktree_counts[item.name]
  end

  for _, item in ipairs(state.staged.items) do
    item.stats = staged_counts[item.name]
  end
end

local function update_status(state, filter)
  local old_files = {
    staged_files = item_collection(state, "staged", filter),
    unstaged_files = item_collection(state, "unstaged", filter),
    untracked_files = item_collection(state, "untracked", filter),
  }

  state.staged.items = {}
  state.untracked.items = {}
  state.unstaged.items = {}

  -- --untracked-files=all: expand untracked directories into individual file
  -- entries, so the status buffer can list (and stage/discard) each file
  -- instead of one collapsed "dir/" row.
  local result = git.cli.status.null_separated
    .porcelain(2)
    .untracked_files("all")
    .call { hidden = true, remove_ansi = false }
  result = vim.split(result.stdout[1] or "", "\n")
  result = util.collect(result, function(line, collection)
    if line == "" then
      return
    end

    if line ~= "" and (line:match("^[12u]%s[%u%s%.%?!][%u%s%.%?!]%s") or line:match("^[%?!#]%s")) then
      table.insert(collection, line)
    else
      collection[#collection] = ("%s\t%s"):format(collection[#collection], line)
    end
  end)

  -- kinds:
  -- u = Unmerged
  -- 1 = Ordinary Entries
  -- 2 = Renamed/Copied Entries
  -- ? = Untracked
  -- ! = Ignored
  for _, l in ipairs(result) do
    local kind, rest = l:match(match_kind)
    if kind == "u" then
      local mode, _, _, _, _, _, _, _, _, name = rest:match(match_u)
      table.insert(
        state.unstaged.items,
        update_file("unstaged", state.worktree_root, old_files.unstaged_files[name], mode, name)
      )
    elseif kind == "?" then
      table.insert(
        state.untracked.items,
        update_file("untracked", state.worktree_root, old_files.untracked_files[rest], "?", rest)
      )
    elseif kind == "1" then
      local mode_staged, mode_unstaged, submodule, mH, mI, mW, _hH, _, name = rest:match(match_1)
      local file_mode = { head = mH, index = mI, worktree = mW }
      local submodule = parse_submodule_status(submodule)

      if mode_staged ~= "." then
        table.insert(
          state.staged.items,
          update_file(
            "staged",
            state.worktree_root,
            old_files.staged_files[name],
            mode_staged,
            name,
            nil,
            file_mode,
            submodule
          )
        )
      end

      if mode_unstaged ~= "." then
        table.insert(
          state.unstaged.items,
          update_file(
            "unstaged",
            state.worktree_root,
            old_files.unstaged_files[name],
            mode_unstaged,
            name,
            nil,
            file_mode,
            submodule
          )
        )
      end
    elseif kind == "2" then
      local mode_staged, mode_unstaged, submodule, mH, mI, mW, _, _, _, name, orig_name = rest:match(match_2)
      local file_mode = { head = mH, index = mI, worktree = mW }
      local submodule = parse_submodule_status(submodule)

      if mode_staged ~= "." then
        table.insert(
          state.staged.items,
          update_file(
            "staged",
            state.worktree_root,
            old_files.staged_files[name],
            mode_staged,
            name,
            orig_name,
            file_mode,
            submodule
          )
        )
      end

      if mode_unstaged ~= "." then
        table.insert(
          state.unstaged.items,
          update_file(
            "unstaged",
            state.worktree_root,
            old_files.unstaged_files[name],
            mode_unstaged,
            name,
            orig_name,
            file_mode,
            submodule
          )
        )
      end
    end
  end

  M.attach_file_stats(state)
end

-- index_write twins keep the GitResult return shape across backends, so
-- callers never need to know which one ran; stage/unstage forward to the
-- index module, which owns that dispatch.

---@param files string[]
---@return GitResult
function M.stage(files)
  return git.index.add(files)
end

---@return GitResult
function M.stage_modified()
  local result, served = libgit2.twin("index_write", "index", "stage_modified", "warn")
  if served then
    return result
  end

  return GitResult.from_process(git.cli.add.update.call { await = true })
end

---@return GitResult
function M.stage_untracked()
  -- Paths are collected BEFORE dispatching: the twin/CLI call can invalidate
  -- the repo state, so the untracked item list must be snapshotted first.
  -- Raw (unescaped) paths are required: every executor here is shell-free
  -- (libuv spawn argv / libgit2 FFI), so fnameescape'd strings with literal
  -- backslashes would no longer match the files on disk.
  local paths = util.map(git.repo.state.untracked.items, function(item)
    return item.name
  end)

  return git.index.add(paths)
end

---@return GitResult
function M.stage_all()
  local result, served = libgit2.twin("index_write", "index", "stage_all", "warn")
  if served then
    return result
  end

  return GitResult.from_process(git.cli.add.all.call { await = true })
end

---@param files string[]
---@return GitResult
function M.unstage(files)
  return git.index.reset(files)
end

---@return GitResult
function M.unstage_all()
  local result, served = libgit2.twin("index_write", "index", "reset_all", "warn")
  if served then
    return result
  end

  return GitResult.from_process(git.cli.reset.call { await = true })
end

---@return boolean
function M.is_dirty()
  return M.anything_unstaged() or M.anything_staged()
end

---@return boolean
function M.anything_staged()
  local result, served = libgit2.twin("query_status", "status", "anything_staged", "warn")
  if served then
    return result
  end

  -- the twin could not answer: serve from the CLI rather than report a
  -- false "nothing staged"
  local output = git.cli.status.porcelain(2).call({ hidden = true }).stdout
  return vim.iter(output):any(function(line)
    return line:match("^%d [^%.]")
  end)
end

---@return boolean
function M.anything_unstaged()
  local result, served = libgit2.twin("query_status", "status", "anything_unstaged", "warn")
  if served then
    return result
  end

  local output = git.cli.status.porcelain(2).call({ hidden = true }).stdout
  return vim.iter(output):any(function(line)
    return line:match("^%d %..")
  end)
end

-- All two-character porcelain status codes that denote an unmerged (conflicted)
-- entry. During a rebase or merge a conflict is not always "UU" -- an add/add
-- conflict is "AA", a delete/delete is "DD", etc.
local UNMERGED_MODES = { "UU", "AA", "DU", "UD", "AU", "UA", "DD" }

---@param mode string a StatusItem `mode` (two-character porcelain status code)
---@return boolean whether the mode denotes an unmerged/conflicted entry
function M.is_unmerged(mode)
  return vim.tbl_contains(UNMERGED_MODES, mode)
end

---@return boolean
function M.any_unmerged()
  return vim.iter(git.repo.state.unstaged.items):any(function(item)
    return M.is_unmerged(item.mode)
  end) or #git.cli["ls-files"].unmerged.call().stdout > 0
end

M.register = function(meta)
  meta.update_status = update_status
end

-- Shared with the libgit2 twin (lib/git/libgit2/status.lua); not public API.
M.internal = {
  update_file = update_file,
  item_collection = item_collection,
  update_status = update_status,
}

return M
