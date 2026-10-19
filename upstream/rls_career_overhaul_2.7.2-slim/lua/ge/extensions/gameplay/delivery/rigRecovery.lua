-- Transform an entire recovery group in one GE tick, without resetting damage.
local M = {}
local pending
local releasing
local scanning

local LOCAL_FORWARD = vec3(0, -1, 0)
local DOWN = vec3(0, 0, -1)
local ROAD_SEARCH_RADIUS = 600

local function suppressPoliceSpeedSpike(ids)
  if gameplay_police and gameplay_police.ignoreSpeedingAfterRecovery then
    gameplay_police.ignoreSpeedingAfterRecovery(ids)
  elseif gameplay_police and gameplay_police.ignoreSpeedingAfterTeleport then
    gameplay_police.ignoreSpeedingAfterTeleport()
  end
end

local function nodeOffset(id, name, transform)
  local data = core_vehicle_manager.getVehicleData(id)
  for _, node in pairs(data and data.vdata and data.vdata.nodes or {}) do
    if node.name == name or node.cid == name then
      local obj = getObjectByID(id)
      if transform and obj then
        local position = obj:getPosition() + obj:getNodePosition(node.cid)
        return (transform * MatrixF(true)):inverse():mulP3F(position), node.couplerTag or node.tag
      end
      local offsets = core_vehicles.vehsCouplerOffset[id]
      return offsets and offsets[node.cid], node.couplerTag or node.tag
    end
  end
end

local function couplerIsOnFrontSide(couplerOffset, veh)
  if not couplerOffset or not veh or not veh.initialCollidableNodePosBB then
    return false
  end
  local refNodeInitial = veh:getInitialNodePosition(veh:getRefNodeId())
  local centerOffset = veh.initialCollidableNodePosBB:getCenter() - refNodeInitial
  return (couplerOffset - centerOffset):dot(LOCAL_FORWARD) > 0
end

local function hitchRotation(parentId, childId, parentOffset, childOffset)
  local rotation = MatrixF(true)
  local parentObj, childObj = getObjectByID(parentId), getObjectByID(childId)
  if parentObj and childObj and couplerIsOnFrontSide(parentOffset, parentObj) == couplerIsOnFrontSide(childOffset, childObj) then
    rotation:setFromEuler(vec3(0, 0, math.pi))
  end
  return rotation
end

local function terrainZ(pos)
  local origin = vec3(pos.x, pos.y, (pos.z or 0) + 80)
  local hit = castRayStatic(origin, DOWN, 160)
  if hit and hit < 160 then
    return origin.z - hit
  end
  origin = vec3(pos.x, pos.y, (pos.z or 0) + 250)
  hit = castRayStatic(origin, DOWN, 500)
  if hit and hit < 500 then
    return origin.z - hit
  end
  return nil
end

local function onTerrain(pos)
  local z = terrainZ(pos)
  if not z then return false end
  return pos.z >= z - 4 and pos.z <= z + 16
end

local function destinationSupported(transform)
  local p = transform:getColumn(3)
  local axis = transform:getColumn(1)
  local points = {p}
  if axis then
    points[#points + 1] = p + axis * 8
    points[#points + 1] = p - axis * 8
  end
  for _, point in ipairs(points) do
    if not onTerrain(point) then return false end
  end
  return true
end

local function groupUprightOnTerrain(group)
  for _, id in ipairs(group.ids) do
    local obj = getObjectByID(id)
    if not obj then return false end
    if obj:getDirectionVectorUp().z < 0.5 then return false end
    if not onTerrain(obj:getPosition()) then return false end
  end
  return true
end

local function roadTarget(pos, dir)
  local a, b = map.findClosestRoad(pos)
  local nodes = map.getMap() and map.getMap().nodes
  if not a or not b or not nodes or not nodes[a] or not nodes[b] then
    return nil, nil, 'No nearby road is available.'
  end
  local start, finish = nodes[a].pos, nodes[b].pos
  local delta = finish - start
  local lengthSq = delta:squaredLength()
  if lengthSq < 0.01 then return nil, nil, 'The nearby road has no usable direction.' end
  local t = math.max(0, math.min(1, (pos - start):dot(delta) / lengthSq))
  local roadPos = start + delta * t
  if delta:dot(dir) < 0 then delta = -delta end
  return roadPos, delta
end

local function rearmHinges(group, hinges)
  for _, hinge in ipairs(hinges or {}) do
    local obj = group.objects[hinge.parent] or getObjectByID(hinge.parent)
    local attached = false
    for _, pair in ipairs(core_vehicles.attachedCouplers or {}) do
      if (pair[1] == hinge.parent and pair[2] == hinge.id) or (pair[2] == hinge.parent and pair[1] == hinge.id) then
        attached = true
        break
      end
    end
    if not attached and obj and hinge.tag then
      pcall(obj.queueLuaCommand, obj, string.format('beamstate.activateAutoCoupling(%q)', hinge.tag))
    end
  end
end

function M.isRecoveryCargo(vehId)
  vehId = tonumber(vehId)
  if not vehId then return false end
  if gameplay_offroadRecovery and gameplay_offroadRecovery.isContractTarget
      and gameplay_offroadRecovery.isContractTarget(vehId) then
    return true
  end
  if gameplay_repo and gameplay_repo.isRepoTarget and gameplay_repo.isRepoTarget(vehId) then
    return true
  end
  return false
end

function M.cargoConnections(members)
  local list = {}
  for _, connection in ipairs(core_vehicles.attachedCouplers or {}) do
    local a, b = connection[1], connection[2]
    if (members[a] and not members[b] and M.isRecoveryCargo(b))
        or (members[b] and not members[a] and M.isRecoveryCargo(a)) then
      list[#list + 1] = connection
    end
  end
  return list
end

function M.releaseCargo(connections)
  for _, connection in ipairs(connections) do
    local a, b = getObjectByID(connection[1]), getObjectByID(connection[2])
    if a then a:queueLuaCommand(string.format('beamstate.disableAutoCoupling(); obj:detachCoupler(%d, 0)', connection[3])) end
    if b then b:queueLuaCommand('beamstate.disableAutoCoupling()') end
  end
end

function M.cargoReleased(connections)
  for _, connection in ipairs(connections) do
    for _, current in ipairs(core_vehicles.attachedCouplers or {}) do
      if (current[1] == connection[1] and current[2] == connection[2])
          or (current[1] == connection[2] and current[2] == connection[1]) then
        return false
      end
    end
  end
  return true
end

function M.forgetCargoPairs(connections)
  local trailerData = core_trailerRespawn and core_trailerRespawn.getTrailerData and core_trailerRespawn.getTrailerData()
  if not trailerData then return end
  for _, connection in ipairs(connections) do
    for _, pair in ipairs({{connection[1], connection[2]}, {connection[2], connection[1]}}) do
      local registered = trailerData[pair[1]]
      if type(registered) == 'table' and registered.trailerId == pair[2] then trailerData[pair[1]] = nil end
    end
  end
end

local function pruneCargo(node, isRoot)
  if not node then return nil end
  if not isRoot and M.isRecoveryCargo(node.vehId) then return nil end
  local copy = {}
  for key, value in pairs(node) do copy[key] = value end
  copy.children = {}
  for _, child in ipairs(node.children or {}) do
    local kept = pruneCargo(child, false)
    if kept then copy.children[#copy.children + 1] = kept end
  end
  return copy
end

local function treeIds(node, into)
  if not node then return into end
  if node.vehId then into[node.vehId] = true end
  for _, child in ipairs(node.children or {}) do treeIds(child, into) end
  return into
end

function M.collect(vehId, opts)
  local ids = {vehId}
  if overhaul_playerVehicles and overhaul_playerVehicles.fillCouplerGroup then
    overhaul_playerVehicles.fillCouplerGroup(vehId, ids, {resolveLead = true})
  end
  local root = ids[1]
  local tree = core_vehicles.generateAttachedVehiclesTree(root)
  local leaveCargo = opts and opts.leaveCargo and not M.isRecoveryCargo(root) and not M.isRecoveryCargo(vehId)
  if leaveCargo then
    local allIds = treeIds(tree, {})
    tree = pruneCargo(tree, true)
    local keptIds = treeIds(tree, {})
    local filtered = {}
    for _, id in ipairs(ids) do
      if not M.isRecoveryCargo(id) and (keptIds[id] or not allIds[id]) then filtered[#filtered + 1] = id end
    end
    ids = filtered
  end
  local seen, objects, original, carried = {}, {}, {}, {}
  local function add(id)
    if seen[id] then return true end
    local obj = getObjectByID(id)
    if not obj then return false end
    local rotation = obj:getClusterRotationSlow(obj:getRefNodeId())
    local transform = QuatF(rotation.x, rotation.y, rotation.z, rotation.w):getMatrix()
    transform:setColumn(3, obj:getPosition())
    seen[id], objects[id], original[id] = true, obj, transform
    return true
  end
  for _, id in ipairs(ids) do if not add(id) then return nil, 'A connected vehicle is unavailable.' end end
  local inv = career_modules_inventory
  local tasks = career_modules_delivery_vehicleTasks
  local capture = career_modules_switchMap and career_modules_switchMap.captureInventoryRelationships
  if opts and opts.leaveCargo and tasks and tasks.getCargoCarrier then
    local candidates = {}
    for _, id in pairs(inv and inv.getMapInventoryIdToVehId() or {}) do candidates[id] = true end
    for _, task in ipairs(tasks.getVehicleTasks()) do
      if not task.remove then candidates[task.vehId] = true end
    end
    local ordered = {}
    for id in pairs(candidates) do ordered[#ordered + 1] = id end
    table.sort(ordered)
    for _, child in ipairs(ordered) do
      if not seen[child] and not (leaveCargo and M.isRecoveryCargo(child)) then
        local parent, waiting = tasks.getCargoCarrier(child, ids)
        if parent and add(child) then
          carried[#carried + 1] = {id = child, parent = parent,
            offset = (original[parent] * MatrixF(true)):inverse() * original[child]}
          ids[#ids + 1] = child
        elseif waiting then
          return nil, 'Load detection is still checking this rig. Try again in a moment.', true
        end
      end
    end
  elseif inv and capture then
    local active = inv.getMapInventoryIdToVehId()
    local manifest = capture(active)
    for _ = 1, #(manifest.carriedVehicles or {}) + 1 do
      for _, relation in ipairs(manifest.carriedVehicles or {}) do
        local parent, child = active[relation.parentInventoryId], active[relation.inventoryId]
        if parent and child and seen[parent] and not seen[child]
            and not (leaveCargo and M.isRecoveryCargo(child)) and add(child) then
          carried[#carried + 1] = {id = child, parent = parent,
            offset = (original[parent] * MatrixF(true)):inverse() * original[child]}
          ids[#ids + 1] = child
        end
      end
    end
  end
  return {root = root, ids = ids, objects = objects, original = original, carried = carried,
    tree = tree, cargoConnections = leaveCargo and M.cargoConnections(seen) or {}}
end

local function planHinges(group)
  local hinges = {}
  local function inspect(node, parent)
    if not node then return true end
    if not group.objects[node.vehId] or not group.original[node.vehId] then return false end
    if parent then
      local relation = node.offsetData or {}
      local a, tag = nodeOffset(parent, relation.parentNode, group.original[parent])
      local b = nodeOffset(node.vehId, relation.node, group.original[node.vehId])
      if not a or not b then return false end
      hinges[#hinges + 1] = {
        id = node.vehId,
        parent = parent,
        a = a,
        b = b,
        rotation = hitchRotation(parent, node.vehId, a, b),
        tag = tag,
      }
    end
    for _, child in ipairs(node.children or {}) do
      if not inspect(child, node.vehId) then return false end
    end
    return true
  end
  if not inspect(group.tree) then
    return nil, 'The trailer coupling data is not ready. Try again after the vehicle finishes loading.'
  end
  return hinges
end

local function moveVehicle(obj, transform)
  local p, rotation = transform:getColumn(3), quat(transform:toQuatF())
  local current = quat(obj:getClusterRotationSlow(obj:getRefNodeId()))
  local delta = current:inversed() * rotation
  obj:setClusterPosRelRot(obj:getRefNodeId(), p.x, p.y, p.z, delta.x, delta.y, delta.z, delta.w)
  obj:applyClusterVelocityScaleAdd(obj:getRefNodeId(), 0, 0, 0, 0)
end

local function relativeDestinations(group, hinges, rootTransform)
  local destinations = {[group.root] = rootTransform}
  for _, hinge in ipairs(hinges) do
    destinations[hinge.id] = spawn.calculateRelativeVehiclePlacement(
      destinations[hinge.parent], hinge.a, hinge.b, hinge.rotation)
  end
  for _, relation in ipairs(group.carried) do
    destinations[relation.id] = destinations[relation.parent] * relation.offset
  end
  return destinations
end

local function collisionBounds(obj)
  local clusters = obj:getNodeClusters()
  local cluster = clusters[obj:getRefNodeId() + 1]
  local rotation = quat(obj:getClusterRotationSlow(obj:getRefNodeId()))
  local inverse = rotation:inversed()
  local localBounds, count = Box3F(), 0
  for index, nodeCluster in ipairs(clusters) do
    if nodeCluster == cluster and obj:getInitialNodeCollision(index - 1) == 3 then
      localBounds:extend(inverse * obj:getNodePosition(index - 1))
      count = count + 1
    end
  end
  if count == 0 then return obj:getSpawnWorldOOBB() end
  local transform = QuatF(rotation.x, rotation.y, rotation.z, rotation.w):getMatrix()
  transform:setColumn(3, obj:getPosition() + rotation * localBounds:getCenter())
  local bounds = OrientedBox3F()
  bounds:set2(transform, localBounds:getExtents())
  return bounds
end

local function placementBoxes(group, destinations)
  local boxes = {}
  group.bounds = group.bounds or {}
  for _, id in ipairs(group.ids) do
    local bounds = group.bounds[id] or collisionBounds(group.objects[id])
    group.bounds[id] = bounds
    local transform = destinations[id] * (group.original[id] * MatrixF(true)):inverse()
    local rotation = quat(transform:toQuatF())
    local half = bounds:getHalfExtents()
    boxes[id] = {center = transform:mulP3F(bounds:getCenter()),
      x = rotation * vec3(bounds:getAxis(0)) * half.x,
      y = rotation * vec3(bounds:getAxis(1)) * half.y,
      z = rotation * vec3(bounds:getAxis(2)) * half.z}
  end
  return boxes
end

local function placementClear(group, destinations, ignoreTraffic)
  local boxes = placementBoxes(group, destinations)
  local members, carried = {}, {}
  for _, id in ipairs(group.ids) do members[id] = true end
  if ignoreTraffic and gameplay_traffic and gameplay_traffic.getTrafficList then
    for _, id in ipairs(gameplay_traffic.getTrafficList()) do members[id] = true end
  end
  for _, relation in ipairs(group.carried) do carried[relation.id] = true end
  for id, other in activeVehiclesIterator() do
    if not members[id] then
      local bounds = other:getSpawnWorldOOBB()
      local half = bounds:getHalfExtents()
      for _, box in pairs(boxes) do
        if overlapsOBB_OBB(box.center, box.x, box.y, box.z, bounds:getCenter(),
            vec3(bounds:getAxis(0)) * half.x, vec3(bounds:getAxis(1)) * half.y, vec3(bounds:getAxis(2)) * half.z) then
          return false
        end
      end
    end
  end
  for id, box in pairs(boxes) do
    if not carried[id] then
      for _, x in ipairs({-0.8, 0, 0.8}) do
        for _, y in ipairs({-0.8, 0, 0.8}) do
          local bottom = box.center + box.x * x + box.y * y - box.z
          local z = terrainZ(bottom)
          if not z or bottom.z - z < -0.5 or bottom.z - z > 1 then return false end
        end
      end
    end
    for _, height in ipairs({-0.7, 0, 0.8}) do
      local center = box.center + box.z * height
      for _, side in ipairs({-0.8, 0, 0.8}) do
        for _, ray in ipairs({{center + box.x * side - box.y, box.y * 2},
            {center + box.y * side - box.x, box.x * 2}}) do
          local length = ray[2]:length()
          if length > 0.01 and castRayStatic(ray[1], ray[2] / length, length) < length then return false end
        end
      end
    end
  end
  return true
end

local function blockingTraffic(group, destinations)
  if not gameplay_traffic or not gameplay_traffic.getTrafficList then return {} end
  local boxes, members = placementBoxes(group, destinations), {}
  for _, id in ipairs(group.ids) do members[id] = true end
  local blocked = {}
  for _, id in ipairs(gameplay_traffic.getTrafficList()) do
    local other = not members[id] and getObjectByID(id)
    if other then
      local bounds = other:getSpawnWorldOOBB()
      local half = bounds:getHalfExtents()
      for _, box in pairs(boxes) do
        if overlapsOBB_OBB(box.center, box.x, box.y, box.z, bounds:getCenter(),
            vec3(bounds:getAxis(0)) * half.x, vec3(bounds:getAxis(1)) * half.y, vec3(bounds:getAxis(2)) * half.z) then
          blocked[#blocked + 1] = other
          break
        end
      end
    end
  end
  return blocked
end

local function planDestinations(group, hinges, pos, dir, wholeGroup)
  local target
  local root = group.objects[group.root]
  local rotation = quatFromDir(dir)
  local overrides = {
    setClusterPosRelRot = function() end,
    applyClusterVelocityScaleAdd = function() end,
    setOriginalTransform = function(_, x, y, z, qx, qy, qz, qw)
      local transform = QuatF(qx, qy, qz, qw):getMatrix()
      transform:setColumn(3, vec3(x, y, z))
      target = transform
    end,
  }
  if wholeGroup then
    local boxes = placementBoxes(group, relativeDestinations(group, hinges, group.original[group.root]))
    local nodes, clusters = {}, {}
    local origin = root:getPosition()
    for _, id in ipairs(group.ids) do
      local box = boxes[id]
      for _, x in ipairs({-1, 1}) do
        for _, y in ipairs({-1, 1}) do
          for _, z in ipairs({-1, 1}) do
            nodes[#nodes + 1] = box.center + box.x * x + box.y * y + box.z * z - origin
            clusters[#clusters + 1] = 0
          end
        end
      end
    end
    overrides.getNodeClusters = function() return clusters end
    overrides.getRefNodeId = function() return 0 end
    overrides.getClusterRotationSlow = function() return root:getClusterRotationSlow(root:getRefNodeId()) end
    overrides.getInitialNodeCollision = function() return 3 end
    overrides.getNodePosition = function(_, id) return nodes[id + 1] end
    -- Native placement rotates the reference-node offset after positioning the box.
    -- Position the rotated box center explicitly so an asymmetric rig still lands at pos.
    local current = quat(root:getClusterRotationSlow(root:getRefNodeId()))
    local inverse, bounds = current:inversed(), Box3F()
    for _, node in ipairs(nodes) do bounds:extend(inverse * node) end
    local offset = current * bounds:getCenter()
    local desired = quat(0, 0, 1, 0) * rotation
    pos = pos + (inverse * desired) * offset
  end
  local proxy = setmetatable(overrides, {__index = function(_, name)
    local member = root[name]
    if type(member) == 'function' then return function(_, ...) return member(root, ...) end end
    return member
  end})
  -- Native vehicle checks only ignore the root, so the proxy would collide with its own rig.
  -- placementClear checks foreign vehicles; traffic is handled after selecting a destination.
  local ok, reason = pcall(spawn.safeTeleport, proxy, pos, rotation, wholeGroup or false, nil, not wholeGroup, wholeGroup or nil, false)
  if not ok then error(reason) end
  if not target then
    return nil, 'No safe recovery position was found.'
  end
  local destinations = relativeDestinations(group, hinges, target)
  for _, id in ipairs(group.ids) do
    if not destinations[id] then
      return nil, 'The connected vehicle placement is incomplete.'
    end
    if not destinationSupported(destinations[id]) then
      return nil, 'The recovered rig would not land on solid ground.'
    end
  end
  if wholeGroup and not placementClear(group, destinations, true) then
    return nil, 'No clear road position large enough for the whole rig was found.'
  end
  return destinations
end

local function destinationOnRoad(position, segments)
  local closest, distance, radius
  for _, segment in ipairs(segments) do
    local t = math.max(0, math.min(1, (position - segment.start):dot(segment.delta) / segment.lengthSq))
    local projected = segment.start + segment.delta * t
    local squaredDistance = (position - projected):squaredLength()
    if not distance or squaredDistance < distance then
      closest, distance = projected, squaredDistance
      radius = segment.startRadius + (segment.endRadius - segment.startRadius) * t
    end
  end
  if not closest or radius <= 0 then return false end
  local offset = position - closest
  -- The reference node can sit above the road; do not accept another level or the roadside.
  return offset.x * offset.x + offset.y * offset.y <= radius * radius and math.abs(offset.z) <= 4
end

local function planRoadDestinations(group, hinges, pos, dir)
  local origin = group.objects[group.root]:getPosition()
  local candidates, cells, segments = {}, {}, {}
  local function addCandidate(position, direction)
    local key = math.floor(position.x / 10 + 0.5) .. ':' .. math.floor(position.y / 10 + 0.5)
      .. ':' .. math.floor(position.z / 10 + 0.5)
    local distance = (position - origin):squaredLength()
    local directions = cells[key]
    if not directions then directions = {}; cells[key] = directions end
    for _, candidate in ipairs(directions) do
      if candidate.dir:dot(direction) > 0.996 * math.sqrt(candidate.dir:squaredLength() * direction:squaredLength()) then
        if distance < candidate.distance then
          candidate.pos, candidate.dir, candidate.distance = position, direction, distance
        end
        return
      end
    end
    local candidate = {pos = position, dir = direction, distance = distance}
    candidates[#candidates + 1], directions[#directions + 1] = candidate, candidate
  end
  addCandidate(pos, dir)
  local nodes = map.getMap() and map.getMap().nodes or {}
  for a, node in pairs(nodes) do
    for b, link in pairs(node.links or {}) do
      local other = nodes[b]
      if other and tostring(a) < tostring(b) and (link.drivability or 1) > 0 then
        local delta = other.pos - node.pos
        local lengthSq = delta:squaredLength()
        if lengthSq > 0.01 then
          segments[#segments + 1] = {start = node.pos, delta = delta, lengthSq = lengthSq,
            startRadius = node.radius or 0, endRadius = other.radius or 0}
        end
        if lengthSq > 1 then
          local t = math.max(0, math.min(1, (origin - node.pos):dot(delta) / lengthSq))
          local closest = node.pos + delta * t
          if (closest - origin):squaredLength() <= ROAD_SEARCH_RADIUS * ROAD_SEARCH_RADIUS then
            local steps = math.ceil(math.sqrt(lengthSq) / 20)
            local range = ROAD_SEARCH_RADIUS / math.sqrt(lengthSq)
            local first = math.max(0, math.floor((t - range) * steps))
            local last = math.min(steps, math.ceil((t + range) * steps))
            addCandidate(closest, delta:dot(dir) < 0 and -delta or delta)
            for step = first, last do
              local candidate = node.pos + delta * (step / steps)
              local distance = (candidate - origin):squaredLength()
              if distance <= ROAD_SEARCH_RADIUS * ROAD_SEARCH_RADIUS then
                addCandidate(candidate, delta:dot(dir) < 0 and -delta or delta)
              end
            end
          end
        end
      end
    end
  end
  table.sort(candidates, function(a, b) return a.distance < b.distance end)
  return coroutine.create(function()
    for index, candidate in ipairs(candidates) do
      if index > 1 and (index - 1) % 40 == 0 then coroutine.yield() end
      local destinations = planDestinations(group, hinges, candidate.pos, candidate.dir, true)
      if destinations and (destinations[group.root]:getColumn(3) - origin):squaredLength() <= ROAD_SEARCH_RADIUS * ROAD_SEARCH_RADIUS
          and destinationOnRoad(destinations[group.root]:getColumn(3), segments) then
        return destinations
      end
    end
    return nil, 'No clear road position large enough for the whole rig was found nearby. Nothing was moved.'
  end)
end

local function startRecovery(group, hinges, destinations, mode, completed)
  local ok, err = pcall(function()
    suppressPoliceSpeedSpike(group.ids)
    for _, id in ipairs(group.ids) do
      moveVehicle(group.objects[id], destinations[id])
    end
    rearmHinges(group, hinges)
  end)
  if not ok then
    suppressPoliceSpeedSpike(group.ids)
    log('E', 'logisticsRecovery', tostring(err))
    return false, 'Recovery could not complete. Your job and vehicles have been retained.'
  end
  if completed then
    pending = {
      group = group,
      destinations = destinations,
      hinges = hinges,
      elapsed = 0,
      completed = completed,
      mode = mode,
    }
  end
  return true
end

local function finishPlan(operation, destinations, reason)
  if not destinations then
    return false, reason or 'Recovery could not complete. Your job and vehicles have been retained.'
  end
  if operation.mode == 'road' then
    if #blockingTraffic(operation.group, destinations) > 0 then
      operation.destinations, operation.elapsed, operation.clearingTraffic = destinations, 0, true
      operation.search = nil
      pending = operation
      return true
    end
    if not placementClear(operation.group, destinations) then
      return false, 'The recovery position is still blocked. Nothing was moved.'
    end
  end
  return startRecovery(operation.group, operation.hinges, destinations, operation.mode, operation.completed)
end

local function validateOperationGroup(operation)
  for _, id in ipairs(operation.group.ids) do
    local allowed, reason = operation.validate(id)
    if not allowed then return false, reason end
    local obj = getObjectByID(id)
    if not obj or (obj:getPosition() - operation.group.original[id]:getColumn(3)):squaredLength() > 1 then
      return false, 'The rig moved while preparing recovery. Nothing was moved.'
    end
  end
  return true
end

local function continueRoadSearch(operation)
  local allowed, why = validateOperationGroup(operation)
  if not allowed then return false, why end
  local ok, destinations, reason = coroutine.resume(operation.search)
  if not ok then
    log('E', 'logisticsRecovery', tostring(destinations))
    return false, 'Recovery could not find a safe road position. Nothing was moved.'
  end
  if coroutine.status(operation.search) ~= 'dead' then
    pending = operation
    return true
  end
  return finishPlan(operation, destinations, reason)
end

function M.recover(vehId, mode, validate, completed)
  if pending or releasing or scanning then return false, 'Please wait for the current recovery to finish.' end
  local group, reason, waiting = M.collect(vehId, {leaveCargo = mode == 'road'})
  if not group then
    if waiting and completed then
      scanning = {vehId = vehId, mode = mode, validate = validate, completed = completed, elapsed = 0}
      return true
    end
    return false, reason
  end
  for _, id in ipairs(group.ids) do
    local ok, why = validate(id)
    if not ok then return false, why end
  end
  if #group.cargoConnections > 0 then
    M.releaseCargo(group.cargoConnections)
    releasing = {
      vehId = vehId, mode = mode, validate = validate, completed = completed,
      connections = group.cargoConnections, elapsed = 0,
    }
    return true
  end
  local root = group.objects[group.root]
  local pos, dir = root:getPosition(), root:getDirectionVector()
  local plannedMode = mode
  if plannedMode == 'road' then
    local roadPos, roadDir, why = roadTarget(pos, dir)
    if not roadPos then return false, why end
    pos, dir = roadPos, roadDir
  end
  dir = vec3(dir.x, dir.y, 0)
  if dir:squaredLength() < 0.01 then dir = vec3(0, 1, 0) end

  local hinges, hingeReason = planHinges(group)
  if not hinges then return false, hingeReason end

  local operation = {group = group, hinges = hinges, mode = plannedMode, completed = completed, validate = validate}
  local destinations, planReason
  if plannedMode ~= 'road' then
    destinations, planReason = planDestinations(group, hinges, pos, dir)
    if not destinations then
      local roadPos, roadDir = roadTarget(root:getPosition(), root:getDirectionVector())
      if roadPos then
        operation.mode, pos = 'road', roadPos
        dir = vec3(roadDir.x, roadDir.y, 0)
        if dir:squaredLength() < 0.01 then dir = vec3(0, 1, 0) end
      end
    end
  end
  if operation.mode == 'road' then
    operation.search = planRoadDestinations(group, hinges, pos, dir)
    return continueRoadSearch(operation)
  end
  return finishPlan(operation, destinations, planReason)
end

function M.update(dtSim)
  if scanning then
    local scan = scanning
    scan.elapsed = scan.elapsed + (dtSim or 0)
    scanning = nil
    local ok, why = M.recover(scan.vehId, scan.mode, scan.validate, scan.completed)
    if scanning then
      scanning.elapsed = scan.elapsed
      if scanning.elapsed >= 2 then
        scanning = nil
        scan.completed(false, 'Load detection is not ready. Nothing was moved and no recovery fee was charged.')
      end
    elseif not ok then
      scan.completed(false, why)
    end
    return
  end
  if releasing then
    local release = releasing
    release.elapsed = release.elapsed + (dtSim or 0)
    local released = M.cargoReleased(release.connections)
    if not released and release.elapsed < 2 then return end
    releasing = nil
    local function finish(success, why)
      if release.completed then release.completed(success, why) end
    end
    if not released then
      finish(false, 'The recovery vehicle could not be unhitched. No recovery fee was charged.')
      return
    end
    M.forgetCargoPairs(release.connections)
    local ok, why = M.recover(release.vehId, release.mode, release.validate, release.completed)
    if not ok then finish(false, why or 'Recovery could not complete. Your job and vehicles have been retained.') end
    return
  end
  if not pending then return end
  local operation = pending
  if operation.search then
    pending = nil
    local ok, why = continueRoadSearch(operation)
    if not ok and operation.completed then operation.completed(false, why) end
    return
  end
  operation.elapsed = operation.elapsed + dtSim
  if operation.clearingTraffic then
    if operation.elapsed < 0.1 then return end
    pending = nil
    local ran, success, why = pcall(function()
      local allowed, reason = validateOperationGroup(operation)
      if not allowed then return false, reason end
      local blocked = blockingTraffic(operation.group, operation.destinations)
      if not operation.trafficRelocated then
        operation.trafficRelocated, operation.elapsed = true, 0
        for _, other in ipairs(blocked) do
          if gameplay_traffic.forceTeleport then
            gameplay_traffic.forceTeleport(other:getID(), operation.destinations[operation.group.root]:getColumn(3))
          end
        end
        pending = operation
        return true
      end
      for _, other in ipairs(blocked) do other:delete() end
      if not placementClear(operation.group, operation.destinations) then
        return false, 'The recovery position is still blocked. Nothing was moved.'
      end
      return startRecovery(operation.group, operation.hinges, operation.destinations, operation.mode, operation.completed)
    end)
    if not ran then
      if operation.completed then operation.completed(false, 'Recovery could not clear the road position. No recovery fee was charged.') end
    elseif not success then
      if operation.completed then operation.completed(false, why or 'The recovery position is still blocked. No recovery fee was charged.') end
    end
    return
  end
  if operation.elapsed < 0.75 then return end
  local ready = true
  for _, id in ipairs(operation.group.ids) do
    local obj = getObjectByID(id)
    if not obj or (obj:getPosition() - operation.destinations[id]:getColumn(3)):squaredLength() > 4
        or obj:getDirectionVectorUp().z < 0.5 then ready = false; break end
  end
  for _, hinge in ipairs(operation.hinges) do
    local attached = false
    for _, pair in ipairs(core_vehicles.attachedCouplers or {}) do
      if (pair[1] == hinge.parent and pair[2] == hinge.id) or (pair[2] == hinge.parent and pair[1] == hinge.id) then
        attached = true
        break
      end
    end
    if not attached then ready = false end
  end
  if ready then
    pending = nil
    suppressPoliceSpeedSpike(operation.group.ids)
    operation.completed(true)
    return
  end
  if operation.elapsed < 4 then return end

  pending = nil
  suppressPoliceSpeedSpike(operation.group.ids)
  if groupUprightOnTerrain(operation.group) then
    rearmHinges(operation.group, operation.hinges)
    operation.completed(true)
    return
  end
  if operation.mode ~= 'road' then
    local ok, why = M.recover(operation.group.root, 'road', function() return true end, operation.completed)
    if ok then return end
    operation.completed(false, why or 'Recovery could not safely place and reconnect the rig. No recovery fee was charged; your jobs remain active.')
    return
  end
  operation.completed(false, 'Recovery could not safely place and reconnect the rig. No recovery fee was charged; your jobs remain active.')
end
return M
