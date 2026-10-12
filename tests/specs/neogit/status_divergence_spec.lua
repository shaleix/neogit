-- Status Head Line: the divergence counters (↑N ↓M) lead the single
-- `<sync> <repo> → <branch>` line, stay clean when in sync, and `<cr>` on the
-- line opens the Repository Details buffer.
local neogit = require("neogit")
local config = require("neogit.config")
local Repo = require("neogit.lib.git.repository")
local status_buf = require("neogit.buffers.status")

local function run(dir, ...)
  local r = vim.system({ "git", "-C", dir, ... }):wait()
  assert(r.code == 0, tostring(r.stderr))
end

local function workdir()
  local dir = vim.fn.tempname()
  vim.uv.fs_mkdir(dir, 493)

  run(dir, "init", "-q", "-b", "main")
  run(dir, "config", "user.email", "t@t")
  run(dir, "config", "user.name", "t")

  local fd = assert(io.open(dir .. "/file.txt", "w"))
  fd:write("one\n")
  fd:close()
  run(dir, "add", "file.txt")
  run(dir, "commit", "-qm", "base")

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

---The Head Line: the single `<sync> <repo> → <branch>` line. The repo name is
---the worktree root's basename, so matching the branch plus the divergence
---fragments pins the line without hardcoding temp paths.
local function head_line(text)
  return text:match("[^\n]*main[^\n]*")
end

---Advance `ref` by one commit on top of HEAD~1 (a sibling of the local
---tip) that ADDS a file: the remote gains one commit with real content the
---local side lacks, without sharing the local-only tip.
local function advance_ref(dir, ref)
  local base = vim.trim(vim.system({ "git", "-C", dir, "rev-parse", "HEAD~1" }):wait().stdout)
  local tree = vim.trim(vim.system({ "git", "-C", dir, "rev-parse", base .. "^{tree}" }):wait().stdout)
  local blob = vim.trim(vim
    .system({ "git", "-C", dir, "hash-object", "-w", "--stdin" }, {
      stdin = "remote\n",
      text = true,
    })
    :wait().stdout)
  local entries = vim.system({ "git", "-C", dir, "ls-tree", tree }):wait().stdout or ""
  local new_tree = vim.trim(
    vim
      .system(
        { "git", "-C", dir, "mktree" },
        { stdin = entries .. "100644 blob " .. blob .. "\tremote.txt\n", text = true }
      )
      :wait().stdout
  )
  local oid =
    vim.system({ "git", "-C", dir, "commit-tree", new_tree, "-p", base, "-m", "remote-only" }):wait().stdout
  run(dir, "branch", "-f", ref, vim.trim(oid))
end

---Diverge the workdir: one local-only commit (ahead), one remote-only
---commit (behind).
local function diverge(dir)
  local fd = assert(io.open(dir .. "/file.txt", "a"))
  fd:write("two\n")
  fd:close()
  run(dir, "add", "file.txt")
  run(dir, "commit", "-qm", "local-only")
  run(dir, "branch", "fake-remote")
  run(dir, "branch", "--set-upstream-to=fake-remote")
  advance_ref(dir, "fake-remote")
end

neogit.setup { filewatcher = { enabled = false }, disable_context_highlighting = true }

describe("status Head Line divergence counters", function()
  it("shows ↑1 ↓1 on the Head line when ahead and behind", function()
    local dir = workdir()
    diverge(dir)

    local buf = open_status(dir)
    local text = buffer_text(buf)

    local line = head_line(text)
    assert.truthy(line and line:find("↑1", 1, true), "Head line must show ↑1:\n" .. text)
    assert.truthy(line and line:find("↓1", 1, true), "Head line must show ↓1:\n" .. text)
    -- single-line format: <sync> <repo> → <branch>, no oid/label leftovers
    assert.truthy(
      line:match("^↑1 ↓1 %S+ → main$"),
      "Head line must be '<sync> <repo> → <branch>':\n" .. line
    )
    assert.falsy(text:find("Merge:", 1, true), "the Merge row must be gone:\n" .. text)
    assert.falsy(text:find("Push:", 1, true), "the Push row must be gone:\n" .. text)
  end)

  it("shows the in-sync check mark when there is nothing to push or pull", function()
    local dir = workdir()
    run(dir, "branch", "fake-remote")
    run(dir, "branch", "--set-upstream-to=fake-remote")

    local buf = open_status(dir)
    local text = buffer_text(buf)

    local line = head_line(text)
    assert.truthy(line, "Head line must render:\n" .. text)
    assert.falsy(line:find("↑", 1, true), "in-sync Head line must not show the ahead counter:\n" .. text)
    assert.falsy(line:find("↓", 1, true), "in-sync Head line must not show the behind counter:\n" .. text)
    assert.truthy(line:find("✓", 1, true), "in-sync Head line must show the ✓ mark:\n" .. text)
    assert.truthy(
      line:match("^✓ %S+ → main$"),
      "in-sync Head line must be '✓ <repo> → <branch>':\n" .. line
    )
  end)

  it("<cr> on the Head line opens Repository Details", function()
    local dir = workdir()
    diverge(dir)
    -- tag the base commit so the details' Tag section has content
    run(dir, "tag", "-a", "v1", "-m", "tagged", "HEAD~1")

    local buf = open_status(dir)
    buf.buffer:focus()
    vim.fn.search("^↑1")
    assert.truthy(
      vim.api.nvim_get_current_line():find("↑1", 1, true),
      "cursor must sit on the Head line:\n" .. buffer_text(buf)
    )

    local actions = require("neogit.buffers.status.actions")
    actions.n_goto_file(buf)()

    local details_buf = vim.fn.bufnr("NeogitRepositoryDetails")
    assert.truthy(details_buf > 0, "<cr> on the Head line must open Repository Details")
    assert.truthy(vim.fn.win_findbuf(details_buf)[1] > 0, "Repository Details must open in a window")

    local details = table.concat(vim.api.nvim_buf_get_lines(details_buf, 0, -1, false), "\n")
    assert.truthy(details:find("Head", 1, true), "details must have a Head section:\n" .. details)
    assert.truthy(details:find("Merge", 1, true), "details must have a Merge section:\n" .. details)
    assert.truthy(details:find("Tag", 1, true), "details must have a Tag section:\n" .. details)
    assert.truthy(details:find("Divergence", 1, true), "details must have a Divergence section:\n" .. details)
    assert.truthy(details:find("↑1", 1, true), "details must show the ahead count:\n" .. details)
    assert.truthy(details:find("↓1", 1, true), "details must show the behind count:\n" .. details)
    -- both embedded diff sections render actual +/- lines
    assert.truthy(
      details:find("Unpushed changes", 1, true),
      "details must have the unpushed diff:\n" .. details
    )
    assert.truthy(
      details:find("Incoming changes", 1, true),
      "details must have the incoming diff:\n" .. details
    )
    assert.truthy(
      details:find("+two", 1, true),
      "the unpushed diff must render the local commit:\n" .. details
    )
    assert.truthy(
      details:find("+remote", 1, true),
      "the incoming diff must render the remote commit:\n" .. details
    )

    -- snapshot semantics: close the details when done
    vim.api.nvim_win_close(vim.fn.win_findbuf(details_buf)[1], false)
  end)

  it("shows Recent Commits even while the branch is ahead of upstream", function()
    local dir = workdir()
    local fd = assert(io.open(dir .. "/file.txt", "a"))
    fd:write("two\n")
    fd:close()
    run(dir, "add", "file.txt")
    run(dir, "commit", "-qm", "local-only")
    run(dir, "branch", "fake-remote")
    run(dir, "branch", "--set-upstream-to=fake-remote")

    local buf = open_status(dir)
    local text = buffer_text(buf)

    assert.truthy(text:find("Recent Commits", 1, true), "Recent Commits must render while ahead:\n" .. text)
    assert.truthy(text:match("%* %x+ t local%-only"), "the ahead commit must be listed:\n" .. text)
  end)
end)
