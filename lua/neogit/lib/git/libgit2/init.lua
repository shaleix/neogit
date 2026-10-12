-- libgit2 backend implementations (migration spec §3.2: parallel backend
-- modules behind the same update_* / query contracts).
--
-- The hub wires twins into the repository:
--   * update twins land in `repo.libgit2_updates` and `repository.lua` picks
--     them per the module capability table
--   * query twins are called through thin dispatchers in the existing
--     lib/git/* modules (see backend.capability keys below)
--
-- All libgit2 calls go through the executor seam (git2.run). Refresh-path
-- twins receive the per-cycle repository handle as `ctx.repo`; single-shot
-- queries open their own handle (git2.with_repo).
local git2 = require("neogit.lib.git2")
local backend = require("neogit.lib.git.backend")
local logger = require("neogit.logger")

local M = {}

M.run = git2.run
M.with_repo = git2.with_repo

---@param level "warn"|"debug"|"none"
---@param module string
---@param fn_name string
---@param reason string "failed" (twin raised) or "unavailable" (twin declined)
---@param detail? string optional traceback / extra context appended on its own line
local function log_fallback(level, module, fn_name, reason, detail)
  if level == "none" then
    return
  end

  logger[level or "warn"](
    ("[%s]: libgit2 %s %s - falling back to CLI%s"):format(
      module:upper(),
      fn_name,
      reason,
      detail and ("\n" .. tostring(detail)) or ""
    )
  )
end

---Dispatch a libgit2 twin with runtime degradation (migration spec §7): the
---single seam point every CLI-side dispatcher goes through. Returns the
---twin's result(s) plus `served = true` when the twin served the call. Twin
---errors are logged with a traceback and treated like a nil ("declined")
---result, so every dispatcher falls back to the CLI without repeating the
---pcall/log dance. A legitimate nil answer (e.g. branch.current() on a
---detached HEAD) also routes through the CLI, which produces the same
---answer.
---@param capability string capability key, e.g. "query_branch"
---@param module string twin module under lib/git/libgit2/, e.g. "branch"
---@param fn_name string function name on the twin module, e.g. "current"
---@param level? "warn"|"debug"|"none" fallback log level (default "warn")
---@return any result first twin result; nil unless the twin served the call
---@return boolean served
---@return ... extra trailing twin results, when the twin returns multiple values
function M.twin(capability, module, fn_name, level, ...)
  if backend.capability(capability) ~= "libgit2" then
    return nil, false
  end

  local fn = require("neogit.lib.git.libgit2." .. module)[fn_name]
  -- nb: a table constructor collects every value of the trailing xpcall
  -- (trailing nils are dropped, which is what the decline check wants)
  local results = { xpcall(fn, debug.traceback, ...) }

  if not results[1] then
    log_fallback(level, module, fn_name, "failed", results[2])
    return nil, false
  end

  if #results < 2 or results[2] == nil then
    log_fallback(level, module, fn_name, "unavailable")
    return nil, false
  end

  results[#results + 1] = true
  return unpack(results, 2, #results)
end

---Sort ref entries per a git `--sort` key. Entries carry `.name` (sort/display
---name) and `.time` (peeled commit time, may be nil). Supports the keys in
---practical use; anything else falls back to refname ascending.
---@param entries { name: string, time: integer? }[]
---@param sortby? string
M.sort_refs = function(entries, sortby)
  local key = sortby or "-committerdate"

  local comparators = {
    ["-committerdate"] = function(a, b)
      return (a.time or 0) > (b.time or 0)
    end,
    committerdate = function(a, b)
      return (a.time or 0) < (b.time or 0)
    end,
    refname = function(a, b)
      return a.name < b.name
    end,
    ["-refname"] = function(a, b)
      return a.name > b.name
    end,
  }

  table.sort(entries, comparators[key] or comparators.refname)
  return entries
end

---Register this backend's implementations with a repository instance.
---Safe to call when libgit2 is absent: capability() re-checks availability
---before any twin is selected.
---@param repo table Repo instance (gains repo.libgit2_updates)
function M.register(repo)
  repo.libgit2_updates = repo.libgit2_updates or {}

  local log = require("neogit.lib.git.libgit2.log")
  repo.libgit2_updates.update_recent = log.update_recent
  backend.mark_migrated("update_recent")

  local status = require("neogit.lib.git.libgit2.status")
  repo.libgit2_updates.update_status = status.update_status
  backend.mark_migrated("update_status")

  -- Query twins (dispatched inside the lib/git/* modules).
  backend.mark_migrated("query_rev_parse")
  backend.mark_migrated("query_log_message")
  backend.mark_migrated("query_log_list")
  backend.mark_migrated("query_branch")
  backend.mark_migrated("query_branch_status")
  backend.mark_migrated("query_refs_listing")
  backend.mark_migrated("query_status")
  backend.mark_migrated("query_remote_list")
  backend.mark_migrated("query_config_build")
  backend.mark_migrated("query_config_global")
  backend.mark_migrated("query_stash_list")
  backend.mark_migrated("query_describe")
  backend.mark_migrated("query_abbrev_size")
  backend.mark_migrated("query_abbreviate_commit")

  -- Index writes (stage/unstage/checkout-file/forward-apply).
  backend.mark_migrated("index_write")
end

return M
