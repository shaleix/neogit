-- Single-file diff preview shown beside the status buffer
-- (status.diff_preview): instead of expanding hunks inline, the diff of the
-- file under the cursor renders in its own split. One preview buffer is
-- reused per process; focus always returns to the status buffer.
local Buffer = require("neogit.lib.buffer")
local Ui = require("neogit.lib.ui")
local common = require("neogit.buffers.common")
local git = require("neogit.lib.git")
local config = require("neogit.config")
local text = Ui.text
local col = Ui.col
local row = Ui.row

local M = {}

local Diff = common.Diff
local EmptyLine = common.EmptyLine

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

---Show (or update) the preview with the given file item. The diff is built
---lazily on first display and cached on the item afterwards. Focus stays in
---the status buffer.
---@param status_buffer Buffer the requesting status buffer (focus target)
---@param section string section name: "untracked"|"unstaged"|"staged"
---@param item table StatusItem
function M.show(status_buffer, section, item)
  local self = current()

  if not item.diff then
    git.diff.build(section, item)
  end

  self.item = item

  if self.buffer and self.buffer:is_visible() then
    self.buffer.ui:render(unpack(self:layout()))
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
        return self:layout()
      end,
      after = function(buffer)
        vim.cmd("normal! zR")
        vim.wo.colorcolumn = ""
        -- keep the cursor working in the status buffer
        if vim.api.nvim_win_is_valid(status_window) then
          vim.api.nvim_set_current_win(status_window)
        end
        buffer:lock()
      end,
    }
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
