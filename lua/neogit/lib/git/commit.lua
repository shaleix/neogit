local git = require("neogit.lib.git")
local client = require("neogit.client")
local GitResult = require("neogit.lib.git.result")

---@class NeogitGitCommit
local M = {}

---Create a commit. Editor-based flow is handled by client.wrap (GIT_EDITOR RPC).
---@param args string[] Positional/flag arguments (e.g. popup args, "--fixup=<commit>")
---@param opts? { edit?: boolean, no_edit?: boolean, all?: boolean, amend?: boolean, only?: boolean, no_verify?: boolean, autocmd?: string, msg?: { success: string, fail: string }, show_diff?: boolean }
---@return GitResult
function M.create(args, opts)
  opts = opts or {}

  local cmd = git.cli.commit
  if opts.edit then
    cmd = cmd.edit
  elseif opts.no_edit then
    cmd = cmd.no_edit
  end

  if opts.all then
    cmd = cmd.all
  end
  if opts.amend then
    cmd = cmd.amend
  end
  if opts.only then
    cmd = cmd.only
  end
  if opts.no_verify then
    cmd = cmd.no_verify
  end

  local code = client.wrap(cmd.arg_list(args or {}), {
    autocmd = opts.autocmd,
    msg = opts.msg,
    interactive = true,
    show_diff = opts.show_diff,
  })

  return GitResult.new(code)
end

---Run git-absorb (fixup absorption) from the given base commit.
---Requires the external `git-absorb` tool.
---@param base string Commit to absorb into upwards from, e.g. "abc1234"
---@return GitResult
function M.absorb(base)
  local result = git.cli.absorb.verbose.base(base .. "^").and_rebase.env({ GIT_SEQUENCE_EDITOR = ":" }).call()

  return GitResult.from_process(result)
end

return M
