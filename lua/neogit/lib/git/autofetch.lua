-- Background auto-fetch when the status buffer opens.
--
-- Opening the status buffer fetches from the configured remote(s) (plain
-- `git fetch`, no arguments - the repo's remote/auth configuration decides
-- what is fetched) and refreshes the buffer once when the fetch moved the
-- upstream ref. This keeps the Head line's ↓N behind counter current even
-- when the remote advanced since the last manual fetch. The fetch NEVER
-- pulls, merges or rebases - only remote-tracking refs move.
--
-- Guardrails:
--   * single-flight per process: triggers while a fetch runs are skipped,
--     not queued (the flag clears on success, failure and cancellation)
--   * credential prompts cannot hang the editor: the fetch runs with
--     GIT_TERMINAL_PROMPT=0 and GIT_ASKPASS=true (/bin/true), so remotes
--     without cached credentials fail fast instead of waiting for input
--   * everything is best-effort: the whole chain is pcall'd and failures
--     log at debug level only - no notification, no console output
local git = require("neogit.lib.git")
local config = require("neogit.config")
local logger = require("neogit.logger")
local a = require("neogit.lib.async")

-- Awaitable delay (resumes the coroutine from a defer_fn callback).
local sleep = a.wrap(function(ms, cb)
  vim.defer_fn(cb, ms)
end, 2)

local M = {}

local in_flight = false

---Whether a fetch triggered by this module is currently running.
---@return boolean
function M.is_fetching()
  return in_flight
end

---Trigger the background fetch for a status buffer. Called once per status
---buffer open; calls while a fetch is already running are skipped.
---@param status_buffer StatusBuffer
function M.trigger(status_buffer)
  if not config.values.auto_fetch or not config.values.auto_fetch.enabled then
    return
  end

  if in_flight then
    logger.debug("[AUTO FETCH]: already in flight - skipping")
    return
  end

  in_flight = true

  local task = a.run(function()
    local ok, err = pcall(function()
      -- Guards (cheap live reads): detached HEAD, no remote, or no upstream
      -- branch - nothing to fetch for. The upstream oid probe doubles as the
      -- "no upstream" guard and the change-gate baseline.
      if git.branch.current() == nil then
        logger.debug("[AUTO FETCH]: detached HEAD - skipping")
        return
      end

      if #git.remote.list() == 0 then
        logger.debug("[AUTO FETCH]: no remote configured - skipping")
        return
      end

      local before = git.rev_parse.oid("@{upstream}")
      if not before then
        logger.debug("[AUTO FETCH]: no upstream branch - skipping")
        return
      end

      -- Plain `git fetch`, no arguments, hidden (no console, no spinner).
      -- The env keeps remotes without cached credentials from hanging the
      -- editor on a credential prompt: prompts are disabled and askpass
      -- succeeds with empty output, so auth fails fast instead.
      git.cli.fetch
        .env({ GIT_TERMINAL_PROMPT = "0", GIT_ASKPASS = "true" })
        .call { hidden = true, ignore_error = true }

      -- The fetch is done: release the single-flight flag here so an open
      -- that happened while the fetch ran is not starved by the remaining
      -- (cheap) gate/refresh tail below.
      in_flight = false

      -- Change gate: refresh only when the fetch actually moved the
      -- upstream ref. A no-op fetch costs nothing but the probes.
      local after = git.rev_parse.oid("@{upstream}")
      if after == before then
        logger.debug("[AUTO FETCH]: upstream unchanged - no refresh")
        return
      end

      -- The refresh's repo update tasks read log listings through a 1s
      -- memoize cache: a refresh dispatched within that window of the
      -- initial refresh would re-serve the pre-fetch divergence from cache
      -- and never pick up the moved ref. Wait past the TTL so the refresh
      -- reads fresh data.
      sleep(1100)

      -- Refresh only while the buffer is still alive, visible, and bound to
      -- the repo the fetch ran in (the global repo pointer may have moved on
      -- to another worktree in the meantime).
      if
        status_buffer.buffer
        and status_buffer.buffer:is_visible()
        and git.repo.worktree_root == status_buffer.root
      then
        logger.debug("[AUTO FETCH]: upstream moved - refreshing status buffer")
        status_buffer:dispatch_refresh(nil, "auto_fetch")
      end
    end)

    if not ok then
      logger.debug("[AUTO FETCH]: failed silently - " .. tostring(err))
    end
  end)

  -- Clear the single-flight flag on success, failure and cancellation.
  task:on_complete(function()
    in_flight = false
  end)
end

return M
