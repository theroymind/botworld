-- Minimal logging seam for the net engine. A no-op by default so the engine
-- stays silent and headless-safe; swap the methods out for a real sink to trace
-- traffic. Replaces botlands' client.debug.debug-logging dependency (which is
-- game instrumentation, not engine) -- see the enet transport's send/recv hooks.
local logger = {}

-- No-ops: callers pass whatever context they like (tags, sizes, payload fields)
-- and Lua discards the extra arguments until a real sink is installed.
local function noop() end

logger.debug = noop
logger.info = noop
logger.warn = noop
logger.error = noop

return logger
