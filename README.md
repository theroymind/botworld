> [!IMPORTANT]
> **This repository has moved.** `botworld` is now part of the
> [**lua-games** monorepo](https://github.com/theroymind/lua-games), at
> [`games/botworld`](https://github.com/theroymind/lua-games/tree/main/games/botworld).
> This repo is archived (read-only); development continues in the monorepo.

---

# botworld

Prototype/benchmark testbed for a Starvester-inspired multi-scale incremental game,
evaluating LÖVE 2D (11.4) as the stack.

## Setup

The UI kit lives in the private [`love-ui`](https://github.com/theroymind/love-ui)
repo, wired in as a git submodule at `lib/love-ui` (you need read access to it).
Clone with submodules:

```
git clone --recurse-submodules git@github.com:theroymind/botworld.git
```

Already cloned, or the game fails to load with `module 'lib.love-ui' not found`? Run:

```
make setup        # git submodule update --init --recursive
```

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

## iOS (dev build on your iPhone)

```
make ios     # package .love, build dev-signed LÖVE app, install + launch on device
```

One-time setup: Xcode signed into your Apple ID, iPhone plugged in and trusted,
Developer Mode on (Settings > Privacy & Security). No paid account needed; free
builds expire after 7 days — re-run `make ios`. Overrides: `TEAM_ID`, `DEVICE`,
`BUNDLE_ID`, `LOVE_VERSION` (see `tools/ios.sh`). On the phone, taps/drags map to
mouse input automatically; pinch zooms.

## Checks

```
make check   # luacheck + stylua --check
```
