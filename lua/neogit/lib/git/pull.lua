local git = require("neogit.lib.git")

---@class NeogitGitPull
local M = {}

---Pulls from the remote and handles password questions
---@param remote string?
---@param branch string?
---@param args string[]
---@return ProcessResult
function M.pull_interactive(remote, branch, args)
  local client = require("neogit.client")
  local envs = client.get_envs_git_editor()
  return git.cli.pull.env(envs).args(remote or "", branch or "").arg_list(args).call { pty = true }
end

return M
