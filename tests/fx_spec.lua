-- Standalone spec for lib/engine/fx.lua (the composable effects controller).
-- Plain Lua 5.1, no framework. fx touches love.* only inside draw closures, so
-- the controller, update, factories, and camera_offset are headless-testable
-- without stubbing love. Run: lua tests/fx_spec.lua
local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
package.path = root .. "/?.lua;" .. package.path

local fx = require("lib.engine.fx")

local checks = 0

local function check(condition, label)
  checks = checks + 1
  if not condition then
    error("FAILED: " .. label, 2)
  end
end

local function approx(a, b) return math.abs(a - b) < 1e-9 end

-- A fresh controller holds an empty effect list.
local ctrl = fx.new()
check(
  type(ctrl.effects) == "table" and #ctrl.effects == 0,
  "new() controller has an empty effects list"
)

-- add appends and returns the effect; a custom effect entity drives the lifecycle.
local e = {
  age = 0,
  life = 1,
  update = function(self, dt)
    self.age = self.age + dt
    return self.age >= self.life
  end,
}
local returned = fx.add(ctrl, e)
check(returned == e, "fx.add returns the added effect")
check(#ctrl.effects == 1, "fx.add appends the effect")

-- update advances effects; an effect lives until its update reports done.
fx.update(ctrl, 0.5)
check(approx(e.age, 0.5), "update advances the effect's age")
check(#ctrl.effects == 1, "effect survives before its life elapses")
fx.update(ctrl, 0.6) -- age 1.1 >= life
check(#ctrl.effects == 0, "expired effect is dropped")

-- shake: contributes a transient camera offset that decays to zero. With freq=0
-- the offset magnitude is purely the linear decay, so it is monotone.
local c2 = fx.new()
fx.add(c2, fx.shake({ life = 1, mag = 10, freq = 0, seed = 0 }))
local ox0, oy0 = fx.camera_offset(c2)
local m0 = math.sqrt(ox0 * ox0 + oy0 * oy0)
check(m0 > 0, "an active shake yields a nonzero camera offset")
check(approx(ox0, 10), "shake offset at age 0 is the peak magnitude (freq 0, seed 0)")
fx.update(c2, 0.5)
local ox1, oy1 = fx.camera_offset(c2)
local m1 = math.sqrt(ox1 * ox1 + oy1 * oy1)
check(m1 < m0, "shake offset decays over its life")
fx.update(c2, 0.6) -- expire
check(#c2.effects == 0, "shake expires after its life")
local ox2, oy2 = fx.camera_offset(c2)
check(ox2 == 0 and oy2 == 0, "no active shakes -> zero camera offset")

-- Multiple shakes sum their offsets (composition).
local c3 = fx.new()
fx.add(c3, fx.shake({ life = 1, mag = 10, freq = 0, seed = 0 }))
fx.add(c3, fx.shake({ life = 1, mag = 10, freq = 0, seed = 0 }))
local sx = fx.camera_offset(c3)
check(approx(sx, 20), "two identical shakes sum their camera offsets")

-- flash is a screen-space overlay effect carrying a draw + update.
local fl = fx.flash({})
check(fl.space == "overlay", "flash is an overlay-space effect")
check(type(fl.draw) == "function" and type(fl.update) == "function", "flash carries draw + update")

-- pulse is a world-space effect carrying its position + a draw.
local pu = fx.pulse({ x = 5, y = 7 })
check(pu.space == "world", "pulse is a world-space effect")
check(pu.x == 5 and pu.y == 7, "pulse carries its world position")
check(type(pu.draw) == "function" and type(pu.update) == "function", "pulse carries draw + update")

-- draw_world / draw_overlay route by space and ignore offset-only effects.
-- (We don't render here -- just confirm the controller partitions cleanly.)
local c4 = fx.new()
fx.add(c4, fx.pulse({ x = 0, y = 0 }))
fx.add(c4, fx.flash({}))
fx.add(c4, fx.shake({}))
local world_n, overlay_n, offset_n = 0, 0, 0
for _, fx_e in ipairs(c4.effects) do
  if fx_e.space == "world" then
    world_n = world_n + 1
  elseif fx_e.space == "overlay" then
    overlay_n = overlay_n + 1
  end
  if fx_e.offset then
    offset_n = offset_n + 1
  end
end
check(world_n == 1, "one world-space effect (pulse)")
check(overlay_n == 1, "one overlay-space effect (flash)")
check(offset_n == 1, "one offset-contributing effect (shake)")

print("all tests passed (" .. checks .. " checks)")
