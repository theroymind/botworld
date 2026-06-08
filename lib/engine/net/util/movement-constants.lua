-- Movement tuning constants shared by the engine's movement-math (used by
-- server-reconciliation). Copied verbatim from botlands; a game can supply its
-- own movement model via the prediction step callback if these don't fit.
local M = {}

M.BASE_SPEED = 35
M.WALK_SPEED_MULTIPLIER = 0.5

-- While locked on, movement speed depends on direction relative to facing.
-- Zones are defined by the dot product of the (normalized) move direction and
-- the facing direction: forward keeps full speed, strafing is slightly slower,
-- backpedalling is much slower.
M.LOCK_ON_BACKWARD_SPEED_MULTIPLIER = 0.5
M.LOCK_ON_STRAFE_SPEED_MULTIPLIER = 0.8
M.LOCK_ON_FORWARD_DOT = 0.5 -- dot >= this (within ~60deg of facing) = forward
M.LOCK_ON_BACKWARD_DOT = -0.5 -- dot <= this (beyond ~120deg) = backpedal

return M
