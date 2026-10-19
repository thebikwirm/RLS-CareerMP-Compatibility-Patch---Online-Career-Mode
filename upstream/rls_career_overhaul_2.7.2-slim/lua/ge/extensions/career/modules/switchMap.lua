local M = {}

M.dependencies = {'career_career', 'career_modules_inventory', 'overhaul_maps', 'overhaul_playerVehicles', 'gameplay_walk'}

local triggerName = "switchMaps"
local stagedVehicles = {}
local nextEntryOrder = 0
local walkingInside = false
local panelActive = false
local switchInProgress = false
local manualCarrierAssignments = {}
local nearbySelections = {}
local nearbyCandidates = {}
local stagingRefreshPending = false

-- Vehicle replacement briefly unregisters the old object. Use native object
-- lookups in this module: global getObjectByID caches misses, which can make
-- BeamNG's subsequent vehicleSpawned callback return before dispatching hooks.

local function isUncoupledNearbyVehicle(vehId)
  for _, connection in ipairs(core_vehicles and core_vehicles.attachedCouplers or {}) do
    if connection[1] == vehId or connection[2] == vehId then return false end
  end
  return true
end

local function withinCarrierRange(childId, carrierId)
  local child, carrier = be:getObjectByID(childId), be:getObjectByID(carrierId)
  if not child or not carrier or not be:getObjectOOBBIsInitialized(carrierId) then return false end
  local delta = child:getPosition() - vec3(be:getObjectOOBBCenterXYZ(carrierId))
  local distanceSquared = 0
  for axis = 0, 2 do
    local halfAxis = vec3(be:getObjectOOBBHalfAxisXYZ(carrierId, axis))
    local length = halfAxis:length()
    if length <= 0 then return false end
    local outside = math.max(0, math.abs(delta:dot(halfAxis) / length) - length)
    distanceSquared = distanceSquared + outside * outside
  end
  return distanceSquared <= 64
end

local carrierTokens = {
  "flatbed", "rollback", "tiltdeck", "carcarrier", "car_hauler",
  "dryvan", "boxutility", "containertrailer",
}

local function isPersonalInventoryId(inventoryId)
  if type(inventoryId) ~= "number" and not (type(inventoryId) == "string" and tonumber(inventoryId)) then
    return false
  end
  local vehicle = career_modules_inventory.getVehicle(inventoryId)
  return vehicle and vehicle.owned ~= false and vehicle.loanType == nil
end

local function getEligibleInventoryId(vehId, sessionIds)
  vehId = tonumber(vehId)
  if not vehId then return nil end
  local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
  return (sessionIds and sessionIds[inventoryId] or isPersonalInventoryId(inventoryId)) and inventoryId or nil
end

local function getVehicleLabel(inventoryId)
  return career_modules_inventory.getVehicleNiceNameTranslated(inventoryId) or ("Vehicle " .. tostring(inventoryId))
end

local function isWalkingSubject(subjectId)
  return subjectId == be:getPlayerVehicleID(0)
    and gameplay_walk
    and gameplay_walk.isWalking
    and gameplay_walk.isWalking()
end

local function containsCarrierToken(value, depth)
  depth = depth or 0
  if depth > 5 then return false end
  if type(value) == "string" then
    local normalized = value:lower()
    for _, token in ipairs(carrierTokens) do
      if normalized:find(token, 1, true) then return true end
    end
    return false
  end
  if type(value) ~= "table" then return false end
  for key, child in pairs(value) do
    if containsCarrierToken(key, depth + 1) or containsCarrierToken(child, depth + 1) then return true end
  end
  return false
end

local function isCarrierVehicle(vehId, inventoryId)
  local object = be:getObjectByID(vehId)
  local inventoryVehicle = career_modules_inventory.getVehicle(inventoryId) or {}
  if object then
    if object.getJBeamFilename and containsCarrierToken(object:getJBeamFilename()) then return true end
    if object.getVehicleConfigName and containsCarrierToken(object:getVehicleConfigName()) then return true end
  end
  return containsCarrierToken(inventoryVehicle.model) or containsCarrierToken(inventoryVehicle.config)
end

local function isVehicleOnCarrier(childId, carrierId)
  if childId == carrierId or not be.getObjectOOBBIsInitialized
      or not be:getObjectOOBBIsInitialized(childId)
      or not be:getObjectOOBBIsInitialized(carrierId) then
    return false
  end

  local child = be:getObjectByID(childId)
  local carrier = be:getObjectByID(carrierId)
  if not child or not carrier then return false end
  local childVelocity = child:getVelocity()
  local carrierVelocity = carrier:getVelocity()
  if childVelocity and carrierVelocity and (childVelocity - carrierVelocity):squaredLength() > 6.25 then return false end

  local carrierCenter = vec3(be:getObjectOOBBCenterXYZ(carrierId))
  local childCenter = vec3(be:getObjectOOBBCenterXYZ(childId))
  local delta = childCenter - carrierCenter
  local axes = {
    vec3(be:getObjectOOBBHalfAxisXYZ(carrierId, 0)),
    vec3(be:getObjectOOBBHalfAxisXYZ(carrierId, 1)),
    vec3(be:getObjectOOBBHalfAxisXYZ(carrierId, 2)),
  }

  local upIndex, upAmount = 1, -1
  for index = 1, 3 do
    local amount = math.abs(axes[index].z)
    if amount > upAmount then
      upIndex, upAmount = index, amount
    end
  end

  for index = 1, 3 do
    local half = axes[index]:length()
    if half < 0.25 then return false end
    local along = delta:dot(axes[index] / half)
    if index == upIndex then
      if along < -(half * 0.05) or along > half + 0.55 then return false end
    else
      local inset = half > 4 and 1.15 or 0.65
      if math.abs(along) > math.max(0.45, half - inset) then return false end
    end
  end
  return true
end

local function getActivePersonalVehicles(sessionIds)
  local result = {}
  local inventoryMap = career_modules_inventory.getMapInventoryIdToVehId()
  for inventoryId, vehId in pairs(inventoryMap or {}) do
    inventoryId = tonumber(inventoryId)
    vehId = tonumber(vehId)
    local object = vehId and be:getObjectByID(vehId) or nil
    if inventoryId and object and object:getActive() and (sessionIds and sessionIds[inventoryId] or isPersonalInventoryId(inventoryId)) then
      result[inventoryId] = vehId
    end
  end
  return result
end

local function captureRelativeOffset(childInventoryId, carrierInventoryId)
  local childId = career_modules_inventory.getVehicleIdFromInventoryId(childInventoryId)
  local carrierId = career_modules_inventory.getVehicleIdFromInventoryId(carrierInventoryId)
  local child = childId and be:getObjectByID(childId) or nil
  local carrier = carrierId and be:getObjectByID(carrierId) or nil
  if not child or not carrier then return nil end

  local ok, offset = pcall(function()
    local matrix = carrier:getRefNodeMatrix():inverse() * child:getRefNodeMatrix()
    local pos = matrix:getPosition()
    local rot = matrix:toEuler()
    return {
      x = pos.x, y = pos.y, z = pos.z,
      rx = rot.x, ry = rot.y, rz = rot.z,
    }
  end)
  return ok and offset or nil
end

local function pruneStagedVehicles()
  for vehId, entry in pairs(stagedVehicles) do
    local object = be:getObjectByID(vehId)
    local inventoryId = object and object:getActive() and getEligibleInventoryId(vehId) or nil
    if not inventoryId or inventoryId ~= entry.inventoryId then
      stagedVehicles[vehId] = nil
    end
  end
end

local function captureTreeNode(entry, parentInventoryId, sessionIds)
  if not entry then return nil end
  local inventoryId = getEligibleInventoryId(entry.vehId, sessionIds)
  if not inventoryId then return nil end

  local node = {
    inventoryId = inventoryId,
    label = getVehicleLabel(inventoryId),
    coupledParentInventoryId = parentInventoryId,
    children = {},
  }
  if entry.offsetData then
    node.parentNode = entry.offsetData.parentNode
    node.node = entry.offsetData.node
    node.couplerOffset = parentInventoryId and captureRelativeOffset(inventoryId, parentInventoryId) or nil
  end
  for _, child in ipairs(entry.children or {}) do
    local childNode = captureTreeNode(child, inventoryId, sessionIds)
    if childNode then
      node.children[#node.children + 1] = childNode
    end
  end
  table.sort(node.children, function(a, b) return tostring(a.inventoryId) < tostring(b.inventoryId) end)
  return node
end

local function flattenTree(node, into, depth, order)
  if not node then return end
  into[#into + 1] = {
    inventoryId = node.inventoryId,
    label = node.label,
    depth = depth or 0,
    coupledParentInventoryId = node.coupledParentInventoryId,
    order = order,
  }
  for _, child in ipairs(node.children or {}) do
    flattenTree(child, into, (depth or 0) + 1, order)
  end
end

local function markTreeSeen(node, seen)
  if not node then return end
  seen[node.inventoryId] = true
  for _, child in ipairs(node.children or {}) do
    markTreeSeen(child, seen)
  end
end

local function removeAssignmentCycles(assignments, assignmentSources)
  while true do
    local ids = {}
    for inventoryId in pairs(assignments) do ids[#ids + 1] = inventoryId end
    table.sort(ids)
    local removed
    for _, inventoryId in ipairs(ids) do
      local path = {}
      local pathIndex = {}
      local cursor = inventoryId
      while cursor and assignments[cursor] do
        if pathIndex[cursor] then
          local removeId
          for index = pathIndex[cursor], #path do
            local candidate = path[index]
            if assignmentSources[candidate] == "auto" and (not removeId or candidate < removeId) then
              removeId = candidate
            end
          end
          removeId = removeId or cursor
          assignments[removeId] = nil
          assignmentSources[removeId] = nil
          removed = true
          break
        end
        path[#path + 1] = cursor
        pathIndex[cursor] = #path
        cursor = assignments[cursor]
      end
      if removed then break end
    end
    if not removed then return end
  end
end

local function getGroups(sourceVehicles, sessionIds)
  if not sourceVehicles then pruneStagedVehicles() end
  local entries = {}
  for vehId, entry in pairs(sourceVehicles or stagedVehicles) do
    entries[#entries + 1] = {
      vehId = vehId,
      inventoryId = entry.inventoryId,
      order = entry.order,
    }
  end
  table.sort(entries, function(a, b) return a.order < b.order end)

  local groups = {}
  local seen = {}
  local coupledGroupByInventoryId = {}
  local playerVehId = be:getPlayerVehicleID(0)
  local walking = gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking()
  local playerInventoryId = not walking and getEligibleInventoryId(playerVehId, sessionIds) or nil

  for _, entry in ipairs(entries) do
    if not seen[entry.inventoryId] then
      local coupledIds = {}
      if overhaul_playerVehicles and overhaul_playerVehicles.fillCouplerGroup then
        local ok = pcall(overhaul_playerVehicles.fillCouplerGroup, entry.vehId, coupledIds, {resolveLead = true})
        if not ok then coupledIds[1] = entry.vehId end
      else
        coupledIds[1] = entry.vehId
      end

      local rootVehId = coupledIds[1] or entry.vehId
      local rootInventoryId = getEligibleInventoryId(rootVehId, sessionIds)
      local tree
      if rootInventoryId and core_vehicles and core_vehicles.generateAttachedVehiclesTree then
        local ok, generated = pcall(core_vehicles.generateAttachedVehiclesTree, rootVehId)
        if ok and generated then
          tree = captureTreeNode(generated, nil, sessionIds)
        end
      end
      if not tree then
        tree = {
          inventoryId = entry.inventoryId,
          label = getVehicleLabel(entry.inventoryId),
          children = {},
        }
        rootVehId = entry.vehId
      end

      local members = {}
      flattenTree(tree, members, 0, entry.order)
      markTreeSeen(tree, seen)
      local containsPlayer = false
      if playerInventoryId then
        for _, member in ipairs(members) do
          if member.inventoryId == playerInventoryId then
            containsPlayer = true
            break
          end
        end
      end
      groups[#groups + 1] = {
        rootInventoryId = tree.inventoryId,
        order = entry.order,
        current = containsPlayer,
        members = members,
        tree = tree,
      }
      for _, member in ipairs(members) do
        coupledGroupByInventoryId[member.inventoryId] = tree.inventoryId
      end
    end
  end

  local activeVehicles = getActivePersonalVehicles(sessionIds)
  local autoAssignments = {}
  local carrierIds = {}
  for inventoryId in pairs(seen) do
    local vehId = activeVehicles[inventoryId]
    if vehId and isCarrierVehicle(vehId, inventoryId) then
      carrierIds[#carrierIds + 1] = inventoryId
    end
  end
  table.sort(carrierIds)

  local autoAdded = {}
  if not sourceVehicles then
    for childId, parentId in pairs(nearbySelections) do
      if not seen[childId] and seen[parentId] and activeVehicles[childId] and activeVehicles[parentId]
          and isCarrierVehicle(activeVehicles[parentId], parentId)
          and withinCarrierRange(activeVehicles[childId], activeVehicles[parentId]) then
        autoAssignments[childId] = parentId
        autoAdded[#autoAdded + 1] = childId
      end
    end
  end
  for childInventoryId, childVehId in pairs(activeVehicles) do
    local bestCarrierId, bestDistance
    for _, carrierInventoryId in ipairs(carrierIds) do
      if childInventoryId ~= carrierInventoryId
          and coupledGroupByInventoryId[childInventoryId] ~= coupledGroupByInventoryId[carrierInventoryId]
          and isVehicleOnCarrier(childVehId, activeVehicles[carrierInventoryId]) then
        local child = be:getObjectByID(childVehId)
        local carrier = be:getObjectByID(activeVehicles[carrierInventoryId])
        local distance = child and carrier and (child:getPosition() - carrier:getPosition()):squaredLength() or math.huge
        if not bestDistance or distance < bestDistance then
          bestCarrierId = carrierInventoryId
          bestDistance = distance
        end
      end
    end
    if bestCarrierId then
      autoAssignments[childInventoryId] = bestCarrierId
      if not seen[childInventoryId] and not (not sourceVehicles and nearbySelections[childInventoryId]) then
        autoAdded[#autoAdded + 1] = childInventoryId
      end
    end
  end

  table.sort(autoAdded)
  local autoOrder = nextEntryOrder
  for _, inventoryId in ipairs(autoAdded) do
    autoOrder = autoOrder + 1
    local order = autoOrder
    local tree = {
      inventoryId = inventoryId,
      label = getVehicleLabel(inventoryId),
      children = {},
    }
    local members = {}
    flattenTree(tree, members, 0, order)
    groups[#groups + 1] = {
      rootInventoryId = inventoryId,
      order = order,
      current = playerInventoryId == inventoryId,
      members = members,
      tree = tree,
    }
    seen[inventoryId] = true
    coupledGroupByInventoryId[inventoryId] = inventoryId
  end

  local assignments = {}
  local assignmentSources = {}
  for childInventoryId, carrierInventoryId in pairs(autoAssignments) do
    if seen[childInventoryId] and seen[carrierInventoryId] then
      assignments[childInventoryId] = carrierInventoryId
      assignmentSources[childInventoryId] = "auto"
    end
  end
  for childInventoryId, carrierInventoryId in pairs(manualCarrierAssignments) do
    if not seen[childInventoryId] then
      manualCarrierAssignments[childInventoryId] = nil
    elseif carrierInventoryId == 0 then
      assignments[childInventoryId] = nil
      assignmentSources[childInventoryId] = nil
    elseif seen[carrierInventoryId] and childInventoryId ~= carrierInventoryId
        and coupledGroupByInventoryId[childInventoryId] ~= coupledGroupByInventoryId[carrierInventoryId] then
      assignments[childInventoryId] = carrierInventoryId
      assignmentSources[childInventoryId] = "manual"
    else
      manualCarrierAssignments[childInventoryId] = nil
    end
  end
  removeAssignmentCycles(assignments, assignmentSources)

  table.sort(groups, function(a, b)
    if a.current ~= b.current then return a.current end
    return a.order < b.order
  end)
  return groups, assignments, assignmentSources
end

local function canTravel()
  if switchInProgress then return false end
  local playerVehId = tonumber(be:getPlayerVehicleID(0))
  if isWalkingSubject(playerVehId) then
    return walkingInside
  end
  return playerVehId and stagedVehicles[playerVehId] ~= nil and getEligibleInventoryId(playerVehId) ~= nil
end

local function getStagingData()
  local ok, groups, assignments, assignmentSources = pcall(getGroups)
  if not ok then
    log("E", "switchMap", "getGroups failed: " .. tostring(groups))
    groups = {}
    assignments = {}
    assignmentSources = {}
  end
  local vehicleCount = 0
  local uiGroups = {}
  local uiVehicles = {}
  local listed = {}
  for _, group in ipairs(groups) do
    vehicleCount = vehicleCount + #group.members
    uiGroups[#uiGroups + 1] = {
      rootInventoryId = group.rootInventoryId,
      current = group.current,
      members = group.members,
    }
    for _, member in ipairs(group.members) do
      if not listed[member.inventoryId] then
        listed[member.inventoryId] = true
        uiVehicles[#uiVehicles + 1] = {
          inventoryId = member.inventoryId,
          label = member.label,
          current = group.current and member.depth == 0,
          order = group.order,
          coupledParentInventoryId = member.coupledParentInventoryId,
          carrierInventoryId = assignments[member.inventoryId],
          carrierSource = assignmentSources[member.inventoryId],
          nearbySelected = nearbySelections[member.inventoryId] ~= nil,
        }
      end
    end
  end
  local playerVehId = tonumber(be:getPlayerVehicleID(0))
  if panelActive and vehicleCount == 0 and not walkingInside
      and not (playerVehId and stagedVehicles[playerVehId]) then
    panelActive = false
  end
  return {
    visible = panelActive,
    walkingInside = walkingInside,
    canTravel = canTravel(),
    switching = switchInProgress,
    vehicleCount = vehicleCount,
    groupCount = #uiGroups,
    groups = uiGroups,
    vehicles = uiVehicles,
    nearbyVehicles = nearbyCandidates,
  }
end

local function publishStagingData()
  stagingRefreshPending = false
  local data = getStagingData()
  guihooks.trigger("MapTravelStaging", data)
  return data
end

local function refreshNearby()
  nearbyCandidates = {}
  if not panelActive or switchInProgress then return publishStagingData() end
  local groups = getGroups()
  local active = getActivePersonalVehicles()
  local listed, carriers = {}, {}
  for _, group in ipairs(groups) do
    for _, member in ipairs(group.members) do
      local id = member.inventoryId
      listed[id] = true
      if not nearbySelections[id] and active[id] and isCarrierVehicle(active[id], id) then carriers[id] = active[id] end
    end
  end
  for id, vehId in pairs(active) do
    if not listed[id] and isUncoupledNearbyVehicle(vehId) then
      local options = {}
      for parentId, parentVehId in pairs(carriers) do
        if withinCarrierRange(vehId, parentVehId) then
          options[#options + 1] = {value = parentId, label = getVehicleLabel(parentId)}
        end
      end
      table.sort(options, function(a, b) return a.value < b.value end)
      if #options > 0 then nearbyCandidates[#nearbyCandidates + 1] = {inventoryId = id, label = getVehicleLabel(id), carriers = options} end
    end
  end
  table.sort(nearbyCandidates, function(a, b) return a.inventoryId < b.inventoryId end)
  for id in pairs(nearbySelections) do
    if not listed[id] then
      nearbyCandidates[#nearbyCandidates + 1] = {inventoryId = id, label = getVehicleLabel(id), invalidSelection = true, carriers = {}}
    end
  end
  return publishStagingData()
end

local function buildManifest(levelName, sourceVehicles, sessionIds)
  local groups, assignments, assignmentSources = getGroups(sourceVehicles, sessionIds)
  local manifestGroups = {}
  local carriedVehicles = {}
  local currentInventoryId
  for _, group in ipairs(groups) do
    manifestGroups[#manifestGroups + 1] = {
      rootInventoryId = group.rootInventoryId,
      order = group.order,
      current = group.current,
      tree = group.tree,
    }
    if group.current then
      currentInventoryId = group.rootInventoryId
    end
  end

  for childInventoryId, carrierInventoryId in pairs(assignments) do
    local offset = captureRelativeOffset(childInventoryId, carrierInventoryId)
    if offset then
      carriedVehicles[#carriedVehicles + 1] = {
        inventoryId = childInventoryId,
        parentInventoryId = carrierInventoryId,
        source = assignmentSources[childInventoryId],
        offset = offset,
        brake = 0,
        parkingbrake = 0,
      }
    end
  end
  table.sort(carriedVehicles, function(a, b) return a.inventoryId < b.inventoryId end)

  return {
    version = 2,
    source = getCurrentLevelIdentifier(),
    destination = levelName,
    walking = gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking() or false,
    currentInventoryId = currentInventoryId,
    groups = manifestGroups,
    carriedVehicles = carriedVehicles,
  }
end

local function captureBrakeStates(entries, callback)
  if #entries == 0 then callback() return end
  local pending = #entries * 2
  local finished = false
  local function completeOne()
    if finished then return end
    pending = pending - 1
    if pending <= 0 then
      finished = true
      callback()
    end
  end

  for _, entry in ipairs(entries) do
    local vehId = career_modules_inventory.getVehicleIdFromInventoryId(entry.inventoryId)
    local veh = vehId and be:getObjectByID(vehId) or nil
    if veh then
      local brakeRequested = pcall(function()
        core_vehicleBridge.requestValue(veh, function(result)
          entry.brake = clamp(tonumber(result and result.result) or 0, 0, 1)
          completeOne()
        end, "electricsValue", "brake_input")
      end)
      if not brakeRequested then completeOne() end
      local parkingBrakeRequested = pcall(function()
        core_vehicleBridge.requestValue(veh, function(result)
          entry.parkingbrake = clamp(tonumber(result and result.result) or 0, 0, 1)
          completeOne()
        end, "electricsValue", "parkingbrake_input")
      end)
      if not parkingBrakeRequested then completeOne() end
    else
      completeOne()
      completeOne()
    end
  end

  core_jobsystem.create(function(job)
    job.sleep(0.5)
    if not finished then
      finished = true
      callback()
    end
  end)
end

local function performSwitch(levelName, manifest)
  career_modules_inventory.prepareMapTravel(manifest)
  local switchOk, accepted, reason = pcall(career_career.switchCareerLevel, levelName)
  if not switchOk then
    reason = accepted
    accepted = false
  end
  if accepted then
    panelActive = false
    publishStagingData()
    gameplay_parking.resetAll()
    return
  end

  switchInProgress = false
  career_modules_inventory.clearPreparedMapTravel()
  guihooks.trigger("toastrMsg", {
    type = "error",
    title = "Map travel unavailable",
    msg = tostring(reason or "The destination could not be loaded."),
  })
  publishStagingData()
end

local TRAVEL_BLOCKED_MESSAGE = 'Finish or cancel Broker work and return rented equipment before travelling to another map.'

local function getTravelBlockers()
  local broker = career_modules_delivery_broker
  if not (broker and broker.hasObligations and broker.hasObligations()) then return nil end
  if broker.getObligations then return broker.getObligations() end
  return {jobs = {}, rentals = {}, totalFine = 0, count = 1}
end

local function publishTravelBlocked(levelName, blockers, message)
  guihooks.trigger("MapTravelBlocked", {
    destination = levelName,
    blockers = blockers or {jobs = {}, rentals = {}, totalFine = 0, count = 0},
    message = message,
  })
end

local function switchMap(levelName)
  local blockers = getTravelBlockers()
  if blockers then
    publishTravelBlocked(levelName, blockers)
    return false, TRAVEL_BLOCKED_MESSAGE
  end
  local currentLevel = getCurrentLevelIdentifier()
  if currentLevel == levelName then return false, "Already in the requested destination" end
  if not canTravel() then return false, "Return to the map travel area before travelling" end

  local groups, assignments = getGroups()
  local active = getActivePersonalVehicles()
  for childId, parentId in pairs(nearbySelections) do
    if assignments[childId] ~= parentId or not active[childId] or not active[parentId]
        or not withinCarrierRange(active[childId], active[parentId])
        or not isUncoupledNearbyVehicle(active[childId]) then
      refreshNearby()
      return false, "A nearby load is no longer within range of its carrier. Remove it or move it closer."
    end
  end

  local manifest = buildManifest(levelName)
  switchInProgress = true
  publishStagingData()
  captureBrakeStates(manifest.carriedVehicles, function() performSwitch(levelName, manifest) end)
  return true
end

local function resolveTravelBlockers(levelName)
  local broker = career_modules_delivery_broker
  if not (broker and broker.clearObligations) then return false, TRAVEL_BLOCKED_MESSAGE end
  if not getTravelBlockers() then return switchMap(levelName) end
  local ok, message = broker.clearObligations(function(success, failures)
    if not success then
      publishTravelBlocked(levelName, getTravelBlockers(), table.concat(failures or {}, ' '))
      return
    end
    local accepted, reason = switchMap(levelName)
    if not accepted then
      local remaining = getTravelBlockers()
      if remaining then
        publishTravelBlocked(levelName, remaining, tostring(reason or TRAVEL_BLOCKED_MESSAGE))
      else
        guihooks.trigger("toastrMsg", {type = "warning", title = "Map travel", msg = tostring(reason or TRAVEL_BLOCKED_MESSAGE)})
        publishStagingData()
      end
    end
  end)
  if not ok then publishTravelBlocked(levelName, getTravelBlockers(), message) end
  return ok, message
end

local function setCarrierAssignment(childInventoryId, carrierInventoryId)
  childInventoryId = tonumber(childInventoryId)
  carrierInventoryId = tonumber(carrierInventoryId)
  if not childInventoryId or not carrierInventoryId or childInventoryId == carrierInventoryId then return false end

  local groups, assignments = getGroups()
  local listed = {}
  local coupledGroupByInventoryId = {}
  for _, group in ipairs(groups) do
    for _, member in ipairs(group.members) do
      listed[member.inventoryId] = true
      coupledGroupByInventoryId[member.inventoryId] = group.rootInventoryId
    end
  end
  if not listed[childInventoryId] and listed[carrierInventoryId] and not nearbySelections[carrierInventoryId]
      and panelActive and not switchInProgress then
    local active = getActivePersonalVehicles()
    if active[childInventoryId] and active[carrierInventoryId] and isUncoupledNearbyVehicle(active[childInventoryId])
        and isCarrierVehicle(active[carrierInventoryId], carrierInventoryId)
        and withinCarrierRange(active[childInventoryId], active[carrierInventoryId]) then
      nearbySelections[childInventoryId] = carrierInventoryId
      manualCarrierAssignments[childInventoryId] = carrierInventoryId
      refreshNearby()
      return true
    end
  end
  if not listed[childInventoryId] or not listed[carrierInventoryId]
      or coupledGroupByInventoryId[childInventoryId] == coupledGroupByInventoryId[carrierInventoryId] then
    return false
  end

  local ancestor = carrierInventoryId
  local visited = {}
  while ancestor do
    if ancestor == childInventoryId or visited[ancestor] then return false end
    visited[ancestor] = true
    ancestor = assignments[ancestor]
  end
  if nearbySelections[childInventoryId] then
    local active = getActivePersonalVehicles()
    if nearbySelections[carrierInventoryId] or not active[childInventoryId] or not active[carrierInventoryId]
        or not isCarrierVehicle(active[carrierInventoryId], carrierInventoryId)
        or not withinCarrierRange(active[childInventoryId], active[carrierInventoryId]) then return false end
    nearbySelections[childInventoryId] = carrierInventoryId
  end
  manualCarrierAssignments[childInventoryId] = carrierInventoryId
  publishStagingData()
  return true
end

local function clearCarrierAssignment(childInventoryId)
  childInventoryId = tonumber(childInventoryId)
  if not childInventoryId then return false end
  if nearbySelections[childInventoryId] then
    nearbySelections[childInventoryId] = nil
    manualCarrierAssignments[childInventoryId] = nil
    refreshNearby()
    return true
  end
  manualCarrierAssignments[childInventoryId] = 0
  publishStagingData()
  return true
end

local function cancelSwitch()
  panelActive = false
  publishStagingData()
end

local function openForTester()
  if not (career_career and career_career.isActive()) then
    return false, "Career is not active."
  end
  local obj = scenetree and scenetree.findObject and scenetree.findObject(triggerName)
  if not obj then
    return false, "No map switcher trigger on this level."
  end
  local pos = obj:getPosition()
  local veh = getPlayerVehicle(0)
  if veh and spawn and spawn.safeTeleport then
    spawn.safeTeleport(veh, pos)
  end
  local playerVehId = tonumber(be:getPlayerVehicleID(0))
  local inventoryId = playerVehId and getEligibleInventoryId(playerVehId) or nil
  if inventoryId then
    if not stagedVehicles[playerVehId] then
      nextEntryOrder = nextEntryOrder + 1
      stagedVehicles[playerVehId] = {inventoryId = inventoryId, order = nextEntryOrder}
    end
  elseif gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking() then
    walkingInside = true
  end
  panelActive = true
  publishStagingData()
  return true
end

local function onRouteLeave()
  simTimeAuthority.pause(false)
end

local function onBeamNGTrigger(data)
  if not data or data.triggerName ~= triggerName or not career_career.isActive() then return end
  if data.event ~= "enter" and data.event ~= "exit" then return end

  local subjectId = tonumber(data.subjectID)
  if not subjectId then return end

  local entering = data.event == "enter"
  local playerSubject = subjectId == tonumber(be:getPlayerVehicleID(0))
  if playerSubject and isWalkingSubject(subjectId) then
    walkingInside = entering
    if entering then panelActive = true end
  else
    local inventoryId = getEligibleInventoryId(subjectId)
    if entering and inventoryId then
      if not stagedVehicles[subjectId] then
        nextEntryOrder = nextEntryOrder + 1
        stagedVehicles[subjectId] = {inventoryId = inventoryId, order = nextEntryOrder}
      end
      if playerSubject then panelActive = true end
    elseif not entering then
      stagedVehicles[subjectId] = nil
    end
  end
  publishStagingData()
end

local function resetStaging()
  table.clear(nearbySelections)
  nearbyCandidates = {}
  table.clear(stagedVehicles)
  table.clear(manualCarrierAssignments)
  nextEntryOrder = 0
  walkingInside = false
  panelActive = false
  switchInProgress = false
  publishStagingData()
end

local function onVehicleDestroyed(vehId)
  if stagedVehicles[vehId] then
    stagedVehicles[vehId] = nil
    stagingRefreshPending = true
  end
end

local function onVehicleSwitched(_, _, player)
  if player == nil or player == 0 then
    if not (gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking()) then
      walkingInside = false
    end
    -- Do not scan inventory in the detach/reattach gap of a vehicle rebuild.
    -- Coalesce both switch notifications into a refresh on the next update.
    stagingRefreshPending = true
  end
end

local function onUpdate()
  if stagingRefreshPending then publishStagingData() end
end

local function onCareerActive(active)
  if not active then resetStaging() end
end

local function onClientEndMission()
  resetStaging()
end

function M.onGetRawPoiListForLevel(levelIdentifier, elements)
  if not (career_career and career_career.isActive()) then return end
  local switchObject = scenetree.findObject(triggerName)
  if not switchObject then return end

  local pos = switchObject:getPosition()
  if not pos then return end

  local mapRows = {}
  for _, levelName in pairs(overhaul_maps.getOtherAvailableMaps(levelIdentifier)) do
    mapRows[#mapRows + 1] = levelName
  end
  table.sort(mapRows, function(a, b) return string.lower(a) < string.lower(b) end)
  if #mapRows == 0 then return end

  local description = "Available maps to switch to:\n"
  for _, levelName in ipairs(mapRows) do
    description = description .. "- " .. levelName .. "\n"
  end

  elements[#elements + 1] = {
    id = "map_switcher",
    data = {type = "travel", facility = {}},
    markerInfo = {
      bigmapMarker = {
        pos = pos,
        icon = "poi_fasttravel_round_orange_green",
        name = "Map Switcher",
        description = description,
        previews = {"/levels/" .. levelIdentifier .. "/facilities/switchMap.jpg"},
        thumbnail = "/levels/" .. levelIdentifier .. "/facilities/switchMap.jpg",
        cardIcon = "fastTravel",
      }
    }
  }
end

M.captureInventoryRelationships = function(inventoryIds)
  local entries, sessionIds = {}, {}
  local employment = career_modules_delivery_employment
  for inventoryId in pairs(inventoryIds) do
    inventoryId = tonumber(inventoryId)
    local info = inventoryId and career_modules_inventory.getVehicle(inventoryId)
    if inventoryId and ((info and (info.logisticsInUse or info.brokerRentalId or info.brokerJobId)) or (employment and employment.shouldPersistVehicle
        and employment.shouldPersistVehicle(inventoryId))) then sessionIds[inventoryId] = true end
  end
  for inventoryId, vehId in pairs(getActivePersonalVehicles(sessionIds)) do
    if inventoryIds[inventoryId] or inventoryIds[tostring(inventoryId)] then
      entries[vehId] = {inventoryId = inventoryId, order = tonumber(inventoryId) or 0}
    end
  end
  local manifest = buildManifest(getCurrentLevelIdentifier(), entries, sessionIds)
  local groups = {}
  local function allowed(id) return inventoryIds[id] or inventoryIds[tostring(id)] end
  local function filterNode(node)
    local children = {}
    for _, child in ipairs(node.children or {}) do
      local kept = filterNode(child)
      if kept then children[#children + 1] = kept end
    end
    if not allowed(node.inventoryId) then
      for _, child in ipairs(children) do
        child.coupledParentInventoryId = nil
        child.couplerOffset = nil
        groups[#groups + 1] = {tree = child, rootInventoryId = child.inventoryId}
      end
      return nil
    end
    node.children = children
    return node
  end
  for _, group in ipairs(manifest.groups) do
    if filterNode(group.tree) then groups[#groups + 1] = group end
  end
  manifest.groups = groups
  local carried = {}
  for _, relation in ipairs(manifest.carriedVehicles) do
    if allowed(relation.inventoryId) and allowed(relation.parentInventoryId) then carried[#carried + 1] = relation end
  end
  manifest.carriedVehicles = carried
  manifest.brakeStates = {}
  local function collectBrakes(node)
    manifest.brakeStates[#manifest.brakeStates + 1] = node
    for _, child in ipairs(node.children or {}) do collectBrakes(child) end
  end
  for _, group in ipairs(groups) do collectBrakes(group.tree) end
  for _, relation in ipairs(carried) do manifest.brakeStates[#manifest.brakeStates + 1] = relation end
  return manifest
end
M.captureRelationshipBrakes = captureBrakeStates
M.switchMap = switchMap
M.getTravelBlockers = getTravelBlockers
M.resolveTravelBlockers = resolveTravelBlockers
M.openForTester = openForTester
M.setCarrierAssignment = setCarrierAssignment
M.refreshNearby = refreshNearby
M.clearCarrierAssignment = clearCarrierAssignment
M.cancelSwitch = cancelSwitch
M.onRouteLeave = onRouteLeave
M.requestStagingData = publishStagingData
M.onBeamNGTrigger = onBeamNGTrigger
M.onVehicleDestroyed = onVehicleDestroyed
M.onVehicleSwitched = onVehicleSwitched
M.onUpdate = onUpdate
M.onCareerActive = onCareerActive
M.onClientEndMission = onClientEndMission
M.onUiReady = publishStagingData

return M
