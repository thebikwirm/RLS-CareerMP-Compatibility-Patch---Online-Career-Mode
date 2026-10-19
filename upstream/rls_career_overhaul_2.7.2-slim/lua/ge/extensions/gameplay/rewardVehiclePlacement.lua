local M = {}

local CLEARANCE = 0.6
local AIR_HEIGHT = 10
local GROUND_PROBE = 16
local MAX_GROUND_DELTA = 5
local MAX_GROUND_RISE = 2
local MAX_FOOTPRINT_STEP = 1
local DOWN = vec3(0, 0, -1)
local pendingVerify = {}

local function parseTransform(transform)
  if type(transform) ~= "table" then return nil end
  local pos = transform.pos or transform.position
  if not pos then return nil end
  local px = tonumber(pos.x or pos[1])
  local py = tonumber(pos.y or pos[2])
  local pz = tonumber(pos.z or pos[3])
  if not px or not py or not pz then return nil end
  local rot = transform.rot or transform.rotation or {}
  local q = quat(
    tonumber(rot.x or rot[1]) or 0,
    tonumber(rot.y or rot[2]) or 0,
    tonumber(rot.z or rot[3]) or 0,
    tonumber(rot.w or rot[4]) or 1
  )
  return vec3(px, py, pz), q
end

local function flattenXY(v, fallback)
  local f = vec3(v.x, v.y, 0)
  local len = f:length()
  if len < 0.05 then return fallback end
  return f / len
end

local function horiz(v)
  local f = vec3(v.x, v.y, 0)
  local len = f:length()
  if len < 0.05 then return nil, 0 end
  return f / len, len
end

local function rayClear(from, to)
  local delta = to - from
  local length = delta:length()
  return length < 0.01 or castRayStatic(from, delta / length, length) >= length
end

local function groundZ(x, y, hintZ)
  local origin = vec3(x, y, hintZ + 8)
  local hit = castRayStatic(origin, DOWN, GROUND_PROBE)
  if not hit or hit >= GROUND_PROBE - 0.05 then return nil end
  local z = origin.z - hit
  if math.abs(z - hintZ) > MAX_GROUND_DELTA then return nil end
  return z
end

local function footprintGroundZ(center, halfX, halfY, hintZ)
  local gz = groundZ(center.x, center.y, hintZ)
  if not gz or gz - hintZ > MAX_GROUND_RISE then return nil end
  local lo, hi = gz, gz
  for _, sx in ipairs({-1, 1}) do
    for _, sy in ipairs({-1, 1}) do
      local corner = center + halfX * sx + halfY * sy
      local z = groundZ(corner.x, corner.y, hintZ)
      if not z then return nil end
      lo, hi = math.min(lo, z), math.max(hi, z)
    end
  end
  if hi - lo > MAX_FOOTPRINT_STEP then return nil end
  return gz
end

local function halfExtents(veh)
  local bb = veh and veh.getSpawnWorldOOBB and veh:getSpawnWorldOOBB()
  if bb then
    local half = bb:getHalfExtents()
    if half and half.x > 0.2 and half.y > 0.2 and half.z > 0.1 then
      return half.x, half.y, half.z
    end
  end
  local box = veh and (veh.initialCollidableNodePosBB or veh.initialNodePosBB)
  if box and box.getExtents then
    local extents = box:getExtents()
    if extents and extents.x > 0.4 then
      return extents.x * 0.5, extents.y * 0.5, extents.z * 0.5
    end
  end
  return 1.1, 2.4, 0.75
end

local function boxOf(veh)
  local bb = veh and veh.getSpawnWorldOOBB and veh:getSpawnWorldOOBB()
  if not bb then return nil end
  local half = bb:getHalfExtents()
  if not half or half.x <= 0 then return nil end
  return {
    center = vec3(bb:getCenter()),
    x = vec3(bb:getAxis(0)) * half.x,
    y = vec3(bb:getAxis(1)) * half.y,
    z = vec3(bb:getAxis(2)) * half.z,
    halfZ = half.z
  }
end

local function staticsBlocked(center, hx, hy, halfZ)
  local xDir, xLen = horiz(hx)
  local yDir, yLen = horiz(hy)
  if not xDir or not yDir then return true end
  local xVec, yVec = xDir * xLen, yDir * yLen
  for _, height in ipairs({0.55, 1.15}) do
    local c = vec3(center.x, center.y, center.z + height - halfZ)
    for _, side in ipairs({-1, 0, 1}) do
      if not rayClear(c + xVec * side - yVec, c + xVec * side + yVec) then return true end
      if not rayClear(c + yVec * side - xVec, c + yVec * side + xVec) then return true end
    end
  end
  return false
end

local function vehiclesBlocked(center, hx, hy, hz, ignoreId)
  if not activeVehiclesIterator then return false end
  for id, other in activeVehiclesIterator() do
    if id ~= ignoreId then
      local otherBox = boxOf(other)
      if otherBox and overlapsOBB_OBB(
        center, hx, hy, hz,
        otherBox.center, otherBox.x, otherBox.y, otherBox.z
      ) then
        return true
      end
    end
  end
  return false
end

local function boxBlocked(center, hx, hy, hz, halfZ, ignoreId)
  return vehiclesBlocked(center, hx, hy, hz, ignoreId) or staticsBlocked(center, hx, hy, halfZ)
end

local function grounded(box, hintZ)
  local xDir, xLen = horiz(box.x)
  local yDir, yLen = horiz(box.y)
  if not xDir or not yDir then return false end
  local gz = footprintGroundZ(box.center, xDir * xLen, yDir * yLen, hintZ)
  if not gz then return false end
  local bottom = box.center.z - box.halfZ
  return math.abs(bottom - gz) <= 1.25
end

local function plantedClear(veh, hintZ)
  local box = boxOf(veh)
  if not box then return false end
  local hx = box.x + flattenXY(box.x, vec3(1, 0, 0)) * CLEARANCE
  local hy = box.y + flattenXY(box.y, vec3(0, 1, 0)) * CLEARANCE
  return grounded(box, hintZ) and not boxBlocked(box.center, hx, hy, box.z, box.halfZ, veh:getID())
end

local function axesFromRot(rot)
  local forward = flattenXY(rot * vec3(0, 1, 0), vec3(0, 1, 0))
  local right = flattenXY(forward:cross(vec3(0, 0, 1)), vec3(1, 0, 0))
  return right, forward
end

local function playerAway(origin, forward)
  local player = getPlayerVehicle and getPlayerVehicle(0)
  if not player or not player.getPosition then return forward end
  local delta = origin - player:getPosition()
  delta.z = 0
  local len = delta:length()
  if len < 0.4 then return forward end
  return delta / len
end

local function collectCandidates(origin, right, forward, halfX, halfY)
  local candidates = {vec3(origin.x, origin.y, origin.z)}
  local seen = {}
  local function add(offset)
    local pos = vec3(origin.x + offset.x, origin.y + offset.y, origin.z)
    local key = string.format("%.2f:%.2f", pos.x, pos.y)
    if seen[key] then return end
    seen[key] = true
    candidates[#candidates + 1] = pos
  end

  local away = playerAway(origin, forward)
  for _, dist in ipairs({halfY + 3, halfY + 6, halfY + 10, halfY + 14}) do
    add(away * dist)
    add(away * dist + right * (halfX + 3))
    add(away * dist - right * (halfX + 3))
  end

  local along = {halfY + 2.5, halfY + 5, halfY + 8, halfY + 12, halfY + 16}
  local side = {halfX + 2.5, halfX + 5, halfX + 8}
  for _, a in ipairs(along) do
    add(forward * a)
    add(forward * -a)
    for _, s in ipairs(side) do
      add(forward * a + right * s)
      add(forward * a - right * s)
      add(forward * -a + right * s)
      add(forward * -a - right * s)
    end
  end
  for _, s in ipairs(side) do
    add(right * s)
    add(right * -s)
  end
  return candidates
end

local function applyParkingBrake(veh)
  if not veh or not veh.queueLuaCommand then return end
  veh:queueLuaCommand("input.event('parkingbrake', 1, 1)")
end

local function teleport(veh, center, rot)
  local safeRot = quat(0, 0, -1, 0) * rot
  spawn.safeTeleport(veh, center, safeRot, false, nil, false, true, false)
  applyParkingBrake(veh)
end

local function placeInner(veh, transform)
  local origin, rot = parseTransform(transform)
  if not origin or not rot or not spawn or not spawn.safeTeleport then return false end
  local vehId = veh:getID()
  local halfX, halfY, halfZ = halfExtents(veh)
  local right, forward = axesFromRot(rot)
  local hx = right * (halfX + CLEARANCE)
  local hy = forward * (halfY + CLEARANCE)
  local hz = vec3(0, 0, halfZ)
  local fallback, fallbackDist

  for _, candidate in ipairs(collectCandidates(origin, right, forward, halfX, halfY)) do
    local gz = footprintGroundZ(candidate, right * halfX, forward * halfY, origin.z)
    if gz then
      local center = vec3(candidate.x, candidate.y, gz + halfZ)
      if not boxBlocked(center, hx, hy, hz, halfZ, vehId) then
        teleport(veh, center, rot)
        return true
      end
      local player = getPlayerVehicle and getPlayerVehicle(0)
      local dist = 0
      if player and player.getPosition then
        local delta = center - player:getPosition()
        dist = delta.x * delta.x + delta.y * delta.y
      end
      if not fallback or dist > fallbackDist then
        fallback, fallbackDist = center, dist
      end
    end
  end

  if fallback then
    teleport(veh, fallback, rot)
  else
    teleport(veh, vec3(origin.x, origin.y, origin.z + halfZ), rot)
  end
  return true
end

local function scheduleVerify(veh, transform)
  if not veh or not veh.getID then return end
  local origin = parseTransform(transform)
  if not origin then return end
  local vehId = veh:getID()
  if pendingVerify[vehId] then return end
  if not (core_jobsystem and core_jobsystem.create) then return end
  pendingVerify[vehId] = true
  core_jobsystem.create(function(job)
    job.sleep(0.25)
    pendingVerify[vehId] = nil
    local obj = getObjectByID(vehId)
    if not obj then return end
    if plantedClear(obj, origin.z) then return end
    placeInner(obj, transform)
  end)
end

function M.airSpawnPos(transform)
  local origin = parseTransform(transform)
  if not origin then return nil end
  return vec3(origin.x, origin.y, origin.z + AIR_HEIGHT)
end

function M.place(veh, transform)
  if not veh then return false end
  local ok, planted = pcall(placeInner, veh, transform)
  if ok and planted then
    scheduleVerify(veh, transform)
    return true
  end
  return false
end

return M
