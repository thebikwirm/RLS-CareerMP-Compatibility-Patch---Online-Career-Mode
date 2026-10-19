local M = {}

M.dependencies = {
  "overhaul_rlsHubDyno",
  "career_career",
  "career_modules_finiteDamage",
  "career_modules_inventory",
  "career_modules_maintenanceComputer",
  "career_modules_payment",
  "career_modules_tireSystem",
  "career_modules_tuning",
  "career_saveSystem",
  "core_vehicle_partmgmt",
  "gameplay_sites_sitesManager"
}

local bundles = require("gameplay/businessBundles")
local jbeamIO = require("jbeam/io")

local SESSION_FEE = 1000
local SESSION_PULL_LIMIT = 3
local TRIGGER_NAME = "dynoSessionTrigger"
local UI_STATE = "dynoSession"
local SITE_FILE_NAME = "dynoSession"
local PARKING_SPOT_NAME = "dynoSessionParking"
local DEFAULT_DYNO_HUB_ID = "rls"
local HISTORY_SAVE_FILE = "/career/rls_career/dynoPullHistory.json"
local HISTORY_VERSION = 1
local HISTORY_LIMIT_PER_VEHICLE = 25

local DYNO_HUB_ORDER = {
  "rls",
  "drowsysam"
}

local DYNO_HUB_OPTIONS = {
  drowsysam = {
    id = "drowsysam",
    label = "DrowsySam Hub Dyno",
    description = "Original D300S hub dyno hardware.",
    requiredFile = "/vehicles/common/dshub_dyno/dshub_dyno_F_5.jbeam",
    frontPartPrefix = "dshub_dyno_F_",
    rearPartPrefix = "dshub_dyno_R_"
  },
  rls = {
    id = "rls",
    label = "RLS Hub Dyno",
    description = "RLS hub dyno hardware.",
    partsBySlot = {
      wheel_F_4 = "wheel_dyno_rls_F5",
      wheel_F_5 = "wheel_dyno_rls_F5",
      wheel_F_6 = "wheel_dyno_rls_F5",
      wheel_F_8 = "wheel_dyno_rls_F5",
      wheel_F_centerlug = "wheel_dyno_rls_F5",
      wheel_R_4 = "wheel_dyno_rls_R5",
      wheel_R_5 = "wheel_dyno_rls_R5",
      wheel_R_6 = "wheel_dyno_rls_R5",
      wheel_R_8 = "wheel_dyno_rls_R5",
      wheel_R_centerlug = "wheel_dyno_rls_R5"
    }
  }
}

local SUPPORTED_FRONT_SUFFIXES = {
  ["4"] = true,
  ["5"] = true,
  ["6"] = true,
  ["8"] = true,
  ["C"] = true
}

local SUPPORTED_REAR_SUFFIXES = {
  ["3"] = true,
  ["4"] = true,
  ["5"] = true,
  ["6"] = true,
  ["8"] = true,
  ["10"] = true,
  ["C"] = true
}

local getDynoHubPartName

local dynoSession = {
  active = false,
  inventoryId = nil,
  sourceVehicleId = nil,
  originalTransform = nil,
  originalConfig = nil,
  originalPartConditions = nil,
  originalLiveConfig = nil,
  sessionVehicleId = nil,
  parkingSpotName = PARKING_SPOT_NAME,
  selectedHubId = DEFAULT_DYNO_HUB_ID,
  hubConfigApplied = false,
  pullState = nil,
  result = nil,
  pullsUsed = 0,
  policy = nil,
  feePaid = 0,
  setupFeeRefundable = false,
  serviceOpen = nil,
  resumePhase = nil,
  retryArmDelay = nil,
  phase = "offer",
  error = nil,
  statusText = nil
}

local playerInsideTrigger = false
-- true while a paid private repair respawns the car in place (see repairAndStart): the old object leaving and
-- the new one appearing on the trigger are not the player driving out / in
local repairRespawnPending = false
local pendingConfigSnapshots = {}
local protectedSteeringVehicles = {}
local pendingSteeringSetup
local steeringSetupTimer = 0
local steeringSetupToken = 0
local pullHistoryByVehicle = {}
local nextPullHistoryId = 1
local pullHistoryLoaded = false
local normalizeQualityFlags
local requestSessionData
local conditionRefreshPending = false
local conditionRefreshToken = 0
local conditionRefreshCallbacks = {}
local ownershipWaitCallbacks = {}

local function safeDeepcopy(value)
  if value == nil then
    return nil
  end
  return deepcopy(value)
end

local function getCurrentSavePath()
  if not career_saveSystem then
    return nil
  end

  if career_saveSystem.getCurrentSaveSlot then
    local _, path = career_saveSystem.getCurrentSaveSlot()
    if path then
      return path
    end
  end

  if career_saveSystem.getCurrentProfile then
    local _, path = career_saveSystem.getCurrentProfile()
    return path
  end

  return nil
end

local function normalizeSavedPull(entry)
  if type(entry) ~= "table" then
    return nil
  end

  local id = tonumber(entry.id)
  if not id then
    return nil
  end

  return {
    id = id,
    savedAt = tonumber(entry.savedAt) or 0,
    inventoryId = tostring(entry.inventoryId or ""),
    vehicleName = entry.vehicleName,
    hubId = entry.hubId,
    peakPower = tonumber(entry.peakPower) or 0,
    peakTorque = tonumber(entry.peakTorque) or 0,
    peakPowerRpm = tonumber(entry.peakPowerRpm) or 0,
    peakTorqueRpm = tonumber(entry.peakTorqueRpm) or 0,
    valid = true,
    measurementComplete = entry.measurementComplete ~= false and entry.valid ~= false,
    pullQuality = (entry.valid == false or entry.measurementComplete == false or entry.pullQuality == "invalid")
      and "warning" or entry.pullQuality,
    qualityFlags = normalizeQualityFlags and normalizeQualityFlags(entry.qualityFlags) or safeDeepcopy(entry.qualityFlags) or {},
    acceptedSampleCount = tonumber(entry.acceptedSampleCount) or 0,
    rejectedSampleCount = tonumber(entry.rejectedSampleCount) or 0,
    curve = safeDeepcopy(entry.curve) or {},
    rawSamples = safeDeepcopy(entry.rawSamples),
    averagedSamples = safeDeepcopy(entry.averagedSamples),
    averageWindow = entry.averageWindow,
    endReason = entry.endReason,
    cutoffTime = entry.cutoffTime,
    startBuffer = entry.startBuffer,
    tailBuffer = entry.tailBuffer
  }
end

local function loadPullHistory()
  pullHistoryByVehicle = {}
  nextPullHistoryId = 1
  pullHistoryLoaded = true

  local savePath = getCurrentSavePath()
  if not savePath then
    return
  end

  local data = jsonReadFile(savePath .. HISTORY_SAVE_FILE)
  if type(data) ~= "table" then
    return
  end

  nextPullHistoryId = math.max(1, math.floor(tonumber(data.nextId) or 1))
  local vehicles = type(data.vehicles) == "table" and data.vehicles or {}
  for inventoryId, entries in pairs(vehicles) do
    if type(entries) == "table" then
      local normalizedEntries = {}
      for _, entry in ipairs(entries) do
        local normalized = normalizeSavedPull(entry)
        if normalized then
          normalized.inventoryId = tostring(inventoryId)
          table.insert(normalizedEntries, normalized)
          nextPullHistoryId = math.max(nextPullHistoryId, normalized.id + 1)
          if #normalizedEntries >= HISTORY_LIMIT_PER_VEHICLE then
            break
          end
        end
      end
      if #normalizedEntries > 0 then
        pullHistoryByVehicle[tostring(inventoryId)] = normalizedEntries
      end
    end
  end
end

local function ensurePullHistoryLoaded()
  if not pullHistoryLoaded then
    loadPullHistory()
  end
end

local function savePullHistory(currentSavePath)
  ensurePullHistoryLoaded()
  currentSavePath = currentSavePath or getCurrentSavePath()
  if not currentSavePath then
    return false
  end

  local dirPath = currentSavePath .. "/career/rls_career"
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end

  return career_saveSystem.jsonWriteFileSafe(currentSavePath .. HISTORY_SAVE_FILE, {
    version = HISTORY_VERSION,
    nextId = nextPullHistoryId,
    vehicles = pullHistoryByVehicle
  }, true) == true
end

local function getPullHistoryForVehicle(inventoryId)
  ensurePullHistoryLoaded()
  if inventoryId == nil then
    return {}
  end
  return safeDeepcopy(pullHistoryByVehicle[tostring(inventoryId)] or {})
end

local function isShopOwnershipReady()
  if not career_career or not career_career.isActive or not career_career.isActive() then
    return true
  end
  local manager = career_modules_business_businessManager
  return manager ~= nil and type(manager.isBusinessOwnershipReady) == "function"
    and manager.isBusinessOwnershipReady() == true
end

local function getDynoBusinessBundle()
  local mapId = getCurrentLevelIdentifier and getCurrentLevelIdentifier()
  return bundles.forDyno(mapId, TRIGGER_NAME, SITE_FILE_NAME, PARKING_SPOT_NAME), mapId
end

local function shopNeedsOwnershipResolution()
  local bundle = getDynoBusinessBundle()
  return bundle ~= nil and not isShopOwnershipReady()
end

local function flushOwnershipWaitCallbacks()
  local callbacks = ownershipWaitCallbacks
  ownershipWaitCallbacks = {}
  for _, cb in ipairs(callbacks) do
    if cb then cb() end
  end
end

local function waitForShopOwnership(callback)
  if not shopNeedsOwnershipResolution() then
    if callback then callback() end
    return true
  end
  if callback then
    ownershipWaitCallbacks[#ownershipWaitCallbacks + 1] = callback
  end
  return true
end

local function resolveShopPolicy()
  local bundle, mapId = getDynoBusinessBundle()
  if bundle and not isShopOwnershipReady() then
    return {
      mapId = mapId,
      businessId = bundle.businessId,
      ownershipReady = false,
      ownerBenefit = false,
      unlimitedPulls = false,
      fee = 0
    }
  end
  local owner = bundles.isOwned(bundle)
  return {
    mapId = mapId,
    businessId = bundle and bundle.businessId,
    ownershipReady = true,
    ownerBenefit = owner,
    unlimitedPulls = owner,
    fee = owner and 0 or SESSION_FEE
  }
end

local function currentPolicy()
  return dynoSession.active and dynoSession.policy or resolveShopPolicy()
end

local function requireResolvedShopPolicy()
  local policy = resolveShopPolicy()
  if policy.ownershipReady == false then
    return nil, "Business ownership is still loading."
  end
  return policy
end

local function getFeePrice()
  return {
    money = {
      amount = currentPolicy().fee,
      canBeNegative = false
    }
  }
end

local function getMoneyPrice(amount)
  return {
    money = {
      amount = math.max(0, tonumber(amount) or 0),
      canBeNegative = false
    }
  }
end

local function canPayAmount(amount)
  if amount <= 0 then return true end
  return career_modules_payment and career_modules_payment.canPay and
           career_modules_payment.canPay(getMoneyPrice(amount)) == true
end

local function canPayFee()
  return canPayAmount(currentPolicy().fee)
end

local function chargeAmount(amount, label, tags)
  amount = math.max(0, tonumber(amount) or 0)
  if amount <= 0 then
    return true
  end
  if not canPayAmount(amount) or not career_modules_payment or not career_modules_payment.pay then
    return false
  end
  return career_modules_payment.pay(getMoneyPrice(amount), {
    label = label,
    tags = tags or {"dyno", "buying"}
  }) == true
end

local function refundAmount(amount, label)
  amount = math.max(0, tonumber(amount) or 0)
  if amount <= 0 then
    return true
  end
  if career_modules_payment and career_modules_payment.reward then
    return career_modules_payment.reward({money = {amount = amount}}, {
      label = label or "Dyno refund",
      tags = {"dyno", "refund"}
    }, true) == true
  end
  if career_modules_payment and career_modules_payment.pay then
    return career_modules_payment.pay({money = {amount = -amount, canBeNegative = true}}, {
      label = label or "Dyno refund",
      tags = {"dyno", "refund"}
    }) == true
  end
  return false
end

local function buildRepairQuote(inventoryId)
  local policy = currentPolicy()
  if policy.ownershipReady == false then
    return {ok = false, required = false, message = "Business ownership is still loading."}
  end
  local fee = policy.fee
  local finite = career_modules_finiteDamage
  if not finite or not finite.assess or not finite.quoteSelection then
    return {ok = false, required = false, message = "Private repair is unavailable."}
  end

  local assessment = finite.assess(inventoryId)
  if not assessment or not assessment.ok then
    return {ok = false, required = false, message = assessment and assessment.reason or "Vehicle damage could not be assessed."}
  end

  local selectedIds = {}
  local damageLines = {}
  for _, line in ipairs(assessment.lines or {}) do
    if line.selectable and line.kind ~= "tire" and line.id then
      table.insert(selectedIds, line.id)
      table.insert(damageLines, safeDeepcopy(line))
    end
  end

  if #selectedIds == 0 then
    return {
      ok = true,
      required = false,
      selectedIds = {},
      damageLines = {},
      baseCost = 0,
      laborMultiplier = 1,
      repairCost = 0,
      dynoFee = fee,
      totalCost = fee,
      revision = "clear:" .. tostring(inventoryId)
    }
  end

  local quote = finite.quoteSelection(inventoryId, selectedIds)
  if not quote or not quote.ok then
    return {ok = false, required = true, message = quote and quote.message or "Private repair could not be quoted."}
  end

  local laborMultiplier = quote.hasBrokenParts and 1.25 or 1.1
  local baseCost = tonumber(quote.totalPreLabor) or 0
  local repairCost = math.ceil(baseCost * laborMultiplier - 0.000001)
  local revisionRows = {}
  for _, line in ipairs(quote.selectedLines or {}) do
    table.insert(revisionRows, string.format("%s:%d", tostring(line.id), math.floor((tonumber(line.cost) or 0) + 0.5)))
  end
  table.sort(revisionRows)

  return {
    ok = true,
    required = true,
    selectedIds = selectedIds,
    damageLines = damageLines,
    baseCost = baseCost,
    laborMultiplier = laborMultiplier,
    repairCost = repairCost,
    dynoFee = fee,
    totalCost = repairCost + fee,
    hasBrokenParts = quote.hasBrokenParts == true,
    selectedCount = #selectedIds,
    revision = table.concat(revisionRows, "|") .. string.format("|%.2f|%d", laborMultiplier, repairCost)
  }
end

local function buildVehicleName(vehicleData, inventoryId)
  if not vehicleData then
    return "Current Vehicle"
  end

  -- Prefer the inventory's display name (same as the rest of the career UI) over the raw config id.
  if inventoryId and career_modules_inventory and career_modules_inventory.getVehicleNiceNameTranslated then
    local ok, niceName = pcall(career_modules_inventory.getVehicleNiceNameTranslated, inventoryId)
    if ok and type(niceName) == "string" and niceName ~= "" then
      return niceName
    end
  end
  local niceName = vehicleData.niceName
  if type(niceName) == "string" and core_locales and core_locales.translateWithOrWithoutContext then
    niceName = core_locales.translateWithOrWithoutContext(niceName)
  end
  if type(niceName) == "string" and niceName ~= "" then
    return niceName
  end

  local parts = {}
  if vehicleData.year then
    table.insert(parts, tostring(vehicleData.year))
  end
  if vehicleData.brand then
    table.insert(parts, tostring(vehicleData.brand))
  end
  if vehicleData.name then
    table.insert(parts, tostring(vehicleData.name))
  elseif vehicleData.model then
    table.insert(parts, tostring(vehicleData.model))
  end

  if #parts == 0 then
    return "Current Vehicle"
  end

  return table.concat(parts, " ")
end

local function getCurrentVehicleContext()
  if not career_career.isActive() then
    return nil, "Career mode must be active."
  end

  if gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking() then
    return nil, "Enter one of your vehicles to use the dyno."
  end

  local veh = be:getPlayerVehicle(0)
  if not veh then
    return nil, "Drive a vehicle into the dyno trigger."
  end

  -- The inventory cache can lag behind direct switches between already-spawned
  -- owned vehicles. The live object mapping is authoritative for a trigger the
  -- player is physically driving into; only fall back to the cache if needed.
  local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(veh:getID())
  if not inventoryId then
    inventoryId = career_modules_inventory.getCurrentVehicle()
  end

  if not inventoryId then
    return nil, "Only owned inventory vehicles can use the dyno."
  end

  local vehicleData = career_modules_inventory.getVehicles()[inventoryId]
  if not vehicleData then
    return nil, "Vehicle data could not be found."
  end

  return {
    inventoryId = inventoryId,
    veh = veh,
    vehicleId = veh:getID(),
    vehicleData = vehicleData,
    vehicleName = buildVehicleName(vehicleData, inventoryId)
  }
end

local function showDynoHud()
  guihooks.trigger("DynoSessionHudShow")
end

local function hideDynoHud()
  guihooks.trigger("DynoSessionHudHide")
end

local function openDynoUi()
  showDynoHud()
end

local function closeDynoUi()
  hideDynoHud()
end

local function clearPendingSnapshots()
  for _, pending in pairs(pendingConfigSnapshots) do
    if pending and pending.extraData and pending.extraData.prepaidFee then
      refundAmount(pending.extraData.prepaidFeePaid, "Cancelled dyno setup refund")
      pending.extraData.prepaidFeePaid = 0
      pending.extraData.prepaidFee = false
    end
  end
  table.clear(pendingConfigSnapshots)
end

local function resetDynoSessionState()
  repairRespawnPending = false
  conditionRefreshToken = conditionRefreshToken + 1
  conditionRefreshPending = false
  conditionRefreshCallbacks = {}
  ownershipWaitCallbacks = {}
  hideDynoHud()
  clearPendingSnapshots()
  dynoSession.active = false
  dynoSession.inventoryId = nil
  dynoSession.sourceVehicleId = nil
  dynoSession.originalTransform = nil
  dynoSession.originalConfig = nil
  dynoSession.originalPartConditions = nil
  dynoSession.originalLiveConfig = nil
  dynoSession.sessionVehicleId = nil
  dynoSession.selectedHubId = DEFAULT_DYNO_HUB_ID
  dynoSession.hubConfigApplied = false
  dynoSession.pullState = nil
  dynoSession.result = nil
  dynoSession.pullsUsed = 0
  dynoSession.setupFeeRefundable = false
  dynoSession.feePaid = 0
  dynoSession.policy = nil
  dynoSession.serviceOpen = nil
  dynoSession.resumePhase = nil
  dynoSession.retryArmDelay = nil
  dynoSession.lastHudPushTime = nil
  dynoSession.phase = "offer"
  dynoSession.error = nil
  dynoSession.statusText = nil
end

local function flushConditionRefreshCallbacks()
  local callbacks = conditionRefreshCallbacks
  conditionRefreshCallbacks = {}
  for _, cb in ipairs(callbacks) do
    if cb then cb() end
  end
end

local function refreshLiveVehicleConditions(context, callback)
  if callback then
    conditionRefreshCallbacks[#conditionRefreshCallbacks + 1] = callback
  end
  if conditionRefreshPending then
    return true
  end
  if not context or not context.inventoryId then
    flushConditionRefreshCallbacks()
    return false
  end

  conditionRefreshPending = true
  conditionRefreshToken = conditionRefreshToken + 1
  local token = conditionRefreshToken
  local function finished()
    if token ~= conditionRefreshToken then return end
    conditionRefreshPending = false
    flushConditionRefreshCallbacks()
  end

  if career_modules_inventory and career_modules_inventory.updatePartConditions then
    career_modules_inventory.updatePartConditions(context.vehicleId, context.inventoryId, finished)
  else
    finished()
  end
  return true
end

normalizeQualityFlags = function(flags)
  local normalized = {}
  if type(flags) == "table" then
    for key, value in pairs(flags) do
      if type(key) == "number" then
        normalized[tostring(value)] = true
      elseif value then
        normalized[tostring(key)] = true
      end
    end
  end
  return normalized
end

local function getQualityFromFlags(flags, valid)
  return valid and (not flags or next(flags) == nil) and "clean" or "warning"
end

local function setDynoError(message, phase)
  dynoSession.error = message
  dynoSession.phase = phase or dynoSession.phase
  dynoSession.statusText = message
  guihooks.trigger("DynoSessionHudState", requestSessionData())
end

local function captureVehicleTransform(veh)
  if not veh then
    return nil
  end

  return {
    pos = vec3(veh:getPosition()),
    rot = quat(0, 0, 1, 0) * quat(veh:getRefNodeRotation())
  }
end

local function restoreVehicleTransform(veh, transform)
  if not veh or not transform or not transform.pos or not transform.rot then
    return false
  end

  if spawn and spawn.safeTeleport then
    spawn.safeTeleport(veh, transform.pos, transform.rot, nil, nil, nil, nil, false)
    return true
  end

  veh:setPosRot(
    transform.pos.x,
    transform.pos.y,
    transform.pos.z,
    transform.rot.x,
    transform.rot.y,
    transform.rot.z,
    transform.rot.w
  )
  return true
end

local function setVehicleFreeze(veh, shouldFreeze)
  if not veh then
    return
  end

  if core_vehicleBridge and core_vehicleBridge.executeAction then
    pcall(function()
      core_vehicleBridge.executeAction(veh, "setFreeze", shouldFreeze and true or false)
    end)
  else
    veh:queueLuaCommand(string.format("controller.setFreeze(%d)", shouldFreeze and 1 or 0))
  end
end

local function setVehicleIgnition(veh, level)
  if not veh then
    return
  end

  if core_vehicleBridge and core_vehicleBridge.executeAction then
    pcall(function()
      core_vehicleBridge.executeAction(veh, "setIgnitionLevel", level)
    end)
  else
    veh:queueLuaCommand(string.format("if electrics and electrics.setIgnitionLevel then electrics.setIgnitionLevel(%d) end", level))
  end
end

local function setVehicleGearboxMode(veh, mode)
  if not veh or not mode then
    return
  end

  if core_vehicleBridge and core_vehicleBridge.executeAction then
    pcall(function()
      core_vehicleBridge.executeAction(veh, "setGearboxMode", mode)
    end)
  else
    veh:queueLuaCommand(string.format([[if controller and controller.mainController and controller.mainController.setGearboxMode then controller.mainController.setGearboxMode(%q) end]], mode))
  end
end

local function getRuntimeFFBConfig(veh)
  local result = {}
  if core_input_bindings and core_input_bindings.getFFBConfigForAction then
    for _, action in ipairs({"steering", "accelerate", "brake"}) do
      local config, id = core_input_bindings.getFFBConfigForAction(veh, action)
      if config then config.FFBID = id; result[action] = config end
    end
  end
  return result
end

local function protectDynoSteering(veh, acknowledge)
  if not veh then return end
  local id = veh:getID()
  protectedSteeringVehicles[id] = true
  local config = getRuntimeFFBConfig(veh)
  veh:queueLuaCommand(string.format([[
    extensions.load("careerDynoControls")
    careerDynoControls.protect(%s)
    %s
  ]], serialize(config), acknowledge and string.format(
    'obj:queueGameEngineLua("career_modules_dynoSession.onSteeringProtectionReady(%d, %d)")', id, steeringSetupToken) or ""))
end

local function releaseDynoSteering(veh)
  if not veh then return end
  protectedSteeringVehicles[veh:getID()] = nil
  local config = getRuntimeFFBConfig(veh)
  veh:queueLuaCommand(string.format([[
    if careerDynoControls then careerDynoControls.release(%s) end
  ]], serialize(config)))
end

local function releaseAllDynoSteering()
  for id in pairs(protectedSteeringVehicles) do
    local veh = getObjectByID(id)
    if veh then releaseDynoSteering(veh) end
    protectedSteeringVehicles[id] = nil
  end
end

local function onSteeringProtectionReady(id, token)
  if token ~= steeringSetupToken or not pendingSteeringSetup or id ~= dynoSession.sourceVehicleId or dynoSession.phase ~= "starting" then return end
  local start = pendingSteeringSetup
  pendingSteeringSetup = nil
  start()
end

-- Spawn callbacks run before the new vehicle starts simulation. Queue the guard
-- on the new VM as well as muting the old VM before asking inventory to rebuild.
local function onVehicleSpawned(id)
  if not dynoSession.active then return end
  local mapped = career_modules_inventory.getVehicleIdFromInventoryId(dynoSession.inventoryId)
  if id == dynoSession.sourceVehicleId or id == dynoSession.sessionVehicleId or id == mapped then
    protectDynoSteering(getObjectByID(id))
  end
end

local function onFFBConfigChanged()
  for id in pairs(protectedSteeringVehicles) do
    protectDynoSteering(getObjectByID(id))
  end
end

local function stopVehiclePullExtension(veh)
  if not veh then
    return
  end

  veh:queueLuaCommand([[
    if extensions and extensions.isExtensionLoaded and extensions.isExtensionLoaded("careerDynoSession") then
      if careerDynoSession and careerDynoSession.abortPull then
        careerDynoSession.abortPull()
      end
    end
  ]])
end

local function getDynoParkingSpot()
  local sitePath = gameplay_sites_sitesManager.getCurrentLevelSitesFileByName(SITE_FILE_NAME)
  if not sitePath then
    local levelInfo = getCurrentLevelIdentifier()
    if levelInfo then
      sitePath = "/levels/" .. levelInfo .. "/" .. SITE_FILE_NAME .. ".sites.json"
    end
  end

  if not sitePath then
    return nil, "Dyno sites file could not be found."
  end

  local sites = gameplay_sites_sitesManager.loadSites(sitePath)
  if not sites or not sites.parkingSpots or not sites.parkingSpots.byName then
    return nil, "Dyno parking spot data is missing."
  end

  local parkingSpot = sites.parkingSpots.byName[PARKING_SPOT_NAME]
  if not parkingSpot or parkingSpot.missing then
    return nil, "Dyno parking spot '" .. PARKING_SPOT_NAME .. "' was not found."
  end

  return parkingSpot
end

-- Inventory respawns can keep the scene object ID while renumbering its nodes.
-- Refresh after the spawn callbacks publish the new vdata, including on exit
-- when the session itself is already inactive. A pose reset alone keeps stale IDs.
local pendingCameraRefresh = {}
local function refreshDynoCamera(veh)
  pendingCameraRefresh[veh:getID()] = 2
end

local function updateDynoCameras()
  for id, frames in pairs(pendingCameraRefresh) do
    if frames > 0 then
      pendingCameraRefresh[id] = frames - 1
    else
      pendingCameraRefresh[id] = nil
      local veh = getObjectByID(id)
      if veh and core_camera then
        -- Rebuild all camera modes from the vehicle's current camera definitions,
        -- including model-specific reference nodes, offsets and default distance.
        core_camera.onVehicleSpawned(id)
        if be:getPlayerVehicleID(0) == id then core_camera.resetCamera(0) end
      end
    end
  end
end

local function alignVehicleToDynoSpot(veh, parkingSpot)
  if not veh or not parkingSpot or not parkingSpot.rot then return end
  local pos = veh:getPosition()
  local rot = quat(0, 0, 1, 0) * quat(parkingSpot.rot)
  veh:setPosRot(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
  if veh.setOriginalTransform then
    veh:setOriginalTransform(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
  end
end

local function moveVehicleToDyno(veh)
  local parkingSpot, parkingError = getDynoParkingSpot()
  if not parkingSpot then
    return false, parkingError
  end

  if parkingSpot.moveResetVehicleTo then
    local ok, err = pcall(function()
      parkingSpot:moveResetVehicleTo(veh:getID(), nil, nil, nil, nil, true)
    end)
    if ok then
      alignVehicleToDynoSpot(veh, parkingSpot)
      refreshDynoCamera(veh)
      return true
    end
    return false, tostring(err)
  end

  return false, "Dyno parking spot could not move the vehicle."
end

local function getDynoHubOption(hubId)
  return DYNO_HUB_OPTIONS[hubId] or DYNO_HUB_OPTIONS[DEFAULT_DYNO_HUB_ID]
end

local function isDynoHubAvailable(hubId)
  local option = DYNO_HUB_OPTIONS[hubId]
  if not option then
    return false
  end

  -- RLS hardware ships with this mod. Optional hub providers are considered
  -- available only when one of their unique files is mounted in BeamNG's VFS,
  -- which also excludes installed-but-disabled mods.
  if not option.requiredFile then
    return true
  end
  if not FS or not FS.fileExists then
    return false
  end

  local ok, exists = pcall(function()
    return FS:fileExists(option.requiredFile)
  end)
  return ok and exists == true
end

local function getDynoHubOptionsForUi()
  local options = {}
  for _, hubId in ipairs(DYNO_HUB_ORDER) do
    local option = DYNO_HUB_OPTIONS[hubId]
    if isDynoHubAvailable(hubId) then
      table.insert(options, {
        id = option.id,
        label = option.label,
        description = option.description
      })
    end
  end
  return options
end

local function getWheelSlotType(node, jbeamData)
  local function asWheelSlotType(value)
    if type(value) == "string" and value:match("^wheel_[FR]_.+$") then
      return value
    end
    return nil
  end

  -- The part tree node identifies the slot that the selected wheel currently
  -- occupies. Prefer it over the wheel part's slotType because modded wheels
  -- commonly declare several compatible slot types as an array.
  local slotType = asWheelSlotType(node and node.id)
  if slotType then
    return slotType
  end

  if node and type(node.path) == "string" then
    slotType = node.path:match("/(wheel_[FR]_[^/]+)/?$")
    if slotType then
      return slotType
    end
  end

  local declaredSlotType = jbeamData and jbeamData.slotType or nil
  slotType = asWheelSlotType(declaredSlotType)
  if slotType then
    return slotType
  end

  -- An array is only safe as a fallback when it names one wheel slot. If it
  -- advertises multiple lug patterns, the part-tree node/path must decide.
  if type(declaredSlotType) == "table" then
    local onlySlotType = nil
    for _, candidate in ipairs(declaredSlotType) do
      candidate = asWheelSlotType(candidate)
      if candidate then
        if onlySlotType and onlySlotType ~= candidate then
          return nil
        end
        onlySlotType = candidate
      end
    end
    return onlySlotType
  end

  return nil
end

local function replaceWheelEntriesWithDynoHubs(vehId, partsTree, hubId)
  if not vehId or not partsTree then
    return nil, "Vehicle wheel data is unavailable."
  end

  local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
  if not vehicleData or not vehicleData.ioCtx then
    return nil, "Vehicle part context is unavailable."
  end

  local replacedCount = 0

  local function walk(node)
    if not node then
      return true
    end

    if node.chosenPartName and node.chosenPartName ~= "" then
      local jbeamData = jbeamIO.getPart(vehicleData.ioCtx, node.chosenPartName)
      local slotType = getWheelSlotType(node, jbeamData)

      if slotType then
        local axle = nil
        if slotType:match("^wheel_F_") then
          axle = "front"
        elseif slotType:match("^wheel_R_") then
          axle = "rear"
        end

        if axle then
          local dynoPartName = getDynoHubPartName(slotType, axle, hubId)
          if not dynoPartName then
            return false, string.format("Missing dyno hub for slot type '%s'.", tostring(slotType))
          end

          if not jbeamIO.getPart(vehicleData.ioCtx, dynoPartName) then
            local hubOption = getDynoHubOption(hubId)
            return false, string.format("%s does not provide a hub for slot type '%s' yet.", hubOption.label, tostring(slotType))
          end

          node.chosenPartName = dynoPartName
          node.children = nil
          node.decisionMethod = "user"
          replacedCount = replacedCount + 1
        end
      end
    end

    for _, childNode in pairs(node.children or {}) do
      local ok, err = walk(childNode)
      if not ok then
        return false, err
      end
    end

    return true
  end

  local ok, err = walk(partsTree)
  if not ok then
    return nil, err
  end

  return replacedCount
end

getDynoHubPartName = function(slotType, axle, hubId)
  local hubOption = getDynoHubOption(hubId)
  if hubOption.partsBySlot then
    return hubOption.partsBySlot[slotType]
  end
  if axle == "front" then
    local suffix = slotType and slotType:match("^wheel_F_(.+)$")
    if suffix and SUPPORTED_FRONT_SUFFIXES[suffix] then
      return hubOption.frontPartPrefix .. suffix
    end
  elseif axle == "rear" then
    local suffix = slotType and slotType:match("^wheel_R_(.+)$")
    if suffix and SUPPORTED_REAR_SUFFIXES[suffix] then
      return hubOption.rearPartPrefix .. suffix
    end
  end

  return nil
end

local function buildDynoConfig(config, vehId, hubId)
  if not config then
    return nil, "Vehicle configuration is missing."
  end

  local fullConfig = safeDeepcopy(config)
  if not fullConfig.partsTree then
    return nil, "The dyno could not read the vehicle part tree."
  end

  local replacedCount, replaceError = replaceWheelEntriesWithDynoHubs(vehId, fullConfig.partsTree, hubId)
  if not replacedCount then
    return nil, replaceError
  end

  if replacedCount == 0 then
    return nil, "The dyno could not find any wheel slots to replace."
  end

  if getDynoHubOption(hubId).id == "rls" then
    fullConfig = overhaul_rlsHubDyno.prepareConfig(fullConfig)
  end
  return fullConfig
end

local function requestVehicleConfigSnapshot(veh, requestType, extraData)
  if not veh then
    return nil
  end

  local callbackId = string.format("%d_%d_%d", veh:getID(), os.time(), math.random(1000, 9999))
  pendingConfigSnapshots[callbackId] = {
    type = requestType,
    extraData = extraData or {}
  }

  veh:queueLuaCommand([[
    local configData = serialize(v.config)
    local tireState = rlsTireProvider and rlsTireProvider.getRlsTireTelemetry and
                        rlsTireProvider.getRlsTireTelemetry() or nil
    obj:queueGameEngineLua("career_modules_dynoSession.onVehicleConfigSnapshotReceived(']] .. callbackId .. [[', " ..
      configData .. ", " .. serialize(tireState) .. ")")
  ]])

  return callbackId
end

local function finalizeUiAfterLeave()
  resetDynoSessionState()
  closeDynoUi()
end

local function beginTireProtection(inventoryId, liveState)
  if not career_modules_tireSystem then
    return false
  end
  if career_modules_tireSystem.beginDynoSession then
    return career_modules_tireSystem.beginDynoSession(inventoryId, liveState) == true
  end
  return career_modules_tireSystem.setDynoOverride and
           career_modules_tireSystem.setDynoOverride(inventoryId, true) == true
end

local function endTireProtection(inventoryId)
  if not career_modules_tireSystem then
    return false
  end
  if career_modules_tireSystem.endDynoSession then
    return career_modules_tireSystem.endDynoSession(inventoryId) == true
  end
  return career_modules_tireSystem.setDynoOverride and
           career_modules_tireSystem.setDynoOverride(inventoryId, false) == true
end

local function syncTunedVarsToOriginalConfig()
  if not dynoSession.inventoryId or not dynoSession.originalConfig then
    return
  end
  local vehicleData = career_modules_inventory.getVehicles()[dynoSession.inventoryId]
  local currentVars
  if dynoSession.serviceOpen == "tuning" and career_modules_tuning and
      career_modules_tuning.getPurchasedVarsForInventory then
    currentVars = career_modules_tuning.getPurchasedVarsForInventory(dynoSession.inventoryId)
  end
  currentVars = currentVars or (vehicleData and vehicleData.config and vehicleData.config.vars or nil)
  if type(currentVars) == "table" then
    dynoSession.originalConfig.vars = safeDeepcopy(currentVars)
  end
end

local function sameInventoryId(first, second)
  return first ~= nil and second ~= nil and tostring(first) == tostring(second)
end

local function isTransientConfigActive(targetInventoryId)
  return dynoSession.active == true and dynoSession.hubConfigApplied == true and
           sameInventoryId(targetInventoryId, dynoSession.inventoryId)
end

local function buildInventorySaveOverride(originalConfig, originalPartConditions, durableVars)
  if type(originalConfig) ~= "table" then return nil end
  local result = {
    config = safeDeepcopy(originalConfig),
    partConditions = safeDeepcopy(originalPartConditions),
  }
  if type(durableVars) == "table" then
    result.config.vars = safeDeepcopy(durableVars)
  end
  return result
end

local function getInventorySaveOverride(targetInventoryId)
  if not isTransientConfigActive(targetInventoryId) then return nil end

  local durableVars
  if dynoSession.serviceOpen == "tuning" and career_modules_tuning and
      career_modules_tuning.getPurchasedVarsForInventory then
    durableVars = career_modules_tuning.getPurchasedVarsForInventory(dynoSession.inventoryId)
  end
  durableVars = durableVars or (dynoSession.originalConfig and dynoSession.originalConfig.vars)
  return buildInventorySaveOverride(
    dynoSession.originalConfig, dynoSession.originalPartConditions, durableVars)
end

local function applyInventorySpawnOverrides(data)
  if type(data) ~= "table" or not isTransientConfigActive(dynoSession.inventoryId) or
      type(dynoSession.originalTransform) ~= "table" then
    return false
  end
  data.spawnedPlayerVehicles = type(data.spawnedPlayerVehicles) == "table" and
                                 data.spawnedPlayerVehicles or {}
  data.spawnedPlayerVehicles[tostring(dynoSession.inventoryId)] = {
    pos = safeDeepcopy(dynoSession.originalTransform.pos),
    rot = safeDeepcopy(dynoSession.originalTransform.rot),
  }
  return true
end

local function commitTuningPurchase(targetInventoryId, purchasedVars)
  if not isTransientConfigActive(targetInventoryId) or type(purchasedVars) ~= "table" or
      type(dynoSession.originalConfig) ~= "table" then
    return false
  end
  dynoSession.originalConfig.vars = safeDeepcopy(purchasedVars)
  return true
end

local function refundSetupFee(reason)
  if not dynoSession.setupFeeRefundable then
    return
  end
  dynoSession.setupFeeRefundable = false
  local paid = dynoSession.feePaid or 0
  dynoSession.feePaid = 0
  refundAmount(paid, reason or "Dyno setup refund")
end

local function rememberPlateMesh(set, mesh)
  if type(mesh) == "string" and mesh ~= "" then
    set[mesh] = true
  end
end

local function plateMeshSet(veh, vdata)
  local set = {}
  local ok, meshes = pcall(function()
    return veh:getMeshesContainingMaterial("licenseplate")
  end)
  if ok and type(meshes) == "string" then
    for mesh in meshes:gmatch("%S+") do
      rememberPlateMesh(set, mesh)
    end
  end
  local function consider(entry)
    if type(entry) ~= "table" then return end
    local mesh = entry.mesh
    local originalMesh = entry.originalMesh
    local function plateName(meshName)
      if type(meshName) ~= "string" then return false end
      local lowered = meshName:lower()
      return lowered:find("licenseplate", 1, true) or lowered:find("licenceplate", 1, true)
    end
    local named = plateName(mesh) or plateName(originalMesh)
    if named or set[mesh] or set[originalMesh] then
      rememberPlateMesh(set, mesh)
      rememberPlateMesh(set, originalMesh)
    end
  end
  if vdata then
    for _, flexbody in pairs(vdata.flexbodies or {}) do
      consider(flexbody)
    end
    for _, prop in pairs(vdata.props or {}) do
      consider(prop)
    end
  end
  return set
end

local function refreshVehiclePartVisibility(vehId)
  -- Inventory respawns reuse a vehicle ID. A highlight map left on that id
  -- (engine thumbnail isolate, or the old dyno-hub pass) stores false for
  -- wheels. setNewParts copies those false entries, so drop the map first.
  core_vehicle_partmgmt.resetVehicleHighlights(false, vehId)
  core_vehicle_partmgmt.setNewParts(vehId)
  local veh = getObjectByID(vehId)
  if not veh then return end
  local vehicleData = core_vehicle_manager and core_vehicle_manager.getVehicleData(vehId)
  local vdata = vehicleData and vehicleData.vdata
  local plates = plateMeshSet(veh, vdata)
  local seen = {}
  local function showMesh(entry)
    if type(entry) ~= "table" then return end
    local mesh = entry.mesh
    if type(mesh) ~= "string" or mesh == "" or seen[mesh] or plates[mesh] or plates[entry.originalMesh] then return end
    if mesh == "SPOTLIGHT" or mesh == "POINTLIGHT" then return end
    seen[mesh] = true
    pcall(function() veh:setMeshAlpha(1, mesh, false) end)
  end
  if vdata then
    for _, flexbody in pairs(vdata.flexbodies or {}) do
      showMesh(flexbody)
    end
    for _, prop in pairs(vdata.props or {}) do
      showMesh(prop)
    end
  end
  if overhaul_licensePlates and overhaul_licensePlates.requestRefresh then
    overhaul_licensePlates.requestRefresh(vehId)
  end
end

local function finishSessionRestore()
  pendingSteeringSetup = nil
  if not dynoSession.inventoryId then
    releaseAllDynoSteering()
    finalizeUiAfterLeave()
    return
  end

  local inventoryId = dynoSession.inventoryId
  refundSetupFee("Dyno setup refund")
  syncTunedVarsToOriginalConfig()
  local transform = safeDeepcopy(dynoSession.originalTransform)
  local originalConfig = safeDeepcopy(dynoSession.originalConfig)

  local vehicleData = career_modules_inventory.getVehicles()[inventoryId]
  if vehicleData and originalConfig then
    vehicleData.config = originalConfig
  end
  career_modules_inventory.spawnVehicle(inventoryId, 2, function()
    local restoredVehId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
    local restoredVeh = restoredVehId and getObjectByID(restoredVehId) or nil

    if restoredVeh then refreshVehiclePartVisibility(restoredVehId) end

    -- Keep the dyno override active while the hub vehicle is removed. Its
    -- shutdown state must not overwrite the tire snapshot. Restore and
    -- re-enable tire persistence only after the original wheels exist again.
    endTireProtection(inventoryId)

    if restoredVeh and transform then
      restoreVehicleTransform(restoredVeh, transform)
      setVehicleFreeze(restoredVeh, false)
      setVehicleIgnition(restoredVeh, 0)
      be:enterVehicle(0, restoredVeh)
      refreshDynoCamera(restoredVeh)
    end

    releaseAllDynoSteering()
    if restoredVeh then releaseDynoSteering(restoredVeh) end
    finalizeUiAfterLeave()
  end)
end

local function abandonSessionWithoutRestore()
  pendingSteeringSetup = nil
  releaseAllDynoSteering()
  if dynoSession.inventoryId then
    refundSetupFee("Dyno setup refund")
    endTireProtection(dynoSession.inventoryId)
  end
  resetDynoSessionState()
  closeDynoUi()
end

local function leaveSession()
  if not dynoSession.active then
    abandonSessionWithoutRestore()
    return true
  end

  local sessionVeh = dynoSession.sessionVehicleId and getObjectByID(dynoSession.sessionVehicleId) or nil
  if sessionVeh then
    stopVehiclePullExtension(sessionVeh)
  end

  dynoSession.phase = "leaving"
  dynoSession.statusText = "Restoring your vehicle."

  finishSessionRestore()
  return true
end

local function startSessionFromSnapshot(config, extraData, tireState)
  local prepaidFee = extraData and extraData.prepaidFee == true
  local feePaid = prepaidFee and (extraData.prepaidFeePaid or 0) or 0
  local policy = extraData and extraData.policy
  if not policy or policy.ownershipReady == false then
    local resolved, resolveError = requireResolvedShopPolicy()
    if not resolved then
      if prepaidFee then
        refundAmount(feePaid, "Dyno setup refund")
      end
      setDynoError(resolveError or "Business ownership is still loading.", "offer")
      return false
    end
    policy = resolved
    if extraData then extraData.policy = policy end
  end
  -- Transfer the pending payment token once, so cancellation cannot refund twice.
  local repairPaid = extraData and tonumber(extraData.repairCostPaid) or 0
  local repairInventoryId = extraData and extraData.inventoryId
  if extraData then extraData.prepaidFeePaid = 0; extraData.prepaidFee = false; extraData.repairCostPaid = 0 end
  local function failBeforeActivation(message)
    message = message or "The dyno session could not start."
    log("W", "dynoSession", "Session start failed: " .. tostring(message))
    if prepaidFee then
      refundAmount(feePaid, "Dyno setup refund")
      feePaid = 0
      prepaidFee = false
    end
    -- A paid private repair that did not hold (the car still needs repair) must not keep the player's money
    if repairPaid > 0 and repairInventoryId then
      local check = buildRepairQuote(repairInventoryId)
      if not check.ok or check.required then
        refundAmount(repairPaid, "Private dyno repair refund")
        message = message .. " The private repair was refunded."
      end
      repairPaid = 0
    end
    setDynoError(message, "offer")
    return false
  end

  if policy.mapId ~= (getCurrentLevelIdentifier and getCurrentLevelIdentifier()) then
    return failBeforeActivation("The dyno location changed during setup.")
  end
  local context, contextError = getCurrentVehicleContext()
  if not context then
    return failBeforeActivation(contextError or "The dyno session could not start.")
  end

  if dynoSession.active then
    return failBeforeActivation("A dyno session is already active.")
  end

  if not playerInsideTrigger then
    return failBeforeActivation("Drive into the dyno trigger to start a session.")
  end

  local repairQuote = buildRepairQuote(context.inventoryId)
  if not repairQuote.ok then
    return failBeforeActivation(repairQuote.message)
  end
  if repairQuote.required then
    return failBeforeActivation("Repair the vehicle first to start the dyno.")
  end

  if not prepaidFee and not canPayAmount(policy.fee) then
    return failBeforeActivation("You do not have enough funds for the dyno session.")
  end

  local requestedHubId = extraData and extraData.hubId or DEFAULT_DYNO_HUB_ID
  if not isDynoHubAvailable(requestedHubId) then
    return failBeforeActivation("The selected dyno hub is not available.")
  end

  local dynoConfig, dynoConfigError = buildDynoConfig(config, context.vehicleId, requestedHubId)
  if not dynoConfig then
    return failBeforeActivation(dynoConfigError or "This vehicle is not supported by the dyno yet.")
  end

  if not prepaidFee then
    if not chargeAmount(policy.fee, "Dyno session fee", {"dyno", "tuning", "buying"}) then
      return failBeforeActivation("The dyno session payment could not be processed.")
    end
    prepaidFee = true
    feePaid = policy.fee
  end

  if not beginTireProtection(context.inventoryId, tireState) then
    return failBeforeActivation("The dyno could not protect the vehicle's tire state.")
  end

  local inventoryVehicleData = context.vehicleData
  dynoSession.active = true
  dynoSession.inventoryId = context.inventoryId
  dynoSession.sourceVehicleId = context.vehicleId
  dynoSession.originalTransform = captureVehicleTransform(context.veh)
  dynoSession.originalConfig = safeDeepcopy(inventoryVehicleData.config)
  dynoSession.originalPartConditions = safeDeepcopy(inventoryVehicleData.partConditions)
  dynoSession.originalLiveConfig = safeDeepcopy(config)
  dynoSession.selectedHubId = requestedHubId
  dynoSession.hubConfigApplied = true
  dynoSession.result = nil
  dynoSession.pullState = nil
  dynoSession.pullsUsed = 0
  dynoSession.policy = policy
  dynoSession.feePaid = feePaid
  dynoSession.setupFeeRefundable = prepaidFee
  prepaidFee = false
  dynoSession.phase = "starting"
  dynoSession.error = nil
  dynoSession.statusText = "Moving your vehicle onto the dyno."

  inventoryVehicleData.config = dynoConfig

  pendingSteeringSetup = function()
    career_modules_inventory.spawnVehicle(context.inventoryId, 2, function()
      local sessionVehId = career_modules_inventory.getVehicleIdFromInventoryId(context.inventoryId)
      local sessionVeh = sessionVehId and getObjectByID(sessionVehId) or nil

      if not sessionVeh then
        setDynoError("The dyno could not spawn your vehicle.", "offer")
        finishSessionRestore()
        return
      end

      protectDynoSteering(sessionVeh)
      dynoSession.sessionVehicleId = sessionVehId
      refreshVehiclePartVisibility(sessionVehId)
      beginTireProtection(context.inventoryId)
      local moved, moveError = moveVehicleToDyno(sessionVeh)
      if not moved then
        setDynoError(moveError or "The dyno parking spot could not move your vehicle.", "offer")
        finishSessionRestore()
        return
      end

      setVehicleFreeze(sessionVeh, true)
      setVehicleIgnition(sessionVeh, 0)
      dynoSession.phase = "ready"
      dynoSession.setupFeeRefundable = false
      dynoSession.statusText = "Start the engine, select a high forward gear, then arm the pull."
      dynoSession.error = nil

      be:enterVehicle(0, sessionVeh)
      openDynoUi()
    end)
  end
  steeringSetupTimer = 0
  steeringSetupToken = steeringSetupToken + 1
  protectDynoSteering(context.veh, true)

  return true
end

local startSession
startSession = function(hubId, conditionsFresh, ownershipFresh)
  if next(pendingConfigSnapshots) or pendingSteeringSetup then return false end
  -- a fresh press while an earlier one is still inspecting / setting up would start (and charge) twice
  if not conditionsFresh and not ownershipFresh and (dynoSession.phase == "inspecting" or dynoSession.phase == "starting") then
    return false
  end
  local context, contextError = getCurrentVehicleContext()
  if not context then
    setDynoError(contextError or "The dyno session could not start.", "offer")
    return false
  end

  if dynoSession.active then
    setDynoError("A dyno session is already active.", dynoSession.phase)
    return false
  end

  if not playerInsideTrigger then
    setDynoError("Drive into the dyno trigger to start a session.", "offer")
    return false
  end

  local requestedHubId = hubId or DEFAULT_DYNO_HUB_ID
  if not isDynoHubAvailable(requestedHubId) then
    setDynoError("The selected dyno hub is not available.", "offer")
    return false
  end

  if not ownershipFresh and shopNeedsOwnershipResolution() then
    dynoSession.selectedHubId = requestedHubId
    dynoSession.phase = "inspecting"
    dynoSession.error = nil
    dynoSession.statusText = "Checking business ownership."
    waitForShopOwnership(function()
      if playerInsideTrigger and not dynoSession.active then
        startSession(requestedHubId, conditionsFresh, true)
      end
    end)
    return true
  end

  if not conditionsFresh then
    dynoSession.selectedHubId = requestedHubId
    dynoSession.phase = "inspecting"
    dynoSession.error = nil
    dynoSession.statusText = "Inspecting current vehicle damage."
    local queued = refreshLiveVehicleConditions(context, function()
      if playerInsideTrigger and not dynoSession.active then
        startSession(requestedHubId, true, true)
      end
    end)
    if not queued then
      setDynoError("The vehicle damage inspection is already in progress.", "inspecting")
    end
    return queued
  end

  local policy, policyError = requireResolvedShopPolicy()
  if not policy then
    setDynoError(policyError or "Business ownership is still loading.", "offer")
    return false
  end

  local repairQuote = buildRepairQuote(context.inventoryId)
  if not repairQuote.ok then
    setDynoError(repairQuote.message or "Vehicle damage could not be assessed.", "offer")
    return false
  end
  if repairQuote.required then
    setDynoError("Repair first to start the dyno.", "offer")
    return false
  end

  if not canPayAmount(policy.fee) then
    setDynoError("You do not have enough funds for the dyno session.", "offer")
    return false
  end

  dynoSession.selectedHubId = requestedHubId
  dynoSession.phase = "starting"
  dynoSession.error = nil
  dynoSession.statusText = "Inspecting your vehicle for the dyno."

  local callbackId = requestVehicleConfigSnapshot(context.veh, "startSession", {
    inventoryId = context.inventoryId,
    sourceVehicleId = context.vehicleId,
    hubId = requestedHubId,
    policy = policy
  })

  if not callbackId then
    setDynoError("The dyno could not inspect the vehicle configuration.", "offer")
    return false
  end

  return true
end

local repairAndStart
repairAndStart = function(hubId, quoteRevision, conditionsFresh, ownershipFresh)
  if next(pendingConfigSnapshots) or pendingSteeringSetup then return {ok = false, message = "Dyno setup is already in progress."} end
  -- a fresh press while an earlier one is still inspecting / setting up would charge again
  if not conditionsFresh and not ownershipFresh and (dynoSession.phase == "inspecting" or dynoSession.phase == "starting") then
    return {ok = false, pending = true, message = "Dyno setup is already in progress."}
  end
  local context, contextError = getCurrentVehicleContext()
  if not context then
    setDynoError(contextError or "The dyno session could not start.", "offer")
    return {ok = false, message = dynoSession.error}
  end
  if dynoSession.active or not playerInsideTrigger then
    setDynoError(dynoSession.active and "A dyno session is already active." or "Drive into the dyno trigger to start a session.", "offer")
    return {ok = false, message = dynoSession.error}
  end

  local requestedHubId = hubId or DEFAULT_DYNO_HUB_ID
  if not isDynoHubAvailable(requestedHubId) then
    setDynoError("The selected dyno hub is not available.", "offer")
    return {ok = false, message = dynoSession.error}
  end

  if not ownershipFresh and shopNeedsOwnershipResolution() then
    dynoSession.selectedHubId = requestedHubId
    dynoSession.phase = "inspecting"
    dynoSession.error = nil
    dynoSession.statusText = "Checking business ownership."
    waitForShopOwnership(function()
      if playerInsideTrigger and not dynoSession.active then
        repairAndStart(requestedHubId, quoteRevision, conditionsFresh, true)
      end
    end)
    return {ok = true, pending = true}
  end

  if not conditionsFresh then
    dynoSession.selectedHubId = requestedHubId
    dynoSession.phase = "inspecting"
    dynoSession.error = nil
    dynoSession.statusText = "Rechecking current vehicle damage."
    local queued = refreshLiveVehicleConditions(context, function()
      if playerInsideTrigger and not dynoSession.active then
        repairAndStart(requestedHubId, quoteRevision, true, true)
      end
    end)
    if not queued then
      setDynoError("The vehicle damage inspection is already in progress.", "inspecting")
      return {ok = false, pending = true, message = dynoSession.error}
    end
    return {ok = true, pending = true}
  end

  local policy, policyError = requireResolvedShopPolicy()
  if not policy then
    setDynoError(policyError or "Business ownership is still loading.", "offer")
    return {ok = false, message = dynoSession.error}
  end

  local repairQuote = buildRepairQuote(context.inventoryId)
  if not repairQuote.ok then
    setDynoError(repairQuote.message or "Private repair could not be quoted.", "offer")
    return {ok = false, message = dynoSession.error}
  end
  if not repairQuote.required then
    return {ok = startSession(requestedHubId, true, true), repaired = false}
  end
  if not canPayAmount(repairQuote.totalCost) then
    setDynoError("You do not have enough funds for the private repair and dyno session.", "offer")
    return {ok = false, message = dynoSession.error}
  end
  if not chargeAmount(repairQuote.totalCost, "Private dyno repair and session", {"dyno", "repair", "buying"}) then
    setDynoError("The private repair payment could not be processed.", "offer")
    return {ok = false, message = dynoSession.error}
  end

  local applied = career_modules_finiteDamage.applySelection(context.inventoryId, repairQuote.selectedIds)
  if not applied or not applied.ok then
    refundAmount(repairQuote.totalCost, "Private dyno repair refund")
    setDynoError(applied and applied.message or "The private repair could not be completed.", "offer")
    return {ok = false, message = dynoSession.error}
  end

  local failedBaseCost = 0
  for _, line in ipairs(applied.failedLines or {}) do
    failedBaseCost = failedBaseCost + (tonumber(line.cost) or 0)
  end
  local failedRefund = math.min(repairQuote.repairCost,
    math.ceil(failedBaseCost * repairQuote.laborMultiplier - 0.000001))
  if failedRefund > 0 then
    refundAmount(failedRefund, "Private dyno repair partial refund")
  end

  local postRepairQuote = buildRepairQuote(context.inventoryId)
  if not postRepairQuote.ok or postRepairQuote.required then
    refundAmount(repairQuote.dynoFee, "Dyno session refund")
    setDynoError("The vehicle still needs repair. Successful work was kept and failed work was refunded.", "offer")
    return {ok = false, repaired = true, message = dynoSession.error}
  end

  dynoSession.selectedHubId = requestedHubId
  dynoSession.phase = "starting"
  dynoSession.error = nil
  dynoSession.statusText = "Private repair complete. Inspecting the vehicle for the dyno."
  local snapshotData = {
    inventoryId = context.inventoryId,
    sourceVehicleId = context.vehicleId,
    hubId = requestedHubId,
    prepaidFee = true,
    prepaidFeePaid = repairQuote.dynoFee,
    repairCostPaid = math.max(0, repairQuote.repairCost - failedRefund),
    policy = policy
  }
  local function inspectForDyno(veh)
    local callbackId = veh and requestVehicleConfigSnapshot(veh, "startSession", snapshotData)
    if not callbackId then
      refundAmount(repairQuote.dynoFee, "Dyno setup refund")
      setDynoError("The repair completed, but the dyno could not inspect the vehicle. The dyno fee was refunded.", "offer")
      return false
    end
    return true
  end

  -- Put the repair on the car in the world, the way the roadside / garage repair does: the repair above only
  -- changes the saved vehicle data, the spawned car stays damaged, and any later read of its condition (the
  -- bay's damage check, a save) copied the damage back over the repair the player had paid for.
  if career_modules_inventory.spawnVehicle and career_modules_inventory.getVehicleIdFromInventoryId(context.inventoryId) then
    repairRespawnPending = true
    if ui_fadeScreen and ui_fadeScreen.start then ui_fadeScreen.start(0.3) end
    career_modules_inventory.spawnVehicle(context.inventoryId, 2, function()
      repairRespawnPending = false
      playerInsideTrigger = true
      if ui_fadeScreen and ui_fadeScreen.stop then ui_fadeScreen.stop(0.3) end
      local vehId = career_modules_inventory.getVehicleIdFromInventoryId(context.inventoryId)
      snapshotData.sourceVehicleId = vehId or snapshotData.sourceVehicleId
      inspectForDyno(vehId and getObjectByID(vehId) or nil)
    end)
    return {ok = true, pending = true, repaired = true, repairCost = repairQuote.repairCost, dynoFee = repairQuote.dynoFee}
  end

  if not inspectForDyno(context.veh) then
    return {ok = false, repaired = true, message = dynoSession.error}
  end
  return {ok = true, repaired = true, repairCost = repairQuote.repairCost, dynoFee = repairQuote.dynoFee}
end

requestSessionData = function()
  local policy = currentPolicy()
  local ownershipReady = policy.ownershipReady ~= false
  local context = nil
  local contextError = nil

  if not dynoSession.active then
    context, contextError = getCurrentVehicleContext()
  else
    local vehicles = career_modules_inventory.getVehicles()
    local vehicleData = dynoSession.inventoryId and vehicles[dynoSession.inventoryId] or nil
    context = {
      inventoryId = dynoSession.inventoryId,
      vehicleData = vehicleData,
      vehicleName = buildVehicleName(vehicleData, dynoSession.inventoryId)
    }
  end

  local currentPhase = dynoSession.phase or "offer"
  local active = dynoSession.active and true or false
  local sessionBusy = currentPhase == "inspecting" or currentPhase == "starting" or currentPhase == "leaving"
    or #ownershipWaitCallbacks > 0
  local result = safeDeepcopy(dynoSession.result)
  local pullsUsed = math.max(0, math.floor(tonumber(dynoSession.pullsUsed) or 0))
  local pullsRemaining = policy.unlimitedPulls and 0 or math.max(0, SESSION_PULL_LIMIT - pullsUsed)
  local inventoryId = context and context.inventoryId or nil
  local repairQuote = nil
  if not active and inventoryId then
    repairQuote = buildRepairQuote(inventoryId)
  end
  local repairRequired = repairQuote and repairQuote.ok and repairQuote.required or false
  local offerTotal = (ownershipReady and (repairRequired and repairQuote.totalCost or policy.fee)) or 0
  local serviceAvailable = active and not dynoSession.serviceOpen and
                             (currentPhase == "ready" or currentPhase == "complete")
  local supportState = {
    supported = context ~= nil,
    reason = contextError
  }

  if not ownershipReady then
    supportState.reason = supportState.reason or "Business ownership is still loading."
  elseif context and repairQuote and not repairQuote.ok then
    supportState.supported = false
    supportState.reason = repairQuote.message
  elseif context then
    supportState.reason = nil
  end

  local hubOptions = getDynoHubOptionsForUi()
  local selectedHubId = dynoSession.selectedHubId or DEFAULT_DYNO_HUB_ID
  if not isDynoHubAvailable(selectedHubId) then
    selectedHubId = DEFAULT_DYNO_HUB_ID
    if not active then
      dynoSession.selectedHubId = selectedHubId
    end
  end

  return {
    fee = ownershipReady and policy.fee or 0,
    feePaid = dynoSession.feePaid or 0,
    ownerBenefit = ownershipReady and policy.ownerBenefit or false,
    unlimitedPulls = ownershipReady and policy.unlimitedPulls or false,
    ownershipReady = ownershipReady,
    pullLimit = (ownershipReady and policy.unlimitedPulls) and 0 or SESSION_PULL_LIMIT,
    pullsUsed = pullsUsed,
    pullsRemaining = pullsRemaining,
    triggerActive = playerInsideTrigger,
    active = active,
    phase = currentPhase,
    inventoryId = inventoryId,
    vehicleName = context and context.vehicleName or "Current Vehicle",
    selectedHubId = selectedHubId,
    hubOptions = hubOptions,
    repairRequired = repairRequired,
    repairQuote = repairQuote and repairQuote.ok and {
      baseCost = repairQuote.baseCost,
      laborMultiplier = repairQuote.laborMultiplier,
      repairCost = repairQuote.repairCost,
      dynoFee = ownershipReady and repairQuote.dynoFee or 0,
      totalCost = offerTotal,
      revision = repairQuote.revision,
      selectedCount = repairQuote.selectedCount or 0,
      damageLines = repairQuote.damageLines or {}
    } or nil,
    canPay = ownershipReady and canPayAmount(offerTotal) or false,
    canStart = ownershipReady and (not active) and (not repairRequired) and (not sessionBusy)
      and playerInsideTrigger and supportState.supported and canPayFee(),
    canRepairAndStart = ownershipReady and (not active) and repairRequired and (not sessionBusy)
      and playerInsideTrigger and supportState.supported and canPayAmount(offerTotal),
    canRetry = active and currentPhase == "complete" and (policy.unlimitedPulls or pullsRemaining > 0),
    canOpenTuning = serviceAvailable,
    canOpenMaintenance = serviceAvailable,
    serviceOpen = dynoSession.serviceOpen,
    canLeave = currentPhase ~= "pulling" and currentPhase ~= "resetting" and currentPhase ~= "leaving",
    support = supportState,
    pullInProgress = dynoSession.pullState and dynoSession.pullState.inProgress or false,
    pullStage = dynoSession.pullState and dynoSession.pullState.pullStage or nil,
    liveSample = dynoSession.pullState and safeDeepcopy(dynoSession.pullState.liveSample) or nil,
    pullQuality = dynoSession.pullState and dynoSession.pullState.pullQuality or (result and result.pullQuality or nil),
    qualityFlags = dynoSession.pullState and safeDeepcopy(dynoSession.pullState.qualityFlags) or (result and safeDeepcopy(result.qualityFlags) or {}),
    acceptedSampleCount = dynoSession.pullState and dynoSession.pullState.acceptedSampleCount or (result and result.acceptedSampleCount or 0),
    rejectedSampleCount = dynoSession.pullState and dynoSession.pullState.rejectedSampleCount or (result and result.rejectedSampleCount or 0),
    savedPulls = getPullHistoryForVehicle(inventoryId),
    currentResultSaved = result and result.savedPullId ~= nil or false,
    error = dynoSession.error,
    statusText = dynoSession.statusText,
    result = result
  }
end

local function requestResultData()
  return safeDeepcopy(dynoSession.result)
end

local function saveCurrentPull()
  if not dynoSession.active or dynoSession.phase ~= "complete" or not dynoSession.result or not dynoSession.inventoryId then
    setDynoError("Complete a dyno pull before saving it.", dynoSession.phase)
    return false
  end

  if dynoSession.result.savedPullId then
    return true
  end

  ensurePullHistoryLoaded()
  local inventoryKey = tostring(dynoSession.inventoryId)
  local vehicleData = career_modules_inventory.getVehicles()[dynoSession.inventoryId]
  local entry = safeDeepcopy(dynoSession.result)
  entry.liveSample = nil
  entry.id = nextPullHistoryId
  entry.savedAt = os.time()
  entry.inventoryId = inventoryKey
  entry.vehicleName = buildVehicleName(vehicleData)
  entry.hubId = dynoSession.selectedHubId

  nextPullHistoryId = nextPullHistoryId + 1
  pullHistoryByVehicle[inventoryKey] = pullHistoryByVehicle[inventoryKey] or {}
  table.insert(pullHistoryByVehicle[inventoryKey], 1, entry)
  while #pullHistoryByVehicle[inventoryKey] > HISTORY_LIMIT_PER_VEHICLE do
    table.remove(pullHistoryByVehicle[inventoryKey])
  end

  if not savePullHistory() then
    table.remove(pullHistoryByVehicle[inventoryKey], 1)
    nextPullHistoryId = math.max(1, nextPullHistoryId - 1)
    setDynoError("The dyno pull could not be saved.", "complete")
    return false
  end

  dynoSession.result.savedPullId = entry.id
  dynoSession.statusText = "Dyno pull saved to this car's history."
  dynoSession.error = nil
  return true
end

local function deleteSavedPull(pullId)
  ensurePullHistoryLoaded()
  pullId = tonumber(pullId)
  if not pullId then
    setDynoError("The saved dyno pull could not be identified.", dynoSession.phase)
    return false
  end

  local inventoryId = dynoSession.inventoryId
  if not inventoryId then
    local context, contextError = getCurrentVehicleContext()
    if not context then
      setDynoError(contextError or "The current car could not be identified.", dynoSession.phase)
      return false
    end
    inventoryId = context.inventoryId
  end

  local inventoryKey = tostring(inventoryId)
  local entries = pullHistoryByVehicle[inventoryKey]
  if type(entries) ~= "table" then
    setDynoError("That saved dyno pull no longer exists for this car.", dynoSession.phase)
    return false
  end

  local removedEntry = nil
  local removedIndex = nil
  for index, entry in ipairs(entries) do
    if tonumber(entry.id) == pullId then
      removedEntry = table.remove(entries, index)
      removedIndex = index
      break
    end
  end

  if not removedEntry then
    setDynoError("That saved dyno pull no longer exists for this car.", dynoSession.phase)
    return false
  end

  if #entries == 0 then
    pullHistoryByVehicle[inventoryKey] = nil
  end

  if not savePullHistory() then
    pullHistoryByVehicle[inventoryKey] = pullHistoryByVehicle[inventoryKey] or {}
    table.insert(pullHistoryByVehicle[inventoryKey], removedIndex, removedEntry)
    setDynoError("The saved dyno pull could not be deleted.", dynoSession.phase)
    return false
  end

  if dynoSession.result and tonumber(dynoSession.result.savedPullId) == pullId then
    dynoSession.result.savedPullId = nil
  end
  dynoSession.statusText = "Saved dyno pull deleted."
  dynoSession.error = nil
  return true
end

local function pushDynoHudState(force)
  if not dynoSession.active then
    return
  end

  if not force then
    local now = os.clock()
    if dynoSession.lastHudPushTime and now - dynoSession.lastHudPushTime < 0.08 then
      return
    end
    dynoSession.lastHudPushTime = now
  else
    dynoSession.lastHudPushTime = os.clock()
  end

  guihooks.trigger("DynoSessionHudState", requestSessionData())
end

local startPull
local retryPull

startPull = function()
  -- The legacy Angular HUD already routes its primary action through startPull.
  -- Reusing that stable action also lets a hot-loaded HUD retry without requiring
  -- a newly registered controller method.
  if dynoSession.active and dynoSession.phase == "complete" then
    return retryPull()
  end

  if not dynoSession.active or dynoSession.phase ~= "ready" then
    setDynoError("The dyno session is not ready for a pull yet.", dynoSession.phase)
    return false
  end

  if not currentPolicy().unlimitedPulls and (tonumber(dynoSession.pullsUsed) or 0) >= SESSION_PULL_LIMIT then
    setDynoError("All three pulls in this dyno session have been used.", dynoSession.phase)
    pushDynoHudState(true)
    return false
  end

  local sessionVeh = dynoSession.sessionVehicleId and getObjectByID(dynoSession.sessionVehicleId) or nil
  if not sessionVeh then
    setDynoError("The dyno vehicle is no longer available.", "offer")
    finishSessionRestore()
    return false
  end

  local pullId = string.format("%d_%d_%d", sessionVeh:getID(), os.time(), math.random(1000, 9999))
  dynoSession.pullsUsed = (tonumber(dynoSession.pullsUsed) or 0) + 1

  dynoSession.phase = "pulling"
  dynoSession.error = nil
  dynoSession.result = nil
  dynoSession.statusText = "Running dyno pull."
  dynoSession.pullState = {
    inProgress = true,
    pullId = pullId,
    pullStage = "armed",
    liveSample = nil,
    pullQuality = "warning",
    qualityFlags = {},
    acceptedSampleCount = 0,
    rejectedSampleCount = 0
  }

  setVehicleFreeze(sessionVeh, false)

  sessionVeh:queueLuaCommand(string.format([[
    extensions.load("careerDynoSession")
    if careerDynoSession and careerDynoSession.startPull then
      careerDynoSession.startPull(%q)
    end
  ]], pullId))

  showDynoHud()
  pushDynoHudState(true)

  return true
end

retryPull = function()
  if not dynoSession.active or dynoSession.phase ~= "complete" then
    setDynoError("A completed dyno pull is required before retrying.", dynoSession.phase)
    pushDynoHudState(true)
    return false
  end

  local sessionVeh = dynoSession.sessionVehicleId and getObjectByID(dynoSession.sessionVehicleId) or nil
  if not sessionVeh then
    setDynoError("The dyno vehicle is no longer available.", "offer")
    finishSessionRestore()
    return false
  end

  if not currentPolicy().unlimitedPulls and (tonumber(dynoSession.pullsUsed) or 0) >= SESSION_PULL_LIMIT then
    setDynoError("All three pulls in this dyno session have been used.", "complete")
    pushDynoHudState(true)
    return false
  end

  -- Moving through the dyno parking spot performs a full physics reset while
  -- preserving the already-installed hub parts and the active career session.
  local moved, moveError = moveVehicleToDyno(sessionVeh)
  if not moved then
    setDynoError(moveError or "The dyno could not reset the vehicle for another pull.", "complete")
    pushDynoHudState(true)
    return false
  end

  setVehicleFreeze(sessionVeh, true)
  setVehicleIgnition(sessionVeh, 0)

  dynoSession.pullState = nil
  dynoSession.result = nil
  dynoSession.phase = "resetting"
  dynoSession.error = nil
  local nextPull = (tonumber(dynoSession.pullsUsed) or 0) + 1
  dynoSession.statusText = currentPolicy().unlimitedPulls
    and string.format("Resetting the vehicle for pull %d. Unlimited pulls.", nextPull)
    or string.format("Resetting the vehicle for pull %d of %d.", nextPull, SESSION_PULL_LIMIT)
  dynoSession.retryArmDelay = 0.5
  showDynoHud()
  pushDynoHudState(true)
  return true
end

local function canOpenSessionService()
  return dynoSession.active and not dynoSession.serviceOpen and
           (dynoSession.phase == "ready" or dynoSession.phase == "complete")
end

local function openTuning()
  if not canOpenSessionService() then
    setDynoError("Tuning is only available while the dyno is idle.", dynoSession.phase)
    pushDynoHudState(true)
    return false
  end
  if not career_modules_tuning or not career_modules_tuning.start then
    setDynoError("The tuning system is unavailable.", dynoSession.phase)
    pushDynoHudState(true)
    return false
  end

  dynoSession.serviceOpen = "tuning"
  dynoSession.resumePhase = dynoSession.phase
  hideDynoHud()
  local opened = career_modules_tuning.start(dynoSession.inventoryId, nil, "dynoSession", {mode = "dyno"})
  if opened == false then
    dynoSession.serviceOpen = nil
    dynoSession.resumePhase = nil
    setDynoError("Engine tuning data is unavailable for this vehicle.", dynoSession.phase)
    showDynoHud()
    pushDynoHudState(true)
    return false
  end
  return true
end

local function openMaintenance()
  if not canOpenSessionService() then
    setDynoError("Maintenance is only available while the dyno is idle.", dynoSession.phase)
    pushDynoHudState(true)
    return false
  end
  if not career_modules_maintenanceComputer or not career_modules_maintenanceComputer.openMenuFromComputer then
    setDynoError("The maintenance system is unavailable.", dynoSession.phase)
    pushDynoHudState(true)
    return false
  end

  dynoSession.serviceOpen = "maintenance"
  dynoSession.resumePhase = dynoSession.phase
  hideDynoHud()
  local opened = career_modules_maintenanceComputer.openMenuFromComputer(
    dynoSession.inventoryId, nil, "dynoSession", {mode = "dyno"})
  if not opened then
    dynoSession.serviceOpen = nil
    dynoSession.resumePhase = nil
    setDynoError("Powertrain maintenance is unavailable while maintenance mode is disabled.", dynoSession.phase)
    showDynoHud()
    pushDynoHudState(true)
    return false
  end
  return true
end

local function resumeFromService()
  if not dynoSession.active or not dynoSession.inventoryId then
    return false
  end

  syncTunedVarsToOriginalConfig()
  local currentVehId = career_modules_inventory.getVehicleIdFromInventoryId(dynoSession.inventoryId)
  local currentVeh = currentVehId and getObjectByID(currentVehId) or nil
  dynoSession.serviceOpen = nil
  dynoSession.phase = dynoSession.resumePhase or dynoSession.phase
  dynoSession.resumePhase = nil

  if not currentVeh then
    setDynoError("The dyno vehicle could not be restored after service.", dynoSession.phase)
    showDynoHud()
    pushDynoHudState(true)
    return false
  end

  dynoSession.sessionVehicleId = currentVehId
  refreshVehiclePartVisibility(currentVehId)
  beginTireProtection(dynoSession.inventoryId)
  local moved, moveError = moveVehicleToDyno(currentVeh)
  if not moved then
    setDynoError(moveError or "The vehicle could not be returned to the dyno.", dynoSession.phase)
  else
    protectDynoSteering(currentVeh)
    setVehicleFreeze(currentVeh, true)
    setVehicleIgnition(currentVeh, 0)
    be:enterVehicle(0, currentVeh)
    refreshDynoCamera(currentVeh)
    dynoSession.error = nil
    dynoSession.statusText = dynoSession.phase == "complete" and
      "Service complete. Review the result or prepare the next pull." or
      "Service complete. The dyno is ready."
  end
  showDynoHud()
  pushDynoHudState(true)
  return moved == true
end

local function onPullSample(sample)
  if not dynoSession.active or not dynoSession.pullState or not sample then
    return
  end

  if sample.pullId ~= dynoSession.pullState.pullId then
    return
  end

  dynoSession.pullState.liveSample = {
    time = tonumber(sample.time) or 0,
    stage = sample.stage,
    rpm = tonumber(sample.rpm) or 0,
    gear = tonumber(sample.gear) or 0,
    throttle = tonumber(sample.throttle) or 0,
    brake = tonumber(sample.brake) or 0,
    wheelPower = tonumber(sample.wheelPower) or 0,
    wheelTorque = tonumber(sample.wheelTorque) or 0,
    rawWheelTorque = tonumber(sample.rawWheelTorque) or 0,
    flywheelPower = tonumber(sample.flywheelPower) or 0,
    flywheelTorque = tonumber(sample.flywheelTorque) or 0,
    rawWheelPowerSource = sample.rawWheelPowerSource,
    rawWheelTorqueSource = sample.rawWheelTorqueSource,
    rawFlywheelTorqueSource = sample.rawFlywheelTorqueSource,
    telemetrySource = sample.telemetrySource,
    rawGear = safeDeepcopy(sample.rawGear),
    valid = sample.valid and true or false,
    invalidReason = sample.invalidReason
  }

  dynoSession.pullState.pullStage = sample.stage or dynoSession.pullState.pullStage

  local expectedExclusion = sample.invalidReason == "waitingForStableGear"
    or sample.invalidReason == "waitingForThrottle" or sample.invalidReason == "finishing"
    or sample.invalidReason == "startBuffer" or sample.invalidReason == "pendingBuffer"
    or sample.invalidReason == "endBuffer" or sample.invalidReason == "limiterBuffer"
    or sample.invalidReason == "incompleteWindow"
  if sample.invalidReason and not expectedExclusion then
    dynoSession.pullState.qualityFlags[tostring(sample.invalidReason)] = true
  end

  if sample.acceptedSampleCount ~= nil then
    dynoSession.pullState.acceptedSampleCount = tonumber(sample.acceptedSampleCount) or 0
    dynoSession.pullState.rejectedSampleCount = tonumber(sample.rejectedSampleCount) or 0
  elseif sample.valid then
    dynoSession.pullState.acceptedSampleCount = dynoSession.pullState.acceptedSampleCount + 1
  else
    if sample.invalidReason and not expectedExclusion then
      dynoSession.pullState.rejectedSampleCount = dynoSession.pullState.rejectedSampleCount + 1
    end
  end

  if dynoSession.pullState.pullStage == "armed" then
    dynoSession.statusText = "Dyno armed. Hold the selected high gear steady."
  elseif dynoSession.pullState.pullStage == "ready" then
    dynoSession.statusText = "Ready. Apply at least 90% throttle to start recording."
  elseif dynoSession.pullState.pullStage == "recording" then
    dynoSession.statusText = "Recording. Hold gear and throttle; lift below 75% to finish."
  elseif dynoSession.pullState.pullStage == "finishing" then
    dynoSession.statusText = "Finishing dyno pull."
  end

  pushDynoHudState(false)
end

local function cleanupIfSessionVehicleMissing()
  if not dynoSession.active then
    return
  end

  if dynoSession.phase == "starting" or dynoSession.phase == "leaving" then
    return
  end

  if not dynoSession.inventoryId then
    abandonSessionWithoutRestore()
    return
  end

  local currentVehId = career_modules_inventory.getVehicleIdFromInventoryId(dynoSession.inventoryId)
  if not currentVehId then
    if dynoSession.serviceOpen then
      return
    end
    setDynoError("The dyno vehicle disappeared, so the session was cancelled.", dynoSession.phase)
    finishSessionRestore()
    return
  end

  dynoSession.sessionVehicleId = currentVehId
end

local function onVehicleConfigSnapshotReceived(callbackId, config, tireState)
  local callbackData = pendingConfigSnapshots[callbackId]
  if not callbackData then
    return
  end

  pendingConfigSnapshots[callbackId] = nil

  if callbackData.type == "startSession" then
    if not config then
      if callbackData.extraData and callbackData.extraData.prepaidFee then
        refundAmount(callbackData.extraData.prepaidFeePaid, "Dyno setup refund")
        callbackData.extraData.prepaidFeePaid = 0
        callbackData.extraData.prepaidFee = false
      end
      local repairPaid = callbackData.extraData and tonumber(callbackData.extraData.repairCostPaid) or 0
      local repairInventoryId = callbackData.extraData and callbackData.extraData.inventoryId
      if repairPaid > 0 and repairInventoryId then
        callbackData.extraData.repairCostPaid = 0
        local check = buildRepairQuote(repairInventoryId)
        if not check.ok or check.required then refundAmount(repairPaid, "Private dyno repair refund") end
      end
      log("W", "dynoSession", "Session start failed: no vehicle configuration snapshot")
      setDynoError("The dyno could not read the vehicle configuration.", "offer")
      return
    end
    startSessionFromSnapshot(config, callbackData.extraData, tireState)
  end
end

local function onPullFinished(result)
  if not dynoSession.active or not dynoSession.pullState or not result then
    return
  end

  if dynoSession.phase == "leaving" then
    return
  end

  if result.pullId ~= dynoSession.pullState.pullId then
    return
  end

  dynoSession.pullState.inProgress = false
  local flags = normalizeQualityFlags(result.qualityFlags)
  local measurementComplete = result.measurementComplete ~= false and result.valid ~= false
  local quality = getQualityFromFlags(flags, measurementComplete)
  if result.pullQuality == "warning" or result.pullQuality == "invalid" then quality = "warning" end
  dynoSession.result = {
    peakPower = tonumber(result.peakPower) or 0,
    peakTorque = tonumber(result.peakTorque) or 0,
    peakPowerRpm = tonumber(result.peakPowerRpm) or 0,
    peakTorqueRpm = tonumber(result.peakTorqueRpm) or 0,
    valid = true,
    measurementComplete = measurementComplete,
    pullQuality = quality,
    qualityFlags = flags,
    acceptedSampleCount = tonumber(result.acceptedSampleCount) or dynoSession.pullState.acceptedSampleCount or 0,
    rejectedSampleCount = tonumber(result.rejectedSampleCount) or dynoSession.pullState.rejectedSampleCount or 0,
    curve = safeDeepcopy(result.curve) or {},
    -- Preserve measured data in current results and saved history, including warnings.
    rawSamples = safeDeepcopy(result.rawSamples),
    averagedSamples = safeDeepcopy(result.averagedSamples),
    averageWindow = result.averageWindow,
    endReason = result.endReason,
    cutoffTime = result.cutoffTime,
    startBuffer = result.startBuffer,
    tailBuffer = result.tailBuffer,
    liveSample = safeDeepcopy(result.liveSample)
  }
  dynoSession.pullState = nil
  dynoSession.phase = "complete"
  dynoSession.statusText = quality == "clean" and (result.endReason == "revLimiter"
    and "Dyno pull complete. Release the throttle." or "Dyno pull complete.")
    or "Dyno pull complete with warnings."
  pushDynoHudState(true)
end

local function onBeamNGTrigger(data)
  if data.subjectID ~= be:getPlayerVehicleID(0) then
    return
  end

  if gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking() then
    return
  end

  if data.triggerName ~= TRIGGER_NAME then
    return
  end

  if repairRespawnPending then
    if data.event == "enter" then playerInsideTrigger = true end
    return
  end

  if data.event == "enter" then
    playerInsideTrigger = true
    if not dynoSession.active and dynoSession.phase ~= "starting" then
      dynoSession.phase = "inspecting"
      dynoSession.error = nil
      dynoSession.statusText = "Inspecting current vehicle damage."
      local context, contextError = getCurrentVehicleContext()
      if not context then
        setDynoError(contextError or "The vehicle could not be inspected.", "offer")
        openDynoUi()
      else
        local queued = refreshLiveVehicleConditions(context, function()
          if playerInsideTrigger and not dynoSession.active then
            dynoSession.phase = "offer"
            dynoSession.error = nil
            dynoSession.statusText = nil
            openDynoUi()
          end
        end)
        if not queued then
          setDynoError("The vehicle damage inspection is already in progress.", "inspecting")
          openDynoUi()
        end
      end
    end
  elseif data.event == "exit" then
    playerInsideTrigger = false
    conditionRefreshToken = conditionRefreshToken + 1
    conditionRefreshPending = false
    conditionRefreshCallbacks = {}
    if not dynoSession.active then
      closeDynoUi()
    end
  end
end

local function onVehicleSwitched(_, newId)
  if not dynoSession.active then
    return
  end

  if dynoSession.phase == "starting" or dynoSession.phase == "leaving" then
    return
  end

  if dynoSession.sessionVehicleId and newId ~= dynoSession.sessionVehicleId then
    local newInventoryId = career_modules_inventory.getInventoryIdFromVehicleId and
                             career_modules_inventory.getInventoryIdFromVehicleId(newId) or nil
    local mappedVehicleId = career_modules_inventory.getVehicleIdFromInventoryId and
                              career_modules_inventory.getVehicleIdFromInventoryId(dynoSession.inventoryId) or nil
    if tonumber(newInventoryId) == tonumber(dynoSession.inventoryId) or tonumber(mappedVehicleId) == tonumber(newId) or
        (dynoSession.serviceOpen and newInventoryId == nil) then
      dynoSession.sessionVehicleId = newId
      beginTireProtection(dynoSession.inventoryId)
      return
    end
    setDynoError("The dyno session ended because you changed vehicles.", dynoSession.phase)
    finishSessionRestore()
  end
end

local function onUpdate(dtReal)
  if #ownershipWaitCallbacks > 0 and not shopNeedsOwnershipResolution() then
    flushOwnershipWaitCallbacks()
  end

  if pendingSteeringSetup then
    steeringSetupTimer = steeringSetupTimer + (dtReal or 0)
    if steeringSetupTimer > 5 then
      pendingSteeringSetup = nil
      setDynoError("The dyno could not mute steering feedback. Session cancelled.", "offer")
      finishSessionRestore()
    end
  end
  updateDynoCameras()
  cleanupIfSessionVehicleMissing()

  if not dynoSession.active or dynoSession.phase ~= "resetting" then
    return
  end

  dynoSession.retryArmDelay = (dynoSession.retryArmDelay or 0) - math.max(tonumber(dtReal) or 0, 0)
  if dynoSession.retryArmDelay > 0 then
    return
  end

  dynoSession.retryArmDelay = nil
  dynoSession.phase = "ready"
  dynoSession.statusText = "Vehicle reset. Arming another dyno pull."
  startPull()
end

local function onCareerDeactivatedWhileLevelLoaded()
  if not dynoSession.active then
    resetDynoSessionState()
    return
  end

  finishSessionRestore()
end

local function onCareerActivated()
  loadPullHistory()
end

local function onExtensionLoaded()
  if career_career and career_career.isActive and career_career.isActive() then
    loadPullHistory()
  end
end

local function onSaveCurrentProfile(currentSavePath)
  if pullHistoryLoaded then
    savePullHistory(currentSavePath)
  end
end

local function onClientEndMission()
  if dynoSession.active then
    finishSessionRestore()
    return
  end

  resetDynoSessionState()
  playerInsideTrigger = false
end

M.onExtensionUnloaded = function()
  if dynoSession.active then
    finishSessionRestore()
  else
    releaseAllDynoSteering()
    resetDynoSessionState()
  end
end
M.onSteeringProtectionReady = onSteeringProtectionReady
M.onVehicleSpawned = onVehicleSpawned
M.onFFBConfigChanged = onFFBConfigChanged
M.onBeamNGTrigger = onBeamNGTrigger
M.onVehicleSwitched = onVehicleSwitched
M.onUpdate = onUpdate
M.onCareerActivated = onCareerActivated
M.onExtensionLoaded = onExtensionLoaded
M.onSaveCurrentProfile = onSaveCurrentProfile
M.onCareerDeactivatedWhileLevelLoaded = onCareerDeactivatedWhileLevelLoaded
M.onClientEndMission = onClientEndMission

M.requestSessionData = requestSessionData
M.requestResultData = requestResultData
M.saveCurrentPull = saveCurrentPull
M.deleteSavedPull = deleteSavedPull
M.getPullHistoryForVehicle = getPullHistoryForVehicle
M.startSession = startSession
M.repairAndStart = repairAndStart
M.leaveSession = leaveSession
M.startPull = startPull
M.retryPull = retryPull
M.openTuning = openTuning
M.openMaintenance = openMaintenance
M.resumeFromService = resumeFromService
M.isTransientConfigActive = isTransientConfigActive
M.getInventorySaveOverride = getInventorySaveOverride
M.applyInventorySpawnOverrides = applyInventorySpawnOverrides
M.commitTuningPurchase = commitTuningPurchase
M.buildInventorySaveOverride = buildInventorySaveOverride

M.onVehicleConfigSnapshotReceived = onVehicleConfigSnapshotReceived
M.onPullSample = onPullSample
M.onPullFinished = onPullFinished

-- Include asynchronous inspection/setup, not just an active pull.
M.isBusinessSessionBusy = function(businessId)
  local policy = currentPolicy()
  return policy.businessId == businessId and (dynoSession.active or conditionRefreshPending
    or #ownershipWaitCallbacks > 0
    or next(pendingConfigSnapshots) ~= nil or pendingSteeringSetup ~= nil
    or dynoSession.phase == "starting" or dynoSession.phase == "inspecting")
end

return M
