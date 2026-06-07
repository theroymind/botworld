# botworld

Prototype/benchmark testbed for a Starvester-inspired multi-scale incremental game,
evaluating LÖVE 2D (11.4) as the stack.

## Current experiment: benchmark #2 — GPU-instanced shader swarm

Benchmark #1 (SpriteBatch + CPU sim, see git history) was CPU-bound: every drone cost
an update tick and a batch:add per frame. Benchmark #2 moves the entire swarm to the
GPU. Drones are stateless — each one's position is a closed-form function of
`(instance attributes, time)` evaluated in a vertex shader, mirroring the planned game
architecture where the server syncs only aggregate numbers and clients render swarms
deterministically from a shared clock.

How it works:

- 5 planets orbit the star; each planet has 3-5 moons. The ~30 body positions are the
  only per-frame uniform upload.
- Drones fly hauler loops: planet → moon A → planet → moon B → repeat, with dwell
  easing at each stop, lane spread, and sine wobble — all computed in GLSL.
- The instance buffer (2M drones × 2 vec4 attributes) is filled once at load via FFI.
  "Spawning" just raises the count passed to `love.graphics.drawInstanced`; the CPU
  does zero per-drone work, ever.

```
make run
```

Controls: `space` +10k drones, `b` +100k, `m` +1M, `c` clear, mouse wheel zoom, drag
to pan, `esc` quit.

Reading the numbers:

- `update` — CPU cost of body orbits + uniform sends. Should stay flat regardless of
  drone count; if it doesn't, something is wrong.
- `draw` — CPU submission cost (one drawInstanced call). Also flat by design.
- GPU cost is the whole story: vsync is off (`conf.lua`), so watch FPS as count rises.
  Find where it crosses ~16ms/frame — that's the visual swarm ceiling.

Target: 1M+ drones at 60fps. Cap is 2M (instance buffer size, `MAX_DRONES`).

## Checks

```
make check   # luacheck + stylua --check
```
