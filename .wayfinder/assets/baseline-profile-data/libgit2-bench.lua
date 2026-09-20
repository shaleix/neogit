-- libgit2 对照基准:经 fugit2 绑定层(FFI)对同一仓库做 status/revwalk/diff 计时
-- 用法:OUT=... nvim --clean --headless -u minimal.lua -l libgit2-bench.lua
local REPO = "/tmp/opencode/stress-repo"
local OUT = assert(os.getenv("OUT"), "OUT env required")
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

vim.opt.runtimepath:prepend("/home/ecs-user/workerspace/fugit2.nvim")

local ok, git2 = pcall(require, "fugit2.core.git2")
local ffi = require("ffi")
if not ok then
  out(("ERROR require fugit2.core.git2\t%s"):format(tostring(git2)))
  fh:close()
  vim.cmd("qa!")
  return
end

local libgit2 = require("fugit2.core.libgit2")
out(("libgit2_version\t%s"):format(tostring(libgit2.C and "loaded" or "lazy")))

-- 0) 库加载 + 首次 open(含 git_libgit2_init)
local t0 = vim.uv.hrtime()
local repo, err = git2.Repository.open(REPO, true)
local t1 = vim.uv.hrtime()
out(("open_first_ms\t%.3f\terr=%d"):format((t1 - t0) / 1e6, err or -1))
if not repo then
  fh:close()
  vim.cmd("qa!")
  return
end

local n = 10

-- 1) 重复 open(git_repository_open_ext)
local t_open = {}
for i = 1, n do
  local a = vim.uv.hrtime()
  local r, e = git2.Repository.open(REPO, true)
  local b = vim.uv.hrtime()
  t_open[i] = (b - a) / 1e6
  if not r then
    out("open failed " .. tostring(e))
  end
  r = nil
  collectgarbage("step")
end
fmt("open_repo_ms", t_open)

-- 2) status 全量(git_status_list_new + 转 Lua items,含 untracked/renames)
local items, err2 = repo:status()
if not items then
  out("status failed " .. tostring(err2))
else
  out(("status_items\t%d"):format(#items))
end
local t_status = {}
for i = 1, n do
  local a = vim.uv.hrtime()
  local it, _ = repo:status()
  local b = vim.uv.hrtime()
  t_status[i] = (b - a) / 1e6
  it = nil
end
fmt("status_full_ms", t_status)

-- 3) revwalk 遍历(全仓库 200 commits,push_head + topo 排序 + commit lookup)
local walker, werr = repo:walker()
if not walker then
  out("walker failed " .. tostring(werr))
else
  local count = 0
  walker:reset()
  walker:sort(true, false, false)
  walker:push_head()
  for oid, _commit in walker:iter() do
    count = count + 1
  end
  out(("revwalk_count\t%d"):format(count))

  local t_walk = {}
  for i = 1, n do
    local a = vim.uv.hrtime()
    walker:reset()
    walker:sort(true, false, false)
    walker:push_head()
    local c = 0
    for _oid, _c in walker:iter() do
      c = c + 1
    end
    local b = vim.uv.hrtime()
    t_walk[i] = (b - a) / 1e6
    if i == 1 and c ~= count then
      out("revwalk count mismatch " .. c)
    end
  end
  fmt("revwalk_all_ms", t_walk)
end

-- 4) tree-to-workdir diff(git diff HEAD 同构:diff_head_to_workdir,fugit2 包装含 find_similar+untracked)
local libgit2_C = libgit2.C
local diff, derr = repo:diff_head_to_workdir(nil, false, 3)
if not diff then
  out("diff failed " .. tostring(derr))
else
  local pok, cnt = pcall(function()
    return tonumber(libgit2_C.git_diff_num_deltas(diff.diff))
  end)
  out(("diff_deltas\t%s"):format(tostring(pok and cnt or "n/a")))
end
local t_diff = {}
for i = 1, n do
  local a = vim.uv.hrtime()
  local d, _ = repo:diff_head_to_workdir(nil, false, 3)
  local b = vim.uv.hrtime()
  t_diff[i] = (b - a) / 1e6
  d = nil
end
fmt("diff_head_to_workdir_ms", t_diff)

-- 4b) 拆分:head->index 与 index->workdir(git CLI 的实际路径)
local t_dhi, t_diw = {}, {}
do
  local d, _ = repo:diff_head_to_index(nil, nil, false, 3)
  local pok2, cnt2 = pcall(function()
    return tonumber(libgit2_C.git_diff_num_deltas(d.diff))
  end)
  out(("diff_head_to_index_deltas\t%s"):format(tostring(pok2 and cnt2 or "n/a")))
  d = nil
end
for i = 1, n do
  local a = vim.uv.hrtime()
  local d, _ = repo:diff_head_to_index(nil, nil, false, 3)
  local b = vim.uv.hrtime()
  t_dhi[i] = (b - a) / 1e6
  d = nil
end
fmt("diff_head_to_index_ms", t_dhi)
for i = 1, n do
  local a = vim.uv.hrtime()
  local d, _ = repo:diff_index_to_workdir(nil, nil, false, 3)
  local b = vim.uv.hrtime()
  t_diw[i] = (b - a) / 1e6
  d = nil
end
fmt("diff_index_to_workdir_ms", t_diw)

-- 4c) 裸 C:git_diff_tree_to_workdir,最小 flags(无 untracked/find_similar)
do
  local head_tree, hterr = repo:head_tree()
  if head_tree then
    local cdiff = ffi.new "git_diff*[1]"
    local opts = ffi.new("git_diff_options[1]", libgit2.GIT_DIFF_OPTIONS_INIT)
    local er = libgit2_C.git_diff_tree_to_workdir(cdiff, repo.repo, head_tree.tree, opts)
    out(("diff_raw_tree_to_workdir_err\t%d"):format(er))
    local pok3, cnt3 = pcall(function()
      return tonumber(libgit2_C.git_diff_num_deltas(cdiff[0]))
    end)
    out(("diff_raw_tree_to_workdir_deltas\t%s"):format(tostring(pok3 and cnt3 or "n/a")))
    libgit2_C.git_diff_free(cdiff[0])

    local t_raw = {}
    for i = 1, n do
      local a = vim.uv.hrtime()
      local cd = ffi.new "git_diff*[1]"
      local o = ffi.new("git_diff_options[1]", libgit2.GIT_DIFF_OPTIONS_INIT)
      libgit2_C.git_diff_tree_to_workdir(cd, repo.repo, head_tree.tree, o)
      local b = vim.uv.hrtime()
      t_raw[i] = (b - a) / 1e6
      libgit2_C.git_diff_free(cd[0])
    end
    fmt("diff_raw_tree_to_workdir_ms", t_raw)
  else
    out("head_tree failed " .. tostring(hterr))
  end
end

-- 5) 分支列表(对照 for-each-ref)
local pok, branches = pcall(function()
  return repo:branches(true, false)
end)
if pok and branches then
  out(("branches_count\t%d"):format(#branches))
  local t_br = {}
  for i = 1, n do
    local a = vim.uv.hrtime()
    repo:branches(true, false)
    local b = vim.uv.hrtime()
    t_br[i] = (b - a) / 1e6
  end
  fmt("branches_ms", t_br)
else
  out("branches skipped: " .. tostring(branches))
end

fh:close()
vim.cmd("qa!")
