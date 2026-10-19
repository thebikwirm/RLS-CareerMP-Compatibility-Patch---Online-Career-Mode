-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {"core_vehicleBridge"}
local moduleVersion = 42
local dParcelManager, dCargoScreen, dGeneral, dGenerator, dProgress, dVehicleTasks, dTasklist, dParcelMods, dVehOfferManager, dTutorial, dMaterialContracts, dOwnerOpContracts
local step
local parkingReservation = require('gameplay/parkingReservation')
local persistence = require('gameplay/delivery/persistence')
local poiCargoSnapshot = setmetatable({}, {__mode = "k"})

local function clearDeliveryParkingReservations()
  poiCargoSnapshot = setmetatable({}, {__mode = "k"})
  parkingReservation.setDeliveryDestinations({})
end
M.onClientEndMission = clearDeliveryParkingReservations
M.onExtensionUnloaded = clearDeliveryParkingReservations

-- Reloads / activate races can leave these upvalues nil while career is already
-- active and markerInteraction is asking for POIs. Rebind from globals on demand.
local function bindDeliveryDeps()
  dParcelManager = career_modules_delivery_parcelManager
  dCargoScreen = career_modules_delivery_cargoScreen
  dGeneral = career_modules_delivery_general
  dGenerator = career_modules_delivery_generator
  dProgress = career_modules_delivery_progress
  dVehicleTasks = career_modules_delivery_vehicleTasks
  dTasklist = career_modules_delivery_tasklist
  dParcelMods = career_modules_delivery_parcelMods
  dVehOfferManager = career_modules_delivery_vehicleOfferManager
  dTutorial = career_modules_delivery_tutorial
  dMaterialContracts = career_modules_delivery_materialContractManager
  dOwnerOpContracts = career_modules_delivery_ownerOpContracts
  step = util_stepHandler
  return dParcelManager and dProgress and dVehicleTasks and dTutorial
end

-- Optional facility-generator offerMode: employment, independent, or shared (default).
-- This is the common cargo-board/dispatch boundary, regardless of map or authoring tool.
function M.isOfferAvailable(item, audience)
  if not item then return false end
  if audience == 'employment' and (item.brokerId or (item.data and item.data.brokerId)) then return false end
  if item.employmentAssigned and audience ~= "employment" then return false end
  local mode = item.offerMode
  if not mode or mode == "shared" then return true end
  return mode == (audience or "independent")
end

function M.canAcceptOffer(item, audience)
  if not M.isOfferAvailable(item, audience) then return false end
  if item.offerMode ~= "employment" then return true end
  local employment = career_modules_delivery_employment
  local company = employment and employment.getEmployerOrgId and employment.getEmployerOrgId()
  return company ~= nil and (not item.organization or item.organization == company)
end

function M.migrateOfferAccess(item)
  if not item then return end
  item.offerMode = item.offerMode or item.plannerMode
  item.organization = item.organization or item.plannerCompanyId
  item.plannerMode=nil; item.plannerLineId=nil; item.plannerCompanyId=nil
  item.plannerDefinitionVersion=nil; item._plannerAccepted=nil
end

local function installParcelAccess()
  if not dParcelManager or dParcelManager._deliveryAccess then return end
  dParcelManager._deliveryAccess=true
  local change = dParcelManager.changeCargoLocation
  dParcelManager.changeCargoLocation = function(id, location)
    local cargo = dParcelManager.getCargoById(id)
    if cargo then cargo.logisticsBinding = nil; cargo.logisticsPending = nil end
    local result = change(id, location)
    if cargo then persistence.captureCargo(cargo) end
    return result
  end
  local list=dParcelManager.getAllCargoForFacilityUnexpiredUndelivered
  dParcelManager.getAllCargoForFacilityUnexpiredUndelivered=function(facId, minTime, maxTime, audience)
    local out={}
    for _, cargo in ipairs(list(facId, minTime, maxTime)) do
      if M.isOfferAvailable(cargo,audience) then out[#out+1]=cargo end
    end
    return out
  end
  local move=dParcelManager.addTransientMoveCargo
  dParcelManager.addTransientMoveCargo=function(id,target)
    local cargo=dParcelManager.getCargoById(id)
    if cargo and cargo.offerMode == "employment" then
      local employment=career_modules_delivery_employment
      if not M.canAcceptOffer(cargo,"employment") or not (employment and employment.isAssignedCargo and employment.isAssignedCargo(cargo)) then return false end
    end
    return move(id,target)
  end
end

local function ensureOwnerOpContracts()
  if not career_modules_delivery_ownerOpContracts and extensions and extensions.load then
    pcall(extensions.load, "career_modules_delivery_ownerOpContracts")
  end
  dOwnerOpContracts = career_modules_delivery_ownerOpContracts
  return dOwnerOpContracts
end

M.onCareerActivated = function()
  bindDeliveryDeps()
end

-- Discover available cargo while loading/screens are open, not during marker refreshes.
local function refreshPoiCargoSnapshot()
  if not bindDeliveryDeps() or not dParcelManager.getAllCargoCustomFilter then return end
  local snapshot = setmetatable({}, {__mode = "k"})
  dParcelManager.getAllCargoCustomFilter(function(cargo)
    snapshot[cargo] = true
    return false
  end)
  poiCargoSnapshot = snapshot
end
M.refreshPoiCargoSnapshot = refreshPoiCargoSnapshot
M.onCargoGenerated = function(cargo)
  poiCargoSnapshot[cargo] = true
end

local function getPoiCargoCounts()
  local counts = {}
  local now = dGeneral.time()
  for cargo in pairs(poiCargoSnapshot) do
    local loc = cargo.location
    if loc and loc.type == "facilityParkingspot" and loc.facId and loc.psPath
        and cargo.offerExpiresAt > now
        and cargo.generatedAtTimestamp <= math.huge
        and dParcelManager.sameLocation(loc, {type = "facilityParkingspot", facId = loc.facId, psPath = loc.psPath})
        and not dParcelManager.sameLocation(loc, cargo.destination) then
      counts[loc.facId] = counts[loc.facId] or {}
      local spots = counts[loc.facId]
      spots[loc.psPath] = (spots[loc.psPath] or 0) + 1
    end
  end
  return counts
end

-- World drop-offs are baked into gameplay_rawPois once. Pause unsticks them only
-- because nearbyActivities calls clear() after career/cargo is actually ready.
-- Rebuild on the next updates so we do not cache an empty list from the first pass.
local deliveryPoiRefreshFrames = nil
local deliveryPoiRefreshTries = 0
local MAX_DELIVERY_POI_REFRESH_TRIES = 90
local lastInteractivePoiKey = nil
local refreshDeliveryWorldPoisIfChanged

local function requestDeliveryPoiRefresh(resetTries)
  deliveryPoiRefreshFrames = 2
  if resetTries then
    deliveryPoiRefreshTries = 0
  end
end

local function refreshDeliveryWorldPoisIfPending()
  if not deliveryPoiRefreshFrames then return end
  deliveryPoiRefreshFrames = deliveryPoiRefreshFrames - 1
  if deliveryPoiRefreshFrames > 0 then return end
  deliveryPoiRefreshFrames = nil
  deliveryPoiRefreshTries = deliveryPoiRefreshTries + 1
  if deliveryPoiRefreshTries > MAX_DELIVERY_POI_REFRESH_TRIES then
    return
  end
  if not bindDeliveryDeps() then
    deliveryPoiRefreshFrames = 2
    return
  end
  if gameplay_rawPois and gameplay_rawPois.clear then
    gameplay_rawPois.clear()
  end
end
M.requestDeliveryPoiRefresh = requestDeliveryPoiRefresh

M.onPlayerAttributesChanged = function(change)
  -- Owner-operator access can change without any active cargo changing. Rebuild
  -- cached inspection/map markers after the XP and unlock listeners have settled.
  local logisticsXp = change and change["logistics-delivery"]
  if logisticsXp and logisticsXp ~= 0 then
    requestDeliveryPoiRefresh(true)
  end
end

local deliveryGameTime = 0
local deliveryGameTimePaused = false
local deliveryGameTimeReady = false

local deliveryModeActive = false
local deliveryAbandonPenaltyFactor = 0.1
M.getDeliveryAbandonPenaltyFactor = function() return deliveryAbandonPenaltyFactor end

local function fireCargoAbandonedNotification(penaltyAmount)
  if not penaltyAmount or penaltyAmount >= 0 then return end
  if not ui_phone_layout and extensions and extensions.load then
    pcall(extensions.load, "ui_phone_layout")
  end
  if ui_phone_layout and ui_phone_layout.fireNotification then
    ui_phone_layout.fireNotification("logistics.cargoAbandoned", {
      title = "Cargo Abandoned",
      message = string.format("Penalty: $%0.2f", -penaltyAmount),
      kind = "warning",
      ttl = 8,
      source = "Logistics",
      sound = { soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open" },
    })
  end
end



-- Career general systems interaction (save/load, level setup)

local saveFile = "logisticsDatabase.json"
local loadData = {}
local function loadSaveData()
  local saveSlot, savePath = career_saveSystem.getCurrentProfile()
  if not saveSlot then return end

  local saveInfo = savePath and jsonReadFile(savePath .. "/info.json")
  local outdated = not saveInfo or saveInfo.version < moduleVersion

  local data = (not outdated and savePath and jsonReadFile(savePath .. "/career/"..saveFile)) or {}

  loadData = data
  local savedMap = persistence.savedMap(data.persistentJobs)
  if data.persistentJobs then
    loadData.materialContracts = savedMap and savedMap.materialContracts
    loadData.ownerOpContracts = savedMap and savedMap.ownerOpContracts
  end
  dProgress.setProgress(loadData.progress)
  dParcelMods.setProgress(loadData.parcelModProgress)
  loadData.facilities = loadData.facilities or {}
  loadData.settings = data.settings or {}

  if loadData.settings.automaticRoute == nil then
    loadData.settings.automaticRoute = true
  end

  deliveryGameTime = loadData.general and loadData.general.gameTime or deliveryGameTime
  deliveryGameTimeReady = true
  if loadData.general and loadData.general.osTime then
    log("I","",string.format("Save data age: %ds",os.time() - loadData.general.osTime))
    -- delete save data if the save is older than an hour
    if os.time() - loadData.general.osTime > 3600 then
      log("I","",string.format("Save data is older than 3600s (%d), wiping cargo and facility timers",os.time() - loadData.general.osTime))
      loadData.cargo = {}
      for key, fac in pairs(loadData.facilities) do
        fac.logisticGenerators = nil
      end
    end
  end

  --log("I","",string.format("Loaded save data for logistics: %d cargo", #loadData.cargo))
end
M.loadSaveData = loadSaveData
local function saveableCargoFilter(cargo)
  local employment=career_modules_delivery_employment
  if employment and employment.isAssignedCargo and employment.isAssignedCargo(cargo) then return false end
  -- Reservation ledgers save uncollected material; persistentJobs saves the
  -- actual accepted vehicle loads, including quantities already in transit.
  if cargo.data and cargo.data.materialContractId then return false end
  if cargo.data and cargo.data.passiveBusinessSupplyReservationId then return false end
  if cargo.data and cargo.data.engineShopSupplyReservationId then return false end
  return cargo.offerExpiresAt > M.time() and cargo.location.type == "facilityParkingspot"
end
local function onSaveCurrentProfile(currentSavePath)
  local filePath = currentSavePath .. "/career/" .. saveFile
  local saveData = {
    general = {},
    persistentJobs = persistence.serialize(),
    parcels = {},
    vehicleOffers = {},
    facilities = {},
    settings = loadData.settings or {},
    materialContracts = dMaterialContracts and dMaterialContracts.serialize() or nil,
    ownerOpContracts = ensureOwnerOpContracts() and dOwnerOpContracts.serialize() or nil,
    broker = career_modules_delivery_broker and career_modules_delivery_broker.serialize() or nil,
  }

  -- general data
  saveData.general.gameTime = M.time()
  saveData.general.osTime = os.time()
  saveData.progress = dProgress.getProgress()
  saveData.parcelModProgress = dParcelMods.getProgress()

  -- facility data

  -- parcels
  local saveableCargo = dParcelManager.getAllCargoCustomFilter(saveableCargoFilter)
  local maxGroupId = 0
  local groupMap = {}
  for _, cargo in ipairs(saveableCargo) do
    local elem = {
      rewards = cargo.rewards,
      templateId = cargo.templateId,
      offerMode = cargo.offerMode,
      name = cargo.name,
      type = cargo.type,
      slots = cargo.slots,
      offerExpiresAt = cargo.offerExpiresAt,
      location = cargo.location,
      origin = cargo.origin,
      destination = cargo.destination,
      data = cargo.data,
      generatorLabel = cargo.generatorLabel,
      modifiers = cargo.modifiers,
      generatedAtTimestamp = cargo.generatedAtTimestamp,
      weight = cargo.weight,
      density = cargo.density,
      groupSeed = cargo.groupSeed,
      automaticDropOff = cargo.automaticDropOff,
      organization = cargo.organization,
      materialType = cargo.materialType,
      merge = cargo.merge,
      sourceStorage = cargo.sourceStorage,
      hiddenInFacility = cargo.hiddenInFacility,
    }
    if not groupMap[cargo.groupId] then
      maxGroupId = maxGroupId + 1
      groupMap[cargo.groupId] = maxGroupId
    end
    elem.groupId = groupMap[cargo.groupId]
    table.insert(saveData.parcels, elem)
  end
  saveData.general.maxGroupId = maxGroupId

  local saveableVehicleOffers = dVehOfferManager.getAllSaveableOffers()
  for _, offer in ipairs(saveableVehicleOffers) do
    -- vehicle offers dont need to be trunkated/cut before saving
    table.insert(saveData.vehicleOffers, offer)
  end

  -- facility data
  for _, facility in ipairs(dGenerator.getFacilities()) do
    local elem = {
      logisticGenerators = {},
      progress = facility.progress,
      materialStorages = facility.materialStorages,
    }
    for i, generator in ipairs(facility.logisticGenerators or {}) do
      elem.logisticGenerators[i] = {
        nextGenerationTimestamp = generator.nextGenerationTimestamp
      }
    end
    saveData.facilities[facility.id] = elem
  end

  -- save the data to file
  career_saveSystem.jsonWriteFileSafe(filePath, saveData, true)
end
M.onSaveCurrentProfile = onSaveCurrentProfile

local persistenceLoadedMap = nil
local logisticsSetupBusy = false
local lastSetupHadProviders = false

local function currentMapId()
  return getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
end

local function mapHasDeliveryProviders(mapId)
  if not (freeroam_facilities and freeroam_facilities.getFacilitiesByType) then return false end
  local providers = freeroam_facilities.getFacilitiesByType("deliveryProvider", mapId)
  return type(providers) == "table" and providers[1] ~= nil
end

local function generatorNeedsResync(mapId)
  if not dGenerator then return true end
  local setupId = dGenerator.getSetupLevelIdentifier and dGenerator.getSetupLevelIdentifier()
  if setupId ~= mapId then return true end
  local hasFacilities = dGenerator.hasFacilities and dGenerator.hasFacilities()
  if hasFacilities then return false end
  return mapHasDeliveryProviders(mapId) and not lastSetupHadProviders
end

local function levelSwitchInProgress()
  local switchState = career_career.getLevelSwitchState and career_career.getLevelSwitchState()
  local phase = switchState and switchState.phase
  return phase ~= nil and phase ~= "idle"
end

local function ensureSetupForCurrentMap(force)
  if logisticsSetupBusy then return persistenceLoadedMap == currentMapId() end
  if not (career_career and career_career.isActive and career_career.isActive()) then return false end
  if not bindDeliveryDeps() then
    log("E", "delivery", "ensureSetupForCurrentMap: delivery deps not ready (parcelManager missing)")
    return false
  end
  local mapId = currentMapId()
  if not mapId or mapId == '' then return false end
  if force then
    persistenceLoadedMap = nil
    lastSetupHadProviders = false
  elseif levelSwitchInProgress() then
    return false
  elseif persistenceLoadedMap == mapId and not generatorNeedsResync(mapId) then
    return true
  end

  logisticsSetupBusy = true
  local ok, result = xpcall(function()
    log("I", "delivery", string.format("Setting up logistics for map %s (was %s)",
      tostring(mapId), tostring(dGenerator.getSetupLevelIdentifier and dGenerator.getSetupLevelIdentifier())))
    loadSaveData()
    map.assureLoad()
    installParcelAccess()
    if dVehOfferManager.resetOffersForLoad then dVehOfferManager.resetOffersForLoad() end
    dGenerator.setup(loadData)
    refreshPoiCargoSnapshot()
    persistence.load(loadData.persistentJobs)
    if dMaterialContracts then
      dMaterialContracts.setup(loadData.materialContracts)
    end
    if not career_modules_delivery_broker then extensions.load('career_modules_delivery_broker') end
    if career_modules_delivery_broker then career_modules_delivery_broker.setup(loadData.broker) end
    if ensureOwnerOpContracts() then
      dOwnerOpContracts.setup(loadData.ownerOpContracts)
    end
    persistence.restore()
    lastSetupHadProviders = mapHasDeliveryProviders(mapId)
    local ready = (dGenerator.hasFacilities and dGenerator.hasFacilities()) or not lastSetupHadProviders
    persistenceLoadedMap = ready and mapId or nil
    requestDeliveryPoiRefresh(true)
    return ready
  end, debug.traceback)
  logisticsSetupBusy = false
  if not ok then
    persistenceLoadedMap = nil
    lastSetupHadProviders = false
    log("E", "delivery", "ensureSetupForCurrentMap failed:\n" .. tostring(result))
    return false
  end
  return result and true or false
end
M.ensureSetupForCurrentMap = ensureSetupForCurrentMap

local function onCareerActive(active)
  if not active then
    persistenceLoadedMap = nil
    lastSetupHadProviders = false
    deliveryModeActive = false
    persistence.reset()
    clearDeliveryParkingReservations()
    return
  end
  ensureSetupForCurrentMap()
end
M.onCareerActive = onCareerActive
M.onBeforeCareerLevelSwitch = function()
  persistenceLoadedMap = nil
  lastSetupHadProviders = false
end
M.onCareerMapTravelCompleted = function()
  ensureSetupForCurrentMap(true)
end
M.onWorldReadyState = function(state)
  if state == 2 then ensureSetupForCurrentMap() end
end


local fast = 1
M.time = function() return deliveryGameTime end
M.isGameTimeReady = function() return deliveryGameTimeReady end



-- vehicle management

local function getVehicleName(vehId)
  local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
  local niceVehicleName = inventoryId and career_modules_inventory.getVehicleNiceNameTranslated(inventoryId)
  if type(niceVehicleName) == "string" and niceVehicleName ~= "" then
    return niceVehicleName
  end
  return core_locales.contextTranslate("ui.career.delivery.general.vehicleFallback", {id = vehId})
end
M.getVehicleName = getVehicleName


local mostRecentCargoContainerData = {}
local nearbyRadius = 40*40
local sortByVehIdAndContainerId = function(a,b) if a.vehId == b.vehId then return a.containerId < b.containerId else return a.vehId < b.vehId end end
local warnedInvalidCargoContainerResponses = {}
local function getCargoContainerListFromBridge(response, vehId)
  if type(response) == "table" and type(response[1]) == "table" then
    return response[1]
  end

  if not warnedInvalidCargoContainerResponses[vehId] then
    warnedInvalidCargoContainerResponses[vehId] = true
    local reason = type(response) == "table" and response.failReason or nil
    log("W", "", string.format(
      "Ignoring invalid cargo-container response from vehicle %s%s.",
      tostring(vehId),
      reason and (": " .. tostring(reason)) or ""
    ))
  end
  return {}
end

local function getNearbyVehicleCargoContainers(callback, vehicleIds)
  if not core_vehicleBridge then
    callback({})
    return
  end
  local vehCargoData = {}
  local playerPos = getPlayerVehicle(0)
  playerPos = playerPos and playerPos:getPosition() or core_camera.getPosition()
  local vehs = {}
  local refNodeClusterIdByVehId = {}
  local footprintSet = {}
  if overhaul_playerVehicles and overhaul_playerVehicles.fillInteractionVehicleIds then
    local footprint = {}
    overhaul_playerVehicles.fillInteractionVehicleIds(footprint)
    for i = 1, #footprint do
      footprintSet[footprint[i]] = true
    end
  end
  for vehId, veh in activeVehiclesIterator() do
    if veh:getJBeamFilename() ~= "unicycle" and veh.playerUsable ~= false then
      local nearCab = playerPos and (playerPos-veh:getPosition()):squaredLength() < nearbyRadius
      if (vehicleIds and vehicleIds[vehId]) or (not vehicleIds and (footprintSet[vehId] or nearCab)) then
        vehCargoData[vehId] = -1
        vehs[vehId] = veh
        refNodeClusterIdByVehId[vehId] = veh:getNodeClusterId(veh:getRefNodeId())
      end
    end
  end
  for vehId, veh in pairs(vehs) do

    core_vehicleBridge.requestValue(veh, function(vehCargoContainerData)
      vehCargoData[vehId] = {}

      for _, container in ipairs(getCargoContainerListFromBridge(vehCargoContainerData, vehId)) do
        if type(container) ~= "table" or container.id == nil then
          local warningKey = "container:" .. tostring(vehId)
          if not warnedInvalidCargoContainerResponses[warningKey] then
            warnedInvalidCargoContainerResponses[warningKey] = true
            log("W", "", string.format("Skipping malformed cargo container from vehicle %s: %s", tostring(vehId), dumps(container)))
          end
          goto continue
        end

        local cargoTypes = type(container.cargoTypes) == "table" and container.cargoTypes or {}
        local capacity = tonumber(container.capacity) or 0
        local vehName = getVehicleName(vehId)
        local elem = {
          vehId = vehId,
          containerId = container.id,
          location = {type = "vehicle", vehId = veh:getID(), containerId = container.id},
          vehName = vehName,
          name = container.name or "Unnamed Container",
          moveToLabel = vehName .. " " .. (container.name or "Unnamed Container"),
          cargoTypesLookup = tableValuesAsLookupDict(cargoTypes),
          cargoTypesString = table.concat(cargoTypes,", "),
          totalCargoSlots = capacity,
          usedCargoSlots = 0,
          transientCargoSlots = 0,
          freeCargoSlots = capacity,
          refNodeClusterId = refNodeClusterIdByVehId[vehId],
          clusterId = container.nodeId and veh:getNodeClusterId(container.nodeId),
          position = (container.nodeId and veh:getNodePosition(container.nodeId) or vec3(0,0,0)) + veh:getPosition(),
        }


        if not elem.clusterId or elem.refNodeClusterId == elem.clusterId then
          elem.attachmentStatus = "attached"
        else
          local dist = (elem.position-veh:getPosition()):length()
          if dist < 10 then
            elem.attachmentStatus = "nearby"
          else
            elem.attachmentStatus = "lost"
          end
        end
        elem.rawCargo = dParcelManager.getAllCargoForLocation(elem.location)

        elem.transientCargo = dParcelManager.getTransientMovesForTargetLocationWithCargo(elem.location)


        --for key, amount in pairs(elem.totalCargoSlots) do
        --  elem.usedCargoSlots[key] = 0
        --end
        for _, cargo in ipairs(elem.rawCargo) do
          elem.usedCargoSlots = elem.usedCargoSlots + cargo.slots
          elem.freeCargoSlots = elem.freeCargoSlots - cargo.slots
        end

        for _, cargo in ipairs(elem.transientCargo) do
          elem.usedCargoSlots = elem.usedCargoSlots + cargo.slots
          elem.transientCargoSlots = elem.transientCargoSlots + cargo.slots
          elem.freeCargoSlots = elem.freeCargoSlots - cargo.slots
        end

        table.insert(vehCargoData[vehId], elem)
        ::continue::
      end

      -- check if all cargo was sent
      for key, val in pairs(vehCargoData) do
        if val == -1 then return end
      end

      -- if we're still here, call the function callback to send data back
      local ret = {}
      for _, list in pairs(vehCargoData) do
        for _, elem in ipairs(list) do
          table.insert(ret, elem)
        end
      end
      table.sort(ret, sortByVehIdAndContainerId)
      if not vehicleIds then mostRecentCargoContainerData = ret end
      callback(ret)

    end, "getCargoContainers")
  end
  if not next(vehs) then
    callback({})
  end

end
M.getNearbyVehicleCargoContainers = getNearbyVehicleCargoContainers
M.getMostRecentCargoContainerData = function() return mostRecentCargoContainerData end

local function getCargoBridgeVehicle(vehId)
  local veh = scenetree.findObjectById(tonumber(vehId) or vehId)
  -- Remembered cargo IDs can outlive their vehicle or resolve to a scene prop.
  -- requestValue requires a vehicle Lua queue; unlike executeAction, it has no guard.
  return veh and veh.queueLuaCommand and veh or nil
end

local updateWeightsScheduled = false
local defaultWeightUpdateActive = false
local function defaultDelayCallback(data)
  defaultWeightUpdateActive = true
  extensions.hook("onDeliveryCargoLoadingStarted", data)
  local maxDelay = 0
  for _, delay in pairs(data) do
    maxDelay = math.max(delay, maxDelay)
  end
  if maxDelay > 0 then
    maxDelay = math.max(maxDelay, 1)
    -- make
    local sequence = {
      step.makeStepWait(maxDelay+0.5),
      step.makeStepReturnTrueFunction(function()
        for vehId, data in pairs(data) do
          local veh = getCargoBridgeVehicle(vehId)
          if veh then core_vehicleBridge.executeAction(veh, 'setFreeze', false) end
        end
        gameplay_markerInteraction.setForceReevaluateOpenPrompt()
        defaultWeightUpdateActive = false
        extensions.hook("onDeliveryCargoLoadingFinished", data)
      return true
      end
      )
    }
    step.startStepSequence(sequence, callback)
    -- add loading progress bar
    guihooks.trigger("OpenSimpleDelayPopup",{timer=maxDelay, heading=_tr("ui.career.delivery.general.loadingCargo")})
  else
    -- 1s delay, no freeze
    for vehId, data in pairs(data) do
      local veh = getCargoBridgeVehicle(vehId)
      if veh then core_vehicleBridge.executeAction(veh, 'setFreeze', false) end
    end
    gameplay_markerInteraction.setForceReevaluateOpenPrompt()
    defaultWeightUpdateActive = false
    extensions.hook("onDeliveryCargoLoadingFinished", data)
  end
  log("I","",string.format("%0.2fs delay after adjusting weights for cargo.", maxDelay))
end

M.isContainerWeightUpdatePending = function()
  return updateWeightsScheduled or defaultWeightUpdateActive
end
local rememberedCargoWeightVehicleIds = {}

local function isUnicycle(veh)
  return veh and veh.getJBeamFilename and veh:getJBeamFilename() == "unicycle"
end

local function rememberCargoWeightVehicle(vehId)
  vehId = tonumber(vehId) or vehId
  if vehId then
    rememberedCargoWeightVehicleIds[vehId] = true
  end
end

local function rememberCurrentCargoWeightVehicles()
  for _, cargo in ipairs(dParcelManager.getAllCargoInVehicles() or {}) do
    if cargo.location and cargo.location.vehId then
      rememberCargoWeightVehicle(cargo.location.vehId)
    end
  end
end

local function collectCargoWeightVehicleIds()
  local vehIds = {}
  for vehId, veh in activeVehiclesIterator() do
    if veh and not isUnicycle(veh) and veh.playerUsable ~= false then
      vehIds[vehId] = true
    end
  end
  for vehId in pairs(rememberedCargoWeightVehicleIds) do
    vehIds[vehId] = true
  end
  for _, cargo in ipairs(dParcelManager.getAllCargoInVehicles() or {}) do
    if cargo.location and cargo.location.vehId then
      vehIds[cargo.location.vehId] = true
    end
  end
  for _, container in ipairs(mostRecentCargoContainerData or {}) do
    if container.vehId then
      vehIds[container.vehId] = true
    end
  end
  return vehIds
end

M.requestUpdateContainerWeights = function() updateWeightsScheduled = true end
M.rememberCargoWeightVehicle = rememberCargoWeightVehicle
M.rememberCurrentCargoWeightVehicles = rememberCurrentCargoWeightVehicles
local function updateContainerWeights(delayCallback)
  if not updateWeightsScheduled then
    return
  end
  delayCallback = delayCallback or defaultDelayCallback
  updateWeightsScheduled = false
  log("I","","updateContainerWeights...")
  local updatePerVehicle = {}
  for vehId in pairs(collectCargoWeightVehicleIds()) do
    vehId = tonumber(vehId) or vehId
    local veh = getCargoBridgeVehicle(vehId)
    if veh and not isUnicycle(veh) then
      updatePerVehicle[vehId] = {}
    end
  end
  rememberedCargoWeightVehicleIds = {}
  for _, cargo in ipairs(dParcelManager.getAllCargoInVehicles()) do
    local vehId = cargo.location and cargo.location.vehId
    vehId = tonumber(vehId) or vehId
    if vehId and updatePerVehicle[vehId] then
      updatePerVehicle[vehId][cargo.location.containerId] = updatePerVehicle[vehId][cargo.location.containerId] or {
        volume = 0,
        density = 1,
        containerId = cargo.location.containerId
      }
      if not cargo.weight then log("W","","No weight on cargo? " .. dumps(cargo.name)) dump(cargo) end

      if cargo.type == "parcel" then
        -- add up load/weight
        updatePerVehicle[vehId][cargo.location.containerId].volume = updatePerVehicle[vehId][cargo.location.containerId].volume + (cargo.weight or 0)
      end

      if cargo.type == "fluid" or cargo.type == "dryBulk" or cargo.type == "cement" or cargo.type == "cash" then
        -- add up volume
        updatePerVehicle[vehId][cargo.location.containerId].volume = updatePerVehicle[vehId][cargo.location.containerId].volume + (cargo.slots or 0)
        local density = 1
        if cargo.slots and cargo.slots > 0 and cargo.weight then
          density = cargo.weight / cargo.slots
        end
        updatePerVehicle[vehId][cargo.location.containerId].density = density
      end
    end
  end
  --if next(updatePerVehicle) then
  for vehId, data in pairs(updatePerVehicle) do
    local veh = getCargoBridgeVehicle(vehId)
    if veh then
      core_vehicleBridge.executeAction(veh, "setCargoContainers", updatePerVehicle[vehId] or {}, "updateAll")
      core_vehicleBridge.executeAction(veh, 'setFreeze', true)

      if next(updatePerVehicle[vehId]) then
        for _, con in pairs(updatePerVehicle[vehId]) do
          log("I","",string.format("Container %d => volume %0.1f | density: %0.1f",con.containerId, con.volume or 0, con.density or 1))
        end
      else
        log("I","",string.format("Vehicle %s => emptied all cargo containers", tostring(vehId)))
      end
    end
  end

  -- check loading delay
  local delayData = {}
  for vehId, data in pairs(updatePerVehicle) do
    if getCargoBridgeVehicle(vehId) then
      delayData[vehId] = -1
    end
  end

  local delayCallbackCalled = false
  local function finishDelayCallback()
    if delayCallbackCalled then return end
    for _, delay in pairs(delayData) do
      if delay == -1 then return end
    end
    delayCallbackCalled = true
    delayCallback(delayData)
  end

  for vehId, _ in pairs(delayData) do
    local veh = getCargoBridgeVehicle(vehId)
    if veh then
      core_vehicleBridge.requestValue(veh, function(vehCargoContainerData)
        local maxForContainer = 0
        for _, container in ipairs(getCargoContainerListFromBridge(vehCargoContainerData, vehId)) do
          maxForContainer = math.max(maxForContainer, tonumber(container.reachTargetTimeRemaining) or 0)
        end
        delayData[vehId] = maxForContainer
        finishDelayCallback()

      end, "getCargoContainers")
    else
      delayData[vehId] = nil
    end
  end
  finishDelayCallback()

end
M.updateContainerWeights = updateContainerWeights


local colorForAttachmentDebug = {
  attached = ColorF(0.2,1,0.2, 0.75),
  nearby = ColorF(1,1,0.2, 0.75),
  lost = ColorF(1,0.2,0.2, 0.75),
}
local tickTimer = 0
M.setDeliveryTimePaused = function(paused) deliveryGameTimePaused = paused end
M.isDeliveryTimePaused = function() return deliveryGameTimePaused end
M.onUpdate = function(dtReal, dtSim, dtRaw)
  profilerPushEvent("Delivery DeliveryManager")
  refreshDeliveryWorldPoisIfPending()
  if refreshDeliveryWorldPoisIfChanged then
    refreshDeliveryWorldPoisIfChanged()
  end
  -- update game time
  --if freeroam_bigMapMode.bigMapActive() and not freeroam_bigMapMode.isTransitionActive() and not deliveryGameTimePaused then
    --deliveryGameTime = deliveryGameTime + dtReal * fast
  --else
  --end
  if not deliveryGameTimePaused then
    deliveryGameTime = deliveryGameTime + dtSim * fast
  end

  -- Old saves stored a speculative abandonment fine. Loading is not abandoning.
  loadData.penalty = nil

  tickTimer = tickTimer + dtSim
  if tickTimer > 1 then
    persistence.reconcile()
    M.getNearbyVehicleCargoContainers(nop)
    tickTimer = tickTimer - 1
  end

  -- check if container weights need to be updated, only if unpauses
  if dtSim > 10e-10 then
    M.updateContainerWeights()
  end

  -- debug display for cargo boxes
  --[[
  if deliveryModeActive then
    for _, container in ipairs(mostRecentCargoContainerData) do
      simpleDebugText3d(container.name, container.position, 0.15, colorForAttachmentDebug[container.attachmentStatus])
    end
  end
  ]]

  profilerPopEvent("Delivery DeliveryManager")
end


local function addInteractivePoi(list, id, field, elem)
  if not id or not list or not field then return end
  if not list[id] then
    list[id] = {dropOffs = {}, pickUps = {}, vehicles = {}, materialContracts = {}, businessSupplies = {}}
  end
  list[id][field] = list[id][field] or {}
  table.insert(list[id][field], elem)
end

local function collectPaidSupplyPickupLocations()
  local locations = {}
  local function addFrom(mod)
    if not (mod and mod.getPaidSupplyPickupLocations) then return end
    for _, loc in ipairs(mod.getPaidSupplyPickupLocations() or {}) do
      if loc and loc.psPath then
        locations[#locations + 1] = loc
      end
    end
  end
  addFrom(career_modules_business_passiveBusiness)
  addFrom(career_modules_business_engineShop)
  return locations
end
local function getInteractivePois()
  if not bindDeliveryDeps() then
    return {}, {}
  end
  local interactiveParkingSpots = {}
  local targetFacilityIds = {}
  local emp = career_modules_delivery_employment
  local filterParcelPins = emp and emp.isOnShift and emp.isOnShift()
    and emp.shouldShowParcelDropOffPin

  for _, cargo in ipairs(dParcelManager.getAllCargoInVehicles()) do
    if filterParcelPins and not emp.shouldShowParcelDropOffPin(cargo) then
      goto continueInteractiveCargo
    end
    local acceptingContracts = cargo.data and cargo.data.materialContractId and dMaterialContracts
      and dMaterialContracts.getContractsAcceptingMaterial(cargo.materialType) or nil
    if acceptingContracts and #acceptingContracts > 0 then
      local addedPaths = {}
      for _, contract in ipairs(acceptingContracts) do
        local destination = contract.destination
        if destination and destination.type == "facilityParkingspot" and destination.psPath and not addedPaths[destination.psPath] then
          addInteractivePoi(interactiveParkingSpots, destination.psPath, "dropOffs", cargo)
          addedPaths[destination.psPath] = true
          if destination.facId then targetFacilityIds[destination.facId] = true end
        end
      end
    elseif cargo.destination and cargo.destination.type == "facilityParkingspot" and cargo.destination.psPath then
      addInteractivePoi(interactiveParkingSpots, cargo.destination.psPath, "dropOffs", cargo)
      if cargo.destination.facId then
        targetFacilityIds[cargo.destination.facId] = true
      end
    elseif cargo.destination and cargo.destination.type == "multi" then
      for _, dest in ipairs(cargo.destination.destinations or {}) do
        if dest and dest.psPath then
          addInteractivePoi(interactiveParkingSpots, dest.psPath, "dropOffs", cargo)
        end
      end
    end
    ::continueInteractiveCargo::
  end

  for _, cargo in ipairs(dParcelManager.getTransientMoveCargo()) do
    if filterParcelPins and not emp.shouldShowParcelDropOffPin(cargo) then
      goto continueTransientCargo
    end
    local locPsPath = cargo.location and cargo.location.psPath
    if locPsPath then
      addInteractivePoi(interactiveParkingSpots, locPsPath, "pickUps", cargo)
    end
    ::continueTransientCargo::
  end

  -- Job Broker reservations waiting at their pickup make that spot a mission spot, so its
  -- "Pick Up" prompt opens on arrival like vanilla staged cargo, even mid-run.
  do
    local broker = career_modules_delivery_broker
    for _, pickup in ipairs(broker and broker.getReservedPickups and broker.getReservedPickups() or {}) do
      addInteractivePoi(interactiveParkingSpots, pickup.psPath, "brokerPickups", pickup)
      if pickup.facId then targetFacilityIds[pickup.facId] = true end
    end
  end

  -- figure out which facilities need to be active in order to drop of vehicles.
  local trailerTargetDestinations = dVehicleTasks.getTargetDestinationsForActiveTasks()
  for _, destination in ipairs(trailerTargetDestinations) do
    if destination and destination.facId then
      targetFacilityIds[destination.facId] = true
    end
    if destination and destination.psPath then
      addInteractivePoi(interactiveParkingSpots, destination.psPath, "vehicles", "vehicle")
    end
  end

  for _, activeContract in ipairs(dMaterialContracts and dMaterialContracts.getActiveContracts() or {}) do
    if activeContract.status == "active" and activeContract.origin
      and activeContract.origin.psPath
      and (activeContract.loadableAmount or 0) > 0 then
      addInteractivePoi(interactiveParkingSpots, activeContract.origin.psPath, "materialContracts", activeContract)
      if activeContract.origin.facId then
        targetFacilityIds[activeContract.origin.facId] = true
      end
    end
  end

  for _, loc in ipairs(collectPaidSupplyPickupLocations()) do
    addInteractivePoi(interactiveParkingSpots, loc.psPath, "businessSupplies", loc)
    if loc.facId then
      targetFacilityIds[loc.facId] = true
    end
  end

  return interactiveParkingSpots, targetFacilityIds
end

-- Pause unsticks drop-offs by clearing this cache. Any change to parcel, vehicle,
-- or trailer interactive spots must do the same or the world markers stay stale.
refreshDeliveryWorldPoisIfChanged = function()
  if not (career_career and career_career.isActive()) then
    clearDeliveryParkingReservations()
    return
  end
  if not bindDeliveryDeps() then return end
  local spots = getInteractivePois()
  local reservedPaths = {}
  for path, data in pairs(spots) do
    if next(data.dropOffs) or next(data.vehicles) then reservedPaths[path] = true end
  end
  -- Reserve accepted vehicle deliveries even before entering or coupling them.
  for _, taskData in ipairs(dVehicleTasks.getVehicleTasks()) do
    if not taskData.remove and not taskData.finished then
      for i = taskData.activeTaskIndex or 1, #(taskData.tasks or {}) do
        local destination = taskData.tasks[i].destination
        if destination and destination.psPath then reservedPaths[destination.psPath] = true end
      end
    end
  end
  parkingReservation.setDeliveryDestinations(reservedPaths)
  local keys = {}
  for path, _ in pairs(spots) do
    keys[#keys + 1] = path
  end
  table.sort(keys)
  local key = table.concat(keys, "|")
  if key == lastInteractivePoiKey then return end
  lastInteractivePoiKey = key
  if gameplay_rawPois and gameplay_rawPois.clear then
    gameplay_rawPois.clear()
  end
end

local function cargoBoardIsBlocked(facId)
  local emp = career_modules_delivery_employment
  if not emp then return false end
  return emp.getCargoBoardBlockMessage and emp.getCargoBoardBlockMessage(facId) ~= nil
end

local function canClockInAtFacility(facId)
  local emp = career_modules_delivery_employment
  return emp and emp.canOpenFacilityShiftUi and emp.canOpenFacilityShiftUi(facId) or false
end

local function isRoleplayFacility(facId)
  local emp = career_modules_delivery_employment
  return emp and emp.isRoleplayFacility and emp.isRoleplayFacility(facId) or false
end

local function hasCompanyShift()
  local emp = career_modules_delivery_employment
  if emp and emp.hasCompanyShift then
    return emp.hasCompanyShift()
  end
  return emp and emp.isOnShift and emp.isOnShift() or false
end

local function shouldShowFreelanceInspectAt(facId)
  local emp = career_modules_delivery_employment
  if emp and emp.shouldShowFreelanceInspectAt then
    return emp.shouldShowFreelanceInspectAt(facId)
  end
  if hasCompanyShift() then return false end
  if isRoleplayFacility(facId) then return false end
  return true
end

local function shouldShowShiftDropOff(elem, anyCargoDropOffable, vehsClose, trailersClose, dropOffable)
  if not anyCargoDropOffable then return false end
  if not hasCompanyShift() then return true end
  local emp = career_modules_delivery_employment
  if emp and emp.isEmployeeDropOffBlocked and emp.isEmployeeDropOffBlocked(elem.facId, elem.psPath) then
    return false
  end
  if emp and emp.shouldOpenEmployeeDropOff and emp.shouldOpenEmployeeDropOff(elem.facId, elem.psPath) then
    return true
  end
  if (vehsClose or 0) > 0 or (trailersClose or 0) > 0 then return true end
  dropOffable = dropOffable or {}
  if (dropOffable.fluid or 0) > 0 or (dropOffable.dryBulk or 0) > 0 or (dropOffable.cement or 0) > 0 then
    return true
  end
  return false
end

local function suppressInspectUiForDropOff(elem, showDropOff)
  if showDropOff then return true end
  local emp = career_modules_delivery_employment
  return emp and emp.willAutoOpenDropOffAt and emp.willAutoOpenDropOffAt(elem.facId, elem.psPath) or false
end

local function isInspectParkingSpot(facId, psPath)
  if not facId or not psPath or not dGenerator or not dGenerator.getFacilityById then
    return false
  end
  local fac = dGenerator.getFacilityById(facId)
  if not fac then return false end
  for _, ap in pairs(fac.accessPointsByName or {}) do
    if ap.isInspectSpot == true then
      local path = ap.psPath
      if not path and ap.ps and ap.ps.getPath then
        path = ap.ps:getPath()
      end
      if path == psPath then
        return true
      end
    end
  end
  return false
end

local function playerAtFacilityStall(psPath, includeCoupled)
  if not psPath then return false end
  if not dGenerator then bindDeliveryDeps() end
  local gen = dGenerator or career_modules_delivery_generator
  if not (gen and gen.getParkingSpotByPath) then return false end
  local spot = gen.getParkingSpotByPath(psPath)
  if not spot then return false end
  local veh = be and be.getPlayerVehicle and be:getPlayerVehicle(0)
  if not (veh and veh.getPosition) then return false end
  local walking = gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking()
  local function atStall(vehicle)
    if not walking then
      local vehId = vehicle.getID and vehicle:getID()
      if vehId and spot.checkParking and spot:checkParking(vehId, 0, 8, 2.5) then
        return true
      end
    end
    local pos = vehicle:getPosition()
    if spot.containsPoint and spot:containsPoint(pos) then return true end
    if not spot.pos then return false end
    local radius = 5
    if spot.scl then
      radius = math.max(math.abs(spot.scl.x or 0), math.abs(spot.scl.y or 0), 3) * 0.5 + 1.25
    end
    return (pos - spot.pos):length() <= radius
  end
  if atStall(veh) then return true end
  if includeCoupled and not walking and overhaul_playerVehicles
      and overhaul_playerVehicles.getPlayerVehicleIds then
    for _, vehId in ipairs(overhaul_playerVehicles.getPlayerVehicleIds()) do
      if vehId ~= veh:getID() then
        local attached = getObjectByID(vehId)
        if attached and attached.getPosition and atStall(attached) then return true end
        if attached and spot.pos and spot.rot and spot.scl and overlapsOBB_OBB then
          local center = vec3(be:getObjectOOBBCenterXYZ(vehId))
          local axis0 = vec3(be:getObjectOOBBHalfAxisXYZ(vehId, 0))
          local axis1 = vec3(be:getObjectOOBBHalfAxisXYZ(vehId, 1))
          local axis2 = vec3(be:getObjectOOBBHalfAxisXYZ(vehId, 2))
          if overlapsOBB_OBB(spot.pos, spot.rot * vec3(spot.scl.x / 2, 0, 0),
              spot.rot * vec3(0, spot.scl.y / 2, 0), spot.rot * vec3(0, 0, spot.scl.z / 2),
              center, axis0, axis1, axis2) then return true end
        end
      end
    end
  end
  return false
end
M.playerAtFacilityStall = playerAtFacilityStall

local function hasPaidBusinessSupplyAt(facId, psPath)
  local pb = career_modules_business_passiveBusiness
  if pb and pb.hasPaidSupplyAt and pb.hasPaidSupplyAt(facId, psPath) then return true end
  local es = career_modules_business_engineShop
  if es and es.hasPaidSupplyAt and es.hasPaidSupplyAt(facId, psPath) then return true end
  return false
end

local function addClockInActivity(activityData, template, facId)
  if not canClockInAtFacility(facId) then return end
  local emp = career_modules_delivery_employment
  local clockPoi = deepcopy(template)
  local onShift = emp.isOnShift and emp.isOnShift()
  local roleplay = isRoleplayFacility(facId)
  clockPoi.icon = "poi_delivery_round"
  if roleplay then
    clockPoi.heading = onShift and "On duty" or "Start shift"
    clockPoi.buttonLabel = onShift and "Open shift" or "Start shift"
    clockPoi.props = {{icon = "checkmark", keyLabel = onShift and "Continue your shift" or "Clock in and take a company vehicle"}}
  else
    clockPoi.heading = onShift and "Company shift" or "Clock in"
    clockPoi.buttonLabel = onShift and "Open shift" or "Clock in"
    clockPoi.props = {{icon = "checkmark", keyLabel = onShift and "Continue your company shift" or "Start your company shift"}}
  end
  clockPoi.buttonFun = function()
    emp.tryOpenFacilityShiftUi(facId)
  end
  table.insert(activityData, clockPoi)
end

-- poi list stuff
local function onGetRawPoiListForLevel(levelIdentifier, elements)
  if not (career_career and career_career.isActive()) then return end
  if not bindDeliveryDeps() then
    requestDeliveryPoiRefresh()
    return
  end

  --local nearbyVehicles = M.getNearbyVehicleCargoContainers()
  local interactiveParkingSpots, targetFacilityIds = getInteractivePois()
  local cargoCounts = getPoiCargoCounts()
  local isCargoDeliveryTutorialActive = dTutorial.isCargoDeliveryTutorialActive()
  local addedDropOff = false

  for _, fac in ipairs(freeroam_facilities.getFacilitiesByType("deliveryProvider") or {}) do
    -- only process facilities if the facility is visible
    local includeFac = dProgress.isFacilityVisible(fac.id, isCargoDeliveryTutorialActive) or targetFacilityIds[fac.id]
    do
      local empPins = career_modules_delivery_employment
      if empPins and empPins.shouldShowDeliveryFacilityWorldPin
          and not empPins.shouldShowDeliveryFacilityWorldPin(fac.id) then
        includeFac = targetFacilityIds[fac.id] and true or false
      end
    end

    if includeFac then
      local totalCargoCount = 0
      local lastPsPos = nil
      local boardBlocked = cargoBoardIsBlocked(fac.id)
      local canClockInHere = canClockInAtFacility(fac.id)

      -- look up all relevant parking spots for this facility
      local spotsForThisFacLookup = {}

      local hasInspectSpot = false
      for name, ap in pairs(fac.accessPointsByName or {}) do
        local ps = ap.ps
        if not (ps and ps.getPath) then goto continueAccessPoint end
        -- Loaner-only pads are not cargo inspect spots; skip walking markers unless
        -- the player has active cargo business at this exact stall.
        local isLoanerOnlySpot = ap.isLoanerVehicleSpot and not ap.isInspectSpot
        local id = string.format("delivery-parking-%s-%s", fac.id, ps:getPath())
        local loc = {type = "facilityParkingspot", facId = fac.id, psPath = ps:getPath()}
        local cargoCount = cargoCounts[fac.id] and cargoCounts[fac.id][ps:getPath()] or 0
        local canInspectCargo = ap.isInspectSpot == true
        if canInspectCargo then hasInspectSpot = true end
        totalCargoCount = totalCargoCount + cargoCount
        lastPsPos = ps.pos
        local icon = "poi_pickup_round"
        if interactiveParkingSpots[ps:getPath()] then
          icon = "poi_dropoff_round"
          addedDropOff = true
        end

        local psPath = ps:getPath()
        local missionSpot = interactiveParkingSpots[psPath] ~= nil
        local empMod = career_modules_delivery_employment
        local companyShift = hasCompanyShift()
        local empReturnHere = empMod and empMod.hasAssignedReturnCargoAtSpot
          and empMod.hasAssignedReturnCargoAtSpot(fac.id, psPath)
        local focus = missionSpot
        local missionInfo = missionSpot and interactiveParkingSpots[psPath] or nil
        local deliveringHere = missionInfo
          and (next(missionInfo.dropOffs) or next(missionInfo.vehicles)) and true or false
        local supplyHere = canInspectCargo and hasPaidBusinessSupplyAt(fac.id, psPath)
        local clockInHere = canInspectCargo and canClockInHere and not deliveringHere
        local inspectHere = canInspectCargo and shouldShowFreelanceInspectAt(fac.id) and not boardBlocked and not deliveringHere
        local showInspectPad = false
        -- Available offers belong at the acceptance pad. Separate work bays
        -- become visible through missionSpot/empReturnHere once needed.
        if canInspectCargo then
          showInspectPad = clockInHere
            or inspectHere
            or supplyHere
            or ((not companyShift) and cargoCount > 0 and not boardBlocked)
        end
        local showParkingMarker = missionSpot or empReturnHere or showInspectPad
        local elem = {
          id = id,
          data = {
            type = "logisticsParking",
            facId = fac.id,
            psPath = psPath,
            canInspectCargo = inspectHere,
            hasPlayerCargo = missionSpot,
            hasPaidSupply = supplyHere,
            hasPickup = missionInfo and (next(missionInfo.pickUps) ~= nil or next(missionInfo.brokerPickups or {}) ~= nil) or false,
            hasMaterialContract = missionSpot
              and next(interactiveParkingSpots[psPath].materialContracts) ~= nil or false,
            hasEmploymentReturn = empReturnHere,
            hasEmploymentClockIn = clockInHere,
          },
          markerInfo = {
            parkingMarker = showParkingMarker and {path = psPath, pos = ps.pos, rot = ps.rot, scl = ps.scl, icon = icon, focus = focus} or nil,
          }
        }
        --print(string.format("including: %s-%s (%s). visible: %s, target: %s",
        --  fac.id, ps.id,
        --  dParcelManager.getLocationLabelShort({type="facilityParkingspot", facId = fac.id, psPath = ps:getPath()}),
        --  dumps(dProgress.isFacilityVisible(fac.id)),
        --  dumps(targetFacilityIds[fac.id] and true or false)
        --  ))
        if dCargoScreen.isCargoScreenOpen() then
          elem.markerInfo.bigmapMarker = {pos = ps.pos, name = _tr("ui.career.delivery.general.pickupPrefix") .. _tr(fac.name), icon = icon}
        else
          if interactiveParkingSpots[ps:getPath()] then

            local tasks = {}
            if next(interactiveParkingSpots[ps:getPath()].dropOffs) then
              table.insert(tasks, core_locales.contextTranslate("ui.career.delivery.general.deliverCargoItemsHere", {count = #interactiveParkingSpots[ps:getPath()].dropOffs}))
            end
            if next(interactiveParkingSpots[ps:getPath()].pickUps) then
              table.insert(tasks, core_locales.contextTranslate("ui.career.delivery.general.pickUpCargoItemsHere", {count = #interactiveParkingSpots[ps:getPath()].pickUps}))
            end
            local reservedHere = interactiveParkingSpots[ps:getPath()].brokerPickups
            if reservedHere and next(reservedHere) then
              table.insert(tasks, #reservedHere == 1 and "Load 1 reserved parcel" or string.format("Load %d reserved parcels", #reservedHere))
            end
            if next(interactiveParkingSpots[ps:getPath()].vehicles) then
              table.insert(tasks, core_locales.contextTranslate("ui.career.delivery.general.deliverVehiclesHere", {count = #interactiveParkingSpots[ps:getPath()].vehicles}))
            end
            if next(interactiveParkingSpots[ps:getPath()].materialContracts) then
              for _, contract in ipairs(interactiveParkingSpots[ps:getPath()].materialContracts) do
                table.insert(tasks, string.format("Load %s - %d %s remaining", _tr(contract.materialName), math.floor((contract.remainingAmount or 0) + 0.5), contract.units or "L"))
              end
            end
            if next(interactiveParkingSpots[ps:getPath()].businessSupplies or {}) then
              table.insert(tasks, "Pick up paid supplies")
            end

            local desc = table.concat(tasks, '<br/>')
            elem.markerInfo.bigmapMarker = {
              pos = ps.pos,
              name = dParcelManager.getLocationLabelShort(loc),
              description = desc,
              icon = "poi_dropoff_round",
              previews = {fac.preview},
              thumbnail = fac.preview,
            }
          end
        end
        if showParkingMarker
            or (not isLoanerOnlySpot and dCargoScreen.isCargoScreenOpen()) then
          --dump(string.format("%s -> %s", fac.name, name))
          --dumpz(ap, 1)
          table.insert(elements, elem)
        end
        ::continueAccessPoint::
      end
      --[[
      -- add trailer spots in a separate entry.
      if dCargoScreen.isCargoScreenOpen() then
        for _, ps in ipairs(fac.trailerSpots) do

          local id = string.format("delivery-parking-%s-%s", fac.id, ps:getPath())
          local loc = {type = "facilityParkingspot", facId = fac.id, psPath = ps:getPath()}

          local icon = "poi_pickup_round"
          if interactiveParkingSpots[ps:getPath()] then
            icon = "poi_dropoff_round"
          end

          local elem = {
            id = id,
            data = {type = "logisticsParking", facId = fac.id, psPath = ps:getPath(), hasPlayerCargo = interactiveParkingSpots[ps:getPath()] and true or false },
            markerInfo = {
              bigmapMarker = {pos = ps.pos, name = "Pickup "..fac.name, icon = icon}
            }
          }
          table.insert(elements, elem)

        end

     end
]]
      -- one POI for the whole facility to display on bigmap under labourer branch.
      if not dCargoScreen.isCargoScreenOpen() then
        local providedLookup = fac.logisticTypesProvidedLookup
        local receivedLookup = fac.logisticTypesReceivedLookup
        local hasProvided = (providedLookup and next(providedLookup) ~= nil)
          or (fac.logisticTypesProvided and (fac.logisticTypesProvided[1] ~= nil or next(fac.logisticTypesProvided) ~= nil))
        local hasReceived = (receivedLookup and next(receivedLookup) ~= nil)
          or (fac.logisticTypesReceived and (fac.logisticTypesReceived[1] ~= nil or next(fac.logisticTypesReceived) ~= nil))
        if dProgress.isFacilityUnlocked(fac.id) and (hasProvided or (hasInspectSpot and hasReceived)) and (not boardBlocked or canClockInHere) then
          local id = string.format("logisticsFacility-%s", fac.id)
          local elems = {}
          if fac.doors and next(fac.doors) then
            freeroam_facilities.walkingMarkerFormatFacility(fac, elems)
          end

          local pos = lastPsPos
          for name, ap in pairs(fac.accessPointsByName or {}) do
            if ap.isInspectSpot and ap.ps then
              pos = ap.ps.pos
            end
          end

          local elem = {
            id = id,
            data = {type = "logisticsOffice", facId = fac.id},
            markerInfo = {
              walkingMarker = next(elems) and elems[1].markerInfo.walkingMarker or nil,
              bigmapMarker = {pos = pos, name = _tr(fac.name), description = core_locales.contextTranslate(totalCargoCount ~= 1 and "ui.career.delivery.general.facilityItemsAvailablePlural" or "ui.career.delivery.general.facilityItemsAvailableSingular", {description = _tr(fac.description), count = totalCargoCount}), icon="poi_delivery_round", previews = {fac.preview}, thumbnail = fac.preview,} or nil
            }
          }
          table.insert(elements, elem)
        end
      end
    end
  end
  if next(interactiveParkingSpots) and not addedDropOff then
    requestDeliveryPoiRefresh()
  end
end
M.onGetRawPoiListForLevel = onGetRawPoiListForLevel



local function onActivityAcceptGatherData(elemData, activityData)
  local employment = career_modules_delivery_employment
  local loaners = career_modules_loanerVehicles
  local blocked = employment and employment.getBlockedSpawnStatus and employment.getBlockedSpawnStatus()
  local blockedSource = "employment"
  if not blocked then
    blocked = loaners and loaners.getBlockedSpawnStatus and loaners.getBlockedSpawnStatus()
    blockedSource = "loaner"
  end
  if blocked and blocked.nearby then
    table.insert(activityData, {
      icon = "poi_delivery_round", heading = blockedSource == "employment" and "Company vehicle spawn area" or "Loaner vehicle spawn area",
      buttonLabel = "Spawn vehicle", disabled = not blocked.ready,
      sorting = {type = "logisticsParking", id = blockedSource == "employment" and "employment-spawn" or "loaner-spawn"},
      props = {{icon = "info", keyLabel = blocked.ready and "Area clear - ready to spawn" or "Clear the highlighted stalls first"}},
      buttonFun = function()
        if blockedSource == "employment" then
          employment.spawnBlockedEquipment()
        else
          loaners.spawnBlockedOffers()
        end
      end,
    })
  end
  for _, elem in ipairs(elemData) do
    if elem.type == "logisticsOffice" then
      local officeTemplate = {
        icon = "poi_delivery_round",
        heading = dGenerator.getFacilityById(elem.facId).name,
        preheadings = {_tr("ui.career.delivery.general.logisticsOffice")},
        sorting = {
          type = elem.type,
          id = elem.id
        },
        props = {},
      }
      addClockInActivity(activityData, officeTemplate, elem.facId)
    elseif elem.type == "logisticsParking" then

      -- cargo menu button
      local loc = {type = "facilityParkingspot", facId = elem.facId, psPath = elem.psPath}
      local poiTemplate = {
        icon = "poi_pickup_round",
        preheadings =  {dParcelManager.getLocationLabelShort({type = "facilityParkingspot", facId = elem.facId, psPath = elem.psPath})},
        props = {},
        sorting = {
          type = elem.type,
          id = elem.id
        },
      }

      -- dropoff data and props
      local psPos = dGenerator.getParkingSpotByPath(elem.psPath).pos
      local dropOffableCargoByCargoType = {
        parcel = 0,
        fluid = 0,
        dryBulk = 0,
        cement = 0,
        cash = 0
      }
      for _, container in ipairs(mostRecentCargoContainerData) do
        for _, cargo in ipairs(container.rawCargo) do
          local add = 1
          local type = cargo.type
          local isContractCargo = cargo.data and cargo.data.materialContractId and dMaterialContracts
          local acceptsContractMaterial = isContractCargo
            and dMaterialContracts.getMaterialDeliveryCapacity(cargo.materialType, {
              type = "facilityParkingspot", facId = elem.facId, psPath = elem.psPath
            }) > 0
          if cargo.type == "fluid" then
            type = "fluid"
            add = cargo.slots
          end
          if cargo.type == "dryBulk" then
            add = cargo.slots
          end
          if cargo.type == "cement" then
            add = cargo.slots
          end
          if cargo.type == "cash" then
            add = cargo.slots
          end
          if acceptsContractMaterial then
            dropOffableCargoByCargoType[type] = dropOffableCargoByCargoType[type]
              + (((container.position - psPos):squaredLength() < 40*40) and add or 0)
          elseif cargo.destination.type == "facilityParkingspot" then
            dropOffableCargoByCargoType[cargo.type]  = dropOffableCargoByCargoType[type] + ((cargo.destination.psPath == elem.psPath and (container.position - psPos):squaredLength() < 40*40) and add or 0)
          elseif cargo.destination.type == "multi" then
            for _, dest in ipairs(cargo.destination.destinations) do
              dropOffableCargoByCargoType[type]  = dropOffableCargoByCargoType[type] + ((dest.psPath == elem.psPath and (container.position - psPos):squaredLength() < 40*40) and add or 0)
            end
          end
        end
      end
      local vehsClose, trailersClose = dVehicleTasks.canDropOffCargoAtPsPath(elem.psPath)
      local anyCargoDropOffable = (dropOffableCargoByCargoType.parcel > 0 or dropOffableCargoByCargoType.fluid > 0 or dropOffableCargoByCargoType.dryBulk > 0 or dropOffableCargoByCargoType.cement > 0 or dropOffableCargoByCargoType.cash > 0) or vehsClose > 0 or trailersClose > 0
      local showDropOff = shouldShowShiftDropOff(elem, anyCargoDropOffable, vehsClose, trailersClose, dropOffableCargoByCargoType)
      local suppressInspect = suppressInspectUiForDropOff(elem, showDropOff)
      -- dropoff props
      if dropOffableCargoByCargoType.parcel > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = dropOffableCargoByCargoType.parcel > 1
            and core_locales.contextTranslate("ui.career.delivery.general.parcelsDropoff", {count = dropOffableCargoByCargoType.parcel})
            or _tr("ui.career.delivery.general.parcelDropoff")
        })
      end
      if dropOffableCargoByCargoType.fluid > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = core_locales.contextTranslate("ui.career.delivery.general.fluidDropoff", {volume = dropOffableCargoByCargoType.fluid})
        })
      end
      if dropOffableCargoByCargoType.dryBulk > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = core_locales.contextTranslate("ui.career.delivery.general.dryBulkDropoff", {volume = dropOffableCargoByCargoType.dryBulk})
        })
      end
      if dropOffableCargoByCargoType.cement > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = string.format("%dL cement dropoff", dropOffableCargoByCargoType.cement)
        })
      end
      if dropOffableCargoByCargoType.cash > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = string.format("%d cash dropoff", dropOffableCargoByCargoType.cash)
        })
      end
      if vehsClose > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = _tr("ui.career.delivery.general.vehicleDropoff")
        })
      end
      if trailersClose > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = _tr("ui.career.delivery.general.trailerDropoff")
        })
      end


      -- pickup data and props
      local pickUpAbleCargoByCargoType = {
        parcel = 0,
        fluid = 0,
        dryBulk = 0,
        cement = 0,
        cash = 0
      }
      for _, container in ipairs(mostRecentCargoContainerData) do
        for _, cargo in ipairs(container.transientCargo) do
          local add = 1
          local type = cargo.type
          if cargo.type == "fluid" then
            type = "fluid"
            add = cargo.slots
          end
          if cargo.type == "dryBulk" then
            add = cargo.slots
          end
          if cargo.type == "cement" then
            add = cargo.slots
          end
          if cargo.type == "cash" then
            add = cargo.slots
          end
          if cargo.location.type == "facilityParkingspot" then
            pickUpAbleCargoByCargoType[cargo.type]  = pickUpAbleCargoByCargoType[type] + ((cargo.location.psPath == elem.psPath and (container.position - psPos):squaredLength() < 40*40) and add or 0)
          end
        end
      end
      local anyCargoPickUpAble = (pickUpAbleCargoByCargoType.parcel > 0 or pickUpAbleCargoByCargoType.fluid > 0 or pickUpAbleCargoByCargoType.dryBulk > 0 or pickUpAbleCargoByCargoType.cement > 0 or pickUpAbleCargoByCargoType.cash > 0)
      if pickUpAbleCargoByCargoType.parcel > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = pickUpAbleCargoByCargoType.parcel > 1
            and core_locales.contextTranslate("ui.career.delivery.general.parcelsPickup", {count = pickUpAbleCargoByCargoType.parcel})
            or _tr("ui.career.delivery.general.parcelPickup")
        })
      end
      if pickUpAbleCargoByCargoType.fluid > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = core_locales.contextTranslate("ui.career.delivery.general.fluidPickup", {volume = pickUpAbleCargoByCargoType.fluid})
        })
      end
      if pickUpAbleCargoByCargoType.dryBulk > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = core_locales.contextTranslate("ui.career.delivery.general.dryBulkPickup", {volume = pickUpAbleCargoByCargoType.dryBulk})
        })
      end    
      if pickUpAbleCargoByCargoType.cement > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = string.format("%dL cement pickup", pickUpAbleCargoByCargoType.cement)
        })
      end
      if pickUpAbleCargoByCargoType.cash > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = string.format("%d cash pickup", pickUpAbleCargoByCargoType.cash)
        })
      end


      if not suppressInspect and isInspectParkingSpot(elem.facId, elem.psPath) and not isRoleplayFacility(elem.facId)
        and shouldShowFreelanceInspectAt(elem.facId) then
        -- available cargo data and props
        local availableCargoCountByCargoType = {
          parcel = 0,
          fluid = 0,
          dryBulk = 0,
          cement = 0,
          cash = 0,
        }
        for _, cargo in ipairs(dParcelManager.getAllCargoForFacilityUnexpiredUndelivered(elem.facId)) do
          local add = 1
          local type = cargo.type
          if cargo.type == "fluid" then
            type = "fluid"
            add = cargo.slots
          end
          if cargo.type == "dryBulk" then
            add = cargo.slots
          end
          if cargo.type == "cement" then
            add = cargo.slots
          end
          if cargo.type == "cash" then
            add = cargo.slots
          end
          availableCargoCountByCargoType[type] = availableCargoCountByCargoType[type] + add
        end
        -- Material availability is contract-based; raw facility stock is no
        -- longer freely loadable.
        for _, contract in ipairs(dMaterialContracts and dMaterialContracts.getOffersForFacility(elem.facId) or {}) do
          local template = dGenerator.getMaterialsTemplatesById(contract.materialType)
          if template then
            availableCargoCountByCargoType[template.type] = (availableCargoCountByCargoType[template.type] or 0) + contract.totalAmount
          end
        end
        for _, activeContract in ipairs(dMaterialContracts and dMaterialContracts.getActiveContracts() or {}) do
          if activeContract.sourceFacId == elem.facId then
            local template = dGenerator.getMaterialsTemplatesById(activeContract.materialType)
            if template then
              availableCargoCountByCargoType[template.type] = (availableCargoCountByCargoType[template.type] or 0) + activeContract.loadableAmount
            end
          end
        end

        if availableCargoCountByCargoType.parcel > 0 then
          table.insert(poiTemplate.props, {
            icon = "checkmark",
            keyLabel = core_locales.contextTranslate(availableCargoCountByCargoType.parcel ~= 1 and "ui.career.delivery.general.parcelsAvailable" or "ui.career.delivery.general.parcelAvailable", {count = availableCargoCountByCargoType.parcel})
          })
        end
        if availableCargoCountByCargoType.fluid > 0 then
          table.insert(poiTemplate.props, {
            icon = "checkmark",
            keyLabel = core_locales.contextTranslate("ui.career.delivery.general.fluidAvailable", {volume = availableCargoCountByCargoType.fluid})
          })
        end
        if availableCargoCountByCargoType.dryBulk > 0 then
          table.insert(poiTemplate.props, {
            icon = "checkmark",
            keyLabel = core_locales.contextTranslate("ui.career.delivery.general.dryBulkAvailable", {volume = availableCargoCountByCargoType.dryBulk})
          })
        end
        if availableCargoCountByCargoType.cement > 0 then
          table.insert(poiTemplate.props, {
            icon = "checkmark",
            keyLabel = string.format("%dL of cement available", availableCargoCountByCargoType.cement)
          })
        end
        if availableCargoCountByCargoType.cash > 0 then
          table.insert(poiTemplate.props, {
            icon = "checkmark",
            keyLabel = string.format("%d cash available", availableCargoCountByCargoType.cash)
          })
        end
        -- veh and trailer props
        local vehOffers, trailerOffers = {}, {}
        for _, offer in ipairs(dVehOfferManager.getAllOfferAtFacilityUnexpired(elem.facId)) do
          if offer.data.type == "vehicle" then
            table.insert(vehOffers, offer)
          end
          if offer.data.type == "trailer" then
            table.insert(trailerOffers, offer)
          end
        end
        if #vehOffers > 0 then
          table.insert(poiTemplate.props, {
            icon = "checkmark",
            keyLabel = core_locales.contextTranslate(#vehOffers ~= 1 and "ui.career.delivery.general.vehicleTransportsAvailable" or "ui.career.delivery.general.vehicleTransportAvailable", {count = #vehOffers})
          })
        end
        if #trailerOffers > 0 then
          table.insert(poiTemplate.props, {
            icon = "checkmark",
            keyLabel = core_locales.contextTranslate(#trailerOffers ~= 1 and "ui.career.delivery.general.trailerTransportsAvailable" or "ui.career.delivery.general.trailerTransportAvailable", {count = #trailerOffers})
          })
        end
      end

      -- make actual poi elemens

      for _, activeMaterialContract in ipairs(dMaterialContracts and dMaterialContracts.getActiveContracts() or {}) do
        local isActiveMaterialPickup = activeMaterialContract.status == "active"
          and activeMaterialContract.origin and activeMaterialContract.origin.facId == elem.facId
          and activeMaterialContract.origin.psPath == elem.psPath and (activeMaterialContract.loadableAmount or 0) > 0

        if isActiveMaterialPickup then
        local materialPoi = deepcopy(poiTemplate)
        materialPoi.preheadings = {"Active Material Contract"}
        materialPoi.heading = string.format("Load %s", _tr(activeMaterialContract.materialName))
        materialPoi.props = {
          {icon = "locationSource", keyLabel = "Destination", valueLabel = _tr(activeMaterialContract.destinationName)},
          {icon = "checkmark", keyLabel = "Delivered", valueLabel = string.format("%d %s", math.floor((activeMaterialContract.deliveredAmount or 0) + 0.5), activeMaterialContract.units or "L")},
          {icon = "deliveryTruck", keyLabel = "In Transit", valueLabel = string.format("%d %s", math.floor((activeMaterialContract.inTransitAmount or 0) + 0.5), activeMaterialContract.units or "L")},
          {icon = "route", keyLabel = "Remaining", valueLabel = string.format("%d %s", math.floor((activeMaterialContract.remainingAmount or 0) + 0.5), activeMaterialContract.units or "L")},
        }
        materialPoi.buttonLabel = "Open Material Loader"
        local contractId = activeMaterialContract.id
        materialPoi.buttonFun = function()
          dCargoScreen.enterMaterialContractPickupScreen(contractId, elem.facId, elem.psPath)
        end
        table.insert(activityData, materialPoi)
        end
      end

      if showDropOff then
        local dropOffPoi = deepcopy(poiTemplate)
        dropOffPoi.heading = _tr("ui.career.delivery.general.deliveryDropOff")
        dropOffPoi.buttonLabel = _tr("ui.career.delivery.general.dropOff")
        dropOffPoi.buttonFun = function()
          local emp = career_modules_delivery_employment
          if emp and emp.shouldOpenEmployeeDropOff and emp.shouldOpenEmployeeDropOff(elem.facId, elem.psPath) then
            if emp.tryAutoDropOffAssigned and emp.tryAutoDropOffAssigned(elem.facId, elem.psPath) then
              return
            end
            if emp.openDropOffUi then
              emp.openDropOffUi(elem.facId, elem.psPath)
              return
            end
          end
          if hasCompanyShift() then
            local materialsHere = (dropOffableCargoByCargoType.fluid or 0) > 0
              or (dropOffableCargoByCargoType.dryBulk or 0) > 0
              or (dropOffableCargoByCargoType.cement or 0) > 0
            if vehsClose <= 0 and trailersClose <= 0 and not materialsHere then
              ui_message("Drop off assigned cargo at the marked destination.", 5, "warning")
              return
            end
          end
          guihooks.trigger('ChangeState', {state = 'career.cargoDropOff', params = {facilityId = elem.facId, parkingSpotPath = elem.psPath}})
        end
        dropOffPoi.icon = "poi_dropoff_round"
        table.insert(activityData, dropOffPoi)
      end

      if anyCargoPickUpAble then
        local pickUpPoi = deepcopy(poiTemplate)
        pickUpPoi.heading = _tr("ui.career.delivery.general.deliveryPickUp")
        pickUpPoi.buttonLabel = _tr("ui.career.delivery.general.pickUp")
        pickUpPoi.buttonFun = function()
          dParcelManager.applyTransientMoves({type="facilityParkingspot", facId = elem.facId, psPath = elem.psPath})
          M.requestUpdateContainerWeights()
          gameplay_markerInteraction.closeViewDetailPrompt(true)
          Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Info_Open')
          gameplay_rawPois.clear()
          dCargoScreen.onCargoPickedUp()
        end
        pickUpPoi.icon = "poi_dropoff_round"
        table.insert(activityData, pickUpPoi)
      end
      -- Job Broker parcels reserved at this spot: the same "Pick Up" prompt, opening the broker's
      -- loader (My Loads, first reservation here selected) instead of applying staged moves.
      do
        local broker = career_modules_delivery_broker
        local reservedHere, reservedSlots = {}, 0
        for _, pickup in ipairs(broker and broker.getReservedPickups and broker.getReservedPickups() or {}) do
          if pickup.psPath == elem.psPath then
            reservedHere[#reservedHere + 1] = pickup
            reservedSlots = reservedSlots + (pickup.slots or 0)
          end
        end
        if #reservedHere > 0 then
          local brokerPoi = deepcopy(poiTemplate)
          brokerPoi.heading = _tr("ui.career.delivery.general.deliveryPickUp")
          brokerPoi.props = {{
            icon = "cardboardBox",
            keyLabel = #reservedHere == 1 and "1 reserved parcel" or string.format("%d reserved parcels", #reservedHere),
            valueLabel = string.format("%d %s", reservedSlots, reservedSlots == 1 and "slot" or "slots"),
          }}
          brokerPoi.buttonLabel = _tr("ui.career.delivery.general.pickUp")
          local firstJobId = reservedHere[1].jobId
          brokerPoi.buttonFun = function()
            gameplay_markerInteraction.closeViewDetailPrompt(true)
            broker.setOpenContext(elem.facId, false, 'jobs', firstJobId)
            guihooks.trigger('ChangeState', {state = 'phone-logistics'})
          end
          brokerPoi.icon = "poi_pickup_round"
          table.insert(activityData, brokerPoi)
        end
      end
      local emp = career_modules_delivery_employment
      if emp and emp.tryAutoLoadAssignedParcelsAtSpot then
        emp.tryAutoLoadAssignedParcelsAtSpot(elem.facId, elem.psPath)
      end
      if isInspectParkingSpot(elem.facId, elem.psPath) then
        local atStall = playerAtFacilityStall(elem.psPath)
        local inspectAtStall = atStall or playerAtFacilityStall(elem.psPath, true)
        local empDropOffAuto = career_modules_delivery_employment
          and career_modules_delivery_employment.willAutoOpenDropOffAt
          and career_modules_delivery_employment.willAutoOpenDropOffAt(elem.facId, elem.psPath)
        if atStall and not empDropOffAuto then
          addClockInActivity(activityData, poiTemplate, elem.facId)
        end
        if not isRoleplayFacility(elem.facId) then
          local pb = career_modules_business_passiveBusiness
          if pb and pb.hasPaidSupplyAt and pb.hasPaidSupplyAt(elem.facId, elem.psPath) then
            local supplyPoi = deepcopy(poiTemplate)
            supplyPoi.heading = "Pickup business supplies"
            supplyPoi.buttonLabel = "Pickup supplies"
            supplyPoi.icon = "poi_pickup_round"
            supplyPoi.props = {{icon = "checkmark", keyLabel = "Paid pallets waiting at this supplier"}}
            supplyPoi.buttonFun = function()
              dCargoScreen.enterPassiveBusinessSupplyPickupScreen(elem.facId, elem.psPath)
            end
            table.insert(activityData, supplyPoi)
          end
          local es = career_modules_business_engineShop
          if es and es.hasPaidSupplyAt and es.hasPaidSupplyAt(elem.facId, elem.psPath) then
            local enginePoi = deepcopy(poiTemplate)
            enginePoi.heading = "Pickup engine materials"
            enginePoi.buttonLabel = "Pickup materials"
            enginePoi.icon = "poi_pickup_round"
            enginePoi.props = {{icon = "checkmark", keyLabel = "Paid engine loads waiting at this supplier"}}
            enginePoi.buttonFun = function()
              dCargoScreen.enterEngineShopSupplyPickupScreen(elem.facId, elem.psPath)
            end
            table.insert(activityData, enginePoi)
          end
          if inspectAtStall and not suppressInspect and shouldShowFreelanceInspectAt(elem.facId) then
            local blocked = cargoBoardIsBlocked(elem.facId)
            local inspectPoi = deepcopy(poiTemplate)
            if blocked then
              inspectPoi.heading = "No work here"
              inspectPoi.buttonLabel = "No work here"
              inspectPoi.props = {{icon = "info", keyLabel = "No freelance cargo at this stop right now"}}
              inspectPoi.buttonFun = function()
                local emp = career_modules_delivery_employment
                local msg = emp and emp.getCargoBoardBlockMessage and emp.getCargoBoardBlockMessage(elem.facId)
                ui_message(msg or "No work here", 6, "info")
              end
            else
              inspectPoi.heading = _tr("ui.career.delivery.general.inspectCargo")
              inspectPoi.buttonLabel = _tr("ui.career.delivery.general.inspect")
              inspectPoi.buttonFun = function()
                dCargoScreen.enterCargoOverviewScreen(elem.facId, elem.psPath)
              end
            end
            table.insert(activityData, inspectPoi)
          end
        end
      end


    end
  end
end
M.onActivityAcceptGatherData = onActivityAcceptGatherData


local deliveryActivity = {
  id = "deliveryMode",
  name = _tr("ui.career.cargoOverview.deliveryMode"),

  vehicleModification = "warning",-- Slow and Fast Repairing, Changing and buying parts, tuning, painting
  vehicleSelling = "warning", --selling a vehicle
  vehicleStorage = "warning", --put vehicles into storage
  vehicleRepair = "warning",
  vehicleRetrieval = "allowed", --retrieve vehicles from storage

  vehicleShopping = "forbidden",

  interactRefuel = "allowed", --use the refueling POI to refuel vehicle
  interactMission = "warning", --use the mission POI to start a mission
  interactDelivery = "allowed", --use any delivery POI to start delivery mode

  recoveryFlipUpright = "allowed", --flip upright
  recoveryTowToRoad = "allowed", --tow to road
  recoveryTowToGarage = "warning", --tow to garage

  getLabel = function(tag)
    local penalty = -M.getDeliveryModePenalty().money
    local penaltyCtx = {penalty = string.format("%0.2f", penalty)}
    if     tag == "vehicleModification" then
      return core_locales.contextTranslate("ui.career.delivery.general.permissionVehicleModification", penaltyCtx)
    elseif tag == "vehicleSelling" then
      return core_locales.contextTranslate("ui.career.delivery.general.permissionVehicleSelling", penaltyCtx)
    elseif tag == "vehicleStorage" then
      return core_locales.contextTranslate("ui.career.delivery.general.permissionVehicleStorage", penaltyCtx)
    elseif tag == "vehicleRepair" then
      return core_locales.contextTranslate("ui.career.delivery.general.permissionVehicleRepair", penaltyCtx)
    elseif tag == "interactMission" then
      return core_locales.contextTranslate("ui.career.delivery.general.permissionInteractMission", penaltyCtx)
    elseif tag == "recoveryTowToGarage" then
      return core_locales.contextTranslate("ui.career.delivery.general.permissionRecoveryTowToGarage", penaltyCtx)
    elseif tag == "vehicleShopping" then
      return _tr("ui.career.delivery.general.permissionVehicleShopping")
    end
  end
}

local function onCheckPermission(tags, permissions, additionalData)
  if not deliveryModeActive then return end
  for _, tag in ipairs(tags) do
    if (tag == 'vehicleSelling' or tag == 'vehicleStorage' or tag == 'vehicleStoring'
        or tag == 'returnLoanedVehicle' or tag == 'junkVehicle')
        and additionalData and persistence.hasVehicleWork(additionalData.inventoryId) then
      table.insert(permissions, {permission = 'forbidden', label = 'Unload or transfer cargo, or explicitly abandon its delivery, first.'})
      return
    elseif tag == 'vehicleModification' or tag == 'vehicleRepair' or tag == 'vehicleRetrieval'
        or tag == 'vehicleShopping' or tag == 'recoveryTowToGarage' or tag == 'interactMission'
        or tag == 'recoveryFlipUpright' or tag == 'recoveryTowToRoad'
        or tag == 'vehicleSelling' or tag == 'vehicleStorage' then
      -- No restriction from delivery. Native permissions treats an explicit
      -- "allowed" entry differently from the unrestricted default.
    elseif deliveryActivity[tag] then
      table.insert(permissions, {permission = deliveryActivity[tag], label = deliveryActivity.getLabel(tag)})
      return
    end
  end
end

local function startDeliveryMode()
  if deliveryModeActive then return end
  bindDeliveryDeps()
  log("I","","Delivery Mode Started.")
  deliveryModeActive = true
  gameplay_rawPois.clear()
  requestDeliveryPoiRefresh(true)
  if dTasklist and dTasklist.sendCargoToTasklist then
    dTasklist.sendCargoToTasklist()
  elseif career_modules_delivery_tasklist and career_modules_delivery_tasklist.sendCargoToTasklist then
    career_modules_delivery_tasklist.sendCargoToTasklist()
  end
  extensions.hook("onDeliveryModeStarted")
end

local function exitDeliveryMode(explicitAbandon, fromEmployment)
  if not deliveryModeActive then return end
  if not explicitAbandon and (next(dParcelManager.getAllCargoInVehicles(true)) or next(dVehicleTasks.getVehicleTasks())
      or (dMaterialContracts and dMaterialContracts.getActiveContracts and next(dMaterialContracts.getActiveContracts()))) then
    return false
  end
  -- Close the transaction gate before cleanup hooks can re-enter this method.
  deliveryModeActive = false
  log("I","","Delivery Mode Exited.")
  -- clearTransientFlags is a deprecated stub that only emits an error. Clear
  -- the real pending-move list when leaving delivery mode instead.
  if dParcelManager.clearAllTransientMoves then
    dParcelManager.clearAllTransientMoves()
  end
  -- get all cargo currently in vehicles.
  local penalty = M.getDeliveryModePenalty()
  local cargoInVehicles = dParcelManager.getAllCargoInVehicles(true)
  for _, cargo in ipairs(cargoInVehicles) do
    if cargo.location and cargo.location.vehId then
      M.rememberCargoWeightVehicle(cargo.location.vehId)
    end
  end
  if next(cargoInVehicles) then
    for _, cargo in ipairs(cargoInVehicles) do
      local passiveBusiness = career_modules_business_passiveBusiness
      local engineShop = career_modules_business_engineShop
      if not (engineShop and engineShop.returnCargoToSupplier and engineShop.returnCargoToSupplier(cargo, false))
        and not (passiveBusiness and passiveBusiness.returnCargoToSupplier and passiveBusiness.returnCargoToSupplier(cargo, false)) then
        dParcelManager.changeCargoLocation(cargo.id, {type="delete"})
      end
    end
  end
  if penalty.money < 0 then
    fireCargoAbandonedNotification(penalty.money)
    log("I","",string.format("Penalty for abandoning cargo: %0.2f$", -penalty.money))
    career_modules_playerAttributes.addAttributes(penalty, {tags={"gameplay", "delivery","fine"}, label="ui.career.delivery.general.penaltyAbandonLabel"})
    Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')
  end

  dVehicleTasks.abandonAllVehicleTasks()

  if explicitAbandon and dMaterialContracts and dMaterialContracts.abandonContract then
    -- The combined penalty already includes each contract once.
    dMaterialContracts.abandonContract(nil, {noFine = true, silent = true})
  end

  dParcelManager.clearAllTransientMoves()

  deliveryModeActive = false
  local employment = career_modules_delivery_employment
  if explicitAbandon and not fromEmployment and employment and employment.onLogisticsAbandoned then
    employment.onLogisticsAbandoned()
  end
  gameplay_rawPois.clear()
  freeroam_bigMapMode.setNavFocus(nil)

  M.requestUpdateContainerWeights()
  dTasklist.clearAll()
  if dMaterialContracts and dMaterialContracts.refreshTaskGuidance then
    dMaterialContracts.refreshTaskGuidance(true)
  end
  --core_gamestate.setGameState("career", "career")
  extensions.hook("onDeliveryModeStopped")
end

local function checkExitDeliveryMode()
  local emp = career_modules_delivery_employment
  if emp and emp.keepDeliveryModeActive and emp.keepDeliveryModeActive() then
    return
  end
  local transfer = gameplay_vehicleTransfer
  if transfer and transfer.isOnShift and transfer.isOnShift() then
    return
  end
  local cargoInVehicles = dParcelManager.getAllCargoInVehicles(true)
  local vehicleTasks = dVehicleTasks.getVehicleTasks()
  if not next(cargoInVehicles) and not next(vehicleTasks) then
    M.exitDeliveryMode()
  end
end

local function isAutomaticRouteEnabled()
  return loadData.settings.automaticRoute
end
M.isAutomaticRouteEnabled = isAutomaticRouteEnabled

local settingDeliveryNavFocus = false
M.setDeliveryNavFocus = function(pos)
  settingDeliveryNavFocus = true
  freeroam_bigMapMode.setNavFocus(pos)
  settingDeliveryNavFocus = false
end

local function setAutomaticRoute(enabled)
  loadData.settings.automaticRoute = enabled
  if enabled then
    career_modules_delivery_cargoScreen.setBestRoute()
  else
    core_groundMarkers.setPath(nil)
    freeroam_bigMapMode.resetRoute()
  end
  guihooks.trigger("automaticRouteSet", enabled)
end

local function setDetailedDropOff(enabled)
  loadData.settings.detailedDropOff = enabled
  guihooks.trigger("detailedDropOffSet", enabled)
end

-- Deactivate automatic route when setting a manual waypoint
local function onSetBigmapNavFocus()
  if M.isDeliveryModeActive() and not settingDeliveryNavFocus then
    setAutomaticRoute(false)
  end
end

local function setSetting(key, value)
  loadData.settings[key] = value
end

local function getSettings()
  return loadData.settings
end

M.setAutomaticRoute = setAutomaticRoute
M.setDetailedDropOff = setDetailedDropOff
M.onSetBigmapNavFocus = onSetBigmapNavFocus

M.setSetting = setSetting
M.getSettings = getSettings

M.startDeliveryMode = startDeliveryMode
M.exitDeliveryMode = exitDeliveryMode
M.checkExitDeliveryMode = checkExitDeliveryMode
M.isDeliveryModeActive = function() return deliveryModeActive end

M.getDeliveryModePenalty = function(onlyVehIdsAsKeys, forSave, cargoFilter)
  local cargoInVehicles = dParcelManager.getAllCargoInVehicles(true)
  local penalty = {money = 0}
  if not onlyVehIdsAsKeys and not cargoFilter then
    local fine = dVehicleTasks.getFineForAbandonAllVehicleTasks(forSave)
    for attKey, amount in pairs(fine) do
      penalty[attKey] = (penalty[attKey] or 0) + amount
    end
  end

  if next(cargoInVehicles) then
    for _, cargo in ipairs(cargoInVehicles) do
      if ((not onlyVehIdsAsKeys) or (cargo.location.vehId and onlyVehIdsAsKeys[cargo.location.vehId]))
        and not (forSave and require('gameplay/delivery/brokerPersistence').canPersistCargo(cargo))
        and (not cargoFilter or cargoFilter(cargo)) then
        local abandonFac = M.getDeliveryAbandonPenaltyFactor()
        local modFac = 0
        if cargo.modifiers then
          for _, mod in ipairs(cargo.modifiers) do
            modFac = modFac + (mod.abandonMultiplier or 0)
          end
        end
        if not cargo._transientMove and not (cargo.data and cargo.data.materialContractId) then
          local rewardMoney = cargo.rewards and tonumber(cargo.rewards.money) or 0
          penalty.money = penalty.money - rewardMoney * (abandonFac + modFac)
        end
        if cargo.organization and cargo.rewards then
          local repKey = cargo.organization .. "reputation"
          local repHit = math.ceil(tonumber(cargo.rewards[repKey]) or 0)
          if repHit ~= 0 then
            penalty[repKey] = (penalty[repKey] or 0) - repHit
          end
        end
      end
    end
  end
  if not onlyVehIdsAsKeys and not cargoFilter and dMaterialContracts and dMaterialContracts.getActiveContracts then
    for _, contract in ipairs(dMaterialContracts.getActiveContracts()) do
      penalty.money = penalty.money - (tonumber(contract.abandonmentFine) or 0)
    end
  end
  return penalty
end

M.onCheckPermission = onCheckPermission

M.getAbandonmentSummary = function()
  local jobs, seen = {}, {}
  for _, cargo in ipairs(dParcelManager.getAllCargoInVehicles(true)) do
    local name = cargo.name or 'Cargo delivery'
    if not seen[name] then jobs[#jobs + 1] = {name = name}; seen[name] = true end
  end
  for _, task in ipairs(dVehicleTasks.getVehicleTasks()) do
    if not task.remove and not task.finished then
      jobs[#jobs + 1] = {name = task.offer.name or task.offer.vehicle.name or 'Vehicle delivery'}
    end
  end
  if dMaterialContracts and dMaterialContracts.getActiveContracts then
    for _, contract in ipairs(dMaterialContracts.getActiveContracts()) do
      jobs[#jobs + 1] = {name = (contract.materialName or 'Material') .. ' contract: ' .. (contract.destinationName or contract.destinationFacId or '')}
    end
  end
  return {jobs = jobs, penalty = math.max(0, -(M.getDeliveryModePenalty().money or 0))}
end

-- Service UI entry captures stable container identities before preview respawns.

M.onPartShoppingStarted = function()
  persistence.capture()
end

M.onCareerPaintingStarted = function()
  persistence.capture()
end

M.onCareerTuningStarted = function()
  persistence.capture()
end

M.onTeleportedToGarage = function(garageId, veh)
  persistence.reconcile()
end

-- Missions may temporarily replace the scene; accepted work remains bound to inventory.
M.onAnyMissionChanged = function() persistence.capture() end

M.onRepairInGarage = function(invVehId)
  persistence.capture()
end

M.onInventoryPreRemoveVehicleObject = function(inventoryId, vehId)
  persistence.suspendVehicle(inventoryId, vehId)
end

M.capturePersistentCargo = persistence.capture
M.capturePersistentTask = persistence.captureTask
M.canRemoveLogisticsVehicle = persistence.allowRemoval
M.validateLogisticsContainers = persistence.validateVehicle
M.getPendingLogisticsVehicles = persistence.getPending
M.retryLogisticsVehicle = persistence.retry



return M
