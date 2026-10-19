-- Freeroam tractor-pulling event controller.
local M = {}

local LOG_TAG = "tractorPull"
local CONFIG_FILENAME = "pulling.config.json"
local METERS_TO_FEET = 3.280839895

local phase = "idle"
local levelId
local config
local sites
local stagingSpot
local spawnSpot
local fullDistance = 0
local stationaryTime = 0
local spawnWaitTime = 0
local elapsedTime = 0
local noProgressTime = 0
local progressCheckpointDistance = 0
local selectedSled
local selectedHitch
local sledVehicleId
local playerVehicleId
local sledStartPos
local lastSledFlatPos
local maxDistance = 0
local hudAccumulator = 0
local resultData

local function logMessage(level, message)
  if log then log(level, LOG_TAG, message) end
end

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

local function arrayToVec(value)
  if type(value) ~= "table" then return nil end
  local x, y, z = tonumber(value[1]), tonumber(value[2]), tonumber(value[3])
  if not x or not y or not z then return nil end
  return vec3(x, y, z)
end

local function arrayToQuat(value)
  if type(value) ~= "table" then return nil end
  local x, y, z, w = tonumber(value[1]), tonumber(value[2]), tonumber(value[3]), tonumber(value[4])
  if not x or not y or not z or not w then return nil end
  return quat(x, y, z, w)
end

local function findParkingSpot(name)
  for _, spot in ipairs(type(sites) == "table" and sites.parkingSpots or {}) do
    if spot.name == name then return spot end
  end
  return nil
end

local function sledById(id)
  for _, sled in ipairs(type(config) == "table" and config.sleds or {}) do
    if sled.id == id then return sled end
  end
  return nil
end

local function hitchById(id)
  for _, hitch in ipairs(type(config) == "table" and config.hitches or {}) do
    if hitch.id == id then return hitch end
  end
  return nil
end

local function loadLevelData()
  local current = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
  if current == levelId and config and sites then return true end

  levelId = current
  config, sites = nil, nil
  stagingSpot, spawnSpot = nil, nil
  fullDistance = 0
  if not levelId then return false end

  config = jsonReadFile("levels/" .. levelId .. "/" .. CONFIG_FILENAME)
  if type(config) ~= "table" then return false end
  sites = jsonReadFile("levels/" .. levelId .. "/" .. tostring(config.sitesFile or "pulling.sites.json"))
  if type(sites) ~= "table" then
    config = nil
    return false
  end

  stagingSpot = findParkingSpot(config.stagingSpot or "pullStaging")
  spawnSpot = findParkingSpot(config.spawnSpot or "sledSpawn")
  local spawnPos = spawnSpot and arrayToVec(spawnSpot.pos)
  if not stagingSpot or not spawnPos then
    logMessage("E", "Pulling sites file is missing pullStaging or sledSpawn")
    config, sites = nil, nil
    return false
  end

  fullDistance = tonumber(config.fullPullDistanceMeters) or 91.44
  if fullDistance <= 1 then
    logMessage("E", "Full-pull distance is invalid")
    config, sites = nil, nil
    return false
  end
  return true
end

local function triggerUi(visible, mode, payload)
  local isVisible = visible == true
  if guihooks and guihooks.trigger then
    guihooks.trigger("TractorPullUi", {
      visible = isVisible,
      mode = isVisible and mode or nil,
      payload = payload or {}
    })
  end
end

local function buildSledChoices()
  local choices = {}
  for _, sled in ipairs(config.sleds or {}) do
    choices[#choices + 1] = {
      id = sled.id,
      label = sled.label,
      baseReward = tonumber(sled.baseReward) or 0
    }
  end
  return choices
end

local function buildHitchChoices()
  local choices = {}
  for _, hitch in ipairs(config.hitches or {}) do
    choices[#choices + 1] = {
      id = hitch.id,
      label = hitch.label
    }
  end
  return choices
end

local function showSelector()
  if phase ~= "idle" then return end
  phase = "selecting"
  triggerUi(true, "select", {
    title = config.label or "Tractor Pull",
    trackDistanceFeet = fullDistance * METERS_TO_FEET,
    sleds = buildSledChoices()
  })
end

local function deleteSled()
  local object = sledVehicleId and be:getObjectByID(sledVehicleId) or nil
  if object and object.delete then object:delete() end
  sledVehicleId = nil
end

local function resetRuntime(deleteSpawnedSled)
  if deleteSpawnedSled then deleteSled() end
  sledVehicleId = nil
  phase = "idle"
  stationaryTime, spawnWaitTime, elapsedTime = 0, 0, 0
  noProgressTime, progressCheckpointDistance, maxDistance = 0, 0, 0
  hudAccumulator = 0
  selectedSled, selectedHitch, playerVehicleId, sledStartPos, lastSledFlatPos, resultData = nil, nil, nil, nil, nil, nil
  triggerUi(false)
end

local function isActiveAttempt()
  return phase == "spawning" or phase == "waiting" or phase == "pulling"
end

local function vehicleIdFrom(veh)
  if type(veh) == "number" then return veh end
  if veh and veh.getID then return veh:getID() end
  return nil
end

local finishPull
local abortAttempt

local function getInventoryId(vehicleId)
  if career_modules_business_businessInventory and
      career_modules_business_businessInventory.resolveFreeroamLeaderboardInventoryId then
    local resolved = career_modules_business_businessInventory.resolveFreeroamLeaderboardInventoryId(vehicleId)
    if resolved then return resolved end
  end
  if career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId then
    return career_modules_inventory.getInventoryIdFromVehicleId(vehicleId) or vehicleId
  end
  return vehicleId
end

local function getVehicleModel(vehicleId)
  if gameplay_events_freContracts_vehiclePool and gameplay_events_freContracts_vehiclePool.getCurrentVehicleModel then
    return gameplay_events_freContracts_vehiclePool.getCurrentVehicleModel(vehicleId)
  end
  local object = vehicleId and be:getObjectByID(vehicleId) or nil
  return object and object.JBeam or nil
end

local function calculateReward(distance, fullPull, pullTime)
  local ratio = clamp(distance / fullDistance, 0, 1)
  local base = tonumber(selectedSled and selectedSled.baseReward) or 0
  local timeBonus = 0
  if fullPull then
    local par = tonumber(selectedSled and selectedSled.parTimeSeconds) or 0
    if par > 0 and pullTime < par then
      timeBonus = clamp((par - pullTime) / (par * 0.5), 0, 1) * 0.2
    end
  end
  local money = base * ratio * (1 + timeBonus)
  local xp = base * 0.25 * ratio
  if gameplay_events_freContracts_race and gameplay_events_freContracts_race.calculateRewardModifiers then
    local modifiers = gameplay_events_freContracts_race.calculateRewardModifiers({"pulling"}) or {}
    local discipline = modifiers.disciplineMultipliers and modifiers.disciplineMultipliers.pulling or {}
    money = money * (tonumber(discipline.moneyMultiplier) or 1)
    xp = xp * (tonumber(discipline.xpMultiplier) or 1)
  end
  return math.max(0, math.floor(money + 0.5)), math.max(0, math.floor(xp + 0.5)), timeBonus
end

local function awardCareer(money, xp, label)
  if not (career_career and career_career.isActive and career_career.isActive()) then return end
  if not (career_modules_payment and career_modules_payment.reward) then return end
  local reward = {
    money = {amount = money, canBeNegative = false},
    ["careerSkills-speed"] = {amount = xp}
  }
  career_modules_payment.reward(reward, {
    label = label .. " - Completion",
    tags = {"gameplay", "reward", "fre", "pulling"}
  }, true)
end

finishPull = function(reason, invalid)
  if phase ~= "pulling" then return end
  local completedDistance = clamp(maxDistance, 0, fullDistance)
  local fullPull = not invalid and (reason == "full_pull" or maxDistance >= fullDistance - (tonumber(config.finishToleranceMeters) or 0.35))
  if fullPull then completedDistance = fullDistance end
  local money, xp, timeBonus = calculateReward(completedDistance, fullPull, elapsedTime)
  if invalid then money, xp = 0, 0 end

  local raceLabel = string.format("%s - %s", config.label or "Tractor Pull", selectedSled.label or selectedSled.id)
  local inventoryId = getInventoryId(playerVehicleId)
  local newBest = false
  if not invalid and inventoryId and gameplay_events_freeroam_leaderboardManager then
    newBest = gameplay_events_freeroam_leaderboardManager.addLeaderboardEntry({
      raceName = config.eventId or "tractorPull",
      raceLabel = raceLabel,
      inventoryId = inventoryId,
      time = elapsedTime,
      pullDistance = completedDistance,
      fullPull = fullPull,
      sledId = selectedSled.id,
      hitchId = selectedHitch and selectedHitch.id or nil,
      reward = money
    }) == true
  end

  if not invalid then awardCareer(money, xp, raceLabel) end

  local payload = {
    raceId = config.eventId or "tractorPull",
    raceName = config.eventId or "tractorPull",
    raceLabel = raceLabel,
    finishTime = elapsedTime,
    vehicleId = playerVehicleId,
    vehicleModel = getVehicleModel(playerVehicleId),
    disciplineIds = {"pulling"},
    invalidLap = invalid == true,
    resultMetrics = {
      sledId = selectedSled.id,
      distanceMeters = completedDistance,
      fullPullDistanceMeters = fullDistance,
      distanceRatio = fullDistance > 0 and completedDistance / fullDistance or 0,
      fullPull = fullPull,
      elapsedTime = elapsedTime,
      timeRecorded = fullPull,
      hitchId = selectedHitch and selectedHitch.id or nil,
      finishReason = reason
    }
  }
  if gameplay_events_freContracts_race and gameplay_events_freContracts_race.onFreeroamRaceCompleted then
    gameplay_events_freContracts_race.onFreeroamRaceCompleted(payload)
  end
  if extensions and extensions.hook then extensions.hook("onRlsFreeroamRaceResultFinalized", payload) end

  resultData = {
    title = invalid and "Pull Invalid" or (fullPull and "Full Pull!" or "Pull Complete"),
    sledLabel = selectedSled.label,
    distanceMeters = completedDistance,
    distanceFeet = completedDistance * METERS_TO_FEET,
    fullDistanceMeters = fullDistance,
    fullDistanceFeet = fullDistance * METERS_TO_FEET,
    fullPull = fullPull,
    elapsedTime = elapsedTime,
    timeRecorded = fullPull,
    finishReason = reason,
    rewardMoney = money,
    rewardXp = xp,
    timeBonusPercent = math.floor(timeBonus * 100 + 0.5),
    newBest = newBest,
    invalid = invalid == true
  }
  phase = "results"
  triggerUi(true, "results", resultData)
end

abortAttempt = function(reason)
  if phase == "pulling" then
    finishPull(reason, true)
  elseif isActiveAttempt() then
    resetRuntime(true)
  end
end

local function spawnSelectedSled(sled, hitch)
  playerVehicleId = be and be:getPlayerVehicleID(0) or nil
  if not playerVehicleId or playerVehicleId == -1 then
    if ui_message then ui_message("Enter a vehicle before starting the tractor pull.", 4, "tractorPull") end
    resetRuntime(true)
    return false
  end
  local pos = arrayToVec(spawnSpot.pos)
  local rot = arrayToQuat(spawnSpot.rot)
  if not pos or not rot or not core_vehicles or not core_vehicles.spawnNewVehicle then
    resetRuntime(true)
    return false
  end
  pos = pos + vec3(0, 0, tonumber(sled.spawnHeightMeters) or tonumber(config.sledSpawnHeightMeters) or 1.25)

  local vehicleConfig = jsonReadFile(sled.config)
  if type(vehicleConfig) ~= "table" or type(vehicleConfig.parts) ~= "table" then
    logMessage("E", "Could not load pulling sled preset " .. tostring(sled.config))
    if ui_message then ui_message("The selected pulling sled preset could not be loaded.", 6, "tractorPull", "warning") end
    resetRuntime(true)
    return false
  end
  vehicleConfig.parts.YB_PPS_chain = hitch.part
  vehicleConfig.partConfigFilename = sled.config

  local ok, object = pcall(function()
    return core_vehicles.spawnNewVehicle(sled.model, {
      config = vehicleConfig,
      pos = pos,
      rot = rot,
      cling = false,
      autoEnterVehicle = false
    })
  end)
  if not ok or not object or not object.getID then
    logMessage("E", "Could not spawn pulling sled " .. tostring(sled.id) .. ": " .. tostring(object))
    if ui_message then ui_message("The selected pulling sled could not be spawned. Check that Youngblood Pulling Sled v2 is enabled.", 7, "tractorPull", "warning") end
    resetRuntime(true)
    return false
  end

  sledVehicleId = object:getID()
  selectedSled = sled
  selectedHitch = hitch
  spawnWaitTime = 0
  elapsedTime = 0
  noProgressTime = 0
  progressCheckpointDistance = 0
  sledStartPos = nil
  lastSledFlatPos = nil
  maxDistance = 0
  phase = "spawning"
  triggerUi(false)
  return true
end

function M.selectSled(id)
  if phase ~= "selecting" or not loadLevelData() then return false end
  local sled = sledById(id)
  if not sled then return false end
  selectedSled = sled
  phase = "choosingHitch"
  triggerUi(true, "hitch", {
    sledLabel = sled.label,
    baseReward = tonumber(sled.baseReward) or 0,
    hitches = buildHitchChoices()
  })
  return true
end

function M.selectHitch(id)
  if phase ~= "choosingHitch" or not selectedSled or not loadLevelData() then return false end
  local hitch = hitchById(id)
  if not hitch or type(hitch.part) ~= "string" or hitch.part == "" then return false end
  return spawnSelectedSled(selectedSled, hitch)
end

function M.backToSleds()
  if phase ~= "choosingHitch" then return end
  selectedSled = nil
  phase = "idle"
  showSelector()
end

function M.cancel()
  resetRuntime(true)
end

function M.dismissResults()
  if phase ~= "results" then return end
  resetRuntime(true)
end

function M.getState()
  return {
    phase = phase,
    levelId = levelId,
    sledVehicleId = sledVehicleId,
    playerVehicleId = playerVehicleId,
    selectedSledId = selectedSled and selectedSled.id or nil,
    selectedHitchId = selectedHitch and selectedHitch.id or nil,
    distanceMeters = maxDistance,
    fullDistanceMeters = fullDistance,
    elapsedTime = elapsedTime,
    result = resultData
  }
end

local function isOtherActivityActive()
  local session = gameplay_events_freeroam_session
  if session and (session.mActiveRace or session.staged) then return true end
  local derby = gameplay_events_freeroam_demolitionDerby
  if derby and derby.isRecoveryRadialOverrideActive and derby.isRecoveryRadialOverrideActive() then return true end
  return false
end

local function updateIdle(dt)
  if isOtherActivityActive() then
    stationaryTime = 0
    if phase == "selecting" or phase == "choosingHitch" then resetRuntime(false) end
    return
  end
  local vehicle = be and be:getPlayerVehicle(0) or nil
  local stagingPos = stagingSpot and arrayToVec(stagingSpot.pos)
  if not vehicle or not stagingPos then return end
  local distance = (vehicle:getPosition() - stagingPos):length()
  local enterRadius = tonumber(config.stagingRadiusMeters) or 6
  local exitRadius = tonumber(config.stagingExitRadiusMeters) or 9
  if phase == "selecting" or phase == "choosingHitch" then
    if distance > exitRadius then resetRuntime(false) end
    return
  end
  if distance > enterRadius then
    stationaryTime = 0
    return
  end
  local speed = vehicle:getVelocity():length()
  if speed <= (tonumber(config.stagingStopSpeedMps) or 0.5) then
    stationaryTime = stationaryTime + dt
    if stationaryTime >= (tonumber(config.stagingStopSeconds) or 1) then showSelector() end
  else
    stationaryTime = 0
  end
end

local function pushHud(status)
  triggerUi(true, "hud", {
    sledLabel = selectedSled.label,
    distanceMeters = clamp(maxDistance, 0, fullDistance),
    distanceFeet = clamp(maxDistance, 0, fullDistance) * METERS_TO_FEET,
    fullDistanceMeters = fullDistance,
    fullDistanceFeet = fullDistance * METERS_TO_FEET,
    elapsedTime = elapsedTime,
    status = status,
    canAbandon = phase == "waiting"
  })
end

local function updateSpawning(dt)
  spawnWaitTime = spawnWaitTime + dt
  if spawnWaitTime < (tonumber(config.sledLoadDelaySeconds) or 2) then return end

  local sled = sledVehicleId and be:getObjectByID(sledVehicleId) or nil
  if not sled then
    if ui_message then ui_message("The pulling sled did not finish spawning.", 5, "tractorPull", "warning") end
    resetRuntime(false)
    return
  end

  local settledPos = sled:getPosition()
  sledStartPos = vec3(settledPos.x, settledPos.y, 0)
  lastSledFlatPos = vec3(settledPos.x, settledPos.y, 0)
  spawnWaitTime = 0
  phase = "waiting"
  pushHud("Waiting for sled movement")
end

local function updateTracking(dt)
  local sled = sledVehicleId and be:getObjectByID(sledVehicleId) or nil
  if not sled or not sledStartPos then
    if phase == "pulling" then finishPull("vehicle_missing", true) else resetRuntime(false) end
    return
  end

  local position = sled:getPosition()
  local flatPos = vec3(position.x, position.y, 0)
  if lastSledFlatPos then
    local jump = (flatPos - lastSledFlatPos):length()
    local baseJump = tonumber(config.maxSledTeleportJumpMeters) or 12
    local maxRate = tonumber(config.maxSledTeleportSpeedMps) or 40
    local maxJump = math.max(baseJump, maxRate * math.max(tonumber(dt) or 0, 0))
    if jump > maxJump then
      abortAttempt("teleported")
      return
    end
  end
  lastSledFlatPos = flatPos

  local dx = flatPos.x - sledStartPos.x
  local dy = flatPos.y - sledStartPos.y
  local distance = math.sqrt(dx * dx + dy * dy)
  maxDistance = math.max(maxDistance, distance)

  local startMovement = (tonumber(config.startMovementFeet) or 1) / METERS_TO_FEET
  if phase == "waiting" and maxDistance > startMovement then
    phase = "pulling"
    elapsedTime = 0
    noProgressTime = 0
    progressCheckpointDistance = maxDistance
  end

  if phase == "pulling" then
    elapsedTime = elapsedTime + dt
  end

  if maxDistance >= fullDistance - (tonumber(config.finishToleranceMeters) or 0.35) then
    finishPull("full_pull", false)
    return
  end

  if phase == "pulling" then
    local progressStep = (tonumber(config.progressIncrementFeet) or 0.1) / METERS_TO_FEET
    if maxDistance >= progressCheckpointDistance + progressStep then
      progressCheckpointDistance = maxDistance
      noProgressTime = 0
    else
      noProgressTime = noProgressTime + dt
      if noProgressTime >= (tonumber(config.noProgressFinishSeconds) or 5) then
        finishPull("no_progress", false)
        return
      end
    end

    if elapsedTime >= (tonumber(config.maximumPullSeconds) or 120) then
      finishPull("time_limit", false)
      return
    end
  end

  hudAccumulator = hudAccumulator + dt
  if hudAccumulator >= 0.1 then
    hudAccumulator = hudAccumulator % 0.1
    pushHud(phase == "waiting" and "Waiting for sled movement" or "Pulling")
  end
end

function M.onUpdate(dtReal, dtSim)
  -- freeroamEvents calls this controller with one argument; ignore the automatic
  -- extension callback to avoid advancing timers twice.
  if dtSim ~= nil then return end
  local dt = math.max(0, tonumber(dtReal) or 0)
  if not loadLevelData() then
    if phase ~= "idle" then resetRuntime(true) end
    return
  end
  if phase == "idle" or phase == "selecting" or phase == "choosingHitch" then
    updateIdle(dt)
  elseif phase == "spawning" then
    updateSpawning(dt)
  elseif phase == "waiting" or phase == "pulling" then
    updateTracking(dt)
  end
end

function M.onVehicleDestroyed(vehicleId)
  if vehicleId == sledVehicleId then
    if phase == "pulling" then finishPull("vehicle_destroyed", true) else resetRuntime(false) end
  elseif vehicleId == playerVehicleId and isActiveAttempt() then
    abortAttempt("player_vehicle_destroyed")
  end
end

function M.onTeleportedToGarage(_, veh)
  local vehId = vehicleIdFrom(veh)
  if not isActiveAttempt() then return end
  if vehId == playerVehicleId or vehId == sledVehicleId then
    abortAttempt("towed_to_garage")
  end
end

function M.onClientEndMission()
  if phase ~= "idle" then resetRuntime(true) end
  levelId, config, sites = nil, nil, nil
end

function M.onWorldReadyState(state)
  if state == 2 then
    levelId, config, sites = nil, nil, nil
    loadLevelData()
  end
end

function M.onExtensionUnloaded()
  resetRuntime(true)
end

return M
