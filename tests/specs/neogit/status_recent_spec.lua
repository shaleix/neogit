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

local function commit_as(dir, name, msg)
  run(
    dir,
    "-c",
    ("user.name=%s"):format(name),
    "-c",
    "user.email=t@t",
    "commit",
    "-q",
    "--allow-empty",
    "-m",
    msg
  )
end

local function workdir()
  local dir = vim.fn.tempname()
  vim.uv.fs_mkdir(dir, 493)

  run(dir, "init", "-q", "-b", "main")
  run(dir, "config", "user.email", "t@t")
  run(dir, "config", "user.name", "t")

  commit_as(dir, "shaleix", "linear one")
  commit_as(dir, "shaleix", "linear two")

  -- diverge a side branch and merge it back: one merge commit with two
  -- parents, authored by someone else
  run(dir, "switch", "-q", "-c", "side")
  commit_as(dir, "alice", "side work")
  run(dir, "switch", "-q", "main")
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
end)
