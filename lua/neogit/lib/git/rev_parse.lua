local git = require("neogit.lib.git")
local util = require("neogit.lib.util")
local backend = require("neogit.lib.git.backend")
local lg2 = require("neogit.lib.git.libgit2.rev_parse")

---@class NeogitGitRevParse
local M = {}

---@param oid string
---@return string
---@async
M.abbreviate_commit = util.memoize(function(oid)
  assert(oid, "Missing oid")

  if oid == "(initial)" then
    return "(initial)"
  end

  if backend.capability("query_abbreviate_commit") == "libgit2" then
    return require("neogit.lib.git.libgit2.rev_parse").abbreviate(oid)
  end

  return git.cli["rev-parse"].short.args(oid).call({ hidden = true, ignore_error = true }).stdout[1]
end, { timeout = math.huge })

---@param rev string
---@return string
---@async
function M.oid(rev)
  if backend.capability("query_rev_parse") == "libgit2" then
    return lg2.oid(rev)
  end

  return git.cli["rev-parse"].args(rev).call({ hidden = true, ignore_error = true }).stdout[1]
end

---@param rev string
---@return string
---@async
function M.verify(rev)
  return git.cli["rev-parse"].verify.abbrev_ref
    .args(rev)
    .call({ hidden = true, ignore_error = true }).stdout[1]
end

---@param rev string
---@return string
function M.full_name(rev)
  return git.cli["rev-parse"].verify.symbolic_full_name
    .args(rev)
    .call({ hidden = true, ignore_error = true }).stdout[1]
end

---@return string?
function M.parent_repo()
  return git.cli["rev-parse"].show_superproject_working_tree.call({ hidden = true, ignore_error = true }).stdout[1]
end

return M
