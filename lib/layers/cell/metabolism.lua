-- Metabolism: the one manual knob of the cell layer. A dial in [0, 1] trades
-- growth against upkeep. Gain rises linearly with the dial; loss rises
-- super-linearly (LOSS_EXP > 1), so net growth peaks at an INTERIOR optimum
-- below the maximum -- pinning the dial to the wall is self-defeating. The
-- plateau around that optimum is deliberately wide and forgiving: the default
-- dial is survivable and the maturity gate is reachable untouched (the
-- relaxation litmus). Curve constants live as data at the top; behaviour is
-- derived from them. Pure Lua 5.1 (no love.*) so it runs headless under tests.
local metabolism = {}

local BASE = 2 -- baseline biomass units/sec at dial 0
local GROWTH_K = 3 -- linear gain slope
local LOSS_K = 2.5 -- super-linear loss scale
local LOSS_EXP = 1.8 -- > 1 is what makes high dials self-defeating
local DEFAULT_DIAL = 0.5 -- survivable resting position, well inside the plateau

metabolism.default_dial = DEFAULT_DIAL

local function clamp01(value)
  if value < 0 then
    return 0
  elseif value > 1 then
    return 1
  end
  return value
end

-- Biomass units/sec produced at this dial, before genome multipliers.
function metabolism.gain(dial) return BASE * (1 + GROWTH_K * clamp01(dial)) end

-- Biomass units/sec burned at this dial, before genome multipliers.
function metabolism.loss(dial) return BASE * LOSS_K * clamp01(dial) ^ LOSS_EXP end

-- Net biomass units/sec at this dial; the live readout the player optimises.
function metabolism.net(dial) return metabolism.gain(dial) - metabolism.loss(dial) end

-- Closed-form argmax of net(dial): d/d(dial)[gain - loss] = 0 gives
-- GROWTH_K = LOSS_K * LOSS_EXP * dial^(LOSS_EXP-1). Exposed for the readout's
-- "sweet spot" marker.
function metabolism.optimum()
  local dial = (GROWTH_K / (LOSS_K * LOSS_EXP)) ^ (1 / (LOSS_EXP - 1))
  return clamp01(dial)
end

return metabolism
