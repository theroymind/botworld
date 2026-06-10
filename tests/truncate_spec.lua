-- Standalone spec for the pure ellipsis helper (lib/engine/ui/util/truncate.lua).
-- Plain Lua 5.1 / luajit, no busted, no love. Run from the repo root:
-- lua tests/truncate_spec.lua
--
-- The measure function is injected, so widths here are a fake 10px-per-byte
-- metric -- the spec asserts the fitting contract, not any real font geometry.
local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local truncate = require("lib.engine.ui.util.truncate")

local checks = 0

local function check(condition, label)
  checks = checks + 1
  if not condition then
    error("FAILED: " .. label, 2)
  end
end

local CHAR_W = 10

-- Hex-escape for error messages so a split character doesn't garble the output.
local function label_safe(s)
  return (s:gsub("[\128-\255]", function(c) return string.format("\\x%02X", c:byte()) end))
end

-- 10px per byte, but error when handed a split multi-byte character: a UTF-8 lead
-- byte (>= 0xC0) must be followed by a continuation byte (0x80-0xBF). truncate must
-- only ever measure (and return) whole-character prefixes.
local function measure(s)
  for i = 1, #s do
    local byte = s:byte(i)
    if byte >= 0xC0 then
      local next_byte = s:byte(i + 1)
      if not next_byte or next_byte < 0x80 or next_byte > 0xBF then
        error("split utf-8 character in measured string: " .. label_safe(s))
      end
    end
  end
  return #s * CHAR_W
end

-- Fitting strings come back unchanged.
check(truncate("abc", 3 * CHAR_W, measure) == "abc", "exactly-fitting string unchanged")
check(truncate("abc", 10 * CHAR_W, measure) == "abc", "roomy string unchanged")
check(truncate("", 0, measure) == "", "empty string unchanged")

-- Overflow keeps the longest prefix + "..." that fits, and the result really fits.
local clipped = truncate("abcdef", 5 * CHAR_W, measure)
check(clipped == "ab...", "overflow yields longest prefix + ellipsis")
check(measure(clipped) <= 5 * CHAR_W, "truncated result fits the budget")
check(truncate("abcdef", 4 * CHAR_W, measure) == "a...", "tighter budget drops more")

-- Degenerate widths: room for only the ellipsis, then not even that.
check(truncate("abcdef", 3 * CHAR_W, measure) == "...", "ellipsis-only width")
check(truncate("abcdef", 2 * CHAR_W, measure) == "", "narrower than the ellipsis -> empty")
check(truncate("abcdef", -1, measure) == "", "negative budget -> empty")

-- Multi-byte characters are dropped whole; measure() errors on a split character,
-- so reaching the expected result proves no invalid prefix was ever formed.
local E_ACUTE = string.char(0xC3, 0xA9) -- é, two bytes
local accented = E_ACUTE:rep(3)
check(truncate(accented, 6 * CHAR_W, measure) == accented, "fitting utf-8 string unchanged")
check(
  truncate(accented, 5 * CHAR_W + CHAR_W / 2, measure) == E_ACUTE .. "...",
  "multibyte char dropped whole, never split"
)

print("all tests passed (" .. checks .. " checks)")
