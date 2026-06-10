-- Standalone spec for lib/layers/cell/organelles.lua (endosymbiosis defs + fold).
-- Plain Lua 5.1, no framework. Run from the repo root: lua tests/organelles_spec.lua
local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
package.path = root .. "/?.lua;" .. package.path

local organelles = require("lib.layers.cell.organelles")

local checks = 0

local function check(condition, label)
  checks = checks + 1
  if not condition then
    error("FAILED: " .. label, 2)
  end
end

-- Ordering: mitochondrion before chloroplast, ascending .order.
local defs = organelles.defs()
check(#defs == 2, "two organelles in v1")
check(defs[1].id == "mitochondrion", "mitochondrion is first")
check(defs[2].id == "chloroplast", "chloroplast is second")
check(defs[1].order < defs[2].order, "defs are ordered by .order")

-- def / has lookups.
check(organelles.def("mitochondrion").label == "Mitochondrion", "def() looks up by id")
check(organelles.def("ghost") == nil, "def() is nil for an unknown id")
check(not organelles.has({}, "mitochondrion"), "has() is false for an empty set")
check(organelles.has({ mitochondrion = true }, "mitochondrion"), "has() is true when held")
check(not organelles.has(nil, "mitochondrion"), "has() tolerates a nil set")

-- Predation gate: nothing is eligible until predation (the prey source) is unlocked.
check(organelles.next_eligible({}, 100000, false) == nil, "nothing eligible without predation")

-- Division gate: the mitochondrion needs its lifetime-division gate met.
check(organelles.next_eligible({}, 10, true) == nil, "below the division gate -> nothing eligible")
local mito_gate = organelles.def("mitochondrion").gate_div
local elig = organelles.next_eligible({}, mito_gate, true)
check(elig and elig.id == "mitochondrion", "mitochondrion becomes eligible once its gate is met")

-- Ordering + prerequisite: even far past the chloroplast gate, mitochondrion comes
-- first (it has no prerequisite and a lower order), and chloroplast NEEDS it.
check(
  organelles.next_eligible({}, 100000, true).id == "mitochondrion",
  "mitochondrion precedes chloroplast even past both gates (order + prereq)"
)
local with_mito = { mitochondrion = true }
local chloro_gate = organelles.def("chloroplast").gate_div
check(
  organelles.next_eligible(with_mito, chloro_gate - 1, true) == nil,
  "with mitochondrion held but below the chloroplast gate -> nothing eligible"
)
local elig2 = organelles.next_eligible(with_mito, chloro_gate, true)
check(
  elig2 and elig2.id == "chloroplast",
  "chloroplast is eligible once mitochondrion is held and its gate is met"
)
check(
  organelles.def("chloroplast").needs == "mitochondrion",
  "chloroplast declares its mitochondrion prerequisite"
)

-- Nothing is eligible once both are held.
check(
  organelles.next_eligible({ mitochondrion = true, chloroplast = true }, 100000, true) == nil,
  "nothing left to keep once both organelles are held"
)

-- acquire applies the fold. A fresh set is neutral.
local set = {}
check(organelles.intake_mult(set) == 1, "neutral intake mult with nothing held")
check(organelles.photo_bonus(set) == 0, "neutral photo bonus with nothing held")
check(organelles.acquire(set, "mitochondrion"), "acquire returns true on first add")
check(not organelles.acquire(set, "mitochondrion"), "re-acquiring is a no-op")
check(not organelles.acquire(set, "ghost"), "acquire rejects an unknown id")
check(
  organelles.intake_mult(set) == 2,
  "mitochondrion doubles the intake mult (+1.0 -> the energy revolution)"
)
check(organelles.photo_bonus(set) == 0, "mitochondrion adds no light income")
organelles.acquire(set, "chloroplast")
check(organelles.photo_bonus(set) == 40, "chloroplast adds flat light income")
check(organelles.intake_mult(set) == 2, "chloroplast adds no intake mult")

-- acquired_list is ordered and skips unknown ids tolerantly.
local listed = organelles.acquired_list({ chloroplast = true, mitochondrion = true, ghost = true })
check(#listed == 2, "acquired_list skips unknown ids")
check(listed[1].id == "mitochondrion" and listed[2].id == "chloroplast", "acquired_list is ordered")
check(#organelles.acquired_list({}) == 0, "acquired_list of an empty set is empty")
check(#organelles.acquired_list(nil) == 0, "acquired_list tolerates a nil set")

print("all tests passed (" .. checks .. " checks)")
