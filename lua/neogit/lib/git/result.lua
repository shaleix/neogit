local util = require("neogit.lib.util")

---Backend-neutral result of a git operation.
---
---Both the CLI backend (wrapping ProcessResult) and the future libgit2
---backend (mapping GIT_ERROR codes) produce this, so callers can check
---outcomes without depending on which backend executed the operation.
---@class GitResult
---@field ok boolean Convenience: true when code == 0.
---@field code integer Exit or error code; 0 means success.
---@field message string User-readable message (stderr summary or libgit2 error text).
local GitResult = {}
GitResult.__index = GitResult

---@param code integer
---@param message? string
---@return GitResult
function GitResult.new(code, message)
  return setmetatable({ ok = code == 0, code = code, message = message or "" }, GitResult)
end

---Wrap a ProcessResult (CLI backend) into a GitResult.
---@param process_result ProcessResult
---@return GitResult
function GitResult.from_process(process_result)
  return GitResult.new(process_result.code, table.concat(process_result.stderr or {}, "\n"))
end

---@return boolean
function GitResult:success()
  return self.code == 0
end

---@return boolean
function GitResult:failure()
  return self.code ~= 0
end

return GitResult
