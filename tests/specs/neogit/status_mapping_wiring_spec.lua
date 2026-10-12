-- Cross-checks the DEFAULT status mappings (config.get_default_values) against
-- the keymaps the status buffer actually wires (the mappings["CommandName"]
-- entries bound to self:_action(...) tables in buffers/status/init.lua).
--
-- Every default status command must be wired, or listed in `known_unwired`
-- with a reason - anything else is drift and fails the suite. The exception
-- list is checked in both directions: an entry whose command gets wired (or
-- that stops being a default command) fails the suite too, so entries get
-- deleted when their wiring lands and the list can't rot.
local Path = require("neogit.lib.path")
local config = require("neogit.config")

---Command names wired in the status buffer's mapping tables. Popup launches
---use popups.mapping_for(...) and raw literals ("V", "<C-d>", "<C-u>") don't
---route through the status maps, so neither matches this extraction.
local function wired_commands()
  local source = Path.new(vim.uv.cwd(), "lua", "neogit", "buffers", "status", "init.lua")
  local wired = {}

  for line in source:iter() do
    for name in line:gmatch('mappings%["([%w_]+)"%]') do
      wired[name] = true
    end
  end

  return wired
end

---Default status commands that have no wiring in the status buffer yet.
---Every entry needs a reason; entries are removed as their wiring lands.
local known_unwired = {
  PeekFile = "does not map to status rows: the views' PeekFile opens a commit view and refocuses the list, but status file rows open editor windows after closing the status buffer itself, so there is no list left to refocus",
}

local function is_default(defaults, command)
  for _, name in pairs(defaults) do
    if name == command then
      return true
    end
  end

  return false
end

describe("status mapping wiring", function()
  local defaults = config.get_default_values().mappings.status
  local wired = wired_commands()

  it("wires every default status command or lists it in known_unwired", function()
    local drift = {}

    for _, command in pairs(defaults) do
      if not wired[command] and not known_unwired[command] then
        table.insert(drift, command)
      end
    end

    table.sort(drift)
    assert.equal(0, #drift, "unwired default status commands: " .. table.concat(drift, ", "))
  end)

  it("keeps known_unwired exact: every entry is unwired and still a default", function()
    for command, reason in pairs(known_unwired) do
      assert.is_string(reason, "known_unwired." .. command .. " needs a reason")
      assert.is_nil(wired[command], command .. " is now wired - delete its known_unwired entry")
      assert.True(is_default(defaults, command), command .. " is no longer a default status command")
    end
  end)

  it("never wires command names outside the default status maps", function()
    for command in pairs(wired) do
      assert.True(is_default(defaults, command), command .. " is wired but not a default status command")
    end
  end)
end)
