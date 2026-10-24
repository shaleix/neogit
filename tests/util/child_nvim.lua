-- E2E harness: drives a real headless Neovim child process over RPC.
-- Lua port of spec/support/neovim_client.rb (the rspec E2E suite).
--
-- Mechanism notes (validated against the ruby client on nvim 0.12):
--   - The child is spawned with `--embed --clean --headless`; no
--     `nvim_ui_attach` is needed: a `:redraw` paints the internal grid,
--     which `screenstring()` then reads back cell by cell.
--   - `keys()` feeds one `nvim_input()` per key, reassembling `<...>`
--     sequences, and waits ~100ms between keys (rspec timing).
--   - Row conventions are ported verbatim from the ruby harness:
--     `screen()` returns 1-based rows, but `move_to_line()` targets
--     `row - 1` in buffer coordinates (the ruby `each_with_index`
--     0-based quirk), and spec expectations that read `nvim.screen[n]`
--     in rspec must use row `n + 1` here.
local util = require("tests.util.util")

local ChildNvim = {}
ChildNvim.__index = ChildNvim

local function child_command()
  return { "nvim", "--embed", "--clean", "--headless" }
end

local function runtime_dependency_dirs()
  local deps = {}
  local tmp = util.project_dir .. "/tmp"
  assert(vim.fn.isdirectory(tmp) == 1, "missing tmp/ runtime dependencies")
  for _, name in ipairs(vim.fn.readdir(tmp)) do
    local path = tmp .. "/" .. name
    if vim.fn.isdirectory(path) == 1 then
      deps[#deps + 1] = path
    end
  end
  assert(
    #deps > 0,
    "no runtime dependencies under tmp/ - clone plenary/telescope/diffview first (see .github/workflows/test.yml)"
  )
  return deps
end

function ChildNvim.new()
  return setmetatable({ chan = nil, debug = os.getenv("NEOGIT_E2E_PRINT") ~= nil }, ChildNvim)
end

---Spawn the child, wire runtimepath + neogit, and open the status buffer.
---@param workdir string cwd for the child (a git repository)
---@param config table? neogit config table (rspec passes a Lua snippet)
function ChildNvim:setup(workdir, config)
  config = config or {}

  -- rspec parity: context/nvim.rb injects the CI backend selector.
  local backend = os.getenv("NEOGIT_GIT_BACKEND")
  if backend and config.git_backend == nil then
    config.git_backend = backend
  end

  self.chan = vim.fn.jobstart(child_command(), { rpc = true, cwd = workdir })
  assert(self.chan and self.chan > 0, "failed to spawn child nvim")

  for _, dep in ipairs(runtime_dependency_dirs()) do
    self:lua(("vim.opt.runtimepath:prepend('%s')"):format(dep))
  end
  self:lua(("vim.opt.runtimepath:prepend('%s')"):format(util.project_dir))

  self:exec_lua(
    [[
      local config = ...
      require("plenary")
      require("diffview").setup()
      require("neogit").setup(config)
      require("neogit").open()
    ]],
    config
  )

  vim.wait(100) -- "Seems to be about right" (rspec)
  self:assert_alive()

  return self
end

function ChildNvim:teardown()
  if self.chan then
    pcall(vim.fn.rpcrequest, self.chan, "nvim_command", "qa!")
    vim.fn.jobwait({ self.chan }, 2000)
    pcall(vim.fn.jobstop, self.chan)
    self.chan = nil
  end
end

-- rpc wrappers ---------------------------------------------------------------

function ChildNvim:exec_lua(code, arg)
  return vim.fn.rpcrequest(self.chan, "nvim_exec_lua", code, { arg or {} })
end

function ChildNvim:lua(code)
  return self:exec_lua(code)
end

function ChildNvim:fn(function_name, args)
  return vim.fn.rpcrequest(self.chan, "nvim_call_function", function_name, args or {})
end

function ChildNvim:eval(expr)
  return vim.fn.rpcrequest(self.chan, "nvim_eval", expr)
end

function ChildNvim:cmd(command)
  local output = vim.fn.rpcrequest(self.chan, "nvim_command_output", command)
  return vim.split(output, "\n", { plain = true })
end

-- harness operations ---------------------------------------------------------

function ChildNvim:refresh()
  self:lua("require('neogit.buffers.status').instance():dispatch_refresh()")
  -- rspec parity: dispatch_refresh is async/debounced, and the ruby
  -- harness's slow per-cell screen capture gave it ~200ms to settle
  -- before the next interaction. Make that delay explicit here.
  vim.wait(250)
end

---Capture the painted grid. One round-trip (rspec issues one screenstring
---rpc per cell; same result).
function ChildNvim:screen()
  return self:exec_lua([[
    vim.cmd("redraw")
    local rows = {}
    for line = 1, vim.o.lines do
      local cells = {}
      for column = 1, vim.o.columns do
        cells[column] = vim.fn.screenstring(line, column)
      end
      rows[line] = table.concat(cells)
    end
    return rows
  ]])
end

function ChildNvim:print_screen()
  print(("CURSOR %d,%d"):format(self:fn("screenrow", {}), self:fn("screencol", {})))
  for i, line in ipairs(self:screen()) do
    print(("%2d|%s"):format(i, line))
  end
end

---Move the cursor to the screen line containing `line` (optionally only
---after a line containing `after`). Ports the ruby 0-based cursor quirk,
---which lands on buffer line `screen_row - 1` (exactly right on this
---fork, where the banner occupies the first screen row). Retries the
---scan briefly when nothing matches, standing in for the settle time
---the slow ruby screen capture provided.
function ChildNvim:move_to_line(line, after)
  if type(line) == "number" then
    self:lua(("vim.api.nvim_win_set_cursor(0, {%d, 0})"):format(line))
    return
  end

  for _ = 1, 5 do
    local preceding_found = after == nil
    for idx, content in ipairs(self:screen()) do
      if not preceding_found and content:find(after, 1, true) then
        preceding_found = true
      end
      if preceding_found and content:find(line, 1, true) then
        self:lua(("vim.api.nvim_win_set_cursor(0, {%d, 0})"):format(idx - 1))
        return
      end
    end
    vim.wait(100)
  end
end

function ChildNvim:errors()
  local found = {}
  for _, line in ipairs(self:cmd("messages")) do
    if line:match("^E%d+: ") or line:find("The coroutine failed with this message", 1, true) then
      found[#found + 1] = vim.trim(line)
    end
  end
  return found
end

function ChildNvim:filetype()
  return self:eval("&filetype")
end

function ChildNvim:assert_alive()
  if self:eval("1 + 2") ~= 3 then
    error("Neovim instance is not alive!")
  end
end

---Stub vim.fn.input to return queued answers instead of blocking.
function ChildNvim:input(...)
  self:exec_lua(
    [[
      local inputs = ...
      vim.fn.input = function()
        return table.remove(inputs, 1)
      end
    ]],
    { ... }
  )
end

function ChildNvim:confirm(state)
  self:exec_lua(("vim.fn.confirm = function() return %d end"):format(state and 1 or 0))
end

---Feed keys, one nvim_input() call per key, `<...>` sequences kept whole.
function ChildNvim:keys(keys)
  local i = 1
  while i <= #keys do
    local key = keys:sub(i, i)
    i = i + 1
    if key == "<" then
      while i <= #keys and key:sub(-1) ~= ">" do
        key = key .. keys:sub(i, i)
        i = i + 1
      end
    end

    local ok, consumed = pcall(vim.fn.rpcrequest, self.chan, "nvim_input", key)
    if not ok or consumed == nil then
      self:assert_alive()
      error("failed to write key to neovim: " .. key)
    end

    if self.debug then
      self:print_screen()
    end
    vim.wait(100)
  end
end

return ChildNvim
