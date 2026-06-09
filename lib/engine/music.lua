-- Streaming BGM manager: named LOOPING music tracks with volume-envelope fades --
-- the long-form sibling of sound.lua (which clones short static SFX). Where sound
-- fires one-shots, music holds a small pool of persistent streams and scores the
-- run by easing their volumes: a track can fade in, fade out (optionally pausing
-- itself when it lands at zero so a later resume continues mid-phrase), or cut.
--
-- VERTICAL LAYERING is the reason the fades live here. Phase 2's stems are exported
-- the SAME length and aligned to the same downbeat, so starting them together (some
-- silent) keeps them in perfect phase; progression then just rides their volumes up.
-- Because every stem started at the same instant and loops the same length, they
-- stay sample-synced no matter how many loops pass -- the manager never re-seeks.
--
-- love.* is touched only through the source handles, and the envelope MATH lives in
-- the pure `advance` helper below, so the fade logic is headless-testable (see
-- tests/music_spec.lua). main.lua drives update(dt) once per frame.
local music = {}

local tracks = {} -- name -> track (see music.load)

-- Pure volume envelope: step `vol` toward `target` at signed `rate` (units/sec),
-- clamping so it never overshoots. Returns (new_vol, arrived) where `arrived` is
-- true on the frame the fade completes (vol reaches target). Side-effect free so
-- the fade timeline can be tested without love. Exposed for the spec.
function music.advance(vol, target, rate, dt)
  if rate == 0 or vol == target then
    return target, vol ~= target -- a zero-rate set arrives immediately
  end
  vol = vol + rate * dt
  if (rate > 0 and vol >= target) or (rate < 0 and vol <= target) then
    return target, true
  end
  return vol, false
end

-- Register a track once (idempotent -- safe from a layer's load() on every reset).
-- Starts paused at volume 0; opts.loop defaults true. By default the source STREAMS
-- (decoded on the fly -- right for long BGM), but a streaming source drops a few ms at
-- the loop point while its decoder refills, so SHORT seamless loops must pass
-- opts.stream = false to decode fully into memory ("static"), which LÖVE loops
-- sample-accurately. Returns the track so callers can introspect in tests.
function music.load(name, path, opts)
  if not tracks[name] then
    opts = opts or {}
    local kind = (opts.stream == false) and "static" or "stream"
    local source = love.audio.newSource(path, kind)
    source:setLooping(opts.loop ~= false)
    source:setVolume(0)
    tracks[name] = { source = source, vol = 0, target = 0, rate = 0 }
  end
  return tracks[name]
end

-- Start `name` playing at `volume` IMMEDIATELY (no fade). Use for a track that should
-- be audible from the first frame (e.g. the boot BGM), or to (re)start a layered stem
-- silently at volume 0 so a later fade brings it in already in phase.
function music.play(name, volume)
  local t = tracks[name]
  if not t then
    return
  end
  volume = volume or 1
  t.vol, t.target, t.rate = volume, volume, 0
  t.on_done, t.pause_on_done = nil, nil
  t.source:setVolume(volume)
  if not t.source:isPlaying() then
    t.source:play()
  end
end

-- Ease `name` toward `target` over `duration` seconds, starting the source if needed.
-- opts.from snaps the starting volume first (so fade-ins always rise from silence);
-- opts.pause_on_done pauses the source once it lands (for fade-then-pause); opts.on_done
-- fires when the fade completes. duration <= 0 applies instantly on the next update.
function music.fade(name, target, duration, opts)
  local t = tracks[name]
  if not t then
    return
  end
  opts = opts or {}
  if opts.from then
    t.vol = opts.from
    t.source:setVolume(opts.from)
  end
  if not t.source:isPlaying() then
    t.source:play()
  end
  t.target = target
  t.rate = (duration and duration > 0) and (target - t.vol) / duration or 0
  t.pause_on_done = opts.pause_on_done
  t.on_done = opts.on_done
end

-- Bring a (possibly silent/just-started) track up from 0 to `volume` over `duration`.
function music.fade_in(name, volume, duration)
  music.fade(name, volume or 1, duration or 1.0, { from = 0 })
end

-- Fade a track DOWN to silence over `duration`, then PAUSE it -- so resume() later
-- picks the phrase back up where it left off rather than restarting.
function music.fade_out_pause(name, duration)
  music.fade(name, 0, duration or 0.5, { pause_on_done = true })
end

-- Hard pause (no fade), holding position. Mirrors a streaming source's pause().
function music.pause(name)
  local t = tracks[name]
  if t then
    t.rate = 0
    t.source:pause()
  end
end

-- Resume a paused track from where it stopped, at its current target volume.
function music.resume(name)
  local t = tracks[name]
  if t and not t.source:isPlaying() then
    t.source:play()
  end
end

-- Advance every track's fade by dt. Cheap no-op for tracks that aren't fading.
function music.update(dt)
  for _, t in pairs(tracks) do
    if t.rate ~= 0 then
      local vol, arrived = music.advance(t.vol, t.target, t.rate, dt)
      t.vol = vol
      t.source:setVolume(vol)
      if arrived then
        t.rate = 0
        if t.pause_on_done then
          t.source:pause()
          t.pause_on_done = nil
        end
        if t.on_done then
          local done = t.on_done
          t.on_done = nil
          done()
        end
      end
    end
  end
end

-- Forget all tracks (tests/teardown). Does not touch love sources.
function music.reset() tracks = {} end

return music
