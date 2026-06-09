-- Standalone spec for lib/engine/music.lua (the streaming BGM / layered-stem manager).
-- Plain Lua 5.1, no framework. The fade ENVELOPE is pure (music.advance) and tested
-- directly; the manager's play/fade/pause routing is exercised against a tiny fake
-- love.audio source, so no real audio device is needed. Run: lua tests/music_spec.lua
local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
package.path = root .. "/?.lua;" .. package.path

-- Minimal fake love.audio: records volume/loop/play state per source so we can assert
-- the manager drove them correctly. Installed BEFORE requiring the module under test.
local function fake_source(kind)
  return {
    _kind = kind, -- "stream" | "static" -- asserted so loop stems decode fully (gapless)
    _vol = nil,
    _loop = nil,
    _playing = false,
    setVolume = function(self, v) self._vol = v end,
    getVolume = function(self) return self._vol end,
    setLooping = function(self, b) self._loop = b end,
    play = function(self) self._playing = true end,
    pause = function(self) self._playing = false end,
    isPlaying = function(self) return self._playing end,
  }
end
love = { audio = { newSource = function(_path, kind) return fake_source(kind) end } }

local music = require("lib.engine.music")

local checks = 0
local function check(condition, label)
  checks = checks + 1
  if not condition then
    error("FAILED: " .. label, 2)
  end
end
local function approx(a, b) return math.abs(a - b) < 1e-6 end

-- ---------------------------------------------------------------------------
-- Pure envelope: music.advance(vol, target, rate, dt) -> (vol, arrived)
-- ---------------------------------------------------------------------------
do
  local v, done = music.advance(0, 1, 1, 0.5) -- halfway up a 1/sec fade
  check(approx(v, 0.5) and not done, "advance rises and is not done mid-fade")

  v, done = music.advance(0.8, 1, 1, 0.5) -- would overshoot to 1.3 -> clamps + done
  check(approx(v, 1) and done, "advance clamps to target and reports done (up)")

  v, done = music.advance(0.3, 0, -1, 0.5) -- would undershoot to -0.2 -> clamps to 0
  check(approx(v, 0) and done, "advance clamps to target and reports done (down)")

  v, done = music.advance(0.5, 0.5, 1, 0.1) -- already at target
  check(approx(v, 0.5) and not done, "advance at target is a no-op")
end

-- ---------------------------------------------------------------------------
-- Manager: load / play start the source looping at the right volume.
-- ---------------------------------------------------------------------------
music.reset()
local bgm = music.load("bgm", "x.ogg")
check(bgm.source._loop == true, "load() sets the stream looping")
check(bgm.source._vol == 0 and bgm.source._playing == false, "load() starts paused at 0")
check(bgm.source._kind == "stream", "load() defaults to a streaming source")

-- Short loop stems must decode fully ("static") so LÖVE loops them gaplessly.
local stem = music.load("stem", "s.ogg", { stream = false })
check(stem.source._kind == "static", "load(stream=false) makes a static (gapless-loop) source")

music.play("bgm", 0.75)
check(approx(bgm.source._vol, 0.75) and bgm.source._playing, "play() sounds at the given volume")

-- ---------------------------------------------------------------------------
-- fade_out_pause: eases to 0 over the duration, THEN pauses (holds position).
-- ---------------------------------------------------------------------------
music.fade_out_pause("bgm", 1.0)
music.update(0.5)
check(
  bgm.source._vol < 0.75 and bgm.source._vol > 0 and bgm.source._playing,
  "mid fade-out: quieter, still playing"
)
music.update(0.5) -- lands at 0
check(approx(bgm.source._vol, 0) and not bgm.source._playing, "fade_out_pause pauses at silence")

-- ---------------------------------------------------------------------------
-- Layered stems: three SAME-LENGTH stems start together; only layer1 fades up,
-- the others stay silent until their own fade-in (the vertical-remix invariant).
-- ---------------------------------------------------------------------------
local l1 = music.load("l1", "1.ogg")
local l2 = music.load("l2", "2.ogg")
music.play("l1", 0)
music.play("l2", 0)
check(l1.source._playing and l2.source._playing, "both stems start playing (in phase)")

music.fade_in("l1", 0.75, 3.0)
music.update(3.0)
check(approx(l1.source._vol, 0.75), "layer1 fades up to full")
check(
  approx(l2.source._vol, 0) and l2.source._playing,
  "layer2 stays silent but keeps rolling (in sync)"
)

-- A later fade brings layer2 in without re-seeking.
music.fade_in("l2", 0.75, 2.0)
music.update(2.0)
check(approx(l2.source._vol, 0.75), "layer2 fades in on cue")

print(string.format("music_spec: %d checks passed", checks))
