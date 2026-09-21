local git = require("neogit.lib.git")
local logger = require("neogit.logger")
local backend = require("neogit.lib.git.backend")

---@class NeogitGitConfig
local M = {}

---@class ConfigEntry
---@field value string
---@field name string
---@field scope string Global/System/Local
local ConfigEntry = {}
ConfigEntry.__index = ConfigEntry

---@param name string
---@return ConfigEntry
function ConfigEntry.new(name, value, scope)
  return setmetatable({
    name = name,
    value = value or "",
    scope = scope,
  }, ConfigEntry)
end

---@return string
function ConfigEntry:type()
  if self.value == "true" or self.value == "false" then
    return "boolean"
  elseif tonumber(self.value) then
    return "number"
  else
    return "string"
  end
end

---@return boolean
function ConfigEntry:is_set()
  return self.value ~= ""
end

---@return boolean
function ConfigEntry:is_unset()
  return not self:is_set()
end

---@return boolean|number|string|nil
function ConfigEntry:read()
  if self:is_unset() then
    return nil
  end

  if self:type() == "boolean" then
    return self.value == "true"
  elseif self:type() == "number" then
    return tonumber(self.value)
  else
    return self.value
  end
end

---@return nil
function ConfigEntry:update(value)
  if not value or value == "" then
    if self:is_set() then
      M.unset(self.name)
    end
  else
    M.set(self.name, value)
  end
end

---@return self
function ConfigEntry:refresh()
  if self.scope == "local" then
    self.value = M.get_local(self.name).value
  elseif self.scope == "global" then
    self.value = M.get_global(self.name).value
  end

  return self
end

---@type table<string, ConfigEntry>
local config_cache = {}
local cache_key = nil

local function make_cache_key()
  local stat = vim.uv.fs_stat(git.repo:git_path("config"):absolute())
  if stat then
    return stat.mtime.sec
  end
end

local function build_config()
  local result = {}

  if backend.capability("query_config_build") == "libgit2" then
    local entries = require("neogit.lib.git.libgit2.config").local_entries()
    if entries then
      for key, value in pairs(entries) do
        result[key] = ConfigEntry.new(key, value, "local")
      end
      return result
    end
    -- else: fall through to the CLI path
  end

  local out = vim.split(
    table.concat(git.cli.config.list.null._local.call({ hidden = true, remove_ansi = false }).stdout, "\0"),
    "\n"
  )
  for _, option in ipairs(out) do
    local key, value = unpack(vim.split(option, "\0"))

    if key ~= "" then
      result[key] = ConfigEntry.new(key, value, "local")
    end
  end

  return result
end

local function config()
  if not cache_key or cache_key ~= make_cache_key() then
    logger.debug("[Config] Rebuilding git config_cache")
    cache_key = make_cache_key()
    config_cache = build_config()
  end

  return config_cache
end

---@return ConfigEntry
function M.get(key)
  if M.get_local(key):is_set() then
    return M.get_local(key)
  elseif M.get_global(key):is_set() then
    return M.get_global(key)
  else
    return ConfigEntry.new(key, "", "local")
  end
end

---@return ConfigEntry
function M.get_global(key)
  if backend.capability("query_config_global") == "libgit2" then
    local libgit2_config = require("neogit.lib.git.libgit2.config")
    -- CLI semantics: `git config --get` reads the MERGED config (local wins),
    -- so mirror that rather than a global-only lookup.
    local value = libgit2_config.merged_get(key)
    if value == nil then
      value = libgit2_config.global_get(key)
    end
    return ConfigEntry.new(key, value, "global")
  end

  local result = git.cli.config.get(key).call({ ignore_error = true }).stdout[1]
  return ConfigEntry.new(key, result, "global")
end

---@return ConfigEntry
function M.get_local(key)
  return config()[key:lower()] or ConfigEntry.new(key, "", "local")
end

function M.get_matching(pattern)
  local matches = {}
  for key, value in pairs(config()) do
    if key:match(pattern) then
      matches[key] = value
    end
  end

  return matches
end

---Returns all values set for a multi-valued key (e.g. remote.<name>.fetch).
---@param key string
---@return string[]
function M.get_all_values(key)
  return git.cli.config.get_all(key).call({ ignore_error = true }).stdout
end

function M.set(key, value)
  cache_key = nil

  if not value or value == "" then
    M.unset(key)
  else
    git.cli.config.set(key, value).call()
  end
end

function M.unset(key)
  -- Unsetting a value that isn't set results in an error.
  if not M.get(key):is_set() then
    return
  end

  cache_key = nil
  git.cli.config.unset(key).call { ignore_error = true }
end

return M
