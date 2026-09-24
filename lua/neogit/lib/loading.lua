-- Bottom-center floating loading indicator: a spinner icon plus text while
-- work is running, settling into a colored result state (check/cross) that
-- auto-dismisses. First consumer: AI Commit.
--
-- Single instance per process; `show` resets any previous state. The window
-- never takes focus and blends with the colorscheme via Neogit* highlight
-- groups (NeogitSpinner{,Success,Warn,Error}).
local nvim = vim.api

local M = {}

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPINNER_INTERVAL = 90
local DONE_ICON = "✓"
local FAIL_ICON = "✗"
-- ms the result state stays visible before the window closes
local DONE_LINGER = 3000

local state = {
  win = nil,
  buf = nil,
  ns = nil,
  timer = nil, -- spinner animation
  close_timer = nil, -- result-state auto close
  frame = 0,
  text = "",
  result = nil, -- { icon, hl, linger } when settled
}

local function highlight_for(level)
  if level == nil or level <= vim.log.levels.INFO then
    return DONE_ICON, "NeogitSpinnerSuccess"
  elseif level <= vim.log.levels.WARN then
    return FAIL_ICON, "NeogitSpinnerWarn"
  else
    return FAIL_ICON, "NeogitSpinnerError"
  end
end

local function render()
  if not state.buf or not nvim.nvim_buf_is_valid(state.buf) then
    return
  end

  local icon, hl
  if state.result then
    icon, hl = state.result.icon, state.result.hl
  else
    icon = FRAMES[(state.frame % #FRAMES) + 1]
    hl = "NeogitSpinner"
  end

  -- Full-width banner with one blank padding row above and below the text
  -- row; every row is padded to the full width so the highlight paints the
  -- whole strip as the background, and the icon+text centers inside it.
  -- Centering uses display width, not byte length: the braille/check icons
  -- are multi-byte but single-cell, and byte math leaves the row shorter
  -- than the window, so the last cells miss the banner highlight.
  local width = vim.o.columns
  local inner = ("%s %s"):format(icon, state.text)
  local inner_width = vim.fn.strdisplaywidth(inner)
  local pad = math.max(math.floor((width - inner_width) / 2), 0)
  local trailing = math.max(width - pad - inner_width, 0)
  local content = ("%s%s%s"):format((" "):rep(pad), inner, (" "):rep(trailing))
  local blank = (" "):rep(width)

  nvim.nvim_buf_set_lines(state.buf, 0, -1, false, { blank, content, blank })
  nvim.nvim_buf_clear_namespace(state.buf, state.ns, 0, -1)
  for l = 0, 2 do
    nvim.nvim_buf_add_highlight(state.buf, state.ns, hl, l, 0, -1)
  end

  if state.win and nvim.nvim_win_is_valid(state.win) then
    nvim.nvim_win_set_config(state.win, {
      relative = "editor",
      row = vim.o.lines - vim.o.cmdheight - 4,
      col = 0,
      width = width,
      height = 3,
    })
  end
end

local function stop_timers()
  if state.timer then
    state.timer:close()
    state.timer = nil
  end
  if state.close_timer then
    state.close_timer:close()
    state.close_timer = nil
  end
end

local function ensure_window()
  if state.win and nvim.nvim_win_is_valid(state.win) and state.buf and nvim.nvim_buf_is_valid(state.buf) then
    return
  end

  state.buf = nvim.nvim_create_buf(false, true)
  state.ns = nvim.nvim_create_namespace("NeogitLoading")
  state.win = nvim.nvim_open_win(state.buf, false, {
    relative = "editor",
    row = vim.o.lines - vim.o.cmdheight - 4,
    col = 0,
    width = vim.o.columns,
    height = 3,
    style = "minimal",
    border = "none",
    focusable = false,
    zindex = 60,
    noautocmd = true,
  })

  -- solid background: the banner color must not be washed out
  vim.wo[state.win].winblend = 0
  vim.wo[state.win].winhighlight = "Normal:NeogitNormalFloat,FloatBorder:NeogitFloatBorder"
end

---Show (or update) the loading indicator with the given text.
---@param text string
function M.show(text)
  stop_timers()
  state.text = text or ""
  state.result = nil
  state.frame = 0

  ensure_window()
  render()

  state.timer = vim.uv.new_timer()
  state.timer:start(SPINNER_INTERVAL, SPINNER_INTERVAL, vim.schedule_wrap(function()
    if state.result then
      return
    end
    state.frame = state.frame + 1
    render()
  end))
end

---Settle into the result state: icon and color follow `level`, the window
---lingers briefly and closes itself.
---@param text string final text
---@param level integer vim.log.levels.INFO on success, WARN/ERROR on failure
function M.done(text, level)
  if not state.win then
    return
  end

  local icon, hl = highlight_for(level)
  state.text = text or state.text
  state.result = { icon = icon, hl = hl }
  render()

  if state.timer then
    state.timer:close()
    state.timer = nil
  end

  state.close_timer = vim.uv.new_timer()
  state.close_timer:start(DONE_LINGER, 0, vim.schedule_wrap(function()
    M.close()
  end))
end

---Close the indicator immediately (idempotent).
function M.close()
  stop_timers()
  if state.win and nvim.nvim_win_is_valid(state.win) then
    nvim.nvim_win_close(state.win, true)
  end
  if state.buf and nvim.nvim_buf_is_valid(state.buf) then
    nvim.nvim_buf_delete(state.buf, { force = true, unload = false })
  end
  state.win = nil
  state.buf = nil
  state.result = nil
end

---Whether the indicator is currently visible.
---@return boolean
function M.is_active()
  return state.win ~= nil and nvim.nvim_win_is_valid(state.win)
end

-- Test seam; not public API.
M.internal = {
  state = state,
}

return M
