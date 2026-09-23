-- Single-file diff preview shown beside the status buffer
-- (status.diff_preview): instead of expanding hunks inline, the diff of the
-- file under the cursor renders in its own split. One preview buffer is
-- reused per process; focus always returns to the status buffer.
local Buffer = require("neogit.lib.buffer")
local Ui = require("neogit.lib.ui")
local common = require("neogit.buffers.common")
local git = require("neogit.lib.git")
local config = require("neogit.config")
local notification = require("neogit.lib.notification")
local text = Ui.text
local col = Ui.col
local row = Ui.row

local M = {}

local Diff = common.Diff
local EmptyLine = common.EmptyLine

-- Preview window width resolution (applies to vsplit kind):
--   number  -> fixed columns
--   fun(columns) -> computed columns
--   nil (default) -> editor-relative auto sizing: wide editors (over
--                    WIDTH_THRESHOLD columns) give the preview 60%, narrower
--                    ones 50%. Always clamped so the status buffer survives.
local WIDTH_THRESHOLD = 120

---@param columns number editor width
---@param conf table diff_preview config
---@return number
local function preview_width(columns, conf)
  conf = conf or config.values.status.diff_preview or {}
  local width

  if type(conf.width) == "function" then
    width = conf.width(columns)
  elseif type(conf.width) == "number" then
    width = conf.width
  elseif columns > WIDTH_THRESHOLD then
    width = math.floor(columns * 0.6)
  else
    width = math.floor(columns * 0.5)
  end

  return math.max(math.min(width or 0, columns - 10), 10)
end

---@class DiffPreviewBuffer
---@field buffer Buffer|nil
---@field item table|nil StatusItem currently displayed
local instance = nil

local function current()
  if not instance then
    instance = setmetatable({ buffer = nil, item = nil }, { __index = M })
  end

  return instance
end

---Close the preview window (no-op when not open).
function M.close()
  local self = current()
  if self.buffer then
    self.buffer:close()
    self.buffer = nil
  end
  instance = nil
end

---Whether the preview window is currently visible.
---@return boolean
function M.is_open()
  local self = current()
  return self.buffer ~= nil and self.buffer:is_visible()
end

---@return number|nil buffer handle of the open preview, if any
function M.buffer_handle()
  local self = current()
  return self.buffer and self.buffer.handle or nil
end

---Scroll the preview window with the given normal-mode keys (e.g. "<C-d>",
---"<C-u>", including any count). Returns true when the scroll was
---forwarded, false when no preview window is open (callers can fall back
---to native scrolling).
---@param keys string
---@return boolean
function M.scroll(keys)
  local self = current()
  if self.buffer and self.buffer:is_visible() and self.buffer.handle then
    local win = vim.fn.bufwinid(self.buffer.handle)
    if win ~= -1 then
      local count = vim.v.count1 > 1 and vim.v.count1 or ""
      local keycodes = vim.api.nvim_replace_termcodes(keys, true, false, true)
      vim.api.nvim_win_call(win, function()
        vim.cmd(("normal! %s%s"):format(count, keycodes))
      end)
      return true
    end
  end

  return false
end

-- Test seam: pure width resolution; not public API.
M.internal = {
  preview_width = preview_width,
}

---Show (or update) the preview with the given file item. The diff is built
---lazily on first display and cached on the item afterwards. Focus stays in
---the status buffer.
---
---When `status.diff_preview.content` returns a `{ filetype, lines }` table,
---it takes over the preview body completely: the lines are rendered as-is
---and the buffer filetype is set to the returned value, so external
---renderers can hook in via the FileType event (e.g. diffs.nvim with
---filetype "diff").
---@param status_buffer Buffer the requesting status buffer (focus target)
---@param section string section name: "untracked"|"unstaged"|"staged"
---@param item table StatusItem
function M.show(status_buffer, section, item)
  local self = current()

  -- custom content hook: full takeover when it returns a table
  self.custom = nil
  local preview_config = config.values.status.diff_preview or {}
  if type(preview_config.content) == "function" then
    local ok, result = pcall(preview_config.content, item, section)
    if ok and type(result) == "table" and type(result.lines) == "table" then
      self.custom = result
    elseif not ok then
      notification.warn("diff_preview.content failed - using built-in renderer")
    end
  end

  if not self.custom then
    if not item.diff then
      git.diff.build(section, item)
    end
  end
  self.item = item

  if self.buffer and self.buffer:is_visible() then
    self:refresh_content()
  else
    local status_window = vim.api.nvim_get_current_win()
    local status_maps = config.get_reversed_status_maps()

    local function goto_hunk(direction)
      local function hunk_header(self, line)
        local c = self.buffer.ui:get_component_on_line(line, function(comp)
          return comp.options.tag == "Diff" or comp.options.tag == "Hunk"
        end)

        if c then
          local first, _ = c:row_range_abs()
          if vim.fn.line(".") == first then
            first = hunk_header(self, line + direction) or first
          end

          return first
        end
      end

      local target = hunk_header(self, vim.fn.line("."))
      if target then
        vim.api.nvim_win_set_cursor(0, { target, 0 })
        vim.cmd("normal! zt")
      end
    end

    self.buffer = Buffer.create {
      name = "NeogitDiffPreview",
      filetype = "NeogitDiffPreview",
      kind = config.values.status.diff_preview.kind,
      bufhidden = "hide",
      status_column = not config.values.disable_signs and "" or nil,
      context_highlight = not config.values.disable_context_highlighting and config.values.log_pager == nil,
      autocmds = {
        ["WinClosed"] = function()
          local preview = current()
          if preview.buffer then
            preview.buffer = nil
            instance = nil
          end
        end,
      },
      mappings = {
        n = {
          ["q"] = function()
            M.close()
          end,
          ["<esc>"] = function()
            M.close()
          end,
          ["{"] = function()
            goto_hunk(-1)
          end,
          ["}"] = function()
            goto_hunk(1)
          end,
          [status_maps["Toggle"]] = function()
            pcall(vim.cmd, "normal! za")
          end,
        },
      },
      render = function()
        return self.custom and { text("") } or self:layout()
      end,
      after = function(buffer)
        vim.cmd("normal! zR")
        vim.wo.colorcolumn = ""

        -- the preview needs no sign/fold columns: renderer folding goes
        -- through statuscolumn, and auto-expanding signs show up as
        -- mystery padding next to the split bar
        if buffer.win_handle then
          vim.wo[buffer.win_handle].signcolumn = "no"
          vim.wo[buffer.win_handle].foldcolumn = "0"
        end

        -- custom width only applies to vertical splits
        if config.values.status.diff_preview.kind == "vsplit" and buffer.win_handle then
          vim.api.nvim_win_set_width(buffer.win_handle, preview_width(vim.o.columns))
        end

        self:refresh_content(buffer)
        -- keep the cursor working in the status buffer
        if vim.api.nvim_win_is_valid(status_window) then
          vim.api.nvim_set_current_win(status_window)
        end
        buffer:lock()
      end,
    }
  end
end

---Render the current state into the preview buffer: custom content
---(`diff_preview.content`) as raw lines with its own filetype, or the
---built-in UI layout. `buffer` is passed explicitly from the create `after`
--- hook, where the instance field is not yet assigned.
---@param buffer? Buffer explicit buffer (defaults to the instance's)
function M:refresh_content(buffer)
  buffer = buffer or self.buffer
  if not buffer or not buffer.handle then
    return
  end

  if self.custom then
    buffer:unlock()
    vim.bo[buffer.handle].filetype = self.custom.filetype or "diff"
    vim.api.nvim_buf_set_lines(buffer.handle, 0, -1, false, self.custom.lines)
    buffer:lock()
  else
    if vim.bo[buffer.handle].filetype ~= "NeogitDiffPreview" then
      vim.bo[buffer.handle].filetype = "NeogitDiffPreview"
    end
    buffer.ui:render(unpack(self:layout()))
  end
end

function M:layout()
  local item = self.item
  if not item or not item.diff then
    return { text("(no diff)") }
  end

  -- insertions/deletions counted from the hunks, like the staged-diff view
  local insertions, deletions = 0, 0
  for _, hunk in ipairs(item.diff.hunks or {}) do
    for _, line in ipairs(hunk.lines or {}) do
      if line:match("^%+") then
        insertions = insertions + 1
      elseif line:match("^%-") then
        deletions = deletions + 1
      end
    end
  end

  return {
    col {
      row {
        text.highlight("NeogitFilePath")(item.name),
        text.highlight("NeogitSubtleText")("  (" .. (item.mode or "?") .. ")"),
        text("  "),
        text.highlight("NeogitDiffAdditions")("+" .. insertions),
        text(" "),
        text.highlight("NeogitDiffDeletions")("-" .. deletions),
      },
      EmptyLine(),
      Diff(item.diff),
    },
  }
end

return M
