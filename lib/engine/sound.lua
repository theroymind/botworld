-- Tiny sound-effect kit: load a short static source once, clone it per play so
-- overlapping triggers never cut each other off, and jitter the pitch a little so
-- rapid repeats stay organic instead of machine-gun identical.
local sound = {}

local sources = {}
local last_pitch_index = {} -- per-name memory so `pitches` never repeats back-to-back

-- Idempotent: safe to call from a layer's load() on every reset.
function sound.load(name, path)
  if not sources[name] then
    sources[name] = love.audio.newSource(path, "static")
  end
end

-- Play `name`. opts: volume (default 1), and one of two pitch modes --
--   pitch_spread: continuous +/- jitter around 1.0 (organic, for noisy sounds)
--   pitches: a list of pitch RATIOS to pick from (musical, for tonal sounds --
--     stays in key where random jitter would read as detuned). Never repeats
--     the same pick twice in a row.
function sound.play(name, opts)
  local src = sources[name]
  if not src then
    return
  end
  opts = opts or {}
  local s = src:clone()
  if opts.pitches then
    local n = #opts.pitches
    local i = love.math.random(n)
    if n > 1 and i == last_pitch_index[name] then
      i = i % n + 1
    end
    last_pitch_index[name] = i
    s:setPitch(opts.pitches[i])
  elseif opts.pitch_spread and opts.pitch_spread > 0 then
    s:setPitch(1 + (love.math.random() * 2 - 1) * opts.pitch_spread)
  end
  s:setVolume(opts.volume or 1)
  s:play()
end

return sound
