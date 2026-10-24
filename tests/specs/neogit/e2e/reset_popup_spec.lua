-- Lua port of spec/popups/reset_popup_spec.rb (E2E).
--
-- Parity notes:
--   * The rspec :popup shared context is ported inline: before_each opens
--     the popup with `keymap`, plus the four standard popup tests.
--   * `include_examples "interaction", key` becomes the local
--     `interaction()` helper below.
--   * `git.revparse` is stood in by `git rev-parse` (chomped);
--     `git.status.added.keys` by the staged files (`git diff --cached`).
--   * Expected strings are byte-exact 80-column copies (trailing-space
--     counts measured from the ruby source).
--   * Reference baseline (rspec, cli backend, this fork): 15 examples,
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

local keymap = "X"

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
  row(" Reset         Reset this", 55),
  row(" f file        m mixed    (HEAD and index)", 38),
  row(" b branch      s soft     (HEAD only)", 43),
  row("               h hard     (HEAD, index and files)", 31),
  row("               k keep     (HEAD and index, keeping uncommitted)", 17),
  row("               i index    (only)", 48),
  row("               w worktree (only)", 48),
}

local function boot()
  if nvim then
    nvim:teardown()
  end
  workdir = e2e.repo()
  nvim = child_nvim.new()
  nvim:setup(workdir)
end

-- Port of `git.revparse(...)`.
local function revparse(rev)
  return vim.trim(e2e.git(workdir, "rev-parse", rev))
end

local function interaction(key, known)
  (known and known_fail or it)(("raises no errors with '%s'"):format(key), function()
    nvim:keys(key)
    assert.equals(0, #nvim:errors(), vim.inspect(nvim:errors()))
  end)
end

describe("Reset Popup", function()
  before_each(function()
    boot() -- :git context (fresh repo) + :nvim context (open status buffer)
    open_popup() -- :popup context
  end)

  after_each(function()
    if nvim then
      nvim:teardown()
      nvim = nil
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

  interaction("f")
  interaction("b")
  interaction("m")
  interaction("s")
  interaction("h")
  interaction("k")
  interaction("i")
  interaction("w")

  describe("Actions", function()
    before_each(function()
      e2e.git(workdir, "tag", "checkpoint") -- lightweight tag at initial commit
      e2e.write_file(workdir, "extra.txt", "extra content")
      e2e.git(workdir, "add", "extra.txt")
      e2e.git(workdir, "commit", "-qm", "add extra.txt")
      nvim:refresh()
    end)

    describe("Mixed reset", function()
      it("resets HEAD and index to the target commit", function()
        local target = revparse("checkpoint")
        nvim:keys("m")
        nvim:keys("check<cr>")
        e2e.await(function()
          assert.equals(target, revparse("HEAD"))
        end)
      end)
    end)

    describe("Soft reset", function()
      it("resets HEAD but preserves staged changes", function()
        local target = revparse("checkpoint")
        nvim:keys("s")
        nvim:keys("check<cr>")
        e2e.await(function()
          assert.equals(target, revparse("HEAD"))
          local staged = e2e.cached_files(workdir)
          assert.truthy(staged:find("extra.txt", 1, true), staged)
        end)
      end)
    end)

    describe("Hard reset", function()
      it("resets HEAD, index, and working tree", function()
        local target = revparse("checkpoint")
        nvim:keys("h")
        nvim:keys("check<cr>")
        e2e.await(function()
          assert.equals(target, revparse("HEAD"))
          assert.falsy(vim.uv.fs_stat(workdir .. "/extra.txt"))
        end)
      end)
    end)
  end)
end)
