-- libgit2 twin of git.refs simple listings (refs.list family): the plain
-- refname listings behind fuzzy finders. Rich formats (list_parsed, head)
-- stay on the CLI backend.
local config = require("neogit.config")
local util = require("neogit.lib.util")
local git2 = require("neogit.lib.git2")
local sort_refs = require("neogit.lib.git.libgit2").sort_refs

local M = {}

local function worktree_root()
  return require("neogit.lib.git").repo.worktree_root
end

---List refs under the given namespaces, short names, config-sorted.
---Mirrors refs.M.list(namespaces) for the default %(refname) format.
---@param namespaces? string[] e.g. { "^refs/heads/" }
---@return string[]
function M.list(namespaces)
  namespaces = namespaces or { "^refs/" }

  return git2.with_repo(worktree_root(), function(repo)
    local lg2 = git2.binding.libgit2()

    local prefixes = util.map(namespaces, function(ns)
      return ns:sub(2, -1)
    end)

    local entries = {}

    -- 1.9 removed the iterator `next` calls; foreach_name is the portable API.
    git2.each_ref_name(repo, function(full)
      local matched = #prefixes == 0
      for _, p in ipairs(prefixes) do
        if vim.startswith(full, p) then
          matched = true
        end
      end

      if matched then
        local entry = { name = full, time = nil }
        local ok, commit = pcall(function()
          local ref, err = repo:reference_lookup(full)
          assert(ref, "reference_lookup failed: " .. tostring(err))
          return ref:peel_commit()
        end)
        if ok and commit then
          local sig = lg2.C.git_commit_committer(commit.commit)
          entry.time = tonumber(sig.when.time) or 0
        end

        entries[#entries + 1] = entry
      end

      return true
    end)

    sort_refs(entries, config.values.sort_branches)

    -- Same shortening as refs.M.list: strip the first path segment.
    return util.map(entries, function(e)
      local name, _ = e.name:gsub("^refs/[^/]*/", "")
      return name
    end)
  end) or {}
end

return M
