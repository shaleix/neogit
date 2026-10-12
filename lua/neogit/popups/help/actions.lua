local M = {}

local util = require("neogit.lib.util")
local NONE = function() end

local status_mappings = require("neogit.config").get_reversed_status_maps()
local popup_mappings = require("neogit.config").get_reversed_popup_maps()

local function present(commands)
  local presenter = util.map(commands, function(command)
    local cmd, name, fn = unpack(command)

    --- Handle the longer table mapping form (mode, func, esc)
    if type(fn) == "table" then
      fn = fn[2]
    end

    local keymap = status_mappings[cmd]
    if not keymap or keymap == "<nop>" then
      keymap = popup_mappings[cmd]
    end

    if type(keymap) == "table" and next(keymap) then
      -- HACK: Remove "za" as listed keymap for toggle action.
      table.sort(keymap)
      if name == "Toggle" and keymap[2] == "za" then
        table.remove(keymap, 2)
      end

      return { { name = name, keys = keymap, cmp = table.concat(keymap):lower(), fn = fn } }
    else
      return { { name = name, keys = {}, cmp = "", fn = fn } }
    end
  end)

  presenter = util.flatten(presenter)

  table.sort(presenter, function(a, b)
    return a.cmp < b.cmp
  end)

  return presenter
end

M.popups = function(env)
  local popups = require("neogit.popups")
  local status_actions = require("neogit.buffers.status.actions")
  local items = {
    {
      "CommandHistory",
      "History",
      function()
        require("neogit.buffers.git_command_history"):new():show()
      end,
    },
    { "InitRepo", "Init", require("neogit.lib.git").init.init_repo },
  }

  -- Popup entries are generated from the shared spec table in
  -- buffers/status/actions.lua: a row with a label lists its popup (in the
  -- table's first-appearance order), so the help popup and the status buffer
  -- can never disagree about which popups exist.
  for _, spec in ipairs(status_actions.popup_specs) do
    if spec.label then
      table.insert(items, {
        status_actions.command_name(spec.name),
        spec.label,
        popups.open(spec.name, function(p)
          p(env[spec.name])
        end),
      })
    end
  end

  table.insert(items, { "Command", "Command", status_actions.n_command(nil) })

  return present(items)
end

M.actions = function()
  return present {
    { "Stage", "Stage", NONE },
    { "StageUnstaged", "Stage unstaged", NONE },
    { "StageAll", "Stage all", NONE },
    { "Unstage", "Unstage", NONE },
    { "UnstageStaged", "Unstage all", NONE },
    { "Discard", "Discard", NONE },
    { "Untrack", "Untrack", NONE },
  }
end

M.essential = function()
  return present {
    {
      "RefreshBuffer",
      "Refresh",
      function()
        local status = require("neogit.buffers.status")
        if status.is_open() then
          status.instance():dispatch_refresh(nil, "user_refresh")
        end
      end,
    },
    { "GoToFile", "Go to file", NONE },
    { "Toggle", "Toggle", NONE },
  }
end

return M
