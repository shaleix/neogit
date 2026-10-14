-- e (n_quick_stash): scope choice (both / staged only / with untracked)
-- followed by a message input - Enter stashes, empty message keeps git's
-- default "WIP on <branch>: ...", Esc at the message box aborts. Also pins
-- the git command layer: staged-only stashing is `stash push --staged`
-- (plain `git stash staged` is not a command) and keep-index needs `push`.
local neogit = require("neogit")
local config = require("neogit.config")
local Repo = require("neogit.lib.git.repository")
local status_buf = require("neogit.buffers.status")
local actions = require("neogit.buffers.status.actions")
local input = require("neogit.lib.input")

local function run(dir, ...)
  local r = vim.system({ "git", "-C", dir, ... }):wait()
  assert(r.code == 0, tostring(r.stderr))
end

local function stash_list(dir)
  local r = vim.system({ "git", "-C", dir, "stash", "list" }):wait()
  return vim.trim(r.stdout or "")
end

local function read_file(path)
  local f = assert(io.open(path, "r"))
  local content = f:read("*a")
  f:close()
  return content
end

local function file_exists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

local function append(dir, path, content)
  local f = assert(io.open(dir .. "/" .. path, "a"))
  f:write(content)
  f:close()
end

local function workdir()
  local dir = vim.fn.tempname()
  vim.uv.fs_mkdir(dir, 493)

  run(dir, "init", "-q", "-b", "main")
  run(dir, "config", "user.email", "t@t")
  run(dir, "config", "user.name", "t")

  local f1 = assert(io.open(dir .. "/tracked.txt", "w"))
  f1:write("one\n")
  f1:close()
  local f2 = assert(io.open(dir .. "/other.txt", "w"))
  f2:write("aaa\n")
  f2:close()
  run(dir, "add", "-A")
  run(dir, "commit", "-qm", "init")

  return dir
end

local function open_status(dir)
  vim.cmd.cd(dir)
  Repo.instance(dir, { autorefresh = false })
  local buf = status_buf.new(config.values, Repo.instance(dir).worktree_root, dir)
  buf:open("split")
  -- tracked so after_each can close it: a lingering status instance keeps
  -- refresh tasks running into the next test's async context
  current_status_buf = buf
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

---Stub the scope choice and the message input; records what was asked and
---returns the restore function.
local function stub_quick_stash_inputs(scope, message)
  local original_choice, original_input = input.get_choice, input.get_user_input
  local asked = {}
  input.get_choice = function(msg, opts)
    asked.choice = { msg = msg, values = opts and opts.values }
    return scope
  end
  input.get_user_input = function(prompt, opts)
    asked.message = { prompt = prompt, opts = opts }
    return message
  end
  return asked, function()
    input.get_choice, input.get_user_input = original_choice, original_input
  end
end

---Runs the handler and waits out the refresh wave it dispatches, so the
---libgit2 tasks it spawns (which can throw on freshly-stashed state) resolve
---inside THIS test instead of leaking into the next test's async context.
local function run_and_settle(handler)
  local refreshed = false
  local id = vim.api.nvim_create_autocmd("User", {
    pattern = "NeogitStatusRefreshed",
    once = true,
    callback = function()
      refreshed = true
    end,
  })

  handler()

  local settled = vim.wait(10000, function()
    return refreshed
  end, 10)
  pcall(vim.api.nvim_del_autocmd, id)
  return settled
end

local current_status_buf

local function wait_for_stash(dir)
  return vim.wait(10000, function()
    return stash_list(dir) ~= ""
  end, 10)
end

neogit.setup { filewatcher = { enabled = false }, disable_context_highlighting = true }

describe("status quick stash (e)", function()
  after_each(function()
    if current_status_buf then
      pcall(function()
        current_status_buf:close()
      end)
      current_status_buf = nil
      vim.wait(50)
    end
  end)

  it("stashes both with the typed message and leaves untracked files alone", function()
    local dir = workdir()
    append(dir, "tracked.txt", "two\n")
    append(dir, "untracked.txt", "new\n")

    local buf = open_status(dir)
    buf.buffer:focus()

    local asked, restore = stub_quick_stash_inputs("b", "my stash msg")
    assert.truthy(vim.fn.search([[\Vtracked.txt]], "w") > 0, "unstaged row must render")
    assert.truthy(
      run_and_settle(function()
        actions.n_quick_stash(buf)()
      end),
      "the post-stash refresh must settle"
    )

    assert.truthy(wait_for_stash(dir), "stash must be created; list: " .. stash_list(dir))
    restore()

    assert.equal("stash@{0}: On main: my stash msg", stash_list(dir), "the typed message must name the stash")
    assert.equal("one\n", read_file(dir .. "/tracked.txt"), "the stashed change must leave the worktree")
    assert.truthy(file_exists(dir .. "/untracked.txt"), "plain 'both' must not touch untracked files")

    assert.same({ "&Both", "&Staged only", "With &untracked" }, asked.choice.values, "scope choices")
    assert.equal("Stash message", asked.message.prompt, "message prompt")
  end)

  it("stages-only scope stashes just the staged change via push --staged", function()
    local dir = workdir()
    append(dir, "tracked.txt", "two\n")
    run(dir, "add", "tracked.txt")
    append(dir, "other.txt", "three\n") -- stays unstaged

    local buf = open_status(dir)
    buf.buffer:focus()

    local _, restore = stub_quick_stash_inputs("s", "staged-msg")
    assert.truthy(vim.fn.search([[\Vtracked.txt]], "w") > 0, "staged row must render")
    assert.truthy(
      run_and_settle(function()
        actions.n_quick_stash(buf)()
      end),
      "the post-stash refresh must settle"
    )

    assert.truthy(wait_for_stash(dir), "stash must be created; list: " .. stash_list(dir))
    restore()

    assert.equal(
      "stash@{0}: On main: staged-msg",
      stash_list(dir),
      "`git stash staged` is not a command; staged-only must go through push --staged"
    )
    assert.equal("one\n", read_file(dir .. "/tracked.txt"), "the staged change must leave the worktree")
    assert.equal("aaa\nthree\n", read_file(dir .. "/other.txt"), "unstaged changes must stay in the worktree")
  end)

  it("with-untracked scope includes untracked files", function()
    local dir = workdir()
    append(dir, "tracked.txt", "two\n")
    append(dir, "new.txt", "brand new\n")

    local buf = open_status(dir)
    buf.buffer:focus()

    local _, restore = stub_quick_stash_inputs("u", "with-untracked")
    assert.truthy(vim.fn.search([[\Vtracked.txt]], "w") > 0, "unstaged row must render")
    assert.truthy(
      run_and_settle(function()
        actions.n_quick_stash(buf)()
      end),
      "the post-stash refresh must settle"
    )

    assert.truthy(wait_for_stash(dir), "stash must be created; list: " .. stash_list(dir))
    restore()

    assert.equal("stash@{0}: On main: with-untracked", stash_list(dir))
    assert.truthy(not file_exists(dir .. "/new.txt"), "the untracked file must be stashed away")
    assert.equal("one\n", read_file(dir .. "/tracked.txt"))
  end)

  it("an empty message keeps git's default WIP message", function()
    local dir = workdir()
    append(dir, "tracked.txt", "two\n")

    local buf = open_status(dir)
    buf.buffer:focus()

    local _, restore = stub_quick_stash_inputs("b", "")
    assert.truthy(vim.fn.search([[\Vtracked.txt]], "w") > 0, "unstaged row must render")
    assert.truthy(
      run_and_settle(function()
        actions.n_quick_stash(buf)()
      end),
      "the post-stash refresh must settle"
    )

    assert.truthy(wait_for_stash(dir), "stash must be created; list: " .. stash_list(dir))
    restore()

    assert.truthy(
      stash_list(dir):find("^stash@{0}: WIP on main", 1, false),
      "empty message must fall back to git's WIP wording; got: " .. stash_list(dir)
    )
  end)

  it("aborting at the message box creates nothing", function()
    local dir = workdir()
    append(dir, "tracked.txt", "two\n")

    local buf = open_status(dir)
    buf.buffer:focus()

    local _, restore = stub_quick_stash_inputs("b", nil)
    assert.truthy(vim.fn.search([[\Vtracked.txt]], "w") > 0, "unstaged row must render")
    -- aborts before any git call or refresh wave: no settle wait applies
    actions.n_quick_stash(buf)()
    vim.wait(500)
    restore()

    assert.equal("", stash_list(dir), "Esc at the message box must abort without stashing")
    assert.equal("one\ntwo\n", read_file(dir .. "/tracked.txt"), "the change must stay in the worktree")
  end)
end)
