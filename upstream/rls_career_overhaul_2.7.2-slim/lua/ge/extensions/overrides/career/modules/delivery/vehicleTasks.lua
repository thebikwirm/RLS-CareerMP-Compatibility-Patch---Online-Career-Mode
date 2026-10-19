-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
M.dependencies = {"util_stepHandler"}
local dParcelManager, dCargoScreen, dGeneral, dGenerator, dProgress, dTasklist, dTutorial, dPrecisionParking
local step
M.onCareerActivated = function()
  dParcelManager = career_modules_delivery_parcelManager
  dCargoScreen = career_modules_delivery_cargoScreen
  dGeneral = career_modules_delivery_general
  dGenerator = career_modules_delivery_generator
  dProgress = career_modules_delivery_progress
  dTasklist = career_modules_delivery_tasklist
  dTutorial = career_modules_delivery_tutorial
  dPrecisionParking = career_modules_delivery_precisionParking
  step = util_stepHandler
end

local vehicleTasks = {}
local taskThatChangedThisFrame
local tasklistRefreshPending = false

-- Keep this in sync with delivery/tasklist.lua. Vehicle task entries use a
-- stable UI id, while the task-list module's offer-id lookup can be stale when
-- a coupled dolly is deleted during its completion callback.
local function clearVehicleTasklistEntry(taskData)
  if not taskData or not taskData.offer then return end
  if dTasklist and dTasklist.clearTasklistForOfferId then
    dTasklist.clearTasklistForOfferId(taskData.offer.id)
  end
  guihooks.trigger("DiscardTasklistItem", "trailer" .. tostring(taskData.offer.id))
  tasklistRefreshPending = true
end

local function offerDestination(offer)
  if not offer then return nil end
  local task = offer.task
  return (task and (task.dropOff or task.destination))
    or offer.destination
    or (offer.locations and offer.locations[2])
end

local function employmentShiftDestination()
  local emp = career_modules_delivery_employment
  if emp and emp.getShiftDestLocation then
    return emp.getShiftDestLocation()
  end
  return nil
end

local function resolveVehicleDestination(taskData, prefer)
  local candidates = {
    prefer,
    taskData and taskData.tasks and taskData.tasks[2] and taskData.tasks[2].destination,
    taskData and taskData.tasks and taskData.tasks[3] and taskData.tasks[3].destination,
    offerDestination(taskData and taskData.offer),
    employmentShiftDestination(),
  }
  for _, dest in ipairs(candidates) do
    if dest and dest.psPath and dGenerator and dGenerator.getParkingSpotByPath
        and dGenerator.getParkingSpotByPath(dest.psPath) then
      return dest
    end
  end
  for _, dest in ipairs(candidates) do
    if dest and (dest.psPath or dest.facId) then
      return dest
    end
  end
  return nil
end

local function isEmploymentJockeyShift()
  local emp = career_modules_delivery_employment
  return emp and emp.isJockeyShift and emp.isJockeyShift() or false
end

local function isBundleFlatbedPending()
  local emp = career_modules_delivery_employment
  return emp and emp.isBundleFlatbedPending and emp.isBundleFlatbedPending() or false
end

-- setup for data
local function expandTasks(offerTask, offer)
  local tasks = {}
  if offer.task.type == "trailerDropOff" then
    tasks = {
      {
        type = "coupleTrailer",
      }, {
        type = "bringToDestination",
        destination = offerTask.destination,
        backOn = "unCouple",
      }, {
        type = "confirmDropOff",
        destination = offerTask.dropOff or offerTask.destination,
      }
    }
  elseif offer.task.type == "vehicleDropOff" then
    local dest = offerTask.dropOff or offerTask.destination or offer.destination
    dest = resolveVehicleDestination({ offer = offer }, dest)
    tasks = {
      {
        type = "enterVehicle",
      }, {
        type = "bringToDestination",
        destination = dest,
        backOn = "exitVehicle",
      }, {
        type = "confirmDropOff",
        destination = dest,
      }
    }
  end
  return tasks
end

-- Like cargo multi-drop: every active vehicle/trailer task destination is on the route
-- at once (nearest first). Avoids last-accepted-wins nav hiding the other yards.
local function collectActiveNavigationTargets()
  local targets = {}
  local seen = {}
  local jockeyShift = isEmploymentJockeyShift()
  local skipVehicleDests = isBundleFlatbedPending()
  for _, taskData in ipairs(vehicleTasks) do
    if taskData.remove then goto continue end
    if skipVehicleDests then goto continue end
    local activeTaskStep = taskData.tasks[taskData.activeTaskIndex]
    if not activeTaskStep then goto continue end

    if activeTaskStep.type == "enterVehicle" or activeTaskStep.type == "coupleTrailer" then
      local key = "veh-" .. tostring(taskData.vehId)
      if not seen[key] then
        local veh = getObjectByID(taskData.vehId)
        if veh then
          seen[key] = true
          targets[#targets + 1] = { key = key, pos = veh:getPosition() }
        end
      end
    else
      local dest = activeTaskStep.destination
      if (not dest or not dest.psPath) and jockeyShift then
        dest = resolveVehicleDestination(taskData, dest)
      end
      if dest and dest.psPath then
        local key = dest.psPath
        if not seen[key] then
          local ps = dGenerator.getParkingSpotByPath(key)
          if ps and ps.pos then
            seen[key] = true
            targets[#targets + 1] = { key = key, pos = ps.pos }
          end
        end
      end
    end
    ::continue::
  end
  return targets
end

local function navigateToActiveTasks()
  local targets = collectActiveNavigationTargets()
  if #targets == 0 then
    local emp = career_modules_delivery_employment
    if emp and emp.isBundleFlatbedPending and emp.isBundleFlatbedPending() then
      if emp.reassertBundleFlatbedRoute then
        return emp.reassertBundleFlatbedRoute() and true or false
      end
      return false
    end
    if emp and emp.isOnShift and emp.isOnShift() then
      return false
    end
    core_groundMarkers.setPath(nil)
    return false
  end

  local playerVeh = getPlayerVehicle(0)
  local playerPos = playerVeh and playerVeh:getPosition() or nil
  if playerPos then
    table.sort(targets, function(a, b)
      return (a.pos - playerPos):squaredLength() < (b.pos - playerPos):squaredLength()
    end)
  end

  if #targets == 1 then
    core_groundMarkers.setPath(targets[1].pos, {clearPathOnReachingTarget = false})
    return true
  end

  local path = {}
  for i, target in ipairs(targets) do
    path[i] = target.pos
  end
  core_groundMarkers.setPath(path, {clearPathOnReachingTarget = false})
  return true
end

local function addVehicleTask(vehId, offer)
  for _, existing in ipairs(vehicleTasks) do
    if not existing.remove and existing.offer.id == offer.id then return end
  end
  local inventory = career_modules_inventory
  local employment = career_modules_delivery_employment
  if inventory then
    local id = offer.vehicle.inventoryId or inventory.getInventoryIdFromVehicleId(vehId)
    local isNew = not id
    if not id and vehId and vehId > 0 then
      id = inventory.addVehicle(vehId, nil, {owned = false, skipPartConditionInit = true})
    end
    local info = id and inventory.getVehicle(id)
    if info and (offer.brokerId or isNew) then
      info.loanType = "delivery"
      info.brokerJobId = offer.brokerId
      info.owningOrganization = offer.organization
      info.takesNoInventorySpace = true
    end
    offer.vehicle.inventoryId = id
    local info = id and inventory.getVehicle(id)
    if info then info.logisticsInUse = true end
  end
  log("I","","addVehicleTask")
  local taskData = {
    vehId = vehId,
    offer = offer,
    tasks = expandTasks(offer.task, offer),
    activeTaskIndex = 1,
    startedTimestamp = dGeneral.time(),
  }
  if offer.logisticsTask then
    for k, value in pairs(offer.logisticsTask) do taskData[k] = deepcopy(value) end
    offer.logisticsTask = nil
  end
  taskData.logisticsPending = not (vehId and vehId > 0 and getObjectByID(vehId)) or nil
  table.insert(vehicleTasks, taskData)
  dTasklist = career_modules_delivery_tasklist or dTasklist
  if dTasklist and dTasklist.sendCargoToTasklist then
    dTasklist.sendCargoToTasklist()
  else
    tasklistRefreshPending = true
  end
  navigateToActiveTasks()
  if dGeneral and dGeneral.requestDeliveryPoiRefresh then
    dGeneral.requestDeliveryPoiRefresh(true)
  elseif gameplay_rawPois then
    gameplay_rawPois.clear()
  end
end
M.addVehicleTask = addVehicleTask

-- Loading another snapshot on the same map can retain this extension. Discard
-- its previous Broker scene tasks before restoring saved tasks, without issuing
-- payouts, abandonment fines, or deleting the newly loaded inventory records.
function M.clearBrokerTasksForLoad()
  for i=#vehicleTasks,1,-1 do
    local task=vehicleTasks[i]
    if task.offer.brokerId then
      clearVehicleTasklistEntry(task)
      local veh=getObjectByID(task.vehId)
      if veh then veh:delete() end
      table.remove(vehicleTasks,i)
    end
  end
end

function M.restoreBrokerTask(saved, vehId)
  for _, task in ipairs(vehicleTasks) do if task.offer.id == saved.offer.id then return end end
  vehicleTasks[#vehicleTasks+1] = {vehId=vehId, offer=saved.offer, tasks=deepcopy(saved.tasks),
    activeTaskIndex=saved.activeTaskIndex, startedTimestamp=saved.startedTimestamp}
  tasklistRefreshPending = true
end


-- checking task completeness

local bringToDestinationThreshold = 20 * 20

local HAUL_DWELL_S = 2.5
local HAUL_LOST_S = 3.0
local HAUL_REL_SPEED_SQ = 2.5 * 2.5
local HAUL_WALKER_NEAR_SQ = 50 * 50
local HAUL_LIFT_LATERAL_MAX = 2.4
local HAUL_LIFT_UP_MAX = 2.5
local HAUL_LIFT_BEHIND_EXTRA = 8
local lastHaulerVehId = nil
local haulPartsCache = {}
local haulGroupScratch = {}
local coupledGroupScratch = {}

local fillHaulerGroup, memberCanBedCarry, haulerTrainCanHaulCargo
local haulSupport = {time = 0, topology = {}, pairs = {}, requestId = 0}

local function isUnicycleVehId(vehId)
  if not vehId or vehId < 0 then return true end
  local obj = getObjectByID(vehId)
  return not obj or (obj.getJBeamFilename and obj:getJBeamFilename() == "unicycle")
end

local function isActiveCargoTaskVehId(vehId)
  if not vehId then return false end
  for _, taskData in ipairs(vehicleTasks) do
    if not taskData.remove and taskData.vehId == vehId then
      return true
    end
  end
  return false
end

local function reassertEmploymentJockeyRoute()
  if not isEmploymentJockeyShift() then return end
  navigateToActiveTasks()
  local emp = career_modules_delivery_employment
  if emp and emp.onVehicleTaskStepChanged then
    emp.onVehicleTaskStepChanged()
  elseif dGeneral and dGeneral.requestDeliveryPoiRefresh then
    dGeneral.requestDeliveryPoiRefresh(true)
  end
end

local function onVehicleSwitched(oldId, newId)
  if newId and newId >= 0 and not isUnicycleVehId(newId) and not isActiveCargoTaskVehId(newId) then
    if haulerTrainCanHaulCargo(newId) then
      lastHaulerVehId = newId
    end
  end
  if not isEmploymentJockeyShift() then return end
  if core_jobsystem and core_jobsystem.create then
    core_jobsystem.create(function(job)
      job.sleep(0)
      reassertEmploymentJockeyRoute()
    end)
  else
    reassertEmploymentJockeyRoute()
  end
end

-- A delivery trailer may be several coupler hops behind the controlled cab.
-- Direct-parent equality makes a rear B-train trailer look uncoupled unless
-- the player switches control into the lead trailer.
local function isTrailerInPlayerTrain(vehId)
  local playerVehId = be:getPlayerVehicleID(0)
  if not playerVehId or playerVehId == -1 then return false end

  if overhaul_playerVehicles and overhaul_playerVehicles.fillCouplerGroup then
    overhaul_playerVehicles.fillCouplerGroup(vehId, coupledGroupScratch, { resolveLead = true })
    local containsPlayer = false
    local groupCount = 0
    for _, groupVehId in ipairs(coupledGroupScratch) do
      groupCount = groupCount + 1
      if groupVehId == playerVehId then
        containsPlayer = true
      end
    end
    if not containsPlayer then return false end
    -- Sitting in a detached delivery trailer still puts vehId in the group.
    -- Require another attached vehicle before treating that as coupled.
    if playerVehId == vehId then
      return groupCount > 1
    end
    return true
  end

  return core_trailerRespawn.getAttachedNonTrailer(vehId) == playerVehId
end

-- Coupler-group proximity via overhaul_playerVehicles (footprint only; job trailers stay loaners).
local function isGroupNearDestination(vehId, destinationPos, thresholdSq)
  if overhaul_playerVehicles and overhaul_playerVehicles.anyInGroupNear then
    return overhaul_playerVehicles.anyInGroupNear(vehId, destinationPos, thresholdSq, { resolveLead = true })
  end
  if not destinationPos then return false end
  local obj = scenetree.findObjectById(vehId)
  return obj and (obj:getPosition() - destinationPos):squaredLength() <= thresholdSq
end

fillHaulerGroup = function(haulerRootId)
  if overhaul_playerVehicles and overhaul_playerVehicles.fillCouplerGroup then
    overhaul_playerVehicles.fillCouplerGroup(haulerRootId, haulGroupScratch, { resolveLead = true })
  else
    table.clear(haulGroupScratch)
    haulGroupScratch[1] = haulerRootId
  end
end

local function isRepoWheelLiftPartName(partName)
  local n = string.lower(tostring(partName or ""))
  if n == "" then return false end
  return n == "repo_main"
    or n == "repo_main_long"
    or n == "repo_parts"
    or n:find("repo_crane", 1, true) ~= nil
    or n:find("/repo_main", 1, true) ~= nil
    or n:find("/repo_parts", 1, true) ~= nil
end

local function classifyHaulParts(obj)
  if not obj then return {lift = false} end
  local id = obj:getID()
  local data = core_vehicle_manager and core_vehicle_manager.getVehicleData(id)
  if not data then return {lift = false} end
  local cached = haulPartsCache[id]
  if cached and cached.source == data.vdata then return cached end
  local result = {lift = false, source = data.vdata}
  for _, parts in ipairs({data.config and data.config.parts or {}, data.vdata and data.vdata.activeParts or {}}) do
    for key, value in pairs(parts) do
      if isRepoWheelLiftPartName(key) or isRepoWheelLiftPartName(value) then result.lift = true end
    end
  end
  haulPartsCache[id] = result
  return result
end

local function memberHasRepoWheelLift(obj)
  return classifyHaulParts(obj).lift
end

local function clearRepoLiftCache(vehId)
  if vehId then
    haulPartsCache[vehId] = nil
    if lastHaulerVehId == vehId then lastHaulerVehId = nil end
    return
  end
  table.clear(haulPartsCache)
end

memberCanBedCarry = function(obj)
  if not obj or isUnicycleVehId(obj:getID()) then return false end
  local data = core_vehicle_manager and core_vehicle_manager.getVehicleData(obj:getID())
  return data and data.vdata and next(data.vdata.triangles or {}) ~= nil or false
end

haulerTrainCanHaulCargo = function(haulerRootId)
  if not haulerRootId then return false end
  fillHaulerGroup(haulerRootId)
  for _, id in ipairs(haulGroupScratch) do
    local obj = getObjectByID(id)
    if memberCanBedCarry(obj) or memberHasRepoWheelLift(obj) then
      return true
    end
  end
  return false
end

local function cargoInRearLiftPocket(delta, fwd, right, up, halfAlong)
  if not delta or not fwd or not right or not up then return false end
  local behind = -delta:dot(fwd)
  local half = tonumber(halfAlong) or 2.5
  if behind < math.max(1.6, half * 0.65) or behind > (half + HAUL_LIFT_BEHIND_EXTRA) then
    return false
  end
  if math.abs(delta:dot(right)) > HAUL_LIFT_LATERAL_MAX then return false end
  if math.abs(delta:dot(up)) > HAUL_LIFT_UP_MAX then return false end
  return true
end

function haulSupport.invalidate(id)
  haulSupport.topology[id] = nil
  for key, state in pairs(haulSupport.pairs) do
    if state.cargoId == id or state.rootId == id or (state.members and state.members[id]) then
      haulSupport.pairs[key] = nil
    end
  end
  for _, task in ipairs(vehicleTasks) do
    if task.vehId == id or task.haulerVehId == id then
      task.haulAcquired, task.haulerVehId = nil, nil
    end
  end
end

function haulSupport.getTopology(obj)
  local id = obj:getID()
  local data = core_vehicle_manager and core_vehicle_manager.getVehicleData(id)
  if not data or not data.vdata then return nil end
  local cached = haulSupport.topology[id]
  if cached and cached.source == data.vdata then return cached end
  if cached then haulSupport.invalidate(id) end
  cached = {source = data.vdata, triangles = {}, nodeIds = {}, wheels = {}}
  local nodes = {}
  for key, t in pairs(data.vdata.triangles or {}) do
    if t.triangleType ~= 2 and t.triangleType ~= 'NONCOLLIDABLE' and t.id1 and t.id2 and t.id3 then
      cached.triangles[#cached.triangles + 1] = {t.id1, t.id2, t.id3, id = key}
      nodes[t.id1], nodes[t.id2], nodes[t.id3] = true, true, true
    end
  end
  for node in pairs(nodes) do cached.nodeIds[#cached.nodeIds + 1] = node end
  for _, wheel in pairs(data.vdata.wheels or {}) do
    cached.wheels[#cached.wheels + 1] = wheel.treadNodes or wheel.nodes or {}
  end
  haulSupport.topology[id] = cached
  return cached
end

function M.receiveHaulSurfaceDamage(id, requestId, broken)
  local cached = haulSupport.topology[id]
  if not cached or cached.requestId ~= requestId then return end
  cached.broken = {}
  for _, triangle in ipairs(broken) do cached.broken[triangle] = true end
  cached.damageTime = haulSupport.time
end

function haulSupport.surfaceNodes(obj, cached, allowPendingDamage)
  local now = haulSupport.time
  if not cached.requestTime or now - cached.requestTime >= 1 then
    haulSupport.requestId = haulSupport.requestId + 1
    cached.requestId, cached.requestTime = haulSupport.requestId, now
    obj:queueLuaCommand(string.format(
      "extensions.load('overhaulCollisionEnvelope'); extensions.overhaulCollisionEnvelope.requestHaulSurfaceDamage(%d)",
      cached.requestId))
  end
  if not allowPendingDamage and (not cached.damageTime or now - cached.damageTime > 2) then return nil end
  if cached.nodeTime ~= now then
    local pos = obj:getPosition()
    cached.nodes = {}
    for _, id in ipairs(cached.nodeIds) do cached.nodes[id] = pos + obj:getNodePosition(id) end
    cached.nodeTime = now
  end
  return cached.nodes
end

local function cargoOnMemberBed(cargoObj, haulerObj, allowPendingDamage)
  if not cargoObj or not haulerObj or cargoObj:getID() == haulerObj:getID() then return false end
  if (cargoObj:getVelocity() - haulerObj:getVelocity()):squaredLength() > HAUL_REL_SPEED_SQ then return false end
  -- Bounds only prune candidates; wheel-to-surface support decides loading.
  local cargoId, carrierId = cargoObj:getID(), haulerObj:getID()
  if be:getObjectOOBBIsInitialized(cargoId) and be:getObjectOOBBIsInitialized(carrierId) then
    local radius = 1
    for axis = 0, 2 do
      radius = radius + vec3(be:getObjectOOBBHalfAxisXYZ(cargoId, axis)):length()
        + vec3(be:getObjectOOBBHalfAxisXYZ(carrierId, axis)):length()
    end
    if (vec3(be:getObjectOOBBCenterXYZ(cargoId)) - vec3(be:getObjectOOBBCenterXYZ(carrierId))):squaredLength() > radius * radius then return false end
  end
  local cargo, carrier = haulSupport.getTopology(cargoObj), haulSupport.getTopology(haulerObj)
  if not cargo or not carrier or #cargo.wheels < 2 then return false end
  local nodes = haulSupport.surfaceNodes(haulerObj, carrier, allowPendingDamage)
  if not nodes then return false, true end
  local wheels, pos = {}, cargoObj:getPosition()
  for _, ids in ipairs(cargo.wheels) do
    local w = {points = {}, minx = math.huge, miny = math.huge, minz = math.huge, maxx = -math.huge, maxy = -math.huge}
    for _, id in ipairs(ids) do
      local p = pos + cargoObj:getNodePosition(id)
      w.points[#w.points + 1] = p
      w.minx, w.maxx = math.min(w.minx, p.x), math.max(w.maxx, p.x)
      w.miny, w.maxy = math.min(w.miny, p.y), math.max(w.maxy, p.y)
      w.minz = math.min(w.minz, p.z)
    end
    wheels[#wheels + 1] = w
  end
  local supported, required = 0, math.ceil(#wheels * 0.75)
  for _, t in ipairs(carrier.triangles) do
    if not (carrier.broken and carrier.broken[t.id]) then
      local a, b, c = nodes[t[1]], nodes[t[2]], nodes[t[3]]
      local ux, uy, uz = b.x-a.x, b.y-a.y, b.z-a.z
      local vx, vy, vz = c.x-a.x, c.y-a.y, c.z-a.z
      local nx, ny, nz = uy*vz-uz*vy, uz*vx-ux*vz, ux*vy-uy*vx
      local norm = math.sqrt(nx*nx + ny*ny + nz*nz)
      if norm > 1e-8 and math.abs(nz)/norm >= 0.35 then
        local minx, maxx = math.min(a.x,b.x,c.x), math.max(a.x,b.x,c.x)
        local miny, maxy = math.min(a.y,b.y,c.y), math.max(a.y,b.y,c.y)
        for _, w in ipairs(wheels) do
          if not w.supported and maxx >= w.minx and minx <= w.maxx and maxy >= w.miny and miny <= w.maxy then
            for _, p in ipairs(w.points) do
              if p.z <= w.minz + 0.12 and p.x >= minx and p.x <= maxx and p.y >= miny and p.y <= maxy then
                local px, py = p.x-a.x, p.y-a.y
                local u, v = (px*vy-py*vx)/nz, (ux*py-uy*px)/nz
                if u >= -0.00001 and v >= -0.00001 and u+v <= 1.00001 then
                  local gap = (p.z-a.z-u*uz-v*vz)*math.abs(nz)/norm
                  if gap >= -0.08 and gap <= 0.065 then
                    w.supported, supported = true, supported + 1
                    if supported >= required then return true end
                    break
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  return false
end

local function cargoOnMemberWheelLift(cargoObj, haulerObj)
  if not cargoObj or not haulerObj or not be then return false end
  local cargoId = cargoObj:getID()
  local haulerId = haulerObj:getID()
  if not be.getObjectOOBBIsInitialized or not be:getObjectOOBBIsInitialized(cargoId)
      or not be:getObjectOOBBIsInitialized(haulerId) then
    return false
  end

  local cVel = cargoObj.getVelocity and cargoObj:getVelocity()
  local hVel = haulerObj.getVelocity and haulerObj:getVelocity()
  if cVel and hVel and (cVel - hVel):squaredLength() > HAUL_REL_SPEED_SQ then
    return false
  end
  if not haulerObj.getDirectionVector then return false end

  local fwd = vec3(haulerObj:getDirectionVector())
  local up = haulerObj.getDirectionVectorUp and vec3(haulerObj:getDirectionVectorUp()) or vec3(0, 0, 1)
  if fwd:squaredLength() < 0.01 then return false end
  fwd = fwd:normalized()
  if up:squaredLength() < 0.01 then
    up = vec3(0, 0, 1)
  else
    up = up:normalized()
  end
  local right = fwd:cross(up)
  if right:squaredLength() < 0.01 then return false end
  right = right:normalized()

  local hCenter = vec3(be:getObjectOOBBCenterXYZ(haulerId))
  local cCenter = vec3(be:getObjectOOBBCenterXYZ(cargoId))
  local halfAlong = 0
  for i = 0, 2 do
    local axis = vec3(be:getObjectOOBBHalfAxisXYZ(haulerId, i))
    local along = math.abs(axis:dot(fwd))
    if along > halfAlong then halfAlong = along end
  end
  return cargoInRearLiftPocket(cCenter - hCenter, fwd, right, up, halfAlong)
end

local function cargoNearHaulerBed(cargoObj, haulerRootId)
  if not cargoObj or not haulerRootId then return false end
  fillHaulerGroup(haulerRootId)
  local cargoId = cargoObj:getID()
  for _, id in ipairs(haulGroupScratch) do
    if id ~= cargoId and not isActiveCargoTaskVehId(id) then
      local hauler = getObjectByID(id)
      if memberCanBedCarry(hauler) and cargoOnMemberBed(cargoObj, hauler) then
        return true
      end
      if memberHasRepoWheelLift(hauler) and cargoOnMemberWheelLift(cargoObj, hauler) then
        return true
      end
    end
  end
  return false
end

function haulSupport.isLoaded(cargoId, rootId)
  if not cargoId or not rootId or cargoId == rootId then return false end
  local cargo, root = getObjectByID(cargoId), getObjectByID(rootId)
  if not cargo or not root then return false end
  local key, now = tostring(cargoId) .. ':' .. tostring(rootId), haulSupport.time
  local state = haulSupport.pairs[key]
  if not state or now - state.used > 2 then
    state = {cargoId = cargoId, rootId = rootId, loaded = false}
    haulSupport.pairs[key] = state
  end
  state.used = now
  if state.sampleTime and now - state.sampleTime < 0.25 then return state.loaded, state.supportSince ~= nil end
  local supported = cargoNearHaulerBed(cargo, rootId)
  if haulSupport.pairs[key] ~= state then
    state = {cargoId = cargoId, rootId = rootId, loaded = false, used = now}
  end
  state.members = {}
  for _, id in ipairs(haulGroupScratch) do state.members[id] = true end
  haulSupport.pairs[key] = state
  state.sampleTime = now
  if supported then
    state.lostSince = nil
    state.supportSince = state.supportSince or now
    if now - state.supportSince >= HAUL_DWELL_S then state.loaded = true end
  else
    state.supportSince = nil
    state.lostSince = state.lostSince or now
    if now - state.lostSince >= HAUL_LOST_S then state.loaded = false end
  end
  return state.loaded, state.supportSince ~= nil
end

local function pickHaulerForCargo(cargoVehId, cargoPos)
  local playerId = be:getPlayerVehicleID(0)
  if playerId and playerId >= 0 and playerId ~= cargoVehId and not isUnicycleVehId(playerId)
      and not isActiveCargoTaskVehId(playerId) and haulerTrainCanHaulCargo(playerId) then
    return playerId
  end

  local walkerPos = nil
  if playerId and playerId >= 0 then
    local walker = getObjectByID(playerId)
    walkerPos = walker and walker:getPosition() or nil
  end
  if not walkerPos and core_camera then
    walkerPos = core_camera.getPosition()
  end

  local function walkerNear(pos)
    if not walkerPos or not pos then return true end
    return (walkerPos - pos):squaredLength() <= HAUL_WALKER_NEAR_SQ
  end

  if lastHaulerVehId and lastHaulerVehId ~= cargoVehId and not isUnicycleVehId(lastHaulerVehId)
      and not isActiveCargoTaskVehId(lastHaulerVehId) and haulerTrainCanHaulCargo(lastHaulerVehId) then
    local last = getObjectByID(lastHaulerVehId)
    if last then
      local lastPos = last:getPosition()
      if walkerNear(lastPos) or (cargoPos and (lastPos - cargoPos):squaredLength() <= HAUL_WALKER_NEAR_SQ) then
        return lastHaulerVehId
      end
    end
  end

  local inv = career_modules_inventory
  local map = inv and inv.getMapInventoryIdToVehId and inv.getMapInventoryIdToVehId()
  if not map or not cargoPos then return nil end
  local bestId, bestDist
  for _, vehId in pairs(map) do
    if vehId and vehId ~= cargoVehId and not isUnicycleVehId(vehId)
        and not isActiveCargoTaskVehId(vehId) and haulerTrainCanHaulCargo(vehId) then
      local obj = getObjectByID(vehId)
      if obj then
        local pos = obj:getPosition()
        local distSq = (pos - cargoPos):squaredLength()
        if distSq <= HAUL_WALKER_NEAR_SQ and walkerNear(pos) and (not bestDist or distSq < bestDist) then
          bestId, bestDist = vehId, distSq
        end
      end
    end
  end
  return bestId
end

-- Cargo on a bed/in a dryvan is not coupler-linked; when acquired (or still on the
-- hauler), destination proximity follows the truck/trailer train instead.
local function isCargoNearDestination(taskData, destinationPos, thresholdSq)
  if not taskData or not taskData.vehId then return false end
  if isGroupNearDestination(taskData.vehId, destinationPos, thresholdSq) then
    return true
  end
  local haulerId = taskData.haulerVehId
  return haulerId and haulSupport.isLoaded(taskData.vehId, haulerId)
    and isGroupNearDestination(haulerId, destinationPos, thresholdSq) or false
end

local function tryHaulAcquireOnCapableHauler(taskData, dtSim)
  local cargo = getObjectByID(taskData.vehId)
  if not cargo then
    taskData.haulAcquired, taskData.haulerVehId = nil, nil
    return false
  end
  local candidates, seen = {}, {}
  local function add(id)
    if id and not seen[id] and id ~= taskData.vehId and not isUnicycleVehId(id)
        and not isActiveCargoTaskVehId(id) then
      candidates[#candidates + 1], seen[id] = id, true
    end
  end
  add(taskData.haulerVehId)
  add(pickHaulerForCargo(taskData.vehId, cargo:getPosition()))
  add(lastHaulerVehId)
  local inv = career_modules_inventory
  for _, id in pairs(inv and inv.getMapInventoryIdToVehId and inv.getMapInventoryIdToVehId() or {}) do add(id) end
  local pending = false
  for _, id in ipairs(candidates) do
    local loaded, acquiring = haulSupport.isLoaded(taskData.vehId, id)
    if loaded then
      taskData.haulAcquired, taskData.haulerVehId = true, id
      lastHaulerVehId = id
      return true
    end
    pending = pending or acquiring
  end
  taskData.haulAcquired, taskData.haulerVehId = nil, nil
  return false, pending
end

local function processActiveTask(taskData, dtSim)
  if taskData.logisticsPending then return end
  local taskIndexBefore = taskData.activeTaskIndex
  local activeTask = taskData.tasks[taskData.activeTaskIndex]
  if activeTask.type == "coupleTrailer" then
    -- Any controlled member of the same connected train counts, including a
    -- cab towing a multi-trailer combination.
    if isTrailerInPlayerTrain(taskData.vehId) then
      taskData.activeTaskIndex = taskData.activeTaskIndex + 1
      dTasklist.updateTasklistForOfferId(taskData.offer.id)
    end
  end

  if activeTask.type == "enterVehicle" then
    if be:getPlayerVehicleID(0) == taskData.vehId then
      taskData.activeTaskIndex = taskData.activeTaskIndex + 1
      dTasklist.updateTasklistForOfferId(taskData.offer.id)
    elseif tryHaulAcquireOnCapableHauler(taskData, dtSim) then
      taskData.activeTaskIndex = taskData.activeTaskIndex + 1
      dTasklist.updateTasklistForOfferId(taskData.offer.id)
    end
  end

  if activeTask.type == "bringToDestination" then
    if not activeTask.destination or not activeTask.destination.psPath then
      activeTask.destination = resolveVehicleDestination(taskData, activeTask.destination)
    end
    -- check if uncoupled, go back if so
    if activeTask.backOn == "uncouple" and not isTrailerInPlayerTrain(taskData.vehId) then
      activeTask.uncoupled = nil
      taskData.activeTaskIndex = taskData.activeTaskIndex - 1
      dTasklist.updateTasklistForOfferId(taskData.offer.id)
    end
    if activeTask.backOn == "exitVehicle" and be:getPlayerVehicleID(0) ~= taskData.vehId then
      local _, acquiring = tryHaulAcquireOnCapableHauler(taskData, dtSim)
      if not taskData.haulAcquired and not acquiring then
        taskData.activeTaskIndex = taskData.activeTaskIndex - 1
        dTasklist.updateTasklistForOfferId(taskData.offer.id)
      end
    end
    -- Coupler train near spot, or bed/enclosed cargo whose hauler train is near.
    local destinationPos = dGenerator.getLocationCoordinates(activeTask.destination)
    if isCargoNearDestination(taskData, destinationPos, bringToDestinationThreshold) then
      taskData.activeTaskIndex = taskData.activeTaskIndex + 1
      dTasklist.updateTasklistForOfferId(taskData.offer.id)
    end
  end
  if activeTask.type == "putIntoParkingSpot" then
    -- check if parked in spot and uncoupled
    local destinationPs = dGenerator.getParkingSpotByPath(activeTask.destination.psPath)
    local valid, res = destinationPs:checkParking(taskData.vehId)
    simpleDebugText3d(valid and "Valid" or "Invalid", destinationPs.pos + vec3(0,0,2), 0.25, valid and ColorF(0,1,0,0.25) or ColorF(1,0,0,0.25))
    destinationPs:drawDebug()
    if valid then
      if activeTask.forwardOn == "unCouple" and not isTrailerInPlayerTrain(taskData.vehId) then
        taskData.activeTaskIndex = taskData.activeTaskIndex + 1
        dTasklist.updateTasklistForOfferId(taskData.offer.id)
      end
      if activeTask.forwardOn == "exitVehicle" and be:getPlayerVehicleID(0) ~= taskData.vehId then
        taskData.activeTaskIndex = taskData.activeTaskIndex + 1
        dTasklist.updateTasklistForOfferId(taskData.offer.id)
      end
    end

    -- Too far: only roll back when the whole train has left the area, not a rear trailer.
    local destinationPos = dGenerator.getLocationCoordinates(activeTask.destination)
    if not isCargoNearDestination(taskData, destinationPos, bringToDestinationThreshold * 1.5) then
      taskData.activeTaskIndex = taskData.activeTaskIndex - 1
      dTasklist.updateTasklistForOfferId(taskData.offer.id)
    end
  end
  if activeTask.type == "confirmDropOff" then
    if not activeTask.destination or not activeTask.destination.psPath then
      activeTask.destination = resolveVehicleDestination(taskData, activeTask.destination)
    end
  end

  if taskIndexBefore ~= taskData.activeTaskIndex then
    taskThatChangedThisFrame = taskData
  end
end

local function onTrailerAttached(objId1, objId2)
  for _, taskData in ipairs(vehicleTasks) do
    if taskData.vehId then
      taskData.loanerOrganisations = taskData.loanerOrganisations or {}
      tableMerge(taskData.loanerOrganisations, career_modules_loanerVehicles.getLoaningOrgsOfVehicle(taskData.vehId))
    end
  end
end

local function getRewardsWithBreakdown(taskData)
  local originalRewards = deepcopy(taskData.offer.rewards)
  local breakdown = {}

  log("I","","Finished Vehicle: " .. taskData.vehId)
  local brokenPartsRelative = taskData.brokenPartsNumber / taskData.partsNumber
  log("I","",string.format("Broken Parts: %0.1f%% (%d / %d)", brokenPartsRelative*100, taskData.brokenPartsNumber, taskData.partsNumber))
  local distanceDriven = (taskData.offer.endingOdometer - taskData.offer.startingOdometer)
  if taskData.offer.startingOdometer == -1 or taskData.offer.endingOdometer == -1 then
    distanceDriven = 0
  end
  local offerData = taskData.offer.data or {}
  local originalDistance = tonumber(offerData.originalDistance)
  if not originalDistance or originalDistance <= 0 then
    if taskData.offer.origin and taskData.offer.destination and dGenerator and dGenerator.getDistanceBetweenFacilities then
      originalDistance = tonumber((dGenerator.getDistanceBetweenFacilities(taskData.offer.origin, taskData.offer.destination))) or 0
    end
    if not originalDistance or originalDistance <= 0 then
      originalDistance = math.max(distanceDriven, 1000)
    end
    offerData.originalDistance = originalDistance
  end
  log("I","",string.format("Driven Distance: %0.3fkm (%0.1f%% of allowed %0.3fkm)", distanceDriven/1000, 100*distanceDriven/originalDistance, 1.2*originalDistance/1000))
  local timeTaken = dGeneral.time() - taskData.startedTimestamp
  local expectedTime = (originalDistance/12 + 30 )
  log("I","",string.format("Time Taken: %0.1f seconds (expected: %0.1fs)", timeTaken, expectedTime))


  local brokenPartsThreshold = career_modules_valueCalculator.getBrokenPartsThreshold()

  local origMoney = originalRewards.money
  local reputationRewards = {}
  for rewardKey, rewardValue in pairs(originalRewards) do
    if rewardKey:endswith("Reputation") then
      reputationRewards[rewardKey] = rewardValue
    end
  end

  local partsBreakdown = {simpleBreakdownType="bonus"}
  local brokenPartsMultipler = 1
  if brokenPartsRelative >= 0.25 then
    brokenPartsMultipler = 0
    partsBreakdown.label = "Excessive Damage"
    partsBreakdown.rewards = {money = -origMoney}
    for rewardKey, rewardValue in pairs(reputationRewards) do
      partsBreakdown.rewards[rewardKey] = -2 * rewardValue
    end
  elseif taskData.brokenPartsNumber >= brokenPartsThreshold then
    brokenPartsMultipler = 0.8 - 0.6*(brokenPartsRelative*4)
    partsBreakdown.label = "Slight Damage"
    partsBreakdown.rewards = {money = -(1-brokenPartsMultipler)*origMoney}
    for rewardKey, rewardValue in pairs(reputationRewards) do
      partsBreakdown.rewards[rewardKey] = -(1-brokenPartsMultipler) * rewardValue
    end
  else
    partsBreakdown.label = "No Damage"
    partsBreakdown.rewards = {money = math.ceil(origMoney*0.05)}
  end

  table.insert(breakdown, partsBreakdown)

  if brokenPartsMultipler == 1 then
    if distanceDriven > 0 then
      if distanceDriven/originalDistance < 1.2 then
        local rewards = {money=origMoney*0.15+10}
        for rewardKey, rewardValue in pairs(reputationRewards) do
          rewards[rewardKey] = math.ceil(rewardValue*0.125)
        end
        table.insert(breakdown, {label = "No Detours", rewards = rewards, simpleBreakdownType="bonus", })
      end
    end
    if timeTaken < expectedTime then
      local rewards = {money=origMoney*0.15+10}
      for rewardKey, rewardValue in pairs(reputationRewards) do
        rewards[rewardKey] = math.ceil(rewardValue*0.125)
      end
      table.insert(breakdown, {label = "No Delays", rewards = rewards, simpleBreakdownType="bonus",})
    end
  end

  local logisticsSkillXpEarned = tonumber(originalRewards["logistics-delivery"])
  if not logisticsSkillXpEarned then
    logisticsSkillXpEarned = tonumber(originalRewards["logistics-vehicleDelivery"]) or tonumber(originalRewards["logistics"]) or 0
  end
  local loanerOrgReputationReward = round(math.max(0, logisticsSkillXpEarned))

  for organizationId, _ in pairs(taskData.loanerOrganisations or {}) do
    local emp = career_modules_delivery_employment
    if emp and emp.usesEmploymentPayForOrg and emp.usesEmploymentPayForOrg(organizationId) then
      -- Employment escrow handles pay on shift; skip independent loaner cut.
    else
      local organization = freeroam_organizations.getOrganization(organizationId)
      local level = organization.reputation.level
      local organizationCut = (organization.reputationLevels[level+2].loanerCut and organization.reputationLevels[level+2].loanerCut.value or 0.5)

      local organizationElement = {
        label = string.format("Loaner Organization (%d%% cut)", round(organizationCut * 100)),
        rewards = {money = -organizationCut * originalRewards.money},
        simpleBreakdownType = "loaner",
      }
      organizationElement.rewards[organizationId.."Reputation"] = loanerOrgReputationReward

      table.insert(breakdown, organizationElement)
    end
  end

  -- Calculate precision parking and add to breakdown
  if taskData.dropOffPsPath then
    local targetParkingSpot = dGenerator.getParkingSpotByPath(taskData.dropOffPsPath)
    if targetParkingSpot then
      local precisionData = dPrecisionParking.calculateVehiclePrecisionScore(taskData.vehId, targetParkingSpot)
      if precisionData then
        local precisionBonus = dPrecisionParking.getPrecisionParkingBonus(precisionData)

        -- Add precision parking breakdown entry
        local precisionBreakdown = {
          label = "Precision Parking (" .. precisionBonus.precisionLevel:gsub("^%l", string.upper) .. ")",
          rewards = {},
          simpleBreakdownType = (precisionBonus.moneyFlat >= 0 and precisionBonus.logisticsFlat >= 0) and "bonus" or "penalty",
          precisionData = precisionData
        }

        -- Calculate money reward
        local moneyReward = precisionBonus.moneyFlat + (originalRewards.money * precisionBonus.moneyPercent)
        if moneyReward ~= 0 then
          precisionBreakdown.rewards.money = math.ceil(moneyReward)
        end

        -- Calculate logistics XP reward
        local logisticsReward = precisionBonus.logisticsFlat + (originalRewards["logistics"] or 0) * precisionBonus.logisticsPercent
        if logisticsReward ~= 0 then
          precisionBreakdown.rewards["logistics"] = math.ceil(logisticsReward)
        end

        -- Calculate skill XP reward (same as logistics for vehicle delivery)
        local skillBaseReward = (originalRewards["logistics-delivery"] or 0) + (originalRewards["logistics-vehicleDelivery"] or 0)
        local skillReward = precisionBonus.skillFlat + skillBaseReward * precisionBonus.skillPercent
        if skillReward ~= 0 then
          precisionBreakdown.rewards["logistics-delivery"] = (precisionBreakdown.rewards["logistics-delivery"] or 0) + math.ceil(skillReward)
        end

        -- Calculate reputation reward
        if taskData.offer and taskData.offer.organization then
          local reputationReward = precisionBonus.reputationFlat + (originalRewards[taskData.offer.organization.."Reputation"] or 0) * precisionBonus.reputationPercent
          if reputationReward ~= 0 then
            precisionBreakdown.rewards[taskData.offer.organization.."Reputation"] = math.ceil(reputationReward)
          end
        end

        table.insert(breakdown, precisionBreakdown)
      end
    end
  end

  local adjustedRewards = deepcopy(originalRewards)
  for _, bd in ipairs(breakdown) do
    for key, amount in pairs(bd.rewards) do
      adjustedRewards[key] = (adjustedRewards[key] or 0) + amount
    end
  end
  return originalRewards, breakdown, adjustedRewards
end

local function getVehicleDataWithRewardsSummary(psPath)
  local vehicleRewardData = {}
  for _, taskData in ipairs(vehicleTasks) do
    local activeTask = taskData.tasks[taskData.activeTaskIndex]
    if activeTask.type == "confirmDropOff" then
      if not psPath or activeTask.destination.psPath == psPath then
        local formatted = dCargoScreen.formatAcceptedOfferForUI(taskData.offer)
        formatted.finished = false
        formatted._taskData = taskData
        table.insert(vehicleRewardData, formatted)
      end
    end
  end
  return vehicleRewardData
end

local function makeGatherVehicleDataSteps(vehicleRewardData)
  local sequence = {}
  for _, formatted in ipairs(vehicleRewardData) do
    local taskData = formatted._taskData
    if not taskData then goto continue end
    local veh = getObjectByID(taskData.vehId)
    if not veh then
      formatted.finished = true
      formatted._taskData = nil
      goto continue
    end
    table.insert(sequence, step.makeStepReturnTrueFunction(function(s)
      if not s.sentCommand then
        s.sentCommand = true
        core_vehicleBridge.requestValue(veh, function(res)
          local partConditions = res.result
          if tableSize(partConditions) > 0 then
            taskData.brokenPartsNumber = career_modules_valueCalculator.getNumberOfBrokenParts(partConditions)
            taskData.partsNumber = tableSize(partConditions)
          end
          s.brokenPartsRequested = true
        end, 'getPartConditions')
      end
      return s.brokenPartsRequested or false
    end))
    table.insert(sequence, step.makeStepReturnTrueFunction(function(s)
      if not s.sentCommand then
        s.sentCommand = true
        local vehData = core_vehicle_manager.getVehicleData(taskData.vehId)
        core_vehicleBridge.requestValue(veh, function(res)
          s.odometerComplete = true
          local mainPartName = "/" .. vehData.config.mainPartName
          local part = res.result[mainPartName]
          if part then
            taskData.offer.endingOdometer = part.odometer
          else
            taskData.offer.endingOdometer = -1
          end
        end, 'getPartConditions')
      end
      return s.odometerComplete or false
    end))
    table.insert(sequence, step.makeStepReturnTrueFunction(function()
      formatted.originalRewards, formatted.breakdown, formatted.adjustedRewards = getRewardsWithBreakdown(taskData)
      formatted.finished = true
      formatted._taskData = nil
      return true
    end))
    ::continue::
  end
  return sequence
end

M.getVehicleDataWithRewardsSummary = getVehicleDataWithRewardsSummary
M.makeGatherVehicleDataSteps = makeGatherVehicleDataSteps

local function canDropOffCargoAtPsPath(psPath)
  local vehsClose, trailersClose = 0,0
  for _, taskData in ipairs(vehicleTasks) do
    local activeTask = taskData.tasks[taskData.activeTaskIndex]
    if activeTask.type == "confirmDropOff" and psPath == activeTask.destination.psPath then
      if taskData.offer.data.type == "vehicle" then vehsClose = vehsClose + 1 end
      if taskData.offer.data.type == "trailer" then trailersClose = trailersClose +1 end
    end
  end
  return vehsClose, trailersClose
end
M.canDropOffCargoAtPsPath = canDropOffCargoAtPsPath


local function makeFinishTasksSteps(affectedOffers)
  local sequence = {}
  for _, taskData in ipairs(affectedOffers) do
    local activeTask = taskData.tasks[taskData.activeTaskIndex]
    if activeTask.type ~= "confirmDropOff" then goto continue end
    local veh = getObjectByID(taskData.vehId)
    if not veh then
      taskData.logisticsPending = true
      goto continue
    end
    table.insert(sequence, step.makeStepReturnTrueFunction(function(s)
      if not s.sentCommand then
        s.sentCommand = true
        core_vehicleBridge.requestValue(veh, function(res)
          local partConditions = res.result
          if tableSize(partConditions) > 0 then
            taskData.brokenPartsNumber = career_modules_valueCalculator.getNumberOfBrokenParts(partConditions)
            taskData.partsNumber = tableSize(partConditions)
          end
          s.brokenPartsRequested = true
        end, 'getPartConditions')
      end
      return s.brokenPartsRequested or false
    end))
    table.insert(sequence, step.makeStepReturnTrueFunction(function(s)
      if not s.sentCommand then
        s.sentCommand = true
        local vehData = core_vehicle_manager.getVehicleData(taskData.vehId)
        core_vehicleBridge.requestValue(veh, function(res)
          s.odometerComplete = true
          local mainPartName = "/" .. vehData.config.mainPartName
          local part = res.result[mainPartName]
          if part then
            taskData.offer.endingOdometer = part.odometer
          else
            taskData.offer.endingOdometer = -1
          end
        end, 'getPartConditions')
      end
      return s.odometerComplete or false
    end))
    table.insert(sequence, step.makeStepReturnTrueFunction(function()
      taskData.originalRewards, taskData.breakdown, taskData.adjustedRewards = getRewardsWithBreakdown(taskData)
      taskData.finished = true
      return true
    end))
    ::continue::
  end
  return sequence
end

M.finishTasks = function(offerIds, missingVehicleDropOff)
  local affectedOffers, fallbackOffers = {}, {}
  local offersById = tableValuesAsLookupDict(offerIds)
  for _, taskData in ipairs(vehicleTasks) do
    local activeTask = taskData.tasks and taskData.tasks[taskData.activeTaskIndex]
    local vehicleReady = not taskData.logisticsPending
      and taskData.vehId and getObjectByID(taskData.vehId)
    local destination = activeTask and activeTask.destination
      or (taskData.offer and (taskData.offer.destination
        or (taskData.offer.task and taskData.offer.task.destination)))
    local missingAtAssignedDropOff = missingVehicleDropOff and not vehicleReady
      and destination and destination.psPath == missingVehicleDropOff.psPath
      and (not destination.facId or destination.facId == missingVehicleDropOff.facId)
      and (activeTask.type == "confirmDropOff"
        or (activeTask.type == "bringToDestination" and (tonumber(taskData.activeTaskIndex) or 0) > 1))
      and career_modules_delivery_employment and career_modules_delivery_employment.isAssignedVehicleOffer
      and career_modules_delivery_employment.isAssignedVehicleOffer(taskData.offer)
    if offersById[taskData.offer.id] and not taskData.finished and not taskData.remove
        and (vehicleReady or missingAtAssignedDropOff) then
      if missingAtAssignedDropOff then
        taskData.finished = true
        taskData.dropOffPsPath = destination.psPath
        local rewards = deepcopy(taskData.offer.rewards or {})
        fallbackOffers[#fallbackOffers + 1] = {
          offer = taskData.offer,
          originalRewards = rewards,
          adjustedRewards = deepcopy(rewards),
          breakdown = {},
          finished = true,
        }
      else
        table.insert(affectedOffers, taskData)
        taskData.finished = false
        if activeTask.type == "confirmDropOff" then
          taskData.dropOffPsPath = activeTask.destination.psPath
        end
      end
    end
  end
  local sequence = makeFinishTasksSteps(affectedOffers)
  for _, offer in ipairs(fallbackOffers) do
    affectedOffers[#affectedOffers + 1] = offer
  end
  if #sequence > 0 then
    step.startStepSequence(sequence, function()
      dProgress.confirmDropOffCheckComplete()
    end)
  else
    for _, taskData in ipairs(affectedOffers) do
      taskData.finished = true
    end
    dProgress.confirmDropOffCheckComplete()
  end
  return affectedOffers
end

local function ejectPlayerFromTaskVehicle(vehId, walkPos)
  if not vehId or not be or not be.getPlayerVehicleID then return end
  if be:getPlayerVehicleID(0) ~= vehId then return end
  if gameplay_walk and gameplay_walk.setWalkingMode then
    gameplay_walk.setWalkingMode(true, walkPos, nil, true)
  end
end

local function deleteTaskVehicle(vehId, inventoryId)
  local inventory = career_modules_inventory
  local id = inventoryId or (inventory and vehId and inventory.getInventoryIdFromVehicleId(vehId))
  local info = id and inventory.getVehicle(id)
  -- Task cleanup owns temporary delivery loans, never an existing player or
  -- company vehicle attached to the task. Keep its scene object as well.
  if info and (info.loanType ~= "delivery" or info.owned) then return end
  if not vehId and not info then return end
  if vehId and vehId >= 0 then
    ejectPlayerFromTaskVehicle(vehId)
    if be and be.getPlayerVehicleID and be:getPlayerVehicleID(0) == vehId then return end
  end
  local veh = vehId and vehId >= 0 and scenetree.findObjectById(vehId)
  if info then
    inventory.removeVehicle(id, true)
    return
  end
  if veh then veh:delete() end
end

local taskDataRemoveThisFrame = false
local function processFinished(taskData)
  if taskData.finished then
    taskDataRemoveThisFrame = true

    local dropSpot = taskData.dropOffPsPath and dGenerator.getParkingSpotByPath(taskData.dropOffPsPath)
    local psPos = dropSpot and dropSpot.pos or nil
    local _, unicycleId
    if be:getPlayerVehicleID(0) == taskData.vehId then
      _, unicycleId = gameplay_walk.setWalkingMode(true, psPos, nil, true)
    end
    deleteTaskVehicle(taskData.vehId,
      taskData.logisticsPending and taskData.offer and taskData.offer.vehicle
        and taskData.offer.vehicle.inventoryId or nil)

    local unicycle = scenetree.findObjectById(unicycleId)
    if unicycle then
      spawn.safeTeleport(unicycle, psPos)
    end

    clearVehicleTasklistEntry(taskData)

    taskData.remove = true
    taskData.processFinishedComplete = true
    dProgress.confirmDropOffCheckComplete()
  end
end

local function showMessageJob(job)
  local message = job.args[1]
  local category = job.args[2]
  local icon = job.args[3]
  job.sleep(1)
  guihooks.trigger('Message', {clear = nil, ttl = 10, msg = message, category = category, icon = icon})
end

local function getFineForAbandon(taskData)
  local fine = {money=-(taskData.offer.rewards.money or 0) * dGeneral.getDeliveryAbandonPenaltyFactor()}
  if taskData.offer.organization then
    fine[taskData.offer.organization .. "Reputation"] = career_modules_reputation.getValueForEvent("discardDeliveryVehicle")
  end
  return fine
end
M.getFineForAbandon = getFineForAbandon

local function processGiveBack(taskData)
  if taskData.giveBack then
    if career_modules_delivery_broker then career_modules_delivery_broker.onBrokerVehicleAbandoned(taskData.offer) end
    taskDataRemoveThisFrame = true
    ejectPlayerFromTaskVehicle(taskData.vehId)
    deleteTaskVehicle(taskData.vehId)
    clearVehicleTasklistEntry(taskData)

    taskData.remove = true
    if not taskData.undeliverable then
      local fine = M.getFineForAbandon(taskData)
      career_modules_playerAttributes.addAttributes(fine, {
        tags = {"gameplay", "delivery", "fine"},
        label = {
          txt = "ui.career.attributeLog.abandonedDeliveryPenaltyFor",
          context = { deliveryName = taskData.offer.name },
        },
      })

      local message = string.format("Delivery %s abandoned. \n %0.2f$ penalty. " .. (taskData.offer.organization and "\n%d reputation lost." or ""), taskData.offer.name, -fine.money, taskData.offer.organization and -fine[taskData.offer.organization .. "Reputation"] or 0)
      core_jobsystem.create(showMessageJob, nil, message, "delivery", "local_shipping")
    end
  end
end

local function navigateToNextTask()
  return navigateToActiveTasks()
end

local toDeleteActiveTrailerIndexes = {}
local function onUpdate(dtReal, dtSim, dtRaw)
  haulSupport.time = haulSupport.time + (dtSim or 0)
  for key, state in pairs(haulSupport.pairs) do
    if haulSupport.time - state.used > 2 then haulSupport.pairs[key] = nil end
  end
  dTasklist = career_modules_delivery_tasklist or dTasklist
  taskThatChangedThisFrame = nil
  for _, taskData in ipairs(vehicleTasks) do
    if not taskData.remove then
      processActiveTask(taskData, dtSim)
    end
  end
  for _, taskData in ipairs(vehicleTasks) do
    if not taskData.remove then
      processFinished(taskData)
    end
  end
  for _, taskData in ipairs(vehicleTasks) do
    if not taskData.remove then
      processGiveBack(taskData)
    end
  end

  local idsToRemove = {}
  if taskDataRemoveThisFrame then
    for id, taskData in ipairs(vehicleTasks) do
      if taskData.remove then
        table.insert(idsToRemove, id)
      end
    end
    -- remove from the back to avoid ids moving
    for _, id in ipairs(arrayReverse(idsToRemove)) do
      local taskToBeRemoved = vehicleTasks[id]
      table.remove(vehicleTasks, id)
      local transfer = gameplay_vehicleTransfer
      if transfer and transfer.onVehicleTaskRemoved and taskToBeRemoved then
        transfer.onVehicleTaskRemoved(taskToBeRemoved)
      end
    end

    dGeneral.checkExitDeliveryMode()
    -- Rebuild only after the completed task is gone from vehicleTasks, so an
    -- asynchronous task-list refresh cannot re-add its stale dolly entry.
    if tasklistRefreshPending then
      dTasklist = career_modules_delivery_tasklist or dTasklist
      if dTasklist and dTasklist.sendCargoToTasklist then
        dTasklist.sendCargoToTasklist()
        tasklistRefreshPending = false
      end
    end
  end

  if taskThatChangedThisFrame or not tableIsEmpty(idsToRemove) then
    navigateToActiveTasks()
    local emp = career_modules_delivery_employment
    if emp and emp.refreshHudTasklist and emp.ownsHudTasklist and emp.ownsHudTasklist() then
      emp.refreshHudTasklist(true)
    elseif emp and emp.onVehicleTaskStepChanged then
      emp.onVehicleTaskStepChanged()
    end
    local transfer = gameplay_vehicleTransfer
    if transfer and transfer.refreshHudTasklist and transfer.isOnShift and transfer.isOnShift() then
      transfer.refreshHudTasklist(true)
    end
    -- Drop-off parking markers come from onGetRawPoiListForLevel → getTargetDestinations.
    -- Active step can change (enterVehicle → bringToDestination) without any other clear,
    -- so rebuild playmode POIs here; otherwise markers stay stale until big map open/close.
    if dGeneral and dGeneral.requestDeliveryPoiRefresh then
      dGeneral.requestDeliveryPoiRefresh(true)
    elseif gameplay_rawPois then
      gameplay_rawPois.clear()
    end
    if gameplay_markerInteraction then
      gameplay_markerInteraction.setForceReevaluateOpenPrompt()
    end
  end

  taskDataRemoveThisFrame = false
end
M.onUpdate = onUpdate


local function getTargetDestinationsForActiveTasks()
  local ret = {}
  local seen = {}
  local jockeyShift = isEmploymentJockeyShift()
  local skipVehicleDests = isBundleFlatbedPending()
  for _, taskData in ipairs(vehicleTasks) do
    if taskData.remove then goto continue end
    if skipVehicleDests then goto continue end
    local activeIdx = taskData.activeTaskIndex or 1
    local activeTask = taskData.tasks[activeIdx]
    local dest = nil
    if activeTask and (activeTask.type == "enterVehicle" or activeTask.type == "coupleTrailer") then
      dest = nil
    elseif jockeyShift then
      dest = resolveVehicleDestination(taskData, activeTask and activeTask.destination)
    elseif activeTask and activeTask.destination and activeTask.destination.psPath then
      dest = activeTask.destination
    elseif activeTask and activeTask.type ~= "enterVehicle" and activeTask.type ~= "coupleTrailer" then
      for i = activeIdx + 1, #(taskData.tasks or {}) do
        local stepTask = taskData.tasks[i]
        if stepTask and stepTask.destination and stepTask.destination.psPath then
          dest = stepTask.destination
          break
        end
      end
    end
    if dest and dest.psPath and not seen[dest.psPath] then
      seen[dest.psPath] = true
      table.insert(ret, dest)
    end
    ::continue::
  end
  return ret
end
M.getTargetDestinationsForActiveTasks = getTargetDestinationsForActiveTasks

local function getPrimaryActiveVehicleTaskInfo()
  for _, taskData in ipairs(vehicleTasks) do
    if not taskData.remove then
      local step = taskData.tasks[taskData.activeTaskIndex]
      local playerId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0)
      local inCargo = playerId and tonumber(playerId) == tonumber(taskData.vehId)
      return {
        vehId = taskData.vehId,
        offerId = taskData.offer and taskData.offer.id,
        stepType = step and step.type,
        inCargoVehicle = inCargo and true or false,
        haulAcquired = taskData.haulAcquired and true or false,
        destination = resolveVehicleDestination(taskData, step and step.destination),
      }
    end
  end
  return nil
end
M.getPrimaryActiveVehicleTaskInfo = getPrimaryActiveVehicleTaskInfo

function M.isCargoOnHaulerBed(cargoVehId, haulerVehId)
  return haulSupport.isLoaded(cargoVehId, haulerVehId)
end

function M.getCargoCarrier(cargoVehId, carrierIds)
  local cargo = getObjectByID(cargoVehId)
  local pending = false
  for _, id in ipairs(carrierIds) do
    if id ~= cargoVehId and not isActiveCargoTaskVehId(id) then
      local carrier = getObjectByID(id)
      if memberCanBedCarry(carrier) then
        local supported, waiting = cargoOnMemberBed(cargo, carrier)
        if supported then return id end
        pending = pending or waiting == true
      end
      if memberHasRepoWheelLift(carrier) and cargoOnMemberWheelLift(cargo, carrier) then return id end
    end
  end
  return nil, pending
end

local function isVehicleDeliveryVehicle(vehId)
  for _, taskData in ipairs(vehicleTasks) do
    if taskData.vehId == vehId then
      return true
    end
  end
  return false
end
M.isVehicleDeliveryVehicle = isVehicleDeliveryVehicle

local function giveBackDeliveryVehicle(vehId)
  for _, taskData in ipairs(vehicleTasks) do
    if taskData.vehId == vehId then
      local employment = career_modules_delivery_employment
      if employment and employment.isAssignedVehicleOffer and employment.isAssignedVehicleOffer(taskData.offer) then
        ui_message('Abandon the company assignment from Employment so its held pay and equipment are settled together.', 8, 'warning')
        return false
      end
      taskData.giveBack = true
      return
    end
  end
end
M.giveBackDeliveryVehicle = giveBackDeliveryVehicle

function M.reportVehicleUndeliverable(vehId)
  for _, taskData in ipairs(vehicleTasks) do
    if taskData.vehId == vehId and not taskData.remove and not taskData.finished and not taskData.giveBack then
      taskData.undeliverable = true
      taskData.giveBack = true
      return true
    end
  end
  return false
end

function M.cancelUnmovedTransfer(offerId)
  local transfer = gameplay_vehicleTransfer
  if not (transfer and transfer.canCancelUnmovedOffer and transfer.canCancelUnmovedOffer(offerId)) then return false end
  for _, taskData in ipairs(vehicleTasks) do
    if taskData.offer.id == offerId and not taskData.remove and not taskData.finished and not taskData.giveBack then
      ejectPlayerFromTaskVehicle(taskData.vehId)
      taskData.remove = true
      deleteTaskVehicle(taskData.vehId)
      clearVehicleTasklistEntry(taskData)
      taskDataRemoveThisFrame = true
      return true
    end
  end
  return false
end

local function getVehicleTasks()
  return vehicleTasks
end
M.getVehicleTasks = getVehicleTasks

function M.shelveOffMapTask(taskData)
  if not taskData or taskData.remove then return end
  taskData.remove = true
  taskDataRemoveThisFrame = true
  clearVehicleTasklistEntry(taskData)
end

function M.canReturnBrokerEquipment(vehId)
  fillHaulerGroup(vehId)
  if #haulGroupScratch>1 then return false,'Uncouple the equipment before returning it.' end
  local carrier=getObjectByID(vehId)
  for _,task in ipairs(vehicleTasks) do
    if not task.remove then
      local cargo = getObjectByID(task.vehId)
      if cargoOnMemberBed(cargo,carrier,true)
          or (memberHasRepoWheelLift(carrier) and cargoOnMemberWheelLift(cargo,carrier)) then
        return false,'Unload the carried vehicles before returning this equipment.'
      end
    end
  end
  return true
end

local function getFineForAbandonAllVehicleTasks(forSave)
  local fine = {}
  for _, taskData in ipairs(vehicleTasks) do
    if not (forSave and taskData.offer.brokerId and career_modules_inventory.getInventoryIdFromVehicleId(taskData.vehId)) then
    for attKey, amount in pairs(M.getFineForAbandon(taskData)) do
      fine[attKey] = (fine[attKey] or 0) + amount
    end
    end
  end
  return fine
end
M.getFineForAbandonAllVehicleTasks = getFineForAbandonAllVehicleTasks

local function abandonAllVehicleTasks()
  for _, taskData in ipairs(vehicleTasks) do
    taskData.remove = true
    if career_modules_delivery_broker then career_modules_delivery_broker.onBrokerVehicleAbandoned(taskData.offer) end
    deleteTaskVehicle(taskData.vehId, taskData.offer.vehicle.inventoryId)
  end
  vehicleTasks = {}
end
M.abandonAllVehicleTasks = abandonAllVehicleTasks

local function getVehicleTaskForOffer(offer)
  for _, task in ipairs(vehicleTasks) do
    if task.offer.id == offer.id then
      return task
    end
  end
  return nil
end
M.getVehicleTaskForOffer = getVehicleTaskForOffer

-- DEBUG part
local im = ui_imgui
M.debugOrder = 12
M.debugName = "Delivery > Trailer Tasks"
local function drawDebugMenu()
  if im.Begin("Trailer Tasks Debug") then
    im.Text(dumps(vehicleTasks))

  end
  im.End()
end

M.drawDebugMenu = drawDebugMenu
M.onTrailerAttached = onTrailerAttached
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleDestroyed = function(id)
  clearRepoLiftCache(id)
  haulSupport.invalidate(id)
end
M.onVehicleSpawned = function(id)
  clearRepoLiftCache(id)
  haulSupport.invalidate(id)
end
M.onVehicleResetted = function(id)
  clearRepoLiftCache(id)
  haulSupport.invalidate(id)
end
M.onClientEndMission = function()
  table.clear(haulSupport.topology)
  table.clear(haulSupport.pairs)
  clearRepoLiftCache()
  lastHaulerVehId = nil
end
M.navigateToNextTask = navigateToNextTask

return M
