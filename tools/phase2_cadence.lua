#!/usr/bin/env lua
-- phase2_cadence.lua -- throwaway tuning harness for the stair-step stage reveals.
-- Drives the REAL catalog + sim (so it reflects catalog.GATES / FORK_AT / value math
-- exactly) with the same balanced buyer the catalog spec's end-to-end uses, and prints
-- the wall-clock time of each stage DISCOVERY and INTEGRATION plus the FORK. Lets us
-- sweep candidate gate thresholds / FORK_AT without touching the catalog each time.
--
-- USAGE: lua tools/phase2_cadence.lua [er golgi transport membrane fork value]
package.path = "./?.lua;" .. package.path

local sim = require("lib.layers.complexcell.sim")
local catalog = require("lib.layers.complexcell.catalog")

-- Optional overrides from argv so we can sweep without editing the catalog.
local function num(i, d) return tonumber(arg[i]) or d end
if arg[1] then
  catalog.GATES[2].at = num(1, catalog.GATES[2].at) -- er
  catalog.GATES[3].at = num(2, catalog.GATES[3].at) -- golgi
  catalog.GATES[4].at = num(3, catalog.GATES[4].at) -- transport
  catalog.GATES[5].at = num(4, catalog.GATES[5].at) -- membrane
end
if arg[5] then catalog.FORK_AT = num(5, catalog.FORK_AT) end
if arg[6] then catalog.VALUE_PER_STAGE = num(6, catalog.VALUE_PER_STAGE) end

local dt = 0.5
local max_t = 60 * 30
local STAGES = catalog.STAGES

local function fmt(s)
  if not s then return "  --  " end
  if s < 90 then return string.format("%5.0fs", s) end
  return string.format("%4.1fm", s / 60)
end

local s = sim.new()
s.unlocked.ribosomes = true
s.stages.ribosomes = 1

local discover_t, integrate_t = {}, {}
local fork_time

-- Integrate the soonest discovered-but-unlocked stage if affordable (mirrors the spec).
local function try_integrate(st, t)
  for _, g in ipairs(catalog.GATES) do
    if catalog.is_discovered(st, g.id) and not st.unlocked[g.id] then
      local cost = catalog.stage_unlock_cost(g.id)
      if cost <= st.energy then
        st.energy = st.energy - cost
        catalog.unlock_stage(st, g.id)
        integrate_t[g.id] = integrate_t[g.id] or t
        return true
      end
      return false
    end
  end
  return false
end

local curve_mode = (arg[1] == "curve")
local next_sample = 0
local t = 0
while t < max_t do
  local rates = catalog.fold(s)
  sim.step(s, dt, rates)
  t = t + dt
  if curve_mode and t >= next_sample then
    next_sample = next_sample + 15
    io.write(string.format("t=%5.1fm built=%-10.0f thru=%-7.1f mito=%d\n",
      t / 60, s.built, rates.throughput, s.mito))
  end
  local newly = catalog.discover_gates(s)
  for _, id in ipairs(newly) do
    discover_t[id] = discover_t[id] or t
  end
  if not fork_time and catalog.reached_fork(s) then
    fork_time = t
    break
  end
  local buys = 0
  while buys < 50 do
    if try_integrate(s, t) then
      buys = buys + 1
    else
      local id = catalog.bottleneck_id(s)
      local mc = catalog.mito_cost(s.mito)
      local sc = id and catalog.stage_cost(s.stages[id] or 0) or math.huge
      local mito_first = mc <= sc
      local cost = mito_first and mc or sc
      if cost > s.energy then break end
      s.energy = s.energy - cost
      if mito_first then
        s.mito = s.mito + 1
      else
        s.stages[id] = (s.stages[id] or 0) + 1
      end
      buys = buys + 1
    end
  end
end

print(string.format(
  "gates: er=%d golgi=%d transport=%d membrane=%d  fork=%d  value=%.2f",
  catalog.GATES[2].at, catalog.GATES[3].at, catalog.GATES[4].at,
  catalog.GATES[5].at, catalog.FORK_AT, catalog.VALUE_PER_STAGE
))
print(string.rep("-", 56))
print(string.format("%-12s %10s %10s", "stage", "discover", "integrate"))
for _, id in ipairs(STAGES) do
  if id ~= "ribosomes" then
    print(string.format("%-12s %10s %10s", id, fmt(discover_t[id]), fmt(integrate_t[id])))
  end
end
print(string.rep("-", 56))
print(string.format("FORK at %s  (built target %d, mito %d)", fmt(fork_time), catalog.FORK_AT, s.mito))
