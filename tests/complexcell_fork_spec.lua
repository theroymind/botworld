-- Standalone spec for lib/layers/complexcell/fork.lua's PURE choice-recording.
-- The fork module's draw functions touch love.*, but record_choice / choice_def /
-- CHOICES are love-free, so they load + run headless here. These checks pin the
-- one place the plant/animal pick is committed (the orchestrator wraps it with
-- persistence + the mode flip). Plain Lua 5.1, no framework. Run from repo root:
--   lua tests/complexcell_fork_spec.lua
local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local fork = require("lib.layers.complexcell.fork")

local checks = 0

local function check(condition, label)
  checks = checks + 1
  if not condition then
    error("FAILED: " .. label, 2)
  end
end

-- The two kingdoms, in order, carry the documented ids.
check(#fork.CHOICES == 2, "two kingdoms")
check(fork.CHOICES[1].id == "plant", "first is plant")
check(fork.CHOICES[2].id == "animal", "second is animal")

-- record_choice writes a VALID id and reports it.
local s1 = {}
check(fork.record_choice(s1, "plant") == "plant", "plant returns its id")
check(s1.fork_choice == "plant", "plant recorded onto state")

local s2 = {}
check(fork.record_choice(s2, "animal") == "animal", "animal returns its id")
check(s2.fork_choice == "animal", "animal recorded onto state")

-- An unknown id is IGNORED: nothing recorded, nil returned (so a stray click /
-- corrupt save can't poison the fork_choice).
local s3 = {}
check(fork.record_choice(s3, "fungus") == nil, "unknown id returns nil")
check(s3.fork_choice == nil, "unknown id records nothing")
check(fork.record_choice(s3, nil) == nil, "nil id returns nil")

-- choice_def round-trips the recorded id back to its display row (the ascension
-- placeholder reads this); an unknown id yields nil.
check(fork.choice_def("plant").label == "PLANT", "plant def label")
check(fork.choice_def("animal").label == "ANIMAL", "animal def label")
check(fork.choice_def("fungus") == nil, "unknown def is nil")

print(string.format("complexcell_fork_spec: %d checks passed", checks))
