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

---Abbreviate any revspec or oid to this repository's abbreviation length
---(matching `git rev-parse --short <spec>`). The spec is resolved first:
---callers pass reflog specs like "stash@{0}", not only full oids.
---@param spec string revspec or oid
---@return string?
function M.abbreviate(spec)
  return git2.with_repo(worktree_root(), function(repo)
    local hex = git2.oid_of(repo, spec)
    if not hex then
      return nil
    end

    return hex:sub(1, require("neogit.lib.git.libgit2.log").abbrev_size())
  end)
end

return M
