local M = {}

M.dependencies = {
  "career_career",
  "career_saveSystem"
}

local LOG_TAG = "cleanupClub"
local SITES_FILE = "cleanup.sites.json"
local REWARDS_FILE = "/gameplay/cleanupClub/rewards.json"
local SAVE_DIR = "/career/rls_career"
local SAVE_FILE = SAVE_DIR .. "/cleanupClub.json"
local MAX_ACTIVE_PER_MAP = 10
local SPAWN_INTERVAL_SECONDS = 30 * 60
local DEBRIS_SHAPE = "/art/shapes/garage_and_dealership/Clutter/big_pile.DAE"
local VEHICLE_CONTAINER_SHAPE = "/levels/west_coast_usa/art/shapes/objects/s_containers_20_beamng.dae"
local REWARD_VEHICLE_SELLER_IDS = {
  "private",
  "scrappers",
  "nebenan",
  "vogelsangGroen",
  "vogelsangbayIbishu"
}

local DEFAULT_REWARD_CONFIG = {
  fallbackMoney = {min = 500, max = 1000},
  rewards = {
    {id = "owned_part_small", type = "ownedVehiclePart", weight = 5, value = {min = 100, max = 2000}},
    {id = "owned_part_large", type = "ownedVehiclePart", weight = 4, value = {min = 3000, max = 10000}},
    {id = "money_small", type = "money", weight = 3, money = {min = 1000, max = 3000}},
    {id = "money_medium", type = "money", weight = 2, money = {min = 5000, max = 10000}},
    {id = "vehicle_junker", type = "vehicle", weight = 2, value = {min = 0, max = 10000}},
    {id = "vehicle_project", type = "vehicle", weight = 1, value = {min = 10000, max = 200000}}
  }
}

local state = {version = 1, maps = {}, totalCleared = 0}
local rewardConfig
local currentLevelId
local currentSitesPath
local sitesSupported = false
local spotsById = {}
local spotOrder = {}
local debrisObjects = {}
local initialized = false
local stateLoaded = false
local stagedSpotId
local dismissedSpotId

local function tableCount(value)
  local count = 0
  for _ in pairs(value or {}) do count = count + 1 end
  return count
end

local function isCareerActive()
  return career_career and career_career.isActive and career_career.isActive() == true
end

local function notify(message, category)
  if ui_message then ui_message(message, 5, category or "info", category or "info") end
end

local function clampRange(range, fallbackMin, fallbackMax)
  if type(range) ~= "table" then return {min = fallbackMin, max = fallbackMax} end
  local minValue = tonumber(range.min) or fallbackMin
  local maxValue = tonumber(range.max) or fallbackMax or minValue
  if maxValue < minValue then minValue, maxValue = maxValue, minValue end
  return {min = minValue, max = maxValue}
end

local function randomWholeRange(range)
  range = clampRange(range, 0, 0)
  local minValue = math.floor(range.min or 0)
  local maxValue = math.floor(range.max or minValue)
  if maxValue <= minValue then return minValue end
  return math.random(minValue, maxValue)
end

local function valueInRange(value, range)
  value = tonumber(value)
  if not value or type(range) ~= "table" then return false end
  return value >= (tonumber(range.min) or 0) and value <= (tonumber(range.max) or math.huge)
end

local function loadRewards()
  if rewardConfig then return rewardConfig end
  local loaded = jsonReadFile(REWARDS_FILE)
  if type(loaded) ~= "table" or type(loaded.rewards) ~= "table" or #loaded.rewards == 0 then
    rewardConfig = deepcopy(DEFAULT_REWARD_CONFIG)
    return rewardConfig
  end

  local rewards = {}
  for _, raw in ipairs(loaded.rewards) do
    if type(raw) == "table" and raw.type and (tonumber(raw.weight) or 0) > 0 then
      local reward = deepcopy(raw)
      reward.weight = tonumber(raw.weight) or 0
      if reward.type == "money" then
        reward.money = clampRange(reward.money, tonumber(raw.amount) or 500, tonumber(raw.amount) or 500)
      elseif reward.type == "ownedVehiclePart" or reward.type == "vehicle" then
        reward.value = clampRange(reward.value, 0, math.huge)
      end
      rewards[#rewards + 1] = reward
    end
  end

  if #rewards == 0 then
    rewardConfig = deepcopy(DEFAULT_REWARD_CONFIG)
  else
    rewardConfig = {
      fallbackMoney = clampRange(loaded.fallbackMoney, 500, 1000),
      rewards = rewards
    }
  end
  return rewardConfig
end

local function selectReward(requestedRewardId)
  local config = loadRewards()
  local pool = config.rewards or DEFAULT_REWARD_CONFIG.rewards
  if requestedRewardId then
    for _, reward in ipairs(pool) do
      if reward.id == requestedRewardId then return deepcopy(reward) end
    end
    return nil
  end

  local totalWeight = 0
  for _, reward in ipairs(pool) do totalWeight = totalWeight + math.max(tonumber(reward.weight) or 0, 0) end
  if totalWeight <= 0 then return pool[1] and deepcopy(pool[1]) or nil end
  local pick = math.random() * totalWeight
  local running = 0
  for _, reward in ipairs(pool) do
    running = running + math.max(tonumber(reward.weight) or 0, 0)
    if pick <= running then return deepcopy(reward) end
  end
  return pool[#pool] and deepcopy(pool[#pool]) or nil
end

local function ensureState()
  if type(state) ~= "table" then state = {} end
  state.version = tonumber(state.version) or 1
  state.maps = type(state.maps) == "table" and state.maps or {}
  state.totalCleared = math.max(0, math.floor(tonumber(state.totalCleared) or 0))
  for mapId, mapState in pairs(state.maps) do
    if type(mapState) ~= "table" then
      state.maps[mapId] = {elapsedSeconds = 0, active = {}, clearedCount = 0}
    else
      mapState.elapsedSeconds = math.max(0, tonumber(mapState.elapsedSeconds) or 0)
      mapState.active = type(mapState.active) == "table" and mapState.active or {}
      mapState.clearedCount = math.max(0, math.floor(tonumber(mapState.clearedCount) or 0))
    end
  end
end

local function getMapState(levelId)
  if not levelId then return nil end
  ensureState()
  local mapState = state.maps[levelId]
  if type(mapState) ~= "table" then
    mapState = {elapsedSeconds = 0, active = {}, clearedCount = 0}
    state.maps[levelId] = mapState
  end
  mapState.elapsedSeconds = math.max(0, tonumber(mapState.elapsedSeconds) or 0)
  mapState.active = type(mapState.active) == "table" and mapState.active or {}
  mapState.clearedCount = math.max(0, math.floor(tonumber(mapState.clearedCount) or 0))
  return mapState
end

local function currentSaveRoot()
  if not career_saveSystem then return nil end
  if career_saveSystem.getCurrentProfile then
    local _, path = career_saveSystem.getCurrentProfile()
    if path then return path end
  end
  if career_saveSystem.getCurrentSaveSlot then
    local _, path = career_saveSystem.getCurrentSaveSlot()
    return path
  end
  return nil
end

local function ensureSaveDirectory(saveRoot)
  if not saveRoot or not FS then return end
  local path = saveRoot .. SAVE_DIR
  if not FS:directoryExists(path) then FS:directoryCreate(path, true) end
end

local function saveStateToRoot(saveRoot)
  if not stateLoaded or not saveRoot or not career_saveSystem or not career_saveSystem.jsonWriteFileSafe then return false end
  ensureState()
  ensureSaveDirectory(saveRoot)
  return career_saveSystem.jsonWriteFileSafe(saveRoot .. SAVE_FILE, deepcopy(state), true) == true
end

local function saveState()
  return saveStateToRoot(currentSaveRoot())
end

local function loadState()
  local saveRoot = currentSaveRoot()
  local loaded = saveRoot and jsonReadFile(saveRoot .. SAVE_FILE) or nil
  state = type(loaded) == "table" and loaded or {version = 1, maps = {}, totalCleared = 0}
  ensureState()
  stateLoaded = true
end

local function asVec3(value, fallback)
  if type(value) == "table" then
    return vec3(tonumber(value[1]) or 0, tonumber(value[2]) or 0, tonumber(value[3]) or 0)
  end
  return fallback or vec3()
end

local function getFirstTag(rawSpot)
  local tags = rawSpot and rawSpot.customFields and rawSpot.customFields.tags
  if type(tags) ~= "table" then return nil end
  local first = tags[1] or tags[0]
  if type(first) == "string" and first ~= "" then return first end
  for key, value in pairs(tags) do
    if type(value) == "string" and value ~= "" then return value end
    if type(key) == "string" and value == true then return key end
  end
  return nil
end

local NEARBY_FACILITY_TYPES = {"garage", "gasStation", "dealership", "deliveryProvider", "tuningShop", "businessGarage", "passiveBusiness", "engineShop"}

local function facilityCenter(facility)
  local center, count = vec3(0, 0, 0), 0
  for _, pair in ipairs(facility and facility.doors or {}) do
    local obj = type(pair) == "table" and pair[1] and scenetree.findObject(pair[1])
    if obj then
      center = center + obj:getPosition()
      count = count + 1
    end
  end
  if count == 0 then return nil end
  return center / count
end

-- Human-readable site name: the authored tag if there is one, otherwise the nearest facility.
local function spotDisplayName(spot)
  if not spot then return "Clean Up Club" end
  if spot.displayName then return spot.displayName end
  local name = spot.name
  if type(name) ~= "string" or name == "" or name == spot.id then
    name = "Parking area"
    if freeroam_facilities and freeroam_facilities.getFacilitiesByType and spot.pos then
      local bestName, bestDist = nil, 400
      for _, facType in ipairs(NEARBY_FACILITY_TYPES) do
        local ok, list = pcall(freeroam_facilities.getFacilitiesByType, facType, currentLevelId)
        for _, fac in ipairs(ok and type(list) == "table" and list or {}) do
          local center = facilityCenter(fac)
          local dist = center and center:distance(spot.pos)
          local facName = fac.name and _tr(fac.name)
          if dist and dist < bestDist and type(facName) == "string" and facName ~= "" then
            bestName, bestDist = facName, dist
          end
        end
      end
      if bestName then name = "Parking area near " .. bestName end
    end
  end
  spot.displayName = name
  return name
end

local function interactionRadius(scale)
  if not scale then return 12 end
  return math.max(scale:length() / 2 + 4, 12)
end

local function objectToken(value)
  local token = tostring(value or "spot"):gsub("[^%w_%-]", "_")
  return token ~= "" and token or "spot"
end

local function hidePrompt()
  stagedSpotId = nil
  if guihooks and guihooks.trigger then guihooks.trigger("CleanupClubPromptUi", {visible = false}) end
end

local function stripObjectCollision(object)
  if not object then return end
  if object.setHidden then pcall(function() object:setHidden(true) end) end
  if object.disableCollision then pcall(function() object:disableCollision() end) end
  if object.setField then
    pcall(function() object:setField("collisionType", 0, "None") end)
  end
end

local function deleteObjectForSpot(spot)
  if not spot then return end
  local object = debrisObjects[spot.id]
  if not object and scenetree and scenetree.findObject then object = scenetree.findObject(spot.objectName) end
  stripObjectCollision(object)
  if object and object.delete then object:delete() end
  debrisObjects[spot.id] = nil
end

local function spotObjectStillPresent(spot)
  if not spot then return false end
  if debrisObjects[spot.id] then return true end
  if not (scenetree and scenetree.findObject and spot.objectName) then return false end
  return scenetree.findObject(spot.objectName) ~= nil
end

local function waitForSpotCollisionClear(job, spot)
  local waited = 0
  while spotObjectStillPresent(spot) and waited < 1.0 do
    job.sleep(0.05)
    waited = waited + 0.05
  end
  -- castRayStatic can keep the deleted mesh for a tick after scenetree removal.
  job.sleep(0.2)
end

local function clearRuntimeObjects()
  for _, object in pairs(debrisObjects) do
    if object and object.delete then object:delete() end
  end
  debrisObjects = {}
  for _, spot in ipairs(spotOrder) do
    local object = scenetree and scenetree.findObject and scenetree.findObject(spot.objectName)
    if object and object.delete then object:delete() end
  end
end

local function rewardShape(reward)
  return reward and reward.type == "vehicle" and VEHICLE_CONTAINER_SHAPE or DEBRIS_SHAPE
end

local function ensureObjectForSpot(spot, reward)
  if not spot or not createObject then return nil end
  local shapeName = rewardShape(reward)
  local existing = debrisObjects[spot.id]
  if not existing and scenetree and scenetree.findObject then existing = scenetree.findObject(spot.objectName) end
  if existing and existing.shapeName ~= shapeName then
    existing:delete()
    existing = nil
  end
  if existing then
    if existing.setHidden then existing:setHidden(false) end
    debrisObjects[spot.id] = existing
    return existing
  end

  local object = createObject("TSStatic")
  if not object then return nil end
  object.shapeName = shapeName
  object:setPosRot(
    spot.pos.x, spot.pos.y, spot.pos.z,
    spot.rot[1] or 0, spot.rot[2] or 0, spot.rot[3] or 0, spot.rot[4] or 1
  )
  object.scale = vec3(1, 1, 1)
  object.useInstanceRenderData = true
  object:setField("canSave", 0, "0")
  object:setField("canSaveDynamicFields", 0, "1")
  object.canSave = false
  object:registerObject(spot.objectName)
  debrisObjects[spot.id] = object
  return object
end

local function reconcileCurrentMapState()
  if not currentLevelId or not sitesSupported then return false end
  local changed = false
  local mapState = getMapState(currentLevelId)
  for spotId, active in pairs(mapState.active) do
    if not spotsById[spotId] then
      mapState.active[spotId] = nil
      changed = true
    elseif type(active) ~= "table" then
      mapState.active[spotId] = {reward = selectReward()}
      changed = true
    elseif type(active.reward) ~= "table" then
      active.reward = selectReward()
      changed = true
    end
  end
  local cap = math.min(MAX_ACTIVE_PER_MAP, #spotOrder)
  if tableCount(mapState.active) >= cap and mapState.elapsedSeconds ~= 0 then
    mapState.elapsedSeconds = 0
    changed = true
  end
  return changed
end

local function rebuildCurrentObjects()
  if not currentLevelId or not sitesSupported then return end
  local mapState = getMapState(currentLevelId)
  for _, spot in ipairs(spotOrder) do
    local active = mapState.active[spot.id]
    if active then
      ensureObjectForSpot(spot, active.reward)
    else
      deleteObjectForSpot(spot)
    end
  end
end

local function loadCurrentSites(force)
  local levelId = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
  if not force and levelId == currentLevelId and currentSitesPath then return sitesSupported end

  clearRuntimeObjects()
  hidePrompt()
  dismissedSpotId = nil
  currentLevelId = levelId
  currentSitesPath = levelId and ("/levels/" .. levelId .. "/" .. SITES_FILE) or nil
  sitesSupported = false
  spotsById = {}
  spotOrder = {}
  if not currentSitesPath then return false end

  local raw = jsonReadFile(currentSitesPath)
  if type(raw) ~= "table" or type(raw.parkingSpots) ~= "table" then return false end
  local seen = {}
  for index, rawSpot in ipairs(raw.parkingSpots) do
    local id = type(rawSpot.name) == "string" and rawSpot.name:match("^%s*(.-)%s*$") or ""
    if id == "" then
      log("W", LOG_TAG, string.format("Ignoring cleanup spot %d without a name in %s", index, currentSitesPath))
    elseif seen[id] then
      log("W", LOG_TAG, string.format("Ignoring duplicate cleanup spot '%s' in %s", id, currentSitesPath))
    elseif type(rawSpot.pos) ~= "table" then
      log("W", LOG_TAG, string.format("Ignoring cleanup spot '%s' without a position in %s", id, currentSitesPath))
    else
      seen[id] = true
      local scale = asVec3(rawSpot.scl, vec3(2.5, 6, 3))
      local spot = {
        id = id,
        name = getFirstTag(rawSpot) or id,
        pos = asVec3(rawSpot.pos),
        rot = type(rawSpot.rot) == "table" and rawSpot.rot or {0, 0, 0, 1},
        scale = scale,
        radius = interactionRadius(scale),
        objectName = string.format("cleanupClub_%s_%03d_%s", objectToken(levelId), index, objectToken(id))
      }
      spotsById[id] = spot
      spotOrder[#spotOrder + 1] = spot
    end
  end

  sitesSupported = #spotOrder > 0
  if sitesSupported then
    if reconcileCurrentMapState() then saveState() end
    rebuildCurrentObjects()
  end
  return sitesSupported
end

local function inactiveSpots()
  local result = {}
  if not currentLevelId or not sitesSupported then return result end
  local mapState = getMapState(currentLevelId)
  for _, spot in ipairs(spotOrder) do
    if not mapState.active[spot.id] then result[#result + 1] = spot end
  end
  return result
end

local function generateCleanup(requestedSpot, requestedRewardId)
  if not loadCurrentSites(false) or not currentLevelId then return false, "This map has no cleanup sites." end
  local mapState = getMapState(currentLevelId)
  local cap = math.min(MAX_ACTIVE_PER_MAP, #spotOrder)
  if tableCount(mapState.active) >= cap then return false, "This map is at its cleanup cap." end

  local spot = requestedSpot
  if spot then
    if not spotsById[spot.id] then return false, "Cleanup spot is not on the current map." end
    if mapState.active[spot.id] then return false, "Cleanup spot is already active." end
  else
    local candidates = inactiveSpots()
    if #candidates == 0 then return false, "No inactive cleanup spots are available." end
    spot = candidates[math.random(1, #candidates)]
  end

  local reward = selectReward(requestedRewardId)
  if requestedRewardId and not reward then return false, "Unknown cleanup reward: " .. tostring(requestedRewardId) end
  reward = reward or selectReward()
  mapState.active[spot.id] = {reward = reward}
  mapState.elapsedSeconds = 0
  ensureObjectForSpot(spot, reward)
  saveState()
  return true, spot
end

local function grantMoneyReward(amount, spot)
  amount = math.max(0, math.floor(tonumber(amount) or 0))
  if amount <= 0 or not career_modules_playerAttributes then return false end
  career_modules_playerAttributes.addAttributes(
    {money = amount},
    {label = spotDisplayName(spot) .. " cleanup reward", tags = {"gameplay", "cleanupClub"}}
  )
  notify("You found $" .. tostring(amount) .. " in the debris.", "info")
  return true
end

local function grantFallbackMoney(spot)
  return grantMoneyReward(randomWholeRange(loadRewards().fallbackMoney), spot)
end

local function getOwnedPartRewardCandidates(range)
  local candidates = {}
  if not career_modules_partInventory or not career_modules_partInventory.getInventory then return candidates end
  if not career_modules_inventory or not career_modules_inventory.getVehicles then return candidates end
  local inventory = career_modules_partInventory.getInventory() or {}
  local vehicles = career_modules_inventory.getVehicles() or {}
  for _, part in pairs(inventory) do
    local vehicle = part and part.location and vehicles[part.location]
    if vehicle and vehicle.owned and tonumber(part.location) and tonumber(part.location) > 0 and valueInRange(part.value, range) then
      candidates[#candidates + 1] = part
    end
  end
  return candidates
end

local function getPartVehicleLabel(part)
  local modelKey = part and part.vehicleModel
  if modelKey and core_vehicles and core_vehicles.getModel then
    local modelData = core_vehicles.getModel(modelKey)
    local modelInfo = modelData and modelData.model
    if type(modelInfo) == "table" then
      local brand = modelInfo.Brand or modelInfo.brand
      local name = modelInfo.Name or modelInfo.name
      if brand and name then return tostring(brand) .. " " .. tostring(name) end
      if name then return tostring(name) end
    end
  end
  if career_modules_inventory and career_modules_inventory.getVehicles and part and part.location then
    local vehicle = (career_modules_inventory.getVehicles() or {})[part.location]
    if vehicle and vehicle.niceName then return tostring(vehicle.niceName) end
    if vehicle and vehicle.model then return tostring(vehicle.model) end
  end
  return tostring(modelKey or "vehicle")
end

local function grantOwnedVehiclePartReward(reward)
  if not career_modules_partInventory or not career_modules_partInventory.addPartToInventory then return false end
  local candidates = getOwnedPartRewardCandidates(reward.value)
  if #candidates == 0 then return false end
  local sourcePart = candidates[math.random(1, #candidates)]
  local vehicleLabel = getPartVehicleLabel(sourcePart)
  local part = deepcopy(sourcePart)
  part.location = 0
  part.partId = nil
  part.partShopId = nil
  part.finalValue = nil
  part.sourcePart = nil
  part.rewardSource = "cleanupClub"
  career_modules_partInventory.addPartToInventory(part)
  local partLabel = type(part.description) == "table" and part.description.description or part.name or "part"
  notify("You found a " .. tostring(partLabel) .. " for a " .. tostring(vehicleLabel) .. ".", "info")
  return true
end

local function getVehicleRewardCandidates(range)
  local candidates = {}
  if not career_modules_vehicleShopping then return candidates end
  if career_modules_vehicleShopping.getVehiclesInShop then
    for _, vehicleInfo in ipairs(career_modules_vehicleShopping.getVehiclesInShop() or {}) do
      if vehicleInfo and valueInRange(vehicleInfo.Value or vehicleInfo.value or vehicleInfo.marketValue, range) then
        candidates[#candidates + 1] = vehicleInfo
      end
    end
  end
  if #candidates > 0 or not career_modules_vehicleShopping.getRandomVehicleFromCache then return candidates end
  for _, sellerId in ipairs(REWARD_VEHICLE_SELLER_IDS) do
    for _, vehicleInfo in ipairs(career_modules_vehicleShopping.getRandomVehicleFromCache(sellerId, 30) or {}) do
      if vehicleInfo and valueInRange(vehicleInfo.Value or vehicleInfo.value or vehicleInfo.marketValue, range) then
        vehicleInfo = deepcopy(vehicleInfo)
        vehicleInfo.sellerId = vehicleInfo.sellerId or sellerId
        vehicleInfo.sellerName = vehicleInfo.sellerName or "Clean Up Club Recovery"
        vehicleInfo.Mileage = tonumber(vehicleInfo.Mileage) or 0
        vehicleInfo.year = tonumber(vehicleInfo.year) or 1985
        candidates[#candidates + 1] = vehicleInfo
        if #candidates >= 25 then return candidates end
      end
    end
  end
  return candidates
end

local function grantVehicleReward(reward, spot)
  if not career_modules_vehicleShopping or not career_modules_vehicleShopping.grantRewardVehicle then return false end
  local candidates = getVehicleRewardCandidates(reward.value)
  if #candidates == 0 and reward.value and (tonumber(reward.value.max) or 0) < 10000 then
    candidates = getVehicleRewardCandidates({min = tonumber(reward.value.min) or 0, max = 10000})
  end
  if #candidates == 0 then
    notify("Clean Up Club could not find a matching recovery vehicle, paying fallback cash.", "warning")
    return false
  end
  local vehicleInfo = deepcopy(candidates[math.random(1, #candidates)])
  local spawnTransform = spot and {
    pos = {spot.pos.x, spot.pos.y, spot.pos.z},
    rot = deepcopy(spot.rot)
  } or nil
  if career_modules_vehicleShopping.grantRewardVehicle(vehicleInfo, "Clean Up Club cleanup reward", {
    ignoreGarageLimit = true,
    randomPaint = true,
    spawnTransform = spawnTransform
  }) then
    notify("Clean Up Club recovered a vehicle: " .. tostring(vehicleInfo.niceName or vehicleInfo.Name or vehicleInfo.key or "vehicle") .. ".", "info")
    return true
  end
  notify("Clean Up Club vehicle recovery failed, paying fallback cash.", "warning")
  return false
end

local function grantReward(reward, spot)
  if not reward then return grantFallbackMoney(spot) end
  local granted = false
  if reward.type == "money" then
    granted = grantMoneyReward(reward.amount or randomWholeRange(reward.money), spot)
  elseif reward.type == "ownedVehiclePart" then
    granted = grantOwnedVehiclePartReward(reward)
  elseif reward.type == "vehicle" then
    if core_jobsystem and core_jobsystem.create then
      core_jobsystem.create(function(job)
        waitForSpotCollisionClear(job, spot)
        if not grantVehicleReward(reward, spot) then
          grantFallbackMoney(spot)
        end
        if career_saveSystem and career_saveSystem.saveCurrent then
          career_saveSystem.saveCurrent()
        end
      end)
      return true
    end
    granted = grantVehicleReward(reward, spot)
  end
  return granted or grantFallbackMoney(spot)
end

local function promptPayload(spot, reward)
  local isVehicle = reward and reward.type == "vehicle"
  return {
    visible = true,
    payload = {
      title = "Clean Up Club",
      spotId = spot.id,
      siteName = spotDisplayName(spot),
      kind = isVehicle and "vehicle" or "debris",
      actionLabel = isVehicle and "Open Container" or "Clear Debris"
    }
  }
end

local function getPlayerVehicleObject()
  if getPlayerVehicle then return getPlayerVehicle(0) end
  return be and be.getPlayerVehicle and be:getPlayerVehicle(0) or nil
end

local function updatePrompt()
  if not isCareerActive() or not sitesSupported or not currentLevelId then
    hidePrompt()
    return
  end
  local vehicle = getPlayerVehicleObject()
  if not vehicle then
    hidePrompt()
    return
  end
  local mapState = getMapState(currentLevelId)
  local playerPos = vehicle:getPosition()
  local nearest, nearestDistance
  for _, spot in ipairs(spotOrder) do
    if mapState.active[spot.id] then
      local distance = (spot.pos - playerPos):length()
      if distance <= spot.radius and (not nearestDistance or distance < nearestDistance) then
        nearest = spot
        nearestDistance = distance
      end
    end
  end

  if nearest then
    if dismissedSpotId == nearest.id then return end
    stagedSpotId = nearest.id
    if guihooks and guihooks.trigger then
      -- Match Road Authority: repeat the event while the player remains in
      -- range so a UI controller mounted after the first frame still sees it.
      guihooks.trigger("CleanupClubPromptUi", promptPayload(nearest, mapState.active[nearest.id].reward))
    end
  else
    dismissedSpotId = nil
    if stagedSpotId then hidePrompt() end
  end
end

local function updateGeneration(dtSim)
  if not sitesSupported or not currentLevelId then return end
  local mapState = getMapState(currentLevelId)
  local cap = math.min(MAX_ACTIVE_PER_MAP, #spotOrder)
  if cap <= 0 then return end
  if tableCount(mapState.active) >= cap then
    if mapState.elapsedSeconds ~= 0 then
      mapState.elapsedSeconds = 0
      saveState()
    end
    return
  end

  local elapsed = math.max(tonumber(dtSim) or 0, 0)
  if elapsed <= 0 then return end
  mapState.elapsedSeconds = math.min(SPAWN_INTERVAL_SECONDS, mapState.elapsedSeconds + elapsed)
  if mapState.elapsedSeconds >= SPAWN_INTERVAL_SECONDS then
    local generated = generateCleanup()
    if not generated then mapState.elapsedSeconds = 0 end
  end
end

function M.completeCleanup(spotId)
  if not isCareerActive() or not loadCurrentSites(false) then return false end
  local spot = spotsById[spotId]
  local mapState = currentLevelId and getMapState(currentLevelId)
  local active = spot and mapState and mapState.active[spotId]
  if not active then return false end

  mapState.active[spotId] = nil
  mapState.clearedCount = mapState.clearedCount + 1
  state.totalCleared = state.totalCleared + 1
  if stagedSpotId == spotId then hidePrompt() end
  deleteObjectForSpot(spot)
  saveState()
  grantReward(active.reward, spot)
  if career_saveSystem and career_saveSystem.saveCurrent then career_saveSystem.saveCurrent() end
  return true
end

function M.closePrompt()
  dismissedSpotId = stagedSpotId
  hidePrompt()
end

local function prepareDebugSession()
  if isCareerActive() or not stateLoaded then return end
  clearRuntimeObjects()
  hidePrompt()
  dismissedSpotId = nil
  state = {version = 1, maps = {}, totalCleared = 0}
  stateLoaded = false
  currentLevelId = nil
  currentSitesPath = nil
  sitesSupported = false
  spotsById = {}
  spotOrder = {}
end

function M.debugGenerateCleanup(spotKey, rewardId)
  if not isCareerActive() then
    local reason = "Clean Up Club debug spawning requires Career Mode."
    notify(reason, "warning")
    return false, reason
  end
  prepareDebugSession()
  if not loadCurrentSites(false) then return false, "This map has no cleanup sites." end
  local requestedSpot
  if spotKey then
    local wanted = string.lower(tostring(spotKey))
    for _, spot in ipairs(spotOrder) do
      if string.lower(spot.id) == wanted or string.lower(spot.name) == wanted then
        requestedSpot = spot
        break
      end
    end
    if not requestedSpot then return false, "Cleanup spot not found: " .. tostring(spotKey) end
  end
  local generated, result = generateCleanup(requestedSpot, rewardId)
  if not generated then return false, result end
  notify("Debug spawned cleanup at " .. tostring(result.name) .. ".", "info")
  return true, {id = result.id, name = result.name, reward = deepcopy(getMapState(currentLevelId).active[result.id].reward)}
end

function M.debugForceSpawn(count, rewardId)
  if type(count) == "string" and rewardId == nil then
    rewardId = count
    count = 1
  end
  count = math.min(MAX_ACTIVE_PER_MAP, math.max(1, math.floor(tonumber(count) or 1)))
  if not isCareerActive() then
    local reason = "Clean Up Club debug spawning requires Career Mode."
    notify(reason, "warning")
    return false, reason
  end
  prepareDebugSession()
  if not loadCurrentSites(false) then return false, "This map has no cleanup sites." end

  local spawned = {}
  local stoppedReason
  for _ = 1, count do
    local generated, result = generateCleanup(nil, rewardId)
    if not generated then
      stoppedReason = result
      break
    end
    spawned[#spawned + 1] = {
      id = result.id,
      name = result.name,
      reward = deepcopy(getMapState(currentLevelId).active[result.id].reward)
    }
  end

  if #spawned == 0 then return false, stoppedReason or "No cleanup was generated." end
  local names = {}
  for _, cleanup in ipairs(spawned) do names[#names + 1] = cleanup.name end
  notify("Debug spawned " .. tostring(#spawned) .. " cleanup" .. (#spawned == 1 and "" or "s") .. ": " .. table.concat(names, ", ") .. ".", "info")
  return true, {
    requested = count,
    spawnedCount = #spawned,
    spawned = spawned,
    stoppedReason = stoppedReason,
    state = M.getDebugState()
  }
end

function M.debugFocusCleanup(spotId)
  if not isCareerActive() then
    local reason = "Clean Up Club debug focus requires Career Mode."
    notify(reason, "warning")
    return false, reason
  end
  prepareDebugSession()
  if not loadCurrentSites(false) then return false, "This map has no cleanup sites." end
  local mapState = currentLevelId and getMapState(currentLevelId)
  local spot
  if spotId then
    spot = spotsById[tostring(spotId)]
    if not spot then return false, "Cleanup spot not found: " .. tostring(spotId) end
    if not mapState.active[spot.id] then return false, "Cleanup spot is not active: " .. tostring(spotId) end
  else
    for _, candidate in ipairs(spotOrder) do
      if mapState.active[candidate.id] then
        spot = candidate
        break
      end
    end
  end
  if not spot then return false, "There are no active cleanups to focus." end
  if not commands or not commands.setFreeCamera or not core_camera or not core_camera.setPosition
      or not core_camera.setRotation or not quatFromDir then
    return false, "Free camera controls are unavailable."
  end

  local cameraPos = vec3(spot.pos.x + 15, spot.pos.y + 15, spot.pos.z + 10)
  local lookDir = vec3(spot.pos.x - cameraPos.x, spot.pos.y - cameraPos.y, spot.pos.z + 1 - cameraPos.z)
  commands.setFreeCamera()
  core_camera.setPosition(0, cameraPos)
  core_camera.setRotation(0, quatFromDir(lookDir))
  if core_camera.resetCamera then core_camera.resetCamera(0) end
  notify("Debug camera focused on " .. tostring(spot.name) .. ".", "info")
  return true, {id = spot.id, name = spot.name, pos = {spot.pos.x, spot.pos.y, spot.pos.z}}
end

function M.debugAdvanceTimer(seconds)
  if not isCareerActive() then return false end
  if not loadCurrentSites(false) then return false end
  updateGeneration(math.max(tonumber(seconds) or 0, 0))
  return true, M.getDebugState()
end

function M.getDebugState()
  loadCurrentSites(false)
  local mapState = currentLevelId and getMapState(currentLevelId) or nil
  return {
    levelId = currentLevelId,
    sitesPath = currentSitesPath,
    supported = sitesSupported,
    siteCount = #spotOrder,
    maxActive = math.min(MAX_ACTIVE_PER_MAP, #spotOrder),
    activeCount = mapState and tableCount(mapState.active) or 0,
    elapsedSeconds = mapState and mapState.elapsedSeconds or 0,
    totalCleared = state.totalCleared,
    mapState = mapState and deepcopy(mapState) or nil
  }
end

function M.onGetRawPoiListForLevel()
  -- Discovery is intentionally visual-only. Do not publish map POIs or routes.
end

local function activate()
  loadState()
  loadRewards()
  loadCurrentSites(true)
  initialized = true
end

local function onExtensionLoaded()
  if isCareerActive() then activate() else initialized = true end
end

local function onCareerModulesActivated()
  activate()
end

local function onCareerActivated()
  activate()
end

local function onWorldReadyState(worldReadyState)
  if worldReadyState == 2 and isCareerActive() then loadCurrentSites(true) end
end

local function onClientStartMission()
  if isCareerActive() then loadCurrentSites(true) end
end

local function onClientEndMission()
  saveState()
  hidePrompt()
  dismissedSpotId = nil
  clearRuntimeObjects()
  currentLevelId = nil
  currentSitesPath = nil
  sitesSupported = false
  spotsById = {}
  spotOrder = {}
end

local function onUpdate(_, dtSim)
  if not initialized or not isCareerActive() then return end
  local levelId = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
  if levelId ~= currentLevelId then loadCurrentSites(true) end
  if not sitesSupported then return end
  updateGeneration(dtSim)
  updatePrompt()
end

local function onExtensionUnloaded()
  saveState()
  hidePrompt()
  clearRuntimeObjects()
  initialized = false
end

M.onExtensionLoaded = onExtensionLoaded
M.onCareerModulesActivated = onCareerModulesActivated
M.onCareerActivated = onCareerActivated
M.onWorldReadyState = onWorldReadyState
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission
M.onSaveCurrentProfile = saveStateToRoot
M.onSaveCurrentSaveSlot = saveState
M.onUpdate = onUpdate
M.onExtensionUnloaded = onExtensionUnloaded

return M
