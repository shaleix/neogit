-- Pulsing highlight ("Banner Transition") for the status buffer's ASCII
-- "NEOGIT" banner during the cold-open loading phase: while the first
-- refresh wave is still in flight, the banner gradient groups
-- (NeogitStatusBanner1..N) are redefined every frame, smoothly oscillating
-- between a dim floor and the full final gradient colors - a visible loading
-- indicator, not a one-shot fade that ends before the data arrives.
--
-- Single instance per process (like lib/loading.lua): the status buffer is
-- the only consumer and cold opens cannot overlap, so `start` simply resets
-- any previous state. The pulse only ever writes interpolated versions of
-- the definitions captured at start, so finishing from any phase restores
-- exactly those - groups owned by the user's colorscheme (hl.setup skips
-- them) can never be clobbered by hl.setup's versions leaking through.
local nvim = vim.api

local config = require("neogit.config")
local hl = require("neogit.lib.hl")

local M = {}

-- 100ms frames; one full floor-to-full cycle takes 24 frames (~2.4s).
local FRAME_INTERVAL = 100
local FRAMES_PER_PERIOD = 24

local state = {
  timer = nil, -- pulse animation
  bufnr = nil,
  frame = 0,
  -- group name -> { original, final_fg, final_bg, floor, bg_floor, bold }
  groups = nil,
}

---Raised-cosine pulse: 0 at phase 0 and 1, 1 at phase 0.5 - a smooth sine
---ease-in-out on both the rise and the fall.
---@param phase number position within one period, 0..1
---@return number
function M.pulse_wave(phase)
  return (1 - math.cos(2 * math.pi * phase)) / 2
end

---The pulse plan (exported so specs cannot drift from the timing).
---@return { interval: integer, frames_per_period: integer, period: integer }
function M.frame_plan()
  return {
    interval = FRAME_INTERVAL,
    frames_per_period = FRAMES_PER_PERIOD,
    period = FRAME_INTERVAL * FRAMES_PER_PERIOD,
  }
end

---Interpolate two integer RGB triples. Integer math all the way: nvim
---highlight colors are integers, and fractional channels would round
---differently per frame and shimmer.
---@param from integer[] {r,g,b}
---@param to integer[] {r,g,b}
---@param t number eased progress, 0..1
---@return integer[]
function M.interpolate_rgb(from, to, t)
  local out = {}
  for i = 1, 3 do
    out[i] = math.floor(from[i] + (to[i] - from[i]) * t + 0.5)
  end
  return out
end

---@param value integer 0xRRGGBB
---@return integer[]
local function rgb_of(value)
  return { math.floor(value / 0x10000) % 0x100, math.floor(value / 0x100) % 0x100, value % 0x100 }
end

---@param rgb integer[]
---@return string
local function css_of(rgb)
  return ("#%02x%02x%02x"):format(rgb[1], rgb[2], rgb[3])
end

---Background the pulse dims toward: the Normal bg when one is defined, so
---the floor reads as "dimmed into the page" on dark AND light themes;
---black/white by &bg otherwise.
---@return integer[]
local function dim_target()
  local ok, normal = pcall(nvim.nvim_get_hl, 0, { name = "Normal" })
  if ok and normal and normal.bg then
    return rgb_of(normal.bg)
  end
  return vim.o.bg == "light" and { 255, 255, 255 } or { 0, 0, 0 }
end

---Dim floor: the final color pulled 60% toward the background, keeping a
---40% trace - clearly dimmed, but unmistakably present.
---@param final_rgb integer[]
---@param bg_rgb integer[]
---@return integer[]
local function pulse_floor(final_rgb, bg_rgb)
  return M.interpolate_rgb(final_rgb, bg_rgb, 0.6)
end

---Effective attributes of a group, following `link` chains: the pulse needs
---concrete colors to interpolate. (The captured original - links included -
---is what gets restored, never this resolved view.)
---@param name string
---@return table
local function resolve(name)
  local ok, def = pcall(nvim.nvim_get_hl, 0, { name = name })
  if not ok then
    return {}
  end

  for _ = 1, 10 do
    if def.link then
      ok, def = pcall(nvim.nvim_get_hl, 0, { name = def.link })
      if not ok then
        return {}
      end
    else
      break
    end
  end

  return def
end

---Restore one group to its captured definition. Clearing first is REQUIRED:
---the pulse frames write non-default definitions, and a non-default
---definition permanently shadows any `default` one (:h hi-default), so
---plainly re-setting the original would be silently ignored. `highlight
---clear` removes every definition; the re-set original then applies again,
---whatever flag it carries.
---@param name string
---@param group table
local function restore_group(name, group)
  pcall(vim.cmd, ("highlight clear %s"):format(name))
  if group.original and not vim.tbl_isempty(group.original) then
    nvim.nvim_set_hl(0, name, group.original)
  end
end

---Write the groups for frame `n`. Frames are unbounded: the phase wraps by
---modulo, so step() stays inside the floor..full range for any n.
---@param n integer
local function step(n)
  if not state.groups then
    return
  end

  local wave = M.pulse_wave((n % FRAMES_PER_PERIOD) / FRAMES_PER_PERIOD)
  for name, group in pairs(state.groups) do
    -- Frames deliberately drop the `default` flag: a default definition
    -- cannot take effect while the group already has one, so the pulse
    -- would never become visible. restore_group() undoes the shadow.
    local attrs = {
      fg = css_of(M.interpolate_rgb(group.floor, group.final_fg, wave)),
      bold = group.bold,
    }
    if group.final_bg then
      attrs.bg = css_of(M.interpolate_rgb(group.bg_floor, group.final_bg, wave))
    end
    nvim.nvim_set_hl(0, name, attrs)
  end

  -- Highlight-only change: no buffer content moved, a plain redraw repaints
  -- the status window with the new colors (same call lib/git uses).
  vim.cmd.redraw()
end

local function stop_timer()
  if state.timer then
    local timer = state.timer
    state.timer = nil
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end
end

---Start the pulse for the banner gradient groups. No-op when the
---environment or config rules it out (no termguicolors, banner or animation
---disabled): the banner then simply renders statically.
---@param bufnr integer
function M.start(bufnr)
  M.finish() -- a previous run (if any) must not keep its timer running

  -- Interpolation needs truecolor; in 16-color terminals the static banner
  -- is already the best available rendering.
  if not vim.o.termguicolors then
    return
  end

  local status = config.values.status or {}
  if status.show_banner == false or status.banner_animation == false then
    return
  end

  state.bufnr = bufnr
  state.frame = 0
  state.groups = {}

  local bg = dim_target()
  for i = 1, hl.STATUS_BANNER_GRADIENT_STEPS do
    local name = ("NeogitStatusBanner%d"):format(i)
    local ok, original = pcall(nvim.nvim_get_hl, 0, { name = name })
    if not ok then
      original = {}
    end

    local final = resolve(name)
    -- Groups without a resolvable fg (empty, or a link chain that bottoms
    -- out attribute-less) cannot pulse; leave them untouched.
    if final.fg then
      local final_fg = rgb_of(final.fg)
      state.groups[name] = {
        original = original,
        final_fg = final_fg,
        final_bg = final.bg and rgb_of(final.bg) or nil,
        floor = pulse_floor(final_fg, bg),
        bg_floor = final.bg and pulse_floor(rgb_of(final.bg), bg) or nil,
        bold = final.bold or original.bold or nil,
      }
    end
  end

  if vim.tbl_isempty(state.groups) then
    return
  end

  step(0) -- first frame immediately: the banner must START at the floor
  state.timer = vim.uv.new_timer()
  -- No frame-count end: the pulse runs until finish()/stop() ends it (first
  -- refresh completion, buffer detach, or ColorScheme). Pulse duration ==
  -- loading duration by design - the banner IS the loading indicator, so it
  -- pulses exactly as long as there is something to wait for.
  state.timer:start(
    FRAME_INTERVAL,
    FRAME_INTERVAL,
    vim.schedule_wrap(function()
      if not state.timer then
        return
      end

      state.frame = state.frame + 1
      step(state.frame)
    end)
  )
end

---Stop the pulse and restore the captured definitions exactly (jump to
---final) from any pulse phase. Idempotent, safe from refresh completion,
---buffer close, or ColorScheme.
function M.finish()
  stop_timer()
  if not state.groups then
    return
  end

  for name, group in pairs(state.groups) do
    -- Groups with no prior definition just get cleared, so hl.setup's
    -- is_set() keeps treating them as unset.
    restore_group(name, group)
  end

  state.groups = nil
  state.bufnr = nil
  state.frame = 0
end

---Stop the pulse WITHOUT restoring: the ColorScheme handler calls this
---before hl.setup re-runs. The colorscheme switch has already reset the
---groups (hl.setup defines them `default`), so restoring our pre-switch
---captures here would resurrect stale colors on top of the new theme.
function M.stop()
  stop_timer()
  state.groups = nil
  state.bufnr = nil
  state.frame = 0
end

---Whether the pulse is currently running.
---@return boolean
function M.is_active()
  return state.timer ~= nil
end

-- Test seam; not public API.
M.internal = {
  state = state,
  step = step,
  floor = pulse_floor,
  resolve = resolve,
}

return M
