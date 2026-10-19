-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

-- Dependencies
M.dependencies = {
    'util_configListGenerator', 'gameplay_parking',
    'freeroam_facilities', 'gameplay_sites_sitesManager', 'gameplay_walk'
}

-- Require necessary modules.
-- Slash form, not dots: overrideManager registers its hooks as
-- package.preload['<slash/path>'], and Lua keys package.loaded by the exact string, so
-- 'gameplay.parking' and 'gameplay/parking' are separate cache entries. The dot form
-- never reaches the preload hook, which silently handed this file un-overridden vanilla
-- copies of parking and facilities while the rest of the mod used the overridden ones.
local configListGenerator = require('util/configListGenerator')
local parking = require('gameplay/parking')
local parkingReservation = require('gameplay/parkingReservation')
local freeroam_facilities = require('freeroam/facilities')
local gameplay_sites_sitesManager = require('gameplay/sites/sitesManager')
local marker

local completionFadeDuration = 0.5

local REPO_SKILL_ATTRIBUTE_KEY = "careerSkills-recovery"
local REPO_SKILL_PATH_IDS = {"careerSkills-recovery", "recovery"}
local REPO_SKILL_MAX_LEVEL = 50
local REPO_FILTERS_FILE = "gameplay/repo/repoVehicleFilters.json"
local repoVehicleFiltersCache = nil
local repoVehicleFiltersByTag = nil

local function loadRepoVehicleFilters()
  if repoVehicleFiltersCache and repoVehicleFiltersByTag then
    return repoVehicleFiltersCache, repoVehicleFiltersByTag
  end

  repoVehicleFiltersCache = {}
  repoVehicleFiltersByTag = {}

  local rawConfig = jsonReadFile(REPO_FILTERS_FILE) or {}
  for id, filterConfig in pairs(rawConfig) do
    if type(filterConfig) == "table" and filterConfig.type == "vehicle" then
      local normalizedConfig = deepcopy(filterConfig)
      normalizedConfig.id = id
      normalizedConfig.unlockTag = normalizedConfig.unlockTag or id
      normalizedConfig.priority = tonumber(normalizedConfig.priority) or 0
      normalizedConfig.skillUnlockLevel = tonumber(normalizedConfig.skillUnlockLevel) or REPO_SKILL_MAX_LEVEL
      normalizedConfig.payMultiplier = tonumber(normalizedConfig.payMultiplier) or 1
      normalizedConfig.baseXp = tonumber(normalizedConfig.baseXp) or 0
      normalizedConfig.tierLabel = normalizedConfig.tierLabel or normalizedConfig.filterName or normalizedConfig.unlockTag
      repoVehicleFiltersCache[#repoVehicleFiltersCache + 1] = normalizedConfig
      repoVehicleFiltersByTag[normalizedConfig.unlockTag] = normalizedConfig
    end
  end

  table.sort(repoVehicleFiltersCache, function(a, b)
    if a.priority ~= b.priority then
      return a.priority > b.priority
    end
    return tostring(a.id) < tostring(b.id)
  end)

  return repoVehicleFiltersCache, repoVehicleFiltersByTag
end

local function safeYearsRange(vehicleInfo)
  if type(vehicleInfo) ~= "table" then
    return nil
  end

  local function normalizeYears(years)
    if type(years) ~= "table" then
      return nil
    end
    local minYear = tonumber(years.min)
    local maxYear = tonumber(years.max)
    if not minYear or not maxYear or minYear > maxYear then
      return nil
    end
    return {min = minYear, max = maxYear}
  end

  return normalizeYears(vehicleInfo.Years) or
    normalizeYears(type(vehicleInfo.aggregates) == "table" and vehicleInfo.aggregates.Years or nil)
end

local function safeNumericAttribute(vehicleInfo, attrName)
  if type(vehicleInfo) ~= "table" then
    return nil
  end

  local directValue = tonumber(vehicleInfo[attrName])
  if directValue then
    return directValue
  end

  local aggregateValue = type(vehicleInfo.aggregates) == "table" and vehicleInfo.aggregates[attrName] or nil
  if type(aggregateValue) == "table" then
    return tonumber(aggregateValue.min)
  end

  return nil
end

local function doesVehiclePassFiltersList(vehicleInfo, filters)
  if type(vehicleInfo) ~= "table" or type(filters) ~= "table" then
    return false
  end

  for filterName, parameters in pairs(filters) do
    if filterName == "Years" then
      local vehicleYears = safeYearsRange(vehicleInfo)
      if not vehicleYears then
        return false
      end
      local minYear = parameters.min ~= nil and tonumber(parameters.min) or nil
      local maxYear = parameters.max ~= nil and tonumber(parameters.max) or nil
      if (parameters.min ~= nil and not minYear) or (parameters.max ~= nil and not maxYear) then
        return false
      end
      if (minYear and vehicleYears.max < minYear) or (maxYear and vehicleYears.min > maxYear) then
        return false
      end
    elseif filterName ~= "Mileage" then
      if type(parameters) == "table" and (parameters.min ~= nil or parameters.max ~= nil) then
        local value = safeNumericAttribute(vehicleInfo, filterName)
        if not value or type(value) ~= "number" then
          return false
        end
        local minValue = parameters.min ~= nil and tonumber(parameters.min) or nil
        local maxValue = parameters.max ~= nil and tonumber(parameters.max) or nil
        if (parameters.min ~= nil and not minValue) or (parameters.max ~= nil and not maxValue) then
          return false
        end
        if (minValue and value < minValue) or (maxValue and value > maxValue) then
          return false
        end
      else
        if type(parameters) ~= "table" then
          return false
        end

        local passed = false
        local aggregateValue = type(vehicleInfo.aggregates) == "table" and vehicleInfo.aggregates[filterName] or nil
        for _, value in ipairs(parameters) do
          if vehicleInfo[filterName] == value or (type(aggregateValue) == "table" and aggregateValue[value]) then
            passed = true
            break
          end
        end
        if not passed then
          return false
        end
      end
    end
  end

  return true
end

local function doesVehiclePassFilter(vehicleInfo, filter)
  if type(filter) ~= "table" then
    return false
  end
  if filter.whiteList and not doesVehiclePassFiltersList(vehicleInfo, filter.whiteList) then
    return false
  end
  if filter.blackList and doesVehiclePassFiltersList(vehicleInfo, filter.blackList) then
    return false
  end
  return true
end

local function getOrgLevelData(org, offset)
  if not org then
    return nil
  end

  local repLevel = (org.reputation and org.reputation.level) or 0
  if type(repLevel) ~= "number" then
    repLevel = 0
  end

  local levels = org.reputationLevels
  if not levels then
    return nil
  end

  local arrayIndex = repLevel + 2 + (offset or 0)
  if arrayIndex < 1 or arrayIndex > #levels then
    return nil
  end

  return levels[arrayIndex]
end

local function getRepoTagData(tag)
  local _, filtersByTag = loadRepoVehicleFilters()
  return filtersByTag[tag]
end

local function getBranchLevelByPathIds(pathIds)
  if not (career_branches and career_branches.getBranchLevel) then
    return 0
  end

  for _, skillPathId in ipairs(pathIds or {}) do
    local branchLevel = career_branches.getBranchLevel(skillPathId)
    local level = tonumber(branchLevel)
    if level then
      return math.max(0, math.floor(level))
    end
  end

  return 0
end

local function getRepoSkillLevel()
  local level = getBranchLevelByPathIds(REPO_SKILL_PATH_IDS)
  if level > 0 then
    return math.min(level, REPO_SKILL_MAX_LEVEL)
  end

  if career_modules_playerAttributes and career_modules_playerAttributes.getAttributeValue and career_branches and career_branches.calcBranchLevelFromValue then
    local value = tonumber(career_modules_playerAttributes.getAttributeValue(REPO_SKILL_ATTRIBUTE_KEY)) or 0
    for _, skillPathId in ipairs(REPO_SKILL_PATH_IDS) do
      local branchLevel = career_branches.calcBranchLevelFromValue(value, skillPathId)
      level = math.max(level, tonumber(branchLevel) or 0)
    end
  end

  return math.min(math.max(0, math.floor(level)), REPO_SKILL_MAX_LEVEL)
end

local function getRepoPayoutBonusPercent(level)
  local clampedLevel = math.min(math.max(tonumber(level) or 0, 0), REPO_SKILL_MAX_LEVEL)
  local rewardCount = math.max(0, math.min(24, math.floor(clampedLevel / 2)))
  return 4 * (rewardCount / 24)
end

local function isRepoTagUnlocked(tag)
  local tagData = getRepoTagData(tag)
  if not tagData then
    return false
  end

  local unlocked = false
  local unlockFlag = tagData.skillUnlockFlag or tagData.unlockFlag
  if career_modules_unlockFlags and career_modules_unlockFlags.getFlag and unlockFlag then
    unlocked = career_modules_unlockFlags.getFlag(unlockFlag) == true
  end
  if unlocked then
    return true
  end

  return getRepoSkillLevel() >= (tagData.skillUnlockLevel or REPO_SKILL_MAX_LEVEL)
end

local function doesVehiclePassRepoFilterConfig(vehicleInfo, filterConfig)
  if type(filterConfig) ~= "table" then
    return false
  end

  local baseFilter = filterConfig.filter or {}
  if not doesVehiclePassFilter(vehicleInfo, baseFilter) then
    return false
  end

  local subFilters = filterConfig.subFilters
  if type(subFilters) ~= "table" or tableIsEmpty(subFilters) then
    return true
  end

  for _, subFilter in ipairs(subFilters) do
    local aggregateFilter = deepcopy(baseFilter)
    if type(subFilter) == "table" then
      tableMergeRecursive(aggregateFilter, subFilter)
      if doesVehiclePassFilter(vehicleInfo, aggregateFilter) then
        return true
      end
    end
  end

  return false
end

local function getRepoVehicleTag(vehicleInfo)
  local orderedFilters = loadRepoVehicleFilters()
  for _, filterConfig in ipairs(orderedFilters) do
    if doesVehiclePassRepoFilterConfig(vehicleInfo, filterConfig) and isRepoTagUnlocked(filterConfig.unlockTag) then
      return filterConfig.unlockTag
    end
  end
  return nil
end

local function buildDealershipFilters(dealership)
  local filter = dealership and dealership.filter or {}
  local subFilters = dealership and dealership.subFilters or {}

  if dealership and dealership.associatedOrganization and freeroam_organizations then
    local org = freeroam_organizations.getOrganization(dealership.associatedOrganization)
    local level = getOrgLevelData(org)
    if level and level.filter then
      filter = level.filter
    end
    if level and level.subFilters then
      subFilters = level.subFilters
    end
  end

  local filters = {}
  if subFilters and not tableIsEmpty(subFilters) then
    for _, subFilter in ipairs(subFilters) do
      local aggregateFilter = deepcopy(filter or {})
      tableMergeRecursive(aggregateFilter, subFilter)
      aggregateFilter._probability = (type(subFilter.probability) == "number" and subFilter.probability) or 1
      table.insert(filters, aggregateFilter)
    end
  else
    local aggregateFilter = deepcopy(filter or {})
    aggregateFilter._probability = 1
    table.insert(filters, aggregateFilter)
  end

  return filters
end

local function getEligibleRepoVehiclesForDealership(dealership, eligibleVehicles)
  local candidates = {}
  local dealershipFilters = buildDealershipFilters(dealership)

  for _, filterVariant in ipairs(dealershipFilters) do
    local variantProbability = tonumber(filterVariant._probability) or 1
    for _, vehicleInfo in ipairs(eligibleVehicles or {}) do
      if doesVehiclePassFilter(vehicleInfo, filterVariant) then
        local repoTag = getRepoVehicleTag(vehicleInfo)
        local repoTagData = getRepoTagData(repoTag)
        if repoTag and repoTagData and isRepoTagUnlocked(repoTag) then
          local candidate = deepcopy(vehicleInfo)
          candidate.repoTag = repoTag
          candidate.repoTierLabel = repoTagData.tierLabel
          candidate.repoSubFilterProbability = variantProbability
          table.insert(candidates, candidate)
        end
      end
    end
  end

  return candidates
end

local function pickWeightedRepoVehicleInfo(candidates)
  if not candidates or #candidates == 0 then
    return nil
  end

  local totalWeight = 0
  local weightedCandidates = {}
  for _, vehicleInfo in ipairs(candidates) do
    local weight = tonumber(vehicleInfo.adjustedPopulation) or tonumber(vehicleInfo.Population) or 1
    weight = weight * math.max(tonumber(vehicleInfo.repoSubFilterProbability) or 1, 0)
    if weight > 0 then
      totalWeight = totalWeight + weight
      weightedCandidates[#weightedCandidates + 1] = {vehicleInfo = vehicleInfo, weight = weight}
    end
  end

  if totalWeight <= 0 then
    return deepcopy(candidates[math.random(#candidates)])
  end

  local roll = math.random() * totalWeight
  local runningWeight = 0
  for _, entry in ipairs(weightedCandidates) do
    runningWeight = runningWeight + entry.weight
    if runningWeight >= roll then
      return deepcopy(entry.vehicleInfo)
    end
  end

  return deepcopy(weightedCandidates[#weightedCandidates].vehicleInfo)
end

local function getRepoStateFields(instance)
  local repoSkillLevel = getRepoSkillLevel()
  return {
    repoTag = instance and instance.repoTag or "",
    repoTierLabel = instance and instance.repoTierLabel or "",
    repoSkillLevel = repoSkillLevel,
    repoPayoutBonusPercent = getRepoPayoutBonusPercent(repoSkillLevel),
  }
end

local function stopFadeSafe()
  if ui_fadeScreen and ui_fadeScreen.stop then
    pcall(function() ui_fadeScreen.stop(completionFadeDuration) end)
  end
end

local function switchPlayerToRepoVehicle(repoVehicleId)
  if not repoVehicleId then return false end

  local vehObj = getObjectByID(repoVehicleId)
  if vehObj then
    be:enterVehicle(0, vehObj)
    return true
  end
  ui_fadeScreen.stop(0.5)

  -- Avoid spawning/entering via inventory here because it can trigger the global loading screen.
  return false
end


-- Create a single repo job instance for the whole module
local repoJobInstance = nil
-- Forward-declared: finalizeRepoDelivery calls this, but it is defined later in the file.
local buildRepoStateData

local function deleteDeliveredVehicle(deliveredId)
  if not deliveredId then return end
  if gameplay_traffic then
    pcall(function() gameplay_traffic.removeTraffic(deliveredId) end)
  end
  local v = getObjectByID(deliveredId)
  if v then
    pcall(function() core_vehicleBridge.executeAction(v, 'setFreeze', true) end)
    pcall(function() v:delete() end)
  end
end

local function clearRepoDeliveryMarker()
  if marker then
    pcall(function() marker:unregisterObject() end)
    pcall(function() marker:delete() end)
    marker = nil
  end
  if core_groundMarkers and core_groundMarkers.resetAll then
    core_groundMarkers.resetAll()
  end
end

local function finalizeRepoDelivery(self, deliveredId, repoId, rewardText)
  clearRepoDeliveryMarker()

  self.isJobStarted = false
  self.isMonitoring = false
  self.isCompleted = true

  if deliveredId and repoId and be:getPlayerVehicleID(0) == deliveredId then
    switchPlayerToRepoVehicle(repoId)
  end

  if deliveredId and be:getPlayerVehicleID(0) ~= deliveredId then
    deleteDeliveredVehicle(deliveredId)
    self.vehicleId = nil
    self.pendingDeliveredDeleteId = nil
  else
    self.pendingDeliveredDeleteId = deliveredId
  end

  self:releaseDeliveryReservation()
  if buildRepoStateData then
    guihooks.trigger('updateRepoState', buildRepoStateData(self, {state = "completed"}))
  end
  if self.employmentMode then
    ui_message(rewardText, 8, "Assignment", "info")
  else
    ui_message(rewardText, 15, "Job Completed", "info")
  end
end

local function createMarker(position)
    if not marker then
        marker = createObject('TSStatic')
        marker.shapeName = "art/shapes/interface/checkpoint_marker.dae"
        marker.scale = vec3(4, 4, 4)
        marker.useInstanceRenderData = true
        marker.instanceColor = ColorF(0, 0.8, 0.2, 0.7):asLinear4F() 
        marker:setPosition(position)
        marker:registerObject("repo_delivery_marker")
    end
end

local VehicleRepoJob = {}
VehicleRepoJob.__index = VehicleRepoJob

-- Constructor for VehicleRepoJob
function VehicleRepoJob:new()
    local instance = setmetatable({}, VehicleRepoJob)
    instance.vehicleId = nil
    instance.vehicleValue = nil
    instance.pickupLocation = nil
    instance.deliveryLocation = nil
    instance.jobStartTime = nil
    instance.isMonitoring = false
    instance.selectedDealership = nil
    instance.isJobStarted = false
    instance.returnCountdown = nil
    instance.totalDistanceTraveled = 0
    instance.spawnedVehicle = false
    instance.isCompleted = false
    instance.isCompleting = false
    instance.reservationToken = nil
    instance.reservedPickupSpot = nil
    instance.reservedDeliverySpot = nil
    instance.availableDealerships = nil
    instance.pendingDeliveredDeleteId = nil
    instance.uiStateUpdateTimer = 0
    if core_groundMarkers then
        core_groundMarkers.resetAll()
    end
    instance.eligibleVehicles = nil
    instance.eligibleRepoVehiclesByDealership = nil
    instance.repoTag = nil
    instance.repoTierLabel = nil
    instance.employmentMode = false
    instance.employmentOnComplete = nil
    instance.employmentOnAbort = nil
    instance.employmentHomeFacId = nil
    instance.employmentDeliveryLabel = nil
    instance.employmentPickupFacId = nil
    instance.employmentPickupLabel = nil
    instance.employmentVehicleCandidates = nil
    return instance
end

function VehicleRepoJob:releasePickupReservation()
    if self.reservedPickupSpot and self.reservationToken then
        parkingReservation.releaseSpot(self.reservedPickupSpot, self.reservationToken)
    end
    self.reservedPickupSpot = nil
end

function VehicleRepoJob:releaseDeliveryReservation()
    if self.reservedDeliverySpot and self.reservationToken then
        parkingReservation.releaseSpot(self.reservedDeliverySpot, self.reservationToken)
    end
    self.reservedDeliverySpot = nil
end

function VehicleRepoJob:releaseReservations()
    self:releasePickupReservation()
    self:releaseDeliveryReservation()
    self.reservationToken = nil
end

-- Reset to initial state (ready to generate new mission)
function VehicleRepoJob:resetToInitialState(opts)
    opts = type(opts) == "table" and opts or {}
    local preserveEmployment = opts.preserveEmployment and self.employmentMode
    local employmentCtx = preserveEmployment and {
        employmentMode = true,
        employmentOnComplete = self.employmentOnComplete,
        employmentOnAbort = self.employmentOnAbort,
        employmentHomeFacId = self.employmentHomeFacId,
        employmentDeliveryLabel = self.employmentDeliveryLabel,
        employmentPickupFacId = self.employmentPickupFacId,
        employmentPickupLabel = self.employmentPickupLabel,
        repoVehicle = self.repoVehicle,
        repoVehicleID = self.repoVehicleID,
    } or nil

    self:releaseReservations()

    if self.vehicleId then
        if gameplay_traffic then
            pcall(function() gameplay_traffic.removeTraffic(self.vehicleId) end)
        end
        local vehicle = getObjectByID(self.vehicleId)
        if vehicle then
            pcall(function() vehicle:delete() end)
        end
    end

    if marker then
        pcall(function() marker:unregisterObject() end)
        pcall(function() marker:delete() end)
        marker = nil
    end

    self.vehicleId = nil
    self.vehicleValue = nil
    self.pickupLocation = nil
    self.deliveryLocation = nil
    self.jobStartTime = nil
    self.isMonitoring = false
    self.selectedDealership = nil
    self.isJobStarted = false
    self.employmentPickupPrepared = nil
    self.returnCountdown = nil
    self.totalDistanceTraveled = 0
    self.spawnedVehicle = false
    self.isCompleted = false
    self.isCompleting = false
    self.reservationToken = nil
    self.reservedPickupSpot = nil
    self.reservedDeliverySpot = nil
    self.reward = nil
    self.jobCoroutine = nil
    self.randomVehicleInfo = nil
    self.vehicleConfig = nil
    self.validSpots = nil
    self.selectedSpot = nil
    self.availableDealerships = nil
    self.pendingDeliveredDeleteId = nil
    self.parkingSpots = nil
    self.playerPosition = nil
    self.vehInfo = nil
    self.paintName = nil
    self.updateTimer = nil
    self.uiStateUpdateTimer = 0
    self.eligibleVehicles = nil
    self.eligibleRepoVehiclesByDealership = nil
    self.repoTag = nil
    self.repoTierLabel = nil
    self.employmentMode = false
    self.employmentOnComplete = nil
    self.employmentOnAbort = nil
    if core_groundMarkers then
        core_groundMarkers.resetAll()
    end

    if employmentCtx then
        self.employmentMode = employmentCtx.employmentMode
        self.employmentOnComplete = employmentCtx.employmentOnComplete
        self.employmentOnAbort = employmentCtx.employmentOnAbort
        self.employmentHomeFacId = employmentCtx.employmentHomeFacId
        self.employmentDeliveryLabel = employmentCtx.employmentDeliveryLabel
        self.employmentPickupFacId = employmentCtx.employmentPickupFacId
        self.employmentPickupLabel = employmentCtx.employmentPickupLabel
        self.repoVehicle = employmentCtx.repoVehicle
        self.repoVehicleID = employmentCtx.repoVehicleID
    else
        self.employmentHomeFacId = nil
        self.employmentDeliveryLabel = nil
        self.employmentPickupFacId = nil
        self.employmentPickupLabel = nil
        self.employmentVehicleCandidates = nil
    end
end

-- Destroy the current job and clean up resources
function VehicleRepoJob:destroy()
    self:resetToInitialState()
end

-- Check if vehicle exists, reset if it doesn't
function VehicleRepoJob:checkVehicleExists()
    if not self.vehicleId then
        return true
    end
    
    local vehicle = getObjectByID(self.vehicleId)
    if not vehicle then
        self:resetToInitialState()
        return false
    end
    
    local success = pcall(function() vehicle:getPosition() end)
    if not success then
        self:resetToInitialState()
        return false
    end
    
    return true
end

local function getEmploymentModule()
    return career_modules_delivery_employment
end

local function isOnEmploymentShift()
    local emp = getEmploymentModule()
    return emp and emp.isOnShift and emp.isOnShift() or false
end

local function isPlayerInCompanyRepoTruck()
    if not (career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId) then
        return false
    end
    local emp = getEmploymentModule()
    if not emp or not emp.getEmployerOrgId then
        return false
    end
    local orgId = emp.getEmployerOrgId()
    if not orgId then
        return false
    end
    local vehId = be:getPlayerVehicleID(0)
    if not vehId or vehId < 0 then
        return false
    end
    local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
    local vehInfo = inventoryId and career_modules_inventory.getVehicles()[inventoryId]
    return vehInfo and vehInfo.loanType == "company" and vehInfo.owningOrganization == orgId
end

local function isRepoDisabled()
    local disabled = false
    local reason = ""

    -- Check if player is walking (highest priority)
    if gameplay_walk and gameplay_walk.isWalking() then
        disabled = true
        reason = "Repo service is not available while walking"
        return disabled, reason
    end

    -- Check if repo multiplier is 0
    if career_economyAdjuster then
        local repoMultiplier = career_economyAdjuster.getSectionMultiplier("repo") or 1.0
        if repoMultiplier == 0 then
            disabled = true
            reason = "Repo multiplier is set to 0"
        end
    end

    -- Check for active challenge that might disable repo
    if career_challengeModes and career_challengeModes.isChallengeActive() then
        local activeChallenge = career_challengeModes.getActiveChallenge()
        if activeChallenge then
            -- Check if the challenge has economy adjuster settings that disable repo
            if activeChallenge.economyAdjuster and activeChallenge.economyAdjuster.repo == 0 then
                disabled = true
                reason = string.format("Repo is disabled due to '%s' Challenge", activeChallenge.name or "Unknown Challenge")
            end
        end
    end

    return disabled, reason
end

buildRepoStateData = function(instance, overrides)
    local repoDisabled, disabledReason = isRepoDisabled()
    if not repoDisabled and isOnEmploymentShift() then
        repoDisabled = true
        disabledReason = "Clock out before taking independent repo jobs."
    end
    local effectiveState = repoDisabled and "disabled" or "no_mission"
    local distanceToDestination = 0

    if instance then
        if instance.deliveryLocation and instance.vehicleId then
            local vehicle = getObjectByID(instance.vehicleId)
            if vehicle then
                local success, pos = pcall(function() return vehicle:getPosition() end)
                if success and pos then
                    distanceToDestination = (pos - instance.deliveryLocation.pos):length()
                end
            end
        end

        if instance.isCompleted then
            effectiveState = repoDisabled and "disabled" or "completed"
        elseif instance.jobCoroutine and coroutine.status(instance.jobCoroutine) ~= "dead" then
            effectiveState = repoDisabled and "disabled" or "loading"
        elseif instance.isMonitoring then
            effectiveState = repoDisabled and "disabled" or (instance.isJobStarted and "dropping_off" or "picking_up")
        end
    end

    local stateFields = getRepoStateFields(instance)
    local data = {
        state = effectiveState,
        vehicle = instance and instance.randomVehicleInfo or nil,
        deliveryLocation = instance and (
            instance.employmentMode and (instance.employmentDeliveryLabel or "the company yard")
            or (instance.selectedDealership and instance.selectedDealership.name)
        ) or "",
        distanceToDestination = distanceToDestination,
        totalDistance = instance and (instance.totalDistanceTraveled or 0) or 0,
        reward = instance and (instance.reward or 0) or 0,
        isRepoVehicle = M.isRepoVehicle and M.isRepoVehicle() or false,
        repoDisabled = repoDisabled,
        disabledReason = disabledReason,
        repoTag = stateFields.repoTag,
        repoTierLabel = stateFields.repoTierLabel,
        repoSkillLevel = stateFields.repoSkillLevel,
        repoPayoutBonusPercent = stateFields.repoPayoutBonusPercent,
    }

    if type(overrides) == "table" then
        for key, value in pairs(overrides) do
            data[key] = value
        end
    end

    return data
end

local function abortRepoGeneration(self, message)
    if message then
        log("W", "repo", message)
    end
    if self.employmentMode then
        local onAbort = self.employmentOnAbort
        self.employmentOnComplete = nil
        self.employmentOnAbort = nil
        self:resetToInitialState()
        if onAbort then
            onAbort(message or "Car haul failed.", true)
        end
        return
    end
    self:resetToInitialState()
    guihooks.trigger('updateRepoState', buildRepoStateData(self))
end

-- Generate a new repo job
function VehicleRepoJob:generateJob()
    self:resetToInitialState({ preserveEmployment = true })
    self.reservationToken = parkingReservation.makeReservationToken("repo")

    -- Set loading state immediately
    local data = buildRepoStateData(self, {
        state = "loading",
        vehicle = nil,
        deliveryLocation = "",
        distanceToDestination = 0,
        totalDistance = 0,
        reward = 0,
        repoTag = "",
        repoTierLabel = "",
    })
    guihooks.trigger('updateRepoState', data)
    
    -- Start the coroutine for job generation
    self.jobCoroutine = coroutine.create(function()
        -- Initialize player vehicle and yield to allow other processes
        self:initializePlayerVehicle()
        for i = 1, 5 do coroutine.yield() end

        -- Find parking spots and yield
        self:findParkingSpots()
        for i = 1, 5 do coroutine.yield() end

        -- Select delivery destination and yield
        if self.employmentMode then
            self:selectEmploymentDelivery()
            if not self.deliveryLocation then
                abortRepoGeneration(self, "No dropoff found for company haul assignment")
                return
            end
            for i = 1, 5 do coroutine.yield() end
            self:buildEmploymentVehiclePool()
            if not self.employmentVehicleCandidates or #self.employmentVehicleCandidates == 0 then
                abortRepoGeneration(self, "No vehicles available for company pickup assignment")
                return
            end
        else
            self:selectDealership()
            if not self.selectedDealership then
                abortRepoGeneration(self, "No dealership found for repo job generation")
                return
            end
            for i = 1, 5 do coroutine.yield() end

            self:determineDeliveryLocation()
            if not self.deliveryLocation then
                abortRepoGeneration(self, "No reservable dealership dropoff spot found for repo job generation")
                return
            end
        end
        for i = 1, 5 do coroutine.yield() end

        -- Filter valid parking spots and yield
        if self.employmentMode and self:selectEmploymentPickup() then
            -- Partner-yard pickup spots already filled into validSpots.
        else
            self:filterValidSpots()
        end
        for i = 1, 5 do coroutine.yield() end

        -- Select a random valid parking spot and yield
        self:selectRandomSpot()
        if not self.selectedSpot then
            abortRepoGeneration(self, "No reservable pickup spot found for repo job generation")
            return
        end
        for i = 1, 5 do coroutine.yield() end

        -- Generate vehicle configuration and yield
        self:generateVehicleConfig()
        if not self.vehicleConfig then
            abortRepoGeneration(self)
            return
        end
        for i = 1, 5 do coroutine.yield() end

        -- Wait for player vehicle to be stationary before spawning
        local playerVelocity = be:getPlayerVehicle(0):getVelocity():length()
        while not self.spawnedVehicle and playerVelocity > 1 do
            coroutine.yield()
            playerVelocity = be:getPlayerVehicle(0):getVelocity():length()
        end

        -- Spawn the vehicle
        if not self.spawnedVehicle then
            self:spawnVehicle()
            if not self.vehicleId then
                abortRepoGeneration(self)
                return
            end
            self.spawnedVehicle = true
        end
        
        -- Set final state after generation is complete
        local finalData = buildRepoStateData(self)
        guihooks.trigger('updateRepoState', finalData)
    end)
end

-- Initialize the player's vehicle
function VehicleRepoJob:initializePlayerVehicle()
    local playerVehicle = be:getPlayerVehicle(0)
    self.repoVehicle = playerVehicle
    if not playerVehicle then
        return
    end
    self.playerPosition = playerVehicle:getPosition()
end

-- Find available parking spots
function VehicleRepoJob:findParkingSpots()
    -- Get fresh sites data for current level
    local sitePath = gameplay_sites_sitesManager.getCurrentLevelSitesFileByName('city')
    if sitePath then
        local siteData = gameplay_sites_sitesManager.loadSites(sitePath, true, true) -- force reload
        self.parkingSpots = siteData and siteData.parkingSpots
    end
    
    -- Fallback to parking module if no sites data
    if not self.parkingSpots then
        self.parkingSpots = parking.getParkingSpots()
        log("W", "repo", "Using parking module fallback for spots")
    end

    if not self.parkingSpots or not self.parkingSpots.objects then
        log("E", "repo", "No parking spots found!")
        return
    end
end

-- Select a random dealership
function VehicleRepoJob:selectDealership()
    local facilities = freeroam_facilities.getFacilities(getCurrentLevelIdentifier())
    local dealerships = {}
    for _, facility in ipairs(facilities and facilities.dealerships or {}) do
        dealerships[#dealerships + 1] = facility
    end
    -- Repair/recovery yards participate in the normal repo selection and skill pool.
    local generator = career_modules_delivery_generator
    for _, facility in ipairs(generator and generator.getFacilities() or {}) do
        if facility.repoProvider then dealerships[#dealerships + 1] = facility end
    end
    if not dealerships or #dealerships == 0 then
        return
    end
    self.eligibleVehicles = configListGenerator.getEligibleVehicles(false, false) or {}
    self.availableDealerships = {}
    self.eligibleRepoVehiclesByDealership = {}

    for _, dealership in ipairs(parkingReservation.shuffleSpots(dealerships)) do
        local repoCandidates = getEligibleRepoVehiclesForDealership(dealership, self.eligibleVehicles)
        if repoCandidates and #repoCandidates > 0 then
            self.eligibleRepoVehiclesByDealership[dealership.id] = repoCandidates
            table.insert(self.availableDealerships, dealership)
        else
            log("I", "repo", string.format("Skipping dealership '%s'; no unlocked repo candidates found", tostring(dealership.name)))
        end
    end

    self.selectedDealership = self.availableDealerships[1]
end

local function pickStaticFacilitySpot(spots)
    for _, spot in ipairs(parkingReservation.shuffleSpots(spots or {})) do
        if spot and spot.pos then
            return spot
        end
    end
end

local function appendUniqueFacilitySpot(list, seen, spot)
    if not spot or not spot.pos then return end
    local key = (spot.getPath and spot:getPath()) or spot.psPath or spot.name or spot
    if seen[key] then return end
    seen[key] = true
    table.insert(list, spot)
end

local function appendFacilitySpotCollection(list, seen, collection)
    if type(collection) ~= "table" then return end
    if collection[1] then
        for _, spot in ipairs(collection) do
            appendUniqueFacilitySpot(list, seen, spot)
        end
    else
        for _, spot in pairs(collection) do
            if type(spot) == "table" then
                appendUniqueFacilitySpot(list, seen, spot)
            end
        end
    end
end

local function getEmploymentDeliveryFacility(facId)
    if not facId then return nil end
    if career_modules_delivery_generator and career_modules_delivery_generator.getFacilityById then
        local fac = career_modules_delivery_generator.getFacilityById(facId)
        if fac then return fac end
    end
    if freeroam_facilities and freeroam_facilities.getFacility then
        return freeroam_facilities.getFacility("deliveryProvider", facId)
    end
    return nil
end

local function collectEmploymentDeliverySpots(fac)
    local facilitySpots, seen = {}, {}
    if not fac then return facilitySpots end
    appendFacilitySpotCollection(facilitySpots, seen, fac.loanerTrailerSpots)
    appendFacilitySpotCollection(facilitySpots, seen, fac.dropOffSpots)
    appendFacilitySpotCollection(facilitySpots, seen, fac.loanerNonTrailerSpots)
    appendFacilitySpotCollection(facilitySpots, seen, fac.inspectSpots)
    appendFacilitySpotCollection(facilitySpots, seen, fac.pickUpSpots)
    if freeroam_facilities and freeroam_facilities.getParkingSpotsForFacility then
        for _, spot in ipairs(freeroam_facilities.getParkingSpotsForFacility(fac) or {}) do
            appendUniqueFacilitySpot(facilitySpots, seen, spot)
        end
    end
    return facilitySpots
end

-- Company employment: return recovered vehicles to the employer yard, not a dealership.
function VehicleRepoJob:selectEmploymentDelivery()
    self.deliveryLocation = nil
    self:releaseDeliveryReservation()

    local facId = self.employmentHomeFacId
    local fac = getEmploymentDeliveryFacility(facId)
    if not fac then
        log("W", "repo", string.format("Employment delivery facility not found: %s", tostring(facId)))
        return
    end

    local yardName = self.employmentDeliveryLabel or fac.name or fac.id or "the company yard"
    self.employmentDeliveryLabel = yardName
    self.selectedDealership = { id = facId, name = yardName }

    local facilitySpots, seen = {}, {}
    appendFacilitySpotCollection(facilitySpots, seen, fac.inspectSpots)
    for _, ap in pairs(fac.accessPointsByName or {}) do
        if ap.isInspectSpot and ap.ps then
            appendUniqueFacilitySpot(facilitySpots, seen, ap.ps)
        end
    end
    if not facilitySpots[1] then
        log("W", "repo", string.format("No parking spots on employer facility '%s' (%s)", tostring(yardName), tostring(facId)))
        return
    end

    local spotLists = {facilitySpots}

    for _, spots in ipairs(spotLists) do
        local liveDeliverySpot = parkingReservation.findReservableSpot(parkingReservation.shuffleSpots(spots), self.reservationToken)
        if liveDeliverySpot then
            self.deliveryLocation = liveDeliverySpot
            self.reservedDeliverySpot = liveDeliverySpot
            log("I", "repo", string.format("Employment dropoff at '%s' (%s)", tostring(yardName), tostring(facId)))
            return
        end
        local staticDeliverySpot = pickStaticFacilitySpot(spots)
        if staticDeliverySpot then
            self.deliveryLocation = staticDeliverySpot
            self.reservedDeliverySpot = nil
            log("I", "repo", string.format("Using static employer dropoff for '%s' (%s)", tostring(yardName), tostring(facId)))
            return
        end
    end

    log("W", "repo", string.format("No dropoff spot found at employer '%s' (%s)", tostring(yardName), tostring(facId)))
end

-- Partner-yard pickup for company haul (no city-wide distance gates).
function VehicleRepoJob:selectEmploymentPickup()
    self.validSpots = {}
    local facId = self.employmentPickupFacId
    if not facId then return false end
    local fac = getEmploymentDeliveryFacility(facId)
    if not fac then
        log("W", "repo", string.format("Employment pickup facility not found: %s", tostring(facId)))
        return false
    end

    local facilitySpots = collectEmploymentDeliverySpots(fac)
    if not facilitySpots[1] then
        log("W", "repo", string.format("No parking spots on pickup facility '%s'", tostring(facId)))
        return false
    end

    local preferred, fallback = {}, {}
    for _, spot in ipairs(facilitySpots) do
        local path = string.lower(tostring((spot.getPath and spot:getPath()) or spot.psPath or spot.name or ""))
        if path:find("trailer", 1, true) or path:find("loaner", 1, true) or path:find("garage_trailer", 1, true) then
            table.insert(preferred, spot)
        else
            table.insert(fallback, spot)
        end
    end
    if #preferred > 0 then
        self.validSpots = preferred
    elseif #fallback > 0 then
        self.validSpots = fallback
    else
        self.validSpots = facilitySpots
    end

    local yardName = self.employmentPickupLabel or fac.name or fac.id or "partner yard"
    self.employmentPickupLabel = yardName
    log("I", "repo", string.format("Employment pickup at '%s' (%s) with %d spots", tostring(yardName), tostring(facId), #self.validSpots))
    return #self.validSpots > 0
end

function VehicleRepoJob:buildEmploymentVehiclePool()
    self.employmentVehicleCandidates = {}
    self.eligibleVehicles = configListGenerator.getEligibleVehicles(false, false) or {}
    local facilities = freeroam_facilities.getFacilities(getCurrentLevelIdentifier())
    local dealerships = facilities and facilities.dealerships or {}
    local seen = {}

    for _, dealership in ipairs(dealerships) do
        local candidates = getEligibleRepoVehiclesForDealership(dealership, self.eligibleVehicles)
        for _, candidate in ipairs(candidates or {}) do
            local key = candidate.key or candidate.model_key or (candidate.model and candidate.config and (candidate.model .. "/" .. candidate.config))
            if key and not seen[key] then
                seen[key] = true
                table.insert(self.employmentVehicleCandidates, candidate)
            end
        end
    end
end

-- Determine the delivery location
function VehicleRepoJob:determineDeliveryLocation()
    self.deliveryLocation = nil
    self:releaseDeliveryReservation()

    local dealerships = self.availableDealerships or (self.selectedDealership and {self.selectedDealership} or {})
    for _, dealership in ipairs(dealerships) do
        local facilitySpots = dealership.repoProvider and collectEmploymentDeliverySpots(dealership)
            or freeroam_facilities.getParkingSpotsForFacility(dealership) or {}
        local liveDeliverySpot = parkingReservation.findReservableSpot(parkingReservation.shuffleSpots(facilitySpots), self.reservationToken)
        if liveDeliverySpot then
            self.selectedDealership = dealership
            self.deliveryLocation = liveDeliverySpot
            self.reservedDeliverySpot = liveDeliverySpot
            return
        end

        -- Some facility site spots are not present in the live parking pool, so reservation can fail
        -- even though the facility has a valid dropoff location. Use a static site spot as a fallback.
        local staticDeliverySpot = pickStaticFacilitySpot(facilitySpots)
        if staticDeliverySpot then
            self.selectedDealership = dealership
            self.deliveryLocation = staticDeliverySpot
            self.reservedDeliverySpot = nil
            log("W", "repo", string.format("Using unreserved static dropoff spot for dealership '%s'", tostring(dealership.name)))
            return
        end

        log("I", "repo", string.format("Rerolling dealership '%s'; no reservable dropoff spot found", tostring(dealership.name)))
    end
end

-- Filter valid parking spots based on distance criteria
function VehicleRepoJob:filterValidSpots()
    self.validSpots = {}
    for _, spot in pairs(self.parkingSpots.objects) do
        if spot.pos then
            local distanceFromPlayer = (spot.pos - self.playerPosition):length()
            local distanceFromDestination = (spot.pos - self.deliveryLocation.pos):length()
            if distanceFromPlayer >= 300 and distanceFromDestination >= 600 then
                table.insert(self.validSpots, spot)
            end
        end
    end
end

-- Select a random valid parking spot
function VehicleRepoJob:selectRandomSpot()
    self.selectedSpot = nil
    self:releasePickupReservation()

    if #self.validSpots == 0 then
        return
    end

    local livePickupSpot = parkingReservation.findReservableSpot(parkingReservation.shuffleSpots(self.validSpots), self.reservationToken)
    if livePickupSpot then
        self.selectedSpot = livePickupSpot
        self.reservedPickupSpot = livePickupSpot
        return
    end
    if self.employmentMode and self.employmentPickupFacId then
        local staticPickupSpot = pickStaticFacilitySpot(self.validSpots)
        if staticPickupSpot then
            self.selectedSpot = staticPickupSpot
            self.reservedPickupSpot = nil
        end
    end
end

-- Generate vehicle configuration
function VehicleRepoJob:generateVehicleConfig()
    local selectedVehicleInfo
    if self.employmentMode then
        selectedVehicleInfo = pickWeightedRepoVehicleInfo(self.employmentVehicleCandidates)
    else
        local dealershipId = self.selectedDealership and self.selectedDealership.id
        local dealershipCandidates = dealershipId and self.eligibleRepoVehiclesByDealership and self.eligibleRepoVehiclesByDealership[dealershipId] or nil
        selectedVehicleInfo = pickWeightedRepoVehicleInfo(dealershipCandidates)
        if not selectedVehicleInfo then
            log("W", "repo", string.format("Selected dealership '%s' had no unlocked repo candidates during vehicle generation", tostring(self.selectedDealership and self.selectedDealership.name)))
            return
        end
    end
    if not selectedVehicleInfo then
        if self.employmentMode then
            log("W", "repo", "No unlocked repo candidates for company pickup assignment")
        end
        return
    end

    self.randomVehicleInfo = selectedVehicleInfo
    self.vehicleConfig = self.randomVehicleInfo.key
    self.repoTag = self.randomVehicleInfo.repoTag
    self.repoTierLabel = self.randomVehicleInfo.repoTierLabel

    local aggregates = type(self.randomVehicleInfo.aggregates) == "table" and self.randomVehicleInfo.aggregates or {}
    local years = self.randomVehicleInfo.Years or aggregates.Years
    self.randomVehicleInfo.year = years and math.random(years.min, years.max) or 2023

    local filter = self.randomVehicleInfo.filter or {}
    if filter.whiteList and filter.whiteList.Mileage then
        self.randomVehicleInfo.Mileage = math.random(filter.whiteList.Mileage.min, filter.whiteList.Mileage.max)
    else
        self.randomVehicleInfo.Mileage = 0
    end

    if career_career.isActive() then
        self.vehicleValue = career_modules_valueCalculator.getVehicleCatalogIntrinsicBookValue({
            catalogBaseValue = self.randomVehicleInfo.Value,
            mileageMeters = self.randomVehicleInfo.Mileage,
            age = 2025 - self.randomVehicleInfo.year,
            modelName = self.randomVehicleInfo.model_key,
            configKey = self.randomVehicleInfo.key,
            logContext = "repo",
            applyVehicleBuyMarket = false
        }) or career_modules_valueCalculator.getAdjustedVehicleBaseValue(self.randomVehicleInfo.Value, {
            mileage = self.randomVehicleInfo.Mileage,
            age = 2025 - self.randomVehicleInfo.year
        })
    end

    local data = buildRepoStateData(self)
    guihooks.trigger('updateRepoState', data)
end

local function isFactoryPaint(paint, paintName)
    if type(paintName) ~= "string" or paintName == "" or paintName == "(Custom)" then
        return false
    end
    if type(paint) ~= "table" then
        return false
    end
    return paint.class ~= "custom"
end

local function pickRepoSpawnPaint(modelKey, configKey)
    if not modelKey or not core_vehicles or not core_vehicles.getModel then
        return nil, nil
    end
    local modelData = core_vehicles.getModel(modelKey)
    local modelPaints = modelData and modelData.model and modelData.model.paints
    if type(modelPaints) ~= "table" then
        return nil, nil
    end

    if core_vehiclePaints and core_vehiclePaints.getRandomPaints then
        for _ = 1, 8 do
            local paintResult = core_vehiclePaints.getRandomPaints(modelKey, configKey)
            local name = paintResult and paintResult.paintName1
            local named = name and modelPaints[name]
            if isFactoryPaint(named, name) then
                return tostring(name), deepcopy(named)
            end
        end
    end

    local factoryNames = {}
    for name, paint in pairs(modelPaints) do
        if isFactoryPaint(paint, name) then
            factoryNames[#factoryNames + 1] = name
        end
    end
    if factoryNames[1] then
        local name = factoryNames[math.random(#factoryNames)]
        return tostring(name), deepcopy(modelPaints[name])
    end
    return nil, nil
end

local function formatRepoVehicleDisplayName(instance)
    local info = instance and (instance.vehInfo or instance.randomVehicleInfo) or nil
    local vehicleName = ""
    if info then
        vehicleName = ((info.Brand or "") .. " " .. (info.Name or "")):gsub("^%s+", ""):gsub("%s+$", "")
        if vehicleName == "" then
            vehicleName = tostring(info.Name or info.model_key or "vehicle")
        end
    else
        vehicleName = "vehicle"
    end
    local color = instance and instance.paintName
    if type(color) ~= "string" or color == "" or color == "(Custom)" then
        color = "unknown color"
    end
    return tostring(color) .. " " .. vehicleName
end

-- Spawn the vehicle at the selected spot
function VehicleRepoJob:spawnVehicle()
    local paintName, paint = pickRepoSpawnPaint(self.randomVehicleInfo.model_key, self.vehicleConfig)
    self.paintName = paintName
    local spawnOptions = {
        config = self.vehicleConfig,
        autoEnterVehicle = false,
        pos = self.selectedSpot.pos,
        rot = self.selectedSpot.rot or quat(0, 0, 0, 1),
        cling = true,
        electrics = {
            parkingbrake = 0
        }
    }
    if paintName and paint then
        spawnOptions.paint = paint
        spawnOptions.paintName = paintName
    end

    local newVehicle = core_vehicles.spawnNewVehicle(self.randomVehicleInfo.model_key, spawnOptions)
    if not newVehicle then
        return
    end

    self.vehicleId = newVehicle:getID()
    if paintName and core_vehicle_manager and core_vehicle_manager.setVehiclePaintsNames then
        core_vehicle_manager.setVehiclePaintsNames(self.vehicleId, {paintName, paintName, paintName})
    end
    self.pickupLocation = self.selectedSpot.pos
    self.isMonitoring = true

    core_groundMarkers.setPath(self.selectedSpot.pos, {clearPathOnReachingTarget = true})
    self.totalDistanceTraveled = core_groundMarkers.getPathLength()

    self.vehInfo = self.randomVehicleInfo
    if not self.employmentMode then
        ui_message("New Repo Job Available!\nSomeone missed a payment on their \n" .. self.randomVehicleInfo.Brand .. " " ..
                       self.randomVehicleInfo.Name .. ".\nPick it up for a reward.", 10, "New Job", "info")
    end
end

-- Handle vehicle switch events
function VehicleRepoJob:onVehicleSwitched(oldId, newId)
    self.repoVehicle = getObjectByID(newId)
    self.repoVehicleID = newId
    if self.employmentMode then
        return
    end
    if not self.isJobStarted then
        self:destroy()
        self:generateJob()
    end
end

-- Calculate the reward for completing the job
function VehicleRepoJob:calculateReward()
    if not career_career.isActive() then
        return nil
    end
    local elapsedSeconds = math.max(1, os.time() - (self.jobStartTime or os.time()))
    local distanceMultiplier = self.totalDistanceTraveled * 2
    local timeMultiplier = (self.totalDistanceTraveled / (elapsedSeconds * 10))
    local rewardFoundation = math.floor((((5 * math.sqrt(self.vehicleValue or 1000)) + distanceMultiplier) * timeMultiplier)/ 4) / 15
    local baseReward = (rewardFoundation * 1.25) + 1000
    local payoutRewardBase = rewardFoundation + 500
    local repoTagData = getRepoTagData(self.repoTag) or {}
    local repoSkillLevel = getRepoSkillLevel()
    local repoPayoutBonusPercent = getRepoPayoutBonusPercent(repoSkillLevel)
    local categoryMultiplier = tonumber(repoTagData.payMultiplier) or 1
    local payoutBase = math.floor((payoutRewardBase * categoryMultiplier * (1 + repoPayoutBonusPercent)) + 0.5)

    print("Base repo reward: " .. payoutBase)

    -- Apply economy adjuster if available
    local adjustedReward = payoutBase
    local repoMultiplier = 1.0
    if career_economyAdjuster then
        -- Use repo type multiplier for repo jobs
        repoMultiplier = career_economyAdjuster.getSectionMultiplier("repo") or 1.0
        adjustedReward = payoutBase * repoMultiplier
        adjustedReward = math.floor(adjustedReward + 0.5) -- Round to nearest integer
        print("Adjusted repo reward: " .. adjustedReward .. " (multiplier: " .. string.format("%.2f", repoMultiplier) .. ")")
    end

    -- Fallback for reward calculation paths where repo economy multiplier was not applied yet.
    if not career_economyAdjuster and career_modules_difficultyMode
        and career_modules_difficultyMode.isDifficultyActive
        and career_modules_difficultyMode.isDifficultyActive()
        and career_modules_difficultyMode.getRewardMultiplier then
        local difficultyMultiplier = tonumber(career_modules_difficultyMode.getRewardMultiplier()) or 1.0
        adjustedReward = math.floor((adjustedReward * difficultyMultiplier) + 0.5)
    end

    return adjustedReward, baseReward, repoMultiplier
end



-- Update function called every frame
function VehicleRepoJob:isEmploymentHeld()
    local employment = career_modules_delivery_employment
    return self.employmentMode and employment and employment.isOnShift
        and not employment.isOnShift() or false
end

local function employmentCargoOnFlatbed(job)
    if not job or not job.employmentMode or not job.vehicleId or not job.repoVehicleID then
        return false
    end
    local vt = career_modules_delivery_vehicleTasks
    if vt and vt.isCargoOnHaulerBed then
        return vt.isCargoOnHaulerBed(job.vehicleId, job.repoVehicleID) and true or false
    end
    return false
end

local function notifyEmploymentRepoHud()
    local emp = career_modules_delivery_employment
    if emp and emp.refreshHudTasklist then
        emp.refreshHudTasklist(true)
    end
end

function VehicleRepoJob:onUpdate(dtReal, dtSim, dtRaw) 
    if self:isEmploymentHeld() then
        if not self.employmentMarkerHeld then
            clearRepoDeliveryMarker()
            self.employmentMarkerHeld = true
        end
        return
    end
    if self.employmentMarkerHeld then
        self.employmentMarkerHeld = nil
        if self.isMonitoring and self.isJobStarted and self.deliveryLocation then
            if not self.employmentMode then
                createMarker(self.deliveryLocation.pos)
            end
            if core_groundMarkers and core_groundMarkers.setPath then
                core_groundMarkers.setPath(self.deliveryLocation.pos, {clearPathOnReachingTarget = true})
            end
        end
    end
    -- Add timer for distance checks
    if not self.updateTimer then self.updateTimer = 0 end
    self.updateTimer = self.updateTimer + dtSim
    if not self.uiStateUpdateTimer then self.uiStateUpdateTimer = 0 end
    self.uiStateUpdateTimer = self.uiStateUpdateTimer + dtSim
    
    if self.jobCoroutine and coroutine.status(self.jobCoroutine) ~= "dead" then
        local success, message = coroutine.resume(self.jobCoroutine)
        if not success then
            log("E", "repo", string.format("Repo generation coroutine failed: %s", tostring(message)))
            self.jobCoroutine = nil
            abortRepoGeneration(self)
            return
        end
    end

    if self.uiStateUpdateTimer >= 0.5 then
        self.uiStateUpdateTimer = 0
        if (self.jobCoroutine and coroutine.status(self.jobCoroutine) ~= "dead") or self.isMonitoring or self.isCompleted then
            guihooks.trigger('updateRepoState', buildRepoStateData(self))
        end
    end

    if not self.isMonitoring or not self.vehicleId then
        return
    end

    -- Check if vehicle still exists, reset if it doesn't
    if not self:checkVehicleExists() then
        return
    end

    -- Only do distance checks once per second
    if self.updateTimer < 1 then
        return
    end

    -- Reset timer after checks
    self.updateTimer = 0

    local playerVehicle = be:getPlayerVehicle(0)
    if not playerVehicle then
        return
    end

    local playerPos = playerVehicle:getPosition()
    local vehicle = getObjectByID(self.vehicleId)
    if not vehicle then
        self:resetToInitialState()
        return
    end

    local vehiclePos
    local success, pos = pcall(function() return vehicle:getPosition() end)
    if not success or not pos then
        self:resetToInitialState()
        return
    end
    vehiclePos = pos
    
    local repoPos
    local distance
    
    local repoVehicle = self.repoVehicleID and getObjectByID(self.repoVehicleID)
    if not repoVehicle then
        self.repoVehicleID = nil
        self.repoVehicle = nil
        if self.vehicleId then
            local vehicle = getObjectByID(self.vehicleId)
            if vehicle then
                pcall(function() vehicle:delete() end)
            end
        end
        if core_groundMarkers then
            core_groundMarkers.resetAll()
        end
        ui_message("Your Repo Vehicle has been removed.\nYou have lost your job.", 10, "info", "info")
        self:resetToInitialState()
        return
    end
    
    local repoPosSuccess, repoPosResult = pcall(function() return repoVehicle:getPosition() end)
    if not repoPosSuccess or not repoPosResult then
        self:resetToInitialState()
        return
    end
    repoPos = repoPosResult
    distance = (vehiclePos - repoPos):length()

    if not self.isJobStarted then
        if distance <= 20 then
            if self.employmentMode then
                if not self.employmentPickupPrepared then
                    self.employmentPickupPrepared = true
                    local dropName = self.employmentDeliveryLabel or (self.selectedDealership and self.selectedDealership.name) or "the yard"
                    ui_message(string.format("Load the %s %s.\nHaul it back to %s.",
                        self.vehInfo.Brand, self.vehInfo.Name, dropName), 10, "info", "info")
                    local vehicle = getObjectByID(self.vehicleId)
                    if vehicle then
                        pcall(function() vehicle:queueLuaCommand('input.event("parkingbrake", 1, "FILTER_DI", nil, nil, nil, nil)') end)
                    end
                    gameplay_traffic.insertTraffic(self.vehicleId, true)
                    local trafficVehicle = gameplay_traffic.getTrafficData()[self.vehicleId]
                    if trafficVehicle then
                        trafficVehicle:setRole("empty")
                    end
                end
            else
                self.isJobStarted = true
                local dropName = self.employmentDeliveryLabel or (self.selectedDealership and self.selectedDealership.name) or "the yard"
                local pickupMsg = string.format("Pick up the %s %s.\nPlease drive it to %s.",
                    self.vehInfo.Brand, self.vehInfo.Name, dropName)
                ui_message(pickupMsg, 10, "info", "info")
                local vehicle = getObjectByID(self.vehicleId)
                if vehicle then
                    local success = pcall(function() vehicle:queueLuaCommand('input.event("parkingbrake", 1, "FILTER_DI", nil, nil, nil, nil)') end)
                    if not success then
                        self:resetToInitialState()
                        return
                    end
                end

                -- First insert the vehicle into traffic system
                gameplay_traffic.insertTraffic(self.vehicleId, true) -- true means ignore AI control

                -- Now we can get and modify the traffic vehicle
                local trafficVehicle = gameplay_traffic.getTrafficData()[self.vehicleId]
                if trafficVehicle then
                    trafficVehicle:setRole("empty")
                    print("Set vehicle role to empty")
                else
                    print("No traffic vehicle found")
                end
                createMarker(self.deliveryLocation.pos)
                core_groundMarkers.setPath(self.deliveryLocation.pos, {clearPathOnReachingTarget = true})
            end
        end
        if self.employmentMode and employmentCargoOnFlatbed(self) then
            self.isJobStarted = true
            self.employmentPickupPrepared = true
            local dropName = self.employmentDeliveryLabel or (self.selectedDealership and self.selectedDealership.name) or "the yard"
            ui_message(string.format("Vehicle loaded.\nHaul it back to %s.", dropName), 8, "info", "info")
            core_groundMarkers.setPath(self.deliveryLocation.pos, {clearPathOnReachingTarget = true})
            notifyEmploymentRepoHud()
        end
        local repoDistance = (playerPos - repoPos):length()
        if repoDistance > 90 and repoDistance < 100 then
            ui_message("You have driven too far from Your Repo Vehicle.\nPlease return to it.", 10, "info", "info")
        elseif repoDistance > 100 and not self.employmentMode then
            if not self.returnCountdown then
                self.returnCountdown = 10
            else
                ui_message("You have " .. math.floor(self.returnCountdown) .. " seconds to return to your Repo Vehicle.", 1, "info", "info")
                self.returnCountdown = self.returnCountdown - 1 -- Changed from dtSim to 1 since we're updating once per second
                if self.returnCountdown <= 0 then
                    ui_message("Someone else has picked up the " .. self.vehInfo.Brand .. " " .. self.vehInfo.Name .. ".", 10, "info", "info")
                    self:resetToInitialState()
                    return
                end
            end
        else
            if self.returnCountdown then
                ui_message("You have returned to your Repo Vehicle.", 3, "info", "info")
                self.returnCountdown = nil
                local vehicle = getObjectByID(self.vehicleId)
                if vehicle then
                    local success, pos = pcall(function() return vehicle:getPosition() end)
                    if success and pos then
                        core_groundMarkers.setPath(pos, {clearPathOnReachingTarget = true})
                    end
                end
                self.isJobStarted = false
            end
        end
    else
        if self.employmentMode and not employmentCargoOnFlatbed(self) then
            self.isJobStarted = false
            self.jobStartTime = nil
            local vehicle = getObjectByID(self.vehicleId)
            if vehicle then
                local success, pos = pcall(function() return vehicle:getPosition() end)
                if success and pos then
                    core_groundMarkers.setPath(pos, {clearPathOnReachingTarget = true})
                end
            end
            notifyEmploymentRepoHud()
        elseif distance > 90 and distance < 100 then
            ui_message("You have driven too far from the " .. self.vehInfo.Brand .. " " .. self.vehInfo.Name .. ".\nPlease return it to the parking spot.", 10, "info", "info")
        elseif distance > 100 and not self.employmentMode then
            if not self.returnCountdown then
                self.returnCountdown = 10
            else
                ui_message("You have " .. math.floor(self.returnCountdown) .. " seconds to return the  " .. self.vehInfo.Brand .. " " .. self.vehInfo.Name .. ".", 1, "info", "info")
                self.returnCountdown = self.returnCountdown - 1 -- Changed from dtSim to 1 since we're updating once per second
                if self.returnCountdown <= 0 then
                    ui_message("Someone else has picked up the " .. self.vehInfo.Brand .. " " .. self.vehInfo.Name .. ".", 10, "info", "info")
                    self:resetToInitialState()
                    return
                end
            end
        else
            if self.returnCountdown then
                ui_message("You have returned to the " .. self.vehInfo.Brand .. " " .. self.vehInfo.Name .. ".", 3, "info", "info")
                self.returnCountdown = nil
                local vehicle = getObjectByID(self.vehicleId)
                if vehicle then
                    local success, pos = pcall(function() return vehicle:getPosition() end)
                    if success and pos then
                        core_groundMarkers.setPath(pos, {clearPathOnReachingTarget = true})
                    end
                end
                self.isJobStarted = false
            end
        end
    end

    if self.jobStartTime then
        local vehicle = getObjectByID(self.vehicleId)
        if not vehicle then
            self:resetToInitialState()
            return
        end
        
        local success, pos = pcall(function() return vehicle:getPosition() end)
        if not success or not pos then
            self:resetToInitialState()
            return
        end
        vehiclePos = pos
        
        local distanceFromDestination = (vehiclePos - self.deliveryLocation.pos):length()
        local velSuccess, vel = pcall(function() return vehicle:getVelocity():length() end)
        if not velSuccess or not vel then
            self:resetToInitialState()
            return
        end
        local velocity = vel
        
        local completionDistance = self.employmentMode and 8 or 3
        local completionSpeed = self.employmentMode and 0.35 or 1
        if distanceFromDestination <= completionDistance and velocity <= completionSpeed then
            if self.isCompleting then return end
            self.isCompleting = true
            core_jobsystem.create(function(job)
              local self = job.args[1]

              -- Never yield inside pcall — LuaJIT cannot yield across a protected call.
              -- That was aborting after the fade ("blink") with the car still on the truck
              -- and the employment complete callback never firing.
              if ui_fadeScreen and ui_fadeScreen.start then
                ui_fadeScreen.start(completionFadeDuration)
              end
              job.sleep(completionFadeDuration)

              if self:isEmploymentHeld() then
                self.isCompleting = false
                if ui_fadeScreen and ui_fadeScreen.stop then ui_fadeScreen.stop(completionFadeDuration) end
                return
              end

              local deliveredId = self.vehicleId
              local repoId = self.repoVehicleID

              if deliveredId and repoId and be:getPlayerVehicleID(0) == deliveredId then
                switchPlayerToRepoVehicle(repoId)
                job.sleep(0.1)
              end

              local reward, baseReward = self:calculateReward()
              local vehInfo = self.vehInfo or {}
              local vehicleName = ((vehInfo.Brand or "") .. " " .. (vehInfo.Name or "")):gsub("^%s+", ""):gsub("%s+$", "")
              if vehicleName == "" then vehicleName = "vehicle" end
              local yardName = self.employmentDeliveryLabel or (self.selectedDealership and self.selectedDealership.name) or "the company yard"
              local rewardText
              if self.employmentMode then
                rewardText = string.format("Returned the %s to %s.", vehicleName, yardName)
              else
                rewardText = "You've Dropped Off a " .. vehicleName .. "."
                if reward then
                  rewardText = rewardText .. "\nYou have been paid $" .. tostring(reward)
                end
              end

              local paidMoney = tonumber(reward) or 0
              local completionMeta = {
                skillXp = 0,
                repoTag = self.repoTag,
                repoTierLabel = self.repoTierLabel,
                vehicleLabel = vehicleName,
              }

              if career_career and career_career.isActive and career_career.isActive() and reward then
                local repoTagData = getRepoTagData(self.repoTag) or {}
                local repoSkillXp = math.max(1, math.floor((5 + (tonumber(repoTagData.baseXp) or 0) + math.floor(((self.totalDistanceTraveled or 0) / 2000) + 0.5)) * 2 + 0.5))
                completionMeta.skillXp = repoSkillXp
                local rewardData = {
                  money = { amount = reward },
                  [REPO_SKILL_ATTRIBUTE_KEY] = { amount = repoSkillXp }
                }
                if career_modules_difficultyMode and career_modules_difficultyMode.scalePaymentRewardData then
                  career_modules_difficultyMode.scalePaymentRewardData(rewardData, {includeMoney = false})
                end
                paidMoney = (rewardData.money and rewardData.money.amount) or reward
                if not self.employmentMode then
                  local repoBonusPercent = getRepoPayoutBonusPercent(getRepoSkillLevel())
                  local repoBonusText = math.floor(repoBonusPercent * 100 + 0.5)
                  rewardText = "You've Dropped Off a " .. vehicleName .. ".\nYou have been paid $" .. paidMoney
                  if career_modules_activityHeat and career_modules_activityHeat.formatSurgeBonusText then
                    rewardText = rewardText .. career_modules_activityHeat.formatSurgeBonusText("repo")
                  end
                  if self.repoTierLabel and self.repoTierLabel ~= "" then
                    rewardText = rewardText .. "\nTier: " .. self.repoTierLabel
                  end
                  if repoBonusText > 0 then
                    rewardText = rewardText .. "\nRepo Skill Bonus: +" .. repoBonusText .. "%"
                  end
                  career_modules_payment.reward(rewardData, {
                    label = rewardText,
                    tags = {"gameplay", "reward", "repo", "recovery"}
                  }, true)
                end
              end

              -- Employment bookkeeping must run even if save/payment side effects fail.
              if self.employmentMode then
                local onComplete = self.employmentOnComplete
                self.employmentOnComplete = nil
                self.employmentOnAbort = nil
                local cbOk, cbErr = pcall(function()
                  if onComplete then
                    onComplete(paidMoney, completionMeta)
                  elseif career_modules_delivery_employment and career_modules_delivery_employment.onRepoDeliveryComplete then
                    career_modules_delivery_employment.onRepoDeliveryComplete(paidMoney, completionMeta)
                  else
                    log("W", "repo", "Employment repo completed without employment callback")
                  end
                end)
                if not cbOk then
                  log("E", "repo", string.format("Employment repo callback failed: %s", tostring(cbErr)))
                end
              end

              if career_career and career_career.isActive and career_career.isActive() and reward then
                local saveOk, saveErr = pcall(function()
                  if career_saveSystem and career_saveSystem.saveCurrent then
                    career_saveSystem.saveCurrent()
                  end
                  if not self.employmentMode
                      and career_modules_inventory
                      and career_modules_inventory.addRepossession
                      and career_modules_inventory.getInventoryIdFromVehicleId then
                    local invId = career_modules_inventory.getInventoryIdFromVehicleId(repoId)
                    if invId then
                      career_modules_inventory.addRepossession(invId)
                    end
                  end
                end)
                if not saveOk then
                  log("W", "repo", string.format("Repo post-completion save failed: %s", tostring(saveErr)))
                end
              end

              self.reward = reward
              local finOk, finErr = pcall(finalizeRepoDelivery, self, deliveredId, repoId, rewardText)
              if not finOk then
                log("E", "repo", string.format("Repo finalize failed: %s", tostring(finErr)))
                clearRepoDeliveryMarker()
                self.isCompleted = true
                self.isMonitoring = false
                self.isJobStarted = false
              end

              self.isCompleting = false
              stopFadeSafe()
            end, 1, self)
        elseif distanceFromDestination <= 10 then
            if self.employmentMode then
                ui_message("You're at the company yard.\nPark the vehicle in the marked stall.", 10, "info", "info")
            else
                ui_message("You've arrived at the dealership.\nPlease return the vehicle to the parking spot.", 10, "info", "info")
            end
        else
            if self.deliveryLocation then
                print("Delivery location: " .. tostring(self.deliveryLocation.pos))
                if core_groundMarkers then
                    print("Core ground markers target pos: " .. tostring(core_groundMarkers.getTargetPos()))
                else
                    print("Core ground markers not found")
                end
            end
            if self.deliveryLocation.pos ~= nil and (not core_groundMarkers.getTargetPos() or core_groundMarkers.getTargetPos() ~= self.deliveryLocation.pos) then
                core_groundMarkers.setPath(self.deliveryLocation.pos, {clearPathOnReachingTarget = true})
            end
        end
    end

    if self.jobStartTime and playerVehicle:getID() == self.vehicleId then
        if distance > 50 then
            local vehicle = getObjectByID(self.vehicleId)
            if vehicle then
                local success = pcall(function() vehicle:queueLuaCommand([[
                if electrics.values.ignition then
                  electrics.setIgnitionLevel(0)
                end
              ]]) end)
                if not success then
                    self:resetToInitialState()
                    return
                end
            end
        end
    end

    if distance <= 15 and not self.jobStartTime then
        if not (self.employmentMode and not employmentCargoOnFlatbed(self)) then
            local vehicle = getObjectByID(self.vehicleId)
            if vehicle then
                local velSuccess, vel = pcall(function() return vehicle:getVelocity():length() end)
                if velSuccess and vel and vel > 2 then
                    self.jobStartTime = os.time()
                    self:releasePickupReservation()
                    core_groundMarkers.setPath(self.deliveryLocation.pos, {clearPathOnReachingTarget = true})
                    self.totalDistanceTraveled = self.totalDistanceTraveled + core_groundMarkers.getPathLength()
                end
            end
        end
    end
end

function VehicleRepoJob:completeJob()
    self:destroy()
end

local function onVehicleSwitched(oldId, newId)
  local instance = M.getRepoJobInstance()
  if not instance then return end

  -- If we finished a delivery while still inside the delivered vehicle, delete it once the player left it.
  if instance.pendingDeliveredDeleteId and oldId == instance.pendingDeliveredDeleteId and newId ~= instance.pendingDeliveredDeleteId then
    local deliveredId = instance.pendingDeliveredDeleteId
    instance.pendingDeliveredDeleteId = nil
    if gameplay_traffic then
      pcall(function() gameplay_traffic.removeTraffic(deliveredId) end)
    end
    local v = getObjectByID(deliveredId)
    if v then
      pcall(function() core_vehicleBridge.executeAction(v, 'setFreeze', true) end)
      pcall(function() v:delete() end)
    end
    if instance.vehicleId == deliveredId then
      instance.vehicleId = nil
    end
  end
end

-- Get the current repo job instance
function M.getRepoJobInstance()
    if not repoJobInstance then
        repoJobInstance = VehicleRepoJob:new()
    end
    return repoJobInstance
end

-- Generate a new repo job (called from playerDriving)
function M.generateJob()
    if isOnEmploymentShift() then
        ui_message("Clock out before taking independent repo jobs.", 10, "info", "info")
        return
    end
    local instance = M.getRepoJobInstance()
    if not M.isRepoVehicle() then
        ui_message("You must be in a vehicle to generate a repo job.", 10, "info", "info")
        return
    end
    
    if instance and M.isRepoVehicle() then
        instance.employmentMode = false
        instance.employmentOnComplete = nil
        instance.employmentOnAbort = nil
        instance.repoVehicle = be:getPlayerVehicle(0)
        instance.repoVehicleID = be:getPlayerVehicle(0):getID()
        instance:generateJob()
    end
end

function M.startEmploymentJob(onComplete, onAbort, opts)
    local disabled, reason = isRepoDisabled()
    if disabled then
        if onAbort then
            onAbort(reason, true)
        end
        return false
    end
    if not isPlayerInCompanyRepoTruck() then
        if onAbort then
            onAbort("Get in the company truck first.")
        end
        return false
    end

    opts = type(opts) == "table" and opts or {}
    local instance = M.getRepoJobInstance()
    -- Re-entering the flatbed must not wipe an in-progress company haul.
    if instance.employmentMode and M.isEmploymentRepoActive() then
        instance.employmentOnComplete = onComplete or instance.employmentOnComplete
        instance.employmentOnAbort = onAbort or instance.employmentOnAbort
        if opts.homeFacId or opts.facId then
            instance.employmentHomeFacId = opts.homeFacId or opts.facId
        end
        if opts.deliveryLabel or opts.yardName then
            instance.employmentDeliveryLabel = opts.deliveryLabel or opts.yardName
        end
        if opts.pickupFacId then
            instance.employmentPickupFacId = opts.pickupFacId
        end
        if opts.pickupLabel then
            instance.employmentPickupLabel = opts.pickupLabel
        end
        instance.repoVehicle = be:getPlayerVehicle(0)
        instance.repoVehicleID = be:getPlayerVehicle(0):getID()
        return true
    end
    instance.employmentMode = true
    instance.employmentOnComplete = onComplete
    instance.employmentOnAbort = onAbort
    instance.employmentHomeFacId = opts.homeFacId or opts.facId
    instance.employmentDeliveryLabel = opts.deliveryLabel or opts.yardName
    instance.employmentPickupFacId = opts.pickupFacId
    instance.employmentPickupLabel = opts.pickupLabel
    instance.employmentVehicleCandidates = nil
    instance.repoVehicle = be:getPlayerVehicle(0)
    instance.repoVehicleID = be:getPlayerVehicle(0):getID()
    instance:generateJob()
    return true
end

function M.isEmploymentRepoActive()
    local instance = M.getRepoJobInstance()
    if not instance or not instance.employmentMode then
        return false
    end
    if instance.isCompleted or instance.isCompleting then
        return false
    end
    if instance.isMonitoring then
        return true
    end
    if instance.jobCoroutine and coroutine.status(instance.jobCoroutine) ~= "dead" then
        return true
    end
    return false
end

function M.isEmploymentPickupReady()
    local instance = M.getRepoJobInstance()
    if not instance or not instance.employmentMode then
        return false
    end
    if instance.isCompleted or instance.isCompleting then
        return false
    end
    return instance.isMonitoring and instance.vehicleId ~= nil
end

function M.isEmploymentRepoCompleting()
    local instance = M.getRepoJobInstance()
    return instance and instance.employmentMode and instance.isCompleting and true or false
end

function M.getEmploymentTaskGuidance()
    local instance = M.getRepoJobInstance()
    if not instance or not instance.employmentMode then
        return nil
    end
    if instance.jobCoroutine and coroutine.status(instance.jobCoroutine) ~= "dead" then
        return {
            label = "Company pickup loading",
            subtext = "Dispatcher is finding a vehicle",
        }
    end
    if not instance.isMonitoring then
        return nil
    end
    local yard = instance.employmentDeliveryLabel or (instance.selectedDealership and instance.selectedDealership.name) or "the dropoff"
    local pickup = instance.employmentPickupLabel
    local vehicleName = formatRepoVehicleDisplayName(instance)
    if not instance.isJobStarted or not employmentCargoOnFlatbed(instance) then
        return {
            label = "Load the vehicle onto the flatbed",
            subtext = pickup and ("Pick up at " .. pickup) or ("Pick up the " .. vehicleName .. " first"),
        }
    end
    return {
        label = "Haul the vehicle to " .. yard,
        subtext = "Drop off the " .. vehicleName .. " at " .. yard,
    }
end

function M.cancelEmploymentJob()
    local instance = M.getRepoJobInstance()
    if not instance or not instance.employmentMode then
        return false
    end
    instance.employmentOnComplete = nil
    local onAbort = instance.employmentOnAbort
    instance.employmentOnAbort = nil
    instance:destroy()
    if onAbort then
        onAbort("Car haul cancelled.")
    end
    return true
end

-- Update the repo job (called from playerDriving's onUpdate)
function M.onUpdate(dtReal, dtSim, dtRaw)
    local instance = M.getRepoJobInstance()
    if instance then
        instance:onUpdate(dtReal, dtSim, dtRaw)
    end
end

-- Compatibility helper used by the phone UI/state; this now means the player
-- can start repo work from their current vehicle, not that the plate is "repo".
function M.isRepoVehicle()
    local playerVehicle = be:getPlayerVehicle(0)
    return playerVehicle ~= nil
end

function M.isRepoTarget(vehId)
    vehId = tonumber(vehId)
    return vehId ~= nil and repoJobInstance ~= nil and repoJobInstance.vehicleId == vehId
end

function M.requestRepoState()
    local instance = M.getRepoJobInstance()

    if instance then
        if instance.isMonitoring and instance.vehicleId then
            if not instance:checkVehicleExists() then
                instance = M.getRepoJobInstance()
            end
        end
    end
    guihooks.trigger('updateRepoState', buildRepoStateData(instance))
end

function M.cancelJob()
    local instance = M.getRepoJobInstance()
    if instance then
        instance:destroy()
    end
end

function M.completeJob()
    local instance = M.getRepoJobInstance()
    if instance then
        instance:completeJob()
    end
end

-- Export the class
M.VehicleRepoJob = VehicleRepoJob
M.onVehicleSwitched = onVehicleSwitched

return M
