# CLAUDE.md

Botworld — idle/incremental game about life scaling up (cell → complex cell → … → galaxy)
in LÖVE 2D (v11.4) / LuaJIT (Lua 5.1). See `GAME_PLAN.md` for the vision and `docs/` for
per-layer design. The architecture is a fixed-timestep clock that ticks every registered
**layer** (so backgrounded scales keep producing) while only the active layer gets per-frame
update/draw/input. Each layer separates a pure economy core from a cosmetic live world.

## Commands

```bash
make run                    # Run the game (love .)
make test                   # Run the spec suite (tests/run)
make lint                   # luacheck
make format                 # stylua (write)
make format-check           # stylua --check (no write)
make check                  # lint + format-check + test  (CI/manual)
make love                   # Package a .love archive
make ios                    # Dev-signed iOS build to a connected iPhone
lua tests/foo_spec.lua      # Run a single spec file
```

`stylua` + `luacheck` run automatically on every `.lua` edit via the `.claude/settings.json`
hook — never run them manually after an edit. Prereqs: LÖVE 2D + luarocks `luacheck` + `stylua`.
Specs are framework-free: each `tests/*_spec.lua` is a plain Lua 5.1 script (no busted) that
`require`s a module, runs `check(condition, label)` assertions, and prints a pass count.
`tests/run` executes them all with the first available interpreter (`lua5.1`/`luajit`).

## Layout

- `main.lua` — thin entry point: boots music, registers layers, resolves the start layer
  (`love . phase2` jumps to the Nth registered layer for debugging), wires input.
- `lib/engine/` — scale-agnostic systems: `clock` (fixed timestep), `layers` (registry +
  dispatch), `economy`, `format` (number abbreviation), `fx`, `music`, `sound`, `save`,
  `touch` (pinch-zoom), plus `net/` and `ui/`.
- `lib/layers/` — one folder/module per scale (`cell`, `complexcell`, `solar`). Each layer is
  an ORCHESTRATOR that wires a **pure core** (no `love.*`) into the live, drawable world.
- `lib/coop/` — co-op messaging. `lib/bodies.lua`, `lib/swarm.lua` — shared sim/render helpers.
- `tests/` — `*_spec.lua` standalone specs + the `run` harness.
- `tools/` — dev/debug labs (`sim_lab.lua`, `phase2_lab.lua`) and `ios.sh`.

Layer contract: a layer module exposes `load`, `update(dt)`, `draw`, `tick(dt)` (for
backgrounded production), and the input handlers the registry forwards (`keypressed`,
`mousepressed`, `mousemoved`, `wheelmoved`). Keep the pure core ignorant of `love.*` and of
other layers; they meet only in the orchestrator.

## Hard rules

- **No magic strings/numbers in logic.** Any value with semantic meaning (enum, tag, state,
  event name, dispatch key, reason) gets a named local or a small constants module — not an
  inline literal. OK to inline: format strings, display text, require paths, obvious numbers
  (0/1/-1), and values inside data/config tables. Name tuning constants at the top of the file
  with a comment on *why* that value (see `BGM_VOLUME` in `main.lua`).
- **Lua 5.1 / LuaJIT only.** No `table.unpack` (use `unpack`), no bitwise operators (use the
  `bit` library), no `//` integer division, no `goto`/labels, no `\z` string escape. Use
  `math.atan2 or math.atan`. Never put a `require()` (or any multi-return call) as the last
  entry in a `{}` constructor — it expands and adds stray elements.
- **Keep the pure core pure.** Economy/sim/trait modules must not touch `love.*`, global state,
  or each other. Idle and offline math runs on the pure core, so it can never depend on live
  agents — backgrounded and offline progression must stay deterministic.
- **Canvas isolation.** Any function that draws to a canvas must create the canvas in the
  update phase (not mid-draw) and restore the previous canvas/transform when done, so it never
  corrupts the shared draw state.
- **Tests:** only add a `_spec.lua` when there's real logic (branching, math, state machines,
  parsing, formatting). Assert behavior and invariants — not exact magic values; derive
  expected timing/amounts from the source constants. No "it exists and runs" tests.
- **Never weaken or remove `assert()` calls.**

## Conventions

`snake_case` for variables/functions/files; `UPPER_SNAKE_CASE` for constants. Boolean functions
prefixed `is_`/`has_`/`can_`. Full words, no abbreviations in new names. The `require` var
matches the filename. Named functions, never functions defined inside functions. Set color with
explicit `love.graphics.setColor` and reset to white when done; don't leak color state across
draws. Before implementing, flag unclear boundaries or missing decisions and wait; while coding,
surface code smells, magic literals, and growing complexity instead of working around them.
