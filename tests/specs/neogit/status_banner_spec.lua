-- The status banner: a large ASCII-art "NEOGIT" title (mcphub.nvim-style)
-- renders centered at the top of the status buffer by default, and
-- status.show_banner = false removes it.
local neogit = require("neogit")
local config = require("neogit.config")
local Repo = require("neogit.lib.git.repository")
local status_buf = require("neogit.buffers.status")

local function run(dir, ...)
  local r = vim.system({ "git", "-C", dir, ... }):wait()
  assert(r.code == 0, tostring(r.stderr))
end

-- A repository with one commit and one untracked file.
local function workdir()
  local dir = vim.fn.tempname()
  vim.uv.fs_mkdir(dir, 493)

  run(dir, "init", "-q", "-b", "main")
  run(dir, "config", "user.email", "t@t")
  run(dir, "config", "user.name", "t")

  local path = dir .. "/tracked.txt"
  vim.fn.writefile({ "one" }, path)
  run(dir, "add", "tracked.txt")
  run(dir, "commit", "-qm", "init")

  return dir
end

local function wait_refreshed(timeout)
  local fired = false
  vim.api.nvim_create_autocmd("User", {
    pattern = "NeogitStatusRefreshed",
    once = true,
    callback = function()
      fired = true
    end,
  })

  return vim.wait(timeout or 10000, function()
    return fired
  end, 10)
end

local function open_status(dir)
  vim.cmd.cd(dir)
  Repo.instance(dir, { autorefresh = false })
  local buf = status_buf.new(config.values, Repo.instance(dir).worktree_root, dir)
  buf:open("split")
  buf:dispatch_refresh()
  assert.truthy(wait_refreshed(), "initial refresh did not complete")
  vim.wait(50)
  return buf
end

local function buffer_lines(buf)
  return buf.buffer:get_lines(0, -1, false)
end

local function buffer_contains(buf, needle)
  for _, line in ipairs(buffer_lines(buf)) do
    if line:find(needle, 1, true) then
      return true
    end
  end

  return false
end

neogit.setup { filewatcher = { enabled = false }, disable_context_highlighting = true }

describe("status buffer banner", function()
  after_each(function()
    config.values.status.show_banner = true
    vim.cmd("silent! %bwipeout!")
  end)

  it("shows the ASCII-art title at the top by default", function()
    local dir = workdir()
    local buf = open_status(dir)

    assert.truthy(buffer_contains(buf, "╔╗ ╦ ╔═╗"), "the banner must render")
    assert.truthy(buffer_contains(buf, "╩ ╚╝ ╚═╝"), "all banner lines must render")

    -- The banner leads the buffer: the first rendered line is part of it.
    local lines = buffer_lines(buf)
    assert.truthy(lines[1]:find("╔╗ ╦ ╔═╗", 1, true), "the banner must be the topmost content")

    -- All banner rows share one left grid (uniform centering): identical
    -- leading padding on every row, so the letterforms cannot shear.
    local pads = {}
    for i = 1, 3 do
      pads[#pads + 1] = #(lines[i]:match("^ *") or "")
    end
    assert.truthy(pads[1] == pads[2] and pads[2] == pads[3], "banner rows must not shear vertically")
  end)

  it("renders the divider under the title", function()
    local dir = workdir()
    local buf = open_status(dir)

    assert.truthy(buffer_contains(buf, "────"), "the divider must render")
  end)

  it("defines the gradient highlight groups", function()
    local first = vim.api.nvim_get_hl(0, { name = "NeogitStatusBanner1" })
    local last = vim.api.nvim_get_hl(0, { name = "NeogitStatusBanner16" })

    assert.truthy(first.fg, "the first gradient step must be defined")
    assert.truthy(last.fg, "the last gradient step must be defined")
    assert.truthy(first.fg ~= last.fg, "the gradient endpoints must differ")
  end)

  it("honors status.show_banner = false", function()
    config.values.status.show_banner = false
    local dir = workdir()
    local buf = open_status(dir)

    assert.falsy(buffer_contains(buf, "║╚╗║"), "the banner must respect the config switch")
    assert.falsy(buffer_contains(buf, "────"), "the divider must respect the config switch")
  end)
end)
