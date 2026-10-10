-- Recent Commits rows: git-history-style star prefixes, hash followed by
-- the author's first two characters, no date, everything left-aligned.
local neogit = require("neogit")
local config = require("neogit.config")
local Repo = require("neogit.lib.git.repository")
local status_buf = require("neogit.buffers.status")

local function run(dir, ...)
  local r = vim.system({ "git", "-C", dir, ... }):wait()
  assert(r.code == 0, tostring(r.stderr))
end

local function write(dir, path, content)
  local fd = assert(io.open(dir .. "/" .. path, "w"))
  fd:write(content)
  fd:close()
end

local function commit_as(dir, name, msg)
  run(dir, "add", "-A")
  run(dir, "-c", ("user.name=%s"):format(name), "-c", "user.email=t@t", "commit", "-q", "-m", msg)
end

local function workdir()
  local dir = vim.fn.tempname()
  vim.uv.fs_mkdir(dir, 493)

  run(dir, "init", "-q", "-b", "main")
  run(dir, "config", "user.email", "t@t")
  run(dir, "config", "user.name", "t")

  write(dir, "a.txt", "one\n")
  commit_as(dir, "shaleix", "linear one")
  write(dir, "a.txt", "one\ntwo\n")
  commit_as(dir, "shaleix", "linear two")

  -- diverge a side branch and merge it back: one merge commit with two
  -- parents, authored by someone else
  run(dir, "switch", "-q", "-c", "side")
  write(dir, "b.txt", "side\n")
  commit_as(dir, "alice", "side work")
  run(dir, "switch", "-q", "main")
  write(dir, "a.txt", "one\ntwo\nthree\n")
  commit_as(dir, "shaleix", "mainline while side exists")
  run(
    dir,
    "-c",
    "user.name=shaleix",
    "-c",
    "user.email=t@t",
    "merge",
    "-q",
    "--no-ff",
    "-m",
    "merge side",
    "side"
  )

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

neogit.setup { filewatcher = { enabled = false }, disable_context_highlighting = true }

describe("status Recent Commits rows", function()
  it("renders star-prefixed rows with author initials after the hash", function()
    local dir = workdir()
    local buf = open_status(dir)
    local text = table.concat(vim.api.nvim_buf_get_lines(buf.buffer.handle, 0, -1, false), "\n")

    -- linear commits: "* <hash> sh <subject>"
    local linear = text:match("%* (%x+) (sh) linear two\n")
    assert.truthy(linear, "linear row must match '* <hash> sh linear two':\n" .. text)

    -- merge commit (two parents): fan-out prefix
    assert.truthy(
      text:match("%*─╮ (%x+) (sh) merge side\n"),
      "merge row must use the fan-out prefix:\n" .. text
    )

    -- merged-in side commit carries the other author's initials
    assert.truthy(text:match("%* (%x+) (al) side work\n"), "side commit must show 'al':\n" .. text)

    -- rows stay left-aligned: no author/date right-margin text bleeds in
    assert.falsy(text:match("[^\n]*ago"), "no relative dates may render:\n" .. text)
  end)

  it("previews the commit diff when the cursor rests on a recent row", function()
    local dir = workdir()
    config.values.sections.recent.folded = false
    config.values.status.diff_preview = { enabled = true, kind = "split", debounce = 50 }

    local buf = open_status(dir)
    buf.buffer:focus()
    vim.fn.search("linear two")

    -- drive the preview hook exactly like CursorMoved does
    buf:_preview_diff_under_cursor()

    local preview = require("neogit.buffers.diff_preview")
    local ready = vim.wait(10000, function()
      local handle = preview.buffer_handle()
      if not handle then
        return false
      end
      local text = table.concat(vim.api.nvim_buf_get_lines(handle, 0, -1, false), "\n")
      return text:find("+two", 1, true) ~= nil
    end, 20)
    assert.truthy(ready, "preview must show the commit's diff (+two)")

    local handle = preview.buffer_handle()
    local final_text = table.concat(vim.api.nvim_buf_get_lines(handle, 0, -1, false), "\n")
    assert.truthy(
      final_text:find("linear two", 1, true),
      "preview header must carry the commit subject:\n" .. final_text
    )
    assert.falsy(final_text:find("\27", 1, true), "preview must be free of ANSI color codes")

    config.values.sections.recent.folded = true
    config.values.status.diff_preview = nil
  end)
end)
