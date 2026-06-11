-- Standalone spec for lib/engine/build_hash.lua's pure hashing core.
-- Plain Lua 5.1 / luajit, no framework, no love. Run from the repo root:
-- lua tests/build_hash_spec.lua
--
-- build_hash.digest(paths, read, hash_hex) is a pure function -- it sorts the
-- paths for determinism, concatenates each readable file's path + body, hashes,
-- and truncates to 8 hex chars. We drive it with a fake reader + a fake hasher
-- (record-and-return) so we can assert ORDERING, truncation, and that missing
-- files are skipped, without depending on love.data's MD5.
local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
package.path = root .. "/?.lua;" .. package.path

local build_hash = require("lib.engine.build_hash")

local checks = 0

local function check(condition, label)
  checks = checks + 1
  if not condition then
    error("FAILED: " .. label, 2)
  end
end

-- A fake hasher that just returns the input it was given, so the spec can inspect
-- exactly what string would be hashed (the concatenated, ordered source).
local function identity_hex(data) return data end

local function reader(files)
  return function(path) return files[path] end
end

-- Deterministic ordering: paths arrive unsorted but the digest input is built in
-- sorted order, each file as "<path>\0<body>\0".
local files = { ["b.lua"] = "B", ["a.lua"] = "A", ["c.lua"] = "C" }
local input = build_hash.digest({ "b.lua", "c.lua", "a.lua" }, reader(files), identity_hex)
-- identity_hex returns the full concat; we truncated to 8 chars, so check the
-- prefix is the sorted "a.lua\0A\0b.lua\0..." run.
check(input == "a.lua\0A\0", "sorted order, truncated to 8 hex chars (full = a.lua\\0A\\0b...)")

-- Truncation length: a long hex digest is cut to exactly 8 chars.
local long = build_hash.digest(
  { "x" },
  function() return "" end,
  function() return "0123456789abcdef" end
)
check(long == "01234567", "digest truncates to 8 chars")
check(#long == 8, "digest length is 8")

-- Missing files (reader returns nil) are skipped, not concatenated as nil/"".
local sparse =
  build_hash.digest({ "present.lua", "ghost.lua" }, reader({ ["present.lua"] = "P" }), identity_hex)
check(
  sparse == "present.",
  "missing ghost.lua skipped; only present.lua contributes (full = present.lua\\0P\\0)"
)
-- Cross-check: a hasher that tags length proves ghost.lua contributed nothing.
local seen
build_hash.digest({ "present.lua", "ghost.lua" }, reader({ ["present.lua"] = "P" }), function(data)
  seen = data
  return data
end)
check(seen == "present.lua\0P\0", "only present file's path+body in hash input")

-- Determinism: same files, different argument order -> identical input string.
local a = build_hash.digest({ "a.lua", "b.lua" }, reader(files), function(d) return d end)
local b = build_hash.digest({ "b.lua", "a.lua" }, reader(files), function(d) return d end)
check(a == b, "argument order does not change the digest")

print("all tests passed (" .. checks .. " checks)")
