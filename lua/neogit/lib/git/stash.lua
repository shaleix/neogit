local git = require("neogit.lib.git")
local input = require("neogit.lib.input")
local util = require("neogit.lib.util")
local config = require("neogit.config")
local event = require("neogit.lib.event")
local libgit2 = require("neogit.lib.git.libgit2")

---@class NeogitGitStash
local M = {}

function M.list_refs()
  local result = git.cli.reflog.show.format("%h").args("stash").call { ignore_error = true }
  if result:failure() then
    return {}
  else
    return result.stdout
  end
end

---@param args string[]
function M.stash_all(args)
  local result = git.cli.stash.push.files(".").arg_list(args).call()
  event.send("Stash", { success = result:success() })
end

function M.stash_index()
  local result = git.cli.stash.staged.call()
  event.send("Stash", { success = result:success() })
end

function M.stash_keep_index()
  local result = git.cli.stash.keep_index.files(".").call()
  event.send("Stash", { success = result:success() })
end

---@param args string[]
---@param files string[]
function M.push(args, files)
  local result = git.cli.stash.push.arg_list(args).files(unpack(files)).call()
  event.send("Stash", { success = result:success() })
end

function M.pop(stash)
  local result = git.cli.stash.apply.index.args(stash).call()

  if result:success() then
    git.cli.stash.drop.args(stash).call()
  else
    git.cli.stash.apply.args(stash).call()
  end

  event.send("Stash", { success = result:success() })
end

function M.apply(stash)
  local result = git.cli.stash.apply.index.args(stash).call()

  if result:failure() then
    git.cli.stash.apply.args(stash).call()
  end

  event.send("Stash", { success = result:success() })
end

function M.drop(stash)
  local result = git.cli.stash.drop.args(stash).call()
  event.send("Stash", { success = result:success() })
end

function M.list()
  local result, served = libgit2.twin("query_stash_list", "stash", "list", "warn")
  if served then
    return result
  end

  return git.cli.stash.args("list").call({ hidden = true }).stdout
end

function M.rename(stash)
  local current = git.log.message(stash)
  local message = input.get_user_input("rename", { prepend = current })
  if message then
    local oid = git.rev_parse.oid(stash)
    -- Resolve BEFORE the destructive drop and refuse to proceed without a
    -- valid oid: dropping first and failing in `stash store` afterwards
    -- would silently lose the stash.
    assert(oid and oid ~= "", ("could not resolve %s - refusing to drop it"):format(tostring(stash)))
    git.cli.stash.drop.args(stash).call()
    git.cli.stash.store.message(message).args(oid).call()
  end
end

---@class StashItem
---@field idx number string the id of the stash i.e. stash@{7}
---@field name string
---@field date string timestamp
---@field rel_date string relative timestamp
---@field message string the message associated with each stash.

function M.register(meta)
  ---Parse one `git stash list --format=%gd%x1f%H%x1f%gs` line into a stash
  ---entry (single spawn for the whole list).
  local function parse_stash_line(line)
    local ref, oid, message = line:match("stash@{(%-?%d*)}\x1f([0-9a-f]+)\x1f(.*)")
    local idx = tonumber(ref)
    if not idx or not oid or not message then
      return nil
    end

    return {
      idx = idx,
      message = message,
      oid = oid,
      name = ("stash@{%d}: %s"):format(idx, message),
    }
  end

  meta.update_stashes = function(state)
    -- libgit2 twin: one foreach, oids included at no extra cost
    local entries, served = libgit2.twin("query_stash_list", "stash", "list_detailed", "warn")

    if not served then
      -- CLI fallback: ONE spawn resolves index, oid and subject together
      local lines = git.cli.stash.args("list", "--format=%gd%x1f%H%x1f%gs").call({ hidden = true }).stdout
      entries = util.filter_map(lines, parse_stash_line)
    end

    state.stashes.items = util.map(entries, function(entry)
      ---@class StashItem
      local item = {
        idx = entry.idx,
        name = entry.name,
        message = entry.message,
        oid = entry.oid, -- concrete: rendering yankables must not spawn
      }

      -- Display-only extras stay lazy (each costs a git call, the status
      -- view never touches them).
      setmetatable(item, {
        __index = function(self, key)
          if key == "rel_date" then
            self.rel_date = git.cli.log
              .max_count(1)
              .format("%cr")
              .args(("stash@{%s}"):format(entry.idx))
              .call({ hidden = true }).stdout[1]

            return self.rel_date
          elseif key == "date" then
            self.date = git.cli.log
              .max_count(1)
              .format("%cd")
              .args("--date=format:" .. config.values.log_date_format)
              .args(("stash@{%s}"):format(entry.idx))
              .call({ hidden = true }).stdout[1]

            return self.date
          end
        end,
      })

      return item
    end)
  end
end

return M
