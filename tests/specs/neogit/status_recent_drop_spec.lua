-- x (n_discard) on a Recent Commits row drops the commit under the cursor
-- after confirmation. Guards the commit-row resolution contract: recent rows
-- carry the raw `{ commit = ... }` item (ui SectionItemRecent), so the OID and
-- the merge check must come from selection.item.commit. Connector Rows and
-- section headers hold no item and must stay no-ops; a visual selection over
-- commits alone must not prompt.
local neogit = require("neogit")
local config = require("neogit.config")
local Repo = require("neogit.lib.git.repository")
local status_buf = require("neogit.buffers.status")
local actions = require("neogit.buffers.status.actions")
local input = require("neogit.lib.input")
local git = require("neogit.lib.git")

local function run(dir, ...)
  local r = vim.system({ "git", "-C", dir, ... }):wait()
  assert(r.code == 0, tostring(r.stderr))
end

local function commit(dir, message)
  run(dir, "commit", "--allow-empty", "-qm", message)
end

local function head_oid(dir)
  local r = vim.system({ "git", "-C", dir, "rev-parse", "HEAD" }):wait()
  return vim.trim(r.stdout)
end

local function oid_of(dir, subject)
  local r = vim.system({ "git", "-C", dir, "log", "--format=%H %s" }):wait()
  for line in (r.stdout or ""):gmatch("[^\r\n]+") do
    local oid, s = line:match("^(%x+) (.+)$")
    if s == subject then
      return oid
    end
  end
  error("no commit with subject " .. subject)
end

local function subjects(dir)
  local r = vim.system({ "git", "-C", dir, "log", "--format=%s" }):wait()
  local out = {}
  for line in (r.stdout or ""):gmatch("[^\r\n]+") do
    table.insert(out, line)
  end
  return out
end

local function workdir()
  local dir = vim.fn.tempname()
  vim.uv.fs_mkdir(dir, 493)

  run(dir, "init", "-q", "-b", "main")
  run(dir, "config", "user.email", "t@t")
  run(dir, "config", "user.name", "t")

  commit(dir, "aaa-init")
  commit(dir, "bbb-middle")
  commit(dir, "ccc-top")

  return dir
end

local function workdir_with_merge()
  local dir = vim.fn.tempname()
  vim.uv.fs_mkdir(dir, 493)

  run(dir, "init", "-q", "-b", "main")
  run(dir, "config", "user.email", "t@t")
  run(dir, "config", "user.name", "t")

  commit(dir, "aaa-init")
  run(dir, "checkout", "-q", "-b", "side", "HEAD")
  commit(dir, "side-work")
  run(dir, "checkout", "-q", "main")
  run(dir, "merge", "-q", "--no-ff", "side", "-m", "merge-them")
  commit(dir, "after-merge")

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

---Stub the confirmation; asked collects the prompts, answer decides confirm
---vs cancel. Returns the restore function.
local function stub_confirm(asked, answer)
  local original = input.get_permission
  input.get_permission = function(msg)
    table.insert(asked, msg)
    return answer
  end
  return function()
    input.get_permission = original
  end
end

---Stub git.rebase.drop; dropped collects the OIDs. The git-side rewrite
---itself is covered by the rebase drop smoke tests.
local function stub_drop(dropped)
  local original = git.rebase.drop
  git.rebase.drop = function(oid)
    table.insert(dropped, oid)
  end
  return function()
    git.rebase.drop = original
  end
end

neogit.setup { filewatcher = { enabled = false }, disable_context_highlighting = true }

describe("status recent-commit drop (x)", function()
  it("drops the commit under the cursor after confirmation", function()
    local dir = workdir()
    local buf = open_status(dir)
    buf.buffer:focus()

    local asked, dropped = {}, {}
    local restore_confirm = stub_confirm(asked, true)
    local restore_drop = stub_drop(dropped)

    assert.truthy(vim.fn.search([[bbb-middle]], "w") > 0, "commit row must render")
    actions.n_discard(buf)()
    assert.truthy(
      vim.wait(10000, function()
        return #asked > 0
      end, 10),
      "confirmation must fire"
    )
    restore_confirm()
    restore_drop()

    assert.equal(1, #asked, "confirmation must be asked exactly once; " .. vim.inspect(asked))
    assert.truthy(
      asked[1] and asked[1]:find('Drop commit "bbb-middle"', 1, true),
      "confirmation must name the subject; got: " .. tostring(asked[1])
    )
    assert.same({ oid_of(dir, "bbb-middle") }, dropped, "must drop the cursor commit's full OID")
  end)

  it("cancelling the confirmation drops nothing", function()
    local dir = workdir()
    local buf = open_status(dir)
    buf.buffer:focus()

    local asked, dropped = {}, {}
    local restore_confirm = stub_confirm(asked, false)
    local restore_drop = stub_drop(dropped)

    assert.truthy(vim.fn.search([[bbb-middle]], "w") > 0, "commit row must render")
    actions.n_discard(buf)()
    assert.truthy(
      vim.wait(10000, function()
        return #asked > 0
      end, 10),
      "confirmation must fire"
    )
    restore_confirm()
    restore_drop()

    assert.equal(1, #asked, "confirmation must be asked exactly once")
    assert.same({}, dropped, "cancel must not drop")
    assert.same({ "ccc-top", "bbb-middle", "aaa-init" }, subjects(dir), "history untouched")
  end)

  it("warns that dropping a merge commit drops what it merged in", function()
    local dir = workdir_with_merge()
    local buf = open_status(dir)
    buf.buffer:focus()

    local asked, dropped = {}, {}
    local restore_confirm = stub_confirm(asked, true)
    local restore_drop = stub_drop(dropped)

    assert.truthy(vim.fn.search([[merge-them]], "w") > 0, "merge row must render")
    actions.n_discard(buf)()
    assert.truthy(
      vim.wait(10000, function()
        return #asked > 0
      end, 10),
      "confirmation must fire"
    )
    restore_confirm()
    restore_drop()

    assert.equal(1, #asked, "confirmation must be asked exactly once; " .. vim.inspect(asked))
    assert.truthy(
      asked[1] and asked[1]:find("merge commit", 1, true) and asked[1]:find("merged in", 1, true),
      "merge warning must spell out the consequence; got: " .. tostring(asked[1])
    )
    assert.same({ oid_of(dir, "merge-them") }, dropped, "must drop the merge commit's OID")
  end)

  it("does nothing off a commit row", function()
    local dir = workdir()
    local buf = open_status(dir)
    buf.buffer:focus()

    local asked, dropped = {}, {}
    local restore_confirm = stub_confirm(asked, true)
    local restore_drop = stub_drop(dropped)

    assert.truthy(vim.fn.search([[Recent Commits]], "w") > 0, "section header must render")
    actions.n_discard(buf)()
    vim.wait(500) -- give the async body a chance to (not) prompt
    restore_confirm()
    restore_drop()

    assert.same({}, asked, "no prompt off commit rows")
    assert.same({}, dropped, "nothing dropped off commit rows")
  end)
end)
