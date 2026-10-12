local Buffer = require("neogit.lib.buffer")
local config = require("neogit.config")
local CommitViewBuffer = require("neogit.buffers.commit_view")
local popups = require("neogit.popups")
local util = require("neogit.lib.util")

local git = require("neogit.lib.git")
local ui = require("neogit.buffers.stash_list_view.ui")
local input = require("neogit.lib.input")
local helpers = require("neogit.lib.ui.helpers")

---@class StashListBuffer
---@field stashes StashItem[]
local M = {}
M.__index = M

--- Gets all current stashes
function M.new(stashes)
  local instance = {
    stashes = stashes,
  }

  setmetatable(instance, M)
  return instance
end

function M:close()
  self.buffer:close()
  self.buffer = nil
end

--- Creates a buffer populated with output of `git stash list`
--- and supports related operations.
function M:open()
  local status_maps = config.get_reversed_status_maps()
  self.buffer = Buffer.create {
    name = "NeogitStashView",
    filetype = "NeogitStashView",
    header = "Stashes (" .. #self.stashes .. ")",
    scroll_header = true,
    kind = config.values.stash.kind,
    context_highlight = true,
    active_item_highlight = true,
    mappings = {
      v = {
        [popups.mapping_for("CherryPickPopup")] = function()
          -- TODO: implement
          -- local stash = self.buffer.ui:get_commit_under_cursor()[1]
          -- if stash then
          --   local stash_item = util.find(self.stashes, function(s)
          --     return s.idx == tonumber(stash:match("stash@{(%d+)}"))
          --   end)
          --
          --   if stash and input.get_permission("Pop stash " .. stash_item.name) then
          --     git.stash.pop(stash)
          --   end
          -- end
        end,
        [status_maps["Discard"]] = function()
          local stashes = self.buffer.ui:get_commits_in_selection()
          if stashes then
            if
              stashes
              and input.get_permission(table.concat(stashes, "\n") .. "\n\nDrop " .. #stashes .. " stashes?")
            then
              for _, stash in ipairs(stashes) do
                git.stash.drop(stash)
              end
            end
          end
        end,
        [popups.mapping_for("BranchPopup")] = popups.open("branch", function(p)
          p { commits = self.buffer.ui:get_commits_in_selection() }
        end),
        [popups.mapping_for("CommitPopup")] = popups.open("commit", function(p)
          p { commit = self.buffer.ui:get_commit_under_cursor() }
        end),
        [popups.mapping_for("FetchPopup")] = popups.open("fetch"),
        [popups.mapping_for("MergePopup")] = popups.open("merge", function(p)
          p { commit = self.buffer.ui:get_commit_under_cursor() }
        end),
        [popups.mapping_for("PushPopup")] = popups.open("push", function(p)
          p { commit = self.buffer.ui:get_commit_under_cursor() }
        end),
        [popups.mapping_for("RebasePopup")] = popups.open("rebase", function(p)
          p { commit = self.buffer.ui:get_commit_under_cursor() }
        end),
        [popups.mapping_for("RevertPopup")] = popups.open("revert", function(p)
          p { commits = self.buffer.ui:get_commits_in_selection() }
        end),
        [popups.mapping_for("ResetPopup")] = popups.open("reset", function(p)
          p { commit = self.buffer.ui:get_commit_under_cursor() }
        end),
        [popups.mapping_for("TagPopup")] = popups.open("tag", function(p)
          p { commit = self.buffer.ui:get_commit_under_cursor() }
        end),
        [popups.mapping_for("PullPopup")] = popups.open("pull"),
        [popups.mapping_for("DiffPopup")] = popups.open("diff", function(p)
          local items = self.buffer.ui:get_commits_in_selection()
          p {
            section = { name = "stashes" },
            item = { name = items },
          }
        end),
        [popups.mapping_for("BisectPopup")] = popups.open("bisect", function(p)
          p { commits = self.buffer.ui:get_commits_in_selection() }
        end),
      },
      n = {
        ["V"] = function()
          vim.cmd("norm! V")
        end,
        [popups.mapping_for("CherryPickPopup")] = function()
          local stash = self.buffer.ui:get_commit_under_cursor()
          if stash then
            local stash_item = util.find(self.stashes, function(s)
              return s.idx == tonumber(stash:match("stash@{(%d+)}"))
            end)

            if stash and input.get_permission("Pop stash " .. stash_item.name) then
              git.stash.pop(stash)
            end
          end
        end,
        [status_maps["Discard"]] = function()
          local stash = self.buffer.ui:get_commit_under_cursor()
          if stash then
            local stash_item = util.find(self.stashes, function(s)
              return s.idx == tonumber(stash:match("stash@{(%d+)}"))
            end)

            if stash and input.get_permission("Drop stash " .. stash_item.name) then
              git.stash.drop(stash)
            end
          end
        end,
        [popups.mapping_for("BisectPopup")] = popups.open("bisect", function(p)
          p { commits = { self.buffer.ui:get_commit_under_cursor() } }
        end),
        [popups.mapping_for("BranchPopup")] = popups.open("branch", function(p)
          p { commits = { self.buffer.ui:get_commit_under_cursor() } }
        end),
        [popups.mapping_for("CommitPopup")] = popups.open("commit", function(p)
          p { commit = self.buffer.ui:get_commit_under_cursor() }
        end),
        [popups.mapping_for("FetchPopup")] = popups.open("fetch"),
        [popups.mapping_for("MergePopup")] = popups.open("merge", function(p)
          p { commit = self.buffer.ui:get_commit_under_cursor() }
        end),
        [popups.mapping_for("PushPopup")] = popups.open("push", function(p)
          p { commit = self.buffer.ui:get_commit_under_cursor() }
        end),
        [popups.mapping_for("RebasePopup")] = popups.open("rebase", function(p)
          p { commit = self.buffer.ui:get_commit_under_cursor() }
        end),
        [popups.mapping_for("RemotePopup")] = popups.open("remote"),
        [popups.mapping_for("RevertPopup")] = popups.open("revert", function(p)
          p { commits = { self.buffer.ui:get_commit_under_cursor() } }
        end),
        [popups.mapping_for("ResetPopup")] = popups.open("reset", function(p)
          p { commit = self.buffer.ui:get_commit_under_cursor() }
        end),
        [popups.mapping_for("TagPopup")] = popups.open("tag", function(p)
          p { commit = self.buffer.ui:get_commit_under_cursor() }
        end),
        [popups.mapping_for("PullPopup")] = popups.open("pull"),
        [popups.mapping_for("DiffPopup")] = popups.open("diff", function(p)
          local item = self.buffer.ui:get_commit_under_cursor()
          p {
            section = { name = "stashes" },
            item = { name = item },
          }
        end),
        [status_maps["YankSelected"]] = function()
          local yank = self.buffer.ui:get_commit_under_cursor()
          if yank then
            yank = string.format("'%s'", yank)
            vim.cmd.let("@+=" .. yank)
            vim.cmd.echo(yank)
          else
            vim.cmd("echo ''")
          end
        end,
        ["<esc>"] = require("neogit.lib.ui.helpers").close_topmost(self),
        [status_maps["Close"]] = require("neogit.lib.ui.helpers").close_topmost(self),
        [status_maps["GoToFile"]] = function()
          local commit = self.buffer.ui:get_commit_under_cursor()
          if commit then
            CommitViewBuffer.new(commit):open()
          end
        end,
        [status_maps["PeekFile"]] = helpers.peek_commit(self, "file"),
        [status_maps["OpenOrScrollDown"]] = helpers.peek_commit(self, "scroll", "down"),
        [status_maps["OpenOrScrollUp"]] = helpers.peek_commit(self, "scroll", "up"),
        [status_maps["PeekUp"]] = helpers.peek_commit(self, "peek", "up", nil, { open_when_absent = true }),
        [status_maps["PeekDown"]] = helpers.peek_commit(
          self,
          "peek",
          "down",
          nil,
          { open_when_absent = true }
        ),
      },
    },
    after = function()
      vim.cmd([[setlocal nowrap]])
    end,
    render = function()
      return ui.View(self.stashes)
    end,
  }
end

return M
