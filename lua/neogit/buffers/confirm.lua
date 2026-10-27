-- Confirm Dialog (see CONTEXT.md): the centered, masked yes/no dialog
-- behind input.get_permission / input.get_confirmation.
--
-- Layout (validated as a throwaway prototype first):
--   ┌ (invisible border, level-colored " Confirm " bar top-center,
--     │  dimmed " Enter select · Tab switch · Esc cancel " bottom-right)
--   │      <icon> <message>
--   │      ▸ [y]es   [n]o        (selected = level color, unselected dim)
--
-- Keys: Tab toggles the selection, <cr> submits it; y/n jump-select and
-- auto-commit after DELAYED_COMMIT_MS (Esc during the window cancels; any
-- other key invalidates the pending commit); Esc/q/Ctrl-C answer No.
--
-- A full-screen backdrop (pure black + winblend, not focusable) dims the
-- editor; its lifetime is bound to the dialog buffer, so it can never leak.
--
-- The dialog is modal by construction: keys are read straight from typeahead
-- in a blocking loop (the same mechanism vim.fn.confirm uses), so
-- input.get_permission stays synchronous from any context - plain calls and
-- coroutines alike - and callers keep their `if input.get_permission(...)`
-- shape unchanged.
local config = require("neogit.config")
local logger = require("neogit.logger")

local M = {}

-- y/n jump-select commits this many milliseconds after the last keypress.
local DELAYED_COMMIT_MS = 300

-- Never render narrower than this, however short the message is.
local MIN_WIDTH = 60

local LEVELS = {
  danger = { hl = "NeogitConfirmDanger", title_hl = "NeogitConfirmTitleDanger" },
  warning = { hl = "NeogitConfirmWarn", title_hl = "NeogitConfirmTitleWarn" },
  info = { hl = "NeogitConfirmInfo", title_hl = "NeogitConfirmTitleInfo" },
}

local state = {
  win = nil,
  buf = nil,
  parent_win = nil,
  selected = 2, -- 1 = [y]es, 2 = [n]o
  result = nil,
  level = nil,
  last_level = nil,
  ns = vim.api.nvim_create_namespace("neogit-confirm"),
}

-- Test/inspection seam: which level the last dialog rendered with.
M._state = state

---@return boolean
function M.is_open()
  return state.win ~= nil
end

-- Full-screen backdrop: pure black background pushed through winblend so the
-- editor dims behind the dialog. Bound to the dialog buffer's lifetime
-- (BufWinLeave/BufHidden/BufWipeout) instead of the window id, so closing
-- the dialog by any path dismisses the mask exactly once.
local function dim_open(host_buf)
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = vim.o.columns,
    height = vim.o.lines - 1, -- never cover the statusline
    focusable = false,
    style = "minimal",
    border = "none",
    -- above every other float (nvim's default zindex is 50, so the diff
    -- preview and friends would shine through at 49), just below the dialog
    zindex = 59,
  })
  vim.wo[win].winhighlight = "Normal:NeogitConfirmBackdrop"
  vim.wo[win].winblend = 50
  vim.bo[buf].buftype = "nofile"

  local gone = false
  vim.api.nvim_create_autocmd({ "BufWinLeave", "BufHidden", "BufWipeout" }, {
    buffer = host_buf,
    once = true,
    callback = function()
      if gone then
        return
      end
      gone = true
      pcall(vim.api.nvim_win_close, win, true)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end,
  })
end

local function choice_row()
  local yes = (state.selected == 1) and "▸ [y]es" or "  [y]es"
  local no = (state.selected == 2) and "▸ [n]o" or "  [n]o"
  return "   " .. yes .. "     " .. no
end

local function rerender_choices()
  local yes = (state.selected == 1) and "▸ [y]es" or "  [y]es"
  local no = (state.selected == 2) and "▸ [n]o" or "  [n]o"
  local lv = LEVELS[state.level]

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 3, 4, false, { choice_row() })
  vim.bo[state.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(state.buf, state.ns, 3, 4)

  local yes_start = #"   "
  local no_start = yes_start + #yes + #"     "
  local yes_hl = (state.selected == 1) and lv.hl or "NeogitConfirmDim"
  local no_hl = (state.selected == 2) and lv.hl or "NeogitConfirmDim"
  vim.api.nvim_buf_add_highlight(state.buf, state.ns, yes_hl, 3, yes_start, yes_start + #yes)
  vim.api.nvim_buf_add_highlight(state.buf, state.ns, no_hl, 3, no_start, no_start + #no)
end

local function finish(result)
  if not state.win then
    return
  end
  state.last_level = state.level

  pcall(vim.api.nvim_win_close, state.win, true) -- bufhidden=wipe dismisses the backdrop
  state.win, state.buf, state.level = nil, nil, nil
  pcall(vim.api.nvim_set_current_win, state.parent_win)
  state.result = result
end

-- Blocking key read with the dialog redrawn first. Returns nil when
-- interrupted (Ctrl-C).
---@return string|nil
local function read_key()
  pcall(vim.cmd, "redraw")
  local ok, key = pcall(vim.fn.getcharstr)
  if not ok then
    return nil
  end
  return key
end

-- The beat between a y/n jump-select and its auto-commit: redraw with the
-- flipped selection and poll typeahead for DELAYED_COMMIT_MS. Esc (or an
-- interrupt) during the window cancels; any other key invalidates the
-- pending commit and is returned for the main loop to process normally.
---@return "commit"|"cancelled"|string the invalidating key
local function delay_window()
  local deadline = vim.loop.now() + DELAYED_COMMIT_MS
  while vim.loop.now() < deadline do
    pcall(vim.cmd, "redraw")
    if vim.fn.getchar(1) ~= 0 then
      local ok, key = pcall(vim.fn.getcharstr)
      if not ok or key == "\27" then
        return "cancelled"
      end
      return key
    end
    vim.wait(15, function()
      return false
    end)
  end
  return "commit"
end

---Open the dialog and block until it resolves.
---@param msg string message shown under the level bar
---@param level "danger"|"warning"|"info" colors the bar, icon and choice text
---@param default_yes boolean initial selection ([y]es vs [n]o)
---@return boolean choice (true = Yes)
function M.open(msg, level, default_yes)
  local lv = LEVELS[level] or LEVELS.info
  local icon = config.values.icons.confirm[level] or ""
  local msg_line = icon .. msg
  local parent_win = vim.api.nvim_get_current_win()

  state.selected = default_yes and 1 or 2
  state.result = nil
  state.level = level

  -- blank / message / blank / choices / blank — the blank rows separate the
  -- content from the title bar and the bottom border slot
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", "   " .. msg_line, "", choice_row(), "" })
  vim.bo[buf].bufhidden = "wipe"

  local width = math.min(
    math.max(vim.fn.strdisplaywidth(msg_line) + 3 + 5 + 5, MIN_WIDTH),
    math.floor(vim.o.columns * 0.6)
  )
  local height = 5

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    -- centered, but deliberately higher than true center (38% of the free
    -- space above instead of 50%) so the dialog doesn't sit on the status
    -- buffer's middle content
    row = math.floor((vim.o.lines - height - 2) * 0.38),
    col = math.floor((vim.o.columns - width - 2) / 2),
    border = { " ", " ", " ", " ", " ", " ", " ", " " }, -- invisible border
    style = "minimal",
    zindex = 60,
    title = { { " Confirm ", lv.title_hl } },
    title_pos = "center",
    footer = { { " Enter select · Tab switch · Esc cancel ", "NeogitConfirmHint" } },
    footer_pos = "right",
  })
  -- Same background for content and border slots: a solid panel instead of
  -- floating text the backdrop bleeds through
  vim.wo[win].winhighlight = "Normal:NeogitConfirmNormal,FloatBorder:NeogitConfirmNormal"
  vim.bo[buf].modifiable = false

  state.win, state.buf, state.parent_win = win, buf, parent_win
  rerender_choices()

  dim_open(buf)

  -- Modal loop: unknown keys (and mouse events) are simply ignored. Keys read
  -- during a delay window are handed back here so they keep their normal
  -- meaning (e.g. Tab both invalidates the pending commit and toggles).
  local pending_key = nil
  while true do
    local key = pending_key or read_key()
    pending_key = nil

    if key == nil or key == "\27" or key == "q" then
      finish(false)
      break
    elseif key == "\r" or key == "\n" then
      finish(state.selected == 1)
      break
    elseif key == "\t" then
      state.selected = (state.selected == 1) and 2 or 1
      rerender_choices()
    elseif key == "y" or key == "Y" then
      state.selected = 1
      rerender_choices()
      local outcome = delay_window()
      if outcome == "commit" then
        finish(true)
        break
      elseif outcome == "cancelled" then
        finish(false)
        break
      else
        pending_key = outcome
      end
    elseif key == "n" or key == "N" then
      state.selected = 2
      rerender_choices()
      local outcome = delay_window()
      if outcome == "commit" or outcome == "cancelled" then
        finish(false)
        break
      else
        pending_key = outcome
      end
    end
  end

  if state.result == nil then
    logger.debug("[confirm] dialog loop ended without a result")
  end

  return state.result == true
end

return M
