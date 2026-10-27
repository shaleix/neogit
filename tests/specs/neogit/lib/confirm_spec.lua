-- Confirm Dialog (buffers/confirm.lua) behind input.get_permission /
-- get_confirmation. Covers the interaction contract: initial selection =
-- default answer, Tab + Enter, y/n delayed auto-commit with Esc interception,
-- level inference and explicit override, and the routing fallbacks
-- (confirm.use_vim, custom values, reentrancy) via the input._vim_confirm
-- seam.
local neogit = require("neogit")
local config = require("neogit.config")
local input = require("neogit.lib.input")
local confirm_buffer = require("neogit.buffers.confirm")

local function press(keys, delay_ms)
  vim.defer_fn(function()
    vim.api.nvim_input(vim.api.nvim_replace_termcodes(keys, true, false, true))
  end, delay_ms or 60)
end

local floats_open = function()
  return #vim.tbl_filter(function(w)
    return vim.api.nvim_win_get_config(w).relative ~= ""
  end, vim.api.nvim_list_wins())
end

neogit.setup { filewatcher = { enabled = false }, disable_context_highlighting = true }

describe("confirm dialog", function()
  after_each(function()
    config.values.confirm.use_vim = false
    -- any dialog left open by a failed test would poison the next one
    if confirm_buffer.is_open() then
      press("<esc>", 0)
      vim.wait(200)
    end
  end)

  it("get_permission defaults to No; Enter submits the selection", function()
    press("<cr>")
    assert.is_false(input.get_permission("discard everything?"))
    assert.is_false(confirm_buffer.is_open())
    assert.equal(0, floats_open(), "dialog and backdrop must close")
  end)

  it("get_confirmation defaults to Yes", function()
    press("<cr>")
    assert.is_true(input.get_confirmation("save changes?"))
  end)

  it("Tab moves the selection and Enter submits it", function()
    press("<tab>", 60)
    press("<cr>", 160)
    assert.is_true(input.get_permission("danger?"))
  end)

  it("y jump-selects Yes and auto-commits after the delay", function()
    press("y")
    assert.is_true(input.get_permission("danger?"))
  end)

  it("Esc during the y delay window cancels instead of committing", function()
    press("y", 50)
    press("<esc>", 150)
    assert.is_false(input.get_permission("danger?"))
    assert.is_false(confirm_buffer.is_open())
  end)

  it("Tab invalidates a pending y commit", function()
    press("y", 50)
    press("<tab>", 150) -- pending Yes invalidated, selection toggles to No
    press("<cr>", 400) -- after the original 300ms window has passed
    assert.is_false(input.get_permission("danger?"))
  end)

  it("infers warning for permission prompts and info for confirmations", function()
    press("<cr>")
    input.get_permission("p")
    assert.equal("warning", confirm_buffer._state.last_level)

    press("<cr>", 200)
    input.get_confirmation("c")
    assert.equal("info", confirm_buffer._state.last_level)
  end)

  it("honors an explicit level override", function()
    press("<cr>")
    input.get_permission("p", { level = "danger" })
    assert.equal("danger", confirm_buffer._state.last_level)
  end)

  it("invalid level values fall back to inference", function()
    press("<cr>")
    input.get_permission("p", { level = "nonsense" })
    assert.equal("warning", confirm_buffer._state.last_level)
  end)

  it("confirm.use_vim routes to the fallback prompt", function()
    config.values.confirm.use_vim = true
    local calls = {}
    local original = input._vim_confirm
    input._vim_confirm = function(msg, values, default)
      table.insert(calls, { msg = msg, default = default })
      return false
    end

    assert.is_false(input.get_permission("via vim?"))
    input._vim_confirm = original

    assert.equal(1, #calls)
    assert.equal(2, calls[1].default)
  end)

  it("custom values route to the fallback prompt", function()
    local calls = {}
    local original = input._vim_confirm
    input._vim_confirm = function(msg, values, default)
      calls[1] = values
      return true
    end

    assert.is_true(input.get_permission("custom?", { values = { "&A", "&B" } }))
    input._vim_confirm = original

    assert.same({ "&A", "&B" }, calls[1])
    assert.is_false(confirm_buffer.is_open())
  end)

  it("reentrancy (dialog already open) routes to the fallback prompt", function()
    local original_is_open = confirm_buffer.is_open
    confirm_buffer.is_open = function()
      return true
    end
    local called = false
    local original = input._vim_confirm
    input._vim_confirm = function()
      called = true
      return false
    end

    assert.is_false(input.get_permission("nested?"))
    input._vim_confirm = original
    confirm_buffer.is_open = original_is_open

    assert.is_true(called)
  end)
end)
