-- Lightweight networking telemetry: snapshots/sec plus a stats snapshot (rtt,
-- ticks, fps). Reads from an injected transport + applicator (duck-typed), so it
-- stays generic. Copied verbatim from botlands -- zero requires. get_stats reads
-- love.timer.getFPS() and so is LÖVE-runtime only.
local function net_stats(config)
  config = config or {}
  local transport = config.transport
  local applicator = config.applicator

  local stats = {
    snapshots_per_second = 0,
  }

  local elapsed = 0
  local previous_snapshot_count = applicator and applicator.snapshot_count or 0
  local snapshots_in_window = 0

  function stats:update(delta_time)
    elapsed = elapsed + delta_time

    if elapsed >= 1 then
      local current_count = applicator and applicator.snapshot_count or 0
      snapshots_in_window = current_count - previous_snapshot_count
      previous_snapshot_count = current_count
      elapsed = elapsed - 1
    end

    self.snapshots_per_second = snapshots_in_window
  end

  function stats:get_stats()
    local round_trip_time = 0
    if transport and transport.get_round_trip_time then
      round_trip_time = transport:get_round_trip_time()
    end

    local server_tick = applicator and applicator.server_tick or 0
    local input_tick = applicator and applicator.input_tick or 0
    local acknowledged_input_tick = applicator and applicator.ack_input_tick or 0

    return {
      fps = love.timer.getFPS(),
      round_trip_time = round_trip_time,
      server_tick = server_tick,
      input_tick = input_tick,
      acknowledged_input_tick = acknowledged_input_tick,
      unacknowledged_inputs = input_tick - acknowledged_input_tick,
      snapshots_per_second = self.snapshots_per_second,
      last_spawned = applicator and applicator.last_snapshot_spawned or 0,
      last_updated = applicator and applicator.last_snapshot_updated or 0,
      last_despawned = applicator and applicator.last_snapshot_despawned or 0,
    }
  end

  return stats
end

return net_stats
