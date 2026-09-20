-- libgit2 twins for git.log: `message` (the `log -1 --format=%s` spawn killed
-- by P0's dedup, now taken off the spawn list entirely) and the
-- `update_recent` refresh task.
local config = require("neogit.config")
local state = require("neogit.lib.state")
local util = require("neogit.lib.util")
local git2 = require("neogit.lib.git2")
local ffi = require("ffi")

local M = {}

local function worktree_root()
  return require("neogit.lib.git").repo.worktree_root
end

---Equivalent of `git log --max-count=1 --format=%s <commit>`.
---@param commit string revspec
---@return string?
function M.message(commit)
  return git2.with_repo(worktree_root(), function(repo)
    local c = git2.commit_of(repo, commit)
    if not c then
      return nil
    end

    return c:summary()
  end)
end

--------------------------------------------------------------------------------
-- update_recent twin
--------------------------------------------------------------------------------

---Humanized relative date in git's `%cr` format ("2 hours ago",
---"1 year, 3 months ago"), following git's date.c show_date_relative so the
---status UI's post-processing matches byte-for-byte.
local function plural(n, unit)
  if n == 1 then
    return ("1 %s ago"):format(unit)
  end
  return ("%d %ss ago"):format(n, unit)
end

local function relative_date(unix_time)
  local diff = os.time() - unix_time
  if diff < 0 then
    diff = 0
  end

  if diff < 90 then
    return plural(diff, "second")
  end

  local minutes = math.floor((diff + 30) / 60)
  if minutes < 90 then
    return plural(minutes, "minute")
  end

  local hours = math.floor((minutes + 30) / 60)
  if hours < 36 then
    return plural(hours, "hour")
  end

  local days = math.floor((hours + 12) / 24)
  if days < 14 then
    return plural(days, "day")
  elseif days < 70 then
    return plural(math.floor((days + 3) / 7), "week")
  elseif days < 365 then
    return plural(math.floor((days + 15) / 30), "month")
  elseif days < 1825 then
    local totalmonths = math.floor((days * 12 * 2 + 365) / (365 * 2))
    local years = math.floor(totalmonths / 12)
    local months = totalmonths % 12
    if months > 0 then
      return ("%d %s, %d %s ago"):format(years, years == 1 and "year" or "years", months, months == 1 and "month" or "months")
    end
    return plural(years, "year")
  else
    return plural(math.floor((days + 183) / 365), "year")
  end
end
M.relative_date = relative_date

---Build a map of commit-oid -> %D-style decoration parts ("HEAD -> x",
---"origin/x", "tag: v1", plain branch names), matching what branch_info
---parses out of `git log --format=%D`.
---
---Note: libgit2 1.9 removed `git_reference_iterator_next`; only
---`next_name` remains (it has existed since 0.28), so we iterate names and
---resolve each reference for peeling.
---@param repo table git2.Repository wrapper
---@return table<string, string[]>
local function decoration_map(repo)
  local map = {}

  git2.each_ref_name(repo, function(full)
    local entry
    if full:match("^refs/heads/") or full:match("^refs/remotes/") then
      entry = full:gsub("^refs/[^/]*/", "")
    elseif full:match("^refs/tags/") then
      entry = "tag: " .. full:sub(#"refs/tags/" + 1)
    end

    if entry then
      local ok, commit = pcall(function()
        local ref, err = repo:reference_lookup(full)
        assert(ref, "reference_lookup failed: " .. tostring(err))
        return ref:peel_commit()
      end)
      if ok and commit then
        local hex = git2.oid_hex(commit:id().oid)
        map[hex] = map[hex] or {}
        map[hex][#map[hex] + 1] = entry
      end
    end

    return true
  end)

  -- HEAD marker: arrow when on a branch, plain "HEAD" when detached.
  local head_ref, err = repo:head()
  if head_ref then
    local ok, commit = pcall(function()
      return head_ref:peel_commit()
    end)
    if ok and commit then
      local hex = git2.oid_hex(commit:id().oid)
      map[hex] = map[hex] or {}

      local marker
      if repo:is_head_detached() then
        marker = "HEAD"
      else
        marker = "HEAD -> " .. head_ref:shorthand()
      end
      table.insert(map[hex], 1, marker)
    end
  end

  return map
end

---update_recent twin: fill state.recent.items via revwalk + decorations.
---Signature matches the update_* contract plus the per-cycle context.
---@param repo_state NeogitRepoState
---@param _filter table?
---@param ctx { repo: table? }? per-refresh repository handle
function M.update_recent(repo_state, _filter, ctx)
  repo_state.recent = { items = {} }

  local count = config.values.status.recent_commit_count
  if count <= 0 then
    return
  end

  local order = state.get({ "NeogitMarginPopup", "-order" }, config.values.commit_order)

  git2.run(function()
    local repo = (ctx and ctx.repo) or git2.open_repo(worktree_root(), true)
    if not repo then
      return
    end

    local git = require("neogit.lib.git")

    local walker = repo:walker()
    if order == "date" then
      walker:sort(false, true, false)
    else
      walker:sort(true, false, false)
    end
    walker:push_head()

    local decorations = decoration_map(repo)
    local records = {}

    for oid, commit in walker:iter() do
      if #records >= count then
        break
      end

      local hex = oid:tostring(40)
      local lg2 = git2.binding.libgit2()
      local sig = lg2.C.git_commit_committer(commit.commit)
      local committer_time = tonumber(sig.when.time) or 0
      local author_name = ffi.string(lg2.C.git_commit_author(commit.commit).name)

      records[#records + 1] = {
        oid = hex,
        abbreviated_commit = hex:sub(1, git.log.abbreviated_size()),
        subject = commit:summary(),
        ref_name = table.concat(decorations[hex] or {}, ", "),
        rel_date = relative_date(committer_time),
        author_name = author_name,
        author_date = committer_time,
        committer_date = committer_time,
        unix_date = committer_time,
      }
    end

    repo_state.recent.items = util.filter_map(records, git.log.present_commit)
  end)
end

return M
