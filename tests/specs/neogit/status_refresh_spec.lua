-- dispatch_refresh coalescing: scheduling is per StatusBuffer instance and
-- dispatches landing in the same tick merge their partial diff-cache
-- invalidations instead of being dropped. (The old module-level flag let a
-- scheduled refresh for one buffer silently swallow every other instance's
-- dispatch in the same tick.)
local status = require("neogit.buffers.status")

---Minimal stand-in for a StatusBuffer: dispatch_refresh only touches
---_refresh_scheduled, _pending_partial and :refresh.
local function fake_buffer()
  return {
    _refresh_scheduled = false,
    _pending_partial = nil,
    calls = {},
    refresh = function(self, partial, reason)
      table.insert(self.calls, { partial = partial, reason = reason })
    end,
  }
end

local function wait_for_calls(fake, n)
  return vim.wait(1000, function()
    return #fake.calls >= n
  end, 10)
end

describe("status dispatch_refresh coalescing", function()
  it("coalesces same-tick dispatches and merges their partial filters", function()
    local fake = fake_buffer()

    status.dispatch_refresh(fake, { update_diffs = { "staged:a.txt" } }, "first")
    status.dispatch_refresh(fake, { update_diffs = { "unstaged:b.txt" } }, "second")

    assert.truthy(wait_for_calls(fake, 1), "the scheduled refresh must run")
    vim.wait(50) -- ensure no second refresh sneaks in
    assert.equal(1, #fake.calls, "same-tick dispatches must coalesce into one refresh")

    local partial = fake.calls[1].partial
    assert.truthy(partial, "merged partial must survive")
    assert.same({ "staged:a.txt", "unstaged:b.txt" }, partial.update_diffs)
    assert.equal("first", fake.calls[1].reason, "the first reason wins")
  end)

  it("deduplicates repeated filters while merging", function()
    local fake = fake_buffer()

    status.dispatch_refresh(fake, { update_diffs = { "staged:a.txt" } }, "first")
    status.dispatch_refresh(fake, { update_diffs = { "staged:a.txt", "*:*" } }, "second")

    assert.truthy(wait_for_calls(fake, 1))
    assert.same({ "staged:a.txt", "*:*" }, fake.calls[1].partial.update_diffs)
  end)

  it("lets a full refresh absorb a pending partial", function()
    local fake = fake_buffer()

    status.dispatch_refresh(fake, { update_diffs = { "staged:a.txt" } }, "partial")
    status.dispatch_refresh(fake, nil, "full")

    assert.truthy(wait_for_calls(fake, 1))
    vim.wait(50)
    assert.equal(1, #fake.calls)
    assert.is_nil(fake.calls[1].partial, "a full refresh absorbs partial invalidations")
  end)

  it("does not drop dispatches from other instances in the same tick", function()
    local a = fake_buffer()
    local b = fake_buffer()

    status.dispatch_refresh(a, { update_diffs = { "staged:a.txt" } }, "a")
    status.dispatch_refresh(b, { update_diffs = { "staged:b.txt" } }, "b")

    assert.truthy(wait_for_calls(a, 1), "instance A must refresh")
    assert.truthy(wait_for_calls(b, 1), "instance B must refresh (was dropped by the shared flag)")
    assert.equal(1, #a.calls)
    assert.equal(1, #b.calls)
    assert.same({ "staged:b.txt" }, b.calls[1].partial.update_diffs)
  end)

  it("schedules again after the tick completes", function()
    local fake = fake_buffer()

    status.dispatch_refresh(fake, nil, "one")
    assert.truthy(wait_for_calls(fake, 1))

    status.dispatch_refresh(fake, { update_diffs = { "*:*" } }, "two")
    assert.truthy(wait_for_calls(fake, 2), "a later dispatch must schedule a new refresh")
    assert.same({ "*:*" }, fake.calls[2].partial.update_diffs)
  end)
end)
