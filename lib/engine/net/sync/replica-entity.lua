-- Generic replica: a shadow container mirroring a remote, server-authoritative
-- entity. Holds an id, a type tag, and an open bag of state applied from
-- snapshots. The game decides how to instantiate and render from this shadow --
-- the engine only tracks the data.
--
-- What was dropped vs botlands: the player/mob/boss/npc entity construction,
-- the seven client.components.* sprites, and entity-types branching. All of that
-- is game content; here a replica is just validated identity + a state bag, so
-- botworld renders co-op presence however it likes. Uses botworld's
-- setmetatable/colon-method composition style.
local function assert_snapshot_entity(snapshot_entity)
  assert(type(snapshot_entity) == "table", "replica_entity: snapshot entity must be a table")
  assert(
    type(snapshot_entity.id) == "number"
      and snapshot_entity.id > 0
      and snapshot_entity.id == math.floor(snapshot_entity.id),
    "replica_entity: snapshot entity missing valid id"
  )
  assert(
    type(snapshot_entity.type) == "string",
    "replica_entity: snapshot entity " .. tostring(snapshot_entity.id) .. " missing type"
  )
end

local replica = {}
replica.__index = replica

local function replica_entity(snapshot_entity)
  assert_snapshot_entity(snapshot_entity)

  local self = setmetatable({}, replica)
  self.id = snapshot_entity.id
  self.type = snapshot_entity.type
  self.state = {}
  for key, value in pairs(snapshot_entity) do
    self.state[key] = value
  end
  return self
end

-- Merge a fresh server snapshot into the shadow state (last write wins).
function replica.apply(self, snapshot)
  for key, value in pairs(snapshot) do
    self.state[key] = value
  end
end

function replica.get(self, field) return self.state[field] end

function replica.set(self, field, value) self.state[field] = value end

return replica_entity
