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

local M = {}

M.run = git2.run
M.with_repo = git2.with_repo

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

  -- Index writes (stage/unstage/checkout-file/forward-apply).
  backend.mark_migrated("index_write")
end

return M
