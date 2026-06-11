-- Complex-cell view: programmatic, asset-free visuals for the INTERIOR of a single
-- eukaryotic cell -- the phase-2 sibling of lib/layers/cell/view.lua. Same discipline:
-- love.* is touched ONLY inside draw-time code (so a bare `require` loads headless),
-- transient beats compose through an fx controller (lib/engine/fx.lua), and every
-- color binds a GLOBAL token from lib/engine/colors -- no literal RGB, no per-layer
-- palette. Where phase 1 framed a dish of flat squares with a stepped fit-camera, this
-- view frames the cytoplasm of ONE cell and aims a swarm INWARD: recognizable
-- organelles at anatomically-anchored positions, and a teeming cloud of vesicles/cargo
-- hauling between them, inside a big wobbling membrane. The orchestrator
-- (complexcell.lua) draws the panel/HUD on top -- this file draws NOTHING of the UI.
--
-- ANATOMICAL ZONES (the phase-2 rework, docs/phase2/DESIGN.md sections 1-2). The
-- old single endpoint RING is gone. Each pipeline stage now sits at a STABLE,
-- anatomically-inspired position keyed to the reference cross-section: nucleus at the
-- centre hub; ribosomes + rough ER as a band hugging the nucleus on one side; the
-- Golgi offset outward from the ER's face; transport/membrane toward the rim; and the
-- mitochondria at FIXED inner-mid positions. Positions are DETERMINISTIC and never
-- reshuffle on level-up -- leveling only grows an organelle in place (the brief's
-- invariant). The swarm's segment legs connect these zone positions in pipeline order
-- (ribosomes -> nucleus -> er -> golgi -> transport -> membrane), so the factory-flow
-- read survives on a body that now looks like a cell.
--
-- THE SWARM IS GPU-INSTANCED (lib/layers/complexcell/interior_swarm.lua) -- the SOLAR
-- layer's proven instanced-mesh technique pointed inward: a fixed, large instance
-- buffer filled ONCE at load with stateless vesicle routes, each vesicle's position a
-- CLOSED-FORM function of (per-instance attributes, time, endpoint uniforms) in the
-- vertex shader. The CPU does ~zero per-instance work; per frame this view ships only
-- a handful of uniforms (the zone endpoint positions, the per-segment flow readouts,
-- the global flow scalars, and a cargo-type palette) and raises the live instance
-- count. The membrane + nucleus + organelles stay CPU primitives FRAMING that cloud.
--
-- READING STATE THROUGH FLOW (the core ask -- docs/phase2/DESIGN.md sections 4-5).
-- Every visual is a CONTINUOUS response to a snapshot field, never a discrete state
-- machine:
--   * MEMBRANE -- a soft body disk with a bright wobbling rim. Rim glow eases with
--     `output` (a lively cell glows). [CPU primitive, framing the swarm.]
--   * NUCLEUS -- the centre hub; chromatin speckle detail fills in with its level.
--   * ORGANELLES -- a draw pass between the membrane and the swarm: rough ER ribbons
--     studded with ribosome dots, a Golgi cisternae stack, stationary mitochondria
--     beans with cristae, cytoskeleton filaments. Each is a recipe of splines + simple
--     polygons tinted from color tokens, scaled by its stage level. [CPU primitives.]
--   * ENDPOINTS = zone positions -- one per UNLOCKED stage at its STABLE anatomical
--     position, then one mitochondria emitter per DRAWN bean (co-located with the
--     bodies, so vesicles land ON the power plants). Uploaded as the swarm's `endpoints`
--     uniform each frame. Vesicles haul along the SEGMENTS between them.
--   * LIVE COUNT -- starts as a HANDFUL and grows with leveling: a base of ~8 plus a
--     `throughput` term (leveling a stage adds vesicles immediately) plus a smaller
--     `built` bulk term, log-scaled and hard-capped. ("Growth is detail.")
--   * EFFICIENCY (`efficiency`, 0..1) -- the DOMINANT liveliness driver: it sets the
--     swarm's global speed + brightness. Optimal (eff ~= 1) = fast + bright; low eff =
--     slow + dim. The eased brownout dim/slow then composes on top.
--   * OVER-BUILD (per-stage 0..1) -- a stage leveled ABOVE the line's throughput is idle
--     surplus: its SEGMENT bows FATTER, clumps, and DIMS (over-stuffed, not a hot lane).
--   * CHOKE (severity 0..1) -- the bottleneck's segment CONSTRICTS into a tight thread and
--     piles cargo up at it, scaled by how hard it pins the line (1 - flow_balance), so a
--     BALANCED cell reads uniform (no false choke on the nominal minimum lane). No halo.
--   * VACANCY -- segments DOWNSTREAM of the bottleneck thin out (parked off-screen), faded
--     where the lane is itself over-built so over-build wins on a lane that is both.
--   * BROWNOUT (`brownout`) -- an energy deficit DIMS + SLOWS the whole swarm, eased
--     over time; the mitochondria gutter FIRST (drawn dim under brownout).
--   * `fuel_factor` -- a subtle whole-interior TINT (>1 plant/green, <1 animal/warm).
-- Red-pulsing is deliberately NOT used here -- held in reserve as an accessibility
-- accent only (per the design brief), so the default language stays flow.
--
-- CHEAP SIM, EXPENSIVE-LOOKING VISUALS. update() only advances clocks and eases the
-- brownout dim/slow + fuel tint; there is no per-particle simulation anywhere -- the
-- vesicle motion is closed-form in the GPU vertex shader, and the framing primitives
-- are a handful of circles/polygons/splines. Cost is bounded regardless of how large
-- `built` grows.
--
-- HEADLESS-SAFE LOAD. ALL GPU work is deferred: this module and interior_swarm
-- bare-`require` without touching love.* or FFI. The swarm lazily initializes on first
-- draw; the membrane/nucleus/organelle draws live below the "draw-time" line.
local fx = require("lib.engine.fx")
local colors = require("lib.engine.colors")
local interior_swarm = require("lib.layers.complexcell.interior_swarm")

local view = {}

-- ============================================================================
-- Tunables (all cosmetic; none feed the authoritative sim).
-- ============================================================================

-- The cell body fills this fraction of the smaller window dimension (radius).
local CELL_FILL = 0.42
local MEMBRANE_WOBBLE = 0.018 -- rim wobble as a fraction of the cell radius
local MEMBRANE_WOBBLE_FREQ = 0.6 -- wobble cycles/sec (gentle)
local RIM_WIDTH = 3 -- membrane rim line width in screen px

-- Mitochondria emitters: extra endpoints (power plants) the swarm hauls ATP to/from --
-- power feeding the line. They sit at the EXACT positions the beans are DRAWN at (one
-- emitter per drawn body, via mito_body_pose -- see build_routes), so the vesicles
-- converge ON the visible mitochondria instead of on a separate fixed angle-ring that
-- drifted off the beans once the reticulum fused. The drawn body count is itself bounded
-- (<= MITO_BODY_MAX), so the emitter block stays well under the swarm's MAX_ENDPOINTS --
-- no extra cap needed. They append after the stage endpoints.
local MITO_RING_FRAC = 0.62 -- mitochondria sit on this inner-mid annulus (was 0.50, which cut
-- through the ER ribbons); pushed out to its OWN clear band between the nucleus-hugging ER
-- (<=~0.44) and the rim organelles (Golgi/transport/membrane at frac >= 0.70)

-- MITOCHONDRIA RENDER (Pillar 4): the DRAWN picture is decoupled from the swarm-endpoint
-- cap above so it keeps moving with state.mito into the hundreds. Real mitochondria are a
-- dynamic FUSED RETICULUM, not a fixed handful of beans -- so low counts read as discrete
-- beans at the fixed MITO_ANGLES (today's look), and as the count climbs those beans FUSE:
-- the bodies elongate, tubules bridge adjacent ring anchors into a branched network, and
-- the cristae densify. None of this touches the economy (power = POWER_PER_MITO*mito is
-- unchanged); it is purely how the same number is shown.
--
-- FUSION is driven by a 0..1 `reticulum` factor: a log sample of mito mapped across
-- [MITO_FUSE_START, MITO_FUSE_FULL] power-plant counts. Below START the cell is all
-- discrete beans; at FULL the ring is a fully-bridged network. Log-scaled so the network
-- keeps visibly thickening from a few dozen into the hundreds without ever exploding the
-- per-frame primitive count (the body/tubule/cristae counts are all bounded samples).
local MITO_FUSE_START = 8 -- below this many plants: discrete beans only (the opening look)
local MITO_FUSE_FULL = 220 -- at/above this: a fully-bridged reticulum (real cells hold hundreds)
local MITO_BODY_MIN = 6 -- discrete-bean phase draws this many bodies (the MITO_ANGLES anchors)
local MITO_BODY_MAX = 14 -- a dense reticulum draws up to this many merged bodies around the ring
local MITO_CRISTAE_MIN = 2 -- cristae arcs per body at the sparse end
local MITO_CRISTAE_MAX = 6 -- cristae arcs per body in a dense, fused body (denser folding)
local MITO_ELONGATE = 1.9 -- a fully-fused body stretches to this multiple of the discrete bean length
local MITO_TUBULE_WIDTH = 0.018 -- connecting-tubule line width as a fraction of cell radius
-- Past the discrete-bean phase (count > the fixed MITO_ANGLES anchors) the bodies are placed
-- EVENLY around the ring from this base angle, so a fused reticulum never piles two bodies on
-- one spot. The old scheme mixed the fixed anchors (m<=6) with an even fill (m>6) computed off
-- a different formula, so the two collided and beans visibly stacked; even placement for the
-- whole fused ring fixes that. Discrete low counts still use the hand-placed MITO_ANGLES.
local MITO_RING_PHASE = math.rad(-90) -- first evenly-placed body sits at the top, then clockwise
-- Bean geometry. A mitochondrion is drawn as a fat rounded CAPSULE (stadium: two semicircular
-- end caps joined by straight sides), NOT a thin pinched ellipse -- the old shape tapered to
-- sharp lens tips and read as an "eye", not a bean. A fatter half-width + true rounded caps give
-- the plump bean silhouette. The capsule is convex, so it still fills as a single polygon.
local MITO_BEAN_LEN = 0.12 -- base bean half-length as a fraction of cell radius (the discrete bean)
local MITO_BEAN_W = 0.072 -- base bean half-width; fatter than the old 0.055 so beans read round, not pointed
local MITO_FUSE_NARROW = 0.15 -- a fully-fused body narrows by this fraction (the tubular reticulum look)
local MITO_CAP_SEGS = 10 -- samples per rounded end cap (smooth bean tips)
local MITO_CRISTAE_SPAN = 0.62 -- cristae spread along the long axis as a fraction of bean_len
local MITO_CRISTAE_REACH = 0.55 -- crista half-length across the short axis as a fraction of bean_w

-- Live vesicle count: START as a handful and GROW with the cell (the phase-1 "fills as
-- you grow" feel). Base is a tiny opening crowd; growth is driven by `throughput`
-- (leveling a stage adds vesicles IMMEDIATELY, log-scaled) plus a `built` bulk term that
-- is SQRT-scaled. The old bulk term was log(1+built), which FLATTENED late: the whole
-- interior topped out near ~185 vesicles against a 4000 budget, so it "barely densified"
-- across the run. sqrt(built) keeps climbing the long game instead, so the cytoplasm
-- visibly fills as built grows. Summed, hard-capped well below the GPU ceiling. NEVER the
-- literal value.
--   count = COUNT_BASE + K_FLOW*log(1+throughput) + K_BULK*sqrt(built)
-- Tuning intent (throughput ~ 5..300 and built ~ 0..180000 [the FORK] across the phase):
--   open   (T~5,    built~0)     ->  4 + 15*ln(6)   + 8*sqrt(0)      -> ~31   (sparse handful)
--   early  (T~30,   built~5000)  ->  4 + 15*ln(31)  + 8*sqrt(5000)   -> ~621  (filling in)
--   mid    (T~120,  built~50000) ->  4 + 15*ln(121) + 8*sqrt(50000)  -> ~1865 (busy)
--   late   (T~300,  built~180000)->  4 + 15*ln(301) + 8*sqrt(180000) -> ~3484 (dense, nears the cap)
-- WHY sqrt: log(1+built) added only ~8*ln(50001) ~= 86 vesicles by built 50k and then went
-- flat; sqrt(built) keeps the "growth is detail" climb alive into the late game while still
-- opening sparse (the bulk term is 0 at built 0). COUNT_BASE / K_FLOW / K_BULK are eyeball-
-- tuned first guesses -- pin them in-game; the count stays well under MAX_LIVE_VESICLES.
local COUNT_BASE = 4 -- the opening handful (keeps early game sparse)
local K_FLOW = 15 -- multiplies log(1 + throughput): leveling adds vesicles at once
local K_BULK = 8 -- multiplies sqrt(built): the long-game bulk fill that keeps climbing (was log)
local MAX_LIVE_VESICLES = 4000 -- the view's hard cap (low-thousands -- stays readable)

-- EFFICIENCY -> global liveliness (the dominant driver). eff in [0,1] lerps the swarm
-- speed + brightness between these floors and ceilings; the eased brownout state then
-- multiplies in (dim + slow), so the two readouts compose. Optimal (eff~1) = fast +
-- bright; low eff = slow + dim.
local SPEED_SLOW = 0.55 -- swarm speed at eff = 0 (still drifts, just sluggish)
local SPEED_FAST = 1.6 -- swarm speed at eff = 1 (a teeming, busy interior)
local BRIGHT_DIM = 0.5 -- swarm brightness at eff = 0
local BRIGHT_BRIGHT = 1.15 -- swarm brightness at eff = 1

-- Output is now only a MINOR secondary liveliness term layered on top of efficiency
-- (a busy cell glows a touch more). Kept small so efficiency dominates.
local OUTPUT_REF = 60 -- output at which the small output bonus is ~half-saturated
local OUTPUT_SPEED_BONUS = 0.18 -- max extra speed from output (added to the eff lerp)
local OUTPUT_BRIGHT_BONUS = 0.12 -- max extra brightness from output

-- Brownout: the whole swarm eases toward this brightness + this speed slowdown.
local BROWNOUT_DIM = 0.42 -- swarm brightness multiplier at full brownout
local BROWNOUT_SLOW = 0.30 -- swarm speed multiplier at full brownout
local DIM_EASE = 2.5 -- per-second lerp rate toward the brownout target

-- fuel_factor tint hook: how far a full plant/animal lean colors the interior.
local FUEL_TINT = 0.18

-- Membrane / nucleus framing alpha (CPU primitives around the swarm).
local CYTOPLASM_ALPHA = 0.5
local NUCLEUS_R_FRAC = 0.30 -- nucleus radius as a fraction of cell radius

-- MANUAL-TAP CUE (the "feed me" affordance). When the kickstart ATP tap is off cooldown
-- (snapshot.tap_ready) ONE randomly-chosen mitochondrion is "primed": a soft green halo ring
-- pulses around it. The affordance lives on a POWER PLANT, not the nucleus -- tapping to inject
-- ATP is thematically the mitochondria's job -- and it hops to a fresh bean each ready-window.
-- The orchestrator picks the bean via a stable 0..1 seed (snapshot.tap_seed) held until the tap
-- is spent, so the cue sits on ONE plant rather than flickering. Drawn at FULL brightness (NOT
-- brownout-dimmed) so it stays legible exactly when the cell is starved and the tap matters
-- most. It reuses the green secondary_bright FEED token (the phase-1 bloom language), now
-- localized onto the chosen organelle.
local MITO_TAP_HALO_SCALE = 1.35 -- halo radius as a multiple of the primed bean's long axis
local MITO_TAP_PULSE_AMP = 0.18 -- +/- size breathe on the halo (clear but unhurried)
local MITO_TAP_PULSE_FREQ = 3.2 -- halo pulse angular frequency in rad/s (~2s period)
local MITO_TAP_ALPHA = 0.5 -- base halo alpha: it IS the call-to-action, so present, not a whisper
local MITO_TAP_WIDTH = 1.5 -- halo outline width in px
local MITO_TAP_HIT_SCALE = 1.7 -- click hit radius as a multiple of the bean's long axis (forgiving target)

-- ROUGH ER band: the ribbons nest OUTWARD from the nucleus rim across this fraction range.
-- They must stay INSIDE the mito ring (MITO_RING_FRAC = 0.62) so the ER reads as hugging the
-- nucleus rather than sprawling into the power band. Previously the ribbons stepped at frac
-- (0.30 + 0.05*b), so a max-level 5-ribbon ER reached frac 0.55 and collided with the mito
-- ring. Now the innermost ribbon sits just past the nucleus rim (0.30) and the step is small
-- enough that even 5 ribbons top out at ER_RIBBON_INNER + 4*ER_RIBBON_STEP ~= 0.45 -- a clean
-- gap below the mito ring. The decluttering comment's promised "ER hugs the nucleus, 0.32..0.44"
-- now actually holds in the geometry.
local ER_RIBBON_INNER = 0.33 -- innermost ribbon radius as a fraction of cell radius (just past the nucleus rim)
local ER_RIBBON_STEP = 0.03 -- per-ribbon outward step; 5 ribbons span 0.33..0.45, clear of the mito ring

-- GOLGI cisternae stack: a short nest of cupped, plump CRESCENT SACS (the reference Golgi look)
-- with round vesicles budding off the trans face. The earlier pass tapered the plate width hard
-- (0.13 -> 0.07) and stacked the arcs, so the tips converged into a CONE/shuttlecock rather than
-- a stack of parallel sacs. The fix: (a) a GENTLE taper so the sacs stay near-parallel and read
-- as nested curved tubes, (b) a PLUMP body stroke with rounded end caps so each cisterna reads
-- as a solid flattened sac (not a thin open arc) under a brighter rim, and (c) round budding
-- vesicles in the same warm tone. All sizes are fractions of the cell radius (px for stroke
-- widths / cap radii), so the stack scales with the window.
local GOLGI_GAP = 0.04 -- spacing between stacked sacs (room for the plumper body stroke)
local GOLGI_CIS_WIDTH = 0.12 -- half-width of the WIDEST (cis, innermost) sac
local GOLGI_TRANS_WIDTH = 0.09 -- half-width of the SHORTEST (trans, outer) sac; GENTLE taper (no cone)
local GOLGI_BOW = 0.05 -- how far each sac bows outward at its midpoint (the gentle crescent curve)
local GOLGI_BODY_WIDTH = 5 -- plump body stroke width in px: reads as a flattened SAC, not a thin line
local GOLGI_EDGE_WIDTH = 1.5 -- brighter top edge stroke width in px (the highlight rim)
local GOLGI_BODY_ALPHA = 0.5 -- body stroke alpha (the soft warm membrane)
local GOLGI_EDGE_ALPHA = 0.85 -- edge stroke alpha (the crisp rim that gives the stack definition)
local GOLGI_EDGE_BRIGHT = 1.25 -- edge brightness multiplier on the tertiary token (a lighter warm highlight)
local GOLGI_BUD_OFFSET = 0.025 -- how far past the trans face the budding vesicles sit (fraction of r)
local GOLGI_BUD_R = 2 -- budding Golgi-vesicle radius in px (round sacs pinching off the trans face)

-- CYTOSKELETON (the TRANSPORT stage): the cell's microtubule scaffold, drawn as an evenly
-- spaced radial ASTER -- faint filament tracks fanning OUTWARD from a hub beside the nucleus to
-- the cell periphery, the rails the vesicle swarm rides. Replaces the old per-leg parallel
-- bundles that bunched into an overlapping mess near the centre with no legible shape. Even
-- angular spacing means the spokes never overlap; a slight tangential curl keeps it organic
-- (a soft pinwheel, not a hard star). COUNT scales with the transport level (a more-developed
-- cytoskeleton = a denser scaffold). All radii are fractions of the cell radius.
local CYTO_SPOKES_BASE = 7 -- radial filaments at a freshly-unlocked transport stage
local CYTO_SPOKES_SCALE = 2.4 -- log growth of the spoke count with the transport level
local CYTO_SPOKES_MAX = 16 -- cap (a dense but still legible aster)
local CYTO_INNER_FRAC = 0.33 -- spokes start just outside the nucleus rim (never cross the nucleus)
local CYTO_OUTER_FRAC = 0.86 -- ...and reach toward the rim, just inside the rim organelles
local CYTO_CURL = 0.05 -- tangential bow at the midpoint: a soft pinwheel curl, fraction of r
local CYTO_ALPHA = 0.18 -- faint background scaffolding that never competes with the swarm/organelles
local CYTO_PHASE = math.rad(-90) -- first spoke points up; the rest fan evenly clockwise

-- The fixed pipeline order (matches the sim's stage ids). The view lays endpoints
-- out in THIS order, and uses the index to judge up/downstream of the bottleneck for
-- the vacancy readout.
local STAGE_ORDER = {
  "ribosomes",
  "nucleus",
  "er",
  "golgi",
  "transport",
  "membrane",
}
local STAGE_INDEX = {}
for i = 1, #STAGE_ORDER do
  STAGE_INDEX[STAGE_ORDER[i]] = i
end

-- ============================================================================
-- ANATOMICAL ZONE LAYOUT (pure data -- no love.*).
--
-- Each stage's zone is a STABLE position given as a (radius-fraction, angle) polar
-- offset from the cell centre. These are fixed constants: leveling NEVER moves them.
-- The scheme distributes zones AROUND the whole cell so organelles don't cluster:
-- the nucleus-hugging structures (ribosomes, ER) sit upper-left; the Golgi steps
-- below-centre; transport and membrane sweep to the right side of the cell, giving
-- each zone clear breathing room. Pipeline order is preserved in the angular sweep
-- (ribosomes -> nucleus -> er -> golgi -> transport -> membrane sweeps clockwise
-- through the cell's interior, ending at the upper-right rim).
--
--   nucleus    -> centre (the hub)                            frac 0.00
--   ribosomes  -> on the nucleus surface, upper-left          frac 0.30, ~135 deg
--   er         -> band hugging the nucleus, left-lower        frac 0.40, ~215 deg
--   golgi      -> a clear mid band out past the mito ring     frac 0.70, ~275 deg
--   transport  -> toward the rim, lower-right                 frac 0.80, ~330 deg
--   membrane   -> the rim, upper-right                        frac 0.90, ~55  deg
--
-- WHY these fracs/angles (the overlap-decluttering pass): the prior layout left three
-- bands COLLIDING regardless of angle -- the tap ring (frac 0.34) sat on top of the
-- ribosomes (0.30) and the inner ER ribbons; the FULL-circle mito ring (frac 0.50)
-- cut straight through the ER ribbons (which sprawled out to frac ~0.55) and crowded
-- the Golgi (0.62). The fix opens clean concentric BANDS, inner-to-outer:
--   nucleus disk (<=0.30) | tap ring (~0.32) + ER ribbons hugging it (0.32..0.44) |
--   mito ring (0.62) | Golgi/transport/membrane (0.70..0.90 at spread angles).
-- The ER ribbons are pulled IN to hug the nucleus tightly (see draw_er's tighter
-- radii) instead of sprawling into the mito band; the mito ring is pushed OUT to its
-- own empty annulus (MITO_RING_FRAC below); and the rim organelles step out to 0.70+.
-- The pipeline still sweeps clockwise 135 -> 215 -> 275 -> 330 -> 55 with each zone
-- >= 55 deg from its neighbours, and the fracs grow monotonically so the pipeline
-- still reads as "travelling outward" from hub to rim. NUCLEUS_R_FRAC (0.30) is
-- unchanged; ribosomes sit at its surface (frac 0.30) so they read as attached.
--
-- Angles are in RADIANS (screen space: +x right, +y down, so positive angle sweeps
-- clockwise on screen). Stored per-id so build_routes can place only UNLOCKED stages.
-- ============================================================================
local ZONE = {
  nucleus = { frac = 0.00, angle = 0.0 },
  ribosomes = { frac = 0.30, angle = math.rad(135) },
  er = { frac = 0.40, angle = math.rad(215) },
  golgi = { frac = 0.70, angle = math.rad(275) },
  transport = { frac = 0.80, angle = math.rad(330) },
  membrane = { frac = 0.90, angle = math.rad(55) },
}

-- Resolve a zone's STABLE screen position. Pure: (cx, cy, r) + the fixed polar offset.
local function zone_pos(id, cx, cy, r)
  local z = ZONE[id]
  if not z then
    return cx, cy
  end
  local rr = r * z.frac
  return cx + math.cos(z.angle) * rr, cy + math.sin(z.angle) * rr
end

-- FIXED mitochondria angles on the inner-mid annulus (deterministic, never reshuffled).
-- A more-powered cell lights up MORE of these SAME positions, in order. Angles are
-- chosen to fill the "gaps" between pipeline zones (upper-right, upper, right, and
-- lower-left quadrants) so the beans read as scattered, not piled on the organelles.
local MITO_ANGLES = {
  math.rad(75), -- upper-right gap (between membrane at 55 and ribosomes at 135)
  math.rad(175), -- left gap (between ribosomes at 135 and ER at 215)
  math.rad(245), -- lower-left gap (between ER at 215 and Golgi at 275)
  math.rad(305), -- lower-right gap (between Golgi at 275 and transport at 330)
  math.rad(20), -- right gap (between transport at 330 and membrane at 55)
  math.rad(115), -- upper-left (fills the wide upper arc for a 6th bean)
}

-- ============================================================================
-- Helpers (pure -- no love.*).
-- ============================================================================

local function clamp01(v)
  if v < 0 then
    return 0
  elseif v > 1 then
    return 1
  end
  return v
end

local function lerp(a, b, t) return a + (b - a) * t end

-- A cheap deterministic 0..1 hash from an integer seed -- used only for the framing
-- primitives' speckles/dot scatter (the swarm itself bakes its own scatter into the
-- instance buffer). Stateless by design.
local function hash01(n)
  local s = math.sin(n * 12.9898) * 43758.5453
  return s - math.floor(s)
end

-- Logarithmic sample: BASE + SCALE*log(1+value), capped. A READABLE SAMPLE of a sim
-- quantity, never the literal value (scale-of-numbers honesty).
local function sample_count(value, base, scale, cap)
  value = value or 0
  if value < 0 then
    value = 0
  end
  local n = base + scale * math.log(1 + value)
  n = math.floor(n + 0.5)
  if n > cap then
    n = cap
  end
  return n
end

-- Soft saturating 0..1 curve: value/(value+ref). Maps an unbounded sim quantity onto
-- a bounded liveliness without a hard clip (half-saturated at value == ref).
local function saturate(value, ref)
  value = value or 0
  if value < 0 then
    value = 0
  end
  return value / (value + ref)
end

-- Find a stage row by id in the snapshot's stages list (linear scan -- at most 6).
local function find_stage(stages, id)
  for i = 1, #stages do
    if stages[i].id == id then
      return stages[i]
    end
  end
  return nil
end

-- ============================================================================
-- CARGO PALETTE (pure -- color tokens only, no literal RGB). One colour per pipeline
-- LEG, passed into interior_swarm.draw{ cargo_palette = ... }. Agent C's swarm honors
-- it (and provides a default); we pass ours regardless. The leg->cargo mapping follows
-- the pipeline order so the cloud reads as identifiable typed streams:
--   leg 0 ribosomes->nucleus   transcript      primary (teal)
--   leg 1 nucleus->er          transcript      primary_dark
--   leg 2 er->golgi            folded protein   tertiary (warm sand)
--   leg 3 golgi->transport     secretory        secondary_bright
--   leg 4 transport->membrane  secretory        secondary
--   leg 5 mito->line           ATP              secondary_bright (bright power)
-- Tokens are reused for adjacent legs so the small palette stays legible at pixel-grid
-- resolution. Built once at load (it's static); strip alpha to rgb triples.
-- ============================================================================
local function rgb(token) return { token[1], token[2], token[3] } end

local CARGO_PALETTE = {
  rgb(colors.primary), -- transcript (nucleus inbound)
  rgb(colors.primary_dark), -- transcript (into the ER)
  rgb(colors.tertiary), -- folded protein
  rgb(colors.secondary_bright), -- secretory vesicle
  rgb(colors.secondary), -- secretory vesicle (to the rim)
  rgb(colors.secondary_bright), -- ATP (mito power)
}

-- ============================================================================
-- View lifecycle.
-- ============================================================================

function view.new()
  -- dim/drift are EASED cosmetic state (brownout fade), so update() has continuous
  -- values to lerp toward each frame; fx is the shared effects controller. The swarm
  -- itself is stateless GPU machinery -- the only per-view state is these eased
  -- cosmetics plus reused scratch arrays so draw allocates nothing per frame.
  return {
    time = 0,
    fx = fx.new(),
    dim = 1, -- 1 = full brightness; eases toward BROWNOUT_DIM under brownout
    drift = 1, -- 1 = full speed; eases toward BROWNOUT_SLOW under brownout
    tint = { 1, 1, 1 }, -- eased fuel tint multiplier (neutral white at fuel 1.0)
    endpoints_x = {},
    endpoints_y = {},
    segments = {},
    -- The primed-mitochondrion hit target (screen x,y + radius), stamped each draw so the
    -- orchestrator can hit-test a click against the glowing power plant. `active` is false
    -- when no tap is pending. Reused in place so draw allocates nothing per frame.
    tap_target = { x = 0, y = 0, r = 0, active = false },
  }
end

-- Cosmetic animation only -- advance the clocks and ease the brownout dim/slow + fuel
-- tint toward their targets. No game state, no GPU work.
function view.update(state, dt)
  state.time = state.time + dt
  fx.update(state.fx, dt)
  interior_swarm.update(dt)

  local dim_target = state.dim_target or 1
  local drift_target = state.drift_target or 1
  local k = clamp01(dt * DIM_EASE)
  state.dim = state.dim + (dim_target - state.dim) * k
  state.drift = state.drift + (drift_target - state.drift) * k

  local tt = state.tint_target
  if tt then
    state.tint[1] = state.tint[1] + (tt[1] - state.tint[1]) * k
    state.tint[2] = state.tint[2] + (tt[2] - state.tint[2]) * k
    state.tint[3] = state.tint[3] + (tt[3] - state.tint[3]) * k
  end
end

-- Spawn a composable effect onto this view's fx controller; returns it. (Kept exactly
-- as the public interface the orchestrator depends on.)
function view.spawn(state, effect) return fx.add(state.fx, effect) end

-- The primed-mitochondrion manual-tap hit target: returns screen x, y, radius when a tap is
-- pending and a power plant is glowing, or nil otherwise. The orchestrator hit-tests a click
-- against this so ONLY the glowing mitochondrion injects ATP. Stamped during draw; the one
-- frame of lag is harmless since the bean position is static between frames.
function view.tap_target(state)
  local t = state.tap_target
  if t and t.active then
    return t.x, t.y, t.r
  end
  return nil
end

-- ============================================================================
-- Draw helpers (love.* lives ONLY below this line, inside draw-time code).
-- ============================================================================

-- Resolve the fuel tint target from fuel_factor: >1 leans toward the green token
-- (plant), <1 toward the warm sand token (animal), 1.0 = neutral white.
local function fuel_tint_target(fuel)
  fuel = fuel or 1
  local lean = clamp01(math.abs(fuel - 1)) * FUEL_TINT
  local token = (fuel >= 1) and colors.secondary or colors.tertiary
  return {
    (1 - lean) + lean * token[1],
    (1 - lean) + lean * token[2],
    (1 - lean) + lean * token[3],
  }
end

-- Apply the eased interior dim + fuel tint on top of a token color, then set it. Used
-- by the framing primitives so the membrane/nucleus/organelles dim + tint in lockstep
-- with the swarm (the whole interior reads as one cell under brownout / fuel lean).
local function set_interior_color(state, token, alpha)
  local t = state.tint
  love.graphics.setColor(
    token[1] * t[1],
    token[2] * t[2],
    token[3] * t[3],
    (alpha or 1) * state.dim
  )
end

-- Like set_interior_color but with an EXTRA brightness multiplier baked in (for the
-- mitochondria inner glow, which keys off snapshot scalars directly).
local function set_interior_color_x(state, token, alpha, bright)
  local t = state.tint
  bright = bright or 1
  love.graphics.setColor(
    token[1] * t[1] * bright,
    token[2] * t[2] * bright,
    token[3] * t[3] * bright,
    (alpha or 1) * state.dim
  )
end

-- The big membrane: a filled soft body disk under a brighter rim that gently wobbles.
-- The rim glow eases with `output` so a lively cell glows; the body is a dim fill that
-- reads as cytoplasm framing the instanced swarm.
local function draw_membrane(state, cx, cy, r, output)
  local t = state.time
  local segs = 64
  set_interior_color(state, colors.surface, CYTOPLASM_ALPHA)
  love.graphics.circle("fill", cx, cy, r)
  set_interior_color(state, colors.primary, 0.06)
  love.graphics.circle("fill", cx, cy, r * 0.96)

  local pts = {}
  for i = 0, segs - 1 do
    local a = (i / segs) * 2 * math.pi
    local w = math.sin(a * 3 + t * MEMBRANE_WOBBLE_FREQ * 2 * math.pi)
      + 0.6 * math.sin(a * 5 - t * MEMBRANE_WOBBLE_FREQ * math.pi)
    local rr = r * (1 + MEMBRANE_WOBBLE * w)
    pts[#pts + 1] = cx + math.cos(a) * rr
    pts[#pts + 1] = cy + math.sin(a) * rr
  end
  local rim_alpha = 0.45 + 0.4 * clamp01((output or 0) / 50)
  love.graphics.setLineWidth(RIM_WIDTH)
  set_interior_color(state, colors.primary, rim_alpha)
  love.graphics.polygon("line", pts)
  love.graphics.setLineWidth(1)
end

-- The nucleus: the centre hub. A filled compartment with a nucleolus dot and speckled
-- chromatin whose density fills in with the nucleus stage's level.
local function draw_nucleus(state, cx, cy, r, level)
  local nr = r * NUCLEUS_R_FRAC
  set_interior_color(state, colors.primary_dark, 0.55)
  love.graphics.circle("fill", cx, cy, nr)
  love.graphics.setLineWidth(2)
  set_interior_color(state, colors.primary, 0.6)
  love.graphics.circle("line", cx, cy, nr)
  love.graphics.setLineWidth(1)
  -- Nucleolus dot (a denser inner body, slightly off-centre).
  set_interior_color(state, colors.primary, 0.45)
  love.graphics.circle("fill", cx + nr * 0.18, cy - nr * 0.12, nr * 0.22)
  -- Chromatin speckles: a logarithmic sample of the level, scattered inside.
  local n = sample_count(level, 4, 7, 40)
  for i = 1, n do
    local a = hash01(i * 1.7) * 2 * math.pi
    local rad = math.sqrt(hash01(i * 2.3)) * nr * 0.82
    local px = cx + math.cos(a) * rad
    local py = cy + math.sin(a) * rad
    set_interior_color(state, colors.primary, 0.5)
    love.graphics.circle("fill", px, py, 1.4)
  end
end

-- Draw a Catmull-Rom-ish smooth ribbon through a short list of control points using
-- love's built-in spline. `pts` is a flat {x,y,...} list; we feed it as a quadratic
-- bezier-style evenly. Cheap: love.math.newBezierCurve renders the smooth poly for us.
-- Used by the ER ribbons (and reusable for any curved organelle stroke).
local function draw_spline(pts, samples)
  if #pts < 6 then
    -- Fewer than 3 control points: just draw the line as-is.
    if #pts >= 4 then
      love.graphics.line(pts)
    end
    return
  end
  local curve = love.math.newBezierCurve(pts)
  local poly = curve:render(samples or 3)
  love.graphics.line(poly)
end

-- Rough ER: smooth concentric membrane arcs hugging the nucleus on the ER's side, studded
-- with ribosome dots. Arc COUNT/sweep scales with the ER level; dot DENSITY with the
-- ribosomes level. Reworked from wavy, rippled bezier ribbons (which undulated out of phase
-- and crossed each other into a tangle) into clean, evenly-nested CONSTANT-RADIUS arcs, so the
-- ER reads as tidy stacked sheets wrapping the nucleus instead of a knot of overlapping curls.
local function draw_er(state, cx, cy, r, er_level, ribo_level)
  local ribbons = 1 + sample_count(er_level, 0, 1.6, 4) -- 1..5 arcs
  -- The ER hugs the nucleus on its side; centre the arcs on the ER zone direction.
  local z = ZONE.er
  local base_a = z.angle
  -- Sweep grows a touch with level so a deeper ER wraps further around the nucleus.
  local sweep = math.rad(70 + 18 * math.min(er_level, 6))
  local arc_steps = 24 -- samples per arc: enough that the constant-radius curve reads smooth
  love.graphics.setLineWidth(1.5)
  for b = 1, ribbons do
    -- Each arc is a clean constant-radius band, nested outward across the ER band; the small
    -- step keeps even a max-level ER clear of the mito ring. NO ripple -> the arcs never cross.
    local rib_r = r * (ER_RIBBON_INNER + ER_RIBBON_STEP * (b - 1))
    local pts = {}
    for s = 0, arc_steps do
      local a = base_a - sweep * 0.5 + sweep * (s / arc_steps)
      pts[#pts + 1] = cx + math.cos(a) * rib_r
      pts[#pts + 1] = cy + math.sin(a) * rib_r
    end
    set_interior_color(state, colors.primary_dark, 0.5)
    love.graphics.line(pts)

    -- Ribosome dots studding this arc; density scales with the ribosomes level.
    local dots = sample_count(ribo_level, 2, 3.5, 14)
    for d = 1, dots do
      local a = base_a - sweep * 0.5 + sweep * ((d - 0.5) / dots)
      local px = cx + math.cos(a) * rib_r
      local py = cy + math.sin(a) * rib_r
      set_interior_color(state, colors.primary, 0.7)
      love.graphics.circle("fill", px, py, 1.2)
    end
  end
  love.graphics.setLineWidth(1)
end

-- Golgi: a short cupped stack of plump CRESCENT SACS at the Golgi zone, widest at the cis
-- (inner) face and only gently tapering to the trans (outer) face, with round vesicles budding
-- off the trans face. Stack HEIGHT scales with the Golgi level. Each sac is a bowed body stroke
-- with rounded end caps (so it reads as a solid flattened tube, not an open arc) under a thinner
-- brighter rim. The gentle taper keeps the sacs near-parallel -- a nested stack, never a cone.
local function draw_golgi(state, cx, cy, r, golgi_level)
  local gx, gy = zone_pos("golgi", cx, cy, r)
  local stack = 2 + sample_count(golgi_level, 0, 1.3, 4) -- 2..6 cisternae
  -- Orient the stack so the sacs face outward from the cell centre (the trans face points to
  -- the rim). The "outward" direction is from the cell centre to the Golgi zone.
  local out_a = ZONE.golgi.angle
  local nx, ny = math.cos(out_a), math.sin(out_a) -- outward normal (cis -> trans)
  local tx, ty = -ny, nx -- tangent (the sac spans this axis)
  local bow = r * GOLGI_BOW
  local gap = r * GOLGI_GAP
  local cap_r = GOLGI_BODY_WIDTH * 0.5 -- end-cap circle radius rounds the sac's butt ends
  for c = 1, stack do
    -- Sac c, indexed cis (c=1, innermost/widest) -> trans (c=stack, outermost). Width tapers
    -- only GENTLY across the stack so the sacs stay near-parallel (a nested cup, not a cone).
    local taper = (stack > 1) and ((c - 1) / (stack - 1)) or 0
    local width = r * lerp(GOLGI_CIS_WIDTH, GOLGI_TRANS_WIDTH, taper)
    local push = (c - 1) * gap
    local ox = gx + nx * push
    local oy = gy + ny * push
    -- Shallow crescent: 3 control points, the midpoint bowed outward along the normal.
    local lx, ly = ox - tx * width, oy - ty * width -- left tip
    local rx, ry = ox + tx * width, oy + ty * width -- right tip
    local pts = { lx, ly, ox + nx * bow, oy + ny * bow, rx, ry }
    -- Body under-stroke + rounded caps: a soft warm membrane giving the sac real thickness.
    set_interior_color(state, colors.tertiary, GOLGI_BODY_ALPHA)
    love.graphics.setLineWidth(GOLGI_BODY_WIDTH)
    draw_spline(pts, 6)
    love.graphics.circle("fill", lx, ly, cap_r)
    love.graphics.circle("fill", rx, ry, cap_r)
    -- Edge top-stroke: a thinner, brighter rim that crisps the sac against its neighbours.
    set_interior_color_x(state, colors.tertiary, GOLGI_EDGE_ALPHA, GOLGI_EDGE_BRIGHT)
    love.graphics.setLineWidth(GOLGI_EDGE_WIDTH)
    draw_spline(pts, 6)
  end
  -- Budding Golgi vesicles: round warm sacs pinching off the trans (outer) face, scattered
  -- along the tangent across the trans-face width. Warm-tinted (same family as the cisternae)
  -- so they read as Golgi-derived. Count scales with the Golgi level.
  local buds = sample_count(golgi_level, 1, 1.2, 5)
  local trans_w = r * GOLGI_TRANS_WIDTH
  local face_x = gx + nx * ((stack - 1) * gap + bow + r * GOLGI_BUD_OFFSET)
  local face_y = gy + ny * ((stack - 1) * gap + bow + r * GOLGI_BUD_OFFSET)
  for d = 1, buds do
    local jx = (hash01(d * 3.1) - 0.5) * 2 * trans_w
    local px = face_x + tx * jx + nx * hash01(d * 5.7) * r * GOLGI_BUD_OFFSET
    local py = face_y + ty * jx + ny * hash01(d * 5.7) * r * GOLGI_BUD_OFFSET
    set_interior_color_x(state, colors.tertiary, 0.85, GOLGI_EDGE_BRIGHT)
    love.graphics.circle("fill", px, py, GOLGI_BUD_R)
  end
  love.graphics.setLineWidth(1)
end

-- The 0..1 RETICULUM fusion factor for a given mitochondria count (pure -- no love.*).
-- A log sample of `mito` mapped across [MITO_FUSE_START, MITO_FUSE_FULL] plant counts:
-- 0 below START (the discrete-bean opening look), ramping to 1 at/above FULL (a fully
-- bridged fused network). Log-scaled so the network keeps thickening from a few dozen
-- plants into the hundreds. This is what makes the picture keep MOVING with state.mito
-- past the old 6-bean clamp -- shape only, the economy never reads it.
local function mito_reticulum_factor(mito)
  mito = mito or 0
  if mito <= MITO_FUSE_START then
    return 0
  end
  local lo = math.log(1 + MITO_FUSE_START)
  local hi = math.log(1 + MITO_FUSE_FULL)
  local v = (math.log(1 + mito) - lo) / (hi - lo)
  return clamp01(v)
end

-- How many merged mitochondrial BODIES to draw around the ring for a count + fusion
-- factor: from MITO_BODY_MIN at the discrete end to MITO_BODY_MAX in a dense reticulum
-- (pure). Bounded so the per-frame primitive cost never grows with the raw count -- a
-- 500-plant cell draws the same body budget as a 220-plant one, just at full fusion.
local function mito_body_count(reticulum)
  return MITO_BODY_MIN + math.floor((MITO_BODY_MAX - MITO_BODY_MIN) * reticulum + 0.5)
end

-- The ring position + base orientation of body index `m` of `count` (pure). At the discrete
-- end (count fits the fixed MITO_ANGLES anchors) bodies sit on those hand-placed angles, which
-- tuck into the gaps between the organelle zones. Once the count climbs past that (the fused
-- reticulum) ALL bodies are placed EVENLY around the ring from MITO_RING_PHASE, so no two ever
-- land on the same spot -- the old scheme mixed the fixed anchors (m<=6) with a different
-- even-fill formula (m>6) and the two overlapped, stacking beans on top of each other.
-- Orientation is a deterministic per-index jitter off the tangent (no reshuffle within a count).
local function mito_body_pose(m, count, cx, cy, r)
  local ring_r = r * MITO_RING_FRAC
  local a
  if count <= #MITO_ANGLES then
    a = MITO_ANGLES[m]
  else
    a = MITO_RING_PHASE + (m - 1) * (2 * math.pi / count)
  end
  local mx = cx + math.cos(a) * ring_r
  local my = cy + math.sin(a) * ring_r
  local rot = a + math.pi * 0.5 + (hash01(m * 9.1) - 0.5) * 0.6
  return mx, my, rot, a
end

-- Draw ONE mitochondrial body: a fat rounded CAPSULE bean -- two semicircular end caps joined
-- by straight sides (rounded ends, never the sharp lens tips of a plain ellipse) -- with a
-- power-keyed inner glow and `cristae` internal fold lines. At reticulum 0 this is a plump
-- discrete bean; as fusion rises the body stretches (MITO_ELONGATE) and narrows into a tubular
-- segment of the network and the cristae densify. The capsule is convex, so it fills as one
-- polygon. love.* draw-time only.
local function draw_mito_body(state, mx, my, rot, bean_len, bean_w, cristae, power_bright)
  local cr, sr = math.cos(rot), math.sin(rot)
  -- `straight` is the half-length of the parallel section; the two caps are semicircles of
  -- radius bean_w centred at +/- straight, so total half-length stays bean_len.
  local straight = bean_len - bean_w
  if straight < 0 then
    straight = 0
  end
  local pts = {}
  -- Right cap: sweep the semicircle from the bottom round to the top.
  for i = 0, MITO_CAP_SEGS do
    local th = -math.pi * 0.5 + (i / MITO_CAP_SEGS) * math.pi
    local ex = straight + math.cos(th) * bean_w
    local ey = math.sin(th) * bean_w
    pts[#pts + 1] = mx + ex * cr - ey * sr
    pts[#pts + 1] = my + ex * sr + ey * cr
  end
  -- Left cap: sweep the semicircle from the top round to the bottom (closing the capsule).
  for i = 0, MITO_CAP_SEGS do
    local th = math.pi * 0.5 + (i / MITO_CAP_SEGS) * math.pi
    local ex = -straight + math.cos(th) * bean_w
    local ey = math.sin(th) * bean_w
    pts[#pts + 1] = mx + ex * cr - ey * sr
    pts[#pts + 1] = my + ex * sr + ey * cr
  end
  -- Outer membrane fill + rim.
  set_interior_color(state, colors.tertiary, 0.5)
  love.graphics.polygon("fill", pts)
  love.graphics.setLineWidth(1.5)
  set_interior_color_x(state, colors.secondary, 0.7, power_bright)
  love.graphics.polygon("line", pts)
  love.graphics.setLineWidth(1)
  -- Inner glow: a brighter inner ellipse keyed to power (dims first on brownout).
  set_interior_color_x(state, colors.secondary_bright, 0.35, power_bright)
  local gpts = {}
  local glow_segs = 20
  for i = 0, glow_segs - 1 do
    local th = (i / glow_segs) * 2 * math.pi
    local ex = math.cos(th) * bean_len * 0.55
    local ey = math.sin(th) * bean_w * 0.6
    gpts[#gpts + 1] = mx + ex * cr - ey * sr
    gpts[#gpts + 1] = my + ex * sr + ey * cr
  end
  love.graphics.polygon("fill", gpts)
  -- Cristae: internal fold lines across the short axis (denser as the body fuses), kept inside
  -- the fattened bean by MITO_CRISTAE_SPAN/REACH.
  love.graphics.setLineWidth(1)
  set_interior_color_x(state, colors.secondary_bright, 0.6, power_bright)
  for k = 1, cristae do
    local along = (k / (cristae + 1) - 0.5) * 2 * bean_len * MITO_CRISTAE_SPAN
    local reach = bean_w * MITO_CRISTAE_REACH
    local x0 = mx + (cr * along) - (sr * reach)
    local y0 = my + (sr * along) + (cr * reach)
    local x1 = mx + (cr * along) + (sr * reach)
    local y1 = my + (sr * along) - (cr * reach)
    love.graphics.line(x0, y0, x1, y1)
  end
end

-- Mitochondria: at LOW counts, discrete STATIONARY beans at the fixed MITO_ANGLES (the
-- opening look); as the count climbs they FUSE into a branched RETICULUM -- bodies
-- elongate, tubules bridge adjacent ring anchors, and cristae densify -- so the picture
-- keeps moving with state.mito into the hundreds instead of clamping at 6 (Pillar 4).
-- A more-powered cell shows a brighter inner glow; under brownout they gutter FIRST (the
-- caller passes a `power_bright` already lowered by the brownout state). Render-only: the
-- economy (power = POWER_PER_MITO*mito) is untouched -- this only changes how it's shown.
local function draw_mitochondria(state, cx, cy, r, mito, power_bright, primed)
  local reticulum = mito_reticulum_factor(mito)
  local count = mito_body_count(reticulum)
  -- A fused body elongates (MITO_ELONGATE) and narrows (MITO_FUSE_NARROW) so the network reads
  -- as tubular rather than a ring of fat blobs; at the discrete end it's a plump bean capsule.
  local bean_len = r * MITO_BEAN_LEN * (1 + (MITO_ELONGATE - 1) * reticulum)
  local bean_w = r * MITO_BEAN_W * (1 - MITO_FUSE_NARROW * reticulum)

  -- TUBULES: as fusion rises, draw connecting tubes between adjacent bodies so the ring
  -- reads as one branched network, not separate beans. Faded in by the fusion factor (none
  -- at the discrete end), and only between bodies close enough on the ring to merge.
  if reticulum > 0 and count >= 2 then
    love.graphics.setLineWidth(math.max(1, r * MITO_TUBULE_WIDTH * reticulum))
    set_interior_color_x(state, colors.secondary, 0.30 * reticulum, power_bright)
    local link_max = (r * MITO_RING_FRAC) * (2 * math.pi / count) * 1.6 -- nearest-neighbour gap + slack
    for m = 1, count do
      local ax, ay = mito_body_pose(m, count, cx, cy, r)
      local nxt = (m % count) + 1
      local bx, by = mito_body_pose(nxt, count, cx, cy, r)
      local dx, dy = bx - ax, by - ay
      if math.sqrt(dx * dx + dy * dy) <= link_max then
        love.graphics.line(ax, ay, bx, by)
      end
    end
    love.graphics.setLineWidth(1)
  end

  -- BODIES: each drawn at its stable pose. Cristae densify with fusion (MITO_CRISTAE_MIN
  -- ..MAX), plus a small per-body variance so the network doesn't read mechanically.
  for m = 1, count do
    local mx, my, rot = mito_body_pose(m, count, cx, cy, r)
    local cristae = MITO_CRISTAE_MIN
      + math.floor((MITO_CRISTAE_MAX - MITO_CRISTAE_MIN) * reticulum + 0.5)
      + (m % 2)
    draw_mito_body(state, mx, my, rot, bean_len, bean_w, cristae, power_bright)
  end

  -- MANUAL-TAP CUE: a soft pulsing green halo around the primed power plant (the orchestrator
  -- picked it via tap_seed; see draw_organelles). Full brightness, NOT brownout-dimmed -- the
  -- feed cue must read when the cell is starved. `primed` is a 1-based body index, or nil when
  -- no tap is pending. The halo breathes in size + alpha so the chosen mitochondrion pulses.
  -- We also stamp the bean's screen position + a forgiving hit radius into state.tap_target so
  -- the orchestrator can route a click ONLY to this glowing plant (a one-frame lag is harmless).
  state.tap_target.active = false
  if primed and primed >= 1 and primed <= count then
    local mx, my = mito_body_pose(primed, count, cx, cy, r)
    local pulse = 0.5 + 0.5 * math.sin(state.time * MITO_TAP_PULSE_FREQ) -- 0..1
    local halo_r = bean_len * (MITO_TAP_HALO_SCALE + MITO_TAP_PULSE_AMP * pulse)
    local col = colors.secondary_bright
    love.graphics.setLineWidth(MITO_TAP_WIDTH)
    love.graphics.setColor(col[1], col[2], col[3], MITO_TAP_ALPHA * (0.55 + 0.45 * pulse))
    love.graphics.circle("line", mx, my, halo_r)
    love.graphics.setLineWidth(1)
    love.graphics.setColor(1, 1, 1, 1)
    state.tap_target.x = mx
    state.tap_target.y = my
    state.tap_target.r = bean_len * MITO_TAP_HIT_SCALE
    state.tap_target.active = true
  end
end

-- Cytoskeleton (the TRANSPORT stage): the cell's microtubule scaffold -- an evenly-spaced
-- radial ASTER of faint filament tracks fanning OUTWARD from a hub beside the nucleus toward
-- the cell periphery, the rails the vesicle swarm rides. COUNT scales with the transport level.
-- Reworked from the old per-leg parallel BUNDLES, which bunched into an overlapping tangle near
-- the centre with no legible construction; even angular spacing means spokes never overlap, and
-- a slight tangential curl keeps the aster organic (a soft pinwheel, not a hard star).
-- The radial aster is anchored at the cell centre and is independent of which zones are
-- unlocked (the old per-leg version walked the pipeline rows; this one doesn't need them).
local function draw_cytoskeleton(state, cx, cy, r, transport_level)
  if transport_level <= 0 then
    return
  end
  local spokes = sample_count(transport_level, CYTO_SPOKES_BASE, CYTO_SPOKES_SCALE, CYTO_SPOKES_MAX)
  local inner = r * CYTO_INNER_FRAC
  local outer = r * CYTO_OUTER_FRAC
  local mid_r = (inner + outer) * 0.5
  local curl = r * CYTO_CURL -- tangential bow at the spoke midpoint (the soft pinwheel)
  love.graphics.setLineWidth(1)
  for k = 1, spokes do
    local a = CYTO_PHASE + (k - 1) * (2 * math.pi / spokes)
    local ca, sa = math.cos(a), math.sin(a)
    local tx, ty = -sa, ca -- tangent (curl direction)
    -- Inner -> curled midpoint -> outer, fed to the spline as bezier control points so the
    -- filament bows gently toward the midpoint rather than running dead straight.
    local pts = {
      cx + ca * inner,
      cy + sa * inner,
      cx + ca * mid_r + tx * curl,
      cy + sa * mid_r + ty * curl,
      cx + ca * outer,
      cy + sa * outer,
    }
    set_interior_color(state, colors.border_inner_highlight, CYTO_ALPHA)
    draw_spline(pts, 6)
  end
  love.graphics.setLineWidth(1)
end

-- The full organelle pass: drawn BETWEEN the membrane and the swarm, for UNLOCKED
-- stages only. Order: cytoskeleton (under) -> ER -> Golgi -> mitochondria.
-- `power_bright` (0..1-ish) keys the mitochondria glow and dims them first on brownout.
local function draw_organelles(state, snapshot, cx, cy, r, power_bright)
  local stages = snapshot.stages or {}

  local transport = find_stage(stages, "transport")
  if transport and transport.unlocked then
    draw_cytoskeleton(state, cx, cy, r, transport.level or 0)
  end

  local er = find_stage(stages, "er")
  if er and er.unlocked then
    local ribo = find_stage(stages, "ribosomes")
    draw_er(state, cx, cy, r, er.level or 0, ribo and (ribo.level or 0) or 0)
  end

  local golgi = find_stage(stages, "golgi")
  if golgi and golgi.unlocked then
    draw_golgi(state, cx, cy, r, golgi.level or 0)
  end

  -- Mitochondria always drawn if there is any power machinery (mito >= 1). When a manual tap
  -- is pending (snapshot.tap_ready) one bean is PRIMED with a pulsing "feed me" halo; the
  -- orchestrator's stable tap_seed (0..1) picks WHICH, mapped to a body index here against the
  -- same count the draw uses, so the cue always lands on a real bean.
  local primed
  if snapshot.tap_ready then
    local count = mito_body_count(mito_reticulum_factor(snapshot.mito or 0))
    primed = 1 + math.floor(clamp01(snapshot.tap_seed or 0) * count)
    if primed > count then
      primed = count
    end
  end
  draw_mitochondria(state, cx, cy, r, snapshot.mito or 0, power_bright, primed)
  -- No bottleneck spotlight: the player reads the choke from the swarm's own flow
  -- (congestion clumps, the bottleneck lane constricts, downstream lanes thin out),
  -- never from a halo pointing at "feed this one".
end

-- Build the swarm's endpoint + segment arrays from the snapshot, in place on the
-- view's scratch tables, and return the live endpoint/segment counts. The bridge from
-- the snapshot CONTRACT to the GPU uniforms:
--   * endpoints = one per UNLOCKED stage at its STABLE anatomical ZONE position, in
--     pipeline order, then FIXED mitochondria emitters.
--   * segments  = one per gap between consecutive endpoints, carrying the flow
--     readouts { over_build, choke, vacancy, density } the shader reads.
-- All cheap: a few dozen table writes, no per-vesicle work.
local function build_routes(state, snapshot, cx, cy, r)
  local stages = snapshot.stages or {}
  local xs, ys, segs = state.endpoints_x, state.endpoints_y, state.segments

  -- Bottleneck pipeline INDEX so segments downstream of it read as vacant.
  local bn_index
  if snapshot.bottleneck_id and STAGE_INDEX[snapshot.bottleneck_id] then
    bn_index = STAGE_INDEX[snapshot.bottleneck_id]
  else
    for i = 1, #stages do
      if stages[i].is_bottleneck then
        bn_index = STAGE_INDEX[stages[i].id]
      end
    end
  end

  -- UNLOCKED stages in fixed pipeline order, each at its STABLE zone position. Keep the
  -- per-stage rows alongside so the segment between endpoint k and k+1 reads the
  -- DOWNSTREAM stage's flow state (cargo entering a stage feels that stage's jam).
  local ep_count = 0
  local ordered = {}
  for order = 1, #STAGE_ORDER do
    local id = STAGE_ORDER[order]
    local row = find_stage(stages, id)
    if row and row.unlocked then
      ep_count = ep_count + 1
      xs[ep_count], ys[ep_count] = zone_pos(id, cx, cy, r)
      ordered[ep_count] = row
    end
  end

  -- Mitochondria emitters at the SAME positions the beans are DRAWN at: one emitter per
  -- drawn body, mirroring draw_mitochondria's count (mito_body_count(reticulum)) and pose
  -- (mito_body_pose). This lands the vesicles ON the visible power plants instead of on a
  -- separate angle-ring that drifted off the beans once the reticulum fused. The body
  -- count is bounded (<= MITO_BODY_MAX), so the endpoint block stays under MAX_ENDPOINTS.
  local mito_bodies = mito_body_count(mito_reticulum_factor(snapshot.mito or 0))
  for m = 1, mito_bodies do
    ep_count = ep_count + 1
    xs[ep_count], ys[ep_count] = mito_body_pose(m, mito_bodies, cx, cy, r)
    ordered[ep_count] = nil
  end

  -- CHOKE SEVERITY: how hard the bottleneck actually pins the line, derived from the per-lane
  -- over-build already in the snapshot. Since each lane's congestion is its capacity above the
  -- line's throughput (over_i = throughput * congestion_i), the total excess is throughput * the
  -- congestion sum, so flow_balance = 1/(1 + sum) and the severity = sum/(1 + sum) = 1 - flow
  -- balance. It is 0 for a balanced cell (no false choke on the nominal minimum lane) and rises as
  -- over-building spreads. The view drives the choke pinch/crowd by THIS, not a binary flag.
  local sum_congestion = 0
  for i = 1, #stages do
    local stage = stages[i]
    if stage.unlocked then
      sum_congestion = sum_congestion + clamp01(stage.congestion or 0)
    end
  end
  local choke_severity = sum_congestion / (1 + sum_congestion)

  -- Segments: one per gap between consecutive endpoints. Readout from the DOWNSTREAM
  -- endpoint's stage; mito emitter segments are calm neutral lanes.
  local seg_count = math.max(ep_count - 1, 0)
  for k = 1, seg_count do
    local row = ordered[k + 1]
    local seg = segs[k]
    if not seg then
      seg = { 0, 0, 0, 0 }
      segs[k] = seg
    end
    if row then
      local congestion = clamp01(row.congestion or 0)
      local choke = row.is_bottleneck and choke_severity or 0
      local vac = 0
      if bn_index then
        local d = (STAGE_INDEX[row.id] or k) - bn_index
        if d > 0 then
          vac = clamp01(d / (#STAGE_ORDER - bn_index + 0.001))
        end
      end
      -- A lane that is BOTH downstream of the choke (vacant) and over-built (congested) would read
      -- as starved and over-stuffed at once. Over-build is the actionable "you over-invested here"
      -- signal, so let it win: fade the sparse/starved look in proportion to the lane's own over-
      -- build, leaving vacancy for correctly-sized downstream lanes.
      vac = vac * (1 - congestion)
      local cap = row.cap or 0
      local fill = cap > 0 and clamp01((row.level or 0) / cap) or 0
      seg[1], seg[2], seg[3], seg[4] = congestion, choke, vac, 0.4 + 0.6 * fill
    else
      seg[1], seg[2], seg[3], seg[4] = 0, 0, 0, 0.6
    end
  end

  return ep_count, seg_count
end

-- Render the cell interior to the screen from a read-only snapshot (the orchestrator
-- builds it fresh each frame; see the EXACT shape in this module's header). Draws
-- nothing of the panel/HUD. Graphics state is reset at the end. Order:
--   membrane (CPU) -> nucleus (CPU) -> organelles (CPU, incl. the mito tap cue) -> GPU swarm -> fx.
function view.draw(state, snapshot)
  snapshot = snapshot or {}
  local win_w, win_h = love.graphics.getDimensions()
  local cx, cy = win_w * 0.5, win_h * 0.5
  local r = math.min(win_w, win_h) * CELL_FILL

  -- Stash the brownout + fuel targets for update()'s easing (continuous, not a flag
  -- flip): a brownout eases the swarm toward dim + slow; fuel sets the tint.
  if snapshot.brownout then
    state.dim_target = BROWNOUT_DIM
    state.drift_target = BROWNOUT_SLOW
  else
    state.dim_target = 1
    state.drift_target = 1
  end
  state.tint_target = fuel_tint_target(snapshot.fuel_factor)

  -- Mitochondria gutter FIRST under brownout: a power-brightness scalar that drops
  -- harder/faster than the global dim, so the beans dim before the rest of the cell.
  -- (state.dim is the eased global brownout dim; square it for a steeper mito fade.)
  local power_bright = state.dim * state.dim

  love.graphics.push()

  -- 1) Membrane frames the interior (cytoplasm fill + wobbling bright rim).
  draw_membrane(state, cx, cy, r, snapshot.output)

  -- 2) Nucleus compartment (only once its stage is unlocked).
  local stages = snapshot.stages or {}
  local nuc = find_stage(stages, "nucleus")
  if nuc and nuc.unlocked then
    draw_nucleus(state, cx, cy, r, nuc.level)
  end

  -- 3) Organelle pass -- between the membrane/nucleus and the swarm.
  draw_organelles(state, snapshot, cx, cy, r, power_bright)

  -- 4) The GPU-INSTANCED vesicle swarm. Build the endpoint + segment uniforms from the
  -- snapshot, set the live count, map the global flow scalars, draw the live prefix.
  local ep_count, seg_count = build_routes(state, snapshot, cx, cy, r)

  -- LIVE COUNT: START as a handful and grow with leveling. throughput drives the
  -- immediate "leveling adds vesicles" feel; built is the slow bulk fill. Hard-capped.
  local throughput = snapshot.throughput or 0
  if throughput < 0 then
    throughput = 0
  end
  local built = snapshot.built or 0
  if built < 0 then
    built = 0
  end
  local count = COUNT_BASE + K_FLOW * math.log(1 + throughput) + K_BULK * math.sqrt(built)
  if count > MAX_LIVE_VESICLES then
    count = MAX_LIVE_VESICLES
  end
  interior_swarm.set_count(count)

  -- EFFICIENCY -> global liveliness (the dominant driver). Optimal = fast + bright;
  -- low eff = slow + dim. A small output term layers on top. The eased brownout state
  -- (state.drift) then multiplies into the motion speed so easing in/out of brownout
  -- produces a smooth deceleration/acceleration with NO teleport or runaway phase jump.
  local eff = snapshot.efficiency
  if eff == nil then
    eff = 1
  end
  eff = clamp01(eff)
  local out_bonus = saturate(snapshot.output, OUTPUT_REF)
  local base_speed = lerp(SPEED_SLOW, SPEED_FAST, eff) + OUTPUT_SPEED_BONUS * out_bonus
  local bright = lerp(BRIGHT_DIM, BRIGHT_BRIGHT, eff) + OUTPUT_BRIGHT_BONUS * out_bonus

  -- FLOW SPEED: efficiency-derived base speed MULTIPLIED BY the eased brownout factor
  -- (state.drift, 1=full speed, BROWNOUT_SLOW at full brownout). By driving the
  -- integrated flow_phase clock at this combined rate, brownout easing changes only
  -- FUTURE accumulation -- vesicles never teleport or race when the factor changes.
  local flow_speed = base_speed * state.drift
  interior_swarm.set_flow_speed(flow_speed)

  interior_swarm.draw({
    endpoints_x = state.endpoints_x,
    endpoints_y = state.endpoints_y,
    endpoint_count = ep_count,
    segments = state.segments,
    segment_count = seg_count,
    -- brightness only: motion rate is owned by set_flow_speed above (speed/slow are
    -- ignored by the swarm's phase-integrated shader; do not pass them).
    brightness = bright * state.dim, -- efficiency/output brightness * eased brownout dim
    tint = state.tint, -- eased fuel_factor tint
    cargo_palette = CARGO_PALETTE, -- typed-cargo colours (Agent C honors / defaults)
  })

  -- 5) World-space fx ride above the interior. (The manual-tap "feed me" cue is no longer a
  -- centre ring -- it's a pulsing halo on a primed mitochondrion, drawn in the organelle pass.)
  fx.draw_world(state.fx)

  love.graphics.pop()

  fx.draw_overlay(state.fx)

  -- 7) STRESS VIGNETTE (optional tell for impending lysis). snapshot.stress is 0..1;
  -- defaults to 0 if absent (guard: new field from Agent ECON, not yet on all builds).
  -- A faint creeping warm-red glow at the cell rim that intensifies as stress rises.
  -- Implementation: a wide rim stroke at the cell edge, alpha proportional to stress.
  -- Cheap: one thick-line circle (no per-pixel work). Drawn in screen space (after pop)
  -- so it doesn't inherit any pushed transform.
  local stress = clamp01(snapshot.stress or 0)
  if stress > 0.02 then
    local vx = win_w * 0.5
    local vy = win_h * 0.5
    local vr = math.min(win_w, win_h) * CELL_FILL
    local vc = colors.quaternary
    -- Rim glow: a thick circle stroke whose width grows with stress (up to ~12% of r),
    -- so at full stress the interior reads as visibly "under attack at the membrane".
    local rim_width = vr * (0.04 + 0.08 * stress)
    love.graphics.setLineWidth(rim_width)
    love.graphics.setColor(vc[1], vc[2], vc[3], 0.45 * stress)
    love.graphics.circle("line", vx, vy, vr - rim_width * 0.5)
    love.graphics.setLineWidth(1)
  end

  love.graphics.setLineWidth(1)
  love.graphics.setColor(1, 1, 1, 1)
end

return view
