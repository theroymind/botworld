# botworld

Prototype/benchmark testbed for a Starvester-inspired multi-scale incremental game,
evaluating LÖVE 2D (11.4) as the stack.

## Current experiment: drone swarm benchmark

Measures how many orbiting drones LÖVE/LuaJIT sustains at 60fps. Drones live in flat
parallel arrays (struct-of-arrays, no per-drone tables) and render through a single
SpriteBatch — one draw call for the whole swarm. This mirrors the architecture the real
game would use, and deliberately avoids the per-entity-object pattern that makes
Starvester (GameMaker) lag in the low thousands.

```
make run
```

Controls: `space` +1k drones, `b` +10k, `c` clear, mouse wheel zoom, drag to pan, `esc` quit.

Reading the numbers:

- `update` — CPU cost of the sim tick (orbit integration for every drone).
- `draw` — CPU cost of batch refill + submission only; GPU cost shows up as FPS drop
  while `draw` stays low.
- vsync is off (`conf.lua`) so FPS reflects real throughput, not the display cap.

Find the drone count where frame time crosses ~16ms and note whether update or draw got
there first. That number decides whether LÖVE survives for the real game.

## Checks

```
make check   # luacheck + stylua --check
```
