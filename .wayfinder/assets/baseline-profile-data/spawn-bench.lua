-- 空闲 nvim 里的单进程开销:jobstart(vim.uv.spawn 封装) vs io.popen vs vim.system
local OUT = assert(os.getenv("OUT"))
local fh = io.open(OUT, "a")
local function out(line)
  fh:write(line, "\n")
end

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
end

local REPO = "/tmp/opencode/stress-repo"
vim.cmd.cd(REPO)

-- jobstart 单进程(git rev-parse HEAD,含读取输出的完整往返)
local function job_time(cmd)
  local t0 = vim.uv.hrtime()
  local stdout = {}
  local jid = vim.fn.jobstart(cmd, {
    stdout_buffered = false,
    on_stdout = function(_, data)
      for _, l in ipairs(data) do
        if l ~= "" then
          table.insert(stdout, l)
        end
      end
    end,
  })
  vim.fn.jobwait({ jid }, 10000)
  local t1 = vim.uv.hrtime()
  return (t1 - t0) / 1e6
end

job_time({ "git", "rev-parse", "HEAD" })
local t = {}
for i = 1, 20 do
  t[i] = job_time({ "git", "rev-parse", "HEAD" })
end
fmt("jobstart_revparse_HEAD_ms", t)

local t2 = {}
for i = 1, 20 do
  t2[i] = job_time({ "/usr/bin/true" })
end
fmt("jobstart_true_ms", t2)

-- jobstart status -z(单进程,无竞争)
local function job_status()
  local t0 = vim.uv.hrtime()
  local stdout = {}
  local jid = vim.fn.jobstart({ "git", "--no-pager", "--no-optional-locks", "-c", "core.preloadindex=true", "-c", "color.ui=always", "-c", "diff.noprefix=false", "status", "-z", "--porcelain=2" }, {
    on_stdout = function(_, data)
      table.insert(stdout, #data)
    end,
  })
  vim.fn.jobwait({ jid }, 10000)
  local t1 = vim.uv.hrtime()
  return (t1 - t0) / 1e6
end
job_status()
local t3 = {}
for i = 1, 10 do
  t3[i] = job_status()
end
fmt("jobstart_status_z_ms", t3)

fh:close()
vim.cmd("qa!")
