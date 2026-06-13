-- Spores: the PHASE-1 dataset over the generic prestige kernel (lib/engine/spore_tree.lua).
-- The kernel is layer-agnostic -- it knows leveled, gated, tier-costed nodes and a
-- peak-observing currency that survives the within-phase reset, but nothing about any
-- economy. THIS module supplies the phase-1 spine (the data) and the two pure folds the
-- orchestrator needs: spores.value() (the instantaneous spore-value the kernel observes,
-- health-multiplied so a sick colony can't ratchet the peak) and spores.fold() (node levels
-- -> economy modifiers, neutral until spent). Mirrors the data-module pattern of
-- organelles.lua / traits.lua: a read-only DEFS spine and pure fold helpers, no love.*, no
-- sim mutation. Reuses sim.health (sim.lua loads headless) for the toxicity factor so the
-- prestige value and the live intake throttle share one curve.
--
-- MIRROR RULE: the tuning constants below are MIRRORED in tools/sim_lab.lua (the prestige
-- harness copy), per the standing mirror rule -- another agent adds the harness copy. Tune
-- here, then port the same values across (the harness `prestige` mode replays N accelerating
-- loops against the ~15-min budget). Placeholder values from docs/phase1/BALANCE.md.
local spores = {}

local sim = require("lib.layers.cell.sim")

-- EARNING -- spores banked from health x growth (BALANCE.md "Earning"). The payout is
-- floor(EARN_K * peak_pop^GROWTH_EXP * vitality), so EARN_K scales loop-1 yield to ~one
-- branch node, GROWTH_EXP's sqrt curve makes the TREE (not one long grind) the lever, and
-- VITALITY_WEIGHT rewards cashing out a healthy, growing colony over a stalled one.
local SPORE_EARN_K = 1.0 -- payout scalar; dial so loop 1 opens one branch node
local SPORE_GROWTH_EXP = 0.5 -- sqrt diminishing curve on peak population -- the tree is the lever
local SPORE_VITALITY_WEIGHT = 1.0 -- how hard per-capita vitality scales payout -- rewards healthy cash-out
local SPORE_LIFETIME_BONUS = 0.005 -- small always-on bonus per lifetime spore, so a weak run still counts

-- COSTS -- spore spend per node level (BALANCE.md "Costs"). Geometric within a node
-- (COST_GROWTH per level), scaled by TIER_MULT^tier so each tier (branch -> capstone ->
-- Engulf -> Mitochondria) costs ~TIER_MULT x the last -- the capstone wall enforces
-- "master both branches first."
local SPORE_COST_BASE = 1 -- cost of the photosynthesis root (first spend; trivial)
local SPORE_COST_GROWTH = 1.6 -- geometric per-level multiplier within a node (1.5-1.7 band)
local SPORE_TIER_MULT = 10 -- each tier ~10x the previous; the capstone wall

-- PER-NODE EFFECT magnitudes (BALANCE.md "Tree node effects"), all per-level. The fold below
-- maps each onto one economy term. MITOSIS is a division-cost CUT, so it is stored NEGATIVE
-- and the fold turns the sum into a < 1 multiplier (cheaper division).
local SPORE_PHOTO_EFF_PER = 0.08 -- +0.08 biomass/sec from photosynthesis, per level
local SPORE_FLAGELLA_PER = 0.06 -- +0.06 swim speed & forage, per level
local SPORE_CHEMO_PER = 0.07 -- +0.07 sense range, per level
local SPORE_MITOSIS_PER = 0.05 -- -0.05 division cost, per level (applied negative below = cheaper)
local SPORE_METABOLIC_PER = 0.10 -- +0.10 all intake, per level (capstone)
local SPORE_DETOX_PER = 0.10 -- +0.10 waste cleanup, per level
local SPORE_MEMBRANE_PER = 0.08 -- +0.08 evasion, per level
local SPORE_FORAGE_DOM_PER = 0.08 -- +0.08 competition counter, per level
local SPORE_HOMEO_PER = 0.10 -- +0.10 vitality / pressure dampening, per level (capstone)
local SPORE_ENGULF_PROGRESS_PER = 0.15 -- +0.15 health & reproduction progress per engulf (reserved; consumed later)
local ENDO_MITO_PER = 0.0006 -- per-level boost to the endosymbiosis chance toward near-certain

-- Tier indices for the spine (root -> branch -> capstone -> gate -> phase-2 gate). Named so
-- the cost scaling (TIER_MULT^tier) and the spine shape read as data, not inline literals.
local TIER_ROOT = 0
local TIER_BRANCH = 1
local TIER_CAPSTONE = 2
local TIER_GATE = 3
local TIER_PHASE2 = 4

-- Caps per node (BALANCE.md): the root is a one-shot unlock, branch nodes fill to 5, the two
-- capstones to 3, and the two gates to 5.
local CAP_ROOT = 1
local CAP_BRANCH = 5
local CAP_CAPSTONE = 3
local CAP_GATE = 5

-- The fixed spine. A photosynthesis root opens both branches; each branch fills, then a
-- capstone; both capstones maxed unlock Engulf; Engulf maxed unlocks Mitochondria. cost_base
-- / cost_growth are baked from the constants into every node; the kernel scales them by
-- TIER_MULT^tier. effects keys are read back by spores.fold via tree:effect_total.
local DEFS = {
  {
    id = "photosynthesis",
    label = "Photosynthesis",
    tier = TIER_ROOT,
    cap = CAP_ROOT,
    cost_base = SPORE_COST_BASE,
    cost_growth = SPORE_COST_GROWTH,
    effects = { photo_channel = 1 },
  },
  -- GROWTH branch -- reach the plateau faster (speed / forage / sense / division).
  {
    id = "photo_eff",
    label = "Photosynthetic Efficiency",
    tier = TIER_BRANCH,
    cap = CAP_BRANCH,
    cost_base = SPORE_COST_BASE,
    cost_growth = SPORE_COST_GROWTH,
    requires = { "photosynthesis" },
    effects = { photo_mult = SPORE_PHOTO_EFF_PER },
  },
  {
    id = "flagella",
    label = "Flagellar Drive",
    tier = TIER_BRANCH,
    cap = CAP_BRANCH,
    cost_base = SPORE_COST_BASE,
    cost_growth = SPORE_COST_GROWTH,
    requires = { "photosynthesis" },
    effects = { forage = SPORE_FLAGELLA_PER },
  },
  {
    id = "chemo",
    label = "Chemotactic Reach",
    tier = TIER_BRANCH,
    cap = CAP_BRANCH,
    cost_base = SPORE_COST_BASE,
    cost_growth = SPORE_COST_GROWTH,
    requires = { "photosynthesis" },
    effects = { sense = SPORE_CHEMO_PER },
  },
  {
    id = "mitosis",
    label = "Mitotic Speed",
    tier = TIER_BRANCH,
    cap = CAP_BRANCH,
    cost_base = SPORE_COST_BASE,
    cost_growth = SPORE_COST_GROWTH,
    requires = { "photosynthesis" },
    effects = { div = -SPORE_MITOSIS_PER }, -- negative = cheaper division
  },
  -- RESILIENCE branch -- raise the plateau (toxicity / predation / competition counters).
  {
    id = "detox",
    label = "Detox Vacuoles",
    tier = TIER_BRANCH,
    cap = CAP_BRANCH,
    cost_base = SPORE_COST_BASE,
    cost_growth = SPORE_COST_GROWTH,
    requires = { "photosynthesis" },
    effects = { cleanup = SPORE_DETOX_PER },
  },
  {
    id = "membrane",
    label = "Membrane Integrity",
    tier = TIER_BRANCH,
    cap = CAP_BRANCH,
    cost_base = SPORE_COST_BASE,
    cost_growth = SPORE_COST_GROWTH,
    requires = { "photosynthesis" },
    effects = { evasion = SPORE_MEMBRANE_PER },
  },
  {
    id = "forage_dom",
    label = "Foraging Dominance",
    tier = TIER_BRANCH,
    cap = CAP_BRANCH,
    cost_base = SPORE_COST_BASE,
    cost_growth = SPORE_COST_GROWTH,
    requires = { "photosynthesis" },
    effects = { competition = SPORE_FORAGE_DOM_PER },
  },
  -- Capstones -- each requires its whole branch maxed.
  {
    id = "metabolic_mastery",
    label = "Metabolic Mastery",
    tier = TIER_CAPSTONE,
    cap = CAP_CAPSTONE,
    cost_base = SPORE_COST_BASE,
    cost_growth = SPORE_COST_GROWTH,
    requires = { "photo_eff", "flagella", "chemo", "mitosis" },
    effects = { all_intake = SPORE_METABOLIC_PER },
  },
  {
    id = "homeostasis",
    label = "Homeostasis",
    tier = TIER_CAPSTONE,
    cap = CAP_CAPSTONE,
    cost_base = SPORE_COST_BASE,
    cost_growth = SPORE_COST_GROWTH,
    requires = { "detox", "membrane", "forage_dom" },
    effects = { pressure_damp = SPORE_HOMEO_PER },
  },
  -- Gate -- both capstones maxed unlocks it; its own maxing unlocks Mitochondria.
  {
    id = "engulf",
    label = "Engulf",
    tier = TIER_GATE,
    cap = CAP_GATE,
    cost_base = SPORE_COST_BASE,
    cost_growth = SPORE_COST_GROWTH,
    requires = { "metabolic_mastery", "homeostasis" },
    effects = { engulf_progress = SPORE_ENGULF_PROGRESS_PER }, -- reserved; consumed later
  },
  {
    id = "mitochondria",
    label = "Mitochondria",
    tier = TIER_PHASE2,
    cap = CAP_GATE,
    cost_base = SPORE_COST_BASE,
    cost_growth = SPORE_COST_GROWTH,
    requires = { "engulf" },
    effects = { endo_chance = ENDO_MITO_PER },
  },
}

-- The spine defs; treat as read-only (the kernel never mutates them, safe to share).
function spores.defs() return DEFS end

-- Kernel opts: the meta-currency name and the per-tier cost multiplier.
function spores.tree_opts() return { currency = "spores", tier_mult = SPORE_TIER_MULT } end

-- PURE instantaneous spore-value the orchestrator feeds to tree:observe(). Health-multiplied
-- (a fouled dish can't ratchet the peak) and vitality-weighted by clamped per-capita net
-- growth (>= 0, so a death-spiral's negative net_rate can't LOWER the value -- the peak only
-- ever reflects the colony at its healthiest). consts supplies tox_half (the toxicity-half
-- curve, shared with the live intake). No mutation.
function spores.value(sim_state, consts)
  local health = sim.health(sim_state.toxicity, consts.tox_half)
  local pop = math.max(sim_state.population, 1)
  local vit = 1 + SPORE_VITALITY_WEIGHT * math.max((sim_state.net_rate or 0) / pop, 0)
  return SPORE_EARN_K * pop ^ SPORE_GROWTH_EXP * health * vit
end

-- Fold the tree's leveled nodes into the economy modifiers the orchestrator mixes into the
-- sim intake. NEUTRAL when every level (and lifetime) is 0: the multipliers are 1 and the
-- additive terms 0, so the fold changes nothing until spores are spent. div_mult is clamped
-- > 0 (a positive multiplier even if the cut ever exceeded 100%); all_intake carries the
-- always-on lifetime bonus (0 at lifetime 0).
function spores.fold(tree)
  return {
    photo_mult = 1 + tree:effect_total("photo_mult"),
    forage_mult = 1 + tree:effect_total("forage"),
    sense_bonus = tree:effect_total("sense"),
    div_mult = math.max(1 + tree:effect_total("div"), 0.05), -- cheaper division; clamp > 0
    all_intake = 1
      + tree:effect_total("all_intake")
      + SPORE_LIFETIME_BONUS * tree:lifetime_amount(),
    cleanup = tree:effect_total("cleanup"), -- additive units/sec
    evasion_add = tree:effect_total("evasion"),
    comp_counter = tree:effect_total("competition"),
    pressure_damp = tree:effect_total("pressure_damp"),
    endo_chance_add = tree:effect_total("endo_chance"),
    engulf_progress = tree:effect_total("engulf_progress"),
  }
end

-- Effect magnitudes exported for the spec / harness mirror so they can assert the fold's
-- relationships against the SOURCE constants rather than hard-coded numbers.
spores.constants = {
  SPORE_EARN_K = SPORE_EARN_K,
  SPORE_GROWTH_EXP = SPORE_GROWTH_EXP,
  SPORE_VITALITY_WEIGHT = SPORE_VITALITY_WEIGHT,
  SPORE_LIFETIME_BONUS = SPORE_LIFETIME_BONUS,
  SPORE_PHOTO_EFF_PER = SPORE_PHOTO_EFF_PER,
  SPORE_MITOSIS_PER = SPORE_MITOSIS_PER,
}

return spores
