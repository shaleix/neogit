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
---@return table<string, string> key -> value
function M.local_entries()
  return git2.with_repo(worktree_root(), function(repo)
    local git2mod = git2.binding.git2()

    local merged, err = repo:config()
    if not merged then
      return {}
    end

    -- GIT_CONFIG_LEVEL.LOCAL (5); overlay fixes the 1.8+ enum insertion
    local local_cfg, lerr = merged:open_level(5)
    if not local_cfg then
      return {}
    end

    local entries, eerr = local_cfg:entries()
    if not entries then
      return {}
    end

    local out = {}
    for _, entry in ipairs(entries) do
      out[entry.name:lower()] = entry.value or ""
    end

    return out
  end) or {}
end

---One global/system/XDG lookup (matches `git config --get` outside the repo).
---@param key string
---@return string? value
function M.global_get(key)
  local git2mod = git2.binding.git2()

  local ok, value = pcall(function()
    local cfg, err = git2mod.Config.open_default()
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
