-- libgit2 twin of git.stash.list: git_stash_foreach instead of a
-- `git stash list` spawn on every refresh.
local git2 = require("neogit.lib.git2")
local logger = require("neogit.logger")

local M = {}

local function worktree_root()
  return require("neogit.lib.git").repo.worktree_root
end

---Returns nil when libgit2 cannot serve the listing (repo open failure or
---foreach error), so the CLI dispatcher can fall back instead of showing
---a silently empty stash list.
---@return string[]? lines shaped like `stash@{N}: message` (CLI compatible)
function M.list()
  return git2.with_repo(worktree_root(), function(repo)
    local ffi = require("ffi")

    local lines = {}
    local failed = false
    local cb = ffi.cast("git_stash_cb", function(index, message)
      lines[#lines + 1] = ("stash@{%d}: %s"):format(tonumber(index) or 0, ffi.string(message))
      return 0
    end)

    local ok, err = pcall(function()
      return git2.binding.libgit2().C.git_stash_foreach(repo.repo, cb, nil)
    end)

    cb:free()

    if not ok then
      logger.error(("[LG2:STASH]: git_stash_foreach raised: %s"):format(tostring(err)))
      return nil
    end

    if type(err) == "number" and err ~= 0 then
      logger.error(("[LG2:STASH]: git_stash_foreach failed: %s"):format(git2.git_result(err, "").message))
      failed = true
    end

    if failed then
      return nil
    end

    return lines
  end)
end

return M
