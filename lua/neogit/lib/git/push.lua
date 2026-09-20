local git = require("neogit.lib.git")
local GitResult = require("neogit.lib.git.result")

---@class NeogitGitPush
local M = {}

---Pushes to the remote and handles password questions
---@param remote string?
---@param branch string?
---@param args string[]
---@return ProcessResult
function M.push_interactive(remote, branch, args)
  return git.cli.push.args(remote or "", branch or "").arg_list(args).call { pty = true }
end

---Delete a remote ref by pushing a delete refspec (`git push <remote> :<refspec>`).
---@param remote string Remote name, e.g. "origin"
---@param refspec string Ref to delete, e.g. "feature" or ":refs/tags/v1.0" (leading ":" added when absent)
---@return GitResult
function M.delete_remote_ref(remote, refspec)
  if not refspec:match("^:") then
    refspec = ":" .. refspec
  end

  return GitResult.from_process(git.cli.push.remote(remote).args(refspec).call())
end

---@param branch string|nil
---@return boolean
function M.auto_setup_remote(branch)
  if not branch then
    return false
  end

  local push_autoSetupRemote = git.config.get("push.autoSetupRemote"):read()
  local push_default = git.config.get("push.default"):read()
  local branch_remote = git.config.get_local("branch." .. branch .. ".remote"):read()

  return (
    push_autoSetupRemote
    and (push_default == "current" or push_default == "simple" or push_default == "upstream")
    and not branch_remote
  ) == true
end

return M
