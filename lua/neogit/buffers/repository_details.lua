-- Repository Details: the buffer the status buffer's Head Line opens with
-- `<cr>`. Styled after the commit view (info header rows + rendered diffs
-- below), opened as a right-side vsplit.
--
-- Snapshot semantics: everything is read from the repo state (and git, for
-- the ahead/behind diffs) once at open; the buffer never refreshes. It is a
-- read-only display - oids are yankable, there are no custom mappings beyond
-- q/<esc>.
local Buffer = require("neogit.lib.buffer")
local Ui = require("neogit.lib.ui")
local util = require("neogit.lib.util")
local common_ui = require("neogit.buffers.common")
local config = require("neogit.config")
local git = require("neogit.lib.git")

local Diff = common_ui.Diff
local text = Ui.text
local col = Ui.col
local row = Ui.row

local M = {}

---Parse `git diff <range>` output into per-file Diff tables (the shape
---`common.Diff` renders), the same way the log module splits `git show`.
---@param range string
---@return table[]
local function range_diffs(range)
  local out = git.cli.diff.args(range).call({ hidden = true, ignore_error = true }).stdout

  local chunks = {}
  local current = nil
  for _, line in ipairs(out) do
    -- Diff body lines carry a +/-/space prefix, so only headers match.
    if line:match("^diff ") then
      current = {}
      chunks[#chunks + 1] = current
    end

    if current then
      current[#current + 1] = line
    end
  end

  return util.filter_map(chunks, function(chunk)
    if #chunk == 0 then
      return nil
    end

    return git.diff.parse(chunk)
  end)
end

local function field(label, value)
  return row {
    text.highlight("NeogitSubtleText")(label),
    text(value),
  }
end

local function oid_row(oid)
  return row({ text.highlight("NeogitObjectId")(oid) }, { yankable = oid })
end

local function message_row(message)
  return col(util.map(vim.split(message or "", "\n"), text), {
    highlight = "NeogitCommitViewDescription",
    tag = "Description",
  })
end

local function section(title, rows)
  local out = { text.line_hl("NeogitSectionHeader")(title) }
  for _, r in ipairs(rows) do
    out[#out + 1] = r
  end
  out[#out + 1] = text("")

  return out
end

local function diff_section(title, diffs)
  return {
    text.line_hl("NeogitSectionHeader")(title),
    text(""),
    col(util.map(diffs, Diff), { tag = "DiffList" }),
    text(""),
  }
end

---Build the layout from the snapshot.
---@param d table details snapshot (see M.new)
---@return table[]
local function RepositoryDetails(d)
  local layout = {}
  local function add(rows)
    vim.list_extend(layout, rows)
  end

  add(section("Head", {
    field("Branch:  ", d.head.branch or "(detached)"),
    oid_row(d.head.oid or "(no commits)"),
    message_row(d.head.message),
  }))

  if d.upstream then
    add(section("Merge (upstream)", {
      field("Remote:  ", d.upstream.remote or ""),
      field("Branch:  ", d.upstream.ref),
      oid_row(d.upstream.oid or "(unavailable)"),
      message_row(d.upstream.message),
    }))
  end

  if d.push_remote then
    add(section("Push (pushRemote)", {
      field("Remote:  ", d.push_remote.remote or ""),
      field("Branch:  ", d.push_remote.ref),
      oid_row(d.push_remote.oid or "(unavailable)"),
      message_row(d.push_remote.message),
    }))
  end

  if d.tag then
    local rows = {
      field("Name:    ", d.tag.name),
      oid_row(d.tag.oid or "(unavailable)"),
    }
    if d.tag.distance then
      rows[#rows + 1] = field("Distance: ", tostring(d.tag.distance))
    end

    add(section("Tag", rows))
  end

  if d.divergence then
    local rows = {}
    if d.divergence.ahead > 0 then
      rows[#rows + 1] =
        field("Ahead:   ", ("↑%d commit(s) not on %s"):format(d.divergence.ahead, d.divergence.ref))
    end
    if d.divergence.behind > 0 then
      rows[#rows + 1] = field(
        "Behind:  ",
        ("↓%d commit(s) on %s not merged locally"):format(d.divergence.behind, d.divergence.ref)
      )
    end
    if #rows == 0 then
      rows[#rows + 1] = field("Sync:    ", ("✓ in sync with %s"):format(d.divergence.ref))
    end

    add(section("Divergence", rows))
  end

  if #d.unpushed > 0 then
    add(diff_section("Unpushed changes", d.unpushed))
  end

  if #d.incoming > 0 then
    add(diff_section("Incoming changes", d.incoming))
  end

  return layout
end

---@class RepositoryDetailsBuffer
---@field details table snapshot taken at open
---@field buffer Buffer|nil
local M = {
  instance = nil,
}
M.__index = M

---Snapshot the repository state for the details view. Everything is read
---once here (including the ahead/behind diffs); the buffer never refreshes.
---@param state NeogitRepoState
---@return RepositoryDetailsBuffer
function M.new(state)
  local upstream_ref = state.upstream.ref
  local ahead = upstream_ref and #state.upstream.unmerged.items or 0
  local behind = upstream_ref and #state.upstream.unpulled.items or 0

  local instance = {
    details = {
      repo = vim.fs.basename(state.worktree_root or ""),
      head = {
        branch = state.head.detached and "(detached)" or state.head.branch,
        oid = state.head.oid,
        message = state.head.commit_message,
      },
      upstream = upstream_ref and {
        ref = upstream_ref,
        remote = state.upstream.remote,
        branch = state.upstream.branch,
        oid = state.upstream.oid,
        message = state.upstream.commit_message,
      } or nil,
      -- The pushRemote section duplicates the upstream one when both name
      -- the same ref, so only the differing case gets its own section.
      push_remote = (state.pushRemote.ref and state.pushRemote.ref ~= upstream_ref) and {
        ref = state.pushRemote.ref,
        remote = state.pushRemote.remote,
        branch = state.pushRemote.branch,
        oid = state.pushRemote.oid,
        message = state.pushRemote.commit_message,
      } or nil,
      tag = state.head.tag.name and {
        name = state.head.tag.name,
        distance = state.head.tag.distance,
        oid = state.head.tag.oid,
      } or nil,
      divergence = upstream_ref and {
        ref = upstream_ref,
        ahead = ahead,
        behind = behind,
      } or nil,
      -- Ahead side: what HEAD has that the upstream lacks. Behind side:
      -- what the upstream has that HEAD lacks - the objects are local
      -- whenever the behind count is > 0, since the fetch brought them.
      unpushed = (upstream_ref and ahead > 0) and range_diffs(upstream_ref .. "...HEAD") or {},
      incoming = (upstream_ref and behind > 0) and range_diffs("HEAD..." .. upstream_ref) or {},
    },
    buffer = nil,
  }

  return setmetatable(instance, M)
end

---Open the details buffer as a right-side vsplit.
---@return RepositoryDetailsBuffer
function M:open()
  M.instance = self

  self.buffer = Buffer.create {
    name = "NeogitRepositoryDetails",
    filetype = "NeogitRepositoryDetails",
    kind = "vsplit", -- buffer.lua opens vsplits on the right
    status_column = not config.values.disable_signs and "" or nil,
    context_highlight = not config.values.disable_context_highlighting and config.values.log_pager == nil,
    mappings = {
      n = {
        ["q"] = function()
          self:close()
        end,
        ["<esc>"] = function()
          self:close()
        end,
      },
    },
    render = function()
      return RepositoryDetails(self.details)
    end,
    after = function()
      vim.cmd("normal! zR")
    end,
  }

  return self
end

---Close the details buffer (no-op when not open).
function M:close()
  if self.buffer then
    self.buffer:close()
    self.buffer = nil
    M.instance = nil
  end
end

---Whether the details buffer is currently visible.
---@return boolean
function M.is_open()
  return (M.instance and M.instance.buffer and M.instance.buffer:is_visible()) == true
end

return M
