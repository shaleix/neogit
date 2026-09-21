-- libgit2 twins for git.config reads: the local-config cache build
-- (`git config --list --null --local`) and global lookups (`git config --get`)
-- become in-process, removing the first-refresh spawn storm on the
-- branch_information path.
local git2 = require("neogit.lib.git2")

local M = {}

local function worktree_root()
  return require("neogit.lib.git").repo.worktree_root
end

---Entries of the LOCAL config only (matches `git config --list --local`).
---Returns nil when the libgit2 path cannot serve the query, so callers fall
---back to the CLI rather than rendering a partial config.
---@return table<string, string>? key -> value
function M.local_entries()
  return git2.with_repo(worktree_root(), function(repo)
    local merged = repo:config()
    if not merged then
      return nil
    end

    -- GIT_CONFIG_LEVEL.LOCAL (5); overlay fixes the 1.8+ enum insertion
    local local_cfg = merged:open_level(5)
    if not local_cfg then
      return nil
    end

    local ok, entries = pcall(function()
      return local_cfg:entries()
    end)

    -- nb: the vendored entries() uses ffi.string on entry.value, which errors
    -- for valueless entries (bare section keys) - fall back to the CLI then
    if not ok or not entries then
      return nil
    end

    local out = {}
    for _, entry in ipairs(entries) do
      out[entry.name:lower()] = entry.value or ""
    end

    return out
  end)
end

---Merged lookup matching `git config --get <key>` (repository config =
---local + global + system, local wins). This is the CLI semantics of
---config.get_global, which does NOT pass --global.
---@param key string
---@return string? value
function M.merged_get(key)
  return git2.with_repo(worktree_root(), function(repo)
    local cfg = repo:config()
    if not cfg then
      return nil
    end

    local ok, value = pcall(function()
      return cfg:get_string(key)
    end)

    return ok and value or nil
  end)
end

---Global/system/XDG-only lookup (used when no repository context is
---available).
---@param key string
---@return string? value
function M.global_get(key)
  local git2mod = git2.binding.git2()

  local ok, value = pcall(function()
    local cfg = git2mod.Config.open_default()
    if not cfg then
      return nil
    end

    return cfg:get_string(key)
  end)

  if not ok then
    return nil
  end

  return value
end

return M
