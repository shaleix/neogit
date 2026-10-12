-- Recent Commits rows: the real Commit Graph prefix (per-glyph highlights,
-- same dispatch as the Log view), hash followed by the author's first two
-- characters, no date, everything left-aligned. Graph-only Connector Rows
-- (merge fan-out, lane turns) render between commit rows.
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
  it("renders the Commit Graph with author initials after the hash", function()
    local dir = workdir()
    local buf = open_status(dir)
    local text = table.concat(vim.api.nvim_buf_get_lines(buf.buffer.handle, 0, -1, false), "\n")

    -- linear commits: "* <hash> sh <subject>"
    local linear = text:match("%* (%x+) (sh) linear two\n")
    assert.truthy(linear, "linear row must match '* <hash> sh linear two':\n" .. text)

    -- merge commit (two parents): the row keeps the wider graph lane
    -- (`*  `) the Log view renders, no fake fan-out glyph
    assert.truthy(
      text:match("%* +(%x+) (sh) merge side\n"),
      "merge row must match '*  <hash> sh merge side':\n" .. text
    )
    assert.falsy(text:find("*─╮", 1, true), "the fake fan-out glyph must be gone:\n" .. text)

    -- Connector Rows: fan-out directly under the merge row, lane turn
    -- before the first-parent lane continues
    assert.truthy(text:find("|\\\n", 1, true), "fan-out Connector Row '|\\' must render:\n" .. text)
    assert.truthy(text:find("|/\n", 1, true), "lane-turn Connector Row '|/' must render:\n" .. text)

    -- merged-in side commit carries the other author's initials
    assert.truthy(text:match("%* (%x+) (al) side work\n"), "side commit must show 'al':\n" .. text)

    -- rows stay left-aligned: no author/date right-margin text bleeds in
    assert.falsy(text:match("[^\n]*ago"), "no relative dates may render:\n" .. text)
  end)

  it("connector rows are pure decoration - not items, skipped by item navigation", function()
    local dir = workdir()
    config.values.sections.recent.folded = false

    local buf = open_status(dir)
    buf.buffer:focus()

    local actions = require("neogit.buffers.status.actions")

    -- the merge row is an item
    vim.fn.search("merge side")
    local merge_item = buf.buffer.ui:get_item_under_cursor()
    assert.truthy(merge_item and merge_item.commit, "merge row must be an item")

    -- item-step down: the fan-out Connector Row must not catch the cursor
    actions.n_down(buf)()
    local item = buf.buffer.ui:get_item_under_cursor()
    assert.truthy(item and item.commit, "n_down must skip the Connector Row")
    assert.equal("side work", item.commit.subject)

    -- stepping back up skips the Connector Row again
    actions.n_up(buf)()
    item = buf.buffer.ui:get_item_under_cursor()
    assert.truthy(item and item.commit, "n_up must skip the Connector Row")
    assert.equal("merge side", item.commit.subject)

    config.values.sections.recent.folded = true
  end)

  it("renders the kitty Commit Graph natively - colored glyphs, no degrade warning", function()
    local dir = workdir()
    config.values.graph_style = "kitty"
    config.values.sections.recent.folded = false

    -- the kitty style renders natively: no degrade warning may fire, across
    -- repeat refreshes either
    local warns = {}
    local notification = require("neogit.lib.notification")
    local original_warn = notification.warn
    notification.warn = function(message)
      warns[#warns + 1] = tostring(message)
    end

    local buf = open_status(dir)

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

    local warn_count = #warns
    notification.warn = original_warn
    assert.equal(0, warn_count, "kitty style must not warn: " .. table.concat(warns, " | "))

    -- commit rows keep hash + initials after the glyph graph prefix (the
    -- initials distinguish the row from the Head Line ("... main merge side")
    -- header line, which carries the branch name instead)
    local lines = vim.api.nvim_buf_get_lines(buf.buffer.handle, 0, -1, false)
    local merge_idx
    for i, line in ipairs(lines) do
      if line:find(" sh merge side", 1, true) then
        merge_idx = i
        break
      end
    end
    assert.truthy(merge_idx, "merge row must render:\n" .. table.concat(lines, "\n"))

    local merge_line = lines[merge_idx]
    assert.truthy(
      merge_line:match("%x+ sh merge side"),
      "hash and initials must follow the graph:\n" .. merge_line
    )

    -- kitty glyphs are nerd-font (multibyte); an ascii fallback would show
    -- an asterisk lane instead
    assert.truthy(
      merge_line:match("[^\x01-\x7f]"),
      "merge row must carry a nerd-font graph glyph:\n" .. merge_line
    )
    assert.falsy(
      merge_line:find("*", 1, true),
      "kitty rows must not fall back to ascii lanes:\n" .. merge_line
    )

    -- commit rows interleave with Connector Rows: the row directly under the
    -- merge is graph-only (glyphs, no commit)
    local connector = lines[merge_idx + 1]
    assert.truthy(connector, "Connector Row must render under the merge row")
    assert.falsy(connector:match("%x"), "Connector Row must not carry a commit:\n" .. connector)
    assert.truthy(connector:match("[^\x01-\x7f]"), "Connector Row must carry graph glyphs:\n" .. connector)

    -- graph glyphs carry NeogitGraph* highlights from the kitty palette:
    -- anything but Purple proves the native kitty builder (an ascii fallback
    -- can only ever produce the Purple recolor)
    local recent_component
    local function find_section(node)
      if node.options and node.options.section == "recent" then
        recent_component = node
        return true
      end
      for _, child in ipairs(node.children or {}) do
        if find_section(child) then
          return true
        end
      end
      return false
    end
    find_section(buf.buffer.ui.layout)
    assert.truthy(recent_component, "Recent Commits section must render")

    local palette = { Red = true, Yellow = true, Blue = true, Cyan = true }
    local highlights = {}
    local function collect(node)
      if node.options and node.options.highlight then
        highlights[node.options.highlight] = true
      end
      for _, child in ipairs(node.children or {}) do
        collect(child)
      end
    end
    collect(recent_component)

    local colored = {}
    for hl in pairs(highlights) do
      local name = hl:match("^NeogitGraphBold?([%a]+)$")
      if name and palette[name] then
        colored[#colored + 1] = hl
      end
    end
    table.sort(colored)
    assert.truthy(
      #colored > 0,
      "kitty graph glyphs must carry NeogitGraph{Red,Yellow,Blue,Cyan} highlights, got: "
        .. table.concat(vim.tbl_keys(highlights), ", ")
    )

    -- data layer: every Commit Graph cell uses the kitty palette (short
    -- suffixes, rendered as NeogitGraph<color>), commits interleave with
    -- Connector Rows
    local git = require("neogit.lib.git")
    local items = git.log.internal.recent_commits({ "--max-count=10" }, true)
    local commits, connectors = 0, 0
    for _, item in ipairs(items) do
      if item.commit then
        commits = commits + 1
        for _, cell in ipairs(item.commit.graph or {}) do
          -- cells the kitty builder leaves unhighlighted carry nil (rendered
          -- uncolored, same as the Log view); the rest are short palette
          -- suffixes rendered as NeogitGraph<color>
          if cell.color ~= nil then
            local color = tostring(cell.color):gsub("^Bold", "")
            assert.truthy(
              vim.tbl_contains({ "Red", "Yellow", "Blue", "Purple", "Cyan" }, color),
              "kitty cell color must be a short palette suffix, got: " .. tostring(cell.color)
            )
          end
        end
      else
        connectors = connectors + 1
      end
    end
    assert.equal(5, commits)
    assert.truthy(connectors > 0, "the merge must produce Connector Rows")

    config.values.graph_style = "ascii"
    config.values.sections.recent.folded = true
  end)

  it("does not open the diff preview on recent rows; <cr> opens the commit view", function()
    local dir = workdir()
    config.values.sections.recent.folded = false
    config.values.status.diff_preview = { enabled = true, kind = "split", debounce = 50 }

    local buf = open_status(dir)
    buf.buffer:focus()
    vim.fn.search(" sh linear two")
    local hash = vim.api.nvim_get_current_line():match("(%x+)")

    -- drive the preview hook exactly like CursorMoved does: a Recent Commits
    -- row must NOT open the file-diff preview (the hook closes the preview
    -- instead, like any non-file row)
    buf:_preview_diff_under_cursor()
    vim.wait(300)

    local preview = require("neogit.buffers.diff_preview")
    assert.falsy(preview.is_open(), "recent rows must not open the diff preview")
    assert.is_nil(preview.buffer_handle(), "no preview buffer may exist")

    -- <cr> on the row still opens the full commit view
    local actions = require("neogit.buffers.status.actions")
    actions.n_goto_file(buf)()

    local commit_view = require("neogit.buffers.commit_view")
    assert.truthy(commit_view.is_open(), "<cr> on a recent row must open the commit view")
    assert.truthy(
      commit_view.instance.commit_info.oid:sub(1, #hash) == hash,
      "commit view must show the row's commit"
    )
    commit_view.instance:close()

    config.values.sections.recent.folded = true
    config.values.status.diff_preview = nil
  end)
end)
