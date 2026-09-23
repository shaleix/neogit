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

  -- a typed file so the file-type icon is exercised
  vim.uv.fs_open(dir .. "/script.lua", "w", 420, function(_, fd)
    vim.uv.fs_write(fd, "return\n", nil, function()
      vim.uv.fs_close(fd)
    end)
  end)
  vim.wait(500, function()
    return vim.fn.filereadable(dir .. "/script.lua") == 1
  end)

  -- a commit so the Recent Commits section renders
  run("commit", "-q", "--allow-empty", "-m", "init")

  return dir
end

-- Upstream divergence: one local-only commit and one remote-only commit, so
-- both "Unmerged into" (outgoing) and "Unpulled from" (incoming) render.
local function workdir_diverged()
  local dir = workdir()
  local function run(...)
    local r = vim.system({ "git", "-C", dir, ... }):wait()
    assert(r.code == 0, tostring(r.stderr))
  end

  local remote = dir .. "-origin.git"
  run("init", "-q", "--bare", "-b", "main", remote)
  run("remote", "add", "origin", remote)
  run("push", "-q", "-u", "origin", "main")

  -- remote-only commit (behind upstream), authored from a scratch clone so we
  -- never push into dir's checked-out branch; cloned before the local-only
  -- commit so the two histories genuinely diverge
  local clone = dir .. "-clone"
  local r = vim.system({ "git", "clone", "-q", dir, clone }):wait()
  assert(r.code == 0, tostring(r.stderr))
  local function run_clone(...)
    local cr = vim.system({ "git", "-C", clone, ... }):wait()
    assert(cr.code == 0, tostring(cr.stderr))
  end
  run_clone("config", "user.email", "t@t")
  run_clone("config", "user.name", "t")
  run_clone("commit", "-q", "--allow-empty", "-m", "remote-only")
  run_clone("push", "-q", remote, "main")
  run("fetch", "-q", "origin")

  -- local-only commit (ahead of upstream)
  run("commit", "-q", "--allow-empty", "-m", "local-only")

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

neogit.setup { filewatcher = { enabled = false }, disable_context_highlighting = true }

describe("section header icons and colors", function()
  it("renders the configured icon before each section title", function()
    local dir = workdir()
    local buf = open_status(dir)
    local text = buffer_text(buf)

    local icons = config.values.icons.sections
    assert.truthy(text:find(icons.untracked .. " Untracked files", 1, true), "untracked icon missing")
    assert.truthy(text:find(icons.recent .. " Recent Commits", 1, true), "recent icon missing")
  end)

  it("renders upload/download icons on remote sections", function()
    local dir = workdir_diverged()
    local buf = open_status(dir)
    local text = buffer_text(buf)

    local icons = config.values.icons.sections
    assert.truthy(text:find(icons.unmerged .. " Unmerged into", 1, true), "unmerged (upload) icon missing")
    assert.truthy(text:find(icons.unpulled .. " Unpulled from", 1, true), "unpulled (download) icon missing")
  end)

  it("renders the single-letter mode column with file-type icons", function()
    local dir = workdir()
    local buf = open_status(dir)
    local text = buffer_text(buf)

    -- mode column: pad_right(mode, max_length(values) + mode_padding)
    local mode_text = config.values.status.mode_text
    local width = math.max(unpack(vim.tbl_values(vim.tbl_map(function(v)
      return #v
    end, mode_text)))) + config.values.status.mode_padding

    local file_icons = (config.values.icons and config.values.icons.file_icons) or {}
    local q = mode_text["?"] .. string.rep(" ", width - #mode_text["?"])
    assert.truthy(
      text:find("  " .. q .. file_icons.txt .. " untracked.txt", 1, true),
      "untracked mode letter + txt file icon missing"
    )
    assert.truthy(
      text:find("  " .. q .. file_icons.lua .. " script.lua", 1, true),
      "lua file-type icon missing"
    )
    assert.is_nil(text:find("modified", 1, true), "full-word mode text must be gone from defaults")
  end)

  it("paints staged items green end-to-end (letter, icon, name)", function()
    local dir = workdir()
    local r = vim.system({ "git", "-C", dir, "add", "script.lua" }):wait()
    assert(r.code == 0, tostring(r.stderr))

    local buf = open_status(dir)
    local handle = buf.buffer.handle
    local lines = vim.api.nvim_buf_get_lines(handle, 0, -1, false)

    local staged_line
    for i, l in ipairs(lines) do
      if l:find("script.lua", 1, true) and l:match("^  A") then
        staged_line = i - 1
      end
    end
    assert.truthy(staged_line, "staged script.lua line not found")

    local marks = vim.api.nvim_buf_get_extmarks(handle, -1, { staged_line, 0 }, { staged_line, -1 }, { details = true })
    local staged_groups = 0
    for _, m in ipairs(marks) do
      local d = m[4] or {}
      if d.hl_group == "NeogitChangeAstaged" then
        staged_groups = staged_groups + 1
      end
    end
    assert.truthy(staged_groups >= 3, "letter + icon + name must all carry the staged green group")
  end)

  it("colors mode letters by change state (lazygit-style)", function()
    local function fg_of(name)
      local def = vim.api.nvim_get_hl(0, { name = name, link = false })
      assert.truthy(def.fg, name .. " must define its own fg")
      return def.fg
    end

    local function channels(fg)
      return math.floor(fg / 65536) % 256, math.floor(fg / 256) % 256, fg % 256
    end

    -- staged: uniform green, no bold
    for _, name in ipairs { "NeogitChangeMstaged", "NeogitChangeDstaged", "NeogitChangeRstaged" } do
      local r, g, b = channels(fg_of(name))
      assert.truthy(g > r and g > b, name .. " must be green-dominant")
      local def = vim.api.nvim_get_hl(0, { name = name, link = false })
      assert.is_nil(def.bold, name .. " must not be bold")
    end
    assert.equal(fg_of("NeogitChangeMstaged"), fg_of("NeogitChangeDstaged"), "staged colors must be uniform")

    -- unstaged + untracked: uniform red
    for _, name in ipairs {
      "NeogitChangeMunstaged",
      "NeogitChangeDunstaged",
      "NeogitChangeUntrackeduntracked",
    } do
      local r, g, b = channels(fg_of(name))
      assert.truthy(r > g and r > b, name .. " must be red-dominant")
    end
    assert.equal(
      fg_of("NeogitChangeMunstaged"),
      fg_of("NeogitChangeUntrackeduntracked"),
      "unstaged and untracked letters share the state red"
    )
  end)

  it("shows modified and new files in green tones", function()
    local function channels(name)
      local def = vim.api.nvim_get_hl(0, { name = name, link = false })
      assert.truthy(def.fg, name .. " must define its own fg")
      local r = math.floor(def.fg / 65536) % 256
      local g = math.floor(def.fg / 256) % 256
      local b = def.fg % 256
      return r, g, b
    end

    -- the base groups stay green (compat reference for user overrides)
    for _, name in ipairs {
      "NeogitChangeModified",
      "NeogitChangeNewFile",
      "NeogitChangeMstaged",
    } do
      local r, g, b = channels(name)
      assert.truthy(g > r and g > b, name .. " must be green-dominant")
    end

    -- same family, still distinguishable
    local mod = vim.api.nvim_get_hl(0, { name = "NeogitChangeModified", link = false }).fg
    local new = vim.api.nvim_get_hl(0, { name = "NeogitChangeNewFile", link = false }).fg
    assert.is_not.equal(mod, new)
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

  it("prefers nvim-web-devicons when available", function()
    -- mock the plugin; reset the module-level resolution cache first
    package.preload["nvim-web-devicons"] = function()
      return {
        get_icon = function(name, ext, opts)
          if name == "script.lua" then
            return "*", "DevIconLua"
          end
          return nil
        end,
      }
    end

    local ui = require("neogit.buffers.status.ui")
    ui.reset_devicons_cache()

    local dir = workdir()
    local buf = open_status(dir)
    local text = buffer_text(buf)

    package.preload["nvim-web-devicons"] = nil
    package.loaded["nvim-web-devicons"] = nil
    ui.reset_devicons_cache()

    assert.truthy(text:find("%* script%.lua", 1, false), "devicons-provided icon must render")
  end)

  it("falls back to the builtin table without devicons", function()
    local ui = require("neogit.buffers.status.ui")
    ui.reset_devicons_cache()

    local dir = workdir()
    local buf = open_status(dir)
    local text = buffer_text(buf)

    local file_icons = config.values.icons.file_icons
    assert.truthy(text:find(file_icons.lua .. " script%.lua", 1, false), "builtin lua icon must render")
    assert.truthy(text:find(file_icons.txt .. " untracked%.txt", 1, false), "builtin txt icon must render")
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
