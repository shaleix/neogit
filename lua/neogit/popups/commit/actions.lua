local M = {}

local CommitSelectViewBuffer = require("neogit.buffers.commit_select_view")
local git = require("neogit.lib.git")
local input = require("neogit.lib.input")
local notification = require("neogit.lib.notification")
local config = require("neogit.config")
local a = require("neogit.lib.async")

-- Maximum bytes of staged diff fed to the AI Commit generator context.
local AI_COMMIT_DIFF_LIMIT = 10000

---Context handed to ai_commit.generator: the staged file names plus the
---staged diff (truncated), so message generators have the raw material
---without spawning git themselves.
---@return { files: string[], diff: string }
local function staged_context()
  local files = vim.tbl_map(function(item)
    return item.name
  end, git.repo.state.staged.items)

  local diff = ""
  if #files > 0 then
    local result = git.cli.diff.no_ext_diff.cached.call { hidden = true }
    diff = table.concat(result.stdout, "\n"):sub(1, AI_COMMIT_DIFF_LIMIT)
  end

  return { files = files, diff = diff }
end

---@param popup PopupData
---@return boolean
local function allow_empty(popup)
  return vim.tbl_contains(popup:get_arguments(), "--allow-empty")
    or vim.tbl_contains(popup:get_arguments(), "--all")
end

local function confirm_modifications()
  if
    git.branch.upstream()
    and #git.repo.state.upstream.unmerged.items < 1
    and config.values.prompt_amend_commit
    and not input.get_permission(
      string.format(
        "This commit has already been published to %s, do you really want to modify it?",
        git.branch.upstream()
      )
    )
  then
    return false
  end

  return true
end

---@param popup PopupData
---@param args string[] Additional positional/flag arguments
---@param opts table See git.commit.create opts (edit/no_edit/all/amend/only)
---@return GitResult
local function do_commit(popup, args, opts)
  return git.commit.create(
    vim.list_extend(vim.list_extend({}, popup:get_arguments()), args),
    vim.tbl_extend("keep", opts or {}, {
      autocmd = "NeogitCommitComplete",
      msg = {
        success = "Committed",
        fail = "Commit failed",
      },
      show_diff = config.values.commit_editor.show_staged_diff,
    })
  )
end

local function commit_special(popup, method, opts)
  if not git.status.anything_staged() and not allow_empty(popup) then
    if git.status.anything_unstaged() then
      if input.get_permission("Nothing is staged. Commit all uncommitted changed?") then
        opts.all = true
      else
        return
      end
    else
      notification.warn("No changes to commit.")
      return
    end
  end

  local commit = popup.state.env.commit
    or CommitSelectViewBuffer.new(git.log.list(), git.remote.list()):open_async()[1]
  if not commit then
    return
  end

  if opts.rebase and not git.log.is_ancestor(commit, "HEAD") then
    local msg = string.format("'%s' isn't an ancestor of HEAD.", string.sub(commit, 1, 7))
    local choice = input.get_choice(msg, {
      values = {
        "&create without rebasing",
        "&select other",
        "&abort",
      },
      default = 3,
    })

    if choice == "c" then
      opts.rebase = false
    elseif choice == "s" then
      commit = CommitSelectViewBuffer.new(git.log.list(), git.remote.list()):open_async()[1]
    else
      return
    end
  end

  a.util.scheduler()
  do_commit(popup, { method:format(commit) }, {
    edit = opts.edit,
    no_edit = not opts.edit,
    all = opts.all,
  })

  if opts.rebase then
    a.util.scheduler()
    git.rebase.instantly(commit .. "~1", { "--keep-empty" })
  end
end

function M.commit(popup)
  if not git.status.anything_staged() and not allow_empty(popup) then
    notification.warn("No changes to commit.")
    return
  end

  do_commit(popup, {}, {})
end

---AI Commit: ask the configured generator for a message and commit without
---opening the editor. Falls back to the regular editor flow when the
---generator is missing, fails, returns an empty message, or times out.
---@param popup PopupData
function M.ai_commit(popup)
  if not git.status.anything_staged() and not allow_empty(popup) then
    notification.warn("No changes to commit.")
    return
  end

  local settings = config.values.ai_commit or {}
  local generator = settings.generator
  if type(generator) ~= "function" then
    -- No custom generator: fall back to the built-in OpenAI-compatible
    -- client when the declarative backend is configured.
    if settings.model and settings.model ~= "" then
      generator = function(done, ctx)
        require("neogit.lib.ai").generate(ctx, settings, done)
      end
    else
      notification.warn(
        "AI Commit: set ai_commit.model (built-in client) or ai_commit.generator in your neogit config"
      )
      return
    end
  end

  local loading = require("neogit.lib.loading")
  loading.show("AI Commit: generating message...")

  local ctx = staged_context()
  local timer = vim.uv.new_timer()
  local settled = false

  -- Single settlement point: message commits directly, anything else
  -- (empty/nil, error, timeout) falls back to the editor-based flow.
  -- `finish` fires from vim.schedule/system callbacks, i.e. OUTSIDE any
  -- async context - but do_commit needs one (the editor path goes through
  -- client.wrap, which calls async.util.scheduler). Run it in a fresh
  -- async task; otherwise the fallback/success path dies with
  -- "wrapped function called outside an async context".
  local commit_async = a.void(do_commit)

  local finish = vim.schedule_wrap(function(message)
    if settled then
      return
    end
    settled = true

    if timer then
      timer:close()
    end

    message = vim.trim(message or "")
    if message ~= "" then
      -- msg = {} silences the generic "Committed" notification: the
      -- loading indicator settles into the final message instead.
      a.run(function()
        return do_commit(popup, {}, { message = message, msg = {} })
      end, function(result)
        if result.code == 0 then
          loading.done(("AI Commit: %s"):format(message), vim.log.levels.INFO)

          -- The editor-based flow refreshes via NeogitEditorClosed; the -m
          -- path skips the editor, so refresh the status buffer explicitly.
          local status = require("neogit.buffers.status")
          local instance = status.instance()
          if instance then
            instance:dispatch_refresh(nil, "ai_commit")
          end
        else
          loading.done("AI Commit: commit failed", vim.log.levels.ERROR)
        end
      end)
    else
      loading.done("AI Commit: empty message - opening editor instead", vim.log.levels.WARN)
      commit_async(popup, {}, {})
    end
  end)

  timer:start((settings.timeout or 30) * 1000, 0, function()
    -- Settle with the precise reason first; finish("")'s own done() is a no-op.
    loading.done("AI Commit: generator timed out - opening editor instead", vim.log.levels.WARN)
    finish("")
  end)

  local ok, err = pcall(generator, finish, ctx)
  if not ok then
    loading.done(
      ("AI Commit: generator failed (%s) - opening editor instead"):format(tostring(err):sub(1, 120)),
      vim.log.levels.WARN
    )
    finish("")
  end
end

function M.extend(popup)
  if not git.status.anything_staged() and not allow_empty(popup) then
    if git.status.anything_unstaged() then
      if input.get_permission("Nothing is staged. Commit all uncommitted changes?") then
        git.status.stage_modified()
      else
        return
      end
    else
      return notification.warn("No changes to commit.")
    end
  end

  if not confirm_modifications() then
    return
  end

  do_commit(popup, {}, { no_edit = true, amend = true })
end

function M.reword(popup)
  if not confirm_modifications() then
    return
  end

  do_commit(popup, {}, { amend = true, only = true })
end

function M.amend(popup)
  if not confirm_modifications() then
    return
  end

  do_commit(popup, {}, { amend = true })
end

function M.fixup(popup)
  commit_special(popup, "--fixup=%s", { edit = false })
end

function M.squash(popup)
  commit_special(popup, "--squash=%s", { edit = false })
end

function M.augment(popup)
  commit_special(popup, "--squash=%s", { edit = true })
end

function M.alter(popup)
  commit_special(popup, "--fixup=amend:%s", { edit = true })
end

function M.revise(popup)
  commit_special(popup, "--fixup=reword:%s", { edit = true })
end

function M.instant_fixup(popup)
  if not confirm_modifications() then
    return
  end

  commit_special(popup, "--fixup=%s", { rebase = true, edit = false })
end

function M.instant_squash(popup)
  if not confirm_modifications() then
    return
  end

  commit_special(popup, "--squash=%s", { rebase = true, edit = false })
end

function M.absorb(popup)
  if vim.fn.executable("git-absorb") == 0 then
    notification.info("Absorb requires `https://github.com/tummychow/git-absorb` to be installed.")
    return
  end

  if not git.status.anything_staged() and not allow_empty(popup) then
    if git.status.anything_unstaged() then
      if input.get_permission("Nothing is staged. Absorb all unstaged changes?") then
        git.status.stage_modified()
      else
        return
      end
    else
      notification.warn("There are no changes that could be absorbed")
      return
    end
  end

  local commit = popup.state.env.commit
    or CommitSelectViewBuffer.new(
      git.log.list { "HEAD" },
      git.remote.list(),
      "Select a base commit for the absorb stack with <cr>, or <esc> to abort"
    )
      :open_async()[1]
  if not commit then
    return
  end

  git.commit.absorb(commit)
end

-- Test seam: context assembly for AI Commit generators; not public API.
M.internal = {
  staged_context = staged_context,
}

return M
