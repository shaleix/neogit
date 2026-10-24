-- Git fixtures and retry helpers for the E2E suite. Ports the rspec
-- spec_helper around-hooks (temp local repo, optional bare origin) and
-- the Helpers module (await, create_file), plus porcelain stand-ins for
-- the ruby `git` gem's status API.
local util = require("tests.util.util")

local M = {}

---Run git in `dir`, asserting success. Returns stdout.
function M.git(dir, ...)
  local result = vim.system({ "git", "-C", dir, ... }, { text = true }):wait()
  assert(
    result.code == 0,
    ("git %s failed (%d): %s"):format(table.concat({ ... }, " "), result.code, result.stderr or "")
  )
  return result.stdout or ""
end

function M.write_file(dir, name, content)
  local path = dir .. "/" .. name
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file = assert(io.open(path, "w"))
  file:write(content or "")
  file:close()
end

function M.read_file(dir, name)
  local file = assert(io.open(dir .. "/" .. name, "r"))
  local content = file:read("*a")
  file:close()
  return content
end

---Ports the rspec `:git` shared context: temp repo with one commit on
---`testfile`. `opts.remote_origin` also creates a bare `origin` remote.
---@return string workdir
function M.repo(opts)
  opts = opts or {}
  local dir = util.create_temp_dir("e2e-local")

  M.git(dir, "init", "-q")
  M.git(dir, "config", "user.email", "test@example.com")
  M.git(dir, "config", "user.name", "tester")

  if opts.remote_origin then
    local remote = util.create_temp_dir("e2e-remote")
    vim.system({ "git", "init", "-q", "--bare", remote }):wait()
    M.git(dir, "remote", "add", "origin", remote)
  end

  M.write_file(dir, "testfile", "hello, world\n")
  M.git(dir, "add", "testfile")
  M.git(dir, "commit", "-qm", "Initial commit\ncommit message")

  return dir
end

---Ports Helpers#await: retry an assertion ~10 times, 100ms apart.
function M.await(fn)
  local last_err
  for _ = 1, 10 do
    local ok, err = pcall(fn)
    if ok then
      return
    end
    last_err = err
    vim.wait(100)
  end
  error(last_err)
end

-- porcelain stand-ins for the ruby git gem ------------------------------------

local function porcelain(dir)
  local entries = {}
  for line in M.git(dir, "status", "--porcelain"):gmatch("[^\r\n]+") do
    entries[#entries + 1] = line
  end
  return entries
end

---git.status.changed.keys: files modified in the worktree (unstaged).
function M.worktree_modified(dir)
  local paths = {}
  for _, line in ipairs(porcelain(dir)) do
    if line:sub(1, 2) == " M" then
      paths[#paths + 1] = line:sub(4)
    end
  end
  return paths
end

---git.status.untracked: untracked files.
function M.untracked(dir)
  local paths = {}
  for _, line in ipairs(porcelain(dir)) do
    if line:sub(1, 2) == "??" then
      paths[#paths + 1] = line:sub(4)
    end
  end
  return paths
end

function M.cached_files(dir)
  return vim.trim(M.git(dir, "diff", "--cached", "--name-only"))
end

return M
