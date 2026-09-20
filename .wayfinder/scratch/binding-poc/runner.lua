-- PROTOTYPE / THROWAWAY — libgit2 绑定直连 PoC runner(wayfinder ticket: binding-poc)
-- 回答三件事:
--   [A] 能加载:vendor 的 fugit2 绑定层在 Neovim LuaJIT 里 ffi.load 系统 libgit2 成功
--   [B] 能对齐:libgit2 status/head/upstream 与 porcelain v2 的语义等价性(全等/缺失/多出)
--   [C] 有收益(指示性):单次 status 读的 FFI 直连 vs spawn git CLI 延迟(权威数字以 baseline-profile 为准)
-- 运行:nvim --headless -l runner.lua /path/to/repo
local REPO = arg[1] or "/tmp/opencode/poc-fixtures/rich"
local here = (debug.getinfo(1, "S").source:match("@(.*[/\\])") or "./")
package.path = here .. "vendor/?.lua;" .. package.path

local ffi = require "ffi"
ffi.cdef [[ void git_libgit2_version(int *major, int *minor, int *rev); ]]

local hr = ("="):rep(72)

print(hr)
print("[A] 加载 vendored 绑定层(fugit2 libgit2.lua + git2.lua + util/stat.lua,零改动)")
print(hr)
local libgit2 = require "fugit2.core.libgit2"
local git2 = require "fugit2.core.git2"
local vmaj, vmin, vrev = ffi.new("int[1]"), ffi.new("int[1]"), ffi.new("int[1]")
libgit2.C.git_libgit2_version(vmaj, vmin, vrev)
print(string.format("ffi.load OK -> libgit2 %d.%d.%d (library_path=%s)",
  vmaj[0], vmin[0], vrev[0], libgit2.library_path))

-- ============ [B] 对齐 ============
print("")
print(hr)
print("[B] status 对齐:porcelain v2(neogit 解析语义)vs libgit2(vendored git2.lua)")
print(hr)

local function sys(cmd)
  -- 注意:vim.fn.system 会破坏输出中的 NUL 字节(porcelain -z 的分隔符),必须用 vim.system
  local r = vim.system(cmd):wait()
  return r.stdout or ""
end

-- ---- porcelain v2 侧:最小解析器,镜像 neogit status.lua 的语义 ----
local out = sys({ "git", "-C", REPO, "status", "--porcelain=2", "-z", "--branch", "--untracked-files=all" })
local toks = vim.split(out, "\0", { plain = true })
if toks[#toks] == "" then toks[#toks] = nil end

-- 跳过 n 个空格分隔字段,取余下部分(路径可含空格)
local function rest_fields(s, n)
  local pos = 1
  for _ = 1, n do
    local sp = s:find(" ", pos, true)
    if not sp then return nil end
    pos = sp + 1
  end
  return s:sub(pos)
end

local porcelain = { branch = "?", ahead = -1, behind = -1, staged = {}, unstaged = {}, untracked = {}, unmerged = {} }
local i = 1
while i <= #toks do
  local t = toks[i]
  if t:sub(1, 1) == "#" then
    local bh = t:match "^# branch%.head (.*)"
    if bh then porcelain.branch = bh end
    local a, b = t:match "^# branch%.ab %+(%d+) %-(%d+)"
    if a then porcelain.ahead, porcelain.behind = tonumber(a), tonumber(b) end
  elseif t:sub(1, 2) == "? " then
    table.insert(porcelain.untracked, t:sub(3))
  elseif t:sub(1, 2) == "! " then
    -- ignored:neogit 默认不带 --ignored,跳过
  elseif t:sub(1, 2) == "1 " then
    local xy = t:match "^1 (..) "
    local path = rest_fields(t, 8)
    local x, y = xy:sub(1, 1), xy:sub(2, 2)
    if x ~= "." then table.insert(porcelain.staged, { x = x, path = path }) end
    if y ~= "." then table.insert(porcelain.unstaged, { y = y, path = path }) end
  elseif t:sub(1, 2) == "2 " then
    local xy = t:match "^2 (..) "
    local path = rest_fields(t, 9)
    local orig = toks[i + 1] -- -z:路径后跟 NUL 起来的 origPath
    i = i + 1
    local x, y = xy:sub(1, 1), xy:sub(2, 2)
    if x ~= "." then table.insert(porcelain.staged, { x = x, path = path, orig = orig }) end
    if y ~= "." then table.insert(porcelain.unstaged, { y = y, path = path }) end
  elseif t:sub(1, 2) == "u " then
    local path = rest_fields(t, 10)
    table.insert(porcelain.unmerged, path)
  end
  i = i + 1
end

print("porcelain 原始记录:")
for _, t in ipairs(toks) do print("  | " .. t:gsub("\0", "\\0")) end

-- ---- libgit2 侧 ----
local repo, oerr = git2.Repository.open(REPO)
assert(repo, "Repository.open failed: " .. tostring(oerr))
local items, rerr = repo:status()
assert(items, "repo:status() failed: " .. tostring(rerr))
local head, upstream, herr = repo:status_head_upstream()
assert(head, "status_head_upstream failed: " .. tostring(herr))

local delta_name = {}
for k, v in pairs(libgit2.GIT_DELTA) do delta_name[tonumber(v)] = k end

local lg2 = { staged = {}, unstaged = {}, untracked = {} }
for _, it in ipairs(items) do
  local idxs, wts = delta_name[tonumber(it.index_status)], delta_name[tonumber(it.worktree_status)]
  -- fugit2 封装对 untracked 条目会把 index_status 也置为 UNTRACKED,只归入 untracked
  if idxs and idxs ~= "UNMODIFIED" and idxs ~= "UNTRACKED" then
    table.insert(lg2.staged, { delta = idxs, path = it.path, new_path = it.renamed and it.new_path or nil })
  end
  if wts and wts ~= "UNMODIFIED" then
    if wts == "UNTRACKED" then
      table.insert(lg2.untracked, it.path)
    else
      table.insert(lg2.unstaged, { delta = wts, path = it.path, new_path = it.renamed and it.new_path or nil })
    end
  end
end

print("")
print("porcelain 归一化: branch=" .. porcelain.branch ..
  " ahead=" .. porcelain.ahead .. " behind=" .. porcelain.behind)
for _, e in ipairs(porcelain.staged) do
  print(("  staged   %s %s%s"):format(e.x, e.orig and (e.orig .. " -> ") or "", e.path))
end
for _, e in ipairs(porcelain.unstaged) do print(("  unstaged %s %s"):format(e.y, e.path)) end
for _, p in ipairs(porcelain.untracked) do print("  untracked? " .. p) end

print("libgit2 归一化:   branch=" .. head.name ..
  " ahead=" .. (upstream and upstream.ahead or "nil") .. " behind=" .. (upstream and upstream.behind or "nil"))
for _, e in ipairs(lg2.staged) do
  print(("  staged   %s %s%s"):format(e.delta, e.new_path and (e.path .. " -> " .. e.new_path) or "", e.new_path and "" or e.path))
end
for _, e in ipairs(lg2.unstaged) do
  print(("  unstaged %s %s%s"):format(e.delta, e.new_path and (e.path .. " -> " .. e.new_path) or "", e.new_path and "" or e.path))
end
for _, p in ipairs(lg2.untracked) do print("  untracked? " .. p) end

-- ---- 集合比较 ----
print("")
local X2D = { A = "ADDED", M = "MODIFIED", D = "DELETED", R = "RENAMED", T = "TYPECHANGE", C = "COPIED" }
local Y2D = { M = "MODIFIED", D = "DELETED", T = "TYPECHANGE" }

local function diffset(name, pk, lk)
  local ps, ls = {}, {}
  for _, k in ipairs(pk) do ps[k] = true end
  for _, k in ipairs(lk) do ls[k] = true end
  local only_p, only_l = {}, {}
  for k in pairs(ps) do if not ls[k] then only_p[#only_p + 1] = k end end
  for k in pairs(ls) do if not ps[k] then only_l[#only_l + 1] = k end end
  local ok = #only_p == 0 and #only_l == 0
  print(("%-10s porcelain=%d libgit2=%d  %s"):format(name, #pk, #lk, ok and "✅ 吻合" or "⚠️ 有单侧差异"))
  for _, k in ipairs(only_p) do print("      仅 porcelain: " .. k) end
  for _, k in ipairs(only_l) do print("      仅 libgit2 : " .. k) end
  return ok
end

local pk_staged, lk_staged = {}, {}
for _, e in ipairs(porcelain.staged) do
  pk_staged[#pk_staged + 1] = (X2D[e.x] or e.x) .. ": " .. (e.orig and (e.orig .. " -> ") or "") .. e.path
end
for _, e in ipairs(lg2.staged) do
  lk_staged[#lk_staged + 1] = e.delta .. ": " .. (e.new_path and (e.path .. " -> " .. e.new_path) or e.path)
end

local pk_unstaged, lk_unstaged = {}, {}
for _, e in ipairs(porcelain.unstaged) do
  pk_unstaged[#pk_unstaged + 1] = (Y2D[e.y] or e.y) .. ": " .. e.path
end
for _, e in ipairs(lg2.unstaged) do
  lk_unstaged[#lk_unstaged + 1] = e.delta .. ": " .. (e.new_path and (e.path .. " -> " .. e.new_path) or e.path)
end

local ok_s = diffset("staged", pk_staged, lk_staged)
local ok_u = diffset("unstaged", pk_unstaged, lk_unstaged)
local ok_ut = diffset("untracked", porcelain.untracked, lg2.untracked)
local ok_b = (porcelain.branch == head.name)
  and (porcelain.ahead == (upstream and upstream.ahead))
  and (porcelain.behind == (upstream and upstream.behind))
print(("%-10s porcelain: %s +%d/-%d  libgit2: %s +%d/-%d  %s"):format("branch",
  porcelain.branch, porcelain.ahead, porcelain.behind,
  head.name, upstream and upstream.ahead or -1, upstream and upstream.behind or -1,
  ok_b and "✅ 吻合" or "⚠️ 不一致"))

-- ============ [C] 指示性延迟 ============
print("")
print(hr)
print("[C] 指示性延迟(小 fixture,暖缓存;权威对比见 baseline-profile 报告)")
print(hr)

local function bench(name, n, fn)
  fn() -- warmup
  local t0 = vim.uv.hrtime()
  for _ = 1, n do fn() end
  local per = (vim.uv.hrtime() - t0) / 1e6 / n
  print(("%-52s %7.3f ms/次 (n=%d)"):format(name, per, n))
  return per
end

local N = 50
local t_cli = bench("CLI: git status --porcelain=2 -z -b -uall", N, function()
  local s = vim.system({ "git", "-C", REPO, "status", "--porcelain=2", "-z", "--branch", "--untracked-files=all" }):wait().stdout
  local n = 0
  for _ in s:gmatch "\0" do n = n + 1 end -- 模拟解析遍历
end)
local t_ffi = bench("FFI: repo:status() + status_head_upstream()", N, function()
  local it = repo:status()
  local h, u = repo:status_head_upstream()
end)
print(("=> status 全量读 FFI/CLI = %.2fx %s"):format(t_cli / t_ffi, t_ffi < t_cli and "(FFI 快)" or "(CLI 快!)"))

local t_lcli = bench("CLI: git log -n 200 --format=%H %s", N, function()
  vim.system({ "git", "-C", REPO, "log", "-n", "200", "--format=%H %s" }):wait()
end)
local t_lffi = bench("FFI: revwalk 前 200 条(push_head+iter)", N, function()
  local w = repo:walker()
  w:reset()
  w:push_head()
  local n = 0
  for oid, commit in w:iter() do
    n = n + 1
    if n >= 200 then break end
  end
end)
print(("=> log 前 200 条 FFI/CLI = %.2fx"):format(t_lcli / t_lffi))

print("")
print("[B] 结论: staged " .. (ok_s and "✅" or "⚠️") ..
  " / unstaged " .. (ok_u and "✅" or "⚠️") ..
  " / untracked " .. (ok_ut and "✅" or "⚠️") ..
  " / branch+ab " .. (ok_b and "✅" or "⚠️"))
