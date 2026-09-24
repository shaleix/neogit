-- libgit2 twins for git.log: `message` (the `log -1 --format=%s` spawn killed
-- by P0's dedup, now taken off the spawn list entirely) and the
-- `update_recent` refresh task.
local config = require("neogit.config")
local state = require("neogit.lib.state")
local util = require("neogit.lib.util")
local git2 = require("neogit.lib.git2")
local ffi = require("ffi")

local M = {}

local function worktree_root()
  return require("neogit.lib.git").repo.worktree_root
end

---Equivalent of `git log --max-count=1 --format=%s <commit>`.
---@param commit string revspec
---@return string?
function M.message(commit)
  return git2.with_repo(worktree_root(), function(repo)
    local c = git2.commit_of(repo, commit)
    if not c then
      return nil
    end

    return c:summary()
  end)
end

--------------------------------------------------------------------------------
-- update_recent twin
--------------------------------------------------------------------------------

---Humanized relative date in git's `%cr` format ("2 hours ago",
---"1 year, 3 months ago"), following git's date.c show_date_relative so the
---status UI's post-processing matches byte-for-byte.
local function plural(n, unit)
  if n == 1 then
    return ("1 %s ago"):format(unit)
  end
  return ("%d %ss ago"):format(n, unit)
end

local function relative_date(unix_time)
  local diff = os.time() - unix_time
  if diff < 0 then
    diff = 0
  end

  if diff < 90 then
    return plural(diff, "second")
  end

  local minutes = math.floor((diff + 30) / 60)
  if minutes < 90 then
    return plural(minutes, "minute")
  end

  local hours = math.floor((minutes + 30) / 60)
  if hours < 36 then
    return plural(hours, "hour")
  end

  local days = math.floor((hours + 12) / 24)
  if days < 14 then
    return plural(days, "day")
  elseif days < 70 then
    return plural(math.floor((days + 3) / 7), "week")
  elseif days < 365 then
    return plural(math.floor((days + 15) / 30), "month")
  elseif days < 1825 then
    local totalmonths = math.floor((days * 12 * 2 + 365) / (365 * 2))
    local years = math.floor(totalmonths / 12)
    local months = totalmonths % 12
    if months > 0 then
      return ("%d %s, %d %s ago"):format(
        years,
        years == 1 and "year" or "years",
        months,
        months == 1 and "month" or "months"
      )
    end
    return plural(years, "year")
  else
    return plural(math.floor((days + 183) / 365), "year")
  end
end
M.relative_date = relative_date
local function decoration_map(repo)
  local map = {}
  local names = {}

  -- Collect first, resolve after: calling git_reference_lookup/peel inside
  -- the foreach callback re-enters libgit2 while the iterator is alive,
  -- which can deadlock or misbehave on some builds.
  git2.each_ref_name(repo, function(full)
    names[#names + 1] = full
    return true
  end)

  for _, full in ipairs(names) do
    local entry
    if full:match("^refs/heads/") or full:match("^refs/remotes/") then
      entry = full:gsub("^refs/[^/]*/", "")
    elseif full:match("^refs/tags/") then
      entry = "tag: " .. full:sub(#"refs/tags/" + 1)
    end
    if entry then
      local ok, commit = pcall(function()
        local ref = repo:reference_lookup(full)
        assert(ref, "reference_lookup failed for " .. full)
        return ref:peel_commit()
      end)
      if ok and commit then
        local hex = git2.oid_hex(commit:id().oid)
        map[hex] = map[hex] or {}
        map[hex][#map[hex] + 1] = entry
      end
    end
  end

  -- HEAD marker: arrow when on a branch, plain "HEAD" when detached.
  local head_ref = repo:head()
  if head_ref then
    local ok, commit = pcall(function()
      return head_ref:peel_commit()
    end)
    if ok and commit then
      local hex = git2.oid_hex(commit:id().oid)
      map[hex] = map[hex] or {}

      local arrow_branch = nil
      local marker
      if repo:is_head_detached() then
        marker = "HEAD"
      else
        arrow_branch = head_ref:shorthand()
        marker = "HEAD -> " .. arrow_branch
      end
      table.insert(map[hex], 1, marker)

      if arrow_branch then
        -- git's %D shows the arrow form only; drop the plain duplicate
        for i = #map[hex], 2, -1 do
          if map[hex][i] == arrow_branch then
            table.remove(map[hex], i)
          end
        end
      end
    end
  end

  return map
end

---update_recent twin: fill state.recent.items via revwalk + decorations.
---Signature matches the update_* contract plus the per-cycle context.
---
---Failure contract: like the status twin, every fallible call happens
---before state mutation and raises on failure, so Repo:tasks can degrade
---this module to the CLI backend for the cycle.
---@param repo_state NeogitRepoState
---@param _filter table?
---@param ctx { repo: table? }? per-refresh repository handle
function M.update_recent(repo_state, _filter, ctx)
  local count = config.values.status.recent_commit_count
  if count <= 0 then
    repo_state.recent = { items = {} }
    return
  end

  local order = state.get({ "NeogitMarginPopup", "-order" }, config.values.commit_order)

  git2.run(function()
    local repo = (ctx and ctx.repo) or git2.open_repo(worktree_root(), true)
    if not repo then
      error(("libgit2: cannot open repository at %q"):format(worktree_root()))
    end

    local git = require("neogit.lib.git")

    local walker = repo:walker()
    if order == "date" then
      walker:sort(false, true, false)
    else
      walker:sort(true, false, false)
    end
    walker:push_head()

    local decorations = decoration_map(repo)
    local records = {}

    for oid, commit in walker:iter() do
      if #records >= count then
        break
      end

      local hex = oid:tostring(40)
      local lg2 = git2.binding.libgit2()
      local sig = lg2.C.git_commit_committer(commit.commit)
      local committer_time = tonumber(sig.when.time) or 0
      local author_name = ffi.string(lg2.C.git_commit_author(commit.commit).name)

      records[#records + 1] = {
        oid = hex,
        abbreviated_commit = hex:sub(1, git.log.abbreviated_size()),
        subject = commit:summary(),
        ref_name = table.concat(decorations[hex] or {}, ", "),
        rel_date = relative_date(committer_time),
        author_name = author_name,
        author_date = committer_time,
        committer_date = committer_time,
        unix_date = committer_time,
      }
    end

    repo_state.recent = { items = util.filter_map(records, git.log.present_commit) }
  end)
end

--------------------------------------------------------------------------------
-- log.list twin (records via revwalk; graph delegated to the shared helpers)
--------------------------------------------------------------------------------

---RFC2822 date like git's %aD/%cD ("Sun, 20 Sep 2026 17:49:39 +0800").
local function rfc2822(time, offset_minutes)
  local utc = os.date("!%a, %d %b %Y %H:%M:%S", time + offset_minutes * 60)
  local sign = offset_minutes < 0 and "-" or "+"
  local abs = math.abs(offset_minutes)
  return ("%s %s%02d%02d"):format(utc, sign, math.floor(abs / 60), abs % 60)
end

---Which option shapes the twin can serve; anything else falls back to CLI.
---A single rev spec ("HEAD", an oid, "@{upstream}") or one range
---("A..B", "..B", "A..") is accepted alongside the known flags.
---@param options string[]
---@param files string[]
---@return boolean
function M.supports(options, files)
  if files and #files > 0 then
    return false
  end

  local specs = 0

  for _, o in ipairs(options or {}) do
    local is_flag = o:match("^%-%-max%-count=%d+$")
      or o:match("^%-%-topo%-order$")
      or o:match("^%-%-date%-order$")
      or o:match("^%-%-reverse$")
      or o == "--all"

    if not is_flag then
      if o:sub(1, 1) == "-" then
        return false
      end

      specs = specs + 1
      if specs > 1 then
        return false
      end
    end
  end

  return true
end

---git's %s/%b from the raw (cached) commit message: subject = folded first
---paragraph, body = remainder after the first blank line. NB: the CLI
---record pipeline strips newlines from the body entirely (NUL/NL handling
---joins the lines without a separator) - mirror that, or multi-line body
---text reaches nvim_buf_set_lines and freezes the log view.
local function subject_and_body(raw)
  local head, rest = raw:match("^(.-)\n\n(.*)$")
  if not head then
    head, rest = raw, nil
  end

  local subject = (head:gsub("\n", " ")):gsub("%s+$", "")
  local body = rest and (rest:gsub("^%s+", "")):gsub("[\n\r]", "") or ""
  return subject, body
end

---Length of this repository's abbreviated OIDs (git's own auto-sizing),
---from HEAD's short id. Zero-spawn under the libgit2 backend.
---@return number
function M.abbrev_size()
  return git2.with_repo(worktree_root(), function(repo)
    local lg2 = git2.binding.libgit2()
    local ffi = require("ffi")

    local out = lg2.git_buf()
    local commit = git2.commit_of(repo, "HEAD")
    if not commit then
      return 7
    end

    local ok = pcall(function()
      lg2.C.git_object_short_id(out, ffi.cast("const git_object*", commit.commit))
    end)
    if not ok then
      return 7
    end

    local len = tonumber(out[0].size) or 0
    lg2.C.git_buf_dispose(out)
    return len > 0 and len or 7
  end) or 7
end

---@param options string[]
---@param graph? table
---@param files string[]
---@param graph_color? boolean
---@return CommitLogEntry[]
function M.list(options, graph, files, graph_color)
  local log = require("neogit.lib.git.log")

  local count, order, reverse, all = nil, "topo", false, false
  local revspec = nil
  for _, o in ipairs(options or {}) do
    local n = o:match("^%-%-max%-count=(%d+)$")
    if n then
      count = tonumber(n)
    elseif o == "--date-order" then
      order = "date"
    elseif o == "--topo-order" then
      order = "topo"
    elseif o == "--reverse" then
      reverse = true
    elseif o == "--all" then
      all = true
    elseif o:sub(1, 1) ~= "-" then
      revspec = o
    end
  end

  local records = git2.with_repo(worktree_root(), function(repo)
    local out = {}

    git2.run(function()
      local lg2 = git2.binding.libgit2()
      local lg2C = lg2.C
      local git2mod = git2.binding.git2()

      local walker = repo:walker()
      if order == "date" then
        walker:sort(false, true, false)
      else
        walker:sort(true, false, false)
      end

      local function oid_of(spec)
        local hex = git2.oid_of(repo, spec)
        return hex and git2mod.ObjectId.from_string(hex)
      end

      if revspec then
        local left, right = revspec:match("^(.*)%.%.(.*)$")
        if left or right then
          -- "A..B": reachable from B, hiding A's history; empty sides mean HEAD
          local push_oid = oid_of(right ~= "" and right or "HEAD")
          local hide_oid = oid_of(left ~= "" and left or "HEAD")

          if push_oid then
            walker:push(push_oid)
          end
          if hide_oid then
            walker:hide(hide_oid)
          end
        else
          local push_oid = oid_of(revspec)
          if push_oid then
            walker:push(push_oid)
          end
        end
      elseif all then
        walker:push_glob("*")
      else
        walker:push_head()
      end

      local decorations = decoration_map(repo)
      local abbrev = log.abbreviated_size()

      -- Hot loop: raw C iteration, no per-commit wrapper objects/ffi.gc.
      local oid_buf = ffi.new("git_oid[1]")
      local commit_out = ffi.new("git_commit*[1]")

      while count == nil or #out < count do
        if lg2C.git_revwalk_next(oid_buf, walker.revwalk) ~= 0 then
          break
        end
        if lg2C.git_commit_lookup(commit_out, repo.repo, oid_buf) ~= 0 then
          break
        end

        local ccommit = commit_out[0]
        local hex = git2.oid_hex(oid_buf)

        local a_sig = lg2C.git_commit_author(ccommit)
        local c_sig = lg2C.git_commit_committer(ccommit)

        local parents = {}
        local nparents = tonumber(lg2C.git_commit_parentcount(ccommit)) or 0
        for i = 0, nparents - 1 do
          parents[#parents + 1] = git2.oid_hex(lg2C.git_commit_parent_id(ccommit, i))
        end

        local subject, body = subject_and_body(ffi.string(lg2C.git_commit_message(ccommit)))
        local c_time = tonumber(c_sig.when.time) or 0
        local c_offset = tonumber(c_sig.when.offset) or 0

        out[#out + 1] = {
          oid = hex,
          abbreviated_commit = hex:sub(1, abbrev),
          parent = table.concat(parents, " "),
          abbreviated_parent = table.concat(
            vim.tbl_map(function(p)
              return p:sub(1, abbrev)
            end, parents),
            " "
          ),
          author_name = ffi.string(a_sig.name),
          author_email = ffi.string(a_sig.email),
          committer_name = ffi.string(c_sig.name),
          committer_email = ffi.string(c_sig.email),
          author_date = rfc2822(tonumber(a_sig.when.time) or 0, tonumber(a_sig.when.offset) or 0),
          committer_date = rfc2822(c_time, c_offset),
          log_date = rfc2822(c_time, c_offset),
          rel_date = relative_date(c_time),
          unix_date = c_time,
          ref_name = table.concat(decorations[hex] or {}, ", "),
          subject = subject,
          body = body,
        }

        lg2C.git_commit_free(ccommit)
      end
    end)

    if reverse then
      local flipped = {}
      for i = #out, 1, -1 do
        flipped[#flipped + 1] = out[i]
      end
      out = flipped
    end

    return out
  end)

  if records == nil then
    -- repository open failed (logged in git2.open_repo): return nil so the
    -- CLI dispatcher in git/log.lua falls back instead of silently serving
    -- an empty log view
    return nil
  end

  if vim.tbl_isempty(records) then
    return {}
  end

  local g = {}
  if graph then
    g = log.internal.graph_rows(options, files, records, graph_color)
  end

  return log.internal.parse_log(records, g)
end

---Build a map of commit-oid -> %D-style decoration parts ("HEAD -> x",
---"origin/x", "tag: v1", plain branch names), matching what branch_info
---parses out of `git log --format=%D`.
---
---Note: libgit2 1.9 removed `git_reference_iterator_next`; only
---`next_name` remains (it has existed since 0.28), so we iterate names and
---resolve each reference for peeling.
---@param repo table git2.Repository wrapper
---@return table<string, string[]>
return M
