-- libgit2 twin of git.remote.list (the `git remote` spawn cached per process
-- on the CLI path; zero-spawn here).
local git2 = require("neogit.lib.git2")
local logger = require("neogit.logger")

local M = {}

local function worktree_root()
  return require("neogit.lib.git").repo.worktree_root
end

---Returns nil when libgit2 cannot serve the listing (repo open failure or
---remote_list error), so the CLI dispatcher can fall back instead of
--- reporting "no remotes" for a repository that has some.
---@return string[]?
function M.list()
  return git2.with_repo(worktree_root(), function(repo)
    local list, err = repo:remote_list()
    if not list then
      logger.error(("[LG2:REMOTE]: remote_list failed: %s"):format(git2.git_result(err, "").message))
      return nil
    end

    return list
  end)
end

return M
