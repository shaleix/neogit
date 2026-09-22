local M = {}
local config = require("neogit.config")

---@param message string  message to send
---@param level   integer vim.log.levels.X
---@param opts    table
local function create(message, level, opts)
  if opts.dismiss then
    M.delete_all()
  end

  vim.schedule(function()
    vim.notify(message, level, { title = "Neogit", icon = config.values.notification_icon })
  end)
end

---@param message string  message to send
---@param opts    table?
function M.error(message, opts)
  create(message, vim.log.levels.ERROR, opts or {})
end

---@param message string  message to send
---@param opts    table?
function M.info(message, opts)
  create(message, vim.log.levels.INFO, opts or {})
end

---@param message string  message to send
---@param opts    table?
function M.warn(message, opts)
  create(message, vim.log.levels.WARN, opts or {})
end

---@param message string  message to send
---@param opts    table?
function M.debug(message, opts)
  create(message, vim.log.levels.DEBUG, opts or {})
end

function M.delete_all()
  if type(vim.notify) == "table" and vim.notify.dismiss then
    vim.notify.dismiss()
  end
end

-- Spinner frames for progress notifications (braille spinner).
local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- Only vim.notify implementations with verified in-place replacement
-- (`opts.replace` honoring record ids) may animate. Returning an id is NOT
-- proof: noice.nvim, for one, returns `{ id = ... }` from every call while
-- ignoring `replace`, so per-frame updates would spam one notification per
-- frame. Unknown implementations get one static notification + the final
-- state instead.
local function replace_capable()
  local ok, notify_plugin = pcall(require, "notify") -- nvim-notify
  return ok
    and type(notify_plugin) == "table"
    and (vim.notify == notify_plugin or vim.notify == notify_plugin.notify)
end

---@class NotificationProgress
---@field message string current text
---@field level integer current level
---@field id? number|table notification record id, when the active vim.notify supports replacement
---@field frame number current spinner frame index
---@field timer? table uv timer animating the spinner
---@field closed boolean
local Progress = {}
Progress.__index = Progress

local function progress_notify(self, icon)
  local id = vim.notify(self.message, self.level, {
    title = "Neogit",
    icon = icon,
    replace = self.id,
  })

  -- vim.notify implementations that support in-place updates (nvim-notify,
  -- snacks.nvim, ...) return a record id; the built-in one returns nil and
  -- ignores `replace`. Keep whatever we get so updates degrade gracefully.
  if id ~= nil then
    self.id = id
  end

  return id ~= nil
end

function Progress:update(message, level)
  if self.closed then
    return
  end

  self.message = message or self.message
  self.level = level or self.level

  vim.schedule(function()
    -- Without replace support, only the first frame may notify; later
    -- intermediate updates stay silent to avoid notification spam.
    if self.id == nil and self.notified then
      return
    end
    self.notified = true
    progress_notify(self, SPINNER_FRAMES[(self.frame % #SPINNER_FRAMES) + 1])
  end)
end

---Settle the notification into its final state (color follows `level`) and
---stop the spinner. The notification closes via the backend's own timeout.
---@param message string final text
---@param level integer vim.log.levels.INFO on success, WARN/ERROR on failure
function Progress:done(message, level)
  if self.closed then
    return
  end
  self.closed = true

  if self.timer then
    self.timer:close()
    self.timer = nil
  end

  self.message = message or self.message
  self.level = level or self.level

  vim.schedule(function()
    -- Even without replace support the final state deserves a notification.
    progress_notify(self, config.values.notification_icon)
  end)
end

---Create a progress notification: a single notification animated with a
---spinner while work is running, settled in place by `:done(message, level)`
---when the outcome is known. Requires a replace-capable vim.notify
---(nvim-notify) for the in-place behavior; other implementations (built-in,
---noice, ...) get one static "loading" notification plus the final state.
---@param message string
---@return NotificationProgress
function M.progress(message)
  local self = setmetatable({
    message = message,
    level = vim.log.levels.INFO,
    frame = 0,
    closed = false,
    animated = false,
  }, Progress)

  -- First frame goes out immediately, animation only when replacement works.
  self:update()
  if M.internal.replace_capable() then
    self.animated = true
    self.timer = vim.uv.new_timer()
    self.timer:start(90, 90, vim.schedule_wrap(function()
      if self.closed then
        return
      end
      self.frame = self.frame + 1
      self:update()
    end))
  end

  return self
end

-- Test seams; not public API.
M.internal = {
  replace_capable = replace_capable,
}

return M
