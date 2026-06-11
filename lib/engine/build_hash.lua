-- Per-launch content hash of the source tree, written to a file and exposed for
-- on-screen display -- true even with uncommitted edits, so a screenshot can be
-- traced back to the exact source it came from. compute() runs once from
-- love.load: it reads main.lua + conf.lua + every lib/**/*.lua in a stable sorted
-- order, MD5s the concatenation, and (in dev) appends the git short sha.
--
-- The hashing core is a pure function of an injected reader + file list, so it is
-- testable headless; only compute()/draw() touch love.* (the documented glue).
local build_hash = {}

-- MD5 over the concatenated source: fast, plenty of bits for a change-detector
-- (this is a build fingerprint, not a security hash).
local HASH_ALGORITHM = "md5"
-- Show the first 8 hex chars -- enough to be unique-at-a-glance without cluttering
-- the HUD; the full digest is overkill on screen.
local HASH_LENGTH = 8
-- Where the computed hash is persisted (lands in t.identity's save dir via
-- love.filesystem.write) so other tooling can read the current build's id.
local HASH_FILE = "build-hash.txt"
-- Source roots fed into the hash. The two top-level files plus the lib/ tree are
-- the game's content; assets/docs/tests are excluded so only code changes the id.
local SINGLE_FILES = { "main.lua", "conf.lua" }
local LIB_ROOT = "lib"
-- Lua source extension -- only .lua files under LIB_ROOT contribute to the hash.
local LUA_EXTENSION = ".lua"
-- Separator joining file bodies before hashing. A path-tagged separator makes the
-- hash sensitive to a file moving/renaming, not just its bytes changing.
local JOIN = "\0"

-- Cached result so get()/draw() are cheap after the one compute().
local cached_hash = nil

-- Hex-encode raw bytes via love.data; isolated so the pure core stays love-free.
local function to_hex(raw) return love.data.encode("string", "hex", raw) end

-- Pure hashing core: given a list of file paths, a `read(path)->contents|nil`
-- function, and a `hash_hex(string)->hexdigest` function, sort the paths for a
-- deterministic order, concatenate each readable file's path + body, hash it, and
-- return the first HASH_LENGTH hex chars. Injecting read + hash_hex keeps this a
-- pure function (no love.*), so a spec can drive it with fakes.
function build_hash.digest(paths, read, hash_hex)
  local ordered = {}
  for i = 1, #paths do
    ordered[i] = paths[i]
  end
  table.sort(ordered)
  local parts = {}
  for i = 1, #ordered do
    local path = ordered[i]
    local contents = read(path)
    if contents then
      parts[#parts + 1] = path
      parts[#parts + 1] = JOIN
      parts[#parts + 1] = contents
      parts[#parts + 1] = JOIN
    end
  end
  return hash_hex(table.concat(parts)):sub(1, HASH_LENGTH)
end

-- Recursively collect every <dir>/**/*.lua path under `dir` into `out`. Uses
-- love.filesystem to enumerate the source tree (works when run from source).
local function collect_lua_files(dir, out)
  for _, item in ipairs(love.filesystem.getDirectoryItems(dir)) do
    local path = dir .. "/" .. item
    local info = love.filesystem.getInfo(path)
    if info and info.type == "directory" then
      collect_lua_files(path, out)
    elseif path:sub(-#LUA_EXTENSION) == LUA_EXTENSION then
      out[#out + 1] = path
    end
  end
  return out
end

-- The full ordered-input file list: the named top-level files plus every lib
-- Lua file. (digest() sorts internally, but assembling here keeps compute small.)
local function source_paths()
  local paths = {}
  for i = 1, #SINGLE_FILES do
    paths[i] = SINGLE_FILES[i]
  end
  collect_lua_files(LIB_ROOT, paths)
  return paths
end

-- The git short sha when a .git is present (dev runs), else nil. io.popen and any
-- git failure are swallowed -- packaged builds have no git and must not error.
local function git_short_sha()
  if not love.filesystem.getInfo(".git") then
    return nil
  end
  local ok, handle = pcall(io.popen, "git rev-parse --short HEAD 2>/dev/null")
  if not ok or not handle then
    return nil
  end
  local sha = handle:read("*l")
  handle:close()
  if sha and sha ~= "" then
    return sha
  end
  return nil
end

-- Compute the build hash once, cache it, persist it to HASH_FILE, and print it.
-- Call from love.load. The result is "<md5-8>" or "<md5-8>-<gitsha>".
function build_hash.compute()
  local content = build_hash.digest(
    source_paths(),
    function(path) return love.filesystem.read(path) end,
    function(data) return to_hex(love.data.hash(HASH_ALGORITHM, data)) end
  )
  local sha = git_short_sha()
  if sha then
    content = content .. "-" .. sha
  end
  cached_hash = content
  love.filesystem.write(HASH_FILE, content)
  print("build " .. content)
  return content
end

-- The computed hash string, or nil if compute() has not run yet.
function build_hash.get() return cached_hash end

-- Draw the hash at (x, y). Caller owns the color/font and where it sits (e.g.
-- bottom-right next to the HUD line); this just prints the cached string.
function build_hash.draw(x, y)
  if cached_hash then
    love.graphics.print(cached_hash, x, y)
  end
end

return build_hash
