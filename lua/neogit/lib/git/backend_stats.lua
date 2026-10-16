-- Backend usage statistics: which operations were served by libgit2 twins,
-- which fell back to (or were routed straight to) the git CLI.
--
-- Three recording seams cover every routing decision:
--   * query twins    - libgit2/init.lua M.twin(): served / fallback / skipped
--   * update twins   - repository.lua task pick: libgit2 twin vs CLI task
--   * CLI spawns     - process.lua: every spawned git process (coarse)
--
-- Counting is in-memory and cheap (table increments, capped event ring);
-- nothing is written to disk. Enable NEOGIT_LOG_LEVEL=trace for the
-- pre-existing verbose process log if you need a persistent audit trail.

local M = {}

---@class BackendStatsEntry
---@field libgit2 integer queries/update tasks served by a twin
---@field cli integer queries that fell back + update tasks routed to CLI
---@field skipped integer queries never offered to a twin (capability/backend off)
---@field failed integer twin raised; counted under cli as well

---Counters per seam. `queries` maps "module.fn" -> BackendStatsEntry,
---`updates` maps the refresh task name -> libgit2/cli run counts, and
---`spawns` maps "git <subcommand>" -> process count.
M.counters = {
  queries = {},
  updates = {},
  spawns = {},
}

local events = {}
local MAX_EVENTS = 200

local function now_ms()
  return vim.uv.now()
end

local function push_event(kind, op, outcome)
  events[#events + 1] = { t = now_ms(), kind = kind, op = op, outcome = outcome }
  if #events > MAX_EVENTS then
    table.remove(events, 1)
  end
end

local function q_entry(op)
  local e = M.counters.queries[op]
  if not e then
    e = { libgit2 = 0, cli = 0, skipped = 0, failed = 0 }
    M.counters.queries[op] = e
  end
  return e
end

---Record one query-twin dispatch outcome.
---@param op string "module.fn", e.g. "branch.current"
---@param outcome "libgit2"|"cli"|"skipped"|"failed"
function M.record_query(op, outcome)
  local e = q_entry(op)
  if outcome == "libgit2" then
    e.libgit2 = e.libgit2 + 1
  elseif outcome == "failed" then
    e.failed = e.failed + 1
    e.cli = e.cli + 1
  elseif outcome == "skipped" then
    e.skipped = e.skipped + 1
  else
    e.cli = e.cli + 1
  end
  push_event("query", op, outcome)
end

---Record which implementation an update task ran on.
---@param task string task name, e.g. "update_status"
---@param used_libgit2 boolean
function M.record_update(task, used_libgit2)
  local e = M.counters.updates[task]
  if not e then
    e = { libgit2 = 0, cli = 0 }
    M.counters.updates[task] = e
  end
  if used_libgit2 then
    e.libgit2 = e.libgit2 + 1
  else
    e.cli = e.cli + 1
  end
  push_event("update", task, used_libgit2 and "libgit2" or "cli")
end

local VALUE_FLAGS =
  { ["-c"] = true, ["-C"] = true, ["--git-dir"] = true, ["--work-tree"] = true, ["--namespace"] = true }

---Record one spawned git CLI process (coarse: "git <subcommand>", skipping
---global flags and their values (--no-pager, -c <cfg>, ...) so the key
---names the actual operation).
---@param cmd string[] full argv
function M.record_spawn(cmd)
  if not cmd or cmd[1] == nil then
    return
  end

  local sub = ""
  local i = 2
  while i <= #cmd do
    local tok = cmd[i]
    if VALUE_FLAGS[tok] then
      i = i + 2 -- flag plus its value
    elseif tok:sub(1, 1) ~= "-" and tok ~= "" then
      sub = " " .. tok
      break
    else
      i = i + 1
    end
  end

  local key = cmd[1] .. sub
  M.counters.spawns[key] = (M.counters.spawns[key] or 0) + 1
  push_event("spawn", key, "cli")
end

---Reset all counters and the event ring.
function M.reset()
  M.counters = { queries = {}, updates = {}, spawns = {} }
  events = {}
end

---@param t table
---@return string[] keys sorted by total count, descending
local function sorted_by_total(t)
  local keys = vim.tbl_keys(t)
  table.sort(keys, function(a, b)
    local ta, tb = t[a], t[b]
    local sa = (ta.libgit2 or 0) + (ta.cli or 0) + (ta.skipped or 0) + (ta.failed or 0)
    local sb = (tb.libgit2 or 0) + (tb.cli or 0) + (tb.skipped or 0) + (tb.failed or 0)
    if sa == sb then
      return tostring(a) < tostring(b)
    end
    return sa > sb
  end)
  return keys
end

---Aggregated, human-readable report of backend usage since load/reset.
---@return string
function M.report()
  local lines = {
    "=== neogit backend usage (since load / last reset) ===",
    "",
    "query twins (dispatcher outcomes):",
    string.format("  %-34s %9s %9s %9s %9s", "operation", "libgit2", "cli", "skipped", "failed"),
  }

  local qkeys = sorted_by_total(M.counters.queries)
  if #qkeys == 0 then
    table.insert(lines, "  (none recorded)")
  end
  for _, op in ipairs(qkeys) do
    local e = M.counters.queries[op]
    table.insert(lines, string.format("  %-34s %9d %9d %9d %9d", op, e.libgit2, e.cli, e.skipped, e.failed))
  end

  table.insert(lines, "")
  table.insert(lines, "update tasks (refresh waves):")
  table.insert(lines, string.format("  %-34s %9s %9s", "task", "libgit2", "cli"))
  local ukeys = sorted_by_total(M.counters.updates)
  if #ukeys == 0 then
    table.insert(lines, "  (none recorded)")
  end
  for _, task in ipairs(ukeys) do
    local e = M.counters.updates[task]
    table.insert(lines, string.format("  %-34s %9d %9d", task, e.libgit2, e.cli))
  end

  table.insert(lines, "")
  table.insert(lines, "cli spawns (process level, includes fallbacks):")
  local skeys = vim.tbl_keys(M.counters.spawns)
  table.sort(skeys, function(a, b)
    local ca, cb = M.counters.spawns[a], M.counters.spawns[b]
    if ca == cb then
      return tostring(a) < tostring(b)
    end
    return ca > cb
  end)
  if #skeys == 0 then
    table.insert(lines, "  (none recorded)")
  end
  for _, key in ipairs(skeys) do
    table.insert(lines, string.format("  %-44s %9d", key, M.counters.spawns[key]))
  end

  return table.concat(lines, "\n")
end

---Most recent routing decisions, newest last.
---@param n? integer
---@return table[]
function M.last(n)
  n = n or 50
  local from = math.max(1, #events - n + 1)
  local out = {}
  for i = from, #events do
    out[#out + 1] = events[i]
  end
  return out
end

return M
