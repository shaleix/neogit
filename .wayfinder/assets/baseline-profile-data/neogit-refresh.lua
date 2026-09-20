-- headless 驱动:测量 neogit status buffer 完整 refresh(cold/warm)与 lib-only refresh
-- 用法:OUT=/path/to/result.txt GIT_PROBE_LOG=/path/to/probe.log nvim --clean --headless -u minimal.lua -l neogit-refresh.lua
-- (以 -s 或 -l 方式执行均可;脚本自带 vim.schedule + qa!)
local REPO = "/tmp/opencode/stress-repo"
local OUT = assert(os.getenv("OUT"), "OUT env required")

local fh = io.open(OUT, "a")

local function out(line)
  fh:write(line, "\n")
  fh:flush()
end

local function ms(a, b)
  return (b - a) / 1e6
end

vim.cmd.cd(REPO)

local neogit = require("neogit")
neogit.setup({
  git_executable = "/tmp/opencode/git-probe",
  filewatcher = { enabled = false },
  disable_context_highlighting = true,
  auto_refresh = false,
})

local runner = require("neogit.runner")
local status = require("neogit.buffers.status")
local repo_mod = require("neogit.lib.git.repository")

out(("nvim_version\t%s"):format(vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch))

local function dump_procs(tag, from, to)
  out(("%s_spawn_count\t%d"):format(tag, to - from))
  for i = from + 1, to do
    local r = runner.history[i]
    if r then
      out(("%s_proc\t%.4f\t%s"):format(tag, r.time or -1, r.cmd or "?"))
    end
  end
end

local function wait_event(pattern, timeout)
  local done = false
  vim.api.nvim_create_autocmd("User", {
    pattern = pattern,
    once = true,
    callback = function()
      done = true
    end,
  })
  local ok = vim.wait(timeout or 60000, function()
    return done
  end, 20)
  return done, ok
end

vim.schedule(function()
  -- Phase 1: 冷启动(打开 status buffer,含 Repo.instance 的首次 refresh 被取消的噪声)
  local h0 = #runner.history
  local t0 = vim.uv.hrtime()
  neogit.open({ kind = "split" })
  local done1 = wait_event("NeogitStatusRefreshed")
  local t1 = vim.uv.hrtime()
  out(("cold_full_ms\t%.3f"):format(ms(t0, t1)))
  out(("cold_event_fired\t%s"):format(tostring(done1)))
  dump_procs("cold", h0, #runner.history)

  -- Phase 2: 热刷新(status buffer 完整链路,含 UI redraw)
  local h1 = #runner.history
  local t2 = vim.uv.hrtime()
  status.instance():refresh(nil, "bench-warm")
  local done2 = wait_event("NeogitStatusRefreshed")
  local t3 = vim.uv.hrtime()
  out(("warm_full_ms\t%.3f"):format(ms(t2, t3)))
  out(("warm_event_fired\t%s"):format(tostring(done2)))
  dump_procs("warm", h1, #runner.history)

  -- Phase 3: 纯 lib 层 refresh(无 UI redraw)
  local h2 = #runner.history
  local libdone = false
  local t4 = vim.uv.hrtime()
  repo_mod.instance():refresh({ source = "bench-lib", callback = function()
    libdone = true
  end })
  vim.wait(60000, function()
    return libdone
  end, 20)
  local t5 = vim.uv.hrtime()
  out(("lib_only_ms\t%.3f"):format(ms(t4, t5)))
  out(("lib_done\t%s"):format(tostring(libdone)))
  dump_procs("lib", h2, #runner.history)

  -- 状态规模 sanity check
  local st = repo_mod.instance().state
  out(("state_unstaged\t%d"):format(#st.unstaged.items))
  out(("state_staged\t%d"):format(#st.staged.items))
  out(("state_untracked\t%d"):format(#st.untracked.items))
  out(("state_recent\t%d"):format(#st.recent.items))

  fh:close()
  vim.cmd("qa!")
end)
