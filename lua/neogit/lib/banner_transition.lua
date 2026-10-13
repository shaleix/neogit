-- Brightness fade-in ("Banner Transition") for the status buffer's ASCII
-- "NEOGIT" banner: on cold open, while the first refresh wave is still in
-- flight, the banner gradient groups (NeogitStatusBanner1..N) are redefined
-- every frame, interpolating each color from a dim anchor up to its final
-- value, so the title fades in during the loading phase.
--
-- Single instance per process (like lib/loading.lua): the status buffer is
-- the only consumer and cold opens cannot overlap, so `start` simply resets
-- any previous state. The animation only ever writes interpolated versions
-- of the definitions captured at start, so finishing at any point restores
-- exactly those - groups owned by the user's colorscheme (hl.setup skips
-- them) can never be clobbered by hl.setup's versions leaking through.
local nvim = vim.api

local config = require("neogit.config")
local hl = require("neogit.lib.hl")

local M = {}

-- ~40ms per frame, ~400ms total: long enough to read as a fade, short
-- enough to usually complete before the refresh wave lands.
local FRAME_INTERVAL = 40
local FRAME_COUNT = 10

local state = {
  timer = nil, -- frame animation
  bufnr = nil,
  frame = 0,
  -- group name -> { original, final_fg, final_bg, anchor, bg_anchor, bold }
  groups = nil,
}

---Cubic ease-out: fast start, gentle settle.
---@param t number progress, 0..1
---@return number
function M.ease_out_cubic(t)
  local clamped = math.min(math.max(t, 0), 1)
  return 1 - (1 - clamped) ^ 3
end

---The frame plan (exported so specs cannot drift from the timing).
---@return { interval: integer, frames: integer, total: integer }
function M.frame_plan()
  return { interval = FRAME_INTERVAL, frames = FRAME_COUNT, total = FRAME_INTERVAL * FRAME_COUNT }
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

---Dim start color: the final color pulled most of the way to the Normal
---background, so the first frame reads as "barely there" on dark AND light
---themes. Without a Normal bg (rare), fall back to black/white by &bg.
---@param final_rgb integer[]
---@return integer[]
local function dim_anchor(final_rgb)
  local anchor
  local ok, normal = pcall(nvim.nvim_get_hl, 0, { name = "Normal" })
  if ok and normal and normal.bg then
    anchor = rgb_of(normal.bg)
  else
    anchor = vim.o.bg == "light" and { 255, 255, 255 } or { 0, 0, 0 }
  end

  -- 85% of the way to the background leaves a 15% trace of the final color.
  return M.interpolate_rgb(final_rgb, anchor, 0.85)
end

---Effective attributes of a group, following `link` chains: the animation
---needs concrete colors to interpolate. (The captured original - links
---included - is what gets restored, never this resolved view.)
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
---the animation frames write non-default definitions, and a non-default
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

---Write the groups for frame `n` (0-based). The last frame restores the
---exact captured definitions, so the animation's endpoint is identical to
---the static banner.
---@param n integer
local function step(n)
  if not state.groups then
    return
  end

  local final_frame = n >= FRAME_COUNT
  for name, group in pairs(state.groups) do
    if final_frame then
      restore_group(name, group)
    else
      local t = M.ease_out_cubic(n / FRAME_COUNT)
      -- Frames deliberately drop the `default` flag: a default definition
      -- cannot take effect while the group already has one, so the fade
      -- would never become visible. restore_group() undoes the shadow.
      local attrs = {
        fg = css_of(M.interpolate_rgb(group.anchor, group.final_fg, t)),
        bold = group.bold,
      }
      if group.final_bg then
        attrs.bg = css_of(M.interpolate_rgb(group.bg_anchor, group.final_bg, t))
      end
      nvim.nvim_set_hl(0, name, attrs)
    end
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

---Start the fade-in for the banner gradient groups. No-op when the
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

  for i = 1, hl.STATUS_BANNER_GRADIENT_STEPS do
    local name = ("NeogitStatusBanner%d"):format(i)
    local ok, original = pcall(nvim.nvim_get_hl, 0, { name = name })
    if not ok then
      original = {}
    end

    local final = resolve(name)
    -- Groups without a resolvable fg (empty, or a link chain that bottoms
    -- out attribute-less) cannot fade; leave them untouched.
    if final.fg then
      local final_fg = rgb_of(final.fg)
      state.groups[name] = {
        original = original,
        final_fg = final_fg,
        final_bg = final.bg and rgb_of(final.bg) or nil,
        anchor = dim_anchor(final_fg),
        bg_anchor = final.bg and dim_anchor(rgb_of(final.bg)) or nil,
        bold = final.bold or original.bold or nil,
      }
    end
  end

  if vim.tbl_isempty(state.groups) then
    return
  end

  step(0) -- first frame immediately: the banner must START dim, not pop
  state.timer = vim.uv.new_timer()
  state.timer:start(
    FRAME_INTERVAL,
    FRAME_INTERVAL,
    vim.schedule_wrap(function()
      if not state.timer then
        return
      end

      state.frame = state.frame + 1
      if state.frame >= FRAME_COUNT then
        M.finish() -- natural end: last frame already restored the originals
      else
        step(state.frame)
      end
    end)
  )
end

---Stop the animation and restore the captured definitions exactly (jump to
---final). Idempotent, safe from refresh completion, buffer close, or the
---animation's own end.
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

---Stop the animation WITHOUT restoring: the ColorScheme handler calls this
---before hl.setup re-runs. The colorscheme switch has already reset the
---groups (hl.setup defines them `default`), so restoring our pre-switch
---captures here would resurrect stale colors on top of the new theme.
function M.stop()
  stop_timer()
  state.groups = nil
  state.bufnr = nil
  state.frame = 0
end

---Whether the animation is currently running.
---@return boolean
function M.is_active()
  return state.timer ~= nil
end

-- Test seam; not public API.
M.internal = {
  state = state,
  step = step,
  dim_anchor = dim_anchor,
  resolve = resolve,
}

return M
