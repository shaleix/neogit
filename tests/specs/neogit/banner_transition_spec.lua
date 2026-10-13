-- The banner fade-in transition: the pure math (easing, interpolation,
-- frame plan), and the start/finish lifecycle driven on a sentinel
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

describe("banner transition math", function()
  it("eases out cubically", function()
    assert.equal(0, transition.ease_out_cubic(0))
    assert.equal(1, transition.ease_out_cubic(1))
    -- Ease-out front-loads the change: every prefix is past the linear point.
    assert.truthy(transition.ease_out_cubic(0.25) > 0.25)
    assert.truthy(transition.ease_out_cubic(0.5) > 0.5)
    assert.truthy(transition.ease_out_cubic(0.75) > 0.75)
  end)

  it("plans ~400ms in ~40ms frames", function()
    local plan = transition.frame_plan()
    assert.equal(40, plan.interval)
    assert.equal(10, plan.frames)
    assert.equal(400, plan.total)
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

  it("dims toward the background, keeping a trace of the final color", function()
    local anchor = transition.internal.dim_anchor { 100, 100, 100 }
    -- 15% of the final color survives: dim, but not invisible.
    for i = 1, 3 do
      assert.truthy(anchor[i] > 0 and anchor[i] < 100, "anchor must sit between black and the final color")
    end
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
    assert.truthy(transition.is_active(), "animation must run after start")

    -- Mid-animation the group carries the interpolated dim color, not the
    -- sentinel (and not the dim anchor of frame 0 either).
    transition.internal.step(3)
    assert.are_not.same(
      original,
      vim.api.nvim_get_hl(0, { name = NAME }),
      "frame 3 must not show the final colors"
    )

    transition.finish()
    assert.falsy(transition.is_active(), "timer must be stopped after finish")
    assert.are.same(original, vim.api.nvim_get_hl(0, { name = NAME }))
  end)

  it("writes the exact originals on the final frame", function()
    set_sentinel()
    local original = sentinel_as_read()

    transition.start(assert(vim.api.nvim_get_current_buf()))
    -- Jump straight to the last frame: the natural end of the animation.
    transition.internal.step(transition.frame_plan().frames)
    assert.are.same(original, vim.api.nvim_get_hl(0, { name = NAME }))

    transition.finish()
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
    assert.falsy(transition.is_active(), "animation must be skipped")
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
