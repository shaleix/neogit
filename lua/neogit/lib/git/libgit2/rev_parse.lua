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

return M
