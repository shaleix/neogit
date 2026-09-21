local git = require("neogit.lib.git")
local client = require("neogit.client")
local GitResult = require("neogit.lib.git.result")
local backend = require("neogit.lib.git.backend")

---@class NeogitGitTag
local M = {}

---Create a tag, editor flow handled by client.wrap.
---@param args string[] Positional/flag arguments (tag name, target, "-m", ...)
---@param opts? { autocmd?: string, msg?: { success: string, fail: string } }
---@return GitResult
function M.create(args, opts)
  opts = opts or {}

  local code = client.wrap(git.cli.tag.arg_list(args), {
    autocmd = opts.autocmd,
    msg = opts.msg,
  })

  return GitResult.new(code)
end

--- Outputs a list of tags locally
---@param filter string?
---@return table List of tags.
function M.list(filter)
  if filter then
    return git.cli.tag.list.args(filter).call({ hidden = true }).stdout
  else
    return git.cli.tag.list.call({ hidden = true }).stdout
  end
end

--- Deletes a list of tags
---@param tags table List of tags
---@return boolean Successfully deleted
function M.delete(tags)
  local result = git.cli.tag.delete.arg_list(tags).call { await = true }
  return result:success()
end

--- Show a list of tags under a selected ref
---@param remote string
---@return table
function M.list_remote(remote)
  return git.cli["ls-remote"].tags.args(remote).call({ hidden = true }).stdout
end

---Find tags that point at an object ID
---@param oid string
---@return string[]
function M.for_commit(oid)
  return git.cli.tag.points_at(oid).call({ hidden = true }).stdout
end

--- Returns the highest tag by version sort, or nil if no tags exist.
---@return string|nil
function M.highest()
  local tags = git.cli.tag.list.args("--sort=version:refname").call({ hidden = true }).stdout
  if #tags == 0 then
    return nil
  end
  return tags[#tags]
end

--- Returns the annotation message of a tag, or nil if lightweight or empty.
---@param tagname string
---@return string|nil
function M.message(tagname)
  local result =
    git.cli["for-each-ref"].format("%(contents)").args("refs/tags/" .. tagname).call { hidden = true }
  local msg = table.concat(result.stdout, "\n"):gsub("%s+$", "")
  return msg ~= "" and msg or nil
end

local tag_pattern = "(.-)%-([0-9]+)%-g%x+$"

function M.register(meta)
  meta.update_tags = function(state)
    state.head.tag = { name = nil, distance = nil, oid = nil }

    if backend.capability("query_describe") == "libgit2" then
      local name, distance, oid = require("neogit.lib.git.libgit2.tag").describe()
      if name and distance then
        state.head.tag = { name = name, distance = distance, oid = oid }
      end
      return
    end

    local tag = git.cli.describe.long.tags.args("HEAD").call({ hidden = true, ignore_error = true }).stdout
    if #tag == 1 then
      local tag, distance = tostring(tag[1]):match(tag_pattern)
      if tag and distance then
        state.head.tag = {
          name = tag,
          distance = tonumber(distance),
          oid = git.rev_parse.oid(tag),
        }
      end
    end
  end
end

return M
