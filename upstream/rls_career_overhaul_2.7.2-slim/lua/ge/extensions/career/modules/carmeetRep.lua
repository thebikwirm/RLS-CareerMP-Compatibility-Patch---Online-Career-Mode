local M = {}

M.dependencies = {"career_career", "career_modules_inventory", "career_modules_valueCalculator", "career_saveSystem"}

local persist = require('ge/extensions/career/modules/carmeetsPersist')

local saveFile = "vehiclePopularityArchive.json"
local archive = {}

local MIN_REPUTATION = 0
local MAX_REPUTATION = 100
local SCENE_HISTORY_MAX = 40
local REP_VALUE_BONUS_MAX = 0.15
local ARRIVAL_CAR_BONUS = 1
local CRUISE_REPUTATION = 5
local CRUISE_CAR_BONUS = 1.5
local SELL_CAR_BONUS = 2
local BUY_CAR_BONUS = 0.5

local reputation = 0
local legacyCarRepMerged = false
local attendanceHistory = {}

local function isHardcoreMode()
  if career_modules_difficultyMode and career_modules_difficultyMode.isHardcoreMode then
    return career_modules_difficultyMode.isHardcoreMode() == true
  end
  return career_career and career_career.hardcoreMode == true
end

local function clampReputation(value)
  return math.min(MAX_REPUTATION, math.max(MIN_REPUTATION, tonumber(value) or 0))
end

local function getReputation()
  return reputation
end

local function getMaxReputation()
  return MAX_REPUTATION
end

local function addReputation(amount, reason)
  amount = tonumber(amount) or 0
  if amount == 0 then return reputation end
  local previous = reputation
  reputation = clampReputation(reputation + amount)
  print(string.format("Car meet reputation changed from %.1f to %.1f (%s)", previous, reputation, reason or "unknown"))
  persist.markDirty()
  return reputation
end

local function getPersistState()
  return {
    playerMeetReputation = reputation,
    legacyCarRepMerged = legacyCarRepMerged,
    attendanceHistory = attendanceHistory,
  }
end

local function applyPersistState(state)
  state = state or {}
  reputation = clampReputation(state.playerMeetReputation)
  legacyCarRepMerged = state.legacyCarRepMerged == true
  attendanceHistory = type(state.attendanceHistory) == "table" and state.attendanceHistory or {}
end

local function getCurrentInventoryId()
  if not career_modules_inventory then return nil end
  if career_modules_inventory.getCurrentVehicle then
    return career_modules_inventory.getCurrentVehicle()
  end
  if career_modules_inventory.getInventoryIdFromVehicleId then
    return career_modules_inventory.getInventoryIdFromVehicleId(be:getPlayerVehicleID(0))
  end
  return nil
end

local function getInventoryVehicle(inventoryId)
  if not inventoryId or not career_modules_inventory or not career_modules_inventory.getVehicles then return nil end
  return career_modules_inventory.getVehicles()[inventoryId]
end

local function getCurrentInventoryVehicle()
  local inventoryId = getCurrentInventoryId()
  if not inventoryId then return nil, nil end
  return inventoryId, getInventoryVehicle(inventoryId)
end

local function getInventoryVehicleValue(inventoryId)
  if not inventoryId or not career_modules_valueCalculator then return 0 end
  local value = career_modules_valueCalculator.getInventoryVehicleValue and career_modules_valueCalculator.getInventoryVehicleValue(inventoryId)
  if not value and career_modules_valueCalculator.getInventoryVehicleSellValue then
    value = career_modules_valueCalculator.getInventoryVehicleSellValue(inventoryId)
  end
  return tonumber(value) or 0
end

local function getSavePath(currentSavePath)
  if not currentSavePath and career_saveSystem and career_saveSystem.getCurrentProfile then
    local _, savePath = career_saveSystem.getCurrentProfile()
    currentSavePath = savePath
  end
  if not currentSavePath then return nil end
  return currentSavePath .. "/career/rls_career/" .. saveFile
end

local function loadArchive()
  archive = {}
  if not career_career or not career_career.isActive or not career_career.isActive() then return end
  local filePath = getSavePath()
  if not filePath then return end
  local data = jsonReadFile(filePath)
  if type(data) == "table" and type(data.previousCars) == "table" then
    archive = data.previousCars
  end
end

local function ensureTracker(vehicle)
  vehicle.rlsLocalPopularity = vehicle.rlsLocalPopularity or {
    totalPercent = 0,
    meetsAttended = 0,
    events = {}
  }
  vehicle.rlsLocalPopularity.events = vehicle.rlsLocalPopularity.events or {}
  vehicle.rlsLocalPopularity.totalPercent = tonumber(vehicle.rlsLocalPopularity.totalPercent) or 0
  vehicle.rlsLocalPopularity.meetsAttended = tonumber(vehicle.rlsLocalPopularity.meetsAttended) or 0
  return vehicle.rlsLocalPopularity
end

local function roundPercent(value)
  return math.floor((tonumber(value) or 0) * 100 + 0.5) / 100
end

local function resolveDisplayName(raw, fallback)
  if raw == nil then
    return fallback
  end
  if core_locales and core_locales.translateWithOrWithoutContext then
    local translated = core_locales.translateWithOrWithoutContext(raw)
    if type(translated) == "string" and translated ~= "" then
      return translated
    end
  end
  if type(raw) == "string" and raw ~= "" then
    return raw
  end
  return fallback
end

local function getVehicleDisplayName(vehicle, inventoryId)
  local fallback = "Vehicle " .. tostring(inventoryId)
  if type(vehicle) ~= "table" then
    return fallback
  end
  return resolveDisplayName(vehicle.niceName or vehicle.Name or vehicle.model, fallback)
end

local function getLegacyCarRep(vehicle)
  if type(vehicle) ~= "table" then return 0 end
  return tonumber(vehicle.meetReputation) or 0
end

local function mergeLegacyCarRep()
  if legacyCarRepMerged then return end
  if not career_modules_inventory or not career_modules_inventory.getVehicles then return end
  legacyCarRepMerged = true
  local total = 0
  for _, vehicle in pairs(career_modules_inventory.getVehicles() or {}) do
    total = total + math.max(0, getLegacyCarRep(vehicle))
  end
  if total > 0 then
    addReputation(total, "merged legacy car rep")
  else
    persist.markDirty()
  end
end

local function hasMeetHistory(vehicle)
  if type(vehicle) ~= "table" then return false end
  local tracker = vehicle.rlsLocalPopularity
  if type(tracker) == "table" and ((tonumber(tracker.meetsAttended) or 0) > 0 or (tonumber(tracker.totalPercent) or 0) > 0) then
    return true
  end
  local history = vehicle.rlsSceneHistory
  if type(history) == "table" and type(history.events) == "table" and #history.events > 0 then
    return true
  end
  return getLegacyCarRep(vehicle) > 0
end

local function getMeetValueBonus(inventoryId)
  if not hasMeetHistory(getInventoryVehicle(inventoryId)) then return 0 end
  return (reputation / MAX_REPUTATION) * REP_VALUE_BONUS_MAX
end

local function getMeetValueBonusPercent(inventoryId)
  return math.floor(getMeetValueBonus(inventoryId) * 1000 + 0.5) / 10
end

local function ensureSceneHistory(vehicle)
  vehicle.rlsSceneHistory = vehicle.rlsSceneHistory or { events = {} }
  vehicle.rlsSceneHistory.events = vehicle.rlsSceneHistory.events or {}
  return vehicle.rlsSceneHistory
end

local function migrateLegacyBuzzEvents(vehicle)
  local tracker = vehicle.rlsLocalPopularity
  local history = ensureSceneHistory(vehicle)
  if type(tracker) ~= "table" or type(tracker.events) ~= "table" then return end
  for _, legacy in ipairs(tracker.events) do
    if type(legacy) == "table" and legacy.amountPercent and not legacy._migrated then
      table.insert(history.events, 1, {
        kind = "buzz",
        time = legacy.time or os.time(),
        label = "Local buzz",
        buzzDelta = legacy.amountPercent,
        playerRep = legacy.amountPercent,
        location = legacy.zoneId,
        _migrated = true
      })
      legacy._migrated = true
    end
  end
end

local function appendSceneEvent(inventoryId, entry)
  if not inventoryId or type(entry) ~= "table" then return end
  local vehicle = getInventoryVehicle(inventoryId)
  if not vehicle then return end
  migrateLegacyBuzzEvents(vehicle)
  local history = ensureSceneHistory(vehicle)
  table.insert(history.events, 1, {
    kind = entry.kind or "event",
    time = entry.time or os.time(),
    label = entry.label or entry.kind or "Scene event",
    playerRep = entry.playerRep,
    buzzDelta = entry.buzzDelta,
    location = entry.location,
    meetType = entry.meetType,
    price = entry.price
  })
  while #history.events > SCENE_HISTORY_MAX do
    table.remove(history.events)
  end
  if career_modules_inventory.setVehicleDirty then
    career_modules_inventory.setVehicleDirty(inventoryId)
  end
end

local function awardBuzzForCurrentVehicle(zone)
  local inventoryId, vehicle = getCurrentInventoryVehicle()
  if not inventoryId or not vehicle then return nil end

  local minPercent = tonumber(zone and zone.localPopularityRewardMinPercent) or 0.4
  local maxPercent = tonumber(zone and zone.localPopularityRewardMaxPercent) or 1.0
  local capPercent = tonumber(zone and zone.localPopularityCapPercent) or 8
  if maxPercent < minPercent then maxPercent = minPercent end

  local tracker = ensureTracker(vehicle)
  local remaining = math.max(0, capPercent - tracker.totalPercent)
  if remaining <= 0 then
    return {
      inventoryId = inventoryId,
      amountPercent = 0,
      totalPercent = roundPercent(tracker.totalPercent),
      capped = true
    }
  end

  local rolled = minPercent + (math.random() * (maxPercent - minPercent))
  local amount = roundPercent(math.min(rolled, remaining))
  if amount <= 0 then return nil end

  tracker.totalPercent = roundPercent(tracker.totalPercent + amount)
  tracker.meetsAttended = tracker.meetsAttended + 1
  table.insert(tracker.events, {
    time = os.time(),
    zoneId = zone and zone.id or "unknown",
    zoneType = zone and zone.type or "meet",
    amountPercent = amount,
    totalPercent = tracker.totalPercent
  })

  while #tracker.events > 20 do
    table.remove(tracker.events, 1)
  end

  appendSceneEvent(inventoryId, {
    kind = "buzz",
    label = "Local buzz",
    buzzDelta = amount,
    playerRep = amount,
    location = zone and zone.id or nil
  })
  if career_modules_inventory.setVehicleDirty then
    career_modules_inventory.setVehicleDirty(inventoryId)
  end
  if career_saveSystem and career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent({inventoryId})
  end

  return {
    inventoryId = inventoryId,
    amountPercent = amount,
    totalPercent = tracker.totalPercent,
    capped = tracker.totalPercent >= capPercent
  }
end

local function sortedStableSerialize(value)
  if type(value) ~= "table" then
    return tostring(value)
  end
  local keys = {}
  for key in pairs(value) do
    table.insert(keys, key)
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, key in ipairs(keys) do
    table.insert(parts, tostring(key) .. "=" .. sortedStableSerialize(value[key]))
  end
  return "{" .. table.concat(parts, "|") .. "}"
end

local function getBuildSignature(inventoryId)
  local vehicle = getInventoryVehicle(inventoryId)
  if not vehicle then return nil end
  local signatureData = {
    model = vehicle.model,
    config = {}
  }
  if vehicle.config then
    signatureData.config.partConfigFilename = vehicle.config.partConfigFilename
    signatureData.config.parts = vehicle.config.parts or vehicle.config.partsTree
    signatureData.config.vars = vehicle.config.vars
    signatureData.config.paints = vehicle.config.paints or vehicle.config.paintsData
    signatureData.config.licenseName = vehicle.config.licenseName
  end
  return sortedStableSerialize(signatureData)
end

local function calculateAttendanceReputation(inventoryId)
  inventoryId = inventoryId or getCurrentInventoryId()
  if not inventoryId then
    return 0, "Attending without a vehicle gives no attendance rep."
  end

  local signature = getBuildSignature(inventoryId)
  if not signature then
    return 0, "Could not read current vehicle build data."
  end

  local historyKey = tostring(inventoryId)
  local previous = attendanceHistory[historyKey]
  if previous and previous.signature == signature then
    return 0, "This vehicle already earned meet rep with the same build."
  end

  local value = getInventoryVehicleValue(inventoryId)
  local valueBonus = 0
  if value > 30000 then
    valueBonus = math.min(5, math.max(0, inverseLerp(30000, 200000, value) * 5))
  end
  local changedBonus = previous and 2 or 0
  local rep = 1 + valueBonus + changedBonus
  if isHardcoreMode() then
    rep = rep / 2
  end
  rep = math.max(1, rep)

  attendanceHistory[historyKey] = {
    signature = signature,
    lastRewardedAt = os.time(),
    lastReward = rep,
    value = value
  }

  return rep, string.format("Attendance rep: +%.1f", rep)
end

local function awardMeetArrival(opts)
  opts = opts or {}
  local multiplier = opts.multiplier
  if multiplier == nil then multiplier = 1 end

  local inventoryId = getCurrentInventoryId()
  local attendanceRep, attendanceMessage = 0, nil
  if multiplier ~= 0 then
    attendanceRep, attendanceMessage = calculateAttendanceReputation(inventoryId)
    attendanceRep = attendanceRep * multiplier
  end

  local buzz = awardBuzzForCurrentVehicle(opts.buzzZone)
  local total = buzz and tonumber(buzz.amountPercent) or 0
  if attendanceRep > 0 then
    total = total + attendanceRep + (inventoryId and ARRIVAL_CAR_BONUS or 0)
  end
  if total > 0 then
    addReputation(total, "arrived at car meet")
  end
  if attendanceRep > 0 and inventoryId then
    appendSceneEvent(inventoryId, {
      kind = "meet_arrival",
      label = opts.meetTypeName or opts.meetTypeKey,
      location = opts.location,
      meetType = opts.meetTypeKey,
      playerRep = attendanceRep + ARRIVAL_CAR_BONUS
    })
  end

  return {
    reputation = attendanceRep,
    attendanceMessage = attendanceMessage,
    buzz = buzz
  }
end

local function awardCruiseComplete(inventoryId, meetTypeKey)
  local baseRep = CRUISE_REPUTATION
  if isHardcoreMode() then
    baseRep = baseRep / 2
  end
  local total = baseRep + (inventoryId and CRUISE_CAR_BONUS or 0)
  addReputation(total, "completed cruise")
  if inventoryId then
    appendSceneEvent(inventoryId, {
      kind = "cruise",
      label = "Street cruise completed",
      playerRep = total,
      meetType = meetTypeKey
    })
  end
  return baseRep
end

local function awardTransaction(kind, price, marketValue, inventoryId, meetTypeKey)
  price = tonumber(price) or 0
  marketValue = math.max(tonumber(marketValue) or 0, 1)
  local rep = 0
  if kind == "buy" then
    rep = math.min(5, math.max(0, inverseLerp(marketValue, marketValue * 1.3, price) * 5))
  elseif kind == "sell" then
    rep = math.min(5, math.max(0, inverseLerp(marketValue * 0.7, marketValue, price) * 5))
  end
  if rep <= 0 then return 0 end

  if inventoryId then
    rep = rep + (kind == "sell" and SELL_CAR_BONUS or BUY_CAR_BONUS)
  end
  addReputation(rep, "car meet " .. tostring(kind) .. " transaction")
  if inventoryId then
    appendSceneEvent(inventoryId, {
      kind = "transaction",
      label = kind == "sell" and "Sold at meet" or "Bought at meet",
      playerRep = rep,
      meetType = meetTypeKey,
      price = price
    })
  end
  return rep
end

local function buildVehicleEntry(inventoryId, vehicle, soldPrice)
  if not inventoryId or type(vehicle) ~= "table" then return nil end
  local tracker = vehicle.rlsLocalPopularity
  if type(tracker) ~= "table" or ((tonumber(tracker.totalPercent) or 0) <= 0 and (tonumber(tracker.meetsAttended) or 0) <= 0) then
    return nil
  end

  local value
  if career_modules_valueCalculator and career_modules_valueCalculator.getInventoryVehicleValue and career_modules_inventory and career_modules_inventory.getVehicle then
    value = career_modules_valueCalculator.getInventoryVehicleValue(inventoryId, true)
  end

  return {
    inventoryId = inventoryId,
    name = getVehicleDisplayName(vehicle, inventoryId),
    year = vehicle.year,
    mileage = vehicle.mileage or vehicle.Mileage,
    thumbnail = career_modules_inventory and career_modules_inventory.getVehicleThumbnail and career_modules_inventory.getVehicleThumbnail(inventoryId) or nil,
    totalPercent = roundPercent(tracker.totalPercent),
    meetsAttended = tonumber(tracker.meetsAttended) or 0,
    estimatedValue = value and math.floor(value + 0.5) or nil,
    soldPrice = soldPrice and math.floor((tonumber(soldPrice) or 0) + 0.5) or nil,
    lastSeenAt = os.time(),
    events = deepcopy(tracker.events or {})
  }
end

local function formatFreValue(raceName, value)
  value = tonumber(value)
  if not value then return "-" end
  local name = tostring(raceName or ""):lower()
  if string.find(name, "drift", 1, true) then
    return string.format("%.0f pts", value)
  end
  local minutes = math.floor(value / 60)
  local seconds = value - (minutes * 60)
  return string.format("%d:%05.2f", minutes, seconds)
end

local function buildFreeroamTimesList(freTimes)
  local result = {}
  if type(freTimes) ~= "table" then return result end
  for raceName, value in pairs(freTimes) do
    table.insert(result, {
      raceName = raceName,
      value = value,
      displayValue = formatFreValue(raceName, value)
    })
  end
  table.sort(result, function(a, b)
    return tostring(a.raceName or "") < tostring(b.raceName or "")
  end)
  return result
end

local function getSceneEventsFromSource(vehicle, archivedEntry)
  if archivedEntry and type(archivedEntry.sceneEvents) == "table" then
    return deepcopy(archivedEntry.sceneEvents)
  end
  if type(vehicle) ~= "table" then return {} end
  migrateLegacyBuzzEvents(vehicle)
  local history = vehicle.rlsSceneHistory
  if type(history) == "table" and type(history.events) == "table" then
    return deepcopy(history.events)
  end
  return {}
end

local function buildArchiveEntry(inventoryId, vehicle, soldPrice)
  if not inventoryId or type(vehicle) ~= "table" then return nil end
  migrateLegacyBuzzEvents(vehicle)
  local tracker = vehicle.rlsLocalPopularity
  local totalPercent = type(tracker) == "table" and roundPercent(tracker.totalPercent) or 0
  local meetsAttended = type(tracker) == "table" and (tonumber(tracker.meetsAttended) or 0) or 0
  local sceneEvents = getSceneEventsFromSource(vehicle)
  if not hasMeetHistory(vehicle) and #sceneEvents == 0 then
    return nil
  end

  return {
    inventoryId = inventoryId,
    name = getVehicleDisplayName(vehicle, inventoryId),
    year = vehicle.year,
    mileage = vehicle.mileage or vehicle.Mileage,
    thumbnail = career_modules_inventory and career_modules_inventory.getVehicleThumbnail and career_modules_inventory.getVehicleThumbnail(inventoryId) or nil,
    totalPercent = totalPercent,
    meetsAttended = meetsAttended,
    soldPrice = soldPrice and math.floor((tonumber(soldPrice) or 0) + 0.5) or nil,
    lastSeenAt = os.time(),
    sold = true,
    sceneEvents = sceneEvents,
    FRETimes = deepcopy(vehicle.FRETimes or {}),
    FRECompletions = deepcopy(vehicle.FRECompletions or {})
  }
end

local function archiveVehicle(inventoryId, soldPrice)
  local entry = buildArchiveEntry(inventoryId, getInventoryVehicle(inventoryId), soldPrice)
  if not entry then return false end
  table.insert(archive, 1, entry)
  while #archive > 40 do
    table.remove(archive)
  end
  return true
end

local function archivedEntryHasMeetHistory(entry)
  return (tonumber(entry.meetsAttended) or 0) > 0
    or (tonumber(entry.totalPercent) or 0) > 0
    or (type(entry.sceneEvents) == "table" and #entry.sceneEvents > 0)
end

local function buildHistoryListEntry(inventoryId, vehicle, archivedEntry, archiveIndex)
  if archivedEntry then
    if not archivedEntryHasMeetHistory(archivedEntry) then return nil end
    return {
      inventoryId = archivedEntry.inventoryId or inventoryId,
      archiveIndex = archiveIndex,
      sold = true,
      name = resolveDisplayName(archivedEntry.name, "Vehicle " .. tostring(archivedEntry.inventoryId or inventoryId or "")),
      thumbnail = archivedEntry.thumbnail,
      totalPercent = roundPercent(archivedEntry.totalPercent or 0),
      meetsAttended = tonumber(archivedEntry.meetsAttended) or 0,
      soldPrice = archivedEntry.soldPrice,
      lastSeenAt = archivedEntry.lastSeenAt
    }
  end
  if not inventoryId or not hasMeetHistory(vehicle) then return nil end
  local tracker = vehicle.rlsLocalPopularity
  return {
    inventoryId = inventoryId,
    archiveIndex = nil,
    sold = false,
    name = getVehicleDisplayName(vehicle, inventoryId),
    thumbnail = career_modules_inventory and career_modules_inventory.getVehicleThumbnail and career_modules_inventory.getVehicleThumbnail(inventoryId) or nil,
    valueBonusPercent = getMeetValueBonusPercent(inventoryId),
    totalPercent = type(tracker) == "table" and roundPercent(tracker.totalPercent) or 0,
    meetsAttended = type(tracker) == "table" and (tonumber(tracker.meetsAttended) or 0) or 0,
    soldPrice = nil,
    lastSeenAt = nil
  }
end

local function getHistoryList()
  local result = {}
  if career_modules_inventory and career_modules_inventory.getVehicles then
    for inventoryId, vehicle in pairs(career_modules_inventory.getVehicles() or {}) do
      local entry = buildHistoryListEntry(inventoryId, vehicle)
      if entry then
        table.insert(result, entry)
      end
    end
  end
  for index, archivedEntry in ipairs(archive or {}) do
    local entry = buildHistoryListEntry(archivedEntry.inventoryId, nil, archivedEntry, index)
    if entry then
      table.insert(result, entry)
    end
  end
  table.sort(result, function(a, b)
    if (a.sold and not b.sold) then return false end
    if (not a.sold and b.sold) then return true end
    if (a.meetsAttended or 0) == (b.meetsAttended or 0) then
      return tostring(a.name or "") < tostring(b.name or "")
    end
    return (a.meetsAttended or 0) > (b.meetsAttended or 0)
  end)
  return result
end

local function getVehicleHistoryDetail(inventoryId, archiveIndex)
  local archivedEntry = nil
  if archiveIndex and archive[archiveIndex] then
    archivedEntry = archive[archiveIndex]
    inventoryId = archivedEntry.inventoryId or inventoryId
  end

  local vehicle = not archivedEntry and getInventoryVehicle(inventoryId) or nil
  if not vehicle and not archivedEntry then return nil end

  local name = archivedEntry and resolveDisplayName(archivedEntry.name, "Vehicle " .. tostring(inventoryId))
      or getVehicleDisplayName(vehicle, inventoryId)
  local tracker = vehicle and vehicle.rlsLocalPopularity
  local totalPercent = archivedEntry and roundPercent(archivedEntry.totalPercent or 0)
      or (type(tracker) == "table" and roundPercent(tracker.totalPercent) or 0)
  local meetsAttended = archivedEntry and (tonumber(archivedEntry.meetsAttended) or 0)
      or (type(tracker) == "table" and (tonumber(tracker.meetsAttended) or 0) or 0)

  local value
  if not archivedEntry and career_modules_valueCalculator and career_modules_valueCalculator.getInventoryVehicleValue then
    value = career_modules_valueCalculator.getInventoryVehicleValue(inventoryId, true)
  end

  local freTimes = archivedEntry and archivedEntry.FRETimes or (vehicle and vehicle.FRETimes)
  local sceneEvents = getSceneEventsFromSource(vehicle, archivedEntry)

  return {
    inventoryId = inventoryId,
    archiveIndex = archiveIndex,
    sold = archivedEntry ~= nil,
    name = name,
    thumbnail = archivedEntry and archivedEntry.thumbnail
        or (career_modules_inventory and career_modules_inventory.getVehicleThumbnail and career_modules_inventory.getVehicleThumbnail(inventoryId)),
    valueBonusPercent = archivedEntry and 0 or getMeetValueBonusPercent(inventoryId),
    totalPercent = totalPercent,
    meetsAttended = meetsAttended,
    estimatedValue = value and math.floor(value + 0.5) or nil,
    soldPrice = archivedEntry and archivedEntry.soldPrice or nil,
    sceneEvents = sceneEvents,
    freeroamTimes = buildFreeroamTimesList(freTimes)
  }
end

local function requestVehicleHistory(inventoryId, archiveIndex)
  local detail = getVehicleHistoryDetail(inventoryId, archiveIndex)
  if guihooks and guihooks.trigger then
    guihooks.trigger("onVehicleSceneHistory", detail or {})
  end
  return detail
end

local function getOwnedPopularityVehicles()
  local result = {}
  if not career_modules_inventory or not career_modules_inventory.getVehicles then return result end
  for inventoryId, vehicle in pairs(career_modules_inventory.getVehicles() or {}) do
    local entry = buildVehicleEntry(inventoryId, vehicle)
    if entry then
      table.insert(result, entry)
    end
  end
  table.sort(result, function(a, b)
    if (a.totalPercent or 0) == (b.totalPercent or 0) then
      return (a.meetsAttended or 0) > (b.meetsAttended or 0)
    end
    return (a.totalPercent or 0) > (b.totalPercent or 0)
  end)
  return result
end

local function getPhoneSocialData()
  return {
    careerActive = career_career and career_career.isActive and career_career.isActive() or false,
    vehicles = getOwnedPopularityVehicles(),
    historyVehicles = getHistoryList(),
    previousCars = deepcopy(archive)
  }
end

local function requestPhoneSocialData()
  local data = getPhoneSocialData()
  if guihooks and guihooks.trigger then
    guihooks.trigger("onCarMeetPopularityData", data)
  end
  return data
end

local function onBeforeVehicleSell(data)
  if type(data) == "table" then
    archiveVehicle(data.inventoryId, data.price)
  end
end

local function onSaveCurrentProfile(currentSavePath)
  local dirPath = currentSavePath .. "/career/rls_career"
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
  career_saveSystem.jsonWriteFileSafe(dirPath .. "/" .. saveFile, {
    previousCars = archive
  }, true)
end

local function onCareerActive(active)
  if active then
    loadArchive()
  else
    archive = {}
  end
end

local function onExtensionLoaded()
  loadArchive()
end

M.getReputation = getReputation
M.getMaxReputation = getMaxReputation
M.addReputation = addReputation
M.getPersistState = getPersistState
M.applyPersistState = applyPersistState
M.mergeLegacyCarRep = mergeLegacyCarRep
M.awardMeetArrival = awardMeetArrival
M.awardCruiseComplete = awardCruiseComplete
M.awardTransaction = awardTransaction
M.getMeetValueBonus = getMeetValueBonus
M.requestPhoneSocialData = requestPhoneSocialData
M.requestVehicleHistory = requestVehicleHistory
M.onBeforeVehicleSell = onBeforeVehicleSell
M.onSaveCurrentProfile = onSaveCurrentProfile
M.onCareerActive = onCareerActive
M.onExtensionLoaded = onExtensionLoaded

return M
