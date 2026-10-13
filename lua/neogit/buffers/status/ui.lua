local Ui = require("neogit.lib.ui")
local Component = require("neogit.lib.ui.component")
local util = require("neogit.lib.util")
local common = require("neogit.buffers.common")
local config = require("neogit.config")
local hl = require("neogit.lib.hl")

local col = Ui.col
local row = Ui.row
local text = Ui.text

local map = util.map

local EmptyLine = common.EmptyLine
local List = common.List
local build_graph = common.build_graph

local M = {}

-- Optional nvim-web-devicons integration: resolved once, nil when absent.
local devicons_cache = nil
local devicons_resolved = false

---@return table|nil
function M.devicons()
  if not devicons_resolved then
    devicons_resolved = true
    local ok, devicons = pcall(require, "nvim-web-devicons")
    if ok and type(devicons) == "table" and devicons.get_icon then
      devicons_cache = devicons
    end
  end

  return devicons_cache
end

-- Test seam: force re-resolution of the devicons integration.
function M.reset_devicons_cache()
  devicons_cache = nil
  devicons_resolved = false
end

-- Big title banner at the top of the status buffer, mcphub.nvim-style:
-- three lines of box-drawing lettering reading "NEOGIT", centered on the
-- window, above a subtle full-width divider. The `width` prop is the
-- visible width of the status window; when nil (e.g. the cold-open render
-- before a window exists) it falls back to the editor width and recenters
-- on the first redraw.
local BANNER = Component.new(function(props)
  local width = props.width or vim.o.columns

  local logo = {
    "╔╗ ╦ ╔═╗ ╔═╗ ╔═╗ ╦ ╔╦╗",
    "║╚╗║ ╠═  ║ ║ ║ ╦ ║  ║",
    "╩ ╚╝ ╚═╝ ╚═╝ ╚═╝ ╩  ╩",
  }

  -- Letterforms carry trimmed trailing blanks, so rows differ in length by
  -- a cell or two. Center against the widest row so every row shares the
  -- same left grid: per-row centering would shear the verticals by 1.
  local banner_width = 0
  for _, line in ipairs(logo) do
    banner_width = math.max(banner_width, vim.fn.strdisplaywidth(line))
  end

  local steps = hl.STATUS_BANNER_GRADIENT_STEPS

  local items = {}

  for _, line in ipairs(logo) do
    local padding = math.max(0, math.floor((width - banner_width) / 2))

    -- One text segment per column, each mapped to a gradient step, so the
    -- title fades left-to-right (dashboard-style). strcharpart iterates
    -- UTF-8 characters: sub() would split the multi-byte box glyphs.
    local segments = {}

    if padding > 0 then
      segments[#segments + 1] = text((" "):rep(padding))
    end

    for idx = 0, vim.fn.strchars(line) - 1 do
      local step = math.min(steps, 1 + math.floor(idx / (banner_width - 1) * (steps - 1) + 0.5))
      segments[#segments + 1] =
        text.highlight(("NeogitStatusBanner%d"):format(step))(vim.fn.strcharpart(line, idx, 1))
    end

    items[#items + 1] = row(segments)
  end

  -- Divider: spans the window minus the sign/fold gutter and a small
  -- margin, so it never overflows into wrapping.
  items[#items + 1] = row {
    text.highlight("NeogitSubtleText")(("─"):rep(math.max(24, width - 6))),
  }

  return col(items)
end)

local HEAD = Component.new(function(props)
  -- Divergence against the upstream ref: `↑N` local commits not on the
  -- remote, `↓M` remote commits not local. Only non-zero directions render;
  -- fully in sync shows a single `✓` in their place, so the line still reads
  -- at a glance. Without an upstream nothing renders at all. The option is
  -- always present on the row (its ref is nil without an upstream) so
  -- `<cr>` can open the Repository Details buffer everywhere.
  local divergence = {}
  if props.divergence and props.divergence.ref then
    if props.divergence.ahead > 0 then
      divergence[#divergence + 1] =
        text.highlight("NeogitDivergenceAhead")(("↑%d"):format(props.divergence.ahead))
    end
    if props.divergence.behind > 0 then
      divergence[#divergence + 1] =
        text.highlight("NeogitDivergenceBehind")(("↓%d"):format(props.divergence.behind))
    end
    if #divergence == 0 then
      divergence[#divergence + 1] = text.highlight("NeogitDivergenceOk")("✓")
    end
  end

  -- Detached HEAD: the abbreviated oid stands in for the branch name.
  local branch, branch_highlight
  if props.branch == nil or props.branch == "(detached)" then
    branch = props.abbrev or (props.oid and props.oid:sub(1, 7)) or "(detached)"
    branch_highlight = "NeogitObjectId"
  else
    branch = props.branch
    branch_highlight = "NeogitBranch"
  end

  -- (built via list_extend: an unpack() mid-table-constructor keeps only
  -- its first value on LuaJIT, which silently dropped the ↓ counter)
  local content = {}
  -- Divergence leads the line at the far left: it is the first thing worth
  -- glancing at. `<cr>` on the line opens the Repository Details buffer.
  for i, fragment in ipairs(divergence) do
    if i > 1 then
      table.insert(content, text(" "))
    end
    table.insert(content, fragment)
  end
  if #divergence > 0 then
    table.insert(content, text(" "))
  end
  vim.list_extend(content, {
    text.highlight("NeogitBranch")(props.repo or ""),
    text.highlight("NeogitSubtleText")(" → "),
    text.highlight(branch_highlight)(branch),
  })

  return row(content, {
    yankable = props.yankable,
    divergence = props.divergence,
  })
end)

local function section_icon(icon)
  if not icon then
    return ""
  end

  return icon .. " "
end

local SectionTitle = Component.new(function(props)
  return { text.highlight(props.highlight or "NeogitSectionHeader")(section_icon(props.icon) .. props.title) }
end)

local SectionTitleRebase = Component.new(function(props)
  if props.onto then
    return {
      text.highlight(props.highlight or "NeogitSectionHeader")(section_icon(props.icon) .. props.title),
      text(" "),
      text.highlight("NeogitBranch")(props.head),
      text.highlight("NeogitSectionHeader")(" onto "),
      text.highlight(props.is_remote_ref and "NeogitRemote" or "NeogitBranch")(props.onto),
    }
  else
    return {
      text.highlight(props.highlight or "NeogitSectionHeader")(section_icon(props.icon) .. props.title),
      text(" "),
      text.highlight("NeogitBranch")(props.head),
    }
  end
end)

local SectionTitleMerge = Component.new(function(props)
  return {
    text.highlight(props.highlight or "NeogitSectionHeader")(section_icon(props.icon) .. props.title),
    text(" "),
    text.highlight("NeogitBranch")(props.branch),
  }
end)

-- Forward declaration: defined after SectionItemFile (it renders leaves),
-- but referenced by Section below.
local FileTree

local Section = Component.new(function(props)
  local count
  if props.count then
    count = { text(" ("), text.highlight("NeogitSectionHeaderCount")(#props.items), text(")") }
  end

  -- File sections always render as a directory tree; diff content lives in
  -- the diff_preview split, never inline in the status buffer.
  return col.tag("Section")({
    row(util.merge(props.title, count or {})),
    FileTree(props.name, props.config)(props.items),
    EmptyLine(),
  }, {
    foldable = true,
    folded = props.folded,
    section = props.name,
    id = props.name,
  })
end)

local SequencerSection = Component.new(function(props)
  local count
  if props.count then
    count = { text(" ("), text.highlight("NeogitSectionHeaderCount")(#props.items), text(")") }
  end

  return col.tag("Section")({
    row(util.merge(props.title, count or {})),
    col(map(props.items, props.render)),
    EmptyLine(),
  }, {
    foldable = true,
    folded = props.folded,
    section = props.name,
    id = props.name,
  })
end)

local RebaseSection = Component.new(function(props)
  return col.tag("Section")({
    row(util.merge(props.title, {
      text(" ("),
      text(props.current),
      text("/"),
      text(#props.items - 1),
      text(")"),
    })),
    col(map(props.items, props.render)),
    EmptyLine(),
  }, {
    foldable = true,
    folded = props.folded,
    section = props.name,
    id = props.name,
  })
end)

-- neo-tree style indent guides: prefix = blank base block (under the
-- section header), one block per ancestor level ("│ " while that ancestor
-- has later siblings, else "  "), then the row's own-level block ("└ "
-- when it is its parent's last child, "│ " otherwise). Rows whose parent
-- is the section root draw no marker at all - the base column never
-- carries one (neo-tree's level < 2 rule).
local function indent_segments(guides, own_last)
  local segments = { text("  ") }
  for _, cont in ipairs(guides) do
    table.insert(segments, cont and text.highlight("NeogitIndentGuide")("│ ") or text("  "))
  end
  if own_last ~= nil then
    table.insert(segments, text.highlight("NeogitIndentGuide")(own_last and "└ " or "│ "))
  end
  return segments
end

local SectionItemFile = function(section, config, guides, own_last)
  guides = guides or {}
  return Component.new(function(item)
    local mode = config.status.mode_text[item.mode]
    local mode_text
    if mode == "" then
      mode_text = ""
    elseif config.status.mode_padding > 0 then
      mode_text = util.pad_right(
        mode,
        util.max_length(vim.tbl_values(config.status.mode_text)) + config.status.mode_padding
      )
    end

    -- Nerd font file-type icon before the name. nvim-web-devicons is used
    -- when available (colored, per-type icons); otherwise the builtin
    -- extension table applies. Staged items paint letter + icon + name in
    -- the section green (lazygit-style); other sections keep the icon
    -- subtle (or devicons-colored).
    local staged_line = section == "staged"
    local highlight = ("NeogitChange%s%s"):format(item.mode:gsub("%?", "Untracked"), section)
    local file_icons = (config.icons and config.icons.file_icons) or {}
    local icon_text
    if not item.submodule then
      local icon, icon_hl
      local use_devicons = not (config.icons and config.icons.use_devicons == false)
      if use_devicons then
        local devicons = M.devicons()
        if devicons then
          local ext = item.name:match("%.([%w]+)$")
          icon, icon_hl = devicons.get_icon(item.name, ext, { default = true })
        end
      end

      if icon then
        icon_text = text.highlight(staged_line and highlight or icon_hl)(icon .. " ")
      else
        local ext = vim.fn.fnamemodify(item.name, ":e"):lower()
        local glyph = file_icons[ext] or file_icons.default
        icon_text = glyph and text.highlight(staged_line and highlight or "NeogitSubtleText")(glyph .. " ")
          or text("")
      end
    else
      local glyph = file_icons.submodule
      icon_text = glyph and text.highlight(staged_line and highlight or "NeogitSubtleText")(glyph .. " ")
        or text("")
    end

    local unmerged_types = {
      ["DD"] = " (both deleted)",
      ["DU"] = " (deleted by us)",
      ["UD"] = " (deleted by them)",
      ["AA"] = " (both added)",
      ["AU"] = " (added by us)",
      ["UA"] = " (added by them)",
    }

    local name = item.original_name and ("%s -> %s"):format(item.original_name, item.name) or item.name
    -- In file-tree mode the directory hierarchy is expressed by nested
    -- indented rows, so file rows show only the basename.
    if own_last ~= nil and not item.original_name then
      name = name:match("([^/]+)$") or name
    elseif own_last ~= nil then
      name = ("%s -> %s"):format(
        item.original_name:match("([^/]+)$") or item.original_name,
        item.name:match("([^/]+)$") or item.name
      )
    end

    local file_mode_change = text("")
    if
      item.file_mode
      and item.file_mode.worktree ~= item.file_mode.head
      and tonumber(item.file_mode.head) > 0
    then
      file_mode_change =
        text.highlight("NeogitSubtleText")((" %s -> %s"):format(item.file_mode.head, item.file_mode.worktree))
    end

    local submodule = text("")
    if item.submodule then
      local submodule_text
      if item.submodule.commit_changed then
        submodule_text = " (new commits)"
      elseif item.submodule.has_tracked_changes then
        submodule_text = " (modified content)"
      elseif item.submodule.has_untracked_changes then
        submodule_text = " (untracked content)"
      end

      submodule = text.highlight("NeogitTagName")(submodule_text)
    end

    -- Lazygit-style per-file +N/-M line counts, computed in bulk at refresh
    -- time (item.stats, from `git diff --numstat`). Both-zero counts (e.g.
    -- mode-only changes) render nothing.
    local line_counts = {}
    if config.status.file_line_counts and item.stats and item.stats.additions + item.stats.deletions > 0 then
      if item.stats.additions > 0 then
        table.insert(
          line_counts,
          text.highlight("NeogitDiffAdditions")(("  +%d"):format(item.stats.additions))
        )
      end

      if item.stats.deletions > 0 then
        table.insert(
          line_counts,
          text.highlight("NeogitDiffDeletions")(("  -%d"):format(item.stats.deletions))
        )
      end
    end

    -- The diff renders in the separate preview window that follows the
    -- cursor (see status/init.lua): file rows are never foldable and hunks
    -- never render inline in the status buffer.
    local segments = util.merge(indent_segments(guides, own_last), {
      text.highlight(highlight)(mode_text),
      icon_text,
      staged_line and text.highlight(highlight)(name) or text(name),
    })
    vim.list_extend(segments, line_counts)
    table.insert(segments, text.highlight("NeogitSubtleText")(unmerged_types[item.mode] or ""))
    table.insert(segments, file_mode_change)
    table.insert(segments, submodule)

    return col.tag("Item")({
      row(segments),
    }, {
      foldable = false,
      folded = true,
      context = true,
      id = ("%s--%s"):format(section, item.name),
      yankable = item.name,
      filename = item.name,
      item = item,
    })
  end)
end

-- File-tree rendering (diffview-style): directory rows are foldable and
-- carry the subtree file count; file rows indent one level deeper and show
-- only the basename - the directory hierarchy is expressed by nesting.
local function build_file_tree(items)
  local root = { path = "", dirs = {}, files = {} }
  for _, item in ipairs(items) do
    local parts = vim.split(item.name, "/")
    local node = root
    local prefix = ""
    for i = 1, #parts - 1 do
      prefix = prefix == "" and parts[i] or prefix .. "/" .. parts[i]
      local dir = node.dirs[parts[i]]
      if not dir then
        dir = { name = parts[i], path = prefix, dirs = {}, files = {} }
        node.dirs[parts[i]] = dir
      end
      node = dir
    end
    table.insert(node.files, item)
  end

  return root
end

local DirRow = Component.new(function(props)
  return row(util.merge(indent_segments(props.guides, props.own_last), {
    text.highlight("NeogitSubtleText")(props.icon .. " " .. props.name),
  }))
end)

-- Collapse single-child directory chains: when a directory holds no files
-- and exactly one subdirectory, merge the chain into one row
-- ("src/lib/deep"), like diffview/lazygit do.
---@param dir table
---@return table dir the deepest directory to render
---@return string display merged display name
local function collapse_dir(dir)
  local display = dir.name

  while true do
    local names = vim.tbl_keys(dir.dirs)
    if #dir.files == 0 and #names == 1 then
      dir = dir.dirs[names[1]]
      display = display .. "/" .. dir.name
    else
      return dir, display
    end
  end
end

local function render_file_tree(section, config, node, guides, depth)
  guides = guides or {}
  depth = depth or 0
  local children = {}

  local file_icons = (config.icons and config.icons.file_icons) or {}
  local dir_icon = file_icons.directory or "󰉋"

  local names = vim.tbl_keys(node.dirs)
  table.sort(names)
  for i, dirname in ipairs(names) do
    local dir, display = collapse_dir(node.dirs[dirname])
    -- Dirs render before files, so a dir is its parent's last child only
    -- when it is the last dir AND no files follow: only then is the guide
    -- line in this dir's column terminated for its subtree.
    local is_last = (i == #names) and #node.files == 0
    -- Rows directly under the section root (depth 0) never draw their own
    -- marker (the base column stays blank, neo-tree's level < 2 rule).
    -- NOTE: this must be keyed on depth, not on #guides == 0: children of
    -- top-level directories also carry empty guides but DO draw a marker.
    local own_last
    if depth > 0 then
      own_last = is_last
    end
    -- The dir's own sibling status propagates to its children's guides,
    -- except at depth 0: those rows' base column never draws, so their
    -- subtree starts a fresh guides chain.
    local child_guides = {}
    if depth > 0 then
      child_guides = util.merge(guides, { not is_last })
    end
    table.insert(
      children,
      col.tag("Directory")({
        DirRow {
          name = display,
          icon = dir_icon,
          guides = guides,
          own_last = own_last,
        },
        render_file_tree(section, config, dir, child_guides, depth + 1),
      }, {
        foldable = true,
        folded = false,
        id = ("%s--tree:%s"):format(section, dir.path),
        -- Marks this as a directory row so cursor-based actions (stage,
        -- unstage, ...) can find the subtree path under the cursor.
        directory = dir.path,
      })
    )
  end

  for j, item in ipairs(node.files) do
    local file_own_last
    if depth > 0 then
      file_own_last = (j == #node.files)
    end
    table.insert(children, SectionItemFile(section, config, guides, file_own_last)(item))
  end

  return col(children)
end

---@param section string
---@param config table
---@return fun(items: table): table
FileTree = function(section, config)
  return function(items)
    return render_file_tree(section, config, build_file_tree(items), {})
  end
end

local SectionItemStash = Component.new(function(item)
  local name = ("stash@{%s}"):format(item.idx)
  return row({
    text("  "),
    text.highlight("NeogitSubtleText")(name),
    text.highlight("NeogitSubtleText")(": "),
    text(item.message),
  }, { yankable = item.oid, item = item })
end)

local SectionItemRecent = Component.new(function(item)
  -- Connector Row: a graph-only row git emits between commit rows (merge
  -- fan-out, lane turns). It holds no commit: not an item, never selectable,
  -- never previewed, and item navigation skips it.
  if not item.commit then
    return row(util.merge({ text("  ") }, build_graph(item.graph)), { connector_row = true })
  end

  -- Commit row: the real Commit Graph prefix (per-glyph highlights, styled
  -- by graph_style exactly like the Log view), then the current layout -
  -- hash, author initials, subject. The separator space is explicit: the
  -- ansi parse of the graph consumes git's own trailing column space.
  local graph = item.commit.graph and build_graph(item.commit.graph) or { text("") }

  return row(
    util.merge({ text("  ") }, graph, {
      text(" "),
      text.highlight("NeogitObjectId")(item.commit.abbreviated_commit),
      text(" "),
      text.highlight("NeogitGraphAuthor")(item.commit.author_name:sub(1, 2)),
      text(" "),
      text(item.commit.subject),
    }),
    {
      oid = item.commit.oid,
      yankable = item.commit.oid,
      item = item,
    }
  )
end)

local SectionItemRebase = Component.new(function(item)
  if item.oid then
    local action_hl = (item.done and "NeogitRebaseDone")
      or (item.action == "onto" and "NeogitGraphBlue")
      or "NeogitGraphOrange"

    return row({
      text("  "),
      text(item.stopped and "> " or "  "),
      text.highlight(action_hl)(util.pad_right(item.action, 6)),
      text(" "),
      text.highlight("NeogitRebaseDone")(item.abbreviated_commit),
      text(" "),
      text.highlight(item.done and "NeogitRebaseDone")(item.subject),
    }, { yankable = item.oid, oid = item.oid })
  else
    return row {
      text("  "),
      text.highlight("NeogitGraphOrange")(item.action),
      text(" "),
      text(item.subject),
    }
  end
end)

local SectionItemSequencer = Component.new(function(item)
  local action_hl = (item.action == "join" and "NeogitGraphRed")
    or (item.action == "onto" and "NeogitGraphBlue")
    or "NeogitGraphOrange"

  local show_action = #item.action > 0
  local action = show_action and util.pad_right(item.action, 6) or ""

  return row({
    text("  "),
    text.highlight(action_hl)(action),
    text(show_action and " " or ""),
    text.highlight("NeogitObjectId")(item.abbreviated_commit),
    text(" "),
    text(item.subject),
  }, { yankable = item.oid, oid = item.oid })
end)

local SectionItemBisect = Component.new(function(item)
  local highlight
  if item.action == "good" then
    highlight = "NeogitGraphGreen"
  elseif item.action == "bad" then
    highlight = "NeogitGraphRed"
  elseif item.finished then
    highlight = "NeogitGraphBoldOrange"
  end

  return row({
    text("  "),
    text(item.finished and "> " or "  "),
    text.highlight(highlight)(util.pad_right(item.action, 5)),
    text(" "),
    text.highlight("NeogitObjectId")(item.abbreviated_commit),
    text(" "),
    text(item.subject),
  }, { yankable = item.oid, oid = item.oid })
end)

local BisectDetailsSection = Component.new(function(props)
  return col.tag("Section")({
    row(util.merge(props.title, { text(" "), text.highlight("NeogitObjectId")(props.commit.oid) })),
    row {
      text.highlight("NeogitSubtleText")("Author:     "),
      text((props.commit.author_name or "") .. " <" .. (props.commit.author_email or "") .. ">"),
    },
    row { text.highlight("NeogitSubtleText")("AuthorDate: "), text(props.commit.author_date) },
    row {
      text.highlight("NeogitSubtleText")("Committer:  "),
      text((props.commit.committer_name or "") .. " <" .. (props.commit.committer_email or "") .. ">"),
    },
    row { text.highlight("NeogitSubtleText")("CommitDate: "), text(props.commit.committer_date) },
    EmptyLine(),
    col(
      map(props.commit.description, text),
      { highlight = "NeogitCommitViewDescription", tag = "Description" }
    ),
    EmptyLine(),
  }, {
    foldable = true,
    folded = props.folded,
    section = props.name,
    yankable = props.commit.oid,
    id = props.name,
  })
end)

---@param state NeogitRepoState
---@param config NeogitConfig
---@param loading boolean? True while the first refresh wave is still in
---flight (cold open): renders a placeholder line instead of an empty buffer.
---The first redraw — the refresh completion callback — replaces it.
---@param width integer? Visible width of the status window, used to center
---the title banner.
function M.Status(state, config, loading, width)
  if loading then
    return {
      List {
        items = {
          row {
            text.highlight("NeogitSubtleText")("Loading repository state…"),
          },
        },
      },
    }
  end

  -- stylua: ignore start
  local show_banner = config.status.show_banner ~= false
  local section_icons = (config.icons and config.icons.sections) or {}

  local show_merge = state.merge.head
    and not config.sections.sequencer.hidden

  local show_rebase = #state.rebase.items > 0
    and not config.sections.rebase.hidden

  local show_cherry_pick = state.sequencer.cherry_pick
    and not config.sections.sequencer.hidden

  local show_revert = state.sequencer.revert
    and not config.sections.sequencer.hidden

  local show_bisect = #state.bisect.items > 0
    and not config.sections.bisect.hidden

  local show_untracked = #state.untracked.items > 0
    and not config.sections.untracked.hidden

  local show_unstaged = #state.unstaged.items > 0
    and not config.sections.unstaged.hidden

  local show_staged = #state.staged.items > 0
    and not config.sections.staged.hidden

  -- Explicit "No changes" placeholder: when the worktree is clean the file
  -- sections above silently vanish, so render a subtle marker in their slot
  -- instead. Skipped when every file section is hidden by config (the user
  -- wants no file-change information at all).
  local show_no_changes = config.status.show_no_changes ~= false
    and #state.untracked.items == 0
    and #state.unstaged.items == 0
    and #state.staged.items == 0
    and not (
      config.sections.untracked.hidden
      and config.sections.unstaged.hidden
      and config.sections.staged.hidden
    )

  -- The "Unpulled from"/"Unmerged into"/"Unpushed to" lists no longer render
  -- as sections: the Head Line's ↑N ↓M counters carry the divergence overview
  -- and <cr> there opens the Repository Details buffer (with the ahead/behind
  -- diffs embedded). The unpulled/unmerged items stay in state (counter
  -- data).

  local show_stashes = #state.stashes.items > 0
    and not config.sections.stashes.hidden

  -- Recent commits show whenever there are any: the old rule of hiding
  -- them while outgoing commits existed only avoided duplicating the
  -- "Unmerged into" list, which no longer renders.
  local show_recent = #state.recent.items > 0
    and not config.sections.recent.hidden

  return {
    List {
      items = {
        show_banner and BANNER { width = width },
        show_banner and EmptyLine(),
        -- The Head Line: `<sync> <repo> <branch>`. The divergence overview
        -- leads the line; `<cr>` opens the Repository Details buffer, which
        -- carries the Merge/Push/Tag info the old head block rows showed.
        -- The divergence option always marks the row (nil ref without an
        -- upstream) so `<cr>` opens the details everywhere.
        HEAD {
          repo = vim.fs.basename(state.worktree_root or ""),
          branch = state.head.branch,
          abbrev = state.head.abbrev,
          oid = state.head.oid,
          yankable = state.head.oid,
          divergence = {
            ref = state.upstream.ref,
            ahead = state.upstream.ref and #state.upstream.unmerged.items or 0,
            behind = state.upstream.ref and #state.upstream.unpulled.items or 0,
          },
        },
        EmptyLine(),
        show_merge and SequencerSection {
          title = SectionTitleMerge { icon = section_icons.merge,
            title = "Merging",
            branch = state.merge.branch,
            highlight = "NeogitMerging",
          },
          render = SectionItemSequencer,
          items = { { action = "", oid = state.merge.head, subject = state.merge.subject } },
          folded = config.sections.sequencer.folded,
          name = "merge",
        },
        show_rebase and RebaseSection {
          title = SectionTitleRebase { icon = section_icons.rebase,
            title = "Rebasing",
            head = state.rebase.head,
            onto = state.rebase.onto.ref,
            oid = state.rebase.onto.oid,
            is_remote_ref = state.rebase.onto.is_remote,
            highlight = "NeogitRebasing",
          },
          render = SectionItemRebase,
          current = state.rebase.current,
          items = state.rebase.items,
          folded = config.sections.rebase.folded,
          name = "rebase",
        },
        show_cherry_pick and SequencerSection {
          title = SectionTitle { title = "Cherry Picking", highlight = "NeogitPicking", icon = section_icons.cherry_pick },
          render = SectionItemSequencer,
          items = util.reverse(state.sequencer.items),
          folded = config.sections.sequencer.folded,
          name = "cherry_pick",
        },
        show_revert and SequencerSection {
          title = SectionTitle { title = "Reverting", highlight = "NeogitReverting", icon = section_icons.revert },
          render = SectionItemSequencer,
          items = util.reverse(state.sequencer.items),
          folded = config.sections.sequencer.folded,
          name = "revert",
        },
        show_bisect and BisectDetailsSection {
          title = SectionTitle { title = "Bisecting at", highlight = "NeogitBisecting", icon = section_icons.bisect },
          commit = state.bisect.current,
          folded = config.sections.bisect.folded,
          name = "bisect_details",
        },
        show_bisect and SequencerSection {
          title = SectionTitle { title = "Bisecting Log", highlight = "NeogitBisecting", icon = section_icons.bisect },
          render = SectionItemBisect,
          items = state.bisect.items,
          folded = config.sections.bisect.folded,
          name = "bisect",
        },
        show_no_changes and row {
          text("  "),
          text.highlight("NeogitSubtleText")("No changes"),
        },
        show_no_changes and EmptyLine(),
        show_untracked and Section {
          title = SectionTitle { title = "Untracked files", highlight = "NeogitUntrackedfiles", icon = section_icons.untracked },
          count = true,
          items = state.untracked.items,
          folded = config.sections.untracked.folded,
          name = "untracked",
          config = config,
        },
        show_unstaged and Section {
          title = SectionTitle { title = "Unstaged changes", highlight = "NeogitUnstagedchanges", icon = section_icons.unstaged },
          count = true,
          items = state.unstaged.items,
          folded = config.sections.unstaged.folded,
          name = "unstaged",
          config = config,
        },
        show_staged and Section {
          title = SectionTitle { title = "Staged changes", highlight = "NeogitStagedchanges", icon = section_icons.staged },
          count = true,
          items = state.staged.items,
          folded = config.sections.staged.folded,
          name = "staged",
          config = config,
        },
        show_recent and SequencerSection {
          title = SectionTitle { title = "Recent Commits", highlight = "NeogitRecentcommits", icon = section_icons.recent },
          render = SectionItemRecent,
          items = state.recent.items,
          folded = config.sections.recent.folded,
          name = "recent",
        },
        show_stashes and SequencerSection {
          title = SectionTitle { title = "Stashes", highlight = "NeogitStashes", icon = section_icons.stashes },
          count = true,
          render = SectionItemStash,
          items = state.stashes.items,
          folded = config.sections.stashes.folded,
          name = "stashes",
        },
      },
    },
  }
end

-- stylua: ignore end

return M
