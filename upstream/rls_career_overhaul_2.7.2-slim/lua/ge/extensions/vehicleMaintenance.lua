local M = {}
local lastQueuedRuntimeInitKeyByInventoryId = {}
local inspectionPreviewsByVehId = {}
-- Session-local latches survive vehicle saves/re-entry without writing warning
-- state into the career save. Each inventory vehicle rearms after replenishment.
local oilWarningsByInventoryId = {}
local maintenanceComputerConfig = require("ge/extensions/career/modules/maintenanceComputerConfig")
local lastMaintenanceLockNotice = {
  inventoryId = nil,
  shownAt = 0,
}

local function isMaintenanceEnabledForCurrentSave()
  if career_career and career_career.isActive and career_career.isActive() and career_modules_maintenanceMode and
      career_modules_maintenanceMode.isEnabled then
    return career_modules_maintenanceMode.isEnabled() == true
  end

  return true
end

local function deepCopyValue(value)
  if type(deepcopy) == "function" then
    return deepcopy(value)
  end
  if type(value) ~= "table" then
    return value
  end

  local result = {}
  for key, nestedValue in pairs(value) do
    result[key] = deepCopyValue(nestedValue)
  end
  return result
end

local function getSerializedSignature(value)
  if type(serialize) ~= "function" then
    return nil
  end
  return serialize(value)
end

local function getInventoryModule()
  return career_modules_inventory
end

local function getVehicleData(inventoryId)
  local inventory = getInventoryModule()
  if not inventory or not inventory.getVehicle or not inventoryId then
    return nil
  end
  return inventory.getVehicle(inventoryId)
end

local function getVehicleObjectForInventoryId(inventoryId)
  local inventory = getInventoryModule()
  if not inventory or not inventory.getVehicleIdFromInventoryId or not inventoryId then
    return nil
  end

  local vehId = inventory.getVehicleIdFromInventoryId(inventoryId)
  if not vehId then
    return nil
  end

  return getObjectByID(vehId)
end

local function maybeNotifyLowOil(inventoryId, snapshot)
  if not (career_career and career_career.isActive and career_career.isActive()) or
      not isMaintenanceEnabledForCurrentSave() then return end
  local engine = type(snapshot) == "table" and snapshot.categories and snapshot.categories.engine
  local level = engine and engine.maintenance and tonumber(engine.maintenance.oilLevel)
  if not level or level ~= level or level < 0 or level > 1 then return end
  if type(engine.cachedPartIds) == "table" and #engine.cachedPartIds == 0 then return end

  local warning = oilWarningsByInventoryId[inventoryId] or {hud = 0, phone = 0}
  oilWarningsByInventoryId[inventoryId] = warning
  -- Hysteresis avoids repeated alerts from tiny changes around a threshold.
  if level > 0.40 then
    warning.hud, warning.phone = 0, 0
  elseif level > 0.20 then
    warning.hud = math.min(warning.hud, 1)
    warning.phone = math.min(warning.phone, 1)
  end
  local severity = level <= 0.15 and 2 or (level <= 0.30 and 1 or 0)
  if severity == 0 then return end

  -- Only warn the player about the vehicle they are actually occupying.
  -- Parked inventory vehicles and inspection previews must not send alerts.
  local inventory = getInventoryModule()
  local playerVehicle = be and be:getPlayerVehicle(0)
  if not inventory or not inventory.getCurrentVehicle or
      tonumber(inventory.getCurrentVehicle()) ~= inventoryId or not playerVehicle or
      not inventory.getVehicleIdFromInventoryId or
      inventory.getVehicleIdFromInventoryId(inventoryId) ~= playerVehicle:getID() or
      (gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking()) then return end

  local critical = severity == 2
  local title = critical and "Engine oil critically low" or "Low engine oil"
  local message = critical and "Stop safely and switch off the engine. Top up the oil before driving." or
                    "Top up the engine oil soon to avoid power loss and engine damage."
  if severity > warning.hud and type(ui_message) == "function" then
    ui_message(title .. ". " .. message, 8, "maintenanceOil", "warning")
    warning.hud = severity
  end
  if severity > warning.phone then
    if not ui_phone_layout and extensions and extensions.load then extensions.load("ui_phone_layout") end
    local layout = ui_phone_layout or (extensions and extensions.ui_phone_layout)
    if layout and layout.isAppInstalled and layout.isAppInstalled("obd-scanner") and layout.fireNotification then
      -- Respect mute/DND without retrying every state sync. Escalation remains
      -- a separate event; app installation can still receive the current alert.
      -- The dispatcher invokes fallback only when the phone surface is absent;
      -- that delivery failure should retry once the UI becomes available.
      local deliveryUnavailable = false
      layout.fireNotification("obdScanner.lowOil", {
        title = title, message = message, source = "OBD Scanner",
        kind = critical and "error" or "warning", ttl = 8,
        appId = "obd-scanner", route = "/career/phone-obd-scanner",
        replaceKey = "obd-low-oil-" .. tostring(inventoryId),
      }, {appId = "obd-scanner", fallback = function() deliveryUnavailable = true end})
      if not deliveryUnavailable then warning.phone = severity end
    end
  end
end

local function hasActiveMaintenanceComputerJobs(vehicleData)
  -- Maintenance actions are synchronous. Legacy jobs are migrated and
  -- completed by maintenanceComputer, so they must never freeze a vehicle.
  return false
end

local function setVehicleFreezeSafe(vehObj, shouldFreeze)
  if not vehObj then
    return false
  end

  local freezeValue = shouldFreeze and true or false
  if core_vehicleBridge and core_vehicleBridge.executeAction then
    local ok = pcall(function()
      core_vehicleBridge.executeAction(vehObj, 'setFreeze', freezeValue)
    end)
    if ok then
      return true
    end
  end

  vehObj:queueLuaCommand(string.format('controller.setFreeze(%d)', shouldFreeze and 1 or 0))
  return true
end

local function applyMaintenanceDriveLockToVehicle(vehObj, shouldLock)
  if not vehObj then
    return false
  end

  setVehicleFreezeSafe(vehObj, shouldLock)
  if shouldLock then
    vehObj:queueLuaCommand([[
      input.event("throttle", 0, 1)
      input.event("brake", 0, 1)
      input.event("clutch", 0, 1)
    ]])
  end

  return true
end

local function syncMaintenanceDriveLock(inventoryId)
  local inventory = getInventoryModule()
  inventoryId = tonumber(inventoryId)
  if not inventory or not inventoryId then
    return false
  end

  local vehicleData = inventory.getVehicle and inventory.getVehicle(inventoryId) or nil
  local vehObj = getVehicleObjectForInventoryId(inventoryId)
  if not vehicleData or not vehObj then
    return false
  end

  return applyMaintenanceDriveLockToVehicle(vehObj, hasActiveMaintenanceComputerJobs(vehicleData))
end

local function maybeNotifyMaintenanceDriveLock(inventoryId)
  inventoryId = tonumber(inventoryId)
  if not inventoryId then
    return false
  end

  local vehicleData = getVehicleData(inventoryId)
  if not hasActiveMaintenanceComputerJobs(vehicleData) then
    if lastMaintenanceLockNotice.inventoryId == inventoryId then
      lastMaintenanceLockNotice.inventoryId = nil
      lastMaintenanceLockNotice.shownAt = 0
    end
    return false
  end

  local now = os.time()
  if lastMaintenanceLockNotice.inventoryId == inventoryId and (now - (lastMaintenanceLockNotice.shownAt or 0)) < 3 then
    return false
  end

  lastMaintenanceLockNotice.inventoryId = inventoryId
  lastMaintenanceLockNotice.shownAt = now
  ui_message("Vehicle waiting for maintenance to be complete.", 4, "maintenance", "info")
  return true
end

local function clearVehicleMaintenanceState(inventoryId, markDirty)
  local inventory = getInventoryModule()
  inventoryId = tonumber(inventoryId)
  if not inventory or not inventoryId then
    return false
  end

  local vehicleData = inventory.getVehicle and inventory.getVehicle(inventoryId) or nil
  if not vehicleData then
    return false
  end

  local hadMaintenanceState = vehicleData.maintenanceState ~= nil
  vehicleData.maintenanceState = nil
  oilWarningsByInventoryId[inventoryId] = nil
  lastQueuedRuntimeInitKeyByInventoryId[inventoryId] = nil
  if hadMaintenanceState and markDirty ~= false and inventory.setVehicleDirty then
    inventory.setVehicleDirty(inventoryId)
  end

  return hadMaintenanceState
end

local function cleanupRuntimeState(inventoryId, vehObj)
  inventoryId = tonumber(inventoryId)
  if not inventoryId then
    return false
  end

  vehObj = vehObj or getVehicleObjectForInventoryId(inventoryId)
  if not vehObj then
    return false
  end

  vehObj:queueLuaCommand(string.format("extensions.load('maintenanceManager'); maintenanceManager.clearForDisabledSave(%d)",
    inventoryId))
  return true
end

local function clearAllInventoryMaintenanceState(markDirty)
  local inventory = getInventoryModule()
  if not inventory or not inventory.getVehicles then
    return
  end

  for inventoryId in pairs(inventory.getVehicles() or {}) do
    clearVehicleMaintenanceState(inventoryId, markDirty)
  end
end

local function queueRuntimeInit(inventoryId, vehObj)
  inventoryId = tonumber(inventoryId)
  if not inventoryId then
    return false
  end

  if not isMaintenanceEnabledForCurrentSave() then
    clearVehicleMaintenanceState(inventoryId)
    return cleanupRuntimeState(inventoryId, vehObj)
  end

  vehObj = vehObj or getVehicleObjectForInventoryId(inventoryId)
  if not vehObj or type(serialize) ~= "function" then
    return false
  end

  local vehicleData = getVehicleData(inventoryId)
  local snapshot = vehicleData and vehicleData.maintenanceState or nil
  local serializedSnapshot = snapshot and serialize(snapshot) or "nil"
  local vehId = vehObj:getID()
  local initKey = string.format("%s:%s:%s", tostring(inventoryId), tostring(vehId), serializedSnapshot)
  if lastQueuedRuntimeInitKeyByInventoryId[inventoryId] == initKey then
    return true
  end

  lastQueuedRuntimeInitKeyByInventoryId[inventoryId] = initKey
  vehObj:queueLuaCommand(string.format("extensions.load('maintenanceManager'); maintenanceManager.initFromSave(%s, %d)",
    serializedSnapshot, inventoryId))
  syncMaintenanceDriveLock(inventoryId)
  return true
end

local function getOrCreateInspectionSnapshot(vehicleInfo)
  if type(vehicleInfo) ~= "table" then return nil end
  if type(vehicleInfo.maintenancePreviewState) ~= "table" then
    local mileageMeters = tonumber(vehicleInfo.wearMileage or vehicleInfo.Mileage) or 0
    vehicleInfo.maintenancePreviewState = maintenanceComputerConfig.buildInitialSnapshotForMileage(
      mileageMeters, "meters", vehicleInfo)
  end
  vehicleInfo.maintenancePreviewState = maintenanceComputerConfig.normalizeSnapshot(
    vehicleInfo.maintenancePreviewState, vehicleInfo)
  return vehicleInfo.maintenancePreviewState
end

local function applyInspectionSnapshotToVehicleData(vehicleInfo, vehicleData)
  if type(vehicleData) ~= "table" or type(vehicleInfo) ~= "table" or
      type(vehicleInfo.maintenancePreviewState) ~= "table" then return false end
  vehicleData.maintenanceState = deepCopyValue(
    maintenanceComputerConfig.normalizeSnapshot(vehicleInfo.maintenancePreviewState, vehicleInfo))
  return true
end

local function registerInspectionVehicle(vehId, vehicleInfo)
  vehId = tonumber(vehId)
  local vehObj = vehId and getObjectByID(vehId) or nil
  if not vehObj or type(serialize) ~= "function" then return false end

  local snapshot = getOrCreateInspectionSnapshot(vehicleInfo)
  if not snapshot then return false end
  inspectionPreviewsByVehId[vehId] = {vehicleInfo = vehicleInfo, snapshot = deepCopyValue(snapshot)}
  if not isMaintenanceEnabledForCurrentSave() then
    vehObj:queueLuaCommand("extensions.load('maintenanceManager'); maintenanceManager.clearForDisabledSave(nil)")
    return true
  end

  vehObj:queueLuaCommand("extensions.load('maintenanceManager'); maintenanceManager.initFromSave(" ..
    serialize(snapshot) .. ", nil, true)")
  return true
end

local function unregisterInspectionVehicle(vehId)
  vehId = tonumber(vehId)
  if not vehId or not inspectionPreviewsByVehId[vehId] then return false end
  inspectionPreviewsByVehId[vehId] = nil

  local inventory = getInventoryModule()
  local inventoryId = inventory and inventory.getInventoryIdFromVehicleId and
                        inventory.getInventoryIdFromVehicleId(vehId) or nil
  local vehObj = getObjectByID(vehId)
  if inventoryId then return queueRuntimeInit(inventoryId, vehObj) end
  if vehObj then
    vehObj:queueLuaCommand("if maintenanceManager then maintenanceManager.clearForDisabledSave(nil) end")
  end
  return true
end

local function queueRuntimeCommand(inventoryId, command)
  if not isMaintenanceEnabledForCurrentSave() then
    clearVehicleMaintenanceState(inventoryId)
    return cleanupRuntimeState(inventoryId)
  end

  local vehObj = getVehicleObjectForInventoryId(inventoryId)
  if not vehObj then
    return false
  end

  vehObj:queueLuaCommand("extensions.load('maintenanceManager'); " .. command)
  return true
end

local function syncVehicleMaintenance(inventoryId)
  local inventory = getInventoryModule()
  if not inventory then
    return false
  end

  inventoryId = tonumber(inventoryId) or (inventory.getCurrentVehicle and inventory.getCurrentVehicle()) or nil
  if not inventoryId then
    return false
  end

  return queueRuntimeInit(inventoryId)
end

local function onVehicleMaintenanceStateChanged(inventoryId, snapshot)
  local inventory = getInventoryModule()
  inventoryId = tonumber(inventoryId)
  if not inventory or not inventoryId then
    return
  end

  local vehicleData = inventory.getVehicle and inventory.getVehicle(inventoryId) or nil
  if not vehicleData then
    return
  end

  if not isMaintenanceEnabledForCurrentSave() or type(snapshot) ~= "table" then
    clearVehicleMaintenanceState(inventoryId)
    return
  end

  vehicleData.maintenanceState = snapshot
  maybeNotifyLowOil(inventoryId, snapshot)
  lastQueuedRuntimeInitKeyByInventoryId[inventoryId] = nil
  if inventory.setVehicleDirty then
    inventory.setVehicleDirty(inventoryId)
  end
end

local function onVehiclePartConditionsChanged(inventoryId)
  inventoryId = tonumber(inventoryId)
  if not inventoryId then
    return
  end

  return queueRuntimeCommand(inventoryId, "maintenanceManager.refreshFromCurrentPartConditions()")
end

local function applyMaintenancePartConditions(inventoryId, partConditions, vehId)
  local inventory = getInventoryModule()
  inventoryId = tonumber(inventoryId)
  vehId = tonumber(vehId)
  if not inventory or not inventoryId or type(partConditions) ~= "table" then
    return false
  end

  local vehicleData = getVehicleData(inventoryId)
  if not vehicleData then
    return false
  end

  local nextSignature = getSerializedSignature(partConditions)
  local currentSignature = getSerializedSignature(vehicleData.partConditions)
  if nextSignature and nextSignature == currentSignature then
    return true
  end

  vehicleData.partConditions = deepCopyValue(partConditions)
  if inventory.setVehicleDirty then
    inventory.setVehicleDirty(inventoryId)
  end
  if career_modules_partInventory and career_modules_partInventory.updatePartConditionsInInventory then
    career_modules_partInventory.updatePartConditionsInInventory(inventoryId)
  end

  return true
end

local function onVehicleSpawned(_, veh)
  local inventory = getInventoryModule()
  if not inventory or not veh or not inventory.getInventoryIdFromVehicleId then
    return
  end

  local inventoryId = inventory.getInventoryIdFromVehicleId(veh:getID())
  if inventoryId then
    queueRuntimeInit(inventoryId, veh)
  end
end

local function onEnterVehicleFinished(inventoryId)
  syncVehicleMaintenance(inventoryId)
  maybeNotifyMaintenanceDriveLock(inventoryId)
  inventoryId = tonumber(inventoryId)
  local vehicleData = getVehicleData(inventoryId)
  if vehicleData then maybeNotifyLowOil(inventoryId, vehicleData.maintenanceState) end
end

local function onPhoneAppInstallStateChanged()
  local inventory = getInventoryModule()
  local inventoryId = inventory and inventory.getCurrentVehicle and tonumber(inventory.getCurrentVehicle())
  local vehicleData = getVehicleData(inventoryId)
  if vehicleData then maybeNotifyLowOil(inventoryId, vehicleData.maintenanceState) end
end

local function onVehicleSaveFinished()
  local inventory = getInventoryModule()
  local inventoryId = inventory and inventory.getCurrentVehicle and inventory.getCurrentVehicle() or nil
  if not inventoryId then
    return
  end

  -- Part-condition capture can recreate vehicle extensions without replacing
  -- the vehicle object. Force the saved snapshot back into the fresh runtime;
  -- the normal init key would otherwise mistake it for the previous instance.
  lastQueuedRuntimeInitKeyByInventoryId[inventoryId] = nil
  syncVehicleMaintenance(inventoryId)
end

local function applyMaintenanceFailure(inventoryId, category, failureType)
  inventoryId = tonumber(inventoryId)
  if not inventoryId or not category then
    return false
  end

  local mode = failureType == "symptom" and "symptom" or "hard"
  return queueRuntimeCommand(inventoryId, string.format("maintenanceManager.debugForceFailure(%q, %q)", tostring(category), mode))
end

local function onExperimentalMaintenanceModeChanged(enabled)
  if enabled == true then
    syncVehicleMaintenance()
    for vehId, preview in pairs(inspectionPreviewsByVehId) do
      registerInspectionVehicle(vehId, preview.vehicleInfo)
    end
    return
  end

  clearAllInventoryMaintenanceState(true)

  local inventory = getInventoryModule()
  if not inventory or not inventory.getVehicles then
    return
  end

  for inventoryId in pairs(inventory.getVehicles() or {}) do
    cleanupRuntimeState(inventoryId)
    applyMaintenanceDriveLockToVehicle(getVehicleObjectForInventoryId(inventoryId), false)
  end
  for vehId in pairs(inspectionPreviewsByVehId) do
    local vehObj = getObjectByID(vehId)
    if vehObj then
      vehObj:queueLuaCommand("extensions.load('maintenanceManager'); maintenanceManager.clearForDisabledSave(nil)")
    end
  end
end

local function onCareerActive(active)
  if not active then
    oilWarningsByInventoryId = {}
    return
  end

  if isMaintenanceEnabledForCurrentSave() then
    syncVehicleMaintenance()
  else
    onExperimentalMaintenanceModeChanged(false)
  end
end

local function onExtensionLoaded()
  local inventory = getInventoryModule()
  if not inventory or not inventory.getCurrentVehicle then
    return
  end

  local currentInventoryId = inventory.getCurrentVehicle()
  if currentInventoryId then
    syncVehicleMaintenance(currentInventoryId)
  end
end

M.onExtensionLoaded = onExtensionLoaded
M.onVehicleSpawned = onVehicleSpawned
M.onEnterVehicleFinished = onEnterVehicleFinished
M.onVehiclePartConditionsChanged = onVehiclePartConditionsChanged
M.onVehicleSaveFinished = onVehicleSaveFinished
M.onCareerActive = onCareerActive
M.onExperimentalMaintenanceModeChanged = onExperimentalMaintenanceModeChanged
M.onPhoneAppInstallStateChanged = onPhoneAppInstallStateChanged

local function resetAllCategories(inventoryId)
  inventoryId = tonumber(inventoryId)
  if not inventoryId then
    return false
  end
  local ok = false
  for _, categoryName in ipairs({"engine", "radiator", "transmission"}) do
    if queueRuntimeCommand(inventoryId, string.format("maintenanceManager.debugResetCategory(%q)", categoryName)) then
      ok = true
    end
  end
  return ok
end

M.onVehicleMaintenanceStateChanged = onVehicleMaintenanceStateChanged
M.syncVehicleMaintenance = syncVehicleMaintenance
M.syncMaintenanceDriveLock = syncMaintenanceDriveLock
M.applyMaintenanceFailure = applyMaintenanceFailure
M.applyMaintenancePartConditions = applyMaintenancePartConditions
M.getOrCreateInspectionSnapshot = getOrCreateInspectionSnapshot
M.applyInspectionSnapshotToVehicleData = applyInspectionSnapshotToVehicleData
M.registerInspectionVehicle = registerInspectionVehicle
M.unregisterInspectionVehicle = unregisterInspectionVehicle
M.resetAllCategories = resetAllCategories

return M
