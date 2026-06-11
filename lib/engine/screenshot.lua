-- Single-PNG screen capture, deferred to the draw phase so the shot is of the
-- fully-rendered frame. One reusable path shared by a console command, the F12
-- keybind, and the agent connector. NO ffmpeg, NO burst/collage -- a capture is
-- exactly one PNG. love.* is touched only in post_draw() (the documented draw
-- phase); the rest is pure path/filename logic so it can be unit-tested headless.
--
-- The capture is queued by request() and fired by post_draw(); main.lua calls
-- post_draw() at the very END of love.draw so the screenshot is clean. Where
-- post_draw runs relative to debug/console overlays is main.lua's choice: call it
-- BEFORE drawing the overlay for a clean shot, AFTER to include the overlay.
local screenshot = {}

-- PNG is the only capture format: lossless, what captureScreenshot's imagedata
-- encodes to natively, and good enough for single frames (no size/quality knobs).
local IMAGE_FORMAT = "png"
-- Default capture directory (real filesystem, relative to the launch cwd) so a
-- `love .` run from source drops shots in the repo's screenshots/ folder.
local DEFAULT_DIR = "screenshots"
-- Save-dir fallback path when io.open into the real filesystem fails (packaged
-- builds, sandboxed cwd) -- love.filesystem.write lands it in t.identity's dir.
local FALLBACK_DIR = "screenshots"
-- Queue states: a capture is either absent (nil) or sitting WAITING for the next
-- post_draw to fire it. There is no multi-frame machine -- one PNG, one fire.
local STATE_WAITING = "waiting"

-- Module state: the single pending request (or nil) and the last path written,
-- so the console command can report where the file landed.
local pending = nil
local last_written_path = nil

-- Build a default filename from an optional build-hash prefix and a unique
-- suffix (frame count or os.time). With a hash: "<hash>-<suffix>.png"; without:
-- "<suffix>.png". Pure -- no love.*, so it is directly testable.
function screenshot.default_filename(build_hash, suffix)
  local stem
  if build_hash and build_hash ~= "" then
    stem = build_hash .. "-" .. tostring(suffix)
  else
    stem = tostring(suffix)
  end
  return stem .. "." .. IMAGE_FORMAT
end

-- Resolve the path to write for a request. An explicit path (connector) is used
-- verbatim; otherwise build DEFAULT_DIR/<default_filename>. Pure -- testable.
function screenshot.resolve_path(explicit_path, build_hash, suffix)
  if explicit_path and explicit_path ~= "" then
    return explicit_path
  end
  return DEFAULT_DIR .. "/" .. screenshot.default_filename(build_hash, suffix)
end

-- Make sure the directory holding `path` exists. mkdir -p is a no-op when it
-- already exists; acceptable on this darwin host and mirrors botlands. Draw-phase
-- helper (called from post_draw just before the file write).
local function ensure_directory(path)
  local directory = path:match("(.+)/[^/]+$")
  if directory then
    os.execute('mkdir -p "' .. directory .. '"')
  end
end

-- Try the real filesystem first (io.open) so source runs land in the repo; fall
-- back to love.filesystem.write (save dir) when io.open fails. Returns the path
-- actually written, or nil + error message.
local function write_png(image_data, path)
  local file_data = image_data:encode(IMAGE_FORMAT)
  local bytes = file_data:getString()
  ensure_directory(path)
  local handle = io.open(path, "wb")
  if handle then
    handle:write(bytes)
    handle:close()
    return path
  end
  -- Packaged / sandboxed: write through love.filesystem into the save dir.
  local fallback = FALLBACK_DIR .. "/" .. (path:match("[^/]+$") or path)
  local ok = love.filesystem.write(fallback, bytes)
  if ok then
    return love.filesystem.getSaveDirectory() .. "/" .. fallback
  end
  return nil, "failed to write screenshot to " .. path
end

-- Queue a capture for the next post_draw. `explicit_path` (optional) is written
-- verbatim; otherwise a default name is built in post_draw from the build hash +
-- a unique suffix. `build_hash` (optional) stamps the default filename. Returns
-- false when a capture is already queued (one in flight at a time).
function screenshot.request(explicit_path, build_hash)
  if pending then
    return false
  end
  pending = {
    explicit_path = explicit_path,
    build_hash = build_hash,
    state = STATE_WAITING,
  }
  return true
end

-- True while a capture is queued (for callers that gate on capture state).
function screenshot.is_pending() return pending ~= nil end

-- The path of the most recently written screenshot, or nil if none yet.
function screenshot.last_path() return last_written_path end

-- Fire any queued capture. Call at the very END of love.draw so the shot is of
-- the fully-rendered frame. captureScreenshot defers the imagedata to the end of
-- the frame and never touches a canvas, so draw state stays clean. The pending
-- slot is cleared synchronously here (so a new request can queue next frame); the
-- write happens in the async callback.
function screenshot.post_draw()
  if not pending or pending.state ~= STATE_WAITING then
    return
  end
  local request = pending
  pending = nil
  -- Frame count gives a stable, monotonically-increasing suffix per run; os.time
  -- is the fallback when the frame counter is unavailable.
  local suffix = (love.timer and love.timer.getTime and math.floor(love.timer.getTime() * 1000))
    or os.time()
  local path = screenshot.resolve_path(request.explicit_path, request.build_hash, suffix)
  love.graphics.captureScreenshot(function(image_data)
    local written = write_png(image_data, path)
    if written then
      last_written_path = written
      print("screenshot: " .. written)
    end
  end)
end

return screenshot
