-- status.diff_preview: file diffs render in a separate window that follows
-- the cursor, instead of expanding hunks inline in the status buffer.
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

  local fd = assert(io.open(dir .. "/tracked.txt", "w"))
  fd:write("one\n")
  fd:close()
  run("add", "tracked.txt")
  run("commit", "-qm", "init")

  fd = assert(io.open(dir .. "/tracked.txt", "a"))
  fd:write("two\n")
  fd:close()

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

local function buffer_text(handle)
  return table.concat(vim.api.nvim_buf_get_lines(handle, 0, -1, false), "\n")
end

neogit.setup { filewatcher = { enabled = false }, disable_context_highlighting = true }

describe("status diff_preview", function()
  after_each(function()
    require("neogit.buffers.diff_preview").close()
    config.values.status.diff_preview = { enabled = false, kind = "vsplit", debounce = 200 }
  end)

  it("validates the config shape", function()
    config.values.status.diff_preview = { enabled = true, kind = "floating", debounce = 100 }
    assert.truthy(vim.tbl_count(config.validate_config()) > 0, "float kind must be rejected")

    config.values.status.diff_preview = { enabled = "yes", debounce = "soon" }
    assert.truthy(vim.tbl_count(config.validate_config()) > 0, "types must be checked")

    config.values.status.diff_preview = { enabled = true, kind = "split", debounce = 100 }
    assert.equal(0, vim.tbl_count(config.validate_config()))
  end)

  it("previews the file under the cursor without stealing focus", function()
    config.values.status.diff_preview = { enabled = true, kind = "vsplit", debounce = 50 }
    local dir = workdir()
    local buf = open_status(dir)

    -- find the unstaged item line and move the cursor onto it
    local lines = vim.api.nvim_buf_get_lines(buf.buffer.handle, 0, -1, false)
    local item_line
    for i, l in ipairs(lines) do
      if l:find("tracked.txt", 1, true) then
        item_line = i
        break
      end
    end
    assert.truthy(item_line, "unstaged item not rendered")
    buf.buffer:move_cursor(item_line)
    vim.wait(60) -- let user-cursor mode settle (anchor cancel)
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf.buffer.handle })

    assert.truthy(vim.wait(5000, function()
      return require("neogit.buffers.diff_preview").is_open()
    end), "preview window must open")

    local preview = require("neogit.buffers.diff_preview")
    local text = buffer_text(preview.buffer_handle())
    assert.truthy(text:find("tracked.txt", 1, true), "preview must show the file name")
    assert.truthy(text:find("+two", 1, true), "preview must show the diff content")

    -- focus stays in the status buffer
    assert.equal(buf.buffer.handle, vim.api.nvim_get_current_buf())
  end)

  it("hides the preview when the cursor leaves the file items", function()
    config.values.status.diff_preview = { enabled = true, kind = "vsplit", debounce = 50 }
    local dir = workdir()
    local buf = open_status(dir)
    local preview = require("neogit.buffers.diff_preview")

    local lines = vim.api.nvim_buf_get_lines(buf.buffer.handle, 0, -1, false)
    local item_line, title_line
    for i, l in ipairs(lines) do
      if l:find("tracked.txt", 1, true) then
        item_line = i
      elseif l:find("Unstaged changes", 1, true) then
        title_line = i
      end
    end
    assert.truthy(item_line and title_line, "status layout incomplete")

    -- open on the file item
    buf.buffer:move_cursor(item_line)
    vim.wait(60)
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf.buffer.handle })
    assert.truthy(vim.wait(5000, function()
      return preview.is_open()
    end), "preview must open on the file item")

    -- move onto the section title (not a file item)
    buf.buffer:move_cursor(title_line)
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf.buffer.handle })
    assert.truthy(vim.wait(5000, function()
      return not preview.is_open()
    end), "preview must hide when the cursor leaves the file items")
  end)

  it("does not expand hunks inline while enabled", function()
    config.values.status.diff_preview = { enabled = true, kind = "vsplit", debounce = 50 }
    local dir = workdir()
    local buf = open_status(dir)

    local before = buffer_text(buf.buffer.handle)
    -- cursor over the file item + CursorMoved fired
    local lines = vim.api.nvim_buf_get_lines(buf.buffer.handle, 0, -1, false)
    for i, l in ipairs(lines) do
      if l:find("tracked.txt", 1, true) then
        buf.buffer:move_cursor(i)
        break
      end
    end
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf.buffer.handle })
    vim.wait(300)

    local after = buffer_text(buf.buffer.handle)
    assert.is_nil(after:find("^@@", 1), "hunk headers must not render inline")
    assert.truthy(#before > 0 and #after > 0)
  end)
end)
