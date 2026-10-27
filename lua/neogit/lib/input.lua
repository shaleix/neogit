local a = require("neogit.lib.async")
local config = require("neogit.config")
local confirm_buffer = require("neogit.buffers.confirm")
local input = a.wrap(vim.ui.input, 2)

local M = {}

-- Fallback path (vim's built-in prompt). Also a seam so tests can observe
-- when routing chose the fallback without opening vim.fn.confirm headless.
M._vim_confirm = function(msg, values, default)
  return vim.fn.confirm(msg, table.concat(values, "\n"), default) == 1
end

-- Shared yes/no implementation. Routes to the Confirm Dialog unless:
--   * confirm.use_vim is set (escape hatch back to vim's prompt),
--   * the caller customized the choices (only [y]es/[n]o are supported), or
--   * a dialog is already open (reentrancy - e.g. a refresh firing during
--     another dialog; nesting would steal its focus).
-- Level: explicit options.level wins; otherwise the default answer decides -
-- defaulting to No marks the action dangerous-ish (warning), defaulting to
-- Yes is informational (info).
---@param msg string
---@param options table|nil
---@param default integer 1 = Yes, 2 = No
---@return boolean
local function confirm(msg, options, default)
  options = options or {}
  default = options.default or default
  local values = options.values or { "&Yes", "&No" }

  local custom_values = #values ~= 2 or values[1] ~= "&Yes" or values[2] ~= "&No"
  local level = options.level
  if level ~= nil and not vim.tbl_contains({ "danger", "warning", "info" }, level) then
    level = nil
  end
  if level == nil then
    level = (default == 2) and "warning" or "info"
  end

  if config.values.confirm.use_vim or custom_values or confirm_buffer.is_open() then
    return M._vim_confirm(msg, values, default)
  end

  return confirm_buffer.open(msg, level, default == 1)
end

--- Provides the user with a confirmation
---@param msg string Prompt to use for confirmation
---@param options table|nil
---@return boolean Confirmation (Yes/No)
function M.get_confirmation(msg, options)
  return confirm(msg, options, 1)
end

--- Provides the user with a confirmation. Like get_confirmation, but defaults to false
---@param msg string Prompt to use for confirmation
---@param options table|nil
---@return boolean Confirmation (Yes/No)
function M.get_permission(msg, options)
  return confirm(msg, options, 2)
end

---@class UserChoiceOptions
---@field values table List of choices prefixed with '&'
---@field default integer Default choice to select

--- Provides the user with choices
---@param msg string Prompt to use for the choices
---@param options UserChoiceOptions
---@return string First letter of the selected choice
function M.get_choice(msg, options)
  local choice = vim.fn.confirm(msg, table.concat(options.values, "\n"), options.default)
  vim.cmd("redraw")

  if choice == 0 then -- User cancelled
    choice = options.default
  end

  return options.values[choice]:match("&(.)")
end

---@class GetUserInputOpts
---@field strip_spaces boolean? Replace spaces with dashes
---@field default any? Default value
---@field completion string?
---@field separator string?
---@field cancel string?
---@field prepend string?
---@field allow_empty boolean? Return "" instead of nil when the user submits an empty line

---@param prompt string Prompt to use for user input
---@param opts GetUserInputOpts? Options table
---@return string|nil
function M.get_user_input(prompt, opts)
  opts = vim.tbl_extend("keep", opts or {}, { strip_spaces = false, separator = ": " })

  if opts.prepend then
    vim.defer_fn(function()
      vim.api.nvim_input(opts.prepend)
    end, 10)
  end

  local status, result = pcall(input, {
    prompt = ("%s%s"):format(prompt, opts.separator),
    default = opts.default,
    completion = opts.completion,
    cancelreturn = opts.cancel,
  })

  if not status or not result then
    return nil
  end

  if opts.strip_spaces then
    result, _ = result:gsub("%s", "-")
  end

  if result == "" and not opts.allow_empty then
    return nil
  end

  return result
end

---Blocking variant to get user input. Needed for usernames/passwords during git interactions
---@param prompt string Prompt to use for user input
---@param opts GetUserInputOpts? Options table
---@return string|nil
function M.get_user_input_blocking(prompt, opts)
  opts = vim.tbl_extend("keep", opts or {}, { strip_spaces = false, separator = ": " })

  vim.fn.inputsave()

  if opts.prepend then
    vim.defer_fn(function()
      vim.api.nvim_input(opts.prepend)
    end, 10)
  end

  local status, result = pcall(vim.fn.input, {
    prompt = ("%s%s"):format(prompt, opts.separator),
    default = opts.default,
    completion = opts.completion,
    cancelreturn = opts.cancel,
  })

  vim.fn.inputrestore()
  if not status then
    return nil
  end

  if result == nil then
    return nil
  end

  if opts.strip_spaces then
    result, _ = result:gsub("%s", "-")
  end

  if result == "" then
    return nil
  end

  return result
end

---@param prompt string
---@param opts? table
---@return string|nil
function M.get_secret_user_input(prompt, opts)
  opts = vim.tbl_extend("keep", opts or {}, { separator = ": " })

  vim.fn.inputsave()
  local status, result = pcall(vim.fn.inputsecret, {
    prompt = ("%s%s"):format(prompt, opts.separator),
    cancelreturn = opts.cancel,
  })

  vim.fn.inputrestore()
  if not status then
    return nil
  end

  return result
end

return M
