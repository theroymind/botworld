-- Standalone spec for lib/layers/cell/metabolism.lua.
-- Plain Lua 5.1, no framework. Run from the repo root: lua tests/metabolism_spec.lua
local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
package.path = root .. "/?.lua;" .. package.path

local metabolism = require("lib.layers.cell.metabolism")

local checks = 0

local function check(condition, label)
  checks = checks + 1
  if not condition then
    error("FAILED: " .. label, 2)
  end
end

-- Dial is clamped to [0, 1] on every channel.
check(metabolism.gain(-1) == metabolism.gain(0), "gain clamps below 0")
check(metabolism.gain(2) == metabolism.gain(1), "gain clamps above 1")
check(metabolism.loss(-1) == metabolism.loss(0), "loss clamps below 0")
check(metabolism.loss(2) == metabolism.loss(1), "loss clamps above 1")

-- Gain rises with the dial; loss rises with the dial; net = gain - loss.
check(metabolism.gain(0.8) > metabolism.gain(0.2), "gain increases with dial")
check(metabolism.loss(0.8) > metabolism.loss(0.2), "loss increases with dial")
check(metabolism.net(0.5) == metabolism.gain(0.5) - metabolism.loss(0.5), "net is gain minus loss")

-- The optimum is strictly interior: a sweet spot, not the wall.
local optimum = metabolism.optimum()
check(optimum > 0 and optimum < 1, "optimum is interior to (0, 1)")

-- Interior optimum: net at the optimum beats net at the maximum dial. Pushing
-- the knob to the wall is self-defeating.
check(metabolism.net(optimum) > metabolism.net(1), "net at optimum > net at dial 1")

-- The optimum really is the argmax across a fine sweep.
local sweep_best = -math.huge
for i = 0, 100 do
  local n = metabolism.net(i / 100)
  if n > sweep_best then
    sweep_best = n
  end
end
check(metabolism.net(optimum) >= sweep_best - 1e-9, "closed-form optimum matches the sweep argmax")

-- Survivable: net is positive across the whole dial range, including the
-- extremes, so the cell never starves no matter where the knob sits.
check(metabolism.net(0) > 0, "net positive at dial 0 (survivable floor)")
check(metabolism.net(1) > 0, "net positive at dial 1 (survivable ceiling)")
check(metabolism.net(metabolism.default_dial) > 0, "net positive at the default dial")

-- Relaxation litmus: a wide band around the optimum yields >= 85% of the max,
-- and the default dial sits comfortably inside it.
local peak = metabolism.net(optimum)
local band_lo, band_hi
for i = 0, 100 do
  local dial = i / 100
  if metabolism.net(dial) >= 0.85 * peak then
    band_lo = band_lo or dial
    band_hi = dial
  end
end
check(band_hi - band_lo >= 0.4, "the >=85%-of-max band spans at least 0.4 of the dial")
local default_net = metabolism.net(metabolism.default_dial)
check(default_net >= 0.85 * peak, "default dial yields >= 85% of max net")
check(default_net <= peak, "default dial does not beat the optimum")

print("all tests passed (" .. checks .. " checks)")
