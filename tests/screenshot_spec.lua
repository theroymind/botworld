-- Standalone spec for lib/engine/screenshot.lua's pure path/queue logic.
-- Plain Lua 5.1 / luajit, no framework, no love. Run from the repo root:
-- lua tests/screenshot_spec.lua
--
-- Covers the testable core: default-filename stamping (with/without a build
-- hash), explicit-vs-default path resolution, and the one-capture-in-flight queue
-- gate. The love.* capture/write glue in post_draw() is not exercised headless.
local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
package.path = root .. "/?.lua;" .. package.path

local screenshot = require("lib.engine.screenshot")

local checks = 0

local function check(condition, label)
  checks = checks + 1
  if not condition then
    error("FAILED: " .. label, 2)
  end
end

-- default_filename: a present hash prefixes the stem; absent/empty hash omits it
-- gracefully. The suffix is stringified and the .png extension is always appended.
check(screenshot.default_filename("abc123", 42) == "abc123-42.png", "hash prefix + suffix")
check(screenshot.default_filename(nil, 42) == "42.png", "nil hash omits prefix")
check(screenshot.default_filename("", 42) == "42.png", "empty hash omits prefix")
check(screenshot.default_filename("abc", "t") == "abc-t.png", "string suffix passes through")

-- resolve_path: an explicit path (the connector's case) is used verbatim; with no
-- explicit path the default name lands under the screenshots/ directory.
check(screenshot.resolve_path("/tmp/x.png", "abc", 1) == "/tmp/x.png", "explicit path verbatim")
check(screenshot.resolve_path(nil, "abc", 7) == "screenshots/abc-7.png", "default dir + name")
check(
  screenshot.resolve_path("", "abc", 7) == "screenshots/abc-7.png",
  "empty path falls to default"
)
check(screenshot.resolve_path(nil, nil, 7) == "screenshots/7.png", "default name without hash")

-- Queue gate: nothing pending at rest; request() queues one and reports true; a
-- second request while one is in flight is refused (one capture at a time).
check(not screenshot.is_pending(), "idle at start")
check(screenshot.request("/tmp/a.png") == true, "first request queues")
check(screenshot.is_pending(), "pending after request")
check(screenshot.request("/tmp/b.png") == false, "second request refused while in flight")
check(screenshot.is_pending(), "still pending after refused request")

-- last_path is nil until a write completes (writes only happen in post_draw glue).
check(screenshot.last_path() == nil, "no last_path before any write")

print("all tests passed (" .. checks .. " checks)")
