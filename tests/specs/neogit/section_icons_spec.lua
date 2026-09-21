-- Section header icons and per-section colors: each status section shows a
-- nerd font icon before its title and carries its own highlight color.
local neogit = require("neogit")
local config = require("neogit.config")
local Repo = require("neogit.lib.git.repository")
local status_buf = require("neogit.buffers.status")

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

  vim.uv.fs_open(dir .. "/untracked.txt", "w", 420, function(_, fd)
    vim.uv.fs_write(fd, "x\n", nil, function()
      vim.uv.fs_close(fd)
    end)
  end)
  vim.wait(500, function()
    return vim.fn.filereadable(dir .. "/untracked.txt") == 1
  end)

  -- a commit so the Recent Commits section renders
  run("commit", "-q", "--allow-empty", "-m", "init")

  return dir
end

local function buffer_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf.buffer.handle, 0, -1, false), "\n")
end

local function wait_refreshed()
  local fired = false
  vim.api.nvim_create_autocmd("User", {
    pattern = "NeogitStatusRefreshed",
    once = true,
    callback = function()
      fired = true
    end,
  })
  assert.truthy(vim.wait(10000, function()
    return fired
  end, 10))
  vim.wait(50)
end

local function open_status(dir)
  vim.cmd.cd(dir)
  Repo.instance(dir, { autorefresh = false })
  local buf = status_buf.new(config.values, Repo.instance(dir).worktree_root, dir)
  buf:open("split")
  buf:dispatch_refresh()
  wait_refreshed()
  return buf
end

neogit.setup({ filewatcher = { enabled = false }, disable_context_highlighting = true })

describe("section header icons and colors", function()
  it("renders the configured icon before each section title", function()
    local dir = workdir()
    local buf = open_status(dir)
    local text = buffer_text(buf)

    local icons = config.values.icons.sections
    assert.truthy(text:find(icons.untracked .. " Untracked files", 1, true), "untracked icon missing")
    assert.truthy(text:find(icons.recent .. " Recent Commits", 1, true), "recent icon missing")
  end)

  it("gives each section its own highlight color", function()
    local groups = { "NeogitUntrackedfiles", "NeogitUnstagedchanges", "NeogitStagedchanges" }

    local colors = {}
    for _, name in ipairs(groups) do
      local hl_def = vim.api.nvim_get_hl(0, { name = name, link = false })
      assert.truthy(hl_def.fg, name .. " must define its own fg color")
      colors[name] = hl_def.fg
    end

    assert.is_not.equal(colors.NeogitUntrackedfiles, colors.NeogitUnstagedchanges)
    assert.is_not.equal(colors.NeogitUnstagedchanges, colors.NeogitStagedchanges)
  end)

  it("hides icons when configured as nil", function()
    local dir = workdir()

    -- disable the untracked icon
    config.values.icons.sections.untracked = nil

    local buf = open_status(dir)
    local text = buffer_text(buf)
    assert.truthy(text:find("Untracked files", 1, true), "title must still render")
    assert.is_nil(text:find("󰝒 Untracked", 1, true), "icon must be gone when nil")
  end)

  it("validates config.icons shape", function()
    config.values.icons = "not-a-table"
    local errors = config.validate_config()
    assert.truthy(vim.tbl_count(errors) > 0, "icons must be validated as a table")
    config.values.icons = { sections = { untracked = "󰝒" } }
    assert.equal(0, vim.tbl_count(config.validate_config()))
  end)
end)
