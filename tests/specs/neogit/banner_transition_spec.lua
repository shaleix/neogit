-- The banner pulse transition: the pure math (waveform, interpolation,
-- pulse plan, floor), and the start/finish lifecycle driven on a sentinel
-- definition of one of the real gradient groups.
local transition = require("neogit.lib.banner_transition")
local config = require("neogit.config")
local hl = require("neogit.lib.hl")

-- A group inside the real gradient range, plus its sentinel definition
-- (integer colors: nvim_get_hl always returns integers, even for
-- definitions made with css-style strings).
local NAME = "NeogitStatusBanner3"
local SENTINEL = { fg = 0x123456, bg = 0xabcdef, bold = true }

-- The definition as nvim_get_hl reports it (it normalizes attributes, e.g.
-- synthesizing a cterm table for bold), so roundtrip assertions compare
-- against reality rather than the raw literal we passed in.
local function sentinel_as_read()
  return vim.api.nvim_get_hl(0, { name = NAME })
end

local function set_sentinel()
  vim.api.nvim_set_hl(0, NAME, SENTINEL)
end

-- Floating-point-safe comparison for waveform values.
local function assert_close(actual, expected, message)
  assert.truthy(
    math.abs(actual - expected) < 1e-9,
    ("%s (got %s, want %s)"):format(message, actual, expected)
  )
end

describe("banner transition math", function()
  it("plans a ~2400ms period at 100ms frames", function()
    local plan = transition.frame_plan()
    assert.equal(100, plan.interval)
    assert.equal(24, plan.frames_per_period)
    assert.equal(2400, plan.period)
  end)

  it("waves smoothly: floor at the edges, full at mid-period", function()
    assert_close(transition.pulse_wave(0), 0, "phase 0 must sit at the floor")
    assert_close(transition.pulse_wave(1), 0, "phase 1 must sit at the floor")
    assert_close(transition.pulse_wave(0.5), 1, "mid-period must be the full color")
    -- Sine ease-in-out: the quarter phases are exactly halfway.
    assert_close(transition.pulse_wave(0.25), 0.5, "rise must ease in and out")
    assert_close(transition.pulse_wave(0.75), 0.5, "fall must ease in and out")
  end)

  it("interpolates in integer RGB", function()
    assert.are.same({ 0, 0, 0 }, transition.interpolate_rgb({ 0, 0, 0 }, { 100, 200, 40 }, 0))
    assert.are.same({ 100, 200, 40 }, transition.interpolate_rgb({ 0, 0, 0 }, { 100, 200, 40 }, 1))
    assert.are.same({ 50, 100, 20 }, transition.interpolate_rgb({ 0, 0, 0 }, { 100, 200, 40 }, 0.5))
    -- Rounding stays integral at awkward fractions.
    local mid = transition.interpolate_rgb({ 0, 0, 0 }, { 99, 199, 39 }, 1 / 3)
    for _, channel in ipairs(mid) do
      assert.equal(0, channel % 1, "channels must be whole numbers")
    end
  end)

  it("floors at a 40% trace of the final color", function()
    -- Toward a black background: exactly 40% of the final color survives.
    assert.are.same({ 40, 40, 40 }, transition.internal.floor({ 100, 100, 100 }, { 0, 0, 0 }))
    -- Toward a bright background the floor sits between the two.
    assert.are.same({ 160, 160, 160 }, transition.internal.floor({ 100, 100, 100 }, { 200, 200, 200 }))
  end)
end)

describe("banner transition lifecycle", function()
  before_each(function()
    vim.o.termguicolors = true
    config.values.status.show_banner = true
    config.values.status.banner_animation = true
  end)

  after_each(function()
    transition.finish()
    config.values = config.get_default_values()
  end)

  it("redefines the groups per frame and restores the originals on finish", function()
    set_sentinel()
    local original = sentinel_as_read()

    transition.start(assert(vim.api.nvim_get_current_buf()))
    assert.truthy(transition.is_active(), "pulse must run after start")

    -- Mid-pulse the group carries an interpolated color, neither the floor
    -- nor the sentinel.
    transition.internal.step(7)
    assert.are_not.same(
      original,
      vim.api.nvim_get_hl(0, { name = NAME }),
      "mid-pulse frame must not show the final colors"
    )

    transition.finish()
    assert.falsy(transition.is_active(), "timer must be stopped after finish")
    assert.are.same(original, vim.api.nvim_get_hl(0, { name = NAME }))
  end)

  it("keeps pulsing well past one period: no self-finish", function()
    set_sentinel()
    local original = sentinel_as_read()

    transition.start(assert(vim.api.nvim_get_current_buf()))

    -- Drive far beyond a full period (24 frames) and past the old one-shot
    -- 400ms runtime: the pulse is tied to the loading phase, not a count.
    for n = 0, 61 do
      transition.internal.step(n)
    end
    assert.truthy(transition.is_active(), "pulse must run until finish()/stop()")

    transition.finish()
    assert.falsy(transition.is_active())
    assert.are.same(original, vim.api.nvim_get_hl(0, { name = NAME }))
  end)

  it("step colors are periodic and stay within floor..full", function()
    set_sentinel()

    transition.start(assert(vim.api.nvim_get_current_buf()))
    local frames_per_period = transition.frame_plan().frames_per_period

    local function fg_at(n)
      transition.internal.step(n)
      return vim.api.nvim_get_hl(0, { name = NAME }).fg
    end

    -- Periodic: same phase, same color, arbitrarily far apart.
    assert.equal(fg_at(5), fg_at(5 + frames_per_period))
    assert.equal(fg_at(5), fg_at(5 + 3 * frames_per_period))

    -- Top of the pulse hits the exact final color.
    assert.equal(SENTINEL.fg, fg_at(frames_per_period / 2))

    -- Bottom sits exactly on the floor: a 40% trace of the final color
    -- toward the same Normal bg the module dims toward (a very dark final
    -- color on a lighter bg may floor BRIGHTER than the final - that is the
    -- correct bg-relative dimming, so compare against the exact value).
    local function rgb_of(c)
      return { math.floor(c / 0x10000) % 0x100, math.floor(c / 0x100) % 0x100, c % 0x100 }
    end

    local ok, normal = pcall(vim.api.nvim_get_hl, 0, { name = "Normal" })
    local bg = ok and normal and normal.bg and rgb_of(normal.bg)
      or (vim.o.bg == "light" and { 255, 255, 255 } or { 0, 0, 0 })
    local floor = transition.internal.floor(rgb_of(SENTINEL.fg), bg)
    assert.equal(floor[1] * 0x10000 + floor[2] * 0x100 + floor[3], fg_at(0))

    transition.finish()
  end)

  it("finish from a mid-pulse phase restores the exact originals", function()
    set_sentinel()
    local original = sentinel_as_read()

    transition.start(assert(vim.api.nvim_get_current_buf()))
    -- Park the pulse near its brightest phase before cutting it.
    transition.internal.step(transition.frame_plan().frames_per_period / 2)
    transition.finish()
    assert.are.same(original, vim.api.nvim_get_hl(0, { name = NAME }))
  end)

  it("double-finish is idempotent", function()
    set_sentinel()
    local original = sentinel_as_read()

    transition.start(assert(vim.api.nvim_get_current_buf()))
    transition.finish()
    assert.has_no.errors(transition.finish)
    assert.falsy(transition.is_active())
    assert.are.same(original, vim.api.nvim_get_hl(0, { name = NAME }))
  end)

  it("no-ops when status.banner_animation is false", function()
    config.values.status.banner_animation = false
    set_sentinel()
    local original = sentinel_as_read()

    transition.start(assert(vim.api.nvim_get_current_buf()))
    assert.falsy(transition.is_active(), "pulse must be skipped")
    assert.are.same(original, vim.api.nvim_get_hl(0, { name = NAME }), "group must stay untouched")
  end)

  it("no-ops when status.show_banner is false", function()
    config.values.status.show_banner = false
    set_sentinel()
    local original = sentinel_as_read()

    transition.start(assert(vim.api.nvim_get_current_buf()))
    assert.falsy(transition.is_active())
    assert.are.same(original, vim.api.nvim_get_hl(0, { name = NAME }))
  end)

  it("no-ops when termguicolors is off", function()
    vim.o.termguicolors = false
    set_sentinel()
    local original = sentinel_as_read()

    transition.start(assert(vim.api.nvim_get_current_buf()))
    assert.falsy(transition.is_active())
    assert.are.same(original, vim.api.nvim_get_hl(0, { name = NAME }))
    vim.o.termguicolors = true
  end)

  it("animates every gradient step in the plan", function()
    -- Give every step a resolvable fg (sentinel colors, not hl.setup's) so
    -- the module and the UI must agree on how many groups exist.
    for i = 1, hl.STATUS_BANNER_GRADIENT_STEPS do
      vim.api.nvim_set_hl(0, ("NeogitStatusBanner%d"):format(i), { fg = 0x111111 + i })
    end

    transition.start(assert(vim.api.nvim_get_current_buf()))
    assert.equal(hl.STATUS_BANNER_GRADIENT_STEPS, vim.tbl_count(transition.internal.state.groups or {}))

    transition.finish()
  end)
end)
