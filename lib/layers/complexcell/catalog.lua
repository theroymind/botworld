-- Complex-cell catalog: ALL of phase 2's economy bookkeeping in one pure, love-free
-- module -- the eukaryotic sibling of lib/layers/cell/traits.lua. Where the sim
-- (lib/layers/complexcell/sim.lua) is the authoritative closed-form economy that
-- only ever sees a folded `rates` table, THIS module owns everything that folds
-- INTO that table: the tuning constants, the assembly-line stages and their unlock
-- gates, the geometric costs, and the self-revealing catalog UI hints. It is the
-- live analogue of tools/phase2_lab.lua -- its fold(), stage_cost(), mito_cost(),
-- gate thresholds, and constants are intentionally byte-for-byte the SAME math the
-- lab pins, so the orchestrator's live progression reproduces the lab's tuned run
-- (FORK in ~10.3 min by the balanced play). It stays headless-testable like traits:
-- no love.*, no RNG, pure Lua 5.1.
--
-- Depends on the sim ONLY for sim.balance_scalar (the shared Pillar-3 balance-scalar
-- math): catalog.efficiency mirrors it byte-for-byte rather than duplicating the
-- formula. The dependency is one-way -- the sim never requires the catalog (it consumes
-- folded scalars only), so there is no cycle.
local sim = require("lib.layers.complexcell.sim")
local catalog = {}

-- ===========================================================================
-- LOCKED constants -- mirror DEFAULTS in tools/phase2_lab.lua EXACTLY (and
-- docs/PHASE_2_ECONOMY.md). These are the values the fold below collapses into the
-- `rates` table the sim consumes; changing them re-tunes the whole phase.
-- ===========================================================================
catalog.POWER_PER_MITO = 10 -- gross ATP/sec per mitochondrion
catalog.UPKEEP_PER_MACHINE = 0.25 -- per-gene idle cost (mito + every stage level)
catalog.WASTE_COEF = 0.0 -- overbuild penalty carried by idle-machine upkeep (no extra waste term)
catalog.E_PER_OUTPUT = 1.0 -- ATP cost per unit of assembly-line output
-- The ATP savings ceiling SCALES with `built` (catalog.buffer_max below) instead of
-- pinning at a fixed wall: once the power-vs-throughput balance is solved, a fixed cap
-- left the cell parked permanently at full with nothing to optimise toward. Now the cap
-- breathes UP as the cell grows, so meticulous tuning keeps paying off. BUFFER_BASE is
-- the cap at built 0 (every current unlock still fits inside it); BUFFER_BUILT_REF is the
-- built that adds one more BUFFER_BASE of headroom -- set so the cap is ~10x by the FORK
-- (180k built). Mirrors tools/phase2_lab.lua + docs/PHASE_2_ECONOMY.md.
catalog.BUFFER_BASE = 5000 -- ATP cap at built 0 (all current unlocks fit; finite)
catalog.BUFFER_BUILT_REF = 20000 -- built per extra BUFFER_BASE of cap (~10x ceiling by the 180k FORK)

-- The live ATP cap at this state's `built`: a gentle linear-in-built climb off BUFFER_BASE.
-- Pure + state-derived (reads only state.built), so the buffer clamp in sim.step is
-- identical online and offline -- offline parity holds. The fold threads this into
-- rates.buffer_max; the orchestrator reads it directly for the tap clamp + buffer bar.
function catalog.buffer_max(state)
  return catalog.BUFFER_BASE * (1 + (state.built or 0) / catalog.BUFFER_BUILT_REF)
end

catalog.BROWNOUT_RESERVE = 0.3 -- fraction of power held for the buffer in a deficit (visible teeth + recovery)
catalog.FUEL_FACTOR = 1.0 -- plant/animal mix; neutral 1.0 through the phase

-- PER-STAGE throughput (Pillar 1: the "golden ratio"). Each stage carries a DISTINCT
-- per-level capacity, so the level mix that equalises every stage's cap is non-trivial
-- (inverse of the rates) -- reading and feeding the slow stage is now a live decision,
-- not a cost-only self-balance. Biology drives the numbers: translation is high-
-- throughput (ribosomes numerous), ER folding/QC is the classic rate-limiter, membrane
-- export is a frontier bottleneck. Routed through stage_rate(id) -- the SINGLE lookup
-- point; nothing reads catalog.STAGE_RATE inline. Mirrors the lab's STAGE_RATE table.
catalog.STAGE_RATE = {
  ribosomes = 12, -- translation is high-throughput; ribosomes are numerous
  nucleus = 6, -- transcription is moderate
  er = 4, -- folding + quality-control is the classic rate-limiter
  golgi = 6, -- sorting/packaging, moderate
  transport = 8, -- motor highways move cargo fast
  membrane = 4, -- export/insertion is a frontier bottleneck
}
catalog.STAGE_BASE = 20 -- geometric stage-level cost base
catalog.STAGE_GROWTH = 1.12 -- gentle growth: stack MANY levels (deep catalog, numbers climb)
catalog.MITO_BASE = 25 -- geometric mitochondrion cost base
catalog.MITO_GROWTH = 1.12 -- gentle growth: power keeps pace so throughput can reach the hundreds+

-- A newly INTEGRATED stage comes online at ~this fraction of the line's current
-- throughput (NOT level 1). A late unlock then dips the line modestly (it is still a
-- new bottleneck to top up) instead of cratering it to near-zero and forcing a brutal
-- re-level grind back to where you were -- the "cripplingly slow after a late unlock"
-- feel. 0.6 -> a ~40% dip the player closes in a few levels, never a hard stall.
catalog.INTEGRATION_SEED_FRACTION = 0.6

-- The pipeline, in unlock order. `ribosomes` is unlocked from t=0 (output > 0
-- immediately); the rest unlock as `built` crosses their gate threshold. Each
-- carries a display label and a one-line flavor -- the science-ordered named beats:
-- Ribosomes, Nucleus, Endomembrane (ER + Golgi), Cytoskeleton (transport), Membrane.
catalog.STAGES = { "ribosomes", "nucleus", "er", "golgi", "transport", "membrane" }

-- id -> { label, flavor }. The view + panel read these for per-stage rows. FULL names,
-- no abbreviations (the player asked "what is ER?") -- the label spells the organelle out
-- and the flavor is a SHORT active-verb line naming the step it owns on the line. That
-- verb is the only guidance: it implies which step speeds up when you level the stage
-- (leaving the player to map a backed-up line to its organelle), without ever printing a
-- "this increases X" hand-hold. Shown on every stage row (the panel's label column).
catalog.STAGE_DEFS = {
  ribosomes = {
    label = "Ribosomes",
    flavor = "assemble the cell's parts",
  },
  nucleus = {
    label = "Nucleus",
    flavor = "direct the whole assembly line",
  },
  er = {
    label = "Endoplasmic Reticulum",
    flavor = "fold raw parts into working shape",
  },
  golgi = {
    label = "Golgi Body",
    flavor = "pack and label each finished part",
  },
  transport = {
    label = "Cytoskeleton",
    flavor = "haul cargo across the cell",
  },
  membrane = {
    label = "Cell Membrane",
    flavor = "export the product and seal the cell",
  },
}

-- Stage-reveal gates, in pipeline order. A gate DISCOVERS its stage once TWO
-- conditions both hold: `built` has crossed `at`, AND its `requires` predecessor has
-- been INTEGRATED (state.unlocked[requires] -- not merely discovered). That second
-- clause makes the reveal a STAIR-STEP: each named beat stays hidden until the player
-- has actually brought the previous one online, so they never arrive in a clump. The
-- `at` thresholds rise steeply down the pipeline (the gaps widen) so the beats land
-- spaced across the climb, not stacked in the opening minutes. nucleus has no
-- predecessor gate (ribosomes are online from t=0), so it gates on `built` alone.
-- Tuned against tools/phase2_lab.lua so the staggered reveals still FORK in ~10-13 min.
-- `label` mirrors STAGE_DEFS[id].label so the self-revealing footer names the next beat
-- with the SAME full word the stage row shows -- kept in sync by hand (both updated when a
-- stage is renamed); next_gate() surfaces it to the teaser.
catalog.GATES = {
  { id = "nucleus", at = 50, requires = nil, label = "Nucleus" },
  { id = "er", at = 5000, requires = "nucleus", label = "Endoplasmic Reticulum" },
  { id = "golgi", at = 30000, requires = "er", label = "Golgi Body" },
  { id = "transport", at = 50000, requires = "golgi", label = "Cytoskeleton" },
  { id = "membrane", at = 105000, requires = "transport", label = "Cell Membrane" },
}

catalog.FORK_AT = 180000 -- end-of-phase gate (~10 min building the full pipeline; raised
-- from 50000 to absorb the integration-value carrot so the smart target stays ~10 min)

-- STAGE INTEGRATION COSTS -- the STEEP ATP price to bring a DISCOVERED stage online.
-- Crossing a built gate only DISCOVERS a stage (a teaser); the player then pays this
-- to INTEGRATE it (unlock). Priced as a deliberate lump the player must save toward
-- (well above the running surplus at the gate, but inside the ATP cap), and rising
-- down the pipeline so each named beat is a bigger commitment than the last. The
-- orchestrator deducts ATP before calling catalog.unlock_stage; the catalog never
-- touches energy itself. Tunable first pass.
catalog.STAGE_UNLOCK_COST = {
  nucleus = 150,
  er = 300,
  golgi = 300,
  transport = 800,
  membrane = 2000,
}

-- OXIDATIVE STRESS tuning (the failure pressure; see sim.step). A FULL power deficit
-- (severity 1) drives stress 0->1 in ~1/STRESS_RISE seconds -- a generous warning
-- window before lysis. Full surplus clears stress 1->0 in ~1/STRESS_FALL seconds --
-- a quick, forgiving recovery once power is restored (a single mitochondrion).
catalog.STRESS_RISE = 1 / 27 -- ~27s for a full deficit to reach the fail threshold
catalog.STRESS_FALL = 1 / 5 -- ~5s for a full surplus to clear accumulated stress
catalog.STRESS_FAIL = 1.0 -- the orchestrator lyses the cell at stress >= this

-- ===========================================================================
-- THE ROS PENDULUM (Pillar 2: symmetric stress). Stress alone would only rise on a power
-- DEFICIT; a surplus would be consequence-free, so "buy mitochondria forever" would be the
-- rewarded play -- a floor but no ceiling. Biology supplies the ceiling: mitochondria
-- respiring at high membrane potential but LOW ATP demand (the resting "state-4" condition)
-- leak electrons and produce REACTIVE OXYGEN SPECIES. Matching production to demand
-- minimises the leak. So idle over-capacity literally damages the cell. We track
-- balance_ratio = power / demand against a SAFE BAND: below BALANCE_LO the line browns out
-- (the deficit half); above BALANCE_HI idle respiratory capacity leaks -> ros rises, scaled
-- by how far past the band you are (maxing at ROS_RATIO_CAP). ros (0..1) integrates like
-- stress and (a) drags built output (the soft cut, Pillar 3) and (b) only when SUSTAINED
-- past ROS_LETHAL feeds the existing lethal stress -- a generous warning window.
--
-- The ceiling is a FIXED constant (no buyable counter-lever): the only honest fix for
-- over-power is to stop over-building power and let demand catch up. An earlier antioxidant
-- ("stabilization") track let the player LIFT this ceiling, which meant the more you bought
-- the less over-power ever bit -- so both the antioxidants AND the over-power penalty read
-- as pointless. Removing the lever pins the ceiling, so running hot is finally a real,
-- felt cost the "power balance" gauge surfaces directly.
-- ===========================================================================
catalog.BALANCE_LO = 1.0 -- power/demand below this -> brownout (the deficit half, unchanged)
catalog.BALANCE_HI = 1.6 -- top of the safe headroom band (a loose nod to phi as ideal reserve)
catalog.ROS_RATIO_CAP = 3.0 -- power/demand at which the ROS leak maxes (3x needed power = full leak)
catalog.ROS_RISE = 1 / 40 -- ~40s of MAX surplus to fill ros from 0->1 (gentle; a long warning)
catalog.ROS_FALL = 1 / 8 -- ~8s to clear ros once back inside the band (forgiving recovery)
catalog.ROS_LETHAL = 0.8 -- ros sustained above this starts feeding the lethal stress tail
catalog.ROS_LETHAL_RISE = 1 / 30 -- past ROS_LETHAL, how fast surplus-ros drives stress->fail (~30s)

-- IMBALANCE CUTS BUILT (Pillar 3). The balance scalar no longer just dims the swarm:
-- it multiplies minted built between MIN_EFF (worst case) and 1 (in-band). The ATP
-- cost e*O is left UNCHANGED, so the brownout/stress closed form is untouched -- only
-- the reward bends. A badly-balanced cell mints as little as MIN_EFF of its potential.
catalog.MIN_EFF = 0.4 -- worst-case built multiplier from being off-balance

-- INTEGRATION VALUE (the CARROT). Each integrated stage beyond the first refines the
-- product further, so every unit that flows down a LONGER pipeline is worth more BUILT.
-- value_mult = 1 + VALUE_PER_STAGE * (unlocked stages - 1) multiplies the built minted
-- per unit of throughput. This is what makes integrating a discovered stage WORTH it
-- without ever punishing the player for NOT buying yet: a half-formed stage you haven't
-- integrated simply isn't earning its bonus -- the line keeps running at full rate, no
-- throttle, no crippling. Skipping the pipeline forgoes the multipliers, so building the
-- cell out is the fast path; ignoring an available unlock is only an opportunity cost,
-- never an active penalty. (Replaces the old discovery-choke throttle, which crippled
-- the line the moment a stage became available -- punitive and bad feel.)
catalog.VALUE_PER_STAGE = 0.40 -- +40% built-per-throughput per integrated stage past the first
-- (tuned with FORK_AT so the full-pipeline build path FORKs in ~10 min while a
-- skip-the-stages rush is ~46% slower -- building the cell out wins on opportunity cost,
-- never on a penalty for leaving an upgrade unbought.)

-- Per-stage throughput rate -- THE single lookup point (Pillar 1). Each stage carries
-- a DISTINCT per-level capacity (catalog.STAGE_RATE[id]); nothing reads the table
-- inline. A missing id is a programming error (every STAGES entry must have a rate),
-- so we assert rather than silently default.
local function stage_rate(id)
  local rate = catalog.STAGE_RATE[id]
  assert(rate, "stage_rate: no rate for stage " .. tostring(id))
  return rate
end

-- ===========================================================================
-- COSTS (orchestrator/catalog, not the sim). Geometric, like phase 1. Buying the
-- NEXT level of a stage costs STAGE_BASE * STAGE_GROWTH ^ current_level; the NEXT
-- mitochondrion costs MITO_BASE * MITO_GROWTH ^ (mito-1). Mirrors the lab.
-- ===========================================================================
function catalog.stage_cost(level) return catalog.STAGE_BASE * catalog.STAGE_GROWTH ^ level end

function catalog.mito_cost(mito) return catalog.MITO_BASE * catalog.MITO_GROWTH ^ (mito - 1) end

-- ===========================================================================
-- THE FOLD: state + constants -> the `rates` table sim.step consumes. This is the
-- live twin of tools/phase2_lab.lua's fold(); it MUST produce identical rates for
-- the same state so the lab's tuned numbers hold. The sim never sees levels or
-- stage_rate -- everything collapses into these scalars here.
-- ===========================================================================
function catalog.fold(state)
  local power = catalog.POWER_PER_MITO * state.mito * catalog.FUEL_FACTOR

  -- Throughput is the MIN capacity over unlocked stages; excess is everything
  -- built above that bottleneck (idle, waste-generating). An unlocked stage at
  -- level 0 contributes 0 -> it pins throughput to 0 until leveled.
  local throughput, any = nil, false
  for _, id in ipairs(catalog.STAGES) do
    if state.unlocked[id] then
      any = true
      local cap = stage_rate(id) * (state.stages[id] or 0)
      if throughput == nil or cap < throughput then
        throughput = cap
      end
    end
  end
  if not any then
    throughput = 0
  end
  throughput = throughput or 0

  local excess = 0
  local levelsum = 0
  local unlocked_count = 0
  for _, id in ipairs(catalog.STAGES) do
    local lvl = state.stages[id] or 0
    levelsum = levelsum + lvl
    if state.unlocked[id] then
      unlocked_count = unlocked_count + 1
      local cap = stage_rate(id) * lvl
      local over = cap - throughput
      if over > 0 then
        excess = excess + over
      end
    end
  end

  -- INTEGRATION VALUE (the carrot): a longer integrated pipeline refines the product
  -- further, so each unit of throughput mints MORE built. value_mult multiplies built
  -- (not power: e*T still costs the same, so brownout/stress are unaffected), which is
  -- what makes integrating a discovered stage worthwhile -- WITHOUT throttling the line
  -- while the stage merely sits available. Skipping the pipeline just forgoes the bonus.
  local value_mult = 1 + catalog.VALUE_PER_STAGE * math.max(unlocked_count - 1, 0)

  -- Idle upkeep: every mitochondrion and every stage level is a machine drawing a running
  -- cost whether or not it adds throughput (so over-leveling a non-bottleneck stage is pure
  -- loss). joins mito + the stage-level sum.
  local upkeep = catalog.UPKEEP_PER_MACHINE * (state.mito + levelsum)

  return {
    power = power,
    throughput = throughput,
    excess = excess,
    upkeep = upkeep,
    waste_coef = catalog.WASTE_COEF,
    e_per_output = catalog.E_PER_OUTPUT,
    buffer_max = catalog.buffer_max(state),
    brownout_reserve = catalog.BROWNOUT_RESERVE,
    stress_rise = catalog.STRESS_RISE,
    stress_fall = catalog.STRESS_FALL,
    value_mult = value_mult, -- built-per-throughput multiplier from the integrated pipeline
    -- ROS pendulum + balance-scalar inputs (Pillars 2 & 3); the sim derives demand,
    -- balance_ratio, ROS integration, and the efficiency cut from these scalars.
    balance_lo = catalog.BALANCE_LO,
    -- The safe-power ceiling is now a FIXED constant (no antioxidant lever lifts it), so
    -- over-power past it always bites. Threaded as balance_hi_eff for the sim/lab contract
    -- (the "_eff" name is kept so the byte-for-byte mirrors don't churn) -- it just no
    -- longer varies with state.
    balance_hi_eff = catalog.BALANCE_HI,
    ros_ratio_cap = catalog.ROS_RATIO_CAP,
    ros_rise = catalog.ROS_RISE,
    ros_fall = catalog.ROS_FALL,
    ros_lethal = catalog.ROS_LETHAL,
    ros_lethal_rise = catalog.ROS_LETHAL_RISE,
    min_eff = catalog.MIN_EFF,
  }
end

-- The unlocked stage that currently PINS throughput (lowest stage_rate*level) --
-- the bottleneck the view tells the player to feed. Ties break by STAGES order.
-- Mirrors bottleneck_stage() in the lab.
function catalog.bottleneck_id(state)
  local best, bestcap = nil, nil
  for _, id in ipairs(catalog.STAGES) do
    if state.unlocked[id] then
      local cap = stage_rate(id) * (state.stages[id] or 0)
      if bestcap == nil or cap < bestcap then
        best, bestcap = id, cap
      end
    end
  end
  return best
end

-- Whether a gate's `requires` predecessor has been INTEGRATED (unlocked, not merely
-- discovered). A nil `requires` (nucleus) is always satisfied. This is the stair-step
-- clause: a gate cannot discover until the player has brought its predecessor online.
local function is_prereq_met(state, gate)
  return gate.requires == nil or state.unlocked[gate.requires] == true
end

-- Apply newly-crossed gates: DISCOVER any stage whose `built` threshold has passed AND
-- whose predecessor is already integrated (the stair-step gate -- see GATES). Discovery
-- is the FIRST half of a two-step unlock -- it only flags the stage as available to
-- integrate (a toast + a buyable row); it does NOT unlock it and does NOT seed a level.
-- The player then pays catalog.stage_unlock_cost via the orchestrator, which calls
-- catalog.unlock_stage to bring it online -- which in turn satisfies the NEXT gate's
-- prereq. RETURNS the ids newly discovered this call (for a toast). Idempotent.
function catalog.discover_gates(state)
  local newly = nil
  for _, g in ipairs(catalog.GATES) do
    if not state.discovered[g.id] and state.built >= g.at and is_prereq_met(state, g) then
      state.discovered[g.id] = true
      newly = newly or {}
      newly[#newly + 1] = g.id
    end
  end
  return newly or {}
end

-- Has this stage's built gate been crossed (discovered, awaiting integration)?
function catalog.is_discovered(state, id) return state.discovered[id] == true end

-- Is any stage DISCOVERED but not yet INTEGRATED? While true, fold() throttles the
-- whole line (CHOKE_FACTOR) -- the forming organelle clogs production until paid for.
-- The orchestrator also reads this to surface the "a stage is forming" line.
function catalog.has_pending_integration(state)
  for _, g in ipairs(catalog.GATES) do
    if state.discovered[g.id] and not state.unlocked[g.id] then
      return true
    end
  end
  return false
end

-- The STEEP ATP price to INTEGRATE a discovered stage (unlock it). The orchestrator
-- checks/deducts this against energy before calling catalog.unlock_stage.
function catalog.stage_unlock_cost(id) return catalog.STAGE_UNLOCK_COST[id] end

-- The level a freshly integrated stage seeds at: enough that its cap sits at
-- INTEGRATION_SEED_FRACTION of the line's CURRENT throughput, so it opens as a new
-- bottleneck the player tops up over a few levels -- not a near-zero crater that forces
-- a full re-level grind. Floors at 1 (an empty/early line still opens at level 1, the
-- old behaviour). `line_throughput` is read BEFORE the stage is flagged unlocked, so it
-- reflects the pre-integration line. Divides by the SPECIFIC stage's rate (Pillar 1:
-- rates differ per stage), so the seeded cap lands near INTEGRATION_SEED_FRACTION of the
-- line regardless of how fast/slow the new stage's machines are.
local function integration_seed_level(id, line_throughput)
  local seed =
    math.floor((catalog.INTEGRATION_SEED_FRACTION * line_throughput) / stage_rate(id) + 0.5)
  if seed < 1 then
    seed = 1
  end
  return seed
end

-- Integrate a DISCOVERED stage: bring it online near the line (integration_seed_level),
-- so a LATE unlock dips throughput modestly instead of pinning it to near-zero -- the
-- stage still opens BELOW the line (a new bottleneck to top up), just not from a crater
-- that demands re-grinding every level you already had. Does NOT touch energy (the
-- orchestrator deducts ATP first). Returns true if it unlocked (was discovered and not
-- already unlocked), false otherwise -- so a double-buy or an un-discovered id is a safe
-- no-op.
function catalog.unlock_stage(state, id)
  if not state.discovered[id] or state.unlocked[id] then
    return false
  end
  local seed = integration_seed_level(id, catalog.fold(state).throughput)
  state.unlocked[id] = true
  state.stages[id] = math.max(state.stages[id] or 0, seed)
  return true
end

-- The next still-undiscovered gate (the upcoming named beat the self-reveal teaser
-- counts toward), or nil once every gate has been discovered. Walks GATES in order,
-- so it returns the soonest unbuilt threshold. Keyed on `discovered` (not `unlocked`)
-- so the teaser stops the moment the gate is reached -- integration is a separate,
-- player-paced step that no longer drives the reveal.
function catalog.next_gate(state)
  for _, g in ipairs(catalog.GATES) do
    if not state.discovered[g.id] then
      return { id = g.id, label = g.label, at = g.at, requires = g.requires }
    end
  end
  return nil
end

-- Is the next gate's stair-step predecessor integrated yet? The orchestrator passes
-- this into reveal() so a beat that is still walled behind an un-integrated stage
-- reads as hidden ("next: …") rather than teasing its silhouette early -- the named
-- beat stays out of sight until the player has earned the right to approach it.
function catalog.is_gate_prereq_met(state, gate) return is_prereq_met(state, gate) end

-- The self-revealing catalog (UI ONLY -- does not touch the economy). Given the
-- NEXT locked gate's `built` threshold, classify how close the cell is into a
-- reveal stage: hidden (<50%), silhouette (>=50%), named (>=75%), ready (>=100%).
-- The orchestrator passes catalog.next_gate(state).at as target_built.
function catalog.reveal(state, target_built, prereq_met)
  -- Stair-step: a beat whose predecessor isn't integrated yet stays fully hidden,
  -- regardless of `built` -- the silhouette never appears until the gate is reachable.
  -- (nil prereq_met means "no prereq to check" -- treated as met, for callers/tests
  -- that reveal a gate with no predecessor.)
  if prereq_met == false then
    return "hidden"
  end
  if not target_built or target_built <= 0 then
    return "hidden"
  end
  local frac = state.built / target_built
  if frac >= 1.0 then
    return "ready"
  elseif frac >= 0.75 then
    return "named"
  elseif frac >= 0.5 then
    return "silhouette"
  end
  return "hidden"
end

-- Has the cell reached the end-of-phase FORK threshold (plant/animal choice)?
function catalog.reached_fork(state) return state.built >= catalog.FORK_AT end

-- Pure read-only BALANCE SCALAR in [0,1] (Pillar 3): the "golden-ratio" readout fed to
-- swarm speed + brightness AND the same number the sim turns into the built-yield cut.
-- Derived from fold(state) + state.ros; it NEVER writes back to the economy. It is the
-- BYTE-FOR-BYTE MIRROR of sim.balance_scalar(fold(state), state.ros) -- the two MUST
-- agree (a spec asserts it), exactly as fold() mirrors the lab. Three factors:
--
--   flow_balance  = throughput / (throughput + excess)
--                   1.0 when every unlocked stage is matched to the bottleneck; falls
--                   as you overbuild any stage past the bottleneck (idle machinery).
--
--   power_balance = a PEAK-IN-BAND curve over balance_ratio = power / demand
--                   (demand = T*e + upkeep): 1.0 inside [BALANCE_LO, BALANCE_HI_eff];
--                   falls on a DEFICIT slope below LO (brownout) AND on a SURPLUS slope
--                   above HI_eff (idle over-power, toward ROS_RATIO_CAP). Two-sided --
--                   over-powering is no longer invisible.
--
--   ros_drag      = 1 - ros   -- accumulated oxidative stress bleeds the scalar further.
--
-- Returns flow_balance * power_balance * ros_drag, clamped to [0,1].
function catalog.efficiency(state) return sim.balance_scalar(catalog.fold(state), state.ros or 0) end

-- The live BUILD RATE in built/sec -- the read-only "+N /s" the headline surfaces so
-- tuning a stage or trimming power shows an immediate, felt payoff. Mirrors the sim's mint
-- BYTE-FOR-BYTE: built += output * value_mult * efficiency_factor (sim.step), where
-- efficiency_factor = MIN_EFF + (1-MIN_EFF) * balance_scalar -- the same soft cut. Folds
-- once and reuses the rates for both value_mult and the balance scalar (no new coupling:
-- catalog already calls sim.balance_scalar via catalog.efficiency). Reads state.output
-- (last step's O), so a one-frame lag is standard and harmless for a readout.
function catalog.build_rate(state)
  local r = catalog.fold(state)
  local eff = catalog.MIN_EFF + (1 - catalog.MIN_EFF) * sim.balance_scalar(r, state.ros or 0)
  return (state.output or 0) * (r.value_mult or 1) * eff
end

-- ===========================================================================
-- GAUGE READOUTS (Pillar 5: surface the state, let the player reason out the fix).
-- Pure derived math so the renderer stays logic-free and the numbers are testable.
-- None of these write back to the economy -- they only READ fold(state).
-- ===========================================================================

-- The ATP DEMAND the line is drawing right now: the cost of running the bottleneck
-- (e * throughput) plus the idle upkeep of every machine. This is the same `demand`
-- the sim's balance scalar uses (demand = e*T + upkeep); folded once here so the
-- balance-ratio gauge agrees with the economy byte-for-byte. Always > 0
-- (upkeep counts mito >= 1), so the divisions below are well-defined.
function catalog.demand(state)
  local rates = catalog.fold(state)
  return rates.e_per_output * rates.throughput + rates.upkeep
end

-- THE BALANCE RATIO gauge (Pillar 5): power / demand, the SAME ratio the ROS pendulum
-- and the peak-in-band efficiency curve key off. The view classifies it against the safe
-- band [BALANCE_LO, balance_hi_eff] into under / ideal / over. Pure read; demand > 0.
function catalog.balance_ratio(state)
  local rates = catalog.fold(state)
  local demand = rates.e_per_output * rates.throughput + rates.upkeep
  return rates.power / demand
end

-- The safe-band CEILING for the balance ratio (the fixed BALANCE_HI). Above this the cell
-- leaks ROS; below BALANCE_LO it browns out. Surfaced so the view can class the balance
-- ratio as under (< LO) / ideal (in band) / over (> HI) without inlining the band math.
function catalog.balance_hi_eff(state) return catalog.fold(state).balance_hi_eff end

-- The three balance-band classes the gauge surfaces (Pillar 5). Named so neither the
-- catalog nor the view inlines a band string: UNDER (ratio < BALANCE_LO -> brownout),
-- IDEAL (inside [BALANCE_LO, balance_hi_eff] -> calm), OVER (ratio > balance_hi_eff ->
-- ROS leak). The panel maps each to a label + color token at its edge.
catalog.BAND_UNDER = "under"
catalog.BAND_IDEAL = "ideal"
catalog.BAND_OVER = "over"

-- Classify the balance ratio against the live safe band [BALANCE_LO, balance_hi_eff]
-- into one of the BAND_* classes. Pure read -- folds once and reuses the SAME ratio +
-- ceiling the ROS pendulum and efficiency curve key off, so the gauge's under/ideal/over
-- verdict can never disagree with the economy that actually leaks ROS or browns out. The
-- boundaries match sim.balance_scalar's power_balance branches exactly (< LO deficit, <=
-- HI_eff calm, else surplus). Used by the view to color + label the ratio.
function catalog.balance_band(state)
  local rates = catalog.fold(state)
  local demand = rates.e_per_output * rates.throughput + rates.upkeep
  local ratio = rates.power / demand
  if ratio < rates.balance_lo then
    return catalog.BAND_UNDER
  elseif ratio <= rates.balance_hi_eff then
    return catalog.BAND_IDEAL
  end
  return catalog.BAND_OVER
end

-- An ordered list of per-stage display rows for the view + panel. Each row carries
-- its cap (stage_rate*level), whether it's unlocked, whether it's the current
-- bottleneck, and a 0..1 CONGESTION figure -- how far the stage's capacity sits
-- ABOVE the line's throughput (built-up, backed-up machinery), normalized and
-- clamped. The bottleneck itself reads 0 congestion; stages stacked above it read
-- toward 1.
function catalog.stage_snapshot(state)
  local rates = catalog.fold(state)
  local throughput = rates.throughput
  local bottleneck = catalog.bottleneck_id(state)
  local rows = {}
  for _, id in ipairs(catalog.STAGES) do
    local def = catalog.STAGE_DEFS[id] or { label = id, flavor = "" }
    local level = state.stages[id] or 0
    local cap = stage_rate(id) * level
    local unlocked = state.unlocked[id] == true
    local congestion = 0
    if unlocked then
      local over = cap - throughput
      if over > 0 then
        congestion = over / math.max(throughput, 1)
        if congestion > 1 then
          congestion = 1
        elseif congestion < 0 then
          congestion = 0
        end
      end
    end
    rows[#rows + 1] = {
      id = id,
      label = def.label,
      flavor = def.flavor,
      level = level,
      cap = cap,
      unlocked = unlocked,
      is_bottleneck = unlocked and (id == bottleneck),
      congestion = congestion,
    }
  end
  return rows
end

return catalog
