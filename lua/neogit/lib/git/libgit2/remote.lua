-- libgit2 twin of git.remote.list (the `git remote` spawn cached per process
-- on the CLI path; zero-spawn here).
local git2 = require("neogit.lib.git2")

local M = {}

local function worktree_root()
  return require("neogit.lib.git").repo.worktree_root
end

---@return string[]
function M.list()
  return git2.with_repo(worktree_root(), function(repo)
    local list = repo:remote_list()
    return list or {}
  end) or {}
end

return M
