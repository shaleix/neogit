-- libgit2 twin of `git describe --long --tags HEAD` (update_tags):
-- find the nearest tag reachable from HEAD and count the distance.
-- libgit2 has no git_describe binding here, so this walks manually - fine for
-- the handful of tags typical repos carry.
local git2 = require("neogit.lib.git2")

local M = {}

local function worktree_root()
  return require("neogit.lib.git").repo.worktree_root
end

---@return string? tag_name
---@return number? distance
---@return string? oid of the tagged commit
function M.describe()
  return git2.with_repo(worktree_root(), function(repo)
    -- tag commit-oid -> lexically smallest tag name pointing at it
    local tag_at = {}
    local tag_names = {}

    -- Collect first, resolve after: git_reference_lookup/peel inside the
    -- foreach callback re-enters libgit2 while the iterator is alive.
    git2.each_ref_name(repo, function(name)
      if vim.startswith(name, "refs/tags/") then
        tag_names[#tag_names + 1] = name:sub(#"refs/tags/" + 1)
      end
      return true
    end)

    for _, short in ipairs(tag_names) do
      local name = "refs/tags/" .. short
      local ok, commit = pcall(function()
        local ref = repo:reference_lookup(name)
        assert(ref, "reference_lookup failed for " .. name)
        return ref:peel_commit()
      end)

      if ok and commit then
        local oid = git2.oid_hex(commit:id().oid)
        if tag_at[oid] == nil or short < tag_at[oid] then
          tag_at[oid] = short
        end
      end
    end

    if vim.tbl_isempty(tag_at) then
      return nil, nil, nil
    end

    -- walk from HEAD; depth of the first commit carrying a tag wins
    local lg2 = git2.binding.libgit2()
    local walker = repo:walker()
    walker:sort(true, false, false)
    walker:push_head()

    local ffi = require("ffi")
    local oid_buf = ffi.new("git_oid[1]")
    local depth = 0

    while lg2.C.git_revwalk_next(oid_buf, walker.revwalk) == 0 do
      local hex = git2.oid_hex(oid_buf)
      local tag = tag_at[hex]
      if tag then
        return tag, depth, hex
      end
      depth = depth + 1
    end

    return nil, nil, nil
  end)
end

return M
