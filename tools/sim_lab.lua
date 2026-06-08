#!/usr/bin/env lua
-- sim_lab.lua -- headless balance harness for the cell layer.
--
-- WHY THIS EXISTS
--   The cell economy (lib/layers/cell/sim.lua) is a pure, deterministic closed
--   form, and the orchestrator (cell.lua) folds traits + organelles + tuning
--   constants into the `intake` table the economy runs on. That makes the whole
--   layer testable WITHOUT love2d: load the real modules, rebuild the same
--   intake fold here, and we can measure the exact growth curve any config
--   produces -- carrying capacity K, time-to-K, division rate -- and A/B two
--   configs to see the IMPACT of a change before touching the game.
--
--   Trait SYNERGY is now SHIPPED (folded into traits.stats: reach -> forage cap,
--   thrift -> upkeep), so it comes through automatically -- the harness mirrors
--   the live game (sanity: the maxed colony now prints K = 110, up from the
--   pre-synergy 91). BIOFILM is still a PROPOSED mechanic, gated behind a config
--   flag and off by default: a network stage where cells share nutrients so the
--   food cap tracks colony size (the "busy network").
--
-- USAGE
--   lua tools/sim_lab.lua                 -- scenario comparison table
--   lua tools/sim_lab.lua sweep forage_cap 1 40 1
--   lua tools/sim_lab.lua curve <scenario> [out.csv]
--
-- Pure Lua 5.1. Run from the repo root.

package.path = "./?.lua;" .. package.path

local sim = require("lib.layers.cell.sim")
local metabolism = require("lib.layers.cell.metabolism")
local traits = require("lib.layers.cell.traits")
local organelles = require("lib.layers.cell.organelles")

-- ---------------------------------------------------------------------------
-- Game constants, mirrored from lib/layers/cell.lua. Kept here as the BASELINE
-- defaults; a config can override any of them to test a tuning change. If these
-- drift from cell.lua the scenario sanity check (K == 91) will catch it.
-- ---------------------------------------------------------------------------
local DEFAULTS = {
  forage_cap = 5, -- FORAGE_CAP   : foraging saturates past this many cells
  upkeep_scale = 1.3, -- UPKEEP_SCALE : per-cell upkeep multiplier
  photo_light = 30, -- PHOTO_LIGHT  : flat light income once photosynthesis unlocks
}
local FIXED_TEMPO = metabolism.optimum() -- the baked-in metabolism dial position

-- Trait synergy is SHIPPED in lib/layers/cell/traits.lua (reach = Motility x
-- Chemotaxis -> forage_cap_mult; thrift = Digestion x Evasion -> upkeep_mult), so
-- it arrives through traits.stats() below -- nothing to model here. To tune it,
-- edit SYN_REACH / SYN_THRIFT in traits.lua and re-run this harness.

-- ---------------------------------------------------------------------------
-- PROPOSED MECHANIC: biofilm. A late milestone where the colony stops being a
-- loose swarm and becomes a connected NETWORK. Mechanically the network shares
-- nutrients, so the forage cap is no longer fixed at 5 -- it tracks population
-- (cap_eff = base + LINK * pop). That removes the saturation that pins K. To
-- keep it idle-safe and self-defeating (the core verb), a super-linear DIFFUSION
-- penalty grows upkeep with density (upkeep *= 1 + DIFFUSION * pop). Linear
-- benefit vs. quadratic cost -> a NEW, far larger interior K (hundreds-to-
-- thousands), and a dense, busy network on screen, not a runaway.
-- `stage` scales both knobs so the biofilm itself is a progression track.
-- ---------------------------------------------------------------------------
local BIOFILM_LINK = 1.0 -- per-stage: cap gains this many slots per cell
local BIOFILM_DIFFUSION = 0.0012 -- per-stage: upkeep penalty per cell (the self-defeat)

-- Build the intake fold for a config at a given population. Population matters
-- only when biofilm is on (cap + upkeep become pop-dependent); the base game is
-- pop-independent and this returns the same table every call.
local function intake_for(cfg, population)
  local tstate = { levels = cfg.levels, unlocked = cfg.unlocked }
  local stats = traits.stats(tstate)
  local set = cfg.organelles or {}

  local photo = 0
  if cfg.unlocked.photosynthesis then
    photo = cfg.photo_light * stats.photo_mult
  end
  photo = photo + organelles.photo_bonus(set)

  -- Synergy is already folded into stats (forage_cap_mult + upkeep_mult), so it
  -- comes through here automatically -- the harness mirrors the shipped game.
  local forage_cap = cfg.forage_cap * stats.forage_cap_mult
  local upkeep = metabolism.loss(FIXED_TEMPO) * stats.upkeep_mult * cfg.upkeep_scale

  -- Biofilm overlay (proposed): cap tracks pop, upkeep gains a density penalty.
  if cfg.biofilm and cfg.biofilm > 0 then
    local s = cfg.biofilm
    forage_cap = forage_cap + BIOFILM_LINK * s * (population or 1)
    upkeep = upkeep * (1 + BIOFILM_DIFFUSION * s * (population or 1))
  end

  return {
    photo = photo,
    forage_per_cell = metabolism.gain(FIXED_TEMPO) * stats.forage_mult,
    forage_cap = forage_cap,
    upkeep_per_cell = upkeep,
    mult = traits.income_mult(tstate) * organelles.intake_mult(set),
    div_mult = stats.div_mult,
  }
end

-- Run the REAL economy step forward and report the growth curve. Recomputes
-- intake each tick so pop-dependent (biofilm) models are handled exactly; for
-- the base game intake is constant so this matches sim.capacity to the integer.
-- Returns: K (steady-state pop), t50/t90 (seconds to 50%/90% of K), peak rate,
-- and the curve samples for CSV.
local function run(cfg, opts)
  opts = opts or {}
  local dt = opts.dt or 0.5
  local max_t = opts.max_t or 60 * 60 * 6 -- 6h cap
  local state = sim.new()
  state.organelles = cfg.organelles or {}

  local curve = {}
  local t = 0
  local peak_rate, stable_for, last_pop = 0, 0, 1
  local K
  while t < max_t do
    local intake = intake_for(cfg, state.population)
    sim.step(state, dt, intake)
    t = t + dt
    if state.div_rate > peak_rate then
      peak_rate = state.div_rate
    end
    if t % 5 < dt then
      curve[#curve + 1] = { t = t, pop = state.population, rate = state.div_rate, biomass = state.biomass }
    end
    -- Steady state: population has not changed for a sustained window.
    if state.population == last_pop then
      stable_for = stable_for + dt
      if stable_for >= 120 then
        K = state.population
        break
      end
    else
      stable_for = 0
      last_pop = state.population
    end
  end
  K = K or state.population

  -- Second pass for t50/t90 now that K is known.
  local s2 = sim.new()
  s2.organelles = cfg.organelles or {}
  local t2, t50, t90 = 0, nil, nil
  while t2 < max_t and not (t50 and t90) do
    local intake = intake_for(cfg, s2.population)
    sim.step(s2, dt, intake)
    t2 = t2 + dt
    if not t50 and s2.population >= 0.5 * K then
      t50 = t2
    end
    if not t90 and s2.population >= 0.9 * K then
      t90 = t2
    end
  end

  return {
    K = K,
    t50 = t50,
    t90 = t90,
    peak_rate = peak_rate,
    closed_form_K = sim.capacity(intake_for(cfg, 1)), -- exact for non-biofilm
    curve = curve,
  }
end

-- ---------------------------------------------------------------------------
-- Config builders.
-- ---------------------------------------------------------------------------
local function base_cfg(overrides)
  local cfg = {
    levels = { photosynthesis = 0, motility = 0, sensing = 0, digestion = 0, evasion = 0 },
    unlocked = {},
    organelles = {},
    forage_cap = DEFAULTS.forage_cap,
    upkeep_scale = DEFAULTS.upkeep_scale,
    photo_light = DEFAULTS.photo_light,
    biofilm = 0,
  }
  if overrides then
    for k, v in pairs(overrides) do
      cfg[k] = v
    end
  end
  return cfg
end

-- The colony in the screenshot: photo5 / motility4 / chemotaxis5 / digestion4 /
-- evasion5, both unlocks fired, no organelles yet.
local function maxed_cfg(overrides)
  local cfg = base_cfg({
    levels = { photosynthesis = 5, motility = 4, sensing = 5, digestion = 4, evasion = 5 },
    unlocked = { photosynthesis = true, predation = true },
  })
  if overrides then
    for k, v in pairs(overrides) do
      cfg[k] = v
    end
  end
  return cfg
end

-- Synergy is shipped, so every maxed_cfg scenario already includes it.
local SCENARIOS = {
  { name = "founder (all Lv0)", cfg = base_cfg({ unlocked = { photosynthesis = true } }) },
  { name = "maxed colony (synergy)", cfg = maxed_cfg() },
  { name = "+ mitochondrion", cfg = maxed_cfg({ organelles = { mitochondrion = true } }) },
  {
    name = "+ chloroplast",
    cfg = maxed_cfg({ organelles = { mitochondrion = true, chloroplast = true } }),
  },
  { name = "+ BIOFILM stage 1", cfg = maxed_cfg({ biofilm = 1 }) },
  { name = "+ BIOFILM stage 2", cfg = maxed_cfg({ biofilm = 2 }) },
  {
    name = "biofilm s2 + organelles",
    cfg = maxed_cfg({
      biofilm = 2,
      organelles = { mitochondrion = true, chloroplast = true },
    }),
  },
}

local function find_scenario(name)
  for _, s in ipairs(SCENARIOS) do
    if s.name == name then
      return s.cfg
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Formatting.
-- ---------------------------------------------------------------------------
local function fmt_time(s)
  if not s then
    return "  --  "
  end
  if s < 90 then
    return string.format("%5.0fs", s)
  elseif s < 5400 then
    return string.format("%5.1fm", s / 60)
  else
    return string.format("%5.1fh", s / 3600)
  end
end

local function scenario_table()
  print("")
  print("cell-layer balance lab -- carrying capacity & growth per config")
  print(string.rep("-", 78))
  print(string.format("%-30s %8s %9s %9s %10s", "scenario", "K (pop)", "t->50%", "t->90%", "peak/min"))
  print(string.rep("-", 78))
  for _, s in ipairs(SCENARIOS) do
    local r = run(s.cfg)
    print(
      string.format(
        "%-30s %8d %9s %9s %10.1f",
        s.name,
        r.K,
        fmt_time(r.t50),
        fmt_time(r.t90),
        r.peak_rate * 60
      )
    )
  end
  print(string.rep("-", 78))
  print("note: render cap is MAX_AGENTS=300; K above that needs a higher visual sample.")
  print("")
end

local function sweep(param, lo, hi, step)
  lo, hi, step = tonumber(lo), tonumber(hi), tonumber(step) or 1
  print("")
  print(string.format("sweep of '%s' on the maxed colony (synergy on, biofilm off)", param))
  print(string.rep("-", 50))
  print(string.format("%12s %10s %10s %10s", param, "K (pop)", "t->90%", "peak/min"))
  print(string.rep("-", 50))
  for v = lo, hi, step do
    local cfg = maxed_cfg({ [param] = v })
    local r = run(cfg)
    print(string.format("%12.3f %10d %10s %10.1f", v, r.K, fmt_time(r.t90), r.peak_rate * 60))
  end
  print(string.rep("-", 50))
  print("")
end

local function curve(name, out)
  local cfg = find_scenario(name)
  if not cfg then
    print("unknown scenario: " .. tostring(name))
    print("available:")
    for _, s in ipairs(SCENARIOS) do
      print("  " .. s.name)
    end
    return
  end
  local r = run(cfg)
  local lines = { "t_seconds,population,div_per_min,biomass" }
  for _, p in ipairs(r.curve) do
    lines[#lines + 1] = string.format("%.1f,%d,%.2f,%.1f", p.t, p.pop, p.rate * 60, p.biomass)
  end
  local body = table.concat(lines, "\n") .. "\n"
  if out then
    local f = assert(io.open(out, "w"))
    f:write(body)
    f:close()
    print(string.format("wrote %d samples to %s (K=%d)", #r.curve, out, r.K))
  else
    io.write(body)
  end
end

-- ---------------------------------------------------------------------------
-- Entry.
-- ---------------------------------------------------------------------------
local mode = arg[1]
if mode == "sweep" then
  sweep(arg[2], arg[3], arg[4], arg[5])
elseif mode == "curve" then
  curve(arg[2], arg[3])
else
  scenario_table()
end
