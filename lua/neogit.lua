local M = {}

local did_setup = false

---Setup neogit
---@param opts NeogitConfig
function M.setup(opts)
  if vim.fn.has("nvim-0.10") ~= 1 then
    vim.notify("Neogit HEAD requires at least NVIM 0.10 - Pin to tag 'v0.0.1' for NVIM 0.9.x")
    return
  end

  local config = require("neogit.config")
  local signs = require("neogit.lib.signs")
  local autocmds = require("neogit.autocmds")
  local hl = require("neogit.lib.hl")
  local state = require("neogit.lib.state")
  local logger = require("neogit.logger")

  if did_setup then
    logger.debug("Already did setup!")
    return
  end
  did_setup = true

  M.autocmd_group = vim.api.nvim_create_augroup("Neogit", { clear = false })

  M.status = require("neogit.buffers.status")

  M.dispatch_reset = function()
    local instance = M.status.instance()
    if instance then
      instance:dispatch_reset()
    end
  end

  M.refresh = function()
    local instance = M.status.instance()
    if instance then
      instance:refresh()
    end
  end

  M.reset = function()
    local instance = M.status.instance()
    if instance then
      instance:reset()
    end
  end

  M.dispatch_refresh = function()
    local instance = M.status.instance()
    if instance then
      instance:dispatch_refresh()
    end
  end

  M.close = function()
    local instance = M.status.instance()
    if instance then
      instance:close()
    end
  end

  M.lib = require("neogit.lib")
  M.cli = M.lib.git.cli
  M.popups = require("neogit.popups")
  M.config = config
  M.notification = require("neogit.lib.notification")

  config.setup(opts)
  hl.setup(config.values)
  signs.setup(config.values)
  state.setup(config.values)
  autocmds.setup()

  -- Warm the libgit2 binding in the background: the first status refresh
  -- otherwise pays ~100ms loading the shared library (ffi.load +
  -- git_libgit2_init) right when the user is watching. Doing it shortly
  -- after setup keeps that cost out of the first-open latency for anyone
  -- who opens neogit a moment later. Harmless with the CLI backend forced.
  if config.values.git_backend == nil or config.values.git_backend == "auto" then
    vim.defer_fn(function()
      require("neogit.lib.git.backend").current()
    end, 1000)
  end
end

local function construct_opts(opts)
  opts = opts or {}

  if opts.cwd and not opts.no_expand then
    opts.cwd = vim.fn.expand(opts.cwd)
  end

  if not opts.cwd then
    local git = require("neogit.lib.git")
    opts.cwd = git.cli.worktree_root(".")

    if opts.cwd == "" then
      opts.cwd = vim.uv.cwd()
    end
  end

  return opts
end

local function open_popup(name)
  local has_pop, popup = pcall(require, "neogit.popups." .. name)
  if not has_pop then
    M.notification.error(("Invalid popup %q"):format(name))
  else
    popup.create {}
  end
end

---Phase 2 completion for the two-phase status open: fill the provisional
---repo in place with the discovered metadata (every Repo.instance(cwd)
---caller sees the real repository from then on) and hand it to the status
---buffer, which attaches what `open` deferred and drives the first refresh.
local function bind_and_refresh(instance, info)
  local Repo = require("neogit.lib.git.repository")
  local repo = Repo.instance(instance.cwd)
  Repo.bind(repo, info)
  instance:bind_repository(repo)
end

local function open_status_buffer(opts)
  local status = require("neogit.buffers.status")
  local config = require("neogit.config")
  local git = require("neogit.lib.git")

  -- Double-open guard: a second :Neogit while a previous open (possibly
  -- with discovery still in flight) already shows this buffer only focuses
  -- it - a second discovery/bind must not race the first one. The refresh
  -- still runs (today's open():dispatch_refresh() semantics); on a still
  -- provisional repo it is a guarded no-op.
  local existing = status.instance(opts.cwd)
  if existing and existing.buffer and existing.buffer:is_visible() then
    existing:open(opts.kind)
    existing:dispatch_refresh()
    return
  end

  -- Phase 1 - optimistic open, ZERO git processes: show the status window
  -- right away on a provisional repo (paths empty, counts as un-refreshed),
  -- so the cold-open render (banner pulse + loading line) is on screen
  -- while discovery runs.
  local Repo = require("neogit.lib.git.repository")
  local repo = Repo.instance(opts.cwd, { autorefresh = false, provisional = true })
  local instance = status.new(config.values, repo.worktree_root, opts.cwd)
  instance:open(opts.kind)

  if not repo.provisional then
    -- Warm cache: the instance already existed bound (an earlier open or
    -- Repo.instance caller created it, rev-parse cached) - nothing to
    -- discover, just today's post-open refresh.
    instance:bind_repository(repo)
    return
  end

  -- Phase 2 - discovery, off the synchronous path: open() must not launch
  -- any git process, so the single async rev-parse batch starts on the next
  -- event-loop turn, with the window already on screen.
  instance._pending_binding = true
  vim.schedule(function()
    -- Closed again before discovery even started (fast toggle): leave the
    -- provisional repo behind, nothing is watching it.
    if not instance.buffer then
      return
    end

    git.cli.repo_info_async(opts.cwd, function(info)
      if not info.inside then
        local input = require("neogit.lib.input")
        if input.get_permission(("Initialize repository in %s?"):format(opts.cwd)) then
          git.init.create(opts.cwd)
          -- The "not a repository" answer is cached; drop it so the re-run
          -- sees the freshly created repository.
          git.cli.invalidate_repo_info(opts.cwd)
          git.cli.repo_info_async(opts.cwd, function(retried)
            bind_and_refresh(instance, retried)
          end)
        else
          -- Restore the old net effect of declining: an error and NO status
          -- buffer (the just-opened window closes; the pulse cleans up via
          -- the buffer's on_detach).
          M.notification.error("The current working directory is not a git repository")
          instance:close()
        end
        return
      end

      bind_and_refresh(instance, info)
    end)
  end)
end

---@alias Popup
---| "bisect"
---| "branch"
---| "branch_config"
---| "cherry_pick"
---| "commit"
---| "diff"
---| "fetch"
---| "help"
---| "ignore"
---| "log"
---| "merge"
---| "pull"
---| "push"
---| "rebase"
---| "remote"
---| "remote_config"
---| "reset"
---| "revert"
---| "stash"
---| "tag"
---| "worktree"

---@class OpenOpts
---@field cwd string|nil
---@field [1] Popup|nil
---@field kind string|nil
---@field no_expand boolean|nil

---@param opts OpenOpts|nil
function M.open(opts)
  if not did_setup then
    M.setup {}
  end

  opts = opts or {}

  local git = require("neogit.lib.git")

  if opts[1] ~= nil then
    -- Popup path: unchanged synchronous behavior - repository discovery
    -- (and the init-repo interaction) happen before anything opens.
    opts = construct_opts(opts)

    if not git.cli.is_inside_worktree(opts.cwd) then
      local input = require("neogit.lib.input")
      if input.get_permission(("Initialize repository in %s?"):format(opts.cwd)) then
        git.init.create(opts.cwd)
      else
        M.notification.error("The current working directory is not a git repository")
        return
      end
    end

    local a = require("neogit.lib.async")
    local cb = function()
      open_popup(opts[1])
    end

    a.void(function()
      git.repo:dispatch_refresh { source = "popup", callback = cb }
    end)()
  else
    -- Status path: two-phase optimistic open. Provisional cwd is whatever
    -- the caller gave (expanded) or the editor cwd - resolved against the
    -- real repository asynchronously AFTER the window is visible.
    if opts.cwd and not opts.no_expand then
      opts.cwd = vim.fn.expand(opts.cwd)
    end

    if not opts.cwd then
      opts.cwd = vim.uv.cwd()
    end

    open_status_buffer(opts)
  end
end

-- This can be used to create bindable functions for custom keybindings:
--   local neogit = require("neogit")
--   vim.keymap.set('n', '<leader>gcc', neogit.action('commit', 'commit', { '--verbose', '--all' }))
--
---@param popup  string Name of popup, as found in `lua/neogit/popups/*`
---@param action string Name of action for popup, found in `lua/neogit/popups/*/actions.lua`
---@param args   table? CLI arguments to pass to git command
---@return function
function M.action(popup, action, args)
  local util = require("neogit.lib.util")
  local git = require("neogit.lib.git")
  local a = require("neogit.lib.async")

  args = args or {}

  local internal_args = {
    graph = util.remove_item_from_table(args, "--graph"),
    color = util.remove_item_from_table(args, "--color"),
    decorate = util.remove_item_from_table(args, "--decorate"),
  }

  return function()
    a.void(function()
      local ok, actions = pcall(require, "neogit.popups." .. popup .. ".actions")
      if ok then
        local fn = actions[action]
        if fn then
          local action = function()
            fn {
              close = function() end,
              state = { env = {} },
              get_arguments = function()
                return args
              end,
              get_internal_arguments = function()
                return internal_args
              end,
            }
          end

          git.repo:dispatch_refresh { source = "action", callback = action }
        else
          M.notification.error(
            string.format(
              "Invalid action %s for %s popup\nValid actions are: %s",
              action,
              popup,
              table.concat(vim.tbl_keys(actions), ", ")
            )
          )
        end
      else
        M.notification.error("Invalid popup: " .. popup)
      end
    end)()
  end
end

function M.complete(arglead)
  if arglead:find("^kind=") then
    return {
      "kind=replace",
      "kind=tab",
      "kind=split",
      "kind=split_above",
      "kind=split_above_all",
      "kind=split_below",
      "kind=split_below_all",
      "kind=vsplit",
      "kind=floating",
      "kind=auto",
    }
  end

  if arglead:find("^cwd=") then
    return {
      "cwd=" .. vim.uv.cwd(),
    }
  end

  return vim.tbl_filter(function(arg)
    return arg:match("^" .. arglead)
  end, {
    "kind=",
    "cwd=",
    "bisect",
    "branch",
    "branch_config",
    "cherry_pick",
    "commit",
    "diff",
    "fetch",
    "help",
    "ignore",
    "log",
    "merge",
    "pull",
    "push",
    "rebase",
    "remote",
    "remote_config",
    "reset",
    "revert",
    "stash",
    "tag",
    "worktree",
  })
end

function M.get_log_file_path()
  return vim.fn.stdpath("cache") .. "/neogit.log"
end

function M.get_config()
  return M.config.values
end

return M
