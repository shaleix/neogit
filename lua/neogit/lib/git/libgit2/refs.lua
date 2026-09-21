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
    local matched_names = {}

    -- Collect first, resolve after: git_reference_lookup/peel inside the
    -- foreach callback re-enters libgit2 while the iterator is alive,
    -- which can deadlock or misbehave on some builds.
    git2.each_ref_name(repo, function(full)
      local matched = #prefixes == 0
      for _, p in ipairs(prefixes) do
        if vim.startswith(full, p) then
          matched = true
        end
      end

      if matched then
        matched_names[#matched_names + 1] = full
      end

      return true
    end)

    for _, full in ipairs(matched_names) do
      local entry = { name = full, time = nil }
      local ok, commit = pcall(function()
        local ref = repo:reference_lookup(full)
        assert(ref, "reference_lookup failed for " .. full)
        return ref:peel_commit()
      end)
      if ok and commit then
        local sig = lg2.C.git_commit_committer(commit.commit)
        entry.time = tonumber(sig.when.time) or 0
      end

      entries[#entries + 1] = entry
    end

    sort_refs(entries, config.values.sort_branches)

    -- Same shortening as refs.M.list: strip the first path segment.
    return util.map(entries, function(e)
      local name, _ = e.name:gsub("^refs/[^/]*/", "")
      return name
    end)
  end) or {}
end

return M
