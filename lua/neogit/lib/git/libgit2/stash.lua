-- libgit2 twin of git.stash.list: git_stash_foreach instead of a
-- `git stash list` spawn on every refresh.
local git2 = require("neogit.lib.git2")
local logger = require("neogit.logger")

local M = {}

local function worktree_root()
  return require("neogit.lib.git").repo.worktree_root
end

---Run git_stash_foreach, invoking `fn(index, message, oid_hex)` per entry.
---Returns true on success; false when the call raised or failed (reason
---logged), so callers can fall back to the CLI instead of silently
---reporting an empty stash list.
---@param repo table git2 repository wrapper
---@param fn fun(index: integer, message: string, oid: string)
---@return boolean
local function stash_foreach(repo, fn)
  local ffi = require("ffi")
  local lg2 = git2.binding.libgit2()

  local cb = ffi.cast("git_stash_cb", function(index, message, stash_id)
    fn(tonumber(index) or 0, ffi.string(message), ffi.string(lg2.C.git_oid_tostr_s(stash_id)))
    return 0
  end)

  local ok, err = pcall(function()
    return lg2.C.git_stash_foreach(repo.repo, cb, nil)
  end)

  cb:free()

  if not ok then
    logger.error(("[LG2:STASH]: git_stash_foreach raised: %s"):format(tostring(err)))
    return false
  end

  if type(err) == "number" and err ~= 0 then
    logger.error(("[LG2:STASH]: git_stash_foreach failed: %s"):format(git2.git_result(err, "").message))
    return false
  end

  return true
end

---Returns nil when libgit2 cannot serve the listing (repo open failure or
---foreach error), so the CLI dispatcher can fall back instead of showing
---a silently empty stash list.
---@return string[]? lines shaped like `stash@{N}: message` (CLI compatible)
function M.list()
  return git2.with_repo(worktree_root(), function(repo)
    local lines = {}
    local ok = stash_foreach(repo, function(index, message)
      lines[#lines + 1] = ("stash@{%d}: %s"):format(index, message)
    end)

    if not ok then
      return nil
    end

    return lines
  end)
end

---Like M.list, but returns the parsed stash entries including each stash's
---oid straight from the foreach callback - resolving oids afterwards (one
---rev-parse per stash, the old lazy `item.oid` path) cost a repository open
---per entry, which stacked up to seconds on stash-heavy repos during
---status rendering.
---@return { idx: integer, message: string, oid: string, name: string }[]? nil when libgit2 cannot serve the listing
function M.list_detailed()
  return git2.with_repo(worktree_root(), function(repo)
    local entries = {}
    local ok = stash_foreach(repo, function(index, message, oid)
      entries[#entries + 1] = {
        idx = index,
        message = message,
        oid = oid,
        name = ("stash@{%d}: %s"):format(index, message),
      }
    end)

    if not ok then
      return nil
    end

    return entries
  end)
end

return M
