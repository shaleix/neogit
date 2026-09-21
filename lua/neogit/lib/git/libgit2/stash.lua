-- libgit2 twin of git.stash.list: git_stash_foreach instead of a
-- `git stash list` spawn on every refresh.
local git2 = require("neogit.lib.git2")

local M = {}

local function worktree_root()
  return require("neogit.lib.git").repo.worktree_root
end

---@return string[] lines shaped like `stash@{N}: message` (CLI compatible)
function M.list()
  return git2.with_repo(worktree_root(), function(repo)
    local ffi = require("ffi")

    local lines = {}
    local cb = ffi.cast("git_stash_cb", function(index, message)
      lines[#lines + 1] = ("stash@{%d}: %s"):format(tonumber(index) or 0, ffi.string(message))
      return 0
    end)

    pcall(function()
      git2.binding.libgit2().C.git_stash_foreach(repo.repo, cb, nil)
    end)

    cb:free()
    return lines
  end) or {}
end

return M
