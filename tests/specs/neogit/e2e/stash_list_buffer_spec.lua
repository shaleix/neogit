-- Lua port of spec/buffers/stash_list_buffer_spec.rb (E2E).
--
-- Parity notes:
--   * rspec's nvim.screen[1..2] is a 0-based range; this harness is
--     1-based, so those rows are screen()[2] and screen()[3] here.
--   * Expected strings are byte-exact copies padded to the 80-column
--     grid (trailing-space counts measured from the ruby source).
--   * Deliberate divergence from rspec: the stash row's relative time is
--     normalized ("%d seconds/second ago" pattern) instead of the exact
--     "0 seconds ago". rspec flakes at the 1-second render boundary
--     (~40-50% locally, both suites); normalization keeps the assertion
--     meaningful and deterministic, so this example is a regular `it`
--     here (rspec has it failing on its baseline).
local child_nvim = require("tests.util.child_nvim")
local e2e = require("tests.util.e2e")

local nvim
local workdir

local function row(s, trail)
  return s .. (" "):rep(trail)
end

local function boot(config)
  if nvim then
    nvim:teardown()
  end
  workdir = e2e.repo()
  nvim = child_nvim.new()
  nvim:setup(workdir, config)
end

describe("Stash list Buffer", function()
  before_each(function()
    boot()
    e2e.write_file(workdir, "1", "")
    e2e.git(workdir, "add", "1")
    e2e.git(workdir, "commit", "-qm", "test")
    e2e.write_file(workdir, "1", "hello world")
    e2e.git(workdir, "stash", "save", "test")
    nvim:refresh()
  end)

  after_each(function()
    if nvim then
      nvim:teardown()
      nvim = nil
    end
  end)

  it("renders, raising no errors", function()
    nvim:keys("Zl")
    local screen = nvim:screen()
    assert.equals(row(" Stashes (1)", 68), screen[2])
    -- relative time normalized - see header (rspec flakes on the exact
    -- "0 seconds ago" at the 1-second render boundary). Padding is
    -- flexible because the field is right-aligned: "1 second ago" is one
    -- char shorter than "0 seconds ago".
    assert.matches("^" .. vim.pesc("stash@{0} On master: test") .. "%s+%d+ seconds? ago%s*$", screen[3])

    assert.equals(0, #nvim:errors(), vim.inspect(nvim:errors()))
    assert.equals("NeogitStashView", nvim:filetype())
  end)

  it("can open CommitView", function()
    nvim:keys("Zl<enter>")
    assert.equals(0, #nvim:errors(), vim.inspect(nvim:errors()))
    assert.equals("NeogitCommitView", nvim:filetype())
  end)
end)
