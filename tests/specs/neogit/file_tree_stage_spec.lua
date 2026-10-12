-- File sections always render as a directory tree: pressing stage/unstage
-- on a directory row must only affect the files under that directory, not
-- the entire section.
local neogit = require("neogit")
local config = require("neogit.config")
local Repo = require("neogit.lib.git.repository")
local status_buf = require("neogit.buffers.status")
local actions = require("neogit.buffers.status.actions")

local function workdir()
  local dir = vim.fn.tempname()
  vim.uv.fs_mkdir(dir, 493)

  local function run(...)
    local r = vim.system({ "git", "-C", dir, ... }):wait()
    assert(r.code == 0, tostring(r.stderr))
  end

  run("init", "-q", "-b", "main")
  run("config", "user.email", "t@t")
  run("config", "user.name", "t")

  local function write(p, c)
    vim.fn.mkdir(vim.fs.dirname(dir .. "/" .. p), "p")
    local fd = assert(io.open(dir .. "/" .. p, "w"))
    fd:write(c)
    fd:close()
  end

  -- committed files
  write("src/main.lua", "a\n")
  write("other/deep/x.lua", "b\n")
  write("root.txt", "c\n")
  run("add", ".")
  run("commit", "-qm", "init")

  return dir, write
end

local function open_status(dir)
  vim.cmd.cd(dir)
  Repo.instance(dir, { autorefresh = false })
  local buf = status_buf.new(config.values, Repo.instance(dir).worktree_root, dir)
  buf:open("split")
  local fired = false
  vim.api.nvim_create_autocmd("User", {
    pattern = "NeogitStatusRefreshed",
    once = true,
    callback = function()
      fired = true
    end,
  })
  buf:dispatch_refresh()
  assert.truthy(
    vim.wait(10000, function()
      return fired
    end, 10),
    "refresh did not complete"
  )
  vim.wait(50)
  return buf
end

---Runs an action and waits for the refresh it dispatches to complete.
local function run_action(buf, action)
  local fired = false
  vim.api.nvim_create_autocmd("User", {
    pattern = "NeogitStatusRefreshed",
    once = true,
    callback = function()
      fired = true
    end,
  })

  action(buf)()

  assert.truthy(
    vim.wait(10000, function()
      return fired
    end, 10),
    "action did not dispatch a refresh"
  )
  vim.wait(50)
end

---Parses `git status --porcelain` into a { path -> "XY" } map.
---`-uall` expands untracked directories into individual files.
local function porcelain(dir)
  local r = assert(vim.system({ "git", "-C", dir, "status", "--porcelain", "-uall" }):wait())
  assert(r.code == 0, tostring(r.stderr))

  local out = {}
  for _, line in ipairs(vim.split(r.stdout, "\n")) do
    if line ~= "" then
      out[line:sub(4)] = line:sub(1, 2)
    end
  end

  return out
end

---Moves the cursor onto a rendered directory row.
local function cursor_to_directory(pattern)
  local line = vim.fn.search(pattern)
  assert.truthy(line > 0, ("directory row %q not found"):format(pattern))
end

neogit.setup { filewatcher = { enabled = false }, disable_context_highlighting = true }

describe("status file tree stage/unstage on directory rows", function()
  it("stages only the files under the cursor's directory (unstaged)", function()
    local dir, write = workdir()
    write("src/main.lua", "a\nb\n")
    write("other/deep/x.lua", "b\nb\n")
    write("root.txt", "c\nc\n")

    local buf = open_status(dir)
    buf.buffer:focus()
    cursor_to_directory("src")

    run_action(buf, actions.n_stage)

    local status = porcelain(dir)
    assert.equal("M ", status["src/main.lua"], "src/main.lua must be staged")
    assert.equal(" M", status["other/deep/x.lua"], "other/deep/x.lua must stay unstaged")
    assert.equal(" M", status["root.txt"], "root.txt must stay unstaged")
  end)

  it("stages mass deletions under the cursor's directory", function()
    local dir, write = workdir()
    for i = 1, 500 do
      write(("src/gen/f%03d.lua"):format(i), ("x%d\n"):format(i))
    end
    assert(vim.system({ "git", "-C", dir, "add", "." }):wait().code == 0)
    assert(vim.system({ "git", "-C", dir, "commit", "-qm", "gen" }):wait().code == 0)
    -- wipe the entire src/ tree from the worktree (500 deletions + main.lua)
    assert(vim.system({ "rm", "-rf", dir .. "/src" }):wait().code == 0)

    local buf = open_status(dir)
    buf.buffer:focus()
    cursor_to_directory("src")

    run_action(buf, actions.n_stage)

    local status = porcelain(dir)
    for i = 1, 500 do
      local path = ("src/gen/f%03d.lua"):format(i)
      assert.equal("D ", status[path], path .. " deletion must be staged")
    end
    assert.equal("D ", status["src/main.lua"], "src/main.lua deletion must be staged")

    -- the UI must reflect the move: deletions leave "Unstaged changes",
    -- appear under "Staged changes"
    local text = table.concat(vim.api.nvim_buf_get_lines(buf.buffer.handle, 0, -1, false), "\n")
    local unstaged = text:match("Unstaged changes(.-)%f[%a].-Staged")
      or text:match("Unstaged changes(.*)")
      or ""
    local staged = text:match("Staged changes(.*)") or ""
    assert.truthy(staged:find("src", 1, true), "staged section must list the src tree:\n" .. text)
    assert.falsy(unstaged:find("src", 1, true), "unstaged section must no longer list src:\n" .. text)
  end)

  it("stages only the files under the cursor's directory (untracked)", function()
    local dir, write = workdir()
    write("new/a.txt", "a\n")
    write("new/sub/b.txt", "b\n")
    write("other_new/c.txt", "c\n")

    local buf = open_status(dir)
    buf.buffer:focus()
    cursor_to_directory("new")

    run_action(buf, actions.n_stage)

    local status = porcelain(dir)
    assert.equal("A ", status["new/a.txt"], "new/a.txt must be staged")
    assert.equal("A ", status["new/sub/b.txt"], "new/sub/b.txt must be staged")
    assert.equal("??", status["other_new/c.txt"], "other_new/c.txt must stay untracked")
  end)

  it("stages in the requesting buffer's repo, not the last-opened one", function()
    local dir_a, write_a = workdir()
    local dir_b, write_b = workdir()
    write_a("src/main.lua", "a\nb\n")
    write_b("src/main.lua", "b\nb\n")

    -- open A, then B: the global repo singleton now points at B
    local buf_a = open_status(dir_a)
    local buf_b = open_status(dir_b)

    -- user switches back to A's status buffer and stages a directory row
    buf_a.buffer:focus()
    cursor_to_directory("src")

    run_action(buf_a, function(b)
      return b:_action("n_stage")
    end)

    local status_a = porcelain(dir_a)
    local status_b = porcelain(dir_b)
    assert.equal("M ", status_a["src/main.lua"], "A's file must be staged in A's index")
    assert.equal(" M", status_b["src/main.lua"], "B's index must be left untouched")
  end)

  it("unstages only the files under the cursor's directory", function()
    local dir, write = workdir()
    write("src/main.lua", "a\nb\n")
    write("other/deep/x.lua", "b\nb\n")
    vim.system({ "git", "-C", dir, "add", "src", "other" }):wait()

    local buf = open_status(dir)
    buf.buffer:focus()
    -- the staged section holds the directory rows for this test
    cursor_to_directory("Staged changes")
    cursor_to_directory("src")

    run_action(buf, actions.n_unstage)

    local status = porcelain(dir)
    assert.equal(" M", status["src/main.lua"], "src/main.lua must be unstaged")
    assert.equal("M ", status["other/deep/x.lua"], "other/deep/x.lua must stay staged")
  end)
end)
