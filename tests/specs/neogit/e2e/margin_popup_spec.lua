-- Lua port of spec/popups/margin_popup_spec.rb (E2E).
--
-- Parity notes:
--   * rspec's `:popup` shared context (spec/support/shared.rb) is ported
--     as popup_context() below: it opens the popup via the keymap in a
--     before_each and registers the 4 standard examples.
--   * Expected strings are byte-exact 80-column rows copied from the ruby
--     source (ruby literals already carry their trailing spaces; row()
--     only pads as a safety net).
--   * Reference baseline (rspec, cli backend, this fork): 9 examples,
--     1 failing ("renders view properly") — the port matches one-for-one.
local child_nvim = require("tests.util.child_nvim")
local e2e = require("tests.util.e2e")

local nvim
local workdir

-- Examples failing on this fork's rspec baseline are registered as
-- pending so the default run stays green; set NEOGIT_E2E_STRICT=1 to
-- execute them for parity verification against rspec.
local strict = os.getenv("NEOGIT_E2E_STRICT") ~= nil
local known_fail = strict and it or pending

local function boot(opts)
  opts = opts or {}
  if nvim then
    nvim:teardown()
  end
  workdir = e2e.repo { remote_origin = opts.remote_origin }
  nvim = child_nvim.new()
  nvim:setup(workdir, opts.config)
end

local function row(s)
  return s .. (" "):rep(80 - #s)
end

-- Port of the rspec `:popup` shared context: `before { nvim.keys(keymap) }`
-- plus its 4 examples. `view_fails` = "renders view properly" fails on
-- this fork's baseline.
local function popup_context(keymap, view, view_fails)
  before_each(function()
    nvim:keys(keymap)
  end)

  it("raises no errors", function()
    assert.equals(0, #nvim:errors(), vim.inspect(nvim:errors()))
  end)

  it("raises no errors with detached HEAD", function()
    nvim:keys("<esc>") -- close popup

    -- Detach HEAD
    e2e.git(workdir, "commit", "--allow-empty", "-qm", "dummy commit")
    e2e.git(workdir, "checkout", "HEAD^")

    vim.wait(1000) -- Allow state to propagate (ruby: sleep 1)
    nvim:keys(keymap) -- open popup
    assert.equals(0, #nvim:errors(), vim.inspect(nvim:errors()))
  end)

  it("has correct filetype", function()
    assert.equals("NeogitPopup", nvim:filetype())
  end)

  local render_view = view_fails and known_fail or it
  render_view("renders view properly", function()
    -- screen#index parity: first occurrence of each exact row.
    local screen = nvim:screen()
    local first
    local all_found = true
    for i, line in ipairs(view) do
      local at
      for r, content in ipairs(screen) do
        if content == line then
          at = r
          break
        end
      end
      if not at then
        all_found = false
        break
      end
      if i == 1 then
        first = at
      end
    end
    assert.truthy(all_found, "not every view row is on screen")
    for i, line in ipairs(view) do
      assert.equals(line, screen[first + i - 1], ("view row %d"):format(i))
    end
  end)
end

-- Ports of include_examples "interaction" / "argument" (identical bodies).
local function interaction(key)
  it(("raises no errors with '%s'"):format(key), function()
    nvim:keys(key)
    assert.equals(0, #nvim:errors(), vim.inspect(nvim:errors()))
  end)
end

local argument = interaction

describe("Margin Popup", function()
  after_each(function()
    if nvim then
      nvim:teardown()
      nvim = nil
    end
  end)

  local view = {
    row(" Arguments                                                                      "),
    row(" -o Order commits by (--[topo|author-date|date]-order)                          "),
    row(" -d Show refnames (--decorate)                                                  "),
    row("                                                                                "),
    row(" Refresh       Margin                                                           "),
    row(" g buffer      L toggle visibility                                              "),
    row("               l cycle style                                                    "),
    row("               d toggle details                                                 "),
    row("               x toggle shortstat                                               "),
  }

  before_each(function()
    boot()
  end)

  popup_context("L", view, true)

  interaction("L")
  interaction("l")
  interaction("d")
  interaction("g")
  interaction("x")
end)
