-- Standalone spec for lib/layers/cell/transition.lua (the end-of-phase-1 cinematic).
-- Plain Lua 5.1, no framework. The timeline touches love.* only inside draw, so
-- begin/update -- phase progression, the single reset fire at the white peak, the
-- callback routing, the active flag -- are all headless-testable without stubbing
-- love. Run: lua tests/transition_spec.lua
local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
package.path = root .. "/?.lua;" .. package.path

local transition = require("lib.layers.cell.transition")

local checks = 0

local function check(condition, label)
  checks = checks + 1
  if not condition then
    error("FAILED: " .. label, 2)
  end
end

-- Build an armed timeline with recording callbacks.
local function armed()
  local log = { focus = {}, shake = 0, resets = 0 }
  local t = transition.new()
  transition.begin(t, {
    x = 100,
    y = 200,
    on_focus = function(x, y, mult)
      log.focus[#log.focus + 1] = { x = x, y = y, mult = mult }
    end,
    on_shake = function()
      log.shake = log.shake + 1
    end,
    on_reset = function()
      log.resets = log.resets + 1
    end,
  })
  return t, log
end

-- Advance the timeline by `total` seconds in fixed steps.
local function step(t, total, dt)
  dt = dt or 1 / 60
  local elapsed = 0
  while elapsed < total do
    transition.update(t, dt)
    elapsed = elapsed + dt
  end
end

-- new() is inert; active() is false until begin().
local fresh = transition.new()
check(transition.active(fresh) == false, "new() is inert")

-- begin() arms it in the freeze phase and fires no callbacks yet.
local t, log = armed()
check(transition.active(t) == true, "begin() arms the timeline")
check(t.phase == "freeze", "begin() opens in freeze")
check(#log.focus == 0, "freeze fires no focus callback")
check(t.reset_done == false, "begin() leaves reset unfired")

-- The focus phase opens with the camera push-in onto the triggering cell.
step(t, transition.FREEZE + 0.05)
check(t.phase == "focus", "advances into focus after FREEZE")
check(#log.focus == 1, "focus fires exactly one focus callback")
check(log.focus[1].x == 100 and log.focus[1].y == 200, "focus targets the triggering cell")
check(log.focus[1].mult > 1, "focus pushes in past the fit zoom")

-- Marches through charge into blast.
step(t, transition.FOCUS)
check(t.phase == "charge", "advances into charge after FOCUS")
step(t, transition.CHARGE)
check(t.phase == "blast", "advances into blast after CHARGE")

-- The reset fires once, at the white peak, and never twice.
check(t.reset_done == false or log.resets <= 1, "reset has not over-fired entering blast")
step(t, transition.BLAST * transition.RESET_FRAC + 0.05)
check(t.reset_done == true, "reset fires at the white peak")
check(log.resets == 1, "reset fires exactly once")

-- The blast completes and the cinematic deactivates; further updates are no-ops.
step(t, transition.BLAST)
check(transition.active(t) == false, "deactivates when the blast completes")
check(log.resets == 1, "reset still fired exactly once after completion")
transition.update(t, 1) -- inert: must not throw or re-fire
check(log.resets == 1, "update on an inert timeline is a no-op")

-- A reset callback that itself re-begins the timeline (the orchestrator's
-- cell.load path doesn't, but guard against double-fire regardless): the reset
-- must fire once even across a coarse dt that overshoots the peak.
local t2, log2 = armed()
step(t2, transition.FREEZE + transition.FOCUS + transition.CHARGE) -- to the brink of blast
transition.update(t2, transition.BLAST) -- one giant step over the whole blast
check(log2.resets == 1, "a single oversized step still fires the reset exactly once")
check(transition.active(t2) == false, "oversized step completes the cinematic")

print(string.format("all tests passed (%d checks)", checks))
