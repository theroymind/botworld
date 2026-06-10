-- Standalone spec for lib/love-ui/toast.lua (the library-owned transient hint shared
-- by every layer). Plain Lua 5.1, no framework. Run from the repo root:
--   lua tests/toast_spec.lua
--
-- The toast module owns module-local state (one message + linger timer), so these checks
-- exercise the show -> decay -> expiry lifecycle the layers drive each frame. draw() is
-- love-coupled (verified by booting the game) and deliberately NOT touched here. All
-- timing is derived from toast.LINGER_SECONDS, never a literal, so a re-tune of the
-- window can't silently rot the spec.
local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
-- Two patterns: files (lib/foo.lua) and packages with init.lua (lib/love-ui).
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local toast = require("lib.love-ui.toast")

local checks = 0

local function check(condition, label)
  checks = checks + 1
  if not condition then
    error("FAILED: " .. label, 2)
  end
end

local L = toast.LINGER_SECONDS
check(type(L) == "number" and L > 0, "LINGER_SECONDS is a positive number")

-- A fresh module shows nothing (no message, timer at rest).
check(not toast.is_active(), "no toast is active before the first show()")
-- update() on an empty toast is a harmless no-op (never goes active on its own).
toast.update(L)
check(not toast.is_active(), "update() on an empty toast stays inactive")

-- show() arms the full linger window.
toast.show("hello")
check(toast.is_active(), "show() activates the toast")

-- update() decays the timer, but the toast stays up until the window elapses. Consuming
-- nearly (but not all of) the window leaves it active. Fresh show so there is no fp
-- residue from a prior split update -- the lifetime is measured from one show().
toast.show("hello")
toast.update(L * 0.99)
check(toast.is_active(), "the toast is still active just before the window elapses")

-- Draining exactly LINGER_SECONDS of update() from a fresh show takes the timer to 0 ->
-- expired. L - L == 0 exactly, so this pins the lifetime to the constant without fp slop.
toast.show("hello")
toast.update(L)
check(not toast.is_active(), "the toast expires once LINGER_SECONDS of update() elapse")

-- show() re-arms after expiry (a fresh tell replaces the dead one).
toast.show("again")
check(toast.is_active(), "show() re-arms an expired toast")

-- Overshooting the window (a long frame dt) expires it cleanly, never wedging active.
toast.update(L + 5)
check(not toast.is_active(), "an over-long update() past the window expires the toast")

-- A replacement show() mid-window resets the full window (replaces any toast in flight).
toast.show("first")
toast.update(L * 0.5)
toast.show("second") -- re-arms to the full window
toast.update(L * 0.75) -- 0.75*L < L, so the re-armed toast is still up
check(toast.is_active(), "a fresh show() resets the full linger window")

print("all tests passed (" .. checks .. " checks)")
