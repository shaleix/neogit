-- libgit2 twins for git.branch read queries: current branch, existence, and
-- the branch listings used by fuzzy finders (zero-spawn interactions).
local config = require("neogit.config")
local git2 = require("neogit.lib.git2")
local sort_refs = require("neogit.lib.git.libgit2").sort_refs

local M = {}

local function worktree_root()
  return require("neogit.lib.git").repo.worktree_root
end

local function current_branch(repo)
  local ref = repo:head()
  if not ref then
    return nil
  end

  return ref:shorthand()
end

---BranchStatus twin matching git.branch.status()'s shape
---({ ab, detached, oid, head, upstream }), killing the `status -b` spawn.
---@return table
function M.status()
  return git2.with_repo(worktree_root(), function(repo)
    local out = { ab = nil, detached = false, oid = nil, head = nil, upstream = nil }

    local head_ref = repo:head()
    if not head_ref then
      -- unborn HEAD: report the branch name with the "(initial)" oid, like porcelain
      local sym = repo:reference_lookup("HEAD")
      if sym then
        local target = sym:symbolic_target()
        out.head = target and target:gsub("^refs/heads/", "") or "(detached)"
      else
        out.head = "(detached)"
      end

      out.oid = "(initial)"
      return out
    end

    if head_ref.name == "HEAD" then
      out.head = "(detached)"
      out.detached = true
    else
      out.head = head_ref:shorthand()
    end

    local commit = head_ref:peel_commit()
    if commit then
      out.oid = git2.oid_hex(commit:id().oid)
    end

    if not out.detached then
      local upstream_ref = head_ref:branch_upstream()
      if upstream_ref then
        out.upstream = (upstream_ref.name or ""):gsub("^refs/remotes/", "")

        local upstream_commit = upstream_ref:peel_commit()
        if upstream_commit and commit then
          local ahead, behind = repo:ahead_behind(commit:id(), upstream_commit:id())
          if ahead and behind then
            out.ab = ("+%d -%d"):format(ahead, behind)
          end
        end
      end
    end

    return out
  end)
end

---Current branch shorthand, or nil on detached/unborn HEAD.
---Mirrors git.branch.current()'s state-first contract.
---@return string?
function M.current()
  local cached = require("neogit.lib.git").repo.state.head.branch
  if cached and cached ~= "(detached)" then
    return cached
  end

  return git2.with_repo(worktree_root(), current_branch)
end

---Full ref name of the current branch ("refs/heads/<name>"), nil when detached.
---@return string?
function M.current_full_name()
  local current = M.current()
  if current then
    return "refs/heads/" .. current
  end
end

---Does a local branch exist?
---@param branch string
---@return boolean
function M.exists(branch)
  return git2.with_repo(worktree_root(), function(repo)
    local ref = repo:branch_lookup(branch, git2.binding.libgit2().GIT_BRANCH.LOCAL)
    return ref ~= nil
  end) == true
end

local function list_branches(repo, locals, remotes, include_current, sortby)
  local branches = repo:branches(locals, remotes) or {}

  local current = current_branch(repo)
  local entries = {}

  for _, b in ipairs(branches) do
    -- type: 1 = local, 2 = remote (GIT_BRANCH LOCAL/REMOTE)
    local is_local = b.type == 1
    local name = b.shorthand

    -- Skip remote HEAD symrefs ("origin/HEAD"), mirroring parse_branches.
    if name and not name:match("/HEAD$") then
      if include_current or name ~= current or not is_local then
        local entry = { name = name, time = nil }

        local ok, commit = pcall(function()
          local ref = repo:reference_lookup(b.name)
          return ref and ref:peel_commit()
        end)
        if ok and commit then
          local lg2 = git2.binding.libgit2()
          local sig = lg2.C.git_commit_committer(commit.commit)
          entry.time = tonumber(sig.when.time) or 0
        end

        entries[#entries + 1] = entry
      end
    end
  end

  sort_refs(entries, sortby)

  local names = {}
  for i, e in ipairs(entries) do
    names[i] = e.name
  end
  return names
end

---@param include_current? boolean
---@return string[]
function M.get_local_branches(include_current)
  return git2.with_repo(worktree_root(), function(repo)
    return list_branches(repo, true, false, include_current, config.values.sort_branches)
  end) or {}
end

---@param include_current? boolean
---@return string[]
function M.get_remote_branches(include_current)
  return git2.with_repo(worktree_root(), function(repo)
    return list_branches(repo, false, true, include_current, config.values.sort_branches)
  end) or {}
end

---@param include_current? boolean
---@return string[]
function M.get_all_branches(include_current)
  return git2.with_repo(worktree_root(), function(repo)
    return list_branches(repo, true, true, include_current, config.values.sort_branches)
  end) or {}
end

return M
