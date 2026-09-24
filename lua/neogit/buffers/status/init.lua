local config = require("neogit.config")
local Buffer = require("neogit.lib.buffer")
local ui = require("neogit.buffers.status.ui")
local popups = require("neogit.popups")
local git = require("neogit.lib.git")
local Watcher = require("neogit.watcher")
local a = require("neogit.lib.async")
local logger = require("neogit.logger") -- TODO: Add logging
local event = require("neogit.lib.event")

---@class Semaphore
---@field permits number
---@field acquire function

---@class StatusBuffer
---@field buffer Buffer instance
---@field config NeogitConfig
---@field root string
---@field cwd string
local M = {}
M.__index = M

local instances = {}

---@class SubmoduleInfo
---@field submodules string[] A list with the relative paths to the project's submodules
---@field parent_repo string? If we are in a submodule, cache the abs path to the parent repo

---@type table<string, SubmoduleInfo>
local submodule_info_per_root = {}
local NIL_SENTINEL = {} -- distinguishes "computed nil" from "not computed yet" in the lazy table

local function unlazy(value)
  if value == NIL_SENTINEL then
    return nil
  end
  return value
end

---@return string?
function M:parent_repo()
  local info = submodule_info_per_root[self.root]
  return unlazy(info and info.parent_repo)
end

---@return string[]
function M:submodules()
  local info = submodule_info_per_root[self.root]
  return unlazy(info and info.submodules) or {}
end

---@param abs_path string
---@return boolean
function M:has_submodule(abs_path)
  local dir = require("neogit.lib.path"):new(abs_path)
  if not dir:exists() or not dir:is_dir() then
    return false
  end
  local rel_path = dir:make_relative(self.cwd)
  for _, submodule in ipairs(self:submodules()) do
    if submodule == rel_path then
      return true
    end
  end
  return false
end

---@param instance StatusBuffer
---@param dir string
function M.register(instance, dir)
  local dir = vim.fs.normalize(dir)
  logger.debug("[STATUS] Registering instance for: " .. dir)

  instances[dir] = instance

  -- Submodule/parent-repo lookups each spawn a git process and are only
  -- needed for navigation actions, so compute them lazily on first access
  -- instead of blocking buffer creation. Results (including nils) are cached.
  submodule_info_per_root[instance.root] = setmetatable({}, {
    __index = function(t, key)
      local value
      if key == "submodules" then
        value = git.submodule.list()
      elseif key == "parent_repo" then
        value = git.rev_parse.parent_repo()
      else
        return nil
      end

      rawset(t, key, value or NIL_SENTINEL)
      return value
    end,
  })
end

---@param dir? string
---@return StatusBuffer
function M.instance(dir)
  local dir = dir or vim.uv.cwd()
  assert(dir, "cannot locate a status buffer with no cwd")

  return instances[vim.fs.normalize(dir)]
end

---@param config NeogitConfig
---@param root string
---@param cwd string
---@return StatusBuffer
function M.new(config, root, cwd)
  if M.instance(cwd) then
    logger.debug("Found instance for cwd " .. cwd)
    return M.instance(cwd)
  end

  local instance = {
    config = config,
    root = root,
    cwd = vim.fs.normalize(cwd),
    buffer = nil,
    fold_state = nil,
    cursor_state = nil,
    view_state = nil,
    -- dispatch_refresh coalescing (per instance, see merge_partial)
    _refresh_scheduled = false,
    _pending_partial = nil,
  }

  setmetatable(instance, M)
  M.register(instance, cwd)

  return instance
end

---@return boolean
function M.is_open()
  return (M.instance() and M.instance().buffer and M.instance().buffer:is_visible()) == true
end

function M:_action(name)
  local action = require("neogit.buffers.status.actions")[name]
  assert(action, ("Status Buffer action %q is undefined"):format(name))

  return action(self)
end

---status.diff_preview: debounce cursor movement, then render the diff of
---the file item under the cursor in the preview window.
function M:_preview_diff_under_cursor()
  local preview_config = self.config.status.diff_preview
  if not preview_config or not preview_config.enabled then
    return
  end

  if self._preview_timer then
    self._preview_timer:close()
    self._preview_timer = nil
  end

  self._preview_timer = vim.defer_fn(function()
    self._preview_timer = nil
    if not self.buffer or not self.buffer:is_visible() then
      return
    end

    self.buffer:win_call(function()
      local item = self.buffer.ui:get_item_under_cursor()
      local section = self.buffer.ui:get_current_section()
      local section_name = section and section.options.section

      if
        item
        and item.name
        and item.mode
        and vim.tbl_contains({ "untracked", "unstaged", "staged" }, section_name)
      then
        require("neogit.buffers.diff_preview").show(self.buffer, section_name, item)
      else
        -- cursor left the file items: hide the preview split
        require("neogit.buffers.diff_preview").close()
      end
    end)
  end, preview_config.debounce or 200)
end

---@param kind nil|string
---| "'floating'"
---| "'split'"
---| "'tab'"
---| "'split'"
---| "'vsplit'"
---@return StatusBuffer
function M:open(kind)
  if self.buffer and self.buffer:is_visible() then
    logger.debug("[STATUS] An Instance is already open - focusing it")
    self.buffer:focus()
    return self
  end

  -- Toggle-reopen: fold state carries over, but the last cursor/view position
  -- must not - the freshly opened buffer anchors on the second section.
  self.cursor_state = nil
  self.view_state = nil
  self._programmatic = self._programmatic or false

  local mappings = config.get_reversed_status_maps()

  self.buffer = Buffer.create {
    name = "NeogitStatus",
    filetype = "NeogitStatus",
    cwd = self.cwd,
    context_highlight = not config.values.disable_context_highlighting and config.values.log_pager == nil,
    kind = kind or config.values.kind or "tab",
    disable_line_numbers = config.values.disable_line_numbers,
    disable_relative_line_numbers = config.values.disable_relative_line_numbers,
    foldmarkers = not config.values.disable_signs,
    active_item_highlight = true,
    on_detach = function()
      Watcher.instance(self.root):unregister(self)
      require("neogit.buffers.diff_preview").close()

      if self.prev_autochdir then
        vim.o.autochdir = self.prev_autochdir
      end
    end,
    --stylua: ignore start
    mappings = {
      v = {
        [mappings["Discard"]]                   = self:_action("v_discard"),
        [mappings["Reverse"]]                   = self:_action("v_reverse"),
        [mappings["Stage"]]                     = self:_action("v_stage"),
        [mappings["Unstage"]]                   = self:_action("v_unstage"),
        [mappings["Untrack"]]                   = self:_action("v_untrack"),
        [popups.mapping_for("BisectPopup")]     = self:_action("v_bisect_popup"),
        [popups.mapping_for("BranchPopup")]     = self:_action("v_branch_popup"),
        [popups.mapping_for("CherryPickPopup")] = self:_action("v_cherry_pick_popup"),
        [popups.mapping_for("CommitPopup")]     = self:_action("v_commit_popup"),
        [popups.mapping_for("DiffPopup")]       = self:_action("v_diff_popup"),
        [popups.mapping_for("FetchPopup")]      = self:_action("v_fetch_popup"),
        [popups.mapping_for("HelpPopup")]       = self:_action("v_help_popup"),
        [popups.mapping_for("IgnorePopup")]     = self:_action("v_ignore_popup"),
        [popups.mapping_for("LogPopup")]        = self:_action("v_log_popup"),
        [popups.mapping_for("MarginPopup")]     = self:_action("v_margin_popup"),
        [popups.mapping_for("MergePopup")]      = self:_action("v_merge_popup"),
        [popups.mapping_for("PullPopup")]       = self:_action("v_pull_popup"),
        [popups.mapping_for("PushPopup")]       = self:_action("v_push_popup"),
        [popups.mapping_for("RebasePopup")]     = self:_action("v_rebase_popup"),
        [popups.mapping_for("RemotePopup")]     = self:_action("v_remote_popup"),
        [popups.mapping_for("ResetPopup")]      = self:_action("v_reset_popup"),
        [popups.mapping_for("RevertPopup")]     = self:_action("v_revert_popup"),
        [popups.mapping_for("StashPopup")]      = self:_action("v_stash_popup"),
        [popups.mapping_for("TagPopup")]        = self:_action("v_tag_popup"),
        [popups.mapping_for("WorktreePopup")]   = self:_action("v_worktree_popup"),
      },
      n = {
        [mappings["Command"]]                   = self:_action("n_command"),
        [mappings["OpenTree"]]                  = self:_action("n_open_tree"),
        [mappings["MoveDown"]]                  = self:_action("n_down"),
        [mappings["MoveUp"]]                    = self:_action("n_up"),
        [mappings["Untrack"]]                   = self:_action("n_untrack"),
        [mappings["Rename"]]                    = self:_action("n_rename"),
        [mappings["Toggle"]]                    = self:_action("n_toggle"),
        [mappings["OpenFold"]]                  = self:_action("n_open_fold"),
        [mappings["CloseFold"]]                 = self:_action("n_close_fold"),
        [mappings["Close"]]                     = self:_action("n_close"),
        [mappings["OpenOrScrollDown"]]          = self:_action("n_open_or_scroll_down"),
        [mappings["OpenOrScrollUp"]]            = self:_action("n_open_or_scroll_up"),
        [mappings["RefreshBuffer"]]             = self:_action("n_refresh_buffer"),
        [mappings["Depth1"]]                    = self:_action("n_depth1"),
        [mappings["Depth2"]]                    = self:_action("n_depth2"),
        [mappings["Depth3"]]                    = self:_action("n_depth3"),
        [mappings["Depth4"]]                    = self:_action("n_depth4"),
        [mappings["CommandHistory"]]            = self:_action("n_command_history"),
        [mappings["ShowRefs"]]                  = self:_action("n_show_refs"),
        [mappings["YankSelected"]]              = self:_action("n_yank_selected"),
        [mappings["Discard"]]                   = self:_action("n_discard"),
        [mappings["Reverse"]]                   = self:_action("n_reverse"),
        [mappings["GoToNextHunkHeader"]]        = self:_action("n_go_to_next_hunk_header"),
        [mappings["GoToPreviousHunkHeader"]]    = self:_action("n_go_to_previous_hunk_header"),
        [mappings["InitRepo"]]                  = self:_action("n_init_repo"),
        [mappings["Stage"]]                     = self:_action("n_stage"),
        [mappings["StageAll"]]                  = self:_action("n_stage_all"),
        [mappings["StageUnstaged"]]             = self:_action("n_stage_unstaged"),
        [mappings["Unstage"]]                   = self:_action("n_unstage"),
        [mappings["UnstageStaged"]]             = self:_action("n_unstage_staged"),
        [mappings["GoToFile"]]                  = self:_action("n_goto_file"),
        [mappings["GoToParentRepo"]]            = self:_action("n_goto_parent_repo"),
        [mappings["TabOpen"]]                   = self:_action("n_tab_open"),
        [mappings["SplitOpen"]]                 = self:_action("n_split_open"),
        [mappings["VSplitOpen"]]                = self:_action("n_vertical_split_open"),
        [mappings["NextSection"]]               = self:_action("n_next_section"),
        [mappings["PreviousSection"]]           = self:_action("n_prev_section"),
        [popups.mapping_for("BisectPopup")]     = self:_action("n_bisect_popup"),
        [popups.mapping_for("BranchPopup")]     = self:_action("n_branch_popup"),
        [popups.mapping_for("CherryPickPopup")] = self:_action("n_cherry_pick_popup"),
        [popups.mapping_for("CommitPopup")]     = self:_action("n_commit_popup"),
        [popups.mapping_for("DiffPopup")]       = self:_action("n_diff_popup"),
        [popups.mapping_for("FetchPopup")]      = self:_action("n_fetch_popup"),
        [popups.mapping_for("HelpPopup")]       = self:_action("n_help_popup"),
        [popups.mapping_for("IgnorePopup")]     = self:_action("n_ignore_popup"),
        [popups.mapping_for("LogPopup")]        = self:_action("n_log_popup"),
        [popups.mapping_for("MarginPopup")]     = self:_action("n_margin_popup"),
        [popups.mapping_for("MergePopup")]      = self:_action("n_merge_popup"),
        [popups.mapping_for("PullPopup")]       = self:_action("n_pull_popup"),
        [popups.mapping_for("PushPopup")]       = self:_action("n_push_popup"),
        [popups.mapping_for("RebasePopup")]     = self:_action("n_rebase_popup"),
        [popups.mapping_for("RemotePopup")]     = self:_action("n_remote_popup"),
        [popups.mapping_for("ResetPopup")]      = self:_action("n_reset_popup"),
        [popups.mapping_for("RevertPopup")]     = self:_action("n_revert_popup"),
        [popups.mapping_for("StashPopup")]      = self:_action("n_stash_popup"),
        [popups.mapping_for("TagPopup")]        = self:_action("n_tag_popup"),
        [popups.mapping_for("WorktreePopup")]   = self:_action("n_worktree_popup"),
        ["V"]                                   = function()
          vim.cmd("norm! V")
        end,
        -- scroll the diff preview split when it is open; otherwise keep
        -- native half-page scrolling on the status buffer
        ["<C-d>"] = function()
          if not require("neogit.buffers.diff_preview").scroll("<C-d>") then
            vim.cmd(("normal! %d<C-d>"):format(vim.v.count1))
          end
        end,
        ["<C-u>"] = function()
          if not require("neogit.buffers.diff_preview").scroll("<C-u>") then
            vim.cmd(("normal! %d<C-u>"):format(vim.v.count1))
          end
        end,
      },
    },
    --stylua: ignore end
    user_mappings = config.get_user_mappings("status"),
    initialize = function()
      self.prev_autochdir = vim.o.autochdir
      vim.o.autochdir = false
    end,
    render = function()
      return ui.Status(git.repo.state, self.config)
    end,
    ---@param buffer Buffer
    ---@param _win any
    after = function(buffer, _win)
      Watcher.instance(self.root):register(self)
      -- Best-effort immediate anchor (when state is already rendered). The
      -- authoritative anchor lands in redraw after the first refresh: at open
      -- time the repo may not be refreshed yet.
      local target = buffer.ui:section_at_index(2) or buffer.ui:first_section()
      if target then
        buffer:move_cursor(target.first)
      end
      self._anchor_pending = true
      vim.b.neogit_git_dir = git.repo.git_dir
    end,
    user_autocmds = {
      -- Resetting doesn't yield the correct repo state instantly, so we need to re-refresh after a few seconds
      -- in order to show the user the correct state.
      ["NeogitReset"] = self:deferred_refresh("reset"),
      ["NeogitBranchReset"] = self:deferred_refresh("reset_branch"),
      ["NeogitEditorClosed"] = self:deferred_refresh("editor_closed"),
    },
    autocmds = {
      ["FocusGained"] = self:deferred_refresh("focused", 10),
      -- user cursor movement cancels the pending open anchor; programmatic
      -- moves set _programmatic so they do not
      ["CursorMoved"] = function()
        if not self._programmatic then
          self._anchor_pending = false
        end
        self:_preview_diff_under_cursor()
      end,
    },
  }

  return self
end

function M:close()
  if self.buffer then
    self.fold_state = self.buffer.ui:get_fold_state()
    self.cursor_state = self.buffer:cursor_line()
    self.view_state = self.buffer:save_view()

    logger.debug("[STATUS] Closing Buffer")
    self.buffer:close()
    self.buffer = nil
  end
end

function M:chdir(dir)
  local Path = require("neogit.lib.path")

  local destination = Path:new(dir)
  vim.wait(5000, function()
    return destination:exists()
  end)

  vim.schedule(function()
    logger.debug("[STATUS] Changing Dir: " .. dir)
    vim.api.nvim_set_current_dir(dir)
    require("neogit.lib.git.repository").instance(dir)
    self.new(config.values, git.repo.worktree_root, dir):open("replace"):dispatch_refresh()
  end)
end

function M:focus()
  if self.buffer then
    logger.debug("[STATUS] Focusing Buffer")
    self.buffer:focus()
  end
end

function M:refresh(partial, reason)
  logger.debug("[STATUS] Beginning refresh from " .. (reason or "UNKNOWN"))

  -- Capture the semantic cursor location before the refresh mutates the
  -- model. Any visible window qualifies (win-scoped reads, not just the
  -- focused one), so background/watcher refreshes restore position by
  -- meaning instead of drifting with raw line numbers.
  local cursor, view
  if self.buffer and self.buffer:is_visible() then
    self.buffer:win_call(function()
      cursor = self.buffer.ui:get_cursor_location(vim.api.nvim_win_get_cursor(0)[1])
      view = self.buffer:save_view()
    end)
  end

  git.repo:dispatch_refresh {
    source = "status",
    partial = partial,
    callback = function()
      self:redraw(cursor, view)
      event.send("StatusRefreshed")
      logger.info("[STATUS] Refresh complete")
    end,
  }
end

---@param cursor CursorLocation?
---@param view table?
---@param fold_state table? explicit fold state to restore (e.g. captured by
---the watcher before dispatching a refresh)
function M:redraw(cursor, view, fold_state)
  if not self.buffer then
    logger.debug("[STATUS] Buffer no longer exists - bail")
    return
  end

  logger.debug("[STATUS] Rendering UI")
  self.buffer.ui:render(unpack(ui.Status(git.repo.state, self.config)))

  if fold_state then
    logger.debug("[STATUS] Restoring explicit fold state")
    self.buffer.ui:set_fold_state(fold_state)
    self.fold_state = nil
  elseif self.fold_state and self.buffer then
    logger.debug("[STATUS] Restoring fold state")
    self.buffer.ui:set_fold_state(self.fold_state)
    self.fold_state = nil
  end

  -- Programmatic cursor movements must not cancel the pending anchor.
  self._programmatic = true
  local ok, err = pcall(function()
    if self.cursor_state and self.view_state and self.buffer then
      logger.debug("[STATUS] Restoring cursor and view state")
      self.buffer:restore_view(self.view_state, self.cursor_state)
      self.view_state = nil
      self.cursor_state = nil
    elseif cursor and view and self.buffer then
      self.buffer:restore_view(view, self.buffer.ui:resolve_cursor_location(cursor))
    end
  end)
  self._programmatic = false
  assert(ok, err)

  -- Open anchor: lands here once real state is rendered (at open time the
  -- repo may not be refreshed yet). Cancelled by any user cursor movement.
  if self._anchor_pending then
    self._anchor_pending = false
    local target = self.buffer.ui:section_at_index(2) or self.buffer.ui:first_section()
    if target then
      logger.debug("[STATUS] Anchoring cursor on second section")
      self._programmatic = true
      pcall(function()
        self.buffer:move_cursor(target.first)
      end)
      self._programmatic = false
    end
  end
end

---Merge two partial refresh specs: nil means "full refresh" and absorbs
---the other side; otherwise the update_diffs filters are unioned, so
---dispatches coalesced into one tick cannot lose diff-cache invalidations.
local function merge_partial(a, b)
  if a == nil or b == nil then
    return nil
  end

  local merged, seen = {}, {}
  for _, spec in ipairs { a, b } do
    for _, f in ipairs(spec.update_diffs or {}) do
      if not seen[f] then
        seen[f] = true
        table.insert(merged, f)
      end
    end
  end

  return { update_diffs = merged }
end

M.dispatch_refresh = a.void(function(self, partial, reason)
  -- Per-instance coalescing: the old module-level flag let a scheduled
  -- refresh for one buffer silently drop dispatches from every other
  -- instance in the same tick (e.g. parent repo + submodule status
  -- buffers), losing their partial diff invalidations with it.
  if self._refresh_scheduled then
    self._pending_partial = merge_partial(self._pending_partial, partial)
    return
  end

  self._refresh_scheduled = true
  self._pending_partial = partial

  vim.schedule(function()
    self._refresh_scheduled = false
    local merged = self._pending_partial
    self._pending_partial = nil
    self:refresh(merged, reason)
  end)
end)

---@param reason string
---@param wait number? timeout in ms, or 2 seconds
---@return fun()
function M:deferred_refresh(reason, wait)
  return function()
    vim.defer_fn(function()
      self:dispatch_refresh(nil, reason)
    end, wait or 2000)
  end
end

function M:reset()
  logger.debug("[STATUS] Resetting repo and refreshing - CWD: " .. vim.uv.cwd())
  git.repo:reset()
  self:refresh(nil, "reset")
end

M.dispatch_reset = a.void(function(self)
  self:reset()
end)

function M:id()
  return "StatusBuffer"
end

return M
