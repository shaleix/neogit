local Ui = require("neogit.lib.ui")
local Component = require("neogit.lib.ui.component")
local util = require("neogit.lib.util")
local common = require("neogit.buffers.common")
local config = require("neogit.config")
local a = require("neogit.lib.async")
local state = require("neogit.lib.state")
local event = require("neogit.lib.event")

local col = Ui.col
local row = Ui.row
local text = Ui.text

local map = util.map

local EmptyLine = common.EmptyLine
local List = common.List
local DiffHunks = common.DiffHunks

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

local HINT = Component.new(function(props)
  ---@return table<string, string[]>
  local function reversed_lookup(tbl)
    local result = {}
    for k, v in pairs(tbl) do
      if v then
        local current = result[v]
        if current then
          table.insert(current, k)
        else
          result[v] = { k }
        end
      end
    end

    return result
  end

  local reversed_status_map = reversed_lookup(props.config.mappings.status)
  local reversed_popup_map = reversed_lookup(props.config.mappings.popup)

  local entry = function(name, hint)
    local keys = reversed_status_map[name] or reversed_popup_map[name]
    local key_hint

    if keys and #keys > 0 then
      key_hint = table.concat(keys, " ")
    else
      key_hint = "<unmapped>"
    end

    return row {
      text.highlight("NeogitPopupActionKey")(key_hint),
      text(" "),
      text(hint),
    }
  end

  return row {
    text.highlight("NeogitSubtleText")("Hint: "),
    entry("Toggle", "toggle"),
    text.highlight("NeogitSubtleText")(" | "),
    entry("Stage", "stage"),
    text.highlight("NeogitSubtleText")(" | "),
    entry("Unstage", "unstage"),
    text.highlight("NeogitSubtleText")(" | "),
    entry("Discard", "discard"),
    text.highlight("NeogitSubtleText")(" | "),
    entry("CommitPopup", "commit"),
    text.highlight("NeogitSubtleText")(" | "),
    entry("HelpPopup", "help"),
  }
end)

local HEAD = Component.new(function(props)
  local show_oid = props.show_oid
  local highlight, ref
  if props.branch == "(detached)" then
    highlight = "NeogitBranch"
    ref = props.branch
    show_oid = true
  elseif props.remote then
    highlight = "NeogitRemote"
    ref = ("%s/%s"):format(props.remote, props.branch)
  else
    highlight = "NeogitBranch"
    ref = props.branch
  end

  local oid = props.yankable
  if not oid or oid == "(initial)" then
    oid = "0000000"
  else
    oid = oid:sub(1, 7)
  end

  return row({
    text.highlight("NeogitStatusHEAD")(util.pad_right(props.name .. ": ", props.HEAD_padding)),
    text.highlight("NeogitObjectId")(show_oid and oid or ""),
    text(show_oid and " " or ""),
    text.highlight(highlight)(ref),
    text(" "),
    text(props.msg or "(no commits)"),
  }, { yankable = props.yankable })
end)

local Tag = Component.new(function(props)
  if props.distance then
    return row({
      text.highlight("NeogitStatusHEAD")(util.pad_right("Tag: ", props.HEAD_padding)),
      text.highlight("NeogitTagName")(props.name),
      text(" ("),
      text.highlight("NeogitTagDistance")(props.distance),
      text(")"),
    }, { yankable = props.yankable })
  else
    return row({
      text(util.pad_right("Tag: ", props.HEAD_padding)),
      text.highlight("NeogitTagName")(props.name),
    }, { yankable = props.yankable })
  end
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

local SectionTitleRemote = Component.new(function(props)
  return {
    text.highlight(props.highlight or "NeogitSectionHeader")(section_icon(props.icon) .. props.title),
    text(" "),
    text.highlight("NeogitRemote")(props.ref),
  }
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

  local body
  if props.file_tree then
    body = FileTree(props.name, props.config)(props.items)
  else
    body = col(map(props.items, props.render))
  end

  return col.tag("Section")({
    row(util.merge(props.title, count or {})),
    body,
    EmptyLine(),
  }, {
    foldable = true,
    folded = props.folded,
    section = props.name,
    id = props.name,
  })
end)

local SequencerSection = Component.new(function(props)
  return col.tag("Section")({
    row(util.merge(props.title)),
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

local SectionItemFile = function(section, config, depth)
  depth = depth or 0
  local indent = ("  "):rep(depth + 1)
  return Component.new(function(item)
    local load_diff = function(item)
      ---@param this Component
      ---@param ui Ui
      ---@param prefix string|nil
      return a.void(function(this, ui, prefix)
        this.options.on_open = nil
        this.options.folded = false

        local row, _ = this:row_range_abs()
        row = row + 1 -- Filename row

        local diff = item.diff
        for _, hunk in ipairs(diff.hunks) do
          hunk.first = row
          hunk.last = row + hunk.length
          row = hunk.last + 1

          -- Set fold state when called from ui:update()
          if prefix then
            local key = ("%s--%s"):format(prefix, hunk.hash)
            if ui._node_fold_state and ui._node_fold_state[key] then
              hunk._folded = ui._node_fold_state[key].folded
            end
          end
        end

        ui.buf:with_locked_viewport(function()
          this:append(DiffHunks(diff))
          ui:update()
        end)

        event.send("DiffLoaded", {
          item = {
            absolute_path = item.absolute_path,
            relative_path = item.escaped_path,
            row_start = item.first,
            row_end = item.last,
            mode = item.mode,
          },
          diff = {
            kind = diff.kind,
            lines = diff.lines,
            hunks = util.map(diff.hunks, function(hunk)
              local original_lines = util.filter_map(hunk.lines, function(line)
                if not (vim.startswith(line, "+") or vim.startswith(line, "-")) then
                  return line
                end
              end)

              local modified_lines = util.map(hunk.lines, function(line)
                return line:gsub("^[+-]", " ")
              end)

              return {
                lines = hunk.lines,
                original_lines = original_lines,
                modified_lines = modified_lines,
                row_start = hunk.first,
                row_end = hunk.last,
                header = hunk.line,
              }
            end),
          },
        })
      end)
    end

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
        icon_text = glyph
          and text.highlight(staged_line and highlight or "NeogitSubtleText")(glyph .. " ")
          or text("")
      end
    else
      local glyph = file_icons.submodule
      icon_text = glyph
        and text.highlight(staged_line and highlight or "NeogitSubtleText")(glyph .. " ")
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
    if depth > 0 and not item.original_name then
      name = name:match("([^/]+)$") or name
    elseif depth > 0 then
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

    -- With status.diff_preview enabled the diff renders in a separate
    -- preview window that follows the cursor (see status/init.lua); the
    -- item is not foldable and hunks never render inline.
    local preview_mode = config.status.diff_preview and config.status.diff_preview.enabled

    return col.tag("Item")({
      row {
        text(indent),
        text.highlight(highlight)(mode_text),
        icon_text,
        staged_line and text.highlight(highlight)(name) or text(name),
        text.highlight("NeogitSubtleText")(unmerged_types[item.mode] or ""),
        file_mode_change,
        submodule,
      },
    }, {
      foldable = not preview_mode,
      folded = true,
      on_open = (not preview_mode) and load_diff(item) or nil,
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
  return row({
    text(props.indent),
    text.highlight("NeogitSubtleText")(props.icon .. " " .. props.name),
  })
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

local function render_file_tree(section, config, node, depth)
  local children = {}

  local file_icons = (config.icons and config.icons.file_icons) or {}
  local dir_icon = file_icons.directory or "󰉋"

  local names = vim.tbl_keys(node.dirs)
  table.sort(names)
  for _, dirname in ipairs(names) do
    local dir, display = collapse_dir(node.dirs[dirname])
    table.insert(children, col.tag("Directory")({
      DirRow {
        name = display,
        icon = dir_icon,
        indent = ("  "):rep(depth + 1),
      },
      render_file_tree(section, config, dir, depth + 1),
    }, {
      foldable = true,
      folded = false,
      id = ("%s--tree:%s"):format(section, dir.path),
    }))
  end

  for _, item in ipairs(node.files) do
    table.insert(children, SectionItemFile(section, config, depth)(item))
  end

  return col(children)
end

---@param section string
---@param config table
---@return fun(items: table): table
FileTree = function(section, config)
  return function(items)
    return render_file_tree(section, config, build_file_tree(items), 0)
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

local SectionItemCommit = Component.new(function(item)
  local ref = {}
  local ref_last = {}

  if item.commit.ref_name ~= "" and state.get({ "NeogitMarginPopup", "decorate" }, true) then
    -- Render local only branches first
    for name, _ in pairs(item.decoration.locals) do
      if name:match("^refs/") then
        table.insert(ref_last, text(name, { highlight = "NeogitGraphGray" }))
        table.insert(ref_last, text(" "))
      elseif item.decoration.remotes[name] == nil then
        local branch_highlight = item.decoration.head == name and "NeogitBranchHead" or "NeogitBranch"
        table.insert(ref, text(name, { highlight = branch_highlight }))
        table.insert(ref, text(" "))
      end
    end

    -- Render tracked (local+remote) branches next
    for name, remotes in pairs(item.decoration.remotes) do
      if #remotes == 1 then
        table.insert(ref, text(remotes[1] .. "/", { highlight = "NeogitRemote" }))
      end

      if #remotes > 1 then
        table.insert(ref, text("{" .. table.concat(remotes, ",") .. "}/", { highlight = "NeogitRemote" }))
      end

      local branch_highlight = item.decoration.head == name and "NeogitBranchHead" or "NeogitBranch"
      local locally = item.decoration.locals[name] ~= nil
      table.insert(ref, text(name, { highlight = locally and branch_highlight or "NeogitRemote" }))
      table.insert(ref, text(" "))
    end

    -- Render tags
    for _, tag in pairs(item.decoration.tags) do
      table.insert(ref, text(tag, { highlight = "NeogitTagName" }))
      table.insert(ref, text(" "))
    end
  end

  local virtual_text

  -- Render margin, if visible
  if state.get({ "margin", "visibility" }, true) then
    local is_shortstat = state.get({ "margin", "shortstat" }, false)

    if is_shortstat then
      local cli_shortstat = item.shortstat
      local files_changed
      local insertions
      local deletions

      files_changed = cli_shortstat:match("^ (%d+) files?")
      files_changed = util.str_min_width(files_changed, 3, nil, { mode = "insert" })
      insertions = cli_shortstat:match("(%d+) insertions?")
      insertions = util.str_min_width(insertions and insertions .. "+" or " ", 5, nil, { mode = "insert" })
      deletions = cli_shortstat:match("(%d+) deletions?")
      deletions = util.str_min_width(deletions and deletions .. "-" or " ", 5, nil, { mode = "insert" })

      virtual_text = {
        { " ", "Constant" },
        { insertions, "NeogitDiffAdditions" },
        { " ", "Constant" },
        { deletions, "NeogitDiffDeletions" },
        { " ", "Constant" },
        { files_changed, "NeogitSubtleText" },
      }
    else -- Author & date margin
      local margin_date_style = state.get({ "margin", "date_style" }, 1)
      local details = state.get({ "margin", "details" }, true)

      local date
      local rel_date
      local date_width = 10
      local clamp_width = 30 -- to avoid having too much space when relative date is short

      -- Render date
      if item.commit.rel_date:match(" years?,") then
        rel_date, _ = item.commit.rel_date:gsub(" years?,", "y")
        rel_date = rel_date .. " "
      elseif item.commit.rel_date:match("^%d ") then
        rel_date = " " .. item.commit.rel_date
      else
        rel_date = item.commit.rel_date
      end

      if margin_date_style == 1 then -- relative date (short)
        local unpacked = vim.split(rel_date, " ")

        -- above, we added a space if the rel_date started with a single number
        -- we get the last two elements to deal with that
        local date_number = unpacked[#unpacked - 1]
        local date_quantifier = unpacked[#unpacked]
        if date_quantifier:match("months?") then
          date_quantifier = date_quantifier:gsub("m", "M") -- to distinguish from minutes
        end

        -- add back the space if we have a single number
        local left_pad
        if #unpacked > 2 then
          left_pad = " "
        else
          left_pad = ""
        end

        date = left_pad .. date_number .. util.str_first_char(date_quantifier)
        date_width = 3
        clamp_width = 23
      elseif margin_date_style == 2 then -- relative date (long)
        date = rel_date
        date_width = 10
      else -- local iso date
        if config.values.log_date_format == nil then
          -- we get the unix date to be able to convert the date to the local timezone
          date = os.date("%Y-%m-%d %H:%M", item.commit.unix_date)
          date_width = 16 -- TODO: what should the width be here?
        else
          date = item.commit.log_date
          date_width = 16
        end
      end

      local author_table = { "" }
      if details then
        author_table = {
          util.str_clamp(item.commit.author_name, clamp_width - (#date > date_width and #date or date_width)),
          "NeogitGraphAuthor",
        }
      end

      virtual_text = {
        { " ", "Constant" },
        author_table,
        { util.str_min_width(date, date_width), "Special" },
      }
    end
  end

  return row(
    util.merge(
      { text("  ") },
      { text.highlight("NeogitObjectId")(item.commit.abbreviated_commit) },
      { text(" ") },
      ref,
      ref_last,
      { text(item.commit.subject) }
    ),
    {
      virtual_text = virtual_text,
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

function M.Status(state, config)
  -- stylua: ignore start
  local show_hint = not config.disable_hint
  local section_icons = (config.icons and config.icons.sections) or {}

  local show_upstream = state.upstream.ref
    and not state.head.detached

  local show_pushRemote = state.pushRemote.ref
    and not state.head.detached

  local show_tag = state.head.tag.name

  local show_tag_distance = state.head.tag.name
    and not state.head.detached

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

  local show_upstream_unpulled = #state.upstream.unpulled.items > 0
    and not config.sections.unpulled_upstream.hidden

  local show_pushRemote_unpulled = #state.pushRemote.unpulled.items > 0
    and state.pushRemote.ref ~= state.upstream.ref
    and not config.sections.unpulled_pushRemote.hidden

  local show_upstream_unmerged = #state.upstream.unmerged.items > 0
    and not config.sections.unmerged_upstream.hidden

  local show_pushRemote_unmerged = #state.pushRemote.unmerged.items > 0
    and state.pushRemote.ref ~= state.upstream.ref
    and not config.sections.unmerged_pushRemote.hidden

  local show_stashes = #state.stashes.items > 0
    and not config.sections.stashes.hidden

  local show_recent = #state.recent.items > 0
    and not config.sections.recent.hidden

  return {
    List {
      items = {
        show_hint and HINT { config = config },
        show_hint and EmptyLine(),
        col.tag("Section")({
          HEAD {
            name = "Head",
            branch = state.head.branch,
            oid = state.head.abbrev,
            msg = state.head.commit_message,
            yankable = state.head.oid,
            show_oid = config.status.show_head_commit_hash,
            HEAD_padding = config.status.HEAD_padding,
          },
          show_upstream and HEAD {
            name = "Merge",
            branch = state.upstream.branch,
            remote = state.upstream.remote,
            msg = state.upstream.commit_message,
            yankable = state.upstream.oid,
            show_oid = config.status.show_head_commit_hash,
            HEAD_padding = config.status.HEAD_padding,
          },
          show_pushRemote and HEAD {
            name = "Push",
            branch = state.pushRemote.branch,
            remote = state.pushRemote.remote,
            msg = state.pushRemote.commit_message,
            yankable = state.pushRemote.oid,
            show_oid = config.status.show_head_commit_hash,
            HEAD_padding = config.status.HEAD_padding,
          },
          show_tag and Tag {
            name = state.head.tag.name,
            distance = show_tag_distance and state.head.tag.distance,
            yankable = state.head.tag.oid,
            HEAD_padding = config.status.HEAD_padding,
          },
        }, { foldable = true, folded = config.status.HEAD_folded }),
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
        show_untracked and Section {
          title = SectionTitle { title = "Untracked files", highlight = "NeogitUntrackedfiles", icon = section_icons.untracked },
          count = true,
          render = SectionItemFile("untracked", config),
          items = state.untracked.items,
          folded = config.sections.untracked.folded,
          name = "untracked",
          file_tree = config.status.file_tree,
          config = config,
        },
        show_unstaged and Section {
          title = SectionTitle { title = "Unstaged changes", highlight = "NeogitUnstagedchanges", icon = section_icons.unstaged },
          count = true,
          render = SectionItemFile("unstaged", config),
          items = state.unstaged.items,
          folded = config.sections.unstaged.folded,
          name = "unstaged",
          file_tree = config.status.file_tree,
          config = config,
        },
        show_staged and Section {
          title = SectionTitle { title = "Staged changes", highlight = "NeogitStagedchanges", icon = section_icons.staged },
          count = true,
          render = SectionItemFile("staged", config),
          items = state.staged.items,
          folded = config.sections.staged.folded,
          name = "staged",
          file_tree = config.status.file_tree,
          config = config,
        },
        show_upstream_unmerged and Section {
          title = SectionTitleRemote {
            title = "Unmerged into",
            ref = state.upstream.ref,
            highlight = "NeogitUnmergedchanges",
            icon = section_icons.unmerged,
          },
          count = true,
          render = SectionItemCommit,
          items = state.upstream.unmerged.items,
          folded = config.sections.unmerged_upstream.folded,
          name = "upstream_unmerged",
        },
        show_pushRemote_unmerged and Section {
          title = SectionTitleRemote {
            title = "Unpushed to",
            ref = state.pushRemote.ref,
            highlight = "NeogitUnpushedchanges",
            icon = section_icons.unmerged,
          },
          count = true,
          render = SectionItemCommit,
          items = state.pushRemote.unmerged.items,
          folded = config.sections.unmerged_pushRemote.folded,
          name = "pushRemote_unmerged",
        },
        not show_upstream_unmerged and show_recent and Section {
          title = SectionTitle { title = "Recent Commits", highlight = "NeogitRecentcommits", icon = section_icons.recent },
          count = false,
          render = SectionItemCommit,
          items = state.recent.items,
          folded = config.sections.recent.folded,
          name = "recent",
        },
        show_upstream_unpulled and Section {
          title = SectionTitleRemote {
            title = "Unpulled from",
            ref = state.upstream.ref,
            highlight = "NeogitUnpulledchanges",
            icon = section_icons.unpulled,
          },
          count = true,
          render = SectionItemCommit,
          items = state.upstream.unpulled.items,
          folded = config.sections.unpulled_upstream.folded,
          name = "upstream_unpulled",
        },
        show_pushRemote_unpulled and Section {
          title = SectionTitleRemote {
            title = "Unpulled from",
            ref = state.pushRemote.ref,
            highlight = "NeogitUnpulledchanges",
            icon = section_icons.unpulled,
          },
          count = true,
          render = SectionItemCommit,
          items = state.pushRemote.unpulled.items,
          folded = config.sections.unpulled_pushRemote.folded,
          name = "pushRemote_unpulled",
        },
        show_stashes and Section {
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
