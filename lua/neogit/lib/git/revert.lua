local git = require("neogit.lib.git")
local util = require("neogit.lib.util")

---@class NeogitGitRevert
local M = {}

---@param commits string[]
---@param args string[]
---@return boolean, string|nil
function M.commits(commits, args)
  local result = git.cli.revert.no_commit.arg_list(util.merge(args, commits)).call { pty = true }
  if result:success() then
    return true, ""
  else
    return false, result.stdout[1]
  end
end

---@param hunk Hunk
---@param _ string[]
---@return boolean success
---@return string|nil error_message
function M.hunk(hunk, _)
  local patch = git.index.generate_patch(hunk, { reverse = true })
  local result = git.index.apply(patch, { reverse = true })

  if result:success() then
    return true, nil
  else
    -- index.apply returns a backend-neutral GitResult: the CLI stderr (or
    -- the libgit2 error text) arrives pre-joined in `message`
    local error_msg = result.message ~= "" and result.message or "Failed to apply patch"
    return false, error_msg
  end
end

function M.continue()
  git.cli.revert.continue.no_edit.call { pty = true }
end

function M.skip()
  git.cli.revert.skip.call()
end

function M.abort()
  git.cli.revert.abort.call()
end

return M
