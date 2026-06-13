-- Endospores: the PHASE-1 dataset over the generic progression core
-- (lib/engine/progression_tree.lua). The core is layer-agnostic -- it knows leveled, gated,
-- tier-costed nodes and a peak-observing meta-currency that survives the within-phase reset,
-- but nothing about any economy. THIS module supplies the phase-1 spine (the data) and the
-- two pure folds the orchestrator needs: endospores.value() (the instantaneous endospore-value
-- the core observes, health-multiplied so a sick colony can't ratchet the peak) and
-- endospores.fold() (node levels -> economy modifiers, neutral until spent). Mirrors the
-- data-module pattern of organelles.lua / traits.lua: a read-only DEFS spine and pure fold
-- helpers, no love.*, no sim mutation. Reuses sim.health (sim.lua loads headless) for the
-- toxicity factor so the prestige value and the live intake throttle share one curve.
--
-- The endospore is the metaphor: bacterial endospores are the dormant survival capsule a
-- colony forms under hostile conditions, then germinates into a fitter generation -- the
-- reset IS that capsule. (Distinct from a fungal/mushroom spore; this is the bacterial one.)
--
-- SINGLE SOURCE: this module owns every ENDOSPORE_* tuning constant. The prestige harness
-- (tools/sim_lab.lua `prestige` mode) requires this module directly and never re-types a
-- magnitude -- so tune here and the harness follows. Placeholder values from
-- docs/phase1/BALANCE.md.
local endospores = {}

local sim = require("lib.layers.cell.sim")

-- EARNING -- endospores banked from health x growth (BALANCE.md "Earning"). The payout is
-- floor(EARN_K * peak_pop^GROWTH_EXP * vitality), so EARN_K scales loop-1 yield to ~one
-- branch node, GROWTH_EXP's sqrt curve makes the TREE (not one long grind) the lever, and
-- VITALITY_WEIGHT rewards cashing out a healthy, growing colony over a stalled one.
local ENDOSPORE_EARN_K = 1.0 -- payout scalar; dial so loop 1 opens one branch node
local ENDOSPORE_GROWTH_EXP = 0.5 -- sqrt diminishing curve on peak population -- the tree is the lever
local ENDOSPORE_VITALITY_WEIGHT = 1.0 -- how hard per-capita vitality scales payout -- rewards healthy cash-out
local ENDOSPORE_LIFETIME_BONUS = 0.005 -- small always-on bonus per lifetime endospore, so a weak run still counts

-- COSTS -- endospore spend per node level (BALANCE.md "Costs"). Geometric within a node
-- (COST_GROWTH per level), scaled by TIER_MULT^tier so each tier (branch -> capstone ->
-- Engulf -> Mitochondria) costs ~TIER_MULT x the last -- the capstone wall enforces
-- "master both branches first."
local ENDOSPORE_COST_BASE = 1 -- cost of the photosynthesis root (first spend; trivial)
local ENDOSPORE_COST_GROWTH = 1.6 -- geometric per-level multiplier within a node (1.5-1.7 band)
local ENDOSPORE_TIER_MULT = 10 -- each tier ~10x the previous; the capstone wall

-- PER-NODE EFFECT magnitudes (BALANCE.md "Tree node effects"), all per-level. The fold below
-- maps each onto one economy term. MITOSIS is a division-cost CUT, so it is stored NEGATIVE
-- and the fold turns the sum into a < 1 multiplier (cheaper division).
local ENDOSPORE_PHOTO_EFF_PER = 0.08 -- +0.08 biomass/sec from photosynthesis, per level
local ENDOSPORE_FLAGELLA_PER = 0.06 -- +0.06 swim speed & forage, per level
local ENDOSPORE_CHEMO_PER = 0.07 -- +0.07 sense range, per level
local ENDOSPORE_MITOSIS_PER = 0.05 -- -0.05 division cost, per level (applied negative below = cheaper)
local ENDOSPORE_METABOLIC_PER = 0.10 -- +0.10 all intake, per level (capstone)
local ENDOSPORE_DETOX_PER = 0.10 -- +0.10 waste cleanup, per level
local ENDOSPORE_MEMBRANE_PER = 0.08 -- +0.08 evasion, per level
local ENDOSPORE_FORAGE_DOM_PER = 0.08 -- +0.08 competition counter, per level
local ENDOSPORE_HOMEO_PER = 0.10 -- +0.10 vitality / pressure dampening, per level (capstone)
local ENDOSPORE_ENGULF_PROGRESS_PER = 0.15 -- +0.15 health & reproduction progress per engulf (consumed in cell.lua as the per-engulf burst multiplier)
local ENDO_MITO_PER = 0.0006 -- per-level boost to the endosymbiosis chance toward near-certain

-- CAPABILITY income channels. Buying Photosynthesis (the tree root) and Engulf opens a
-- flat, always-on income multiplier on top of the base economy -- faithful to the retired
-- biomass-unlock balance these replace (the old traits.UNLOCKS `income` values 0.3 / 0.8).
-- FLAT on unlock: the +ENGULF_INCOME holds at Engulf level >= 1; the per-LEVEL Engulf growth
-- is the engulf burst (ENDOSPORE_ENGULF_PROGRESS_PER, consumed in cell.lua), NOT this income.
local PHOTO_INCOME = 0.3 -- income the Photosynthesis root opens (matches the old photo unlock)
local ENGULF_INCOME = 0.8 -- income Engulf (level >= 1) opens (matches the old phagocytosis unlock)

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
-- / cost_growth are baked from the constants into every node; the core scales them by
-- TIER_MULT^tier. effects keys are read back by endospores.fold via tree:effect_total. `short`
-- is the compact chip label the love-ui tree_modal widget draws (the full name is `label`).
local DEFS = {
  {
    id = "photosynthesis",
    label = "Photosynthesis",
    short = "Photosynthesis",
    tier = TIER_ROOT,
    cap = CAP_ROOT,
    cost_base = ENDOSPORE_COST_BASE,
    cost_growth = ENDOSPORE_COST_GROWTH,
    -- photo_channel is a documented NO-OP marker: the photosynthesis capability gates on
    -- this node's id/level via endospores.capabilities (level >= 1), NOT on a folded effect.
    effects = { photo_channel = 1 },
  },
  -- GROWTH branch -- reach the plateau faster (speed / forage / sense / division).
  {
    id = "photo_eff",
    label = "Photosynthetic Efficiency",
    short = "Photo Eff",
    tier = TIER_BRANCH,
    cap = CAP_BRANCH,
    cost_base = ENDOSPORE_COST_BASE,
    cost_growth = ENDOSPORE_COST_GROWTH,
    requires = { "photosynthesis" },
    effects = { photo_mult = ENDOSPORE_PHOTO_EFF_PER },
  },
  {
    id = "flagella",
    label = "Flagellar Drive",
    short = "Flagella",
    tier = TIER_BRANCH,
    cap = CAP_BRANCH,
    cost_base = ENDOSPORE_COST_BASE,
    cost_growth = ENDOSPORE_COST_GROWTH,
    requires = { "photosynthesis" },
    effects = { forage = ENDOSPORE_FLAGELLA_PER },
  },
  {
    id = "chemo",
    label = "Chemotactic Reach",
    short = "Chemo",
    tier = TIER_BRANCH,
    cap = CAP_BRANCH,
    cost_base = ENDOSPORE_COST_BASE,
    cost_growth = ENDOSPORE_COST_GROWTH,
    requires = { "photosynthesis" },
    effects = { sense = ENDOSPORE_CHEMO_PER },
  },
  {
    id = "mitosis",
    label = "Mitotic Speed",
    short = "Mitosis",
    tier = TIER_BRANCH,
    cap = CAP_BRANCH,
    cost_base = ENDOSPORE_COST_BASE,
    cost_growth = ENDOSPORE_COST_GROWTH,
    requires = { "photosynthesis" },
    effects = { div = -ENDOSPORE_MITOSIS_PER }, -- negative = cheaper division
  },
  -- RESILIENCE branch -- raise the plateau (toxicity / predation / competition counters).
  {
    id = "detox",
    label = "Detox Vacuoles",
    short = "Detox",
    tier = TIER_BRANCH,
    cap = CAP_BRANCH,
    cost_base = ENDOSPORE_COST_BASE,
    cost_growth = ENDOSPORE_COST_GROWTH,
    requires = { "photosynthesis" },
    effects = { cleanup = ENDOSPORE_DETOX_PER },
  },
  {
    id = "membrane",
    label = "Membrane Integrity",
    short = "Membrane",
    tier = TIER_BRANCH,
    cap = CAP_BRANCH,
    cost_base = ENDOSPORE_COST_BASE,
    cost_growth = ENDOSPORE_COST_GROWTH,
    requires = { "photosynthesis" },
    effects = { evasion = ENDOSPORE_MEMBRANE_PER },
  },
  {
    id = "forage_dom",
    label = "Foraging Dominance",
    short = "Forage",
    tier = TIER_BRANCH,
    cap = CAP_BRANCH,
    cost_base = ENDOSPORE_COST_BASE,
    cost_growth = ENDOSPORE_COST_GROWTH,
    requires = { "photosynthesis" },
    effects = { competition = ENDOSPORE_FORAGE_DOM_PER },
  },
  -- Capstones -- each requires its whole branch maxed.
  {
    id = "metabolic_mastery",
    label = "Metabolic Mastery",
    short = "Metabolic",
    tier = TIER_CAPSTONE,
    cap = CAP_CAPSTONE,
    cost_base = ENDOSPORE_COST_BASE,
    cost_growth = ENDOSPORE_COST_GROWTH,
    requires = { "photo_eff", "flagella", "chemo", "mitosis" },
    effects = { all_intake = ENDOSPORE_METABOLIC_PER },
  },
  {
    id = "homeostasis",
    label = "Homeostasis",
    short = "Homeostasis",
    tier = TIER_CAPSTONE,
    cap = CAP_CAPSTONE,
    cost_base = ENDOSPORE_COST_BASE,
    cost_growth = ENDOSPORE_COST_GROWTH,
    requires = { "detox", "membrane", "forage_dom" },
    effects = { pressure_damp = ENDOSPORE_HOMEO_PER },
  },
  -- Gate -- both capstones maxed unlocks it; its own maxing unlocks Mitochondria.
  {
    id = "engulf",
    label = "Engulf",
    short = "Engulf",
    tier = TIER_GATE,
    cap = CAP_GATE,
    cost_base = ENDOSPORE_COST_BASE,
    cost_growth = ENDOSPORE_COST_GROWTH,
    requires = { "metabolic_mastery", "homeostasis" },
    effects = { engulf_progress = ENDOSPORE_ENGULF_PROGRESS_PER }, -- reserved; consumed later
  },
  {
    id = "mitochondria",
    label = "Mitochondria",
    short = "Mitochondria",
    tier = TIER_PHASE2,
    cap = CAP_GATE,
    cost_base = ENDOSPORE_COST_BASE,
    cost_growth = ENDOSPORE_COST_GROWTH,
    requires = { "engulf" },
    effects = { endo_chance = ENDO_MITO_PER },
  },
}

-- The spine defs; treat as read-only (the core never mutates them, safe to share).
function endospores.defs() return DEFS end

-- Core opts: the meta-currency name and the per-tier cost multiplier.
function endospores.tree_opts() return { currency = "endospores", tier_mult = ENDOSPORE_TIER_MULT } end

-- PURE instantaneous endospore-value the orchestrator feeds to tree:observe(). Health-multiplied
-- (a fouled dish can't ratchet the peak) and vitality-weighted by clamped per-capita net
-- growth (>= 0, so a death-spiral's negative net_rate can't LOWER the value -- the peak only
-- ever reflects the colony at its healthiest). consts supplies tox_half (the toxicity-half
-- curve, shared with the live intake). No mutation.
function endospores.value(sim_state, consts)
  local health = sim.health(sim_state.toxicity, consts.tox_half)
  local pop = math.max(sim_state.population, 1)
  local vit = 1 + ENDOSPORE_VITALITY_WEIGHT * math.max((sim_state.net_rate or 0) / pop, 0)
  return ENDOSPORE_EARN_K * pop ^ ENDOSPORE_GROWTH_EXP * health * vit
end

-- Fold the tree's leveled nodes into the economy modifiers the orchestrator mixes into the
-- sim intake. NEUTRAL when every level (and lifetime) is 0: the multipliers are 1 and the
-- additive terms 0, so the fold changes nothing until endospores are spent. div_mult is clamped
-- > 0 (a positive multiplier even if the cut ever exceeded 100%); all_intake carries the
-- always-on lifetime bonus (0 at lifetime 0).
function endospores.fold(tree)
  return {
    photo_mult = 1 + tree:effect_total("photo_mult"),
    forage_mult = 1 + tree:effect_total("forage"),
    sense_bonus = tree:effect_total("sense"),
    div_mult = math.max(1 + tree:effect_total("div"), 0.05), -- cheaper division; clamp > 0
    all_intake = 1
      + tree:effect_total("all_intake")
      + ENDOSPORE_LIFETIME_BONUS * tree:lifetime_amount(),
    cleanup = tree:effect_total("cleanup"), -- additive units/sec
    evasion_add = tree:effect_total("evasion"),
    comp_counter = tree:effect_total("competition"),
    pressure_damp = tree:effect_total("pressure_damp"),
    endo_chance_add = tree:effect_total("endo_chance"),
    engulf_progress = tree:effect_total("engulf_progress"),
  }
end

-- The CAPABILITY BRIDGE: the single source mapping tree state -> the milestone gates the
-- cell orchestrator needs. The three capabilities (photosynthesis, phagocytosis, and the
-- endosymbiosis proc) now live on the tree, not in-run. Gate on tree:level_of(id) >= 1
-- (BOUGHT) -- NOT tree:is_unlocked(id), which in the generic core means "every requires is
-- maxed" (merely buyable). Photosynthesis (the root) opens the light channel + the
-- PHOTO_INCOME multiplier and reveals the levelable Photosynthesis biomass trait; Engulf
-- (level >= 1) enables phagocytosis (prey/predators spawn, +ENGULF_INCOME, organelle
-- eligibility), with each level raising the per-engulf burst (engulf_progress, consumed in
-- cell.lua). unlock_income is the flat-on-unlock income multiplier. Pure over tree state
-- (no clock / RNG), so it is offline-deterministic like the rest of the fold.
function endospores.capabilities(tree)
  local photosynthesis = tree:level_of("photosynthesis") >= 1
  local predation = tree:level_of("engulf") >= 1
  return {
    photosynthesis = photosynthesis,
    predation = predation,
    unlock_income = 1 + (photosynthesis and PHOTO_INCOME or 0) + (predation and ENGULF_INCOME or 0),
  }
end

-- Effect magnitudes exported for the spec / harness mirror so they can assert the fold's
-- relationships against the SOURCE constants rather than hard-coded numbers.
endospores.constants = {
  ENDOSPORE_EARN_K = ENDOSPORE_EARN_K,
  ENDOSPORE_GROWTH_EXP = ENDOSPORE_GROWTH_EXP,
  ENDOSPORE_VITALITY_WEIGHT = ENDOSPORE_VITALITY_WEIGHT,
  ENDOSPORE_LIFETIME_BONUS = ENDOSPORE_LIFETIME_BONUS,
  ENDOSPORE_PHOTO_EFF_PER = ENDOSPORE_PHOTO_EFF_PER,
  ENDOSPORE_MITOSIS_PER = ENDOSPORE_MITOSIS_PER,
  ENDOSPORE_CHEMO_PER = ENDOSPORE_CHEMO_PER,
  ENDOSPORE_ENGULF_PROGRESS_PER = ENDOSPORE_ENGULF_PROGRESS_PER,
  PHOTO_INCOME = PHOTO_INCOME,
  ENGULF_INCOME = ENGULF_INCOME,
}

return endospores
