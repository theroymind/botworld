-- Standalone spec for lib/engine/layers.lua: the layer registry's load / reach / tick
-- gating. The load-bearing invariant: a layer that has NOT been reached (entered via
-- switch) must never tick OR load -- so an unentered phase can't produce, or leak UI
-- (toasts), in the background behind the active phase. A phase you've PASSED keeps
-- ticking (the idle design). Plain Lua 5.1, no framework; layers.lua has no love deps.
local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
package.path = root .. "/?.lua;" .. package.path

local layers = require("lib.engine.layers")

local checks = 0
local function check(condition, label)
  checks = checks + 1
  if not condition then
    error("FAILED: " .. label, 2)
  end
end

-- A stub layer that counts its load() and tick() calls.
local function make_layer()
  local layer = { loads = 0, ticks = 0 }
  layer.load = function() layer.loads = layer.loads + 1 end
  layer.tick = function() layer.ticks = layer.ticks + 1 end
  return layer
end

local a, b, c = make_layer(), make_layer(), make_layer()
layers.register("a", a)
layers.register("b", b)
layers.register("c", c)

-- Nothing ticks before any layer is reached.
layers.tick_all(0.1)
check(a.ticks == 0 and b.ticks == 0 and c.ticks == 0, "no layer ticks before any is reached")

-- Boot the first layer: load() runs once, and only the reached layer ticks.
layers.load("a")
check(a.loads == 1, "load() runs the layer's load() once")
layers.switch("a")
layers.tick_all(0.1)
check(a.ticks == 1, "the reached layer ticks")
check(b.ticks == 0 and c.ticks == 0, "an unreached layer never ticks (no background leak)")
check(b.loads == 0 and c.loads == 0, "an unreached layer is never loaded")

-- load() is idempotent: a second call does not re-run load() (so a re-entry can't
-- clobber a phase's live state).
layers.load("a")
check(a.loads == 1, "load() is idempotent -- a loaded layer is not reloaded")

-- Enter a second layer: it reaches + ticks, and the FIRST keeps ticking -- a passed
-- phase keeps producing in the background.
layers.switch("b")
layers.tick_all(0.1)
check(b.ticks == 1, "a newly entered layer ticks")
check(a.ticks == 2, "a passed layer keeps ticking in the background (the idle design)")
check(c.ticks == 0, "the still-unreached layer still never ticks")

-- switch() marks the entrant loaded, so a later load() is skipped: the seam sets a phase
-- up itself (enter_from_seam, NOT load), and this guards that state from a reload clobber.
check(b.loads == 0, "switch() alone does not call load() (the entrant set itself up)")
layers.load("b")
check(b.loads == 0, "switch() marked the layer loaded, so a later load() is skipped (no clobber)")

print("all tests passed (" .. checks .. " checks)")
