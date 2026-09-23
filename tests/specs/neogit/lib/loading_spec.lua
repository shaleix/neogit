-- Bottom-center loading indicator (lib/loading.lua): spinner while loading,
-- colored result state that lingers and auto-dismisses.
local loading = require("neogit.lib.loading")
local nvim = vim.api

describe("lib.loading", function()
  after_each(function()
    loading.close()
  end)

  local function content()
    local s = loading.internal.state
    if not s.buf or not nvim.nvim_buf_is_valid(s.buf) then
      return ""
    end
    local lines = nvim.nvim_buf_get_lines(s.buf, 0, -1, false)
    return lines[2] or "", lines
  end

  it("shows a full-width bottom banner with centered spinner and text", function()
    loading.show("working hard")

    assert.truthy(loading.is_active(), "window must be visible")
    assert.truthy(content():find("working hard", 1, true), "text must render")

    local s = loading.internal.state
    local win_config = nvim.nvim_win_get_config(s.win)
    assert.equal("editor", win_config.relative, "must float over the editor")
    assert.equal(false, win_config.focusable, "must never take focus")

    -- full editor width, at the bottom, starting at column 0, 3 rows tall
    assert.equal(vim.o.columns, win_config.width, "must span the full editor width")
    assert.equal(3, win_config.height, "must have padding rows above and below")
    assert.equal(0, win_config.col, "must start at column 0")
    assert.truthy(win_config.row > vim.o.lines / 2, "must sit near the bottom")

    local _, lines = content()
    assert.equal(3, #lines, "buffer must hold blank/text/blank rows")
    assert.equal(vim.o.columns, #(lines[1] or ""), "padding row must fill the width")
    assert.equal(vim.o.columns, #(lines[3] or ""), "padding row must fill the width")

    -- the icon+text centers inside the full-width banner (byte-length math
    -- is approximate around the multi-byte icon, so compare side padding)
    local line = content()
    local leading = #(line:match("^%s*"))
    local trailing = #(line:match("%s*$"))
    assert.truthy(
      math.abs(leading - trailing) <= 4,
      ("text must be centered (leading=%d trailing=%d)"):format(leading, trailing)
    )

    -- spinner animates
    local first = content()
    assert.truthy(vim.wait(500, function()
      return content() ~= first
    end), "spinner frames must animate")
  end)

  it("settles into a colored result state and auto-dismisses", function()
    loading.show("generating")
    loading.done("feat: done!", vim.log.levels.INFO)

    assert.truthy(content():find("feat: done!", 1, true), "final text must render")
    assert.truthy(content():find("✓", 1, true), "success icon")

    local s = loading.internal.state
    assert.truthy(s.result and s.result.hl == "NeogitSpinnerSuccess", "success highlight")

    assert.truthy(vim.wait(5000, function()
      return not loading.is_active()
    end), "window must auto-dismiss after lingering")
  end)

  it("uses warn styling for failures and lingers longer", function()
    loading.show("generating")
    loading.done("timed out", vim.log.levels.WARN)

    assert.truthy(content():find("✗", 1, true), "failure icon")
    local s = loading.internal.state
    assert.truthy(s.result and s.result.hl == "NeogitSpinnerWarn", "warn highlight")
  end)

  it("re-showing resets a settled result", function()
    loading.show("first")
    loading.done("done", vim.log.levels.INFO)
    loading.show("second run")

    assert.truthy(loading.is_active(), "window must be back")
    assert.truthy(content():find("second run", 1, true))
    assert.is_nil(loading.internal.state.result, "result state must reset")
  end)
end)
