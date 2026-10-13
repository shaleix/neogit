local config = require("neogit.config")
local Buffer = require("neogit.lib.buffer")
local ui = require("neogit.buffers.status.ui")
local popups = require("neogit.popups")
local git = require("neogit.lib.git")
local Repo = require("neogit.lib.git.repository")
local Watcher = require("neogit.watcher")
local a = require("neogit.lib.async")
local logger = require("neogit.logger") -- TODO: Add logging
local event = require("neogit.lib.event")
local banner_transition = require("neogit.lib.banner_transition")

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

  -- Bind the repo singleton to THIS buffer's repository before the action
  -- runs. Actions resolve their target through `git.repo` (which follows the
  -- last directory handed to Repo.instance): with several repositories'
  -- status buffers alive at once, that pointer may name a different
  -- repository, and index writes (stage/unstage/reset) would silently land
  -- in the wrong repository's index.
  -- The action is invoked through its returned closure: n_*/v_* build an
  -- a.void(...) coroutine there, and nvim's keymap callback is what normally
  -- runs it.
  return function()
    Repo.instance(self.cwd)
    local task = action(self)
    if type(task) == "function" then
      return task()
    end
    return task
  end
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
        -- cursor left the file items (including onto Recent Commits rows):
        -- hide the preview split
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

  -- Popup launches are wired from the shared spec table in
  -- buffers/status/actions.lua: one row per popup per mode names the popup,
  -- its mode, and the context extractor it hands to the popup.
  local status_actions = require("neogit.buffers.status.actions")

  local mode_mappings = {
    v = {
      [mappings["Discard"]] = self:_action("v_discard"),
      [mappings["Reverse"]] = self:_action("v_reverse"),
      [mappings["Stage"]] = self:_action("v_stage"),
      [mappings["Unstage"]] = self:_action("v_unstage"),
      [mappings["Untrack"]] = self:_action("v_untrack"),
    },
    n = {
      [mappings["Command"]] = self:_action("n_command"),
      [mappings["OpenTree"]] = self:_action("n_open_tree"),
      [mappings["MoveDown"]] = self:_action("n_down"),
      [mappings["MoveUp"]] = self:_action("n_up"),
      [mappings["Untrack"]] = self:_action("n_untrack"),
      [mappings["Rename"]] = self:_action("n_rename"),
      [mappings["Toggle"]] = self:_action("n_toggle"),
      [mappings["OpenFold"]] = self:_action("n_open_fold"),
      [mappings["CloseFold"]] = self:_action("n_close_fold"),
      [mappings["Close"]] = self:_action("n_close"),
      [mappings["OpenOrScrollDown"]] = self:_action("n_open_or_scroll_down"),
      [mappings["OpenOrScrollUp"]] = self:_action("n_open_or_scroll_up"),
      [mappings["PeekUp"]] = self:_action("n_peek_up"),
      [mappings["PeekDown"]] = self:_action("n_peek_down"),
      [mappings["RefreshBuffer"]] = self:_action("n_refresh_buffer"),
      [mappings["Depth1"]] = self:_action("n_depth1"),
      [mappings["Depth2"]] = self:_action("n_depth2"),
      [mappings["Depth3"]] = self:_action("n_depth3"),
      [mappings["Depth4"]] = self:_action("n_depth4"),
      [mappings["CommandHistory"]] = self:_action("n_command_history"),
      [mappings["ShowRefs"]] = self:_action("n_show_refs"),
      [mappings["YankSelected"]] = self:_action("n_yank_selected"),
      [mappings["Discard"]] = self:_action("n_discard"),
      [mappings["Reverse"]] = self:_action("n_reverse"),
      [mappings["GoToNextHunkHeader"]] = self:_action("n_go_to_next_hunk_header"),
      [mappings["GoToPreviousHunkHeader"]] = self:_action("n_go_to_previous_hunk_header"),
      [mappings["InitRepo"]] = self:_action("n_init_repo"),
      [mappings["Stage"]] = self:_action("n_stage"),
      [mappings["StageAll"]] = self:_action("n_stage_all"),
      [mappings["StageUnstaged"]] = self:_action("n_stage_unstaged"),
      [mappings["Unstage"]] = self:_action("n_unstage"),
      [mappings["UnstageStaged"]] = self:_action("n_unstage_staged"),
      [mappings["GoToFile"]] = self:_action("n_goto_file"),
      [mappings["GoToParentRepo"]] = self:_action("n_goto_parent_repo"),
      [mappings["TabOpen"]] = self:_action("n_tab_open"),
      [mappings["SplitOpen"]] = self:_action("n_split_open"),
      [mappings["VSplitOpen"]] = self:_action("n_vertical_split_open"),
      [mappings["NextSection"]] = self:_action("n_next_section"),
      [mappings["PreviousSection"]] = self:_action("n_prev_section"),
      ["V"] = function()
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
  }

  for _, spec in ipairs(status_actions.popup_specs) do
    mode_mappings[spec.mode][popups.mapping_for(status_actions.command_name(spec.name))] =
      self:_action(spec.mode .. "_" .. spec.name .. "_popup")
  end

  self.buffer = Buffer.create {
    -- One buffer per repository: a fixed name made the second repository's
    -- status view reuse the first one's buffer (same name => same buffer),
    -- so its refresh overwrote the other repo's rendering and actions mixed
    -- up which repository they read from and wrote to. Suffixing with the
    -- worktree cwd keeps every repository's status view in its own buffer.
    name = "NeogitStatus (" .. self.cwd .. ")",
    filetype = "NeogitStatus",
    cwd = self.cwd,
    context_highlight = not config.values.disable_context_highlighting and config.values.log_pager == nil,
    kind = kind or config.values.kind or "tab",
    disable_line_numbers = config.values.disable_line_numbers,
    disable_relative_line_numbers = config.values.disable_relative_line_numbers,
    foldmarkers = not config.values.disable_signs,
    active_item_highlight = true,
    on_detach = function()
      -- Buffer gone mid-pulse: restore the captured group definitions so the
      -- banner transition cannot leak past the status buffer's lifetime.
      banner_transition.finish()
      -- Two-phase open: while the repo is still provisional nothing was
      -- registered (see `after`), so there is nothing to unregister.
      if self._watcher_registered then
        Watcher.instance(self.root):unregister(self)
        self._watcher_registered = false
      end
      require("neogit.buffers.diff_preview").close()

      if self.prev_autochdir then
        vim.o.autochdir = self.prev_autochdir
      end
    end,
    mappings = mode_mappings,
    user_mappings = config.get_user_mappings("status"),
    initialize = function()
      self.prev_autochdir = vim.o.autochdir
      vim.o.autochdir = false
    end,
    render = function(buffer)
      -- Cold open: the first refresh wave (which fetches status, HEAD commit
      -- info, recent commits, ...) is still in flight and state is empty, so
      -- render the loading placeholder. The refresh completion callback's
      -- redraw replaces it with real content. Warm re-opens of an already
      -- refreshed repo render the existing state directly.
      local repo = Repo.instance(self.cwd)
      -- Same width the real render (redraw) uses, so the banner does not
      -- jump sideways when the loading placeholder is replaced. The buffer
      -- arrives as an argument here: self.buffer is not assigned until
      -- Buffer.create returns, after this render has run.
      local width = nil
      if buffer.win_handle and vim.api.nvim_win_is_valid(buffer.win_handle) then
        width = vim.api.nvim_win_get_width(buffer.win_handle)
      end
      return ui.Status(repo.state, self.config, not repo._refreshed, width)
    end,
    ---@param buffer Buffer
    ---@param _win any
    after = function(buffer, _win)
      -- Two-phase open: while the repo is still provisional (async discovery
      -- in flight) there is no real root to watch and no git_dir to publish,
      -- and both lookups would spawn git - bind_repository() runs these once
      -- discovery has landed.
      if self:repo_bound() then
        Watcher.instance(self.root):register(self)
        self._watcher_registered = true
        vim.b.neogit_git_dir = git.repo.git_dir
      end
      -- Best-effort immediate anchor (when state is already rendered). The
      -- authoritative anchor lands in redraw after the first refresh: at open
      -- time the repo may not be refreshed yet.
      local target = buffer.ui:section_at_index(2) or buffer.ui:first_section()
      if target then
        buffer:move_cursor(target.first)
      end
      self._anchor_pending = true
    end,
    user_autocmds = {
      -- Resetting doesn't yield the correct repo state instantly, so we need to re-refresh after a few seconds
      -- in order to show the user the correct state.
      ["NeogitReset"] = self:deferred_refresh("reset"),
      ["NeogitBranchReset"] = self:deferred_refresh("reset_branch"),
      ["NeogitEditorClosed"] = self:deferred_refresh("editor_closed"),
      ["NeogitFetchComplete"] = self:deferred_refresh("fetch"),
      ["NeogitMerge"] = self:deferred_refresh("merge"),
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

  -- Banner pulse: cold open only (first refresh wave still in flight), and
  -- it runs for as long as that loading phase lasts. Warm re-opens of an
  -- already-refreshed repo skip it, later redraws never restart it, and the
  -- refresh completion callback finishes it.
  if not Repo.instance(self.cwd)._refreshed then
    banner_transition.start(self.buffer.handle)
  end

  -- Window-width tracking for the banner. These MUST be global, not
  -- buffer-local: buffer-local WinResized only fires while this buffer is
  -- current, but the status window is usually resized from a neighboring
  -- window. v:event.windows lists the actually-resized windows, so foreign
  -- resizes are filtered out. The augroup is owned by the buffer and gets
  -- deleted on detach, which removes these too.
  vim.api.nvim_create_autocmd("WinResized", {
    group = self.buffer.autocmd_group,
    callback = function()
      local win = self.buffer.win_handle
      if not win or not vim.api.nvim_win_is_valid(win) then
        return
      end
      local wins = vim.v.event and vim.v.event.windows
      if wins == nil or vim.tbl_contains(vim.tbl_map(tostring, wins), tostring(win)) then
        self:redraw()
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = self.buffer.autocmd_group,
    callback = function()
      if self.buffer.win_handle and vim.api.nvim_win_is_valid(self.buffer.win_handle) then
        self:redraw()
      end
    end,
  })

  -- Background auto-fetch once per open (never part of a refresh cycle):
  -- keeps the Head line's ↓N behind counter current when the remote moved
  -- since the last manual fetch. Two-phase open: with discovery still in
  -- flight there is no repository to fetch in (and probing would spawn git),
  -- so bind_repository() schedules the fetch once it binds.
  vim.schedule(function()
    if self:repo_bound() then
      require("neogit.lib.git.autofetch").trigger(self)
    end
  end)

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

---Whether this buffer's repository is fully bound (two-phase optimistic
---open): provisional instances carry empty paths until the async discovery
---lands and Repo.bind fills them.
---@return boolean
function M:repo_bound()
  return not Repo.instance(self.cwd).provisional
end

---Phase 2 of the two-phase optimistic open: discovery landed. Run what
---`open` deferred while the repo was provisional (watcher registration,
---buffer git-dir var, background auto-fetch), then drive the first
---refresh. Safe when the buffer is already gone (user closed it while
---discovery ran) - the repo stays bound either way, and every later
---refresh is a plain no-op guarded redraw.
---@param repo NeogitRepo
function M:bind_repository(repo)
  -- The handle can be wiped while discovery runs (user closes the window /
  -- :%bwipeout): nothing left to attach or refresh.
  if not self.buffer or not vim.api.nvim_buf_is_valid(self.buffer.handle) then
    return
  end

  if self._pending_binding then
    self._pending_binding = false
    self.root = repo.worktree_root
    Watcher.instance(self.root):register(self)
    self._watcher_registered = true
    self.buffer:call(function()
      vim.b.neogit_git_dir = repo.git_dir
    end)
    -- Mirror open()'s once-per-open auto-fetch, now that a repository
    -- exists to fetch in.
    vim.schedule(function()
      require("neogit.lib.git.autofetch").trigger(self)
    end)
  end

  self:dispatch_refresh()
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

  -- Route the refresh through this buffer's own repo instance: the global
  -- `git.repo` pointer follows the last directory any code handed to
  -- Repo.instance, so with multiple status buffers open it may name another
  -- repository (wrong data source, and the "status" callback slot of that
  -- other repo's instance table would be hijacked).
  Repo.instance(self.cwd):dispatch_refresh {
    source = "status",
    partial = partial,
    callback = function()
      -- First refresh wave after a cold open landed: stop the banner pulse
      -- and jump its groups back to their exact definitions.
      banner_transition.finish()
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
  -- Visible window width, for centering the title banner. Guarded: redraw
  -- can run from a watcher callback after the window is gone.
  local width = nil
  if self.buffer.win_handle and vim.api.nvim_win_is_valid(self.buffer.win_handle) then
    width = vim.api.nvim_win_get_width(self.buffer.win_handle)
  end

  local repo = Repo.instance(self.cwd)
  -- The loading flag follows the repo exactly like the cold-open render:
  -- a redraw racing the first refresh - or arriving while the two-phase
  -- open is still unbound - keeps the placeholder instead of flashing an
  -- empty sections UI.
  self.buffer.ui:render(unpack(ui.Status(repo.state, self.config, not repo._refreshed, width)))

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
