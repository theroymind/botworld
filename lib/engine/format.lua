-- Compact number display for incremental-scale values: integers below 100,000
-- shown in full with thousand separators (2,500), one decimal for sub-1000
-- fractions, K/M/B/T/Qa/Qi suffixes with ~3 significant digits from 100,000 up
-- to 1e21, scientific ("1.2e21") beyond. Pure Lua 5.1.
local format = {}

local SUFFIXES = { "K", "M", "B", "T", "Qa", "Qi" }
local LOG10 = math.log(10)
-- Below this, render the exact integer with thousand separators rather than a
-- K-suffix: abbreviation only earns its lost precision once a value hits six digits.
local GROUP_THRESHOLD = 100000

-- Insert thousand separators into a non-negative integer string ("12345" -> "12,345").
local function group_thousands(digits)
  local grouped = digits
  local count
  repeat
    grouped, count = grouped:gsub("^(%d+)(%d%d%d)", "%1,%2")
  until count == 0
  return grouped
end

function format.number(n)
  if n ~= n or n == math.huge or n == -math.huge then
    return tostring(n)
  end
  if n < 0 then
    return "-" .. format.number(-n)
  end
  if n < 1000 then
    if n % 1 == 0 then
      return string.format("%d", n)
    end
    return string.format("%.1f", n)
  end
  if n < GROUP_THRESHOLD then
    return group_thousands(string.format("%.0f", n))
  end
  -- Walk up suffix tiers; 999.5 is where "%.0f" starts rounding into the next tier.
  local value = n
  local tier = 0
  repeat
    value = value / 1000
    tier = tier + 1
  until value < 999.5 or tier > #SUFFIXES
  if tier <= #SUFFIXES then
    if value >= 99.95 then
      return string.format("%.0f%s", value, SUFFIXES[tier])
    end
    if value >= 9.995 then
      return string.format("%.1f%s", value, SUFFIXES[tier])
    end
    return string.format("%.2f%s", value, SUFFIXES[tier])
  end
  local exponent = math.floor(math.log(n) / LOG10)
  local mantissa = n / 10 ^ exponent
  if mantissa >= 9.95 then -- keep one digit before the point after rounding
    mantissa = mantissa / 10
    exponent = exponent + 1
  elseif mantissa < 1 then -- floor(log10) wobbled high
    mantissa = mantissa * 10
    exponent = exponent - 1
  end
  return string.format("%.1fe%d", mantissa, exponent)
end

return format
