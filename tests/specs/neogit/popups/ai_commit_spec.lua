-- AI Commit (`m` in the commit popup): the generator seam. Covers the
-- success path end-to-end, the unconfigured-generator guard, config
-- validation, and context assembly. The empty/timeout fallback paths open
-- the real commit editor and are not headless-testable; they are covered by
-- code review instead.
local neogit = require("neogit")
local config = require("neogit.config")
local Repo = require("neogit.lib.git.repository")

local function workdir()
  local dir = vim.fn.tempname()
  vim.uv.fs_mkdir(dir, 493)
  local function run(...)
    local r = vim.system({ "git", "-C", dir, ... }):wait()
    assert(r.code == 0, tostring(r.stderr))
  end

  run("init", "-q", "-b", "main")
  run("config", "user.email", "t@t")
  run("config", "user.name", "t")

  local fd = assert(io.open(dir .. "/file.txt", "w"))
  fd:write("one\n")
  fd:close()
  run("add", "file.txt")

  return dir
end

local function last_message(dir)
  local r = vim.system({ "git", "-C", dir, "log", "-1", "--pretty=%s" }):wait()
  return vim.trim(r.stdout or "")
end

neogit.setup { filewatcher = { enabled = false }, disable_context_highlighting = true }

describe("commit popup AI Commit", function()
  before_each(function()
    config.values.ai_commit = { generator = nil, timeout = 30 }
  end)

  it("commits with the generated message without an editor", function()
    local dir = workdir()
    vim.cmd.cd(dir)
    Repo.instance(dir, { autorefresh = false })

    config.values.ai_commit.generator = function(done, ctx)
      assert.truthy(ctx.diff:find("file.txt", 1, true), "generator must receive the staged diff")
      done("generated: add file")
    end

    neogit.action("commit", "ai_commit", {})()

    assert.truthy(vim.wait(10000, function()
      return last_message(dir) == "generated: add file"
    end), "commit with generated message never landed")
  end)

  it("refreshes the status buffer after committing", function()
    local dir = workdir()
    vim.cmd.cd(dir)
    local Repo2 = require("neogit.lib.git.repository")
    Repo2.instance(dir, { autorefresh = false })

    local status_buf = require("neogit.buffers.status")
    local buf = status_buf.new(config.values, Repo2.instance(dir).worktree_root, dir)
    buf:open("split")

    local refreshed = 0
    vim.api.nvim_create_autocmd("User", {
      pattern = "NeogitStatusRefreshed",
      callback = function()
        refreshed = refreshed + 1
      end,
    })

    local fired = false
    vim.api.nvim_create_autocmd("User", {
      pattern = "NeogitStatusRefreshed",
      once = true,
      callback = function()
        fired = true
      end,
    })
    buf:dispatch_refresh()
    assert.truthy(vim.wait(10000, function()
      return fired
    end, 10), "initial refresh did not complete")
    vim.wait(100)
    local baseline = refreshed

    config.values.ai_commit.generator = function(done)
      done("feat: add file")
    end
    neogit.action("commit", "ai_commit", {})()

    assert.truthy(vim.wait(10000, function()
      return refreshed > baseline
    end, 10), "status buffer must refresh after an AI commit")
  end)

  it("warns instead of committing when no generator is configured", function()
    local dir = workdir()
    vim.cmd.cd(dir)
    Repo.instance(dir, { autorefresh = false })

    neogit.action("commit", "ai_commit", {})()
    vim.wait(200)

    local r = vim.system({ "git", "-C", dir, "log", "-1", "--pretty=%s" }):wait()
    assert.truthy(r.code ~= 0, "nothing must be committed (no HEAD yet)")
  end)

  it("assembles the staged context (files + diff)", function()
    local dir = workdir()
    vim.cmd.cd(dir)
    local repo = Repo.instance(dir, { autorefresh = false })
    repo.state.staged.items = { { name = "file.txt" } }

    local actions = require("neogit.popups.commit.actions")
    local ctx = actions.internal.staged_context()

    assert.truthy(vim.tbl_contains(ctx.files, "file.txt"), "staged file missing from ctx.files")
    assert.truthy(ctx.diff:find("+one", 1, true), "staged diff missing from ctx.diff")
  end)

  it("validates ai_commit config shape", function()
    config.values.ai_commit = "not-a-table"
    assert.truthy(vim.tbl_count(config.validate_config()) > 0, "ai_commit must be a table")

    config.values.ai_commit = { generator = "not-a-function", timeout = "x" }
    assert.truthy(vim.tbl_count(config.validate_config()) > 0, "generator/timeout types must be checked")

    config.values.ai_commit = { generator = function() end, timeout = 5 }
    assert.equal(0, vim.tbl_count(config.validate_config()))

    config.values.ai_commit = { model = "deepseek-flash", prompt = function() end, timeout = 30 }
    assert.equal(0, vim.tbl_count(config.validate_config()), "declarative fields must validate")

    config.values.ai_commit = { model = 42, prompt = {} }
    assert.truthy(vim.tbl_count(config.validate_config()) > 0, "bad declarative types must fail")
  end)

  describe("built-in OpenAI-compatible client", function()
    local ai = require("neogit.lib.ai")

    it("builds conventional-commit prompts from the context", function()
      local system_prompt, user_prompt =
        ai.build_prompts({ files = { "a.lua" }, diff = "+x" }, nil)
      assert.truthy(system_prompt:find("conventional", 1, true))
      assert.truthy(user_prompt:find("a.lua", 1, true))
      assert.truthy(user_prompt:find("+x", 1, true))

      local custom = ai.build_prompts({ files = {}, diff = "" }, function(ctx)
        return "custom for " .. #ctx.files .. " files"
      end)
      assert.equal("custom for 0 files", custom)
    end)

    it("parses chat/completions responses and rejects malformed ones", function()
      local ok_body = vim.json.encode({ choices = { { message = { content = "  feat: x \n" } } } })
      assert.equal("feat: x", ai.parse_response(ok_body))
      assert.equal("", ai.parse_response("not json"))
      assert.equal("", ai.parse_response(vim.json.encode({ choices = {} })))
      assert.equal("", ai.parse_response(vim.json.encode({ error = "x" })))
    end)

    it("resolves endpoints per backend", function()
      local url, token = ai.resolve_endpoint { backend = "openai", api_token_env = "HOME" }
      assert.equal("https://api.openai.com/v1", url)
      assert.truthy(token, "token must be read from the env var")

      url = ai.resolve_endpoint { backend = "ollama" }
      assert.equal("http://localhost:11434/v1", url)

      url = ai.resolve_endpoint { url = "https://api.deepseek.com/v1/" }
      assert.equal("https://api.deepseek.com/v1", url, "trailing slash must be trimmed")
    end)

    it("end-to-end: declarative model config commits without a generator", function()
      local dir = workdir()
      vim.cmd.cd(dir)
      Repo.instance(dir, { autorefresh = false })

      -- Intercept the process seam: pretend to be the backend.
      local real_spawn = ai.internal.spawn
      ai.internal.spawn = function(_args, cb)
        local body = vim.json.encode({ choices = { { message = { content = "feat: via builtin" } } } })
        cb({ code = 0, stdout = body })
      end

      config.values.ai_commit = {
        backend = "openai",
        url = "https://fake.local/v1",
        model = "deepseek-flash",
        api_token_env = "HOME",
        timeout = 30,
      }

      local landed
      neogit.action("commit", "ai_commit", {})()
      landed = vim.wait(10000, function()
        return last_message(dir) == "feat: via builtin"
      end)

      ai.internal.spawn = real_spawn
      assert.truthy(landed, "built-in client must commit the parsed message")
    end)
  end)

  describe("notification progress", function()
    local notification = require("neogit.lib.notification")

    local function stub_capability(on)
      local real = notification.internal.replace_capable
      notification.internal.replace_capable = function()
        return on
      end
      return function()
        notification.internal.replace_capable = real
      end
    end

    it("settles in place when replacement is supported", function()
      local restore = stub_capability(true)
      local calls = {}
      local real_notify = vim.notify
      local next_id = 0
      vim.notify = function(message, level, opts)
        next_id = next_id + 1
        table.insert(calls, { message = message, level = level, opts = opts, id = next_id })
        return next_id
      end

      local p = notification.progress("working")
      vim.wait(200) -- a few spinner frames
      p:done("done!", vim.log.levels.WARN)
      vim.wait(100)

      vim.notify = real_notify
      restore()
      assert.truthy(#calls >= 2, "spinner frames + final state must notify")

      -- every update after the first carries replace = previous id
      for i = 2, #calls do
        assert.equal(calls[i - 1].id, calls[i].opts.replace, "updates must replace in place")
      end

      local final = calls[#calls]
      assert.equal("done!", final.message)
      assert.equal(vim.log.levels.WARN, final.level, "final color follows the level")
    end)

    it("shows exactly two static notifications without replacement support", function()
      -- noice-style: returns an id-like table but ignores opts.replace
      local restore = stub_capability(false)
      local calls = {}
      local real_notify = vim.notify
      vim.notify = function(message, level, opts)
        table.insert(calls, { message = message, level = level, opts = opts })
        return { id = #calls }
      end

      local p = notification.progress("working")
      vim.wait(200) -- animation is off; no frame may spam
      p:done("done!", vim.log.levels.INFO)
      vim.wait(100)

      vim.notify = real_notify
      restore()
      assert.equal(2, #calls, "exactly the loading frame and the final state")
      assert.equal("working", calls[1].message)
      assert.equal("done!", calls[2].message)
    end)
  end)
end)
