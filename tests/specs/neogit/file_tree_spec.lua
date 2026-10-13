-- File sections in the status buffer always render as a diffview-style
-- directory tree (foldable directory rows, indented basename file rows).
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
  assert.truthy(
    vim.wait(10000, function()
      return fired
    end, 10),
    "refresh did not complete"
  )
  vim.wait(50)
  return buf
end

local function buffer_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf.buffer.handle, 0, -1, false), "\n")
end

neogit.setup { filewatcher = { enabled = false }, disable_context_highlighting = true }

describe("status file tree", function()
  it("renders nested directory rows with indented basename file rows by default", function()
    -- DEFAULT config: no overrides. The tree is unconditional.
    local dir = workdir()
    local buf = open_status(dir)
    local text = buffer_text(buf)

    assert.truthy(text:find("󰉋 src", 1, true), "directory row with icon + subtree count missing")
    assert.truthy(text:find("󰉋 lib/deep", 1, true), "single-child chain must merge into one row")
    assert.truthy(text:find("util%.lua", 1, false), "basename file row missing")
    assert.truthy(text:find("main%.lua", 1, false), "basename file row missing")
    assert.is_nil(text:find("src/lib/deep/util%.lua", 1, false), "full paths must not render in tree mode")
    assert.is_nil(text:find("src/%s", 1, false), "directory rows must not carry a trailing slash")

    -- The basename file row sits indented one level deeper than its
    -- directory row. Indent width counts the neo-tree style guide columns
    -- ("│ ") as well as blank ones - nested rows must carry the guide.
    local function indent_width(line)
      return vim.fn.strdisplaywidth(line:match("^[%s│]*"))
    end

    local lines = vim.split(text, "\n")
    local dir_indent, file_indent, file_line
    for _, line in ipairs(lines) do
      if not dir_indent and line:match("󰉋 src") then
        dir_indent = indent_width(line)
      elseif not file_indent and line:match("util%.lua") then
        file_indent = indent_width(line)
        file_line = line
      end
    end

    assert.truthy(dir_indent, "directory row not found")
    assert.truthy(file_indent, "file row not found")
    assert.truthy(
      file_line:match("^[%s│]*"):find("│", 1, true),
      "rows nested under a directory must render the gray indent guide line"
    )
    assert.truthy(
      file_indent > dir_indent,
      ("file row (indent %d) must be indented deeper than its directory row (indent %d)"):format(
        file_indent,
        dir_indent
      )
    )

    -- neo-tree geometry: a marker sits in the FIRST column of each
    -- 2-column block, directly under the parent row's leading glyph.
    -- Continuing siblings draw "│", the last child's own block closes with
    -- "└", and the section base column never carries a marker.
    local function prefix(line)
      return line:match("^[%s│└]*")
    end

    local lib_row, main_row
    for _, line in ipairs(lines) do
      if not lib_row and line:match("lib/deep") then
        lib_row = line
      elseif not main_row and line:match("main%.lua") then
        main_row = line
      end
    end

    assert.truthy(lib_row and main_row, "nested tree rows not found")
    assert.equals("  │ ", prefix(lib_row), "dir row: │ under its parent's icon, base column blank")
    assert.equals("  │ └ ", prefix(file_line), "nested file: ancestor │ continues, own └ closes")
    assert.equals("  └ ", prefix(main_row), "last child of a top-level dir closes with └ in its column")
  end)
end)
