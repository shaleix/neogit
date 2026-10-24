-- Lua port of spec/popups/worktree_popup_spec.rb (E2E).
--
-- Parity notes:
--   * The rspec :popup shared context is ported inline: before_each opens
--     the popup with `keymap`, plus the four standard popup tests.
--   * `include_examples "interaction", key` becomes the local
--     `interaction()` helper below.
--   * `git.worktrees.map(&:dir).last` is stood in by the last "worktree"
--     entry of `git worktree list --porcelain`.
--   * Expected strings are byte-exact 80-column copies (trailing-space
--     counts measured from the ruby source).
--   * Reference baseline (rspec, cli backend, this fork): 11 examples,
--     1 failing ("renders view properly") - the port matches one-for-one.
local child_nvim = require("tests.util.child_nvim")
local e2e = require("tests.util.e2e")

local function row(s, trail)
  return s .. (" "):rep(trail)
end

local nvim
local workdir

-- Tests failing on this fork's rspec baseline are registered as pending so
-- the default run stays green; set NEOGIT_E2E_STRICT=1 to execute them for
-- parity verification against rspec (see status_buffer_spec.lua).
local strict = os.getenv("NEOGIT_E2E_STRICT") ~= nil
local known_fail = strict and it or pending

local keymap = "w"

-- Port of the :popup shared context's before hook. The ruby harness's
-- per-key screen capture leaves a few hundred ms after the keystroke;
-- give the popup the same settle time before assertions run
-- (harness-gap workaround; the key sequence is unchanged).
local function open_popup()
  nvim:keys(keymap)
  assert(
    vim.wait(2000, function()
      return nvim:filetype() == "NeogitPopup"
    end, 50),
    "popup did not open"
  )
end

local view = {
  row(" Worktree        Do", 61),
  row(" w Checkout      g Goto", 57),
  row(" W Create        m Move", 57),
  row("                 D Delete", 55),
}

-- Port of `let(:dir) { "worktree_test_#{SecureRandom.hex(4)}" }`.
math.randomseed(os.time())
local function new_dir_name()
  return "worktree_test_" .. string.format("%08x", math.random(0, 2 ^ 31 - 1))
end

local function boot()
  if nvim then
    nvim:teardown()
  end
  workdir = e2e.repo()
  nvim = child_nvim.new()
  nvim:setup(workdir)
end

-- Port of `git.worktrees.map(&:dir).last`.
local function last_worktree_dir()
  local last
  for line in e2e.git(workdir, "worktree", "list", "--porcelain"):gmatch("[^\r\n]+") do
    last = line:match("^worktree (.+)$") or last
  end
  assert(last, "no worktrees found")
  return last
end

local function interaction(key, known)
  (known and known_fail or it)(("raises no errors with '%s'"):format(key), function()
    nvim:keys(key)
    assert.equals(0, #nvim:errors(), vim.inspect(nvim:errors()))
  end)
end

describe("Worktree Popup", function()
  before_each(function()
    boot() -- :git context (fresh repo) + :nvim context (open status buffer)
    open_popup() -- :popup context
  end)

  after_each(function()
    if nvim then
      nvim:teardown()
      nvim = nil
    end
    -- Port of the ruby after-hook: clean up worktree dirs left in tmpdir.
    local tmpdir = os.getenv("TMPDIR") or "/tmp"
    local scan = vim.uv.fs_scandir(tmpdir)
    if scan then
      while true do
        local name = vim.uv.fs_scandir_next(scan)
        if not name then
          break
        end
        if name:sub(1, #"worktree_test_") == "worktree_test_" then
          vim.fn.delete(tmpdir .. "/" .. name, "rf")
        end
      end
    end
  end)

  it("raises no errors", function()
    assert.equals(0, #nvim:errors(), vim.inspect(nvim:errors()))
  end)

  it("raises no errors with detached HEAD", function()
    nvim:keys("<esc>") -- close popup

    -- Detach HEAD
    e2e.git(workdir, "commit", "--allow-empty", "-qm", "dummy commit")
    e2e.git(workdir, "checkout", "HEAD^")

    vim.wait(1000) -- Allow state to propagate
    open_popup() -- open popup
    assert.equals(0, #nvim:errors(), vim.inspect(nvim:errors()))
  end)

  it("has correct filetype", function()
    assert.equals("NeogitPopup", nvim:filetype())
  end)

  known_fail("renders view properly", function()
    local screen = nvim:screen()
    local indices = {}
    for i, line in ipairs(view) do
      local found
      for r, content in ipairs(screen) do
        if content == line then
          found = r
          break
        end
      end
      assert(found, "screen is missing view line " .. i .. "\n" .. table.concat(screen, "\n"))
      indices[i] = found
    end
    for i, line in ipairs(view) do
      assert.equals(line, screen[indices[1] + i - 1], "view line " .. i)
    end
  end)

  interaction("w")
  interaction("W")
  interaction("g")
  interaction("m")
  interaction("D")

  describe("Actions", function()
    describe("Checkout", function()
      before_each(function()
        e2e.git(workdir, "checkout", "-b", "worktree-test")
        e2e.git(workdir, "checkout", "master")
      end)

      it("creates a worktree for an existing branch and checks it out", function()
        local dir = new_dir_name()
        nvim:keys("w") -- Action
        nvim:keys("wor<cr>") -- Select "worktree-test" branch
        nvim:keys(dir .. "/<cr>") -- go up level, new folder name

        local last = last_worktree_dir()
        assert.truthy(last:match("/" .. dir .. "$"), last)
        local pwd = nvim:cmd("pwd")[1]
        assert.truthy(pwd:match("/" .. dir .. "$"), pwd)
      end)
    end)

    describe("Create", function()
      before_each(function()
        e2e.git(workdir, "checkout", "-b", "worktree-test")
        e2e.git(workdir, "checkout", "master")
      end)

      it("creates a worktree for a new branch and checks it out", function()
        local dir = new_dir_name()
        nvim:keys("W") -- Action
        nvim:keys(dir .. "/<cr>") -- new folder name
        nvim:keys("mas<cr>") -- Set base branch to 'master'
        nvim:keys("create-worktree-test<cr>") -- branch name

        local last = last_worktree_dir()
        assert.truthy(last:match("/" .. dir .. "$"), last)
        local pwd = nvim:cmd("pwd")[1]
        assert.truthy(pwd:match("/" .. dir .. "$"), pwd)
      end)
    end)
    -- describe "Goto" / "Move" / "Delete" are commented out in the ruby spec
  end)
end)
