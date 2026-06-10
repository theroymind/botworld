-- Engine-owned transient TOAST/HINT: one shared message + linger timer that every layer
-- routes its on-screen tells through (an unlock, a warning, a lineage beat). Lifted out
-- of the per-layer orchestrators (cell.lua / complexcell.lua each carried a byte-identical
-- copy) so the cadence + look live in ONE place and can never drift between phases. Pure
-- module state; love.* is touched ONLY inside draw(), so a bare require loads headless and
-- the show/update/expiry logic is spec-testable without a window.
local colors = require("lib.engine.ui.colors")
local text = require("lib.engine.ui.primitives.text")
local rect = require("lib.engine.ui.primitives.rect")

local toast = {}

-- A toast lingers this many seconds, then vanishes (fading over its final second). Lifted
-- from the old per-layer 4s to a single GLOBAL 7s here: a phase-2 hint was read too late
-- (or missed) at 4s, so every layer now shares the same +3s window. Public so specs derive
-- their timing from the constant, never a literal.
toast.LINGER_SECONDS = 7

-- Module-local state, shared across all layers (only one layer is active at a time, so a
-- single message/timer pair is enough). A fresh launch opens with no toast.
local message = nil
local timer = 0

-- Show a toast: set the text and arm the full linger window. Replaces any toast in flight.
function toast.show(msg)
  message = msg
  timer = toast.LINGER_SECONDS
end

-- Drain the linger timer (called from the active layer's update). A no-op once expired.
function toast.update(dt)
  if timer > 0 then
    timer = timer - dt
  end
end

-- Is a toast currently showing? (the timer is still running and a message is set).
function toast.is_active() return timer > 0 and message ~= nil end

-- Draw the toast centered near the top of the screen, fading out over its final second
-- (alpha = min(timer, 1)). love.* lives only here, at draw time. `width` is the screen
-- width to center within. A no-op when no toast is active.
function toast.draw(width)
  if not toast.is_active() then
    return
  end
  text(rect(0, 40, width, 22), message, {
    font = "hud_lg",
    color = colors.with_alpha(colors.ui.accent, math.min(timer, 1)),
    align = "center",
  })
end

return toast
