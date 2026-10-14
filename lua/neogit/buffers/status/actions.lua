-- NOTE: `v_` prefix stands for visual mode actions, `n_` for normal mode.
--
local a = require("neogit.lib.async")
local git = require("neogit.lib.git")
local popups = require("neogit.popups")
local logger = require("neogit.logger")
local input = require("neogit.lib.input")
local notification = require("neogit.lib.notification")
local util = require("neogit.lib.util")
local config = require("neogit.config")
local jump = require("neogit.lib.jump")

local FuzzyFinderBuffer = require("neogit.buffers.fuzzy_finder")

local fn = vim.fn
local api = vim.api

local function absolute_path(path)
  if vim.startswith(path, "/") or path:match("^%a:[/\\]") or vim.startswith(path, "\\\\") then
    return vim.fs.normalize(path)
  end

  return vim.fs.normalize(git.repo.worktree_root .. "/" .. path)
end

local function path_contains(parent, child)
  parent = vim.fs.normalize(parent)
  child = vim.fs.normalize(child)

  return child == parent or vim.startswith(child .. "/", parent .. "/")
end

local function move_cwds_out_of_dir(dir)
  local root = vim.fs.normalize(git.repo.worktree_root)

  if path_contains(dir, vim.uv.cwd()) then
    api.nvim_set_current_dir(root)
  end

  for _, tabpage in ipairs(api.nvim_list_tabpages()) do
    for _, win in ipairs(api.nvim_tabpage_list_wins(tabpage)) do
      api.nvim_win_call(win, function()
        if path_contains(dir, fn.getcwd()) then
          vim.cmd.lcd(fn.fnameescape(root))
        end
      end)
    end
  end
end

local function cleanup_dir(dir)
  if vim.in_fast_event() then
    a.util.scheduler()
  end

  dir = absolute_path(dir)
  move_cwds_out_of_dir(dir)

  for name, type in vim.fs.dir(dir, { depth = math.huge }) do
    if type == "file" then
      local bufnr = fn.bufnr(vim.fs.joinpath(dir, name))
      if bufnr > 0 then
        api.nvim_buf_delete(bufnr, { force = false })
      end
    end
  end

  fn.delete(dir, "rf")
end

local function empty_dir(dir)
  local ok, iter = pcall(vim.fs.dir, dir)
  return ok and iter and iter() == nil
end

local function cleanup_empty_parent_dirs(path)
  local root = vim.fs.normalize(git.repo.worktree_root)
  local dir = vim.fs.dirname(absolute_path(path))

  while dir and dir ~= "." do
    dir = vim.fs.normalize(dir)

    if dir == root or not path_contains(root, dir) then
      break
    end

    if fn.isdirectory(dir) == 0 or not empty_dir(dir) then
      break
    end

    fn.delete(dir, "d")
    dir = vim.fs.dirname(dir)
  end
end

---@param items StatusItem[]
local function cleanup_items(items)
  if vim.in_fast_event() then
    a.util.scheduler()
  end

  for _, item in ipairs(items) do
    local path = item.absolute_path or item.name
    logger.debug("[cleanup_items()] Cleaning " .. vim.inspect(path))
    assert(path, "cleanup_items() - item must have a name")
    local resolved_path = absolute_path(path)

    local bufnr = fn.bufnr(resolved_path)
    if bufnr > 0 then
      pcall(api.nvim_buf_delete, bufnr, { force = false })
    end

    if fn.isdirectory(resolved_path) == 1 then
      cleanup_dir(resolved_path)
      cleanup_empty_parent_dirs(resolved_path)
    elseif fn.delete(resolved_path) == 0 then
      cleanup_empty_parent_dirs(resolved_path)
    end
  end
end

local function open(type, path, cursor)
  jump.open(type, path, cursor, "[Status - Open]")
end

---Diff-cache invalidation keys for a set of file items, so a partial
---refresh drops the cached diffs of exactly those files (both sections).
---@param items StatusItem[]
---@return string[]
local function invalidated_diffs_for(items)
  return util.map(items, function(item)
    return "*:" .. item.name
  end)
end

local M = {}

---@param self StatusBuffer
---@return fun(): nil
M.v_discard = function(self)
  return a.void(function()
    local selection = self.buffer.ui:get_selection()

    local discard_message = "Discard selection?"
    local file_count = 0

    local invalidated_diffs = {}
    local untracked_files = {}
    local unstaged_files = {}
    local new_files = {}
    local staged_files_modified = {}
    local stashes = {}

    for _, section in ipairs(selection.sections) do
      if section.name == "untracked" or section.name == "unstaged" or section.name == "staged" then
        file_count = file_count + #section.items

        for _, item in ipairs(section.items) do
          discard_message = ("Discard %s files?"):format(file_count)
          logger.debug(("Discarding in section %s %s"):format(section.name, item.name))
          table.insert(invalidated_diffs, "*:" .. item.name)

          if section.name == "untracked" then
            table.insert(untracked_files, item)
          elseif section.name == "unstaged" then
            if item.mode == "A" then
              table.insert(new_files, item)
            else
              table.insert(unstaged_files, item)
            end
          elseif section.name == "staged" then
            if item.mode == "N" or item.mode == "A" then
              table.insert(new_files, item)
            else
              table.insert(staged_files_modified, item)
            end
          end
        end
      elseif section.name == "stashes" then
        discard_message = ("Discard %s stashes?"):format(#selection.items)

        for _, stash in ipairs(selection.items) do
          table.insert(stashes, stash.name:match("(stash@{%d+})"))
        end

        table.sort(stashes)
        stashes = util.reverse(stashes)
      end
    end

    if input.get_permission(discard_message) then
      if #untracked_files > 0 then
        cleanup_items(untracked_files)
      end

      if #unstaged_files > 0 then
        git.index.checkout(util.map(unstaged_files, function(item)
          return item.escaped_path
        end))
      end

      if #new_files > 0 then
        git.index.reset(util.map(new_files, function(item)
          return item.escaped_path
        end))
        cleanup_items(new_files)
      end

      if #staged_files_modified > 0 then
        local paths = util.map(staged_files_modified, function(item)
          return item.escaped_path
        end)
        git.index.reset(paths)
        git.index.checkout(paths)
      end

      -- TODO: Investigate why, when dropping multiple stashes, the UI doesn't get updated at the end
      if #stashes > 0 then
        for _, stash in ipairs(stashes) do
          git.stash.drop(stash)
        end
      end

      self:dispatch_refresh({ update_diffs = invalidated_diffs }, "v_discard")
    end
  end)
end

---@param self StatusBuffer
---@return fun(): nil
M.v_stage = function(self)
  return a.void(function()
    local selection = self.buffer.ui:get_selection()

    local untracked_files = {}
    local unstaged_files = {}
    local invalidated_diffs = {}

    for _, section in ipairs(selection.sections) do
      if section.name == "unstaged" or section.name == "untracked" then
        for _, item in ipairs(section.items) do
          if git.status.is_unmerged(item.mode) then
            notification.info("Conflicts must be resolved before staging lines")
            return
          end

          table.insert(invalidated_diffs, "*:" .. item.name)

          if section.name == "unstaged" then
            table.insert(unstaged_files, item.escaped_path)
          else
            table.insert(untracked_files, item.escaped_path)
          end
        end
      end
    end

    if #untracked_files > 0 then
      git.index.add(untracked_files)
    end

    if #unstaged_files > 0 then
      git.status.stage(unstaged_files)
    end

    if #untracked_files > 0 or #unstaged_files > 0 then
      self:dispatch_refresh({ update_diffs = invalidated_diffs }, "n_stage")
    end
  end)
end

---@param self StatusBuffer
---@return fun(): nil
M.v_unstage = function(self)
  return a.void(function()
    local selection = self.buffer.ui:get_selection()

    local files = {}
    local invalidated_diffs = {}

    for _, section in ipairs(selection.sections) do
      if section.name == "staged" then
        for _, item in ipairs(section.items) do
          table.insert(invalidated_diffs, "*:" .. item.name)
          table.insert(files, item.escaped_path)
        end
      end
    end

    if #files > 0 then
      git.status.unstage(files)
      self:dispatch_refresh({ update_diffs = invalidated_diffs }, "v_unstage")
    end
  end)
end

---Popup launchers are data-driven: `M.popup_specs` holds one row per popup per
---mode, and the thin `M.n_x_popup` / `M.v_x_popup` exports below are generated
---from it. The same table drives the status buffer's key wiring
---(buffers/status/init.lua) and the help popup's listing
---(popups/help/actions.lua), so each popup's context behavior is described in
---exactly one place.
---
---`env` names a context extractor; "none" opens the popup without context.
---Rows are ordered so each popup's first appearance preserves the help popup's
---historical listing order, and `label` (set on a popup's first row) is its
---display name there. The help popup has no label: it does not list itself.
---@class StatusPopupSpec
---@field name string popup name, e.g. "cherry_pick"
---@field mode "n"|"v"
---@field env string context extractor key, or "none"
---@field label nil|string help popup display label

---Resolves the stash ref ("stash@{N}") under the cursor, or nil anywhere
---else in the buffer. Stash rows' yankable is the stash OID (see
---SectionItemStash in buffers/status/ui.lua), so the ref must come from the
---selection's item - get_yankable_under_cursor() can never match it.
---@param self StatusBuffer
---@return string?
local function stash_under_cursor(self)
  local selection = self.buffer.ui:get_selection()
  if selection.section and selection.section.name == "stashes" and selection.item then
    return selection.item.name:match("^stash@{%d+}")
  end
end

---Context extractors. Each receives the status buffer and returns the table
---handed to the popup's create function - or nil, which skips that call and
---leaves the popup closed (preserving the historical hand-written guards).
---Visual-mode rows read the selection; normal-mode rows read the cursor.
local context = {
  ["selection-commits"] = function(self)
    return { commits = self.buffer.ui:get_commits_in_selection() }
  end,
  ["first-commit"] = function(self)
    local commits = self.buffer.ui:get_commits_in_selection()
    if #commits == 1 then
      return { commit = commits[1] }
    end
  end,
  -- Normal mode has no selection: the commit under the cursor is the context,
  -- either as a bare commit or wrapped in the list form some popups expect.
  ["cursor-commit"] = function(self)
    return { commit = self.buffer.ui:get_commit_under_cursor() }
  end,
  ["cursor-commit-list"] = function(self)
    return { commits = { self.buffer.ui:get_commit_under_cursor() } }
  end,
  stash = function(self)
    return { name = stash_under_cursor(self) }
  end,
  diff = function(self)
    local section = self.buffer.ui:get_selection().section
    local item = self.buffer.ui:get_yankable_under_cursor()
    return { section = { name = section and section.name }, item = { name = item } }
  end,
  -- Visual ignore works on the selected file paths; normal ignore on the hunk
  -- or filename under the cursor.
  ["ignore-visual"] = function(self)
    return { paths = self.buffer.ui:get_filepaths_in_selection(), worktree_root = git.repo.worktree_root }
  end,
  ["ignore-normal"] = function(self)
    local path = self.buffer.ui:get_hunk_or_filename_under_cursor()
    return { paths = { path and path.filename }, worktree_root = git.repo.worktree_root }
  end,
  margin = function(self)
    return { buffer = self }
  end,
  -- Since any other popup can be launched from help, build an ENV for any of them.
  help = function(self)
    local path = self.buffer.ui:get_hunk_or_filename_under_cursor()
    local section = self.buffer.ui:get_selection().section
    local section_name
    if section then
      section_name = section.name
    end

    local item = self.buffer.ui:get_yankable_under_cursor()
    local stash = self.buffer.ui:get_yankable_under_cursor()
    local commit = self.buffer.ui:get_commit_under_cursor()
    local commits = { commit }

    -- TODO: Pass selection here so we can stage/unstage etc stuff
    return {
      branch = { commits = commits },
      cherry_pick = { commits = commits },
      commit = { commit = commit },
      merge = { commit = commit },
      push = { commit = commit },
      rebase = { commit = commit },
      revert = { commits = commits },
      bisect = { commits = commits },
      reset = { commit = commit },
      tag = { commit = commit },
      margin = { buffer = self },
      stash = { name = stash and stash:match("^stash@{%d+}") },
      diff = {
        section = { name = section_name },
        item = { name = item },
      },
      ignore = {
        paths = { path and path.filename },
        worktree_root = git.repo.worktree_root,
      },
      remote = {},
      fetch = {},
      pull = {},
      log = {},
      worktree = {},
    }
  end,
}

---@param name string popup name, e.g. "cherry_pick"
---@param env? string key into `context`, or "none"/nil for no context
---@return fun(self: StatusBuffer): fun(): nil
local function open_popup(name, env)
  return function(self)
    if not env or env == "none" then
      return popups.open(name)
    end

    return popups.open(name, function(p)
      local args = context[env](self)
      if args then
        p(args)
      end
    end)
  end
end

M.popup_specs = {
  --                 name            mode env                       help label
  { name = "diff", mode = "v", env = "diff", label = "Diff" },
  { name = "diff", mode = "n", env = "diff" },
  { name = "pull", mode = "v", env = "none", label = "Pull" },
  { name = "pull", mode = "n", env = "none" },
  { name = "rebase", mode = "v", env = "first-commit", label = "Rebase" },
  { name = "rebase", mode = "n", env = "cursor-commit" },
  { name = "merge", mode = "v", env = "first-commit", label = "Merge" },
  { name = "merge", mode = "n", env = "cursor-commit" },
  { name = "push", mode = "v", env = "first-commit", label = "Push" },
  { name = "push", mode = "n", env = "cursor-commit" },
  { name = "commit", mode = "v", env = "first-commit", label = "Commit" },
  { name = "commit", mode = "n", env = "cursor-commit" },
  { name = "ignore", mode = "v", env = "ignore-visual", label = "Ignore" },
  { name = "ignore", mode = "n", env = "ignore-normal" },
  { name = "tag", mode = "v", env = "first-commit", label = "Tag" },
  { name = "tag", mode = "n", env = "cursor-commit" },
  { name = "log", mode = "v", env = "none", label = "Log" },
  { name = "log", mode = "n", env = "none" },
  { name = "margin", mode = "v", env = "margin", label = "Margin" },
  { name = "margin", mode = "n", env = "margin" },
  { name = "cherry_pick", mode = "v", env = "selection-commits", label = "Cherry Pick" },
  { name = "cherry_pick", mode = "n", env = "cursor-commit-list" },
  { name = "branch", mode = "v", env = "selection-commits", label = "Branch" },
  { name = "branch", mode = "n", env = "cursor-commit-list" },
  { name = "bisect", mode = "v", env = "selection-commits", label = "Bisect" },
  { name = "bisect", mode = "n", env = "cursor-commit-list" },
  { name = "fetch", mode = "v", env = "none", label = "Fetch" },
  { name = "fetch", mode = "n", env = "none" },
  { name = "reset", mode = "v", env = "first-commit", label = "Reset" },
  { name = "reset", mode = "n", env = "cursor-commit" },
  { name = "revert", mode = "v", env = "selection-commits", label = "Revert" },
  { name = "revert", mode = "n", env = "cursor-commit-list" },
  { name = "remote", mode = "v", env = "none", label = "Remote" },
  { name = "remote", mode = "n", env = "none" },
  { name = "worktree", mode = "v", env = "none", label = "Worktree" },
  { name = "worktree", mode = "n", env = "none" },
  { name = "stash", mode = "v", env = "stash", label = "Stash" },
  { name = "stash", mode = "n", env = "stash" },
  { name = "help", mode = "v", env = "none" },
  { name = "help", mode = "n", env = "help" },
}

-- Generate the thin per-mode exports (M.n_branch_popup, M.v_stash_popup, ...)
-- that the status buffer's key wiring and the help popup resolve by name.
for _, spec in ipairs(M.popup_specs) do
  M[spec.mode .. "_" .. spec.name .. "_popup"] = open_popup(spec.name, spec.env)
end

---The popup command name ("CherryPickPopup") for a popup name ("cherry_pick"),
---matching the values of config.mappings.popup.
---@param name string popup name
---@return string
function M.command_name(name)
  return (
    name
      :gsub("_(%a)", function(char)
        return char:upper()
      end)
      :gsub("^%a", string.upper)
  ) .. "Popup"
end

---True when the cursor rests on a Recent Commits Connector Row (the Commit
---Graph's graph-only decoration rows between commit rows). Connector Rows
---hold no item, so item-based cursor movement must skip them.
---@param ui Ui
---@return boolean
local function on_connector_row(ui)
  local node = ui.node_index:find_by_line(vim.api.nvim_win_get_cursor(0)[1])[1]

  while node do
    if node.options.connector_row then
      return true
    end

    node = node.parent
  end

  return false
end

---Shared body of n_down/n_up: one count-aware `key` step, then keep stepping
---while the cursor rests on a blank line or Connector Row, so it lands on
---items (or section headers). The guard breaks at the buffer edge, where the
---step is a no-op.
---@param self StatusBuffer
---@param key string "j" or "k"
---@return fun(): nil
local function move_to_item(self, key)
  return function()
    if vim.v.count > 0 then
      vim.cmd("norm! " .. vim.v.count .. key)
    else
      vim.cmd("norm! " .. key)
    end

    local line = vim.api.nvim_win_get_cursor(0)[1]
    while self.buffer:get_current_line()[1] == "" or on_connector_row(self.buffer.ui) do
      vim.cmd("norm! " .. key)

      local next_line = vim.api.nvim_win_get_cursor(0)[1]
      if next_line == line then
        break
      end

      line = next_line
    end
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_down = function(self)
  return move_to_item(self, "j")
end

---@param self StatusBuffer
---@return fun(): nil
M.n_up = function(self)
  return move_to_item(self, "k")
end

---@param self StatusBuffer
---@return fun(): nil
M.n_toggle = function(self)
  return function()
    local fold = self.buffer.ui:get_fold_under_cursor()
    if fold then
      if fold.options.on_open then
        fold.options.on_open(fold, self.buffer.ui)
      else
        local start, _ = fold:row_range_abs()
        local ok, _ = pcall(vim.cmd, "normal! za")
        if ok then
          self.buffer:move_cursor(start)
          fold.options.folded = not fold.options.folded
        end
      end
    end
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_open_fold = function(self)
  return function()
    local fold = self.buffer.ui:get_fold_under_cursor()
    if fold then
      if fold.options.on_open then
        fold.options.on_open(fold, self.buffer.ui)
      else
        local start, _ = fold:row_range_abs()
        local ok, _ = pcall(vim.cmd, "normal! zo")
        if ok then
          self.buffer:move_cursor(start)
          fold.options.folded = false
        end
      end
    end
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_close_fold = function(self)
  return function()
    local fold = self.buffer.ui:get_fold_under_cursor()
    if fold then
      local start, _ = fold:row_range_abs()
      local ok, _ = pcall(vim.cmd, "normal! zc")
      if ok then
        self.buffer:move_cursor(start)
        fold.options.folded = true
      end
    end
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_close = function(self)
  return require("neogit.lib.ui.helpers").close_topmost(self)
end

---Shared body of n_open_or_scroll_up / n_open_or_scroll_down: scroll the open
---commit view (or open one) to the commit under the cursor.
---@param self StatusBuffer
---@param method string "open_or_scroll_up" or "open_or_scroll_down"
---@return fun(): nil
local function open_or_scroll(self, method)
  return function()
    local commit = self.buffer.ui:get_commit_under_cursor()
    if commit then
      require("neogit.buffers.commit_view")[method](commit)
    end
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_open_or_scroll_down = function(self)
  return open_or_scroll(self, "open_or_scroll_down")
end

---@param self StatusBuffer
---@return fun(): nil
M.n_open_or_scroll_up = function(self)
  return open_or_scroll(self, "open_or_scroll_up")
end

---PeekUp/PeekDown body: render the diff preview for the file item one row
---above/below the cursor WITHOUT moving the cursor. Per-row semantics match
---the cursor-following preview exactly (only file rows in the
---untracked/unstaged/staged sections preview), just evaluated one row away:
---Head Lines, Connector Rows, section headers, Recent Commits rows and every
---other non-previewable row are no-ops. The cursor never moves - that is what
---distinguishes peek from plain navigation.
---@param self StatusBuffer
---@param direction integer -1 peeks the row above, 1 the row below
---@return fun(): nil
local function peek_row(self, direction)
  return function()
    local preview_config = self.config.status.diff_preview
    if not preview_config or not preview_config.enabled then
      return
    end

    local line = vim.api.nvim_win_get_cursor(0)[1] + direction
    if line < 1 then
      return
    end

    local component = self.buffer.ui:get_component_on_line(line, function(node)
      return node.options.item ~= nil
    end)
    local item = component and component.options.item

    local section = self.buffer.ui:get_current_section(line)
    local section_name = section and section.options.section

    if
      item
      and item.name
      and item.mode
      and vim.tbl_contains({ "untracked", "unstaged", "staged" }, section_name)
    then
      require("neogit.buffers.diff_preview").show(self.buffer, section_name, item)
    end
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_peek_up = function(self)
  return peek_row(self, -1)
end

---@param self StatusBuffer
---@return fun(): nil
M.n_peek_down = function(self)
  return peek_row(self, 1)
end

---@param self StatusBuffer
---@return fun(): nil
M.n_refresh_buffer = function(self)
  return a.void(function()
    self:dispatch_refresh({ update_diffs = { "*:*" } }, "n_refresh_buffer")
  end)
end

---Shared body of n_depth1..4: close every fold in the cursor's section, then
---re-open `open_depth` levels (nil keeps everything closed), and restore the
---cursor to the row it started on, resolved by `context` (captured before the
---move, like the originals).
---@param self StatusBuffer
---@param open_depth nil|integer levels passed to open_all_folds
---@param double boolean repeat the close/open cycle (Depth3's historical quirk)
---@param context nil|fun(ui: Ui): Component? resolves the cursor-restore target
---@return fun(): nil
local function set_fold_depth(self, open_depth, double, context)
  return function()
    local section = self.buffer.ui:get_current_section()
    local restore = context and context(self.buffer.ui) or nil

    if section then
      local start, last = section:row_range_abs()
      if self.buffer:cursor_line() < start or self.buffer:cursor_line() >= last then
        return
      end

      self.buffer:move_cursor(start)

      section:close_all_folds(self.buffer.ui)
      if open_depth then
        section:open_all_folds(self.buffer.ui, open_depth)
      end

      -- NOTE: Depth3's second close/open cycle is undocumented behavior kept
      -- verbatim from the original hand-written mapping (a doubled
      -- open_all_folds(2)); deliberately not "fixed".
      if double then
        section:close_all_folds(self.buffer.ui)
        section:open_all_folds(self.buffer.ui, open_depth)
      end

      self.buffer.ui:update()

      if restore then
        local start, _ = restore:row_range_abs()
        self.buffer:move_cursor(start)
      end
    end
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_depth1 = function(self)
  return set_fold_depth(self, nil, false, nil)
end

---@param self StatusBuffer
---@return fun(): nil
M.n_depth2 = function(self)
  return set_fold_depth(self, 1, false, function(ui)
    return ui:get_component_under_cursor()
  end)
end

---@param self StatusBuffer
---@return fun(): nil
M.n_depth3 = function(self)
  return set_fold_depth(self, 2, true, function(ui)
    return ui:get_cursor_context()
  end)
end

---@param self StatusBuffer
---@return fun(): nil
M.n_depth4 = function(self)
  return set_fold_depth(self, 3, false, function(ui)
    return ui:get_cursor_context()
  end)
end

---@param _self StatusBuffer
---@return fun(): nil
M.n_command_history = function(_self)
  return a.void(function()
    require("neogit.buffers.git_command_history"):new():show()
  end)
end

---@param _self StatusBuffer
---@return fun(): nil
M.n_show_refs = function(_self)
  return a.void(function()
    require("neogit.buffers.refs_view").new(git.refs.list_parsed(), git.repo.worktree_root):open()
  end)
end

---@param self StatusBuffer
---@return fun(): nil
M.n_yank_selected = function(self)
  return function()
    local yank = self.buffer.ui:get_yankable_under_cursor()
    if yank then
      if yank:match("^stash@{%d+}") then
        yank = git.rev_parse.oid(yank:match("^(stash@{%d+})"))
      end

      yank = string.format("'%s'", yank)
      vim.cmd.let("@+=" .. yank)
      vim.cmd.echo(yank)
    else
      vim.cmd("echo ''")
    end
  end
end

---Pop the stash under the cursor ("stash@{N}" from the Stashes section) after
---confirmation. Anywhere else the cursor has no stash and nothing happens.
---@param self StatusBuffer
---@return fun(): nil
M.n_pop_stash = function(self)
  return a.void(function()
    local dbg = require("neogit.lib.git.stash").__dbg -- [DEBUG-stashpop]
    local stash = stash_under_cursor(self)
    dbg("n_pop_stash: resolved stash=%s", vim.inspect(stash))
    if not stash then
      dbg("n_pop_stash: no stash under cursor, returning")
      return
    end

    if input.get_permission(("Pop stash '%s'?"):format(stash)) then
      dbg("n_pop_stash(%s): confirmed, popping", stash)
      git.stash.pop(stash)
      self:dispatch_refresh({ update_diffs = { "*:*" } }, "n_pop_stash")
    else
      dbg("n_pop_stash(%s): cancelled at confirmation", stash)
    end
  end)
end

---Conflict-side discard ("Discard File" on a conflicted unstaged item):
---prompts for ours/theirs/conflict and applies the choice. Every resolution
---re-stages the file; abort does nothing.
---@param item StatusItem
local function discard_conflict(item)
  local choices = { "&ours", "&theirs", "&conflict", "&abort" }
  local choice = input.get_choice("Discard conflict by taking...", { values = choices, default = #choices })

  if choice == "o" then
    if item.mode:sub(1, 1) == "D" then
      git.files.remove { item.absolute_path }
    else
      git.reset.checkout_ours { item.absolute_path }
      git.status.stage { item.name }
    end
  elseif choice == "t" then
    if item.mode:sub(2, 2) == "D" then
      git.files.remove { item.absolute_path }
    else
      git.reset.checkout_theirs { item.absolute_path }
      git.status.stage { item.name }
    end
  elseif choice == "c" then
    git.reset.checkout_merge { item.absolute_path }
    git.status.stage { item.name }
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_discard = function(self)
  return a.void(function()
    git.index.update()

    local selection = self.buffer.ui:get_selection()
    if not selection.section then
      return
    end

    local section = selection.section.name
    local action, message, own_prompt
    local refresh = {}

    if selection.item and selection.item.first == fn.line(".") then -- Discard File
      if section == "untracked" then
        local mode = git.config.get("status.showUntrackedFiles"):read()

        refresh = { update_diffs = { "untracked:" .. selection.item.name } }
        if mode == "all" then
          message = ("Discard %q?"):format(selection.item.name)
          action = function()
            cleanup_items { selection.item }
          end
        else
          message = ("Recursively discard %q?"):format(selection.item.name)
          action = function()
            cleanup_dir(selection.item.name)
          end
        end
      elseif section == "unstaged" then
        if git.status.is_unmerged(selection.item.mode) then
          -- The conflict flow prompts for its own choice (see discard_conflict
          -- above); marking the action as own-prompted skips the generic
          -- permission prompt below.
          own_prompt = true
          action = function()
            discard_conflict(selection.item)
          end
          -- Resolution re-stages the file, so BOTH sides' diff caches are
          -- stale; update_file carries cached diffs into the refreshed
          -- state, and a single-section filter would keep the other side's
          -- old diff alive.
          refresh = { update_diffs = { "*:" .. selection.item.name } }
        else
          message = ("Discard %q?"):format(selection.item.name)
          action = function()
            if selection.item.mode == "A" then
              git.index.reset { selection.item.escaped_path }
              cleanup_items { selection.item }
            else
              git.index.checkout { selection.item.name }
            end
          end
        end
        refresh = { update_diffs = { "unstaged:" .. selection.item.name } }
      elseif section == "staged" then
        message = ("Discard %q?"):format(selection.item.name)
        action = function()
          if selection.item.mode == "N" or selection.item.mode == "A" then
            git.index.reset { selection.item.escaped_path }
            cleanup_items { selection.item }
          elseif selection.item.mode == "M" then
            git.index.reset { selection.item.escaped_path }
            git.index.checkout { selection.item.escaped_path }
          elseif selection.item.mode == "R" then
            git.index.reset_HEAD(selection.item.name, selection.item.original_name)
            git.index.checkout { selection.item.original_name }
            cleanup_items { selection.item }
          elseif selection.item.mode == "D" then
            git.index.reset_HEAD(selection.item.escaped_path)
            git.index.checkout { selection.item.escaped_path }
          else
            error(("Unhandled file mode %q for %q"):format(selection.item.mode, selection.item.escaped_path))
          end
        end
        refresh = { update_diffs = { "staged:" .. selection.item.name } }
      elseif section == "stashes" then
        message = ("Discard %q?"):format(selection.item.name)
        action = function()
          git.stash.drop(selection.item.name:match("(stash@{%d+})"))
        end
        refresh = {}
      end
    else -- Discard Section
      if section == "untracked" then
        message = ("Discard %s files?"):format(#selection.section.items)
        action = function()
          cleanup_items(selection.section.items)
        end
        refresh = { update_diffs = { "untracked:*" } }
      elseif section == "unstaged" then
        local conflict = false
        for _, item in ipairs(selection.section.items) do
          if git.status.is_unmerged(item.mode) then
            conflict = true
            break
          end
        end

        if conflict then
          -- TODO: https://github.com/magit/magit/blob/28bcd29db547ab73002fb81b05579e4a2e90f048/lisp/magit-apply.el#L515
          notification.warn("Resolve conflicts before discarding section.")
          return
        else
          message = ("Discard %s files?"):format(#selection.section.items)
          action = function()
            git.index.checkout_unstaged()
          end
          refresh = { update_diffs = { "unstaged:*" } }
        end
      elseif section == "staged" then
        message = ("Discard %s files?"):format(#selection.section.items)
        action = function()
          local new_files = {}
          local staged_files_modified = {}
          local staged_files_renamed = {}
          local staged_files_deleted = {}

          for _, item in ipairs(selection.section.items) do
            if item.mode == "N" or item.mode == "A" then
              table.insert(new_files, item)
            elseif item.mode == "M" then
              table.insert(staged_files_modified, item.escaped_path)
            elseif item.mode == "R" then
              table.insert(staged_files_renamed, item)
            elseif item.mode == "D" then
              table.insert(staged_files_deleted, item.escaped_path)
            else
              error(("Unknown file mode %q for %q"):format(item.mode, item.escaped_path))
            end
          end

          if #new_files > 0 then
            git.index.reset(util.map(new_files, function(item)
              return item.escaped_path
            end))
            cleanup_items(new_files)
          end

          if #staged_files_modified > 0 then
            git.index.reset(staged_files_modified)
            git.index.checkout(staged_files_modified)
          end

          if #staged_files_renamed > 0 then
            for _, item in ipairs(staged_files_renamed) do
              git.index.reset_HEAD(item.name, item.original_name)
              git.index.checkout { item.original_name }
              fn.delete(item.escaped_path)
            end
          end

          if #staged_files_deleted > 0 then
            git.index.reset_HEAD(unpack(staged_files_deleted))
            git.index.checkout(staged_files_deleted)
          end
        end
        refresh = { update_diffs = { "staged:*" } }
      elseif section == "stashes" then
        message = ("Discard %s stashes?"):format(#selection.section.items)
        action = function()
          for _, stash in ipairs(selection.section.items) do
            git.stash.drop(stash.name:match("(stash@{%d+})"))
          end
        end
      end
    end

    if action and (own_prompt or input.get_permission(message)) then
      action()
      self:dispatch_refresh(refresh, "n_discard")
    end
  end)
end

---@param self StatusBuffer
---@return fun(): nil
M.n_go_to_next_hunk_header = function(self)
  return function()
    local c = self.buffer.ui:get_component_under_cursor(function(c)
      return c.options.tag == "Item"
    end)
    local section = self.buffer.ui:get_current_section()

    if c and section then
      local _, section_last = section:row_range_abs()
      local next_location = fn.line(".") + 1

      if next_location < section_last then
        self.buffer:move_cursor(next_location)
      end

      vim.cmd("normal! zt")
    end
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_go_to_previous_hunk_header = function(self)
  return function()
    local function previous_item_header(self, line)
      local c = self.buffer.ui:get_component_on_line(line, function(c)
        return c.options.tag == "Item"
      end)

      if c then
        local first, _ = c:row_range_abs()
        if fn.line(".") == first then
          first = previous_item_header(self, line - 1)
        end

        return first
      end
    end

    local previous_header = previous_item_header(self, fn.line("."))
    if previous_header then
      self.buffer:move_cursor(previous_header)
      vim.cmd("normal! zt")
    end
  end
end

---@param _self StatusBuffer
---@return fun(): nil
M.n_init_repo = function(_self)
  return a.void(function()
    git.init.init_repo()
  end)
end

---@param self StatusBuffer
---@return fun(): nil
M.n_rename = function(self)
  return a.void(function()
    local selection = self.buffer.ui:get_selection()
    local paths = git.files.all_tree()

    if
      selection.item
      and selection.item.escaped_path
      and git.files.is_tracked(selection.item.escaped_path)
    then
      paths = util.deduplicate(util.merge({ selection.item.escaped_path }, paths))
    end

    local selected = FuzzyFinderBuffer.new(paths):open_async { prompt_prefix = "Rename file" }
    if (selected or "") == "" then
      return
    end

    local destination = input.get_user_input("Move to", { completion = "dir", prepend = selected })
    if (destination or "") == "" then
      return
    end

    assert(destination, "must have a destination")
    local success = git.files.move(selected, destination)

    if not success then
      notification.warn("Renaming failed")
    end

    self:dispatch_refresh({ update_diffs = { "*:*" } }, "n_rename")
  end)
end

---@param self StatusBuffer
---@return fun(): nil
M.n_untrack = function(self)
  return a.void(function()
    local selection = self.buffer.ui:get_selection()
    local paths = git.files.all_tree()

    if
      selection.item
      and selection.item.escaped_path
      and git.files.is_tracked(selection.item.escaped_path)
    then
      paths = util.deduplicate(util.merge({ selection.item.escaped_path }, paths))
    end

    local selected = FuzzyFinderBuffer.new(paths)
      :open_async { prompt_prefix = "Untrack file(s)", allow_multi = true }
    if selected and #selected > 0 and git.files.untrack(selected) then
      local message
      if #selected > 1 then
        message = ("%s files untracked"):format(#selected)
      else
        message = ("%q untracked"):format(selected[1])
      end

      notification.info(message)
      self:dispatch_refresh({ update_diffs = { "*:*" } }, "n_untrack")
    end
  end)
end

---@param self StatusBuffer
---@return fun(): nil
M.v_untrack = function(self)
  return a.void(function()
    local selection = self.buffer.ui:get_selection()
    local selected_paths = util.filter_map(selection.items or {}, function(item)
      if git.files.is_tracked(item.escaped_path) then
        return item.escaped_path
      end
    end)

    local paths = util.deduplicate(util.merge(selected_paths, git.files.all_tree()))
    local selected = FuzzyFinderBuffer.new(paths)
      :open_async { prompt_prefix = "Untrack file(s)", allow_multi = true }
    if selected and #selected > 0 and git.files.untrack(selected) then
      local message
      if #selected > 1 then
        message = ("Untracked %s files"):format(#selected)
      else
        message = ("%q untracked"):format(selected[1])
      end

      notification.info(message)
      self:dispatch_refresh({ update_diffs = { "*:*" } }, "v_untrack")
    end
  end)
end

---@param self StatusBuffer
---@return fun(): nil
M.n_stage = function(self)
  return a.void(function()
    local stagable = self.buffer.ui:get_hunk_or_filename_under_cursor()
    local section = self.buffer.ui:get_current_section()
    local selection = self.buffer.ui:get_selection()

    if stagable and section then
      if section.options.section == "staged" then
        return
      end

      if selection.item and git.status.is_unmerged(selection.item.mode) then
        local diff_viewer = config.get_diff_viewer()
        if diff_viewer and git.merge.is_conflicted(selection.item.name) then
          local integration = diff_viewer == "codediff" and require("neogit.integrations.codediff")
            or require("neogit.integrations.diffview")
          integration.open("conflict", selection.item.name, {
            on_close = {
              handle = self.buffer.handle,
              fn = function()
                if not git.merge.is_conflicted(selection.item.name) then
                  git.status.stage { selection.item.name }
                  self:dispatch_refresh({ update_diffs = { "*:" .. selection.item.name } }, "n_stage")
                end
              end,
            },
          })
        else
          if not git.merge.is_conflicted(selection.item.name) then
            git.status.stage { selection.item.name }
            self:dispatch_refresh({ update_diffs = { "*:" .. selection.item.name } }, "n_stage")
          else
            notification.info("Conflicts must be resolved before staging")
          end
          return
        end
      elseif selection.item and section.options.section == "untracked" then
        git.index.add { selection.item.name }
        self:dispatch_refresh({ update_diffs = { "*:" .. selection.item.name } }, "n_stage")
      elseif stagable.filename and section.options.section == "unstaged" then
        git.status.stage { stagable.filename }
        self:dispatch_refresh({ update_diffs = { "*:" .. stagable.filename } }, "n_stage")
      end
    elseif section then
      local directory = self.buffer.ui:get_directory_under_cursor()
      if directory and (section.options.section == "untracked" or section.options.section == "unstaged") then
        -- File-tree directory row: restrict the stage to the files in that
        -- subtree instead of the entire section
        local items = self.buffer.ui:files_in_component(directory)

        for _, item in ipairs(items) do
          if git.status.is_unmerged(item.mode) then
            notification.info("Conflicts must be resolved before staging")
            return
          end
        end

        if #items > 0 then
          local files = util.map(items, function(item)
            return item.name
          end)

          if section.options.section == "untracked" then
            git.index.add(files)
          else
            git.status.stage(files)
          end

          self:dispatch_refresh({ update_diffs = invalidated_diffs_for(items) }, "n_stage")
        end
      elseif section.options.section == "untracked" then
        git.status.stage_untracked()
        self:dispatch_refresh({ update_diffs = { "untracked:*" } }, "n_stage")
      elseif section.options.section == "unstaged" then
        if git.status.any_unmerged() then
          local diff_viewer = config.get_diff_viewer()
          if diff_viewer then
            local integration = diff_viewer == "codediff" and require("neogit.integrations.codediff")
              or require("neogit.integrations.diffview")
            integration.open("conflict", nil, {
              on_close = {
                handle = self.buffer.handle,
                fn = function()
                  if not git.merge.any_conflicted() then
                    git.status.stage_modified()
                    self:dispatch_refresh({ update_diffs = { "*:*" } }, "n_stage")
                    popups.open("merge")()
                  end
                end,
              },
            })
          else
            notification.info("Conflicts must be resolved before staging")
            return
          end
        else
          git.status.stage_modified()
          self:dispatch_refresh({ update_diffs = { "*:*" } }, "n_stage")
        end
      end
    end
  end)
end

---@param self StatusBuffer
---@return fun(): nil
M.n_stage_all = function(self)
  return a.void(function()
    git.status.stage_all()
    self:dispatch_refresh({ update_diffs = { "*:*" } }, "n_stage_all")
  end)
end

---@param self StatusBuffer
---@return fun(): nil
M.n_stage_unstaged = function(self)
  return a.void(function()
    git.status.stage_modified()
    self:dispatch_refresh({ update_diffs = { "*:*" } }, "n_stage_unstaged")
  end)
end

---@param self StatusBuffer
---@return fun(): nil
M.n_unstage = function(self)
  return a.void(function()
    local unstagable = self.buffer.ui:get_hunk_or_filename_under_cursor()
    local selection = self.buffer.ui:get_selection()

    local section = self.buffer.ui:get_current_section()
    if section and section.options.section ~= "staged" then
      return
    end

    if unstagable then
      if selection.item and (selection.item.mode == "N" or selection.item.mode == "A") then
        git.status.unstage { selection.item.name }
        self:dispatch_refresh({ update_diffs = { "*:" .. selection.item.name } }, "n_unstage")
      elseif unstagable.filename then
        git.status.unstage { unstagable.filename }
        self:dispatch_refresh({ update_diffs = { "*:" .. unstagable.filename } }, "n_unstage")
      end
    elseif section then
      local directory = self.buffer.ui:get_directory_under_cursor()
      if directory then
        -- File-tree directory row: restrict the unstage to the files in
        -- that subtree instead of unstaging everything
        local items = self.buffer.ui:files_in_component(directory)

        if #items > 0 then
          git.status.unstage(util.map(items, function(item)
            return item.name
          end))
          self:dispatch_refresh({ update_diffs = invalidated_diffs_for(items) }, "n_unstage")
        end
      else
        git.status.unstage_all()
        self:dispatch_refresh({ update_diffs = { "*:*" } }, "n_unstage")
      end
    end
  end)
end

---@param self StatusBuffer
---@return fun(): nil
M.n_unstage_staged = function(self)
  return a.void(function()
    git.status.unstage_all()
    self:dispatch_refresh({ update_diffs = { "*:*" } }, "n_unstage_all")
  end)
end

---Opens neogit on the parent repo if if we are in a submodule
---@param self StatusBuffer
M.n_goto_parent_repo = function(self)
  return function()
    local parent = self:parent_repo()
    if parent then
      self:close()
      require("neogit").open { cwd = parent }
    end
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_goto_file = function(self)
  return function()
    local item = self.buffer.ui:get_item_under_cursor()

    -- Goto FILE
    if item and item.absolute_path then
      if self:has_submodule(item.absolute_path) then
        self:close()
        require("neogit").open { cwd = item.absolute_path }
        return
      end

      -- No inline hunks in the status buffer: nothing to translate the
      -- cursor position onto in the opened file.
      self:close()
      vim.schedule_wrap(open)("edit", item.absolute_path, nil)
      return
    end

    -- Head Line: `<cr>` opens the Repository Details buffer (a right
    -- vsplit with Head/Merge/Push/Tag info and the ahead/behind diffs
    -- embedded; snapshot semantics - no live refresh).
    local component = self.buffer.ui:get_component_on_line(vim.fn.line("."), function(c)
      return c.options and type(c.options.divergence) == "table"
    end)
    if component then
      require("neogit.buffers.repository_details").new(git.repo.state):open()
      return
    end

    -- Goto COMMIT
    local ref = self.buffer.ui:get_yankable_under_cursor()
    if ref then
      require("neogit.buffers.commit_view").new(ref):open()
    end
  end
end

---Shared body of n_tab_open / n_split_open / n_vertical_split_open: open the
---file item under the cursor with the given vim command.
---@param self StatusBuffer
---@param type string vim command used to open the file
---@return fun(): nil
local function open_item(self, type)
  return function()
    local item = self.buffer.ui:get_item_under_cursor()

    if item and item.absolute_path then
      open(type, item.absolute_path, nil)
    end
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_tab_open = function(self)
  return open_item(self, "tabedit")
end

---@param self StatusBuffer
---@return fun(): nil
M.n_split_open = function(self)
  return open_item(self, "split")
end

---@param self StatusBuffer
---@return fun(): nil
M.n_vertical_split_open = function(self)
  return open_item(self, "vsplit")
end

---@param self StatusBuffer
---@return fun(): nil
M.n_open_tree = function(self)
  return a.void(function()
    if not vim.ui.open then
      notification.warn("Requires Neovim >= 0.10")
      return
    end

    local commit = self.buffer.ui:get_commit_under_cursor()
    local branch = git.branch.current()
    local url

    if commit then
      url = git.remote.commit_url(commit)
    elseif branch then
      url = git.remote.tree_url(branch)
    end

    if url then
      notification.info(("Opening %q in your browser."):format(url))
      vim.ui.open(url)
    else
      notification.warn("Couldn't determine commit URL to open")
    end
  end)
end

---@param self StatusBuffer|nil
---@return fun(): nil
M.n_command = function(self)
  local process = require("neogit.process")
  local runner = require("neogit.runner")

  return a.void(function()
    local cmd =
      input.get_user_input(("Run command in %s"):format(git.repo.worktree_root), { prepend = "git " })
    if not cmd then
      return
    end

    local cmd = vim.split(cmd, " ")
    table.insert(cmd, 2, "--no-pager")
    table.insert(cmd, 3, "--no-optional-locks")

    local proc = process.new {
      cmd = cmd,
      cwd = git.repo.worktree_root,
      env = {},
      on_error = function()
        return false
      end,
      git_hook = true,
      suppress_console = false,
      user_command = true,
    }

    proc:show_console()

    runner.call(proc, {
      pty = true,
      callback = function()
        if self then
          self:dispatch_refresh()
        end
      end,
    })
  end)
end

---@param self StatusBuffer
---@return fun(): nil
M.n_next_section = function(self)
  return function()
    local section = self.buffer.ui:get_current_section()
    if section then
      local position = section.position.row_end + 2
      self.buffer:move_cursor(position)
    else
      self.buffer:move_cursor(self.buffer.ui:first_section().first + 1)
    end
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_prev_section = function(self)
  return function()
    local section = self.buffer.ui:get_current_section()
    if section then
      local prev_section = self.buffer.ui:get_current_section(section.position.row_start - 1)
      if prev_section then
        self.buffer:move_cursor(prev_section.position.row_start + 1)
        return
      end
    end

    self.buffer:win_exec("norm! gg")
  end
end

---@param self StatusBuffer
---@return fun(): nil
M.n_reverse = function(self)
  return a.void(function()
    git.index.update()

    local selection = self.buffer.ui:get_selection()
    if not selection.section then
      return
    end

    local section = selection.section.name

    if section == "untracked" then
      notification.warn("Cannot reverse untracked changes")
      return
    end

    if section == "unstaged" then
      notification.warn("Cannot reverse unstaged changes")
      return
    end

    if section ~= "staged" then
      return
    end

    local message, action
    local refresh = {}

    if selection.item and selection.item.first == fn.line(".") then -- Reverse File
      message = ("Reverse %q?"):format(selection.item.name)
      action = function()
        for _, hunk in ipairs(selection.item.diff and selection.item.diff.hunks or {}) do
          local patch = git.index.generate_patch(hunk, { reverse = true })
          git.index.apply(patch, { reverse = true })
        end
      end
      refresh = { update_diffs = { "staged:" .. selection.item.name } }
    else -- Reverse Section
      message = ("Reverse %s files?"):format(#selection.section.items)
      action = function()
        for _, item in ipairs(selection.section.items) do
          for _, hunk in ipairs(item.diff and item.diff.hunks or {}) do
            local patch = git.index.generate_patch(hunk, { reverse = true })
            git.index.apply(patch, { reverse = true })
          end
        end
      end
      refresh = { update_diffs = { "staged:*" } }
    end

    if action and input.get_permission(message) then
      action()
      self:dispatch_refresh(refresh, "n_reverse")
    end
  end)
end

---@param self StatusBuffer
---@return fun(): nil
M.v_reverse = function(self)
  return a.void(function()
    local selection = self.buffer.ui:get_selection()

    local patches = {}
    local invalidated_diffs = {}

    for _, section in ipairs(selection.sections) do
      if section.name == "untracked" or section.name == "unstaged" then
        notification.warn("Cannot reverse untracked or unstaged changes")
        return
      end

      if section.name == "staged" then
        for _, item in ipairs(section.items) do
          table.insert(invalidated_diffs, "*:" .. item.name)

          -- Whole-file reversal (the visual analogue of "Reverse File"):
          -- with no inline hunks there is no line-level selection to apply.
          for _, hunk in ipairs(item.diff and item.diff.hunks or {}) do
            table.insert(patches, git.index.generate_patch(hunk, { reverse = true }))
          end
        end
      end
    end

    if #patches > 0 and input.get_permission("Reverse selection?") then
      for _, patch in ipairs(patches) do
        git.index.apply(patch, { reverse = true })
      end
      self:dispatch_refresh({ update_diffs = invalidated_diffs }, "v_reverse")
    end
  end)
end

return M
