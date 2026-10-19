local M = {}
local active = false

local function spotArea(spot)
  local scl = spot and spot.scl
  if not scl then return 0 end
  return math.abs(scl.x or 0) * math.abs(scl.y or 0)
end

function M.plan(groups, spots, fits, clear)
  if #groups == 0 or not spots or #spots == 0 then return nil, nil end
  local all = {root = groups[1].root, ids = {}}
  for _, group in ipairs(groups) do
    for _, id in ipairs(group.ids) do all.ids[#all.ids + 1] = id end
  end
  local fitted, fallback, fallbackArea = {}, nil, nil
  for _, spot in ipairs(spots) do
    if clear(spot, all) then
      if fits(all, spot) then
        fitted[#fitted + 1] = {spot = spot, area = spotArea(spot)}
      else
        local area = spotArea(spot)
        if not fallback or area > fallbackArea then
          fallback, fallbackArea = spot, area
        end
      end
    end
  end
  table.sort(fitted, function(a, b) return a.area > b.area end)
  local coupled = {}
  for i = 1, math.min(#fitted, 3) do
    coupled[#coupled + 1] = {group = all, spot = fitted[i].spot}
  end
  if fallback then
    local listed = false
    for _, entry in ipairs(coupled) do
      if entry.spot == fallback then listed = true; break end
    end
    if not listed then coupled[#coupled + 1] = {group = all, spot = fallback} end
  end
  local used = {}
  local split = {}
  local function assignSpot(group, requireFit)
    for i, spot in ipairs(spots) do
      if not used[i] and clear(spot, group) and (not requireFit or fits(group, spot)) then
        used[i] = true
        return spot
      end
    end
  end
  for _, group in ipairs(groups) do
    local spot = assignSpot(group, true)
    if not spot then
      spot = assignSpot(group, false)
      if spot then fits(group, spot) end
    end
    if not spot then
      return #coupled > 0 and coupled or nil, nil
    end
    split[#split + 1] = {group = group, spot = spot}
  end
  return #coupled > 0 and coupled or nil, split
end

local function footprint(group, objects)
  local box = objects[group.root]:getSpawnWorldOOBB()
  local origin = box:getCenter()
  local x = (box:getPoint(3) - box:getPoint(0)):normalized()
  local y = (box:getPoint(0) - box:getPoint(4)):normalized()
  local z = (box:getPoint(1) - box:getPoint(0)):normalized()
  local lo, hi = {math.huge, math.huge, math.huge}, {-math.huge, -math.huge, -math.huge}
  for _, id in ipairs(group.ids) do
    local bounds = objects[id]:getSpawnWorldOOBB()
    for corner = 0, 7 do
      local delta = bounds:getPoint(corner) - origin
      local values = {delta:dot(x), delta:dot(y), delta:dot(z)}
      for axis = 1, 3 do
        lo[axis], hi[axis] = math.min(lo[axis], values[axis]), math.max(hi[axis], values[axis])
      end
    end
  end
  return {x = hi[1] - lo[1], y = hi[2] - lo[2], z = hi[3] - lo[3]},
    vec3(-(lo[1] + hi[1]) / 2, -(lo[2] + hi[2]) / 2, 0)
end

local function boxOf(veh)
  local bb = veh and veh.getSpawnWorldOOBB and veh:getSpawnWorldOOBB()
  if not bb then return nil end
  local half = bb:getHalfExtents()
  return {
    center = vec3(bb:getCenter()),
    x = vec3(bb:getAxis(0)) * half.x,
    y = vec3(bb:getAxis(1)) * half.y,
    z = vec3(bb:getAxis(2)) * half.z,
    halfZ = half.z,
  }
end

local function centerInside(box, point)
  local d = point - box.center
  local ax2, ay2, az2 = box.x:squaredLength(), box.y:squaredLength(), box.z:squaredLength()
  if ax2 < 1e-4 or ay2 < 1e-4 or az2 < 1e-4 then return true end
  return math.abs(d:dot(box.x)) < ax2 and math.abs(d:dot(box.y)) < ay2 and math.abs(d:dot(box.z)) < az2
end

local function rayClear(from, to)
  local delta = to - from
  local length = delta:length()
  return length < 0.01 or castRayStatic(from, delta / length, length) >= length
end

local function horiz(v)
  local f = vec3(v.x, v.y, 0)
  local len = f:length()
  if len < 0.05 then return nil, 0 end
  return f / len, len
end

local function placementBlocked(ids, objects)
  local boxes = {}
  for _, id in ipairs(ids) do
    local box = boxOf(objects[id])
    if not box then return true end
    boxes[#boxes + 1] = box
  end
  for i = 1, #boxes do
    for j = i + 1, #boxes do
      if boxes[i].center:squaredDistance(boxes[j].center) < 0.56
          or centerInside(boxes[i], boxes[j].center)
          or centerInside(boxes[j], boxes[i].center) then
        return true
      end
    end
  end
  local moving = {}
  for _, id in ipairs(ids) do moving[id] = true end
  for id, other in activeVehiclesIterator() do
    if not moving[id] then
      local otherBox = boxOf(other)
      if otherBox then
        for _, box in ipairs(boxes) do
          if overlapsOBB_OBB(box.center, box.x, box.y, box.z, otherBox.center, otherBox.x, otherBox.y, otherBox.z) then
            return true
          end
        end
      end
    end
  end
  for _, box in ipairs(boxes) do
    local xDir, xLen = horiz(box.x)
    local yDir, yLen = horiz(box.y)
    if xDir and yDir then
      local hx, hy = xDir * xLen, yDir * yLen
      for _, height in ipairs({0.55, 1.15}) do
        local c = vec3(box.center.x, box.center.y, box.center.z + height - box.halfZ)
        for _, side in ipairs({-1, 0, 1}) do
          if not rayClear(c + hx * side - hy, c + hx * side + hy)
              or not rayClear(c + hy * side - hx, c + hy * side + hx) then
            return true
          end
        end
      end
    end
  end
  return false
end

local function moveCluster(object, pos, delta)
  local refNode = object:getRefNodeId()
  object:setClusterPosRelRot(refNode, pos.x, pos.y, pos.z, delta.x, delta.y, delta.z, delta.w)
  object:applyClusterVelocityScaleAdd(refNode, 0, 0, 0, 0)
end

local function placeGroup(entry, objects)
  local group = entry.group
  local root = objects[group.root]
  local spot = entry.spot
  if not spot then error("Garage placement refused") end
  local target
  local proxy = setmetatable({
    setClusterPosRelRot = function(_, _, x, y, z, qx, qy, qz, qw)
      target = {pos = vec3(x, y, z), rot = quat(qx, qy, qz, qw)}
    end,
    applyClusterVelocityScaleAdd = function() end,
    setOriginalTransform = function() end,
  }, {__index = function(_, name)
    local member = root[name]
    if type(member) == 'function' then return function(_, ...) return member(root, ...) end end
    return member
  end})
  local offset = group.offset or vec3()
  local shift = vec3()
  shift:setRotate(spot.rot, vec3(offset.x, offset.y, 0))
  spawn.safeTeleport(proxy, spot.pos + shift, spot.rot, true, nil, nil, true, false)
  if not target then error("Garage placement refused") end
  local rootPos = vec3(root:getPosition())
  for _, id in ipairs(group.ids) do
    local object = objects[id]
    local pos = target.pos
    if id ~= group.root then pos = target.pos + target.rot * (vec3(object:getPosition()) - rootPos) end
    moveCluster(object, pos, target.rot)
  end
end

function M.tow(garageId, vehicle, callback, resetVeh, cargoRetry)
  if active then
    ui_message("A vehicle tow is already in progress.", 5, "warning")
    if callback then callback(false, "A vehicle tow is already in progress.") end
    return false
  end
  local inventory = career_modules_inventory
  local capture = career_modules_switchMap
  local function fail(message)
    active = false
    ui_message(message, 8, "warning")
    if callback then callback(false, message) end
    return false
  end
  if not vehicle or not inventory or not capture or not capture.captureInventoryRelationships then
    return fail("Vehicle transport is not ready.")
  end
  local garage = freeroam_facilities.getGarage(garageId)
  if not garage then return fail("Garage is unavailable. Nothing was moved or charged.") end
  local spots = garage and freeroam_facilities.getParkingSpotsForFacility(garage) or {}
  local mapping = inventory.getMapInventoryIdToVehId()
  local manifest = capture.captureInventoryRelationships(mapping)
  local rigRecovery = require('gameplay/delivery/rigRecovery')
  local rootId = vehicle:getID()
  local leaveCargo = not rigRecovery.isRecoveryCargo(rootId)
  local function isCargo(id) return leaveCargo and id ~= rootId and rigRecovery.isRecoveryCargo(id) end
  local objects, original, groups, memberGroup = {}, {}, {}, {}
  local children, loaded = {}, {}
  local function visit(node)
    local id = mapping[tonumber(node.inventoryId)]
    if id then
      children[id] = {}
      for _, child in ipairs(node.children or {}) do
        local childId = mapping[tonumber(child.inventoryId)]
        if childId then children[id][#children[id] + 1] = childId end
        visit(child)
      end
    end
  end
  for _, group in ipairs(manifest.groups) do visit(group.tree) end
  for _, relation in ipairs(manifest.carriedVehicles or {}) do
    local parent, child = mapping[tonumber(relation.parentInventoryId)], mapping[tonumber(relation.inventoryId)]
    if parent and child then loaded[parent] = loaded[parent] or {}; table.insert(loaded[parent], child) end
  end
  local function add(id, group)
    if memberGroup[id] or isCargo(id) then return end
    local object = getObjectByID(id)
    if not object then return end
    objects[id], memberGroup[id] = object, group
    original[id] = {
      pos = vec3(object:getPosition()),
      rot = quat(object:getClusterRotationSlow(object:getRefNodeId())),
    }
    group.ids[#group.ids + 1] = id
    for _, child in ipairs(loaded[id] or {}) do add(child, group) end
    for _, child in ipairs(children[id] or {}) do
      if not memberGroup[child] and not isCargo(child) then
        local nextGroup = {root = child, ids = {}}
        groups[#groups + 1] = nextGroup
        add(child, nextGroup)
      end
    end
  end
  groups[1] = {root = rootId, ids = {}}
  add(rootId, groups[1])
  local progress = true
  while progress do
    progress = false
    for _, connection in ipairs(core_vehicles.attachedCouplers or {}) do
      local a, b = connection[1], connection[2]
      if memberGroup[a] and b and not memberGroup[b] and not isCargo(b) then
        local nextGroup = {root = b, ids = {}}
        groups[#groups + 1] = nextGroup
        add(b, nextGroup)
        progress = true
      elseif memberGroup[b] and a and not memberGroup[a] and not isCargo(a) then
        local nextGroup = {root = a, ids = {}}
        groups[#groups + 1] = nextGroup
        add(a, nextGroup)
        progress = true
      end
    end
  end
  local cargoConnections = leaveCargo and rigRecovery.cargoConnections(memberGroup) or {}
  if #cargoConnections > 0 then
    if cargoRetry then return fail("The recovery vehicle could not be unhitched. Tow cancelled; no charge.") end
    active = true
    rigRecovery.releaseCargo(cargoConnections)
    core_jobsystem.create(function(job)
      for _ = 1, 40 do
        if rigRecovery.cargoReleased(cargoConnections) then break end
        job.sleep(0.05)
      end
      active = false
      if not rigRecovery.cargoReleased(cargoConnections) then
        fail("The recovery vehicle could not be unhitched. Tow cancelled; no charge.")
        return
      end
      rigRecovery.forgetCargoPairs(cargoConnections)
      if getObjectByID(rootId) ~= vehicle then
        fail("Tow cancelled: vehicle or map changed.")
        return
      end
      M.tow(garageId, vehicle, callback, resetVeh, true)
    end)
    return true
  end
  local singleVehicle = #groups == 1 and #groups[1].ids == 1
  for _, connection in ipairs(core_vehicles.attachedCouplers or {}) do
    if connection[1] == rootId or connection[2] == rootId then singleVehicle = false; break end
  end
  if singleVehicle then
    if not garage then return fail("Garage is unavailable. Nothing was moved or charged.") end
    active = true
    local ok, result = pcall(freeroam_facilities.teleportToGarage, garageId, vehicle, resetVeh)
    active = false
    if not ok or result ~= true then
      return fail("Vehicle placement failed. No tow charge.")
    end
    if callback then callback(true) end
    return true
  end
  local function clear(spot, group)
    if not spot.hasAnyVehicles then return false end
    local occupied, ids = spot:hasAnyVehicles()
    if not occupied then return true end
    if not ids or not ids[1] then return false end
    for _, id in ipairs(ids) do if not objects[id] then return false end end
    return true
  end
  local function fits(group, spot)
    local size, offset = footprint(group, objects)
    group.offset = offset
    return spot.scl and size.x <= (spot.scl.x or 0) and size.y <= (spot.scl.y or 0) and size.z <= (spot.scl.z or 0)
  end
  local coupledTries, splitPlan = M.plan(groups, spots, fits, clear)
  if not coupledTries and not splitPlan then
    return fail("No free garage spots fit your vehicle and trailer. Nothing was moved or charged.")
  end
  local function hitchConnections(plan)
    local destinations, connections, seen = {}, {}, {}
    for _, entry in ipairs(plan or {}) do
      for _, id in ipairs(entry.group.ids) do destinations[id] = entry end
    end
    for _, connection in ipairs(core_vehicles.attachedCouplers or {}) do
      if objects[connection[1]] or objects[connection[2]] then
        if not objects[connection[1]] or not objects[connection[2]] then
          return nil, "Select the lead vehicle before towing this coupled group."
        end
        if destinations[connection[1]] ~= destinations[connection[2]] then
          local key = table.concat(connection, ':')
          if not seen[key] then
            seen[key] = true
            connections[#connections + 1] = {connection[1], connection[2], connection[3], connection[4], key = key}
          end
        end
      end
    end
    return connections, nil, seen
  end
  active = true
  local level = getCurrentLevelIdentifier()
  local function valid()
    if level ~= getCurrentLevelIdentifier() or inventory ~= career_modules_inventory then return false end
    for id, object in pairs(objects) do if getObjectByID(id) ~= object then return false end end
    return true
  end
  local function restore(job)
    job.sleep(0.1)
    for id, state in pairs(original) do
      local object = getObjectByID(id)
      if object then
        local current = quat(object:getClusterRotationSlow(object:getRefNodeId()))
        moveCluster(object, state.pos, current:inversed() * state.rot)
      end
    end
  end
  core_jobsystem.create(function(job)
    if not valid() then fail("Tow cancelled: vehicle or map changed."); return end
    local function placePlan(plan)
      for _, entry in ipairs(plan) do
        if entry.spot and not clear(entry.spot, entry.group) then
          return false, "occupied"
        end
      end
      local ok, err = pcall(function()
        for _, entry in ipairs(plan) do
          fits(entry.group, entry.spot)
          placeGroup(entry, objects)
        end
      end)
      if not ok then return false, err end
      return true
    end
    if coupledTries then
      for _, entry in ipairs(coupledTries) do
        if not valid() then fail("Tow cancelled: vehicle or map changed."); return end
        local ok = placePlan({entry})
        if ok then
          job.sleep(0.1)
          if not valid() then fail("Tow cancelled: vehicle or map changed."); return end
          if not placementBlocked(entry.group.ids, objects) then
            active = false
            if callback then callback(true) end
            return
          end
        end
      end
    end
    if not splitPlan then
      restore(job)
      fail("No free garage spots fit your vehicle and trailer. Nothing was moved or charged.")
      return
    end
    local connections, hitchErr, seen = hitchConnections(splitPlan)
    if hitchErr then
      restore(job)
      fail(hitchErr)
      return
    end
    local retained = {}
    for i = #(core_vehicles.attachedCouplers or {}), 1, -1 do
      local key = table.concat(core_vehicles.attachedCouplers[i], ':')
      if seen[key] and retained[key] then table.remove(core_vehicles.attachedCouplers, i) end
      retained[key] = true
    end
    for _, connection in ipairs(connections) do
      objects[connection[1]]:queueLuaCommand(string.format('beamstate.disableAutoCoupling(); obj:detachCoupler(%d, 0)', connection[3]))
      objects[connection[2]]:queueLuaCommand('beamstate.disableAutoCoupling()')
    end
    local function detached()
      for _, connection in ipairs(connections) do
        for _, current in ipairs(core_vehicles.attachedCouplers or {}) do
          if (current[1] == connection[1] and current[2] == connection[2])
            or (current[2] == connection[1] and current[1] == connection[2]) then return false end
        end
      end
      return true
    end
    for _ = 1, 40 do
      if detached() then break end
      job.sleep(0.05)
      if not valid() then fail("Tow cancelled: vehicle or map changed."); return end
    end
    if not detached() then
      restore(job)
      fail("Trailer could not be disconnected. Tow cancelled; no charge.")
      return
    end
    local trailerData = core_trailerRespawn and core_trailerRespawn.getTrailerData()
    for _, connection in ipairs(connections) do
      for _, pair in ipairs({{connection[1], connection[2]}, {connection[2], connection[1]}}) do
        local registered = trailerData and trailerData[pair[1]]
        if type(registered) == 'table' and registered.trailerId == pair[2] then trailerData[pair[1]] = nil end
      end
    end
    local ok, err = placePlan(splitPlan)
    if not ok then
      restore(job)
      if err == "occupied" then
        fail("Garage spawn area became occupied. No tow charge; check trailer couplings before driving.")
      else
        log("E", "garageVehicleTransport", tostring(err))
        fail("Vehicle placement failed. Positions restored; no tow charge. Check trailer couplings before driving.")
      end
      return
    end
    if #splitPlan > 1 then
      ui_message("Truck and trailer towed to the garage separately.", 8, "info")
    end
    active = false
    if callback then callback(true) end
  end)
  return true
end

function M.onClientEndMission()
  active = false
end

return M
