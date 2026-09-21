-- libgit2 twin of git.rev_parse.oid (rev_parse.lua).
local git2 = require("neogit.lib.git2")

local M = {}

local function worktree_root()
  return require("neogit.lib.git").repo.worktree_root
end

---Resolve a revspec to a full oid; nil when it does not resolve.
---@param spec string
---@return string?
function M.oid(spec)
  return git2.with_repo(worktree_root(), function(repo)
    return git2.oid_of(repo, spec)
  end)
end

---Abbreviate a full oid to this repository's abbreviation length
---(git's own auto-sizing, via git_object_short_id).
---@param oid string
---@return string
function M.abbreviate(oid)
  return oid:sub(1, require("neogit.lib.git.libgit2.log").abbrev_size())
end

return M
