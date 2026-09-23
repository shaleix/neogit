-- status.file_tree: diffview-style directory tree for the file sections.
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

  local function write(p, c)
    vim.fn.mkdir(vim.fs.dirname(dir .. "/" .. p), "p")
    local fd = assert(io.open(dir .. "/" .. p, "w"))
    fd:write(c)
    fd:close()
  end

  write("root.txt", "a\n")
  run("add", ".")
  run("commit", "-qm", "init")

  write("src/lib/deep/util.lua", "b\n")
  write("src/main.lua", "c\n")
  write("root.txt", "a\nb\n")

  return dir
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
  assert.truthy(vim.wait(10000, function()
    return fired
  end, 10), "refresh did not complete")
  vim.wait(50)
  return buf
end

local function buffer_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf.buffer.handle, 0, -1, false), "\n")
end

neogit.setup { filewatcher = { enabled = false }, disable_context_highlighting = true }

describe("status file_tree", function()
  after_each(function()
    config.values.status.file_tree = false
  end)

  it("renders nested directory rows with counts and basename file rows", function()
    config.values.status.file_tree = true
    local dir = workdir()
    local buf = open_status(dir)
    local text = buffer_text(buf)

    assert.truthy(text:find("󰉋 src", 1, true), "directory row with icon + subtree count missing")
    assert.truthy(text:find("󰉋 lib/deep", 1, true), "single-child chain must merge into one row")
    assert.truthy(text:find("util%.lua", 1, false), "basename file row missing")
    assert.truthy(text:find("main%.lua", 1, false), "basename file row missing")
    assert.is_nil(text:find("src/lib/deep/util%.lua", 1, false), "full paths must not render in tree mode")
    assert.is_nil(text:find("src/%s", 1, false), "directory rows must not carry a trailing slash")
  end)

  it("renders flat file paths when disabled", function()
    config.values.status.file_tree = false
    local dir = workdir()
    local buf = open_status(dir)
    local text = buffer_text(buf)

    assert.truthy(text:find("src/lib/deep/util%.lua", 1, false), "flat mode must keep full paths")
    assert.is_nil(text:find("src %(2%)", 1, true), "directory rows must not render in flat mode")
  end)

  it("validates the config shape", function()
    config.values.status.file_tree = "yes"
    assert.truthy(vim.tbl_count(config.validate_config()) > 0, "file_tree must be a boolean")

    config.values.status.file_tree = true
    assert.equal(0, vim.tbl_count(config.validate_config()))
  end)
end)
