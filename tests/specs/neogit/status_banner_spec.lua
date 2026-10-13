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

  it("re-centers the banner and resizes the divider on window resize", function()
    local dir = workdir()
    local buf = open_status(dir)

    local win = buf.buffer.win_handle
    assert.truthy(win and vim.api.nvim_win_is_valid(win), "status window must exist")

    -- A sole window clamps its width to the editor width, so give it a real
    -- vertical split neighbor first; then narrowing the status window is a
    -- legal resize. The divider is the 4th line (3 logo rows + divider),
    -- rendered as width - 6 dashes.
    vim.cmd("vnew")
    -- Make the status window current so `:vertical resize` targets it.
    vim.api.nvim_set_current_win(win)

    local expected_divider = ("─"):rep(math.max(24, 40 - 6))
    local function divider_matches()
      local lines = buffer_lines(buf)
      return (lines[4] or "") == expected_divider
    end

    -- Trigger the REAL user path: `:vertical resize` fires WinResized with
    -- v:event.windows listing the resized windows.
    vim.cmd("vertical resize 40")

    -- The handler is global, so the real event reaches it even when the
    -- status window is not current. Only if this runner never delivers the
    -- event, fire it manually (no buffer filter) and record which path won.
    local delivered_via = "real WinResized"
    if not vim.wait(1000, divider_matches, 10) then
      delivered_via = "nvim_exec_autocmds fallback"
      vim.api.nvim_exec_autocmds("WinResized", {})
      vim.wait(1000, divider_matches, 10)
    end

    assert.truthy(divider_matches(), "banner did not redraw (delivered via " .. delivered_via .. ")")

    local lines = buffer_lines(buf)
    assert.equal(expected_divider, lines[4], "divider must track the new window width")

    -- Logo rows keep one shared left grid (no shear) and stay centered for
    -- the new width: padding = floor((width - logo_width) / 2), measured
    -- against the widest row, computed from the rendered lines.
    local logo_width = 0
    for i = 1, 3 do
      logo_width = math.max(logo_width, vim.fn.strdisplaywidth(vim.trim(lines[i])))
    end

    local pads = {}
    for i = 1, 3 do
      pads[i] = #(lines[i]:match("^ *") or "")
    end
    assert.truthy(pads[1] == pads[2] and pads[2] == pads[3], "resized banner rows must not shear")

    local expected_pad = math.floor((40 - logo_width) / 2)
    for i = 1, 3 do
      assert.equal(expected_pad, pads[i], "logo row " .. i .. " must be centered for width 40")
    end
  end)
end)
