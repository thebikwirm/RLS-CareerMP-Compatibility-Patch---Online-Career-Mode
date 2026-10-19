-- Shared placement for newly issued equipment. Never relocate existing vehicles.
local M = {}

local MAX_DISTANCE = 40
local MAX_DECK_CHANGE = 2
local CLEARANCE = 0.5
local DOWN = vec3(0, 0, -1)

local function rayClear(from, to)
  local delta = to - from
  local length = delta:length()
  return length < 0.01 or castRayStatic(from, delta / length, length) >= length
end

local function groundHeight(point, deckZ)
  local origin = vec3(point.x, point.y, deckZ + MAX_DECK_CHANGE + 1)
  local distance = MAX_DECK_CHANGE * 2 + 2
  local hit = castRayStatic(origin, DOWN, distance)
  if not hit or hit >= distance then return nil end
  local z = origin.z - hit
  if math.abs(z - deckZ) > MAX_DECK_CHANGE then return nil end
  return z
end

-- safeTeleport has no success return and can leave its original box in place
-- when the native search fails. Validate the resulting box before accepting it.
local function placementValid(veh, spot, anchor, isTrailer)
  local bb = veh:getSpawnWorldOOBB()
  if not bb then return false end
  local center, half = vec3(bb:getCenter()), bb:getHalfExtents()
  local x, y, z = vec3(bb:getAxis(0)), vec3(bb:getAxis(1)), vec3(bb:getAxis(2))
  if half.x <= 0 or half.y <= 0 or half.z <= 0 or z.z < 0.94 then return false end
  local delta = center - anchor
  if delta.x * delta.x + delta.y * delta.y > MAX_DISTANCE * MAX_DISTANCE then return false end

  local bottom = center - z * half.z
  local floor = groundHeight(bottom, spot.pos.z)
  if not floor or math.abs(bottom.z - floor) > 1.25 then return false end
  -- Check support across the footprint, not just under the reference node.
  for _, sx in ipairs({-1, 1}) do
    for _, sy in ipairs({-1, 1}) do
      local point = bottom + x * (half.x * sx) + y * (half.y * sy)
      local height = groundHeight(point, spot.pos.z)
      if not height or math.abs(point.z - height) > 1.25 then return false end
    end
  end

  local checkCenter = center
  local checkHalfY = half.y + CLEARANCE
  if isTrailer then
    -- Reserve six metres in front for a tow vehicle to approach the hitch.
    local forward = veh:getDirectionVector()
    checkCenter = center + forward * 3
    checkHalfY = checkHalfY + 3
    local approach = bottom + forward * (half.y + 6)
    if not groundHeight(approach, spot.pos.z) then return false end
  end
  local hx, hy, hz = x * (half.x + CLEARANCE), y * checkHalfY, z * half.z
  for id, other in activeVehiclesIterator() do
    if id ~= veh:getID() then
      local otherBB = other:getSpawnWorldOOBB()
      if not otherBB then return false end
      local ext = otherBB:getHalfExtents()
      if overlapsOBB_OBB(checkCenter, hx, hy, hz, otherBB:getCenter(),
          otherBB:getAxis(0) * ext.x, otherBB:getAxis(1) * ext.y, otherBB:getAxis(2) * ext.z) then
        return false
      end
    end
  end

  -- Native placement checks walls near the bottom of the vehicle. Also check
  -- the upper body/roof and hitch approach so trucks do not fit under low roofs.
  for _, height in ipairs({-half.z + 0.35, 0, half.z - 0.1}) do
    local c = checkCenter + z * height
    for _, side in ipairs({-1, 0, 1}) do
      if not rayClear(c + hx * side - hy, c + hx * side + hy)
          or not rayClear(c + hy * side - hx, c + hy * side + hx) then return false end
    end
  end
  for _, sx in ipairs({-1, 1}) do
    for _, sy in ipairs({-1, 1}) do
      local corner = checkCenter + hx * sx + hy * sy
      if not rayClear(corner - z * (half.z - 0.35), corner + z * (half.z + 0.15)) then return false end
    end
  end
  return true
end

-- All callers own a newly spawned, unregistered vehicle and delete it on
-- failure. waitForPhysics must yield to the next frame after each teleport.
function M.place(veh, spots, options)
  options = options or {}
  if not veh then return false, nil, "missingVehicle" end
  local candidates, seen = {}, {}
  for _, spot in ipairs(spots or {}) do
    if spot and spot.pos and spot.rot and not seen[spot] then
      seen[spot] = true
      candidates[#candidates + 1] = spot
    end
  end
  if not candidates[1] then return false, nil, "noSpace" end
  assert(options.waitForPhysics, "Placement requires a physics-frame wait")
  local vehId = veh:getID()
  veh:queueLuaCommand("controller.setFreeze(1)")
  local anchor = options.anchor or candidates[1].pos
  -- Facilities can contain distant pads; do not search the whole site.
  local nearby = {}
  for _, spot in ipairs(candidates) do
    local delta = spot.pos - anchor
    if delta.x * delta.x + delta.y * delta.y <= MAX_DISTANCE * MAX_DISTANCE then
      nearby[#nearby + 1] = spot
      if #nearby == 8 then break end
    end
  end
  candidates = nearby
  if not candidates[1] then return false, nil, "occupied" end
  local function attempt(spot, pos)
    if not getObjectByID(vehId) then return false end
    if not groundHeight(pos, spot.pos.z) then return false end
    -- Keep vehicle and traffic intersection checks enabled; false explicitly
    -- prevents freeroam's usual traffic-removal behavior.
    -- Do not reset onto the requested bay first. On native-search failure this
    -- leaves the vehicle at its previous position, away from the occupants.
    spawn.safeTeleport(veh, pos, quat(spot.rot), false, nil, false, true, false)
    options.waitForPhysics()
    if not getObjectByID(vehId) then return false end
    return placementValid(veh, spot, anchor, options.isTrailer)
  end
  local function success(spot)
    veh:queueLuaCommand("controller.setFreeze(0)")
    return true, spot
  end

  -- Empty, fitting bays first. The native solver still checks geometry and
  -- partial vehicle overlaps that parking-spot occupancy alone can miss.
  for _, spot in ipairs(candidates) do
    if (not spot.hasAnyVehicles or not spot:hasAnyVehicles(veh:getID()))
        and (not spot.vehicleFits or spot:vehicleFits(veh:getID())) then
      if attempt(spot, spot.pos) then return success(spot) end
    end
  end
  -- Occupied and undersized bays remain useful search origins. Limit both
  -- search seeds and the accepted result to the pickup facility's vicinity.
  for _, spot in ipairs(candidates) do
    if attempt(spot, spot.pos) then return success(spot) end
  end
  local spot = candidates[1]
  for _, radius in ipairs({12, 24}) do
    for _, offset in ipairs({vec3(radius, 0, 0), vec3(-radius, 0, 0), vec3(0, radius, 0), vec3(0, -radius, 0)}) do
      if attempt(spot, spot.pos + offset) then return success(spot) end
    end
  end
  return false, nil, "occupied"
end

return M
