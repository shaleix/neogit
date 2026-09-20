local git = require("neogit.lib.git")

---@class NeogitGitReset
local M = {}

---@param target string
---@return boolean
function M.mixed(target)
  local result = git.cli.reset.mixed.args(target).call()
  return result:success()
end

---@param target string
---@return boolean
function M.soft(target)
  local result = git.cli.reset.soft.args(target).call()
  return result:success()
end

---@param target string
---@param opts? { backup?: boolean } Set `backup = false` to skip the pre-reset snapshot
---@return boolean
function M.hard(target, opts)
  if not (opts and opts.backup == false) then
    git.index.create_backup()
  end

  local result = git.cli.reset.hard.args(target).call()
  return result:success()
end

---@param target string
---@return boolean
function M.keep(target)
  local result = git.cli.reset.keep.args(target).call()
  return result:success()
end

---@param target string
---@return boolean
function M.index(target)
  local result = git.cli.reset.args(target).files(".").call()
  return result:success()
end

---@param target string revision to reset to
---@return boolean
function M.worktree(target)
  local success = false
  git.index.with_temp_index(target, function(index)
    local result = git.cli["checkout-index"].all.force.env({ GIT_INDEX_FILE = index }).call()
    success = result:success()
  end)

  return success
end

---@param target string
---@param files string[]
---@return boolean
function M.file(target, files)
  local result = git.cli.checkout.rev(target).files(unpack(files)).call()
  if result:failure() then
    result = git.cli.reset.args(target).files(unpack(files)).call()
  end

  return result:success()
end

---Take "our" version of conflicted files from the index (`git checkout --ours -- <files>`).
---@param files string[]
function M.checkout_ours(files)
  git.cli.checkout.ours.files(unpack(files)).call { await = true }
end

---Take "their" version of conflicted files from the index (`git checkout --theirs -- <files>`).
---@param files string[]
function M.checkout_theirs(files)
  git.cli.checkout.theirs.files(unpack(files)).call { await = true }
end

---Re-create the conflicted state of files from the merge base (`git checkout --merge -- <files>`).
---@param files string[]
function M.checkout_merge(files)
  git.cli.checkout.merge.files(unpack(files)).call { await = true }
end

return M
