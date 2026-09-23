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

---Wait until the preview window exists and its buffer contains the given
---literal text.
local function wait_for_content(preview, needle, timeout)
  return vim.wait(timeout or 5000, function()
    local handle = preview.buffer_handle()
    return handle ~= nil and buffer_text(handle):find(needle, 1, true) ~= nil
  end, 20)
end

---Create a git wrapper that logs every invocation and sleeps `delay`
---seconds before running the real git, but only when the command mentions
---`slow_file` (pass an empty string to never delay). Returns the wrapper
---path and the log path.
local function slow_git(slow_file, delay)
  local log = vim.fn.tempname()
  local wrapper = vim.fn.tempname()
  local fd = assert(io.open(wrapper, "w"))
  fd:write(([[
#!/bin/sh
echo "$@" >> %s
for a in "$@"; do
  [ "$a" = "%s" ] && sleep %d
done
exec %s "$@"
]]):format(log, slow_file, delay, vim.fn.exepath("git")))
  fd:close()
  vim.fn.setfperm(wrapper, "rwxr-xr-x")
  return wrapper, log
end

---Count logged git invocations that are diff commands for the given file.
local function count_diff_calls(log, file)
  local calls = 0
  for line in io.lines(log) do
    if line:find(" diff ", 1, true) and line:find(file, 1, true) then
      calls = calls + 1
    end
  end
  return calls
end

---Move the status buffer cursor onto the line containing `needle` and fire
---CursorMoved.
local function cursor_onto(buf, needle)
  local lines = vim.api.nvim_buf_get_lines(buf.buffer.handle, 0, -1, false)
  local found
  for i, l in ipairs(lines) do
    if l:find(needle, 1, true) then
      found = i
      buf.buffer:move_cursor(i)
      break
    end
  end
  assert.truthy(found, ("status buffer has no line containing %q"):format(needle))

  -- let user-cursor mode settle (anchor cancel) before simulating the move
  vim.wait(60)
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf.buffer.handle })
end

neogit.setup { filewatcher = { enabled = false }, disable_context_highlighting = true }

describe("status diff_preview", function()
  local original_git = config.values.git_executable

  after_each(function()
    require("neogit.buffers.diff_preview").close()
    config.values.status.diff_preview = { enabled = false, kind = "vsplit", debounce = 200 }
    config.values.git_executable = original_git
  end)

  it("validates the config shape", function()
    config.values.status.diff_preview = { enabled = true, kind = "floating", debounce = 100 }
    assert.truthy(vim.tbl_count(config.validate_config()) > 0, "float kind must be rejected")

    config.values.status.diff_preview = { enabled = "yes", debounce = "soon" }
    assert.truthy(vim.tbl_count(config.validate_config()) > 0, "types must be checked")

    config.values.status.diff_preview = { enabled = true, kind = "split", debounce = 100, content = "not-a-fn" }
    assert.truthy(vim.tbl_count(config.validate_config()) > 0, "content must be a function")

    config.values.status.diff_preview = { enabled = true, kind = "split", debounce = 100, content = function() end }
    assert.equal(0, vim.tbl_count(config.validate_config()))
  end)

  it("previews the file under the cursor without stealing focus", function()
    config.values.status.diff_preview = { enabled = true, kind = "vsplit", debounce = 50 }
    local dir = workdir()
    local buf = open_status(dir)
    local preview = require("neogit.buffers.diff_preview")

    cursor_onto(buf, "tracked.txt")

    assert.truthy(vim.wait(5000, function()
      return preview.is_open()
    end), "preview window must open")

    assert.truthy(wait_for_content(preview, "+two"), "diff content must render")
    local text = buffer_text(preview.buffer_handle())
    assert.truthy(text:find("tracked.txt", 1, true), "preview must show the file name")

    -- focus stays in the status buffer
    assert.equal(buf.buffer.handle, vim.api.nvim_get_current_buf())
  end)

  it("hides the preview when the cursor leaves the file items", function()
    config.values.status.diff_preview = { enabled = true, kind = "vsplit", debounce = 50 }
    local dir = workdir()
    local buf = open_status(dir)
    local preview = require("neogit.buffers.diff_preview")

    -- open on the file item
    cursor_onto(buf, "tracked.txt")
    assert.truthy(vim.wait(5000, function()
      return preview.is_open()
    end), "preview must open on the file item")

    -- move onto the section title (not a file item)
    local lines = vim.api.nvim_buf_get_lines(buf.buffer.handle, 0, -1, false)
    local title_line
    for i, l in ipairs(lines) do
      if l:find("Unstaged changes", 1, true) then
        title_line = i
        break
      end
    end
    assert.truthy(title_line, "status layout incomplete")

    buf.buffer:move_cursor(title_line)
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf.buffer.handle })
    assert.truthy(vim.wait(5000, function()
      return not preview.is_open()
    end), "preview must hide when the cursor leaves the file items")
  end)

  it("renders custom content from diff_preview.content with its filetype", function()
    config.values.status.diff_preview = {
      enabled = true,
      kind = "vsplit",
      debounce = 50,
      content = function(item, section)
        assert.truthy(item.name, "content callback must receive the item")
        return {
          filetype = "diff",
          lines = { "diff --git a/" .. item.name, "+++ custom line", "section: " .. section },
        }
      end,
    }
    local dir = workdir()
    local buf = open_status(dir)

    cursor_onto(buf, "tracked.txt")

    local preview = require("neogit.buffers.diff_preview")
    assert.truthy(vim.wait(5000, function()
      return preview.is_open()
    end), "preview must open")

    local handle = preview.buffer_handle()
    assert.equal("diff", vim.bo[handle].filetype, "custom filetype must be applied")
    local text = table.concat(vim.api.nvim_buf_get_lines(handle, 0, -1, false), "\n")
    assert.truthy(text:find("+++ custom line", 1, true), "custom lines must render")
    assert.truthy(text:find("section: unstaged", 1, true), "section must be passed through")
  end)

  it("falls back to the built-in renderer when content returns nil", function()
    config.values.status.diff_preview = {
      enabled = true,
      kind = "vsplit",
      debounce = 50,
      content = function()
        return nil
      end,
    }
    local dir = workdir()
    local buf = open_status(dir)

    cursor_onto(buf, "tracked.txt")

    local preview = require("neogit.buffers.diff_preview")
    assert.truthy(vim.wait(5000, function()
      return preview.is_open()
    end), "preview must open")

    local handle = preview.buffer_handle()
    assert.equal("NeogitDiffPreview", vim.bo[handle].filetype, "built-in filetype must be kept")
    assert.truthy(wait_for_content(preview, "+two"), "built-in diff must render")
  end)

  it("does not expand hunks inline while enabled", function()
    config.values.status.diff_preview = { enabled = true, kind = "vsplit", debounce = 50 }
    local dir = workdir()
    local buf = open_status(dir)

    local before = buffer_text(buf.buffer.handle)
    -- cursor over the file item + CursorMoved fired
    cursor_onto(buf, "tracked.txt")
    vim.wait(300)

    local after = buffer_text(buf.buffer.handle)
    assert.is_nil(after:find("^@@", 1), "hunk headers must not render inline")
    assert.truthy(#before > 0 and #after > 0)
  end)

  describe("preview width", function()
    local preview = require("neogit.buffers.diff_preview")

    local function open_and_measure(width_config)
      config.values.status.diff_preview = {
        enabled = true,
        kind = "vsplit",
        debounce = 50,
        width = width_config,
      }
      local dir = workdir()
      local buf = open_status(dir)

      cursor_onto(buf, "tracked.txt")
      assert.truthy(vim.wait(5000, function()
        return preview.is_open()
      end), "preview must open")

      local handle = preview.buffer_handle()
      return vim.api.nvim_win_get_width(vim.fn.bufwinid(handle))
    end

    after_each(function()
      preview.close()
    end)

    it("defaults to 50% on narrow editors and 60% on wide ones", function()
      local resolve = preview.internal.preview_width
      assert.equal(40, resolve(80, {}), "80 columns -> 40 (50%)")
      assert.equal(60, resolve(120, {}), "120 columns -> 60 (50%, threshold not exceeded)")
      assert.equal(72, resolve(121, {}), "121 columns -> 72 (60%)")
      assert.equal(96, resolve(160, {}), "160 columns -> 96 (60%)")
    end)

    it("accepts a fixed number", function()
      local w = open_and_measure(30)
      assert.equal(30, w)
    end)

    it("accepts a callback receiving the editor width", function()
      local seen
      local w = open_and_measure(function(columns)
        seen = columns
        return 25
      end)
      assert.equal(25, w)
      assert.equal(vim.o.columns, seen, "callback must receive the editor width")
    end)

    it("clamps absurd widths so the status buffer survives", function()
      local w = open_and_measure(10000)
      assert.truthy(w <= vim.o.columns - 10, ("clamped: %d"):format(w))
    end)
  end)

  it("scrolls the preview split with C-d/C-u from the status buffer", function()
    -- build a long diff so the preview actually scrolls
    local dir = workdir()
    do
      local fd = assert(io.open(dir .. "/tracked.txt", "a"))
      for i = 1, 200 do
        fd:write(("line %d\n"):format(i))
      end
      fd:close()
    end

    config.values.status.diff_preview = { enabled = true, kind = "vsplit", debounce = 50 }
    local buf = open_status(dir)

    cursor_onto(buf, "tracked.txt")

    local preview = require("neogit.buffers.diff_preview")
    assert.truthy(vim.wait(5000, function()
      return preview.is_open()
    end), "preview must open")
    assert.truthy(
      wait_for_content(preview, "+line 5"),
      "diff content must render before scrolling"
    )

    local win = vim.fn.bufwinid(preview.buffer_handle())
    assert.truthy(win ~= -1, "preview window must exist")

    local top = function()
      return vim.api.nvim_win_call(win, function()
        return vim.fn.line("w0")
      end)
    end

    local before = top()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-d>", true, false, true), "x", false)
    vim.wait(100)
    assert.truthy(top() > before, ("C-d must scroll the preview down (before=%d after=%d)"):format(before, top()))

    local mid = top()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-u>", true, false, true), "x", false)
    vim.wait(100)
    assert.truthy(top() < mid, "C-u must scroll the preview back up")

    -- cursor stays in the status buffer throughout
    assert.equal(buf.buffer.handle, vim.api.nvim_get_current_buf())
  end)

  it("opens with a loading placeholder instead of blocking on a slow diff", function()
    local wrapper = slow_git("tracked.txt", 1)
    config.values.git_executable = wrapper

    config.values.status.diff_preview = { enabled = true, kind = "vsplit", debounce = 50 }
    local dir = workdir()
    local buf = open_status(dir)
    local preview = require("neogit.buffers.diff_preview")

    cursor_onto(buf, "tracked.txt")

    -- the window opens right away, while the (sleeping) git diff is still
    -- running: the deferred callback cannot have waited for the process
    assert.truthy(vim.wait(1000, function()
      return preview.is_open()
    end), "preview window must open before the slow diff completes")
    assert.truthy(
      buffer_text(preview.buffer_handle()):find("Loading diff", 1, true),
      "placeholder must be visible while the diff loads"
    )

    -- and the real content renders once the process finishes
    assert.truthy(
      wait_for_content(preview, "+two", 10000),
      "diff content must render after the slow diff completes"
    )
  end)

  it("switches to the next file's diff while a slow load is in flight", function()
    local wrapper = slow_git("slow.txt", 1)
    config.values.git_executable = wrapper

    -- two untracked files: slow.txt's diff sleeps inside the wrapper,
    -- fast.txt's returns immediately
    local dir = workdir()
    do
      local fd = assert(io.open(dir .. "/slow.txt", "w"))
      fd:write("slow content\n")
      fd:close()
      fd = assert(io.open(dir .. "/fast.txt", "w"))
      fd:write("fast content\n")
      fd:close()
    end

    config.values.status.diff_preview = { enabled = true, kind = "vsplit", debounce = 50 }
    local buf = open_status(dir)
    local preview = require("neogit.buffers.diff_preview")

    cursor_onto(buf, "slow.txt")
    assert.truthy(vim.wait(1000, function()
      return preview.is_open()
    end), "preview must open on the slow item")
    assert.truthy(
      buffer_text(preview.buffer_handle()):find("Loading diff", 1, true),
      "slow item shows the placeholder"
    )

    -- move onto fast.txt while slow.txt's diff is still loading
    cursor_onto(buf, "fast.txt")
    assert.truthy(
      wait_for_content(preview, "+fast content", 5000),
      "fast item's diff must render while the slow load was in flight"
    )

    -- the slow diff completes (or is cancelled) without ever overwriting
    -- the fast item's content
    vim.wait(1500)
    local text = buffer_text(preview.buffer_handle())
    assert.truthy(text:find("+fast content", 1, true), "fast diff must stay rendered")
    assert.is_nil(text:find("+slow content", 1, true), "stale slow diff must not render")
  end)

  it("fetches each item's diff once, reusing the cache on revisit", function()
    local wrapper, log = slow_git("", 0)
    config.values.git_executable = wrapper

    -- a second file so the cursor can move away and back
    local dir = workdir()
    do
      local fd = assert(io.open(dir .. "/other.txt", "w"))
      fd:write("other content\n")
      fd:close()
    end

    config.values.status.diff_preview = { enabled = true, kind = "vsplit", debounce = 50 }
    local buf = open_status(dir)
    local preview = require("neogit.buffers.diff_preview")

    cursor_onto(buf, "tracked.txt")
    assert.truthy(
      wait_for_content(preview, "+two"),
      "diff content must render"
    )
    local initial_calls = count_diff_calls(log, "tracked.txt")
    assert.truthy(initial_calls > 0, "tracked.txt diff must have been fetched")

    -- more cursor movement within the same item: no refetch, no re-render
    for _ = 1, 3 do
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf.buffer.handle })
      vim.wait(100)
    end

    -- move away to another file and back: the cached diff renders without
    -- a new git invocation
    cursor_onto(buf, "other.txt")
    assert.truthy(
      wait_for_content(preview, "+other content"),
      "other item's diff must render"
    )
    cursor_onto(buf, "tracked.txt")
    assert.truthy(
      wait_for_content(preview, "+two"),
      "cached diff must render on revisit"
    )

    assert.equal(
      initial_calls,
      count_diff_calls(log, "tracked.txt"),
      "tracked.txt diff must not be refetched for same-item moves or revisits"
    )
  end)
end)
