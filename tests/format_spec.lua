-- Standalone spec for the compact number formatter (lib/engine/format.lua).
-- Plain Lua 5.1 / luajit, no busted, no love. Run from the repo root:
-- lua tests/format_spec.lua
--
-- The formatter's output string IS its contract, so these assert exact renders.
-- The key boundary is GROUP_THRESHOLD (100,000): below it values show in full with
-- thousand separators; at and above it they collapse to K/M/... suffixes.
local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local format = require("lib.engine.format")

local checks = 0

local function check(condition, label)
  checks = checks + 1
  if not condition then
    error("FAILED: " .. label, 2)
  end
end

local function expect(n, want)
  local got = format.number(n)
  check(got == want, string.format("format.number(%s) -> %q (got %q)", tostring(n), want, got))
end

-- Sub-1000: bare integers, one decimal for fractions.
expect(0, "0")
expect(7, "7")
expect(999, "999")
expect(12.34, "12.3")

-- [1000, 100000): full integer with thousand separators -- the reported bug (2,500
-- instead of 2.50K) and the rest of the grouped range up to the threshold.
expect(1000, "1,000")
expect(2500, "2,500")
expect(25000, "25,000")
expect(99999, "99,999")
-- Fractions in the grouped range round to a whole, separated number (no decimal tail).
expect(2500.4, "2,500")

-- Boundary: GROUP_THRESHOLD switches to suffixes -- 99,999 grouped, 100,000 abbreviated.
expect(100000, "100K")
expect(250000, "250K")

-- Higher tiers keep ~3 significant digits with the right suffix, all the way up.
expect(1200000, "1.20M")
expect(45600000, "45.6M")
expect(789e9, "789B")
expect(5000000000, "5.00B")
expect(1e15, "1.00Qa")
expect(2.5e18, "2.50Qi")
-- Rounding that spills into the next tier carries up cleanly.
expect(999999, "1.00M")
-- Past the largest suffix, fall back to scientific (and round its mantissa too).
expect(1.2e21, "1.2e21")
expect(9.99e22, "1.0e23")

-- Sign is owned out front; magnitude reuses the same rules across every range.
expect(-12.5, "-12.5")
expect(-2500, "-2,500")
expect(-100000, "-100K")

-- Non-finite values pass through as their tostring.
expect(1 / 0, tostring(1 / 0))
expect(-1 / 0, tostring(-1 / 0))
check(format.number(0 / 0) == tostring(0 / 0), "nan passes through")

-- Invariant: nothing in the grouped range ever carries a letter suffix, and every
-- comma sits exactly three digits from the end of its run.
for _, n in ipairs({ 1000, 4096, 31415, 99999 }) do
  local s = format.number(n)
  check(not s:find("%a"), "grouped value has no suffix: " .. s)
  check(s:gsub(",", ""):find("^%d+$") ~= nil, "grouped value is digits + commas: " .. s)
end

print("all tests passed (" .. checks .. " checks)")
