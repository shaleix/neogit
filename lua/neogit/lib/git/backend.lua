-- Backend selection policy (migration spec §3.1/§7).
--
-- kind resolution: config git_backend = "auto" | "libgit2" | "cli"
--   auto     — probe lazily; use libgit2 when available, degrade to CLI
--   libgit2  — hard-require the binding (error when unavailable)
--   cli      — never touch libgit2
--
-- The module capability table maps each update_* module to the backend its
-- libgit2 implementation is wired into. In P1 everything resolves to "cli";
-- entries flip to "libgit2" module by module as the P2/P3 waves land, which
-- is also how per-module gradual rollout works.
local config = require("neogit.config")

local M = {}

---@type table<string, boolean> Allowed git_backend values (single source: config.GIT_BACKENDS).
local KINDS = {}

for _, kind in ipairs(config.GIT_BACKENDS) do
  KINDS[kind] = true
end

local resolved = nil
local notified = false

---@return "auto"|"libgit2"|"cli"
function M.kind()
  return config.values.git_backend or "auto"
end

---Resolve the backend in use, probing lazily on first call (not at setup).
---auto + probe failure => one-time notification, then silent CLI degrade.
---@return "libgit2"|"cli"
function M.current()
  if resolved then
    return resolved
  end

  local kind = M.kind()
  if not KINDS[kind] then
    error(("neogit: invalid git_backend %q (expected auto, libgit2 or cli)"):format(kind))
  end

  if kind == "cli" then
    resolved = "cli"
    return resolved
  end

  local git2 = require("neogit.lib.git2")
  local probe = git2.probe()

  if probe.available then
    resolved = "libgit2"
    return resolved
  end

  if kind == "libgit2" then
    error(('neogit: git_backend = "libgit2", but %s'):format(probe.reason))
  end

  resolved = "cli"
  if not notified then
    notified = true
    vim.schedule(function()
      vim.notify(
        (
          "neogit: libgit2 backend unavailable (%s).\nFalling back to the git CLI backend. "
          .. "Install libgit2 >= 1.7 (e.g. `apt install libgit2-1.9` / `brew install libgit2`) "
          .. 'or set `git_backend = "cli"` to silence this.'
        ):format(probe.reason),
        vim.log.levels.INFO
      )
    end)
  end

  return resolved
end

---Forget the resolved backend (forces re-probe on next current()).
function M.reset()
  resolved = nil
end

--------------------------------------------------------------------------------
-- Module capability table
--------------------------------------------------------------------------------

local capabilities = {}

---Declare an update_* module's libgit2 implementation wired and ready
---("libgit2" once migrated; absent means not migrated yet).
---@param module string update_* module name, e.g. "update_status"
function M.mark_migrated(module)
  capabilities[module] = "libgit2"
end

---@param module string update_* module name
---@return "libgit2"|"cli"
function M.capability(module)
  if M.current() == "cli" then
    return "cli"
  end

  return capabilities[module] or "cli"
end

return M
