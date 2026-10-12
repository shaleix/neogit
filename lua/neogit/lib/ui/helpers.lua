local M = {}

---Closable must implement self:close() method
---@return function
function M.close_topmost(closable)
  return function()
    local commit_view = require("neogit.buffers.commit_view")
    local popup = require("neogit.lib.popup")
    local history = require("neogit.buffers.git_command_history")

    if popup.is_open() then
      popup.instance:close()
    elseif commit_view.is_open() then
      commit_view.instance:close()
    elseif history.is_open() then
      history.instance:close()
    else
      closable:close()
    end
  end
end

---Commit-view navigation shared by the commit-list views (log, reflog, stash
---list, refs): one helper backs their OpenOrScrollUp/Down, PeekUp/PeekDown and
---PeekFile mappings, preserving each view's exact historical behavior.
---
---kind "scroll" resolves the commit under the cursor without moving and
---scrolls the open commit view to it (opening one when none is open).
---kind "peek" moves the cursor one row in `direction` first, then mirrors the
---new row's commit into the open commit view; when none is open it opens one
---(`open_when_absent`), except the log view which falls back to local fold
---navigation (re-open the landed fold, center the row) instead.
---kind "file" opens the row's commit in a fresh commit view and refocuses the
---list (PeekFile); `rewind` first scrolls it to the top (log view).
---
---`skip_folds` is the log view's fold-aware travel distance: fold the row
---being left, then keep moving in `direction` until the cursor rests on a
---folded row.
---@param view table commit-list view instance (`.buffer` / `.buffer.ui`)
---@param kind string "scroll"|"peek"|"file"
---@param direction nil|string "up" or "down" (scroll/peek)
---@param files nil|table file filter forwarded to the commit view
---@param opts nil|table { skip_folds: boolean, open_when_absent: boolean, rewind: boolean }
---@return function
function M.peek_commit(view, kind, direction, files, opts)
  opts = opts or {}
  local key = direction == "up" and "k" or "j"

  return function()
    local CommitViewBuffer = require("neogit.buffers.commit_view")
    local ui = view.buffer.ui

    if kind == "scroll" then
      local commit = ui:get_commit_under_cursor()
      if commit then
        if files then
          CommitViewBuffer["open_or_scroll_" .. direction](commit, files)
        else
          CommitViewBuffer["open_or_scroll_" .. direction](commit)
        end
      end
    elseif kind == "file" then
      local commit = ui:get_commit_under_cursor()
      if commit then
        local buffer = CommitViewBuffer.new(commit, files):open()
        if opts.rewind then
          buffer.buffer:win_call(vim.cmd, "normal! gg")
        end

        view.buffer:focus()
      end
    else -- kind == "peek"
      if opts.skip_folds then
        pcall(vim.cmd, "normal! zc")
      end

      vim.cmd("normal! " .. key)

      if opts.skip_folds then
        local limit = direction == "up" and 0 or vim.fn.line("$")
        local step = direction == "up" and -1 or 1
        for _ = vim.fn.line("."), limit, step do
          if vim.fn.foldlevel(".") > 0 then
            break
          end

          vim.cmd("normal! " .. key)
        end
      end

      if CommitViewBuffer.is_open() then
        local commit = ui:get_commit_under_cursor()
        if commit then
          if files then
            CommitViewBuffer.instance:update(commit, files)
          else
            CommitViewBuffer.instance:update(commit)
          end
        end
      elseif opts.open_when_absent then
        local commit = ui:get_commit_under_cursor()
        if commit then
          if files then
            CommitViewBuffer.new(commit, files):open()
          else
            CommitViewBuffer.new(commit):open()
          end
        end
      elseif opts.skip_folds then
        -- log view fallback: no commit view to mirror into - re-open the
        -- landed fold and center the row instead
        pcall(vim.cmd, "normal! zo")
        vim.cmd("normal! zz")
      end
    end
  end
end

return M
