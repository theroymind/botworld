-- Standalone smoke spec for the copied net engine (lib/engine/net) + botworld's
-- own co-op message set (lib/coop/messages). Plain Lua 5.1 / luajit, no busted,
-- no love. Run from the repo root: lua tests/net_spec.lua
--
-- Covers: codec roundtrip, loopback send/recv through net.new, registry +
-- packet-type discovery, and the pure sync skeletons (interpolator,
-- reconciliation, generic prediction, generic replica). The enet and steam
-- transports need a runtime (LÖVE/luasteam), so they are verified by behavior at
-- runtime, not here.
local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
-- Two patterns: files (lib/foo.lua) and packages with init.lua (lib/engine/net).
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local net = require("lib.engine.net")
local serializer = require("lib.engine.net.codec.serializer")
local packet = require("lib.engine.net.codec.packet")
local coop_messages = require("lib.coop.messages")

local checks = 0

local function check(condition, label)
  checks = checks + 1
  if not condition then
    error("FAILED: " .. label, 2)
  end
end

local function approx(a, b) return math.abs(a - b) < 0.01 end

local function deep_equal(a, b)
  if type(a) ~= type(b) then
    return false
  end
  if type(a) ~= "table" then
    return a == b
  end
  for key, value in pairs(a) do
    if not deep_equal(value, b[key]) then
      return false
    end
  end
  for key in pairs(b) do
    if a[key] == nil then
      return false
    end
  end
  return true
end

-- Codec roundtrip: serializer and the (headless, uncompressed) packet envelope.
local message = {
  type = "presence",
  x = 1,
  y = 2,
  name = "alpha",
  nested = { a = true, b = { 1, 2, 3 } },
}
check(deep_equal(serializer.decode(serializer.encode(message)), message), "serializer roundtrip")
check(deep_equal(packet.decode(packet.encode(message)), message), "packet roundtrip")
local encoded = packet.encode(message)
check(encoded.compression == "none", "packet encodes uncompressed when headless")

-- Registry discovery: botworld's own message set, discovered the botlands way.
local registry = coop_messages.build()
check(registry.by_type.presence ~= nil, "registry discovered presence")
check(registry.by_type.aura ~= nil, "registry discovered aura")
check(registry.by_type.niche_construction ~= nil, "registry discovered niche_construction")
check(
  registry.by_type.presence.channel == net.channels.state_stream,
  "presence rides the state-stream channel"
)
check(
  registry.by_type.aura.channel == net.channels.reliable_commands,
  "aura rides the reliable channel"
)

-- packet-types discovery convention (kebab file -> SNAKE id).
local discovered = net.codec.packet_types.discover("lib/coop/messages")
check(discovered.presence == "PRESENCE", "discover maps presence")
check(discovered.niche_construction == "NICHE_CONSTRUCTION", "discover snake-cases kebab names")

-- Loopback send/recv end-to-end through two net.new connections over one hub.
local hub = net.transport.loopback()
local server_got = nil
local server = net.new({
  endpoint = hub.server,
  role = "server",
  messages = registry,
  on_recv = function(msg, client_id) server_got = { msg = msg, client_id = client_id } end,
})
local client_got = nil
local client = net.new({
  endpoint = hub:create_client("c1"),
  role = "client",
  messages = registry,
  on_recv = function(msg) client_got = msg end,
})

client:send({ type = "presence", x = 3, y = 4 })
server:poll(0)
check(server_got ~= nil, "loopback delivers client->server")
check(server_got.client_id == "c1", "server sees sender client id")
check(server_got.msg.x == 3 and server_got.msg.y == 4, "client->server payload intact")

server:send_to("c1", { type = "presence", x = 7, y = 8 })
client:poll(0)
check(client_got ~= nil, "loopback delivers server->client")
check(client_got.x == 7 and client_got.y == 8, "server->client payload intact")

-- Broadcast reaches the connected client too.
client_got = nil
server:broadcast({ type = "aura", kind = "warmth", strength = 0.5 })
client:poll(0)
check(client_got ~= nil and client_got.kind == "warmth", "broadcast reaches client")

-- Registry validation gates delivery: a malformed presence is dropped.
server_got = nil
client:send({ type = "presence" }) -- missing x/y -> validate fails
server:poll(0)
check(server_got == nil, "invalid message rejected by registry validate")

-- Sync skeleton: entity interpolator interpolates between buffered samples.
local interpolator = net.sync.interpolator()
interpolator.spawn(1, 0, 0)
interpolator.update(1.0)
interpolator.push_position(1, 100, 0)
interpolator.update(0.05) -- clock 1.05, render_time 0.95 -> 95% between samples
local ix, iy = interpolator.get_position(1)
check(approx(ix, 95) and approx(iy, 0), "interpolator interpolates toward latest sample")

-- Sync skeleton: server reconciliation replays the unacknowledged input tail.
local reconciliation = net.sync.reconciliation
local replay_x, replay_y = reconciliation.reconcile(
  0,
  0,
  { { type = "keyboard", dx = 1, dy = 0, input_tick = 1 } },
  100,
  0.05,
  nil,
  nil,
  nil
)
check(approx(replay_x, 5) and approx(replay_y, 0), "reconciliation replays keyboard input")
local hold_x, hold_y = reconciliation.reconcile(10, 20, {}, 100, 0.05, nil, nil, nil)
check(approx(hold_x, 10) and approx(hold_y, 20), "reconciliation is a no-op on empty input")

-- Sync skeleton: generic prediction replays an injected step + smooths corrections.
local prediction = net.sync.prediction({
  step = function(state, input, dt) state.x = state.x + input.dx * dt end,
})
prediction.initialize(0, 0)
prediction.record({ dx = 10, input_tick = 1 })
prediction.update(1.0)
local predicted_x = prediction.get_predicted_position()
check(approx(predicted_x, 10), "prediction replays the injected step")
prediction.set_corrected_position(7, 0)
local visual_x = prediction.get_visual_position()
check(approx(visual_x, 10), "correction offset keeps the visual position smooth")
local corrected_x = prediction.get_predicted_position()
check(approx(corrected_x, 7), "correction sets the authoritative position")

-- Sync skeleton: generic replica is a validated shadow-state container.
local replica_entity = net.sync.replica
local replica = replica_entity({ id = 1, type = "presence", x = 5, y = 9 })
check(replica.id == 1 and replica.type == "presence", "replica keeps identity")
check(replica:get("x") == 5, "replica reads shadow field")
replica:apply({ x = 12 })
check(replica:get("x") == 12 and replica:get("y") == 9, "replica merges a snapshot")

print("all tests passed (" .. checks .. " checks)")
