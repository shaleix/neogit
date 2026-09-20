-- 解析微基准:分离 "CLI spawn 耗时" 与 "Lua 解析耗时"
-- 用法:OUT=... nvim --clean --headless -u minimal.lua -l parse-bench.lua
local REPO = "/tmp/opencode/stress-repo"
local OUT = assert(os.getenv("OUT"), "OUT env required")
local fh = io.open(OUT, "a")
local function out(line)
  fh:write(line, "\n")
end

local LOGFMT = "sanitized_subject_line%x1D%f%x1Fparent%x1F%P%x1Fauthor_date%x1D%aD%x1Fcommit_notes%x1D%N%x1Fcommitter_name%x1D%cN%x1Fcommitter_email%x1D%cE%x1Fcommitter_date%x1D%cD%x1Fref_name%x1D%D%x1Ftree%x1D%T%x1Funix_date%x1D%ct%x1Flog_date%x1D%cd%x1Fauthor_name%x1D%aN%x1Fabbreviated_commit%x1D%h%x1Foid%x1D%H%x1Fbody%x1D%b%x1Fabbreviated_tree%x1D%t%x1Frel_date%x1D%cr%x1Fsubject%x1D%s%x1Fabbreviated_parent%x1D%p%x1Fencoding%x1D%e%x1Fauthor_email%x1D%aE%x1E"

local function stats(t)
  table.sort(t)
  local sum = 0
  for _, v in ipairs(t) do
    sum = sum + v
  end
  return t[1], t[math.floor(#t / 2) + 1], sum / #t, t[#t]
end

local function fmt(tag, t)
  local mn, md, mean, mx = stats(t)
  out(("%s\tn=%d\tmin=%.3f\tmed=%.3f\tmean=%.3f\tmax=%.3f"):format(tag, #t, mn, md, mean, mx))
  return md
end

vim.cmd.cd(REPO)
require("neogit").setup({ filewatcher = { enabled = false } })

local cli = require("neogit.lib.git.cli")
local record = require("neogit.lib.record")
local Repo = require("neogit.lib.git.repository")
local ItemFilter = require("neogit.lib.item_filter")

-- 1) 捕获真实输出(经 io.popen,顺带测 popen spawn 路径)
local function capture(cmd)
  local t0 = vim.uv.hrtime()
  local h = io.popen(cmd)
  local s = h:read("*a")
  h:close()
  local t1 = vim.uv.hrtime()
  return s, (t1 - t0) / 1e6
end

local status_raw, status_popen_ms = capture("git --no-pager status --porcelain=2 -z | tr '\\0' '\\n'")
out(("capture_status_bytes\t%d"):format(#status_raw))
out(("capture_status_popen_ms\t%.3f"):format(status_popen_ms))

local log_raw, log_popen_ms = capture(
  ("git --no-pager log --format=%q --no-patch --max-count=500 --topo-order"):format(LOGFMT)
)
out(("capture_log_bytes\t%d"):format(#log_raw))
out(("capture_log_popen_ms\t%.3f"):format(log_popen_ms))

-- 2) status 解析:stub cli.status,喂捕获输出,调用真实 update_status
local status_result = { stdout = { status_raw }, stderr = {}, code = 0 }
local stub
stub = setmetatable({}, {
  __index = function(_, k)
    if k == "call" then
      return function()
        return status_result
      end
    end
    return stub
  end,
  __call = function()
    return stub
  end,
})
local real_status_cmd = cli.status
cli.status = stub

local repo = Repo.new(REPO)
local filter = ItemFilter.create { "*:*" }

-- warmup
repo.lib.update_status(repo.state, filter)
local n = 10
local t_status = {}
for i = 1, n do
  local t0 = vim.uv.hrtime()
  repo.lib.update_status(repo.state, filter)
  local t1 = vim.uv.hrtime()
  t_status[i] = (t1 - t0) / 1e6
end
fmt("parse_status_update_ms", t_status)
out(("parse_status_items\tstaged=%d,unstaged=%d,untracked=%d"):format(
  #repo.state.staged.items, #repo.state.unstaged.items, #repo.state.untracked.items))
cli.status = real_status_cmd

-- 3) log 解析:record.decode(500 commits;decode 接收行数组,与 log.list 一致)
local log_lines = vim.split(log_raw, "\n", { plain = true })
record.decode(log_lines)
local t_log = {}
for i = 1, n do
  local t0 = vim.uv.hrtime()
  local commits = record.decode(log_lines)
  local t1 = vim.uv.hrtime()
  t_log[i] = (t1 - t0) / 1e6
  if i == 1 then
    out(("parse_log_commits\t%d"):format(#commits))
  end
end
fmt("parse_log_record_decode_ms", t_log)

fh:close()
vim.cmd("qa!")
