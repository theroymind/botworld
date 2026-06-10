-- Pure single-line ellipsis truncation. measure_fn is injected (str -> pixel width)
-- so this stays love-free and spec-testable; callers pass font:getWidth.
-- Uses "..." rather than U+2026 -- the ellipsis glyph isn't guaranteed across
-- PixelOperator and the DepartureMono fallback.
local ELLIPSIS = "..."

-- UTF-8 continuation bytes are 0b10xxxxxx; a prefix must never end inside a
-- multi-byte character or measure_fn (and the renderer) would see invalid UTF-8.
local CONTINUATION_MIN = 0x80
local CONTINUATION_MAX = 0xBF

local function is_continuation_byte(byte)
  return byte >= CONTINUATION_MIN and byte <= CONTINUATION_MAX
end

-- The prefix made of the first `count` characters, given the byte index where
-- each character starts.
local function prefix_of(str, starts, count)
  if count <= 0 then
    return ""
  end
  local next_start = starts[count + 1]
  if next_start then
    return str:sub(1, next_start - 1)
  end
  return str
end

-- Returns str unchanged when it fits in max_w, otherwise the longest
-- prefix + "..." that fits. When not even "..." fits, returns "".
-- Truncation runs on every draw of an overflowing label, so the prefix is found
-- by binary search -- O(log n) measure_fn calls instead of one per dropped
-- character. This relies on width being monotonic in prefix length, which holds
-- for font metrics (character advances are never negative).
local function truncate(str, max_w, measure_fn)
  if measure_fn(str) <= max_w then
    return str
  end

  local starts = {} -- starts[k] = byte index where the k-th character begins
  for i = 1, #str do
    if not is_continuation_byte(str:byte(i)) then
      table.insert(starts, i)
    end
  end

  -- The full string already failed, so only proper prefixes are candidates.
  local low = 0
  local high = #starts - 1
  local best
  while low <= high do
    local mid = math.floor((low + high) / 2)
    if measure_fn(prefix_of(str, starts, mid) .. ELLIPSIS) <= max_w then
      best = mid
      low = mid + 1
    else
      high = mid - 1
    end
  end

  if not best then
    return ""
  end
  return prefix_of(str, starts, best) .. ELLIPSIS
end

return truncate
