-- Endosymbiosis transition: the cinematic that fires when endosymbiosis procs --
-- the climactic beat that ENDS the cell layer (phase 1). A single cell's absorbed
-- partner is the culmination of the run; the level then resets into a fresh
-- lineage. (The next scale isn't built yet -- this is phase 1's ending, not a
-- bridge into a phase 2.) It is a sequenced TIMELINE, not a gameplay system: a
-- small state machine over four phases the orchestrator suspends the live sim
-- through --
--
--   freeze  -- the world holds its breath on the moment of the proc;
--   focus   -- the camera glides + pushes in onto the cell that triggered, the
--              title fading up over it;
--   charge  -- a bright core gathers AT that cell, a ring collapsing inward, the
--              world dimming around it as the build-up rises;
--   blast   -- the core detonates into a white-out that wipes the screen; at the
--              white peak the level RESETS, then the white fades to reveal the
--              fresh founder.
--
-- Like fx.lua and view.lua it touches love.* ONLY inside draw, so the whole
-- timeline (phase advance, the single reset fire at the white peak, the active
-- flag) is headless-testable. Side effects are routed OUT through callbacks the
-- orchestrator binds (on_focus -> view.focus, on_shake -> a view shake, on_reset
-- -> wipe + reload), so this module knows nothing of the view or the save -- it
-- only owns the clock and the overlay. Colors come from the global tokens.
local colors = require("lib.engine.ui.colors")
local fonts = require("lib.engine.ui.fonts")

local transition = {}

-- Phase durations (seconds). The whole cinematic runs FREEZE+FOCUS+CHARGE+BLAST.
local FREEZE = 0.5 -- the held beat: everything stops on the proc
local FOCUS = 1.4 -- camera glides + zooms onto the triggering cell; title fades in
local CHARGE = 1.8 -- the build-up: core gathers, ring collapses, world dims
local BLAST = 1.1 -- the white-out wipe; the level resets at its peak
local RESET_FRAC = 0.46 -- fraction of BLAST at which the white peaks and reset fires

local ZOOM_MULT = 3.4 -- how far past the settled fit-zoom the focus pushes in
-- The "dive" style (phase 1) plunges INTO the winning cell -- the zoom itself is the
-- bridge into phase 2, not a white-out cut. Its SECOND HALF (charge + the pre-reset
-- plunge) runs LONGER than the shared white-style timeline so the descent is unhurried,
-- and the zoom keeps DEEPENING continuously the whole way (re-aimed every update in
-- transition.update, never lerped to a fixed target that then sits still). focus leaves
-- the camera at ZOOM_MULT; from there it climbs to DIVE_ZOOM_END right at the hand-off.
-- (The "white" style -- phase 2's fork -- ignores all of this: its on_focus has no
-- camera and it keeps the short shared durations.)
local DIVE_CHARGE = 3.0 -- the build-up + descent (was 1.8): slower, the dish dissolving
local DIVE_BLAST = 2.6 -- the plunge into the cell (was 1.1): the long final push-in
local DIVE_ZOOM_START = ZOOM_MULT -- where the focus push-in left the camera
local DIVE_ZOOM_END = 80 -- the deep target the camera is still climbing toward at handoff

-- The words stamped over the cell that evolved. The kicker names the trigger,
-- the title marks the run's culmination, the line underneath gives it weight.
transition.TITLE = "A NEW LINEAGE"
transition.KICKER = "endosymbiosis"
transition.SUBTITLE = "the soup begins again"

-- Phase table in order: { name, duration }. Ordered so advance() can walk it.
local PHASES = {
  { "freeze", FREEZE },
  { "focus", FOCUS },
  { "charge", CHARGE },
  { "blast", BLAST },
}

local function clamp01(v)
  if v < 0 then
    return 0
  elseif v > 1 then
    return 1
  end
  return v
end

local function smoothstep(k)
  k = clamp01(k)
  return k * k * (3 - 2 * k)
end

-- Per-style phase durations. The "dive" (phase 1) stretches its second half so the
-- descent into phase 2 is slow; "white" (phase 2's fork) keeps the short shared
-- timeline. dur_for is the SINGLE source the timeline walk, the world fade, the
-- continuous zoom, and the overlay all read, so the longer dive stays consistent.
local DIVE_DUR = { freeze = FREEZE, focus = FOCUS, charge = DIVE_CHARGE, blast = DIVE_BLAST }
local function dur_for(t, name)
  if t.style == "dive" then
    return DIVE_DUR[name]
  end
  if name == "freeze" then
    return FREEZE
  elseif name == "focus" then
    return FOCUS
  elseif name == "charge" then
    return CHARGE
  end
  return BLAST
end

-- A fresh, INERT timeline. begin() arms it; until then active() is false and the
-- orchestrator runs the layer normally.
function transition.new() return { active = false } end

function transition.active(t) return t.active == true end

-- Arm the cinematic on the cell at (opts.x, opts.y). opts also carries the three
-- side-effect callbacks (on_focus(x,y,zoom), on_shake(mag,life,seed), on_reset())
-- and optional text overrides. Begins in `freeze`; the world holds while phase
-- and timers advance under update().
function transition.begin(t, opts)
  t.active = true
  t.phase = "freeze"
  t.phase_i = 1
  t.elapsed = 0 -- seconds inside the current phase
  -- Style selects the FINALE language. "white" (default, phase 2's fork) is the classic
  -- dim-wash + white-out wipe. "dive" (phase 1's endosymbiosis) instead DISSOLVES the
  -- dish to isolate the winning cell, brightens it into a hero, and plunges the camera
  -- into it -- a teal flood, never a white flash -- handing straight off to phase 2.
  t.style = opts.style or "white"
  t.x = opts.x
  t.y = opts.y
  t.title = opts.title or transition.TITLE
  t.kicker = opts.kicker or transition.KICKER
  t.subtitle = opts.subtitle or transition.SUBTITLE
  t.on_focus = opts.on_focus
  t.on_shake = opts.on_shake
  t.on_reset = opts.on_reset
  t.reset_done = false
end

-- Fire the side effect that OPENS a phase (called once, as the phase begins).
local function enter_phase(t)
  if t.phase == "focus" then
    -- Begin the camera push-in onto the triggering cell.
    if t.on_focus then
      t.on_focus(t.x, t.y, ZOOM_MULT)
    end
    if t.on_shake then
      t.on_shake(3, 0.5, t.x + t.y) -- a small settle bump as the camera takes hold
    end
  elseif t.phase == "charge" then
    -- The dive's deepening zoom is driven CONTINUOUSLY in update() (not a step here);
    -- the white style holds its single focus zoom. This opens the rising rumble.
    if t.on_shake then
      t.on_shake(5, dur_for(t, "charge") * 0.9, t.x) -- rumble across the build-up
    end
  elseif t.phase == "blast" then
    if t.on_shake then
      -- A softer settle for the dive (no detonation -- we're gliding inside the cell);
      -- the full kick stays for the white-out blast.
      local kick = t.style == "dive" and 6 or 14
      t.on_shake(kick, 0.7, t.y)
    end
  end
end

-- Advance the timeline. Walks phases as their timers fill; in `blast`, fires the
-- single reset at the white peak (RESET_FRAC) and ends the cinematic when the
-- blast completes. Pure: every side effect goes through the bound callbacks.
function transition.update(t, dt)
  if not t.active then
    return
  end
  t.elapsed = t.elapsed + dt

  -- The reset fires once, at the peak -- the white style hides its wipe behind full
  -- white; the dive hands off behind its full teal engulf. Keyed on the style's blast
  -- duration so the longer dive holds the descent before crossing into phase 2.
  if t.phase == "blast" and not t.reset_done and t.elapsed >= dur_for(t, "blast") * RESET_FRAC then
    t.reset_done = true
    if t.on_reset then
      t.on_reset()
    end
  end

  local dur = dur_for(t, PHASES[t.phase_i][1])
  while t.elapsed >= dur do
    if t.phase_i >= #PHASES then
      t.active = false -- blast complete: the cinematic is over
      return
    end
    t.elapsed = t.elapsed - dur
    t.phase_i = t.phase_i + 1
    t.phase = PHASES[t.phase_i][1]
    enter_phase(t)
    dur = dur_for(t, t.phase)
  end

  -- The dive keeps DEEPENING the zoom continuously across its second half (charge ->
  -- the pre-reset plunge): re-aim the focus a little further in every update, so the
  -- camera never reaches its target and sits -- it's still descending as we cross into
  -- phase 2. `into/span` runs 0->1 from the charge start to the hand-off; smoothstep
  -- eases the climb. (The white style holds its single focus zoom -- nothing here.)
  if t.style == "dive" and t.on_focus and (t.phase == "charge" or t.phase == "blast") then
    local charge_d = dur_for(t, "charge")
    local span = charge_d + dur_for(t, "blast") * RESET_FRAC -- charge start -> hand-off
    local into = (t.phase == "charge") and t.elapsed or (charge_d + t.elapsed)
    local k = smoothstep(into / span)
    t.on_focus(t.x, t.y, DIVE_ZOOM_START + (DIVE_ZOOM_END - DIVE_ZOOM_START) * k)
  end
end

-- How far the dish has DISSOLVED (0 = full dish, 1 = only the winner left), for the
-- orchestrator to hand to view.draw_world as the isolation fade. The siblings start
-- fading the moment the camera takes hold (focus), are mostly gone by the end of the
-- build-up (charge), and fully gone through the plunge (blast) -- so the lone hero cell
-- is all that remains as the camera dives in. Pure (no love.*); 0 when inert or for the
-- white style (only phase 1 reads it, but it stays well-defined everywhere).
function transition.world_fade(t)
  if not t.active then
    return 0
  end
  if t.phase == "freeze" then
    return 0
  elseif t.phase == "focus" then
    return smoothstep(t.elapsed / dur_for(t, "focus")) * 0.6
  elseif t.phase == "charge" then
    return 0.6 + 0.4 * smoothstep(t.elapsed / dur_for(t, "charge"))
  end
  return 1 -- blast: the dish is gone; only the hero remains under the plunge
end

-- ============================================================================
-- Draw (love.* lives only below this line). Screen-space overlay drawn by the
-- orchestrator AFTER the world, given the triggering cell's projected screen
-- position (sx, sy). Everything keys off the phase + in-phase progress.
-- ============================================================================

-- Centered scaled print of a pixel font at (cx, cy). Pixel fonts scale crisply
-- under the nearest filter, so the title can blow up large without blur.
local function print_centered(font, str, cx, cy, scale, color, alpha)
  if alpha <= 0 then
    return
  end
  love.graphics.setFont(font)
  local w = font:getWidth(str) * scale
  local h = font:getHeight() * scale
  -- Drop shadow for legibility over the busy dish.
  love.graphics.setColor(0, 0, 0, 0.5 * alpha)
  love.graphics.print(str, cx - w / 2 + scale, cy - h / 2 + scale, 0, scale, scale)
  love.graphics.setColor(color[1], color[2], color[3], alpha)
  love.graphics.print(str, cx - w / 2, cy - h / 2, 0, scale, scale)
end

-- The kicker / title / subtitle block, anchored above (ax, ay) and fading with
-- `reveal` (0..1) and an overall `alpha` (the blast blows it out).
local function draw_text_block(t, ax, ay, reveal, alpha)
  if alpha <= 0 then
    return
  end
  local title_font = fonts.get("hud_lg")
  local body_font = fonts.get("hud")
  local rise = (1 - smoothstep(reveal)) * 22 -- text eases upward as it fades in
  local title = colors.ui.white
  local kick = colors.tertiary
  local sub = colors.ui.text_dim
  print_centered(body_font, t.kicker, ax, ay - 56 + rise, 1.2, kick, alpha * reveal)
  print_centered(title_font, t.title, ax, ay - 22 + rise, 2.1, title, alpha * reveal)
  print_centered(body_font, t.subtitle, ax, ay + 26 + rise, 1.2, sub, alpha * smoothstep(reveal))
end

-- The gathering core + collapsing ring at the cell during focus/charge. Grows
-- and brightens toward the blast; the ring falls inward like energy drawn in.
local function draw_core(sx, sy, intensity)
  if intensity <= 0 then
    return
  end
  local prim = colors.primary
  -- Outer glow.
  love.graphics.setColor(prim[1], prim[2], prim[3], 0.18 * intensity)
  love.graphics.circle("fill", sx, sy, 26 + 70 * intensity)
  -- Bright core, whitening (lerp toward 1) as it charges.
  local cw = intensity -- 0..1 -> teal to white
  local cr = prim[1] + (1 - prim[1]) * cw
  local cg = prim[2] + (1 - prim[2]) * cw
  local cb = prim[3] + (1 - prim[3]) * cw
  love.graphics.setColor(cr, cg, cb, 0.85 * intensity)
  love.graphics.circle("fill", sx, sy, 6 + 22 * intensity)
  -- Collapsing ring: starts wide, falls inward as the charge completes.
  love.graphics.setLineWidth(2)
  love.graphics.setColor(1, 1, 1, 0.6 * intensity)
  love.graphics.circle("line", sx, sy, 150 * (1 - intensity) + 14)
  love.graphics.setLineWidth(1)
  love.graphics.setColor(1, 1, 1, 1)
end

-- A full-screen dark wash that dims the world so the charging cell stands out.
local function draw_dim(alpha)
  if alpha <= 0 then
    return
  end
  local w, h = love.graphics.getDimensions()
  love.graphics.setColor(0, 0, 0, alpha)
  love.graphics.rectangle("fill", 0, 0, w, h)
  love.graphics.setColor(1, 1, 1, 1)
end

-- The white-out: an expanding disk from the cell that fills the screen, peaking
-- to a full white sheet at RESET_FRAC (where the reset fires), then fading to
-- reveal the fresh level.
local function draw_blast(sx, sy, k)
  local w, h = love.graphics.getDimensions()
  local diag = math.sqrt(w * w + h * h)
  if k < RESET_FRAC then
    -- Rising: a disk blooms from the cell while a white sheet ramps to full.
    local rise = smoothstep(k / RESET_FRAC)
    love.graphics.setColor(1, 1, 1, rise)
    love.graphics.circle("fill", sx, sy, diag * 1.1 * rise)
    love.graphics.setColor(1, 1, 1, rise * 0.9)
    love.graphics.rectangle("fill", 0, 0, w, h)
  else
    -- Falling: hold then fade the full sheet, revealing the reset world beneath.
    local fall = 1 - smoothstep((k - RESET_FRAC) / (1 - RESET_FRAC))
    love.graphics.setColor(1, 1, 1, fall)
    love.graphics.rectangle("fill", 0, 0, w, h)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

-- The HERO core (dive style): the winning cell's own teal core gathers + brightens as
-- the dish dissolves around it, swelling toward white-teal so the lone survivor reads
-- as the chosen one. Same gather-and-collapse language as draw_core, but in the cell's
-- colour (no dim wash behind it -- the world fade does the isolating).
local function draw_hero_core(sx, sy, intensity)
  if intensity <= 0 then
    return
  end
  local prim = colors.primary
  -- Outer glow in the cell's hue.
  love.graphics.setColor(prim[1], prim[2], prim[3], 0.22 * intensity)
  love.graphics.circle("fill", sx, sy, 30 + 90 * intensity)
  -- Bright core, whitening toward 1 as it heroes (teal -> bright teal-white).
  local cw = intensity
  local cr = prim[1] + (1 - prim[1]) * cw
  local cg = prim[2] + (1 - prim[2]) * cw
  local cb = prim[3] + (1 - prim[3]) * cw
  love.graphics.setColor(cr, cg, cb, 0.9 * intensity)
  love.graphics.circle("fill", sx, sy, 8 + 30 * intensity)
  -- Collapsing ring, drawn inward as the charge completes (energy gathering in).
  love.graphics.setLineWidth(2)
  love.graphics.setColor(prim[1], prim[2], prim[3], 0.55 * intensity)
  love.graphics.circle("line", sx, sy, 170 * (1 - intensity) + 16)
  love.graphics.setLineWidth(1)
  love.graphics.setColor(1, 1, 1, 1)
end

-- The ENGULF (dive style, replacing the white-out): the hero cell's teal body floods
-- out from itself to fill the frame -- we are diving INSIDE the cell. `cover` (0..1)
-- reaches 1 at the hand-off, so the screen is solidly the cell's colour exactly as the
-- layer switches behind it (phase 2 opens out of the same teal, so there's no flash and
-- no cut). A touch of whitening keeps it reading as the cell's bright interior, never a
-- flat sheet.
local function draw_engulf(sx, sy, cover)
  if cover <= 0 then
    return
  end
  local w, h = love.graphics.getDimensions()
  local diag = math.sqrt(w * w + h * h)
  local prim = colors.primary
  local wb = 0.25 * cover
  local r = prim[1] + (1 - prim[1]) * wb
  local g = prim[2] + (1 - prim[2]) * wb
  local b = prim[3] + (1 - prim[3]) * wb
  -- An expanding disk blooms from the cell while a teal sheet ramps to full, so the
  -- frame is wholly the cell's colour at the peak (masking the seam into phase 2).
  love.graphics.setColor(r, g, b, cover)
  love.graphics.circle("fill", sx, sy, diag * 1.15 * cover)
  love.graphics.setColor(r, g, b, cover)
  love.graphics.rectangle("fill", 0, 0, w, h)
  love.graphics.setColor(1, 1, 1, 1)
end

-- Phase 1's "dive" overlay: no dark wash (view.draw_world dissolves the dish via the
-- world fade), a teal hero core riding the lone winner, and a teal engulf that floods
-- the frame as the camera plunges in -- the continuous zoom IS the bridge to phase 2.
local function draw_dive(t, sx, sy, ay)
  if t.phase == "freeze" then
    return -- held frame: the endosymbiosis beat (owned by the view) plays
  elseif t.phase == "focus" then
    local p = clamp01(t.elapsed / dur_for(t, "focus"))
    draw_hero_core(sx, sy, 0.25 + 0.35 * smoothstep(p))
    draw_text_block(t, sx, ay, p, 1)
  elseif t.phase == "charge" then
    local p = clamp01(t.elapsed / dur_for(t, "charge"))
    draw_hero_core(sx, sy, 0.6 + 0.4 * (p * p)) -- gathers to full by the plunge
    draw_text_block(t, sx, ay, 1, 1)
  elseif t.phase == "blast" then
    local p = clamp01(t.elapsed / dur_for(t, "blast"))
    draw_hero_core(sx, sy, 1)
    -- The text blows out fast as the engulf floods up.
    draw_text_block(t, sx, ay, 1, 1 - smoothstep(p / 0.25))
    -- Cover reaches full at RESET_FRAC -- exactly when the hand-off into phase 2 fires.
    draw_engulf(sx, sy, smoothstep(clamp01(p / RESET_FRAC)))
  end
end

-- Draw the cinematic overlay. (sx, sy) is the triggering cell projected to the
-- screen (the orchestrator computes it via view.world_to_screen each frame, so
-- the core + text ride the cell as the camera moves). No-op when inactive. Dispatches
-- on style: "dive" (phase 1's zoom-into-the-cell) vs the classic "white" wipe.
function transition.draw(t, sx, sy)
  if not t.active then
    return
  end
  local _w, h = love.graphics.getDimensions()
  -- Anchor the text near the cell but clamp it on-screen so it never sails off.
  local ay = math.max(h * 0.24, math.min(sy, h * 0.8))

  if t.style == "dive" then
    return draw_dive(t, sx, sy, ay)
  end

  if t.phase == "freeze" then
    -- Held frame: the endosymbiosis beat (owned by the view) plays; nothing here.
    return
  elseif t.phase == "focus" then
    local p = clamp01(t.elapsed / FOCUS)
    draw_dim(0.45 * smoothstep(p))
    draw_core(sx, sy, 0.25 * smoothstep(p))
    draw_text_block(t, sx, ay, p, 1)
  elseif t.phase == "charge" then
    local p = clamp01(t.elapsed / CHARGE)
    draw_dim(0.45 + 0.2 * p)
    -- Intensity ramps with a late surge near the detonation.
    draw_core(sx, sy, 0.25 + 0.75 * (p * p))
    draw_text_block(t, sx, ay, 1, 1)
  elseif t.phase == "blast" then
    local p = clamp01(t.elapsed / BLAST)
    -- The dim wash fades out across the blast so the revealed (reset) level isn't
    -- left darkened under the lifting white-out -- it's hidden by white while high.
    draw_dim(0.65 * (1 - smoothstep(p)))
    -- The text blows out fast in the opening of the blast.
    draw_text_block(t, sx, ay, 1, 1 - smoothstep(p / 0.25))
    draw_blast(sx, sy, p)
  end
end

-- Tuning exposed for tests (the timeline lengths + the reset point).
transition.FREEZE = FREEZE
transition.FOCUS = FOCUS
transition.CHARGE = CHARGE
transition.BLAST = BLAST
transition.RESET_FRAC = RESET_FRAC

return transition
