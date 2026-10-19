-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.dependencies = {"util_stepHandler"}

local dateUtils = require('utils/dateUtils')
local facilityRole = require('gameplay/delivery/facilityRole')

local walkAwayRadius = 100
local comeBackRadius = 95
local walkAwayTimeLimit = 300
local walkAwayWarningTime = 60
local RENTAL_SIM_SECONDS_PER_HOUR = 3600
local loanedVehiclesInfo = {}

local function deliveryGameTime()
  return career_modules_delivery_general and career_modules_delivery_general.time
    and career_modules_delivery_general.time() or nil
end

local function deliverySimPaused()
  return career_modules_delivery_general and career_modules_delivery_general.isDeliveryTimePaused
    and career_modules_delivery_general.isDeliveryTimePaused() or false
end

local function rentalBilledSimSeconds(vehInfo)
  if vehInfo.rentalBilledSimSeconds ~= nil then
    return math.max(0, tonumber(vehInfo.rentalBilledSimSeconds) or 0)
  end
  return math.max(0, tonumber(vehInfo.rentalBilledHours) or 0) * RENTAL_SIM_SECONDS_PER_HOUR
end

local function initRentalBilling(vehInfo)
  if not vehInfo then return end
  vehInfo.rentalSimAccrued = tonumber(vehInfo.rentalSimAccrued) or 0
  vehInfo.rentalBilledSimSeconds = rentalBilledSimSeconds(vehInfo)
  vehInfo.rentalLastGameTime = deliveryGameTime()
end

local function accrueRentalSimTime(vehInfo)
  if not vehInfo or vehInfo.loanType ~= "rental" then return 0 end
  if deliverySimPaused() then return 0 end
  local gameTime = deliveryGameTime()
  if not gameTime then return 0 end
  local last = vehInfo.rentalLastGameTime
  if last == nil then
    vehInfo.rentalLastGameTime = gameTime
    return 0
  end
  local delta = gameTime - last
  if delta <= 0 then return 0 end
  vehInfo.rentalLastGameTime = gameTime
  vehInfo.rentalSimAccrued = (tonumber(vehInfo.rentalSimAccrued) or 0) + delta
  return delta
end
local LOANER_UNLOCK_MODE_ORG_REPUTATION = "orgReputation"
local LOANER_UNLOCK_MODE_SKILL_LEVEL = "skillLevel"
local DEFAULT_LOANER_UNLOCK_SKILL_LABEL = "Police Skill"
local DEFAULT_LOANER_UNLOCK_SKILL_ICON = "wigwags"
local DEFAULT_LOANER_UNLOCK_SKILL_PATH_IDS = {"careerSkills-emergency", "emergency"}

local function getBranchLevelByPathIds(pathIds)
  if not career_branches or not career_branches.getBranchLevel then
    return 0
  end

  for _, skillPathId in ipairs(pathIds or {}) do
    -- Assign first; never tonumber(getBranchLevel()) — extra returns become tonumber's base.
    local branchLevel = career_branches.getBranchLevel(skillPathId)
    if branchLevel ~= nil then
      local level = tonumber(branchLevel)
      if level ~= nil then
        return math.max(0, math.floor(level))
      end
    end
  end

  return 0
end

local function getLoanerUnlockMode(organization)
  local mode = organization and organization.loanerUnlockMode
  if mode == LOANER_UNLOCK_MODE_SKILL_LEVEL then
    return LOANER_UNLOCK_MODE_SKILL_LEVEL
  end
  return LOANER_UNLOCK_MODE_ORG_REPUTATION
end

local function getLoanerUnlockSkillPathIds(organization)
  local pathIds = organization and organization.loanerUnlockSkillPathIds
  if type(pathIds) == "table" and #pathIds > 0 then
    return pathIds
  end

  local pathId = organization and organization.loanerUnlockSkillPathId
  if type(pathId) == "string" and pathId ~= "" then
    return {pathId}
  end

  return DEFAULT_LOANER_UNLOCK_SKILL_PATH_IDS
end

local function getLoanerUnlockSkillLevel(organization)
  return getBranchLevelByPathIds(getLoanerUnlockSkillPathIds(organization))
end

local function getLoanerUnlockSkillDisplayData(organization)
  local label = organization and organization.loanerUnlockSkillLabel or DEFAULT_LOANER_UNLOCK_SKILL_LABEL
  local icon = organization and organization.loanerUnlockSkillIcon or DEFAULT_LOANER_UNLOCK_SKILL_ICON
  return label, icon
end

local markedForSpawningLoaners = {}

local function markForSpawning(offer)
  if markedForSpawningLoaners[offer.id] then
    markedForSpawningLoaners[offer.id] = nil
  else
    markedForSpawningLoaners[offer.id] = offer
  end
end
M.markForSpawning = markForSpawning

local function setMarkedForSpawning(offer, marked)
  if not offer or not offer.id then return end
  if marked then
    markedForSpawningLoaners[offer.id] = offer
  else
    markedForSpawningLoaners[offer.id] = nil
  end
end
M.setMarkedForSpawning = setMarkedForSpawning
M.hasMarkedOffers = function() return next(markedForSpawningLoaners) ~= nil end

function M.markCompanyOfferForSpawning(offer, sourceFacilityId, idPrefix)
  if not offer then return end
  offer.loanType = "company"
  if not offer.sourceFacility or not offer.sourceFacility.id then
    if sourceFacilityId then
      offer.sourceFacility = { type = "deliveryProvider", id = sourceFacilityId }
    end
  end
  if not offer.id then
    local facId = offer.sourceFacility and offer.sourceFacility.id or sourceFacilityId or "company"
    offer.id = string.format("%s-%s-%s-%s", idPrefix or "company",
      tostring(facId), tostring(offer.model or "m"), tostring(offer.config or "c"))
  end
  M.setMarkedForSpawning(offer, true)
end

local function unmarkAllForSpawning()
  markedForSpawningLoaners = {}
end
M.unmarkAllForSpawning = unmarkAllForSpawning

local vehicleAdded = false
local function onVehicleAdded(id)
  vehicleAdded = true
end

local function getConfigInfo(model, config)
  if not model or not config then return nil end
  local configInfo = core_vehicles.getConfig(model, config)
  if configInfo and configInfo.infoFilename then
    local rawInfo = jsonReadFile(configInfo.infoFilename)
    configInfo.loanerName = rawInfo and rawInfo.loanerName or nil
  end
  return configInfo
end

local function getInventoryConfigInfo(vehicleInfo)
  if not vehicleInfo then return nil end
  local config = vehicleInfo.config
  local configFilename = nil
  if type(config) == "table" and type(config.partConfigFilename) == "string" then
    local _, filename = path.splitWithoutExt(config.partConfigFilename)
    configFilename = filename
  elseif type(config) == "string" then
    local _, filename = path.splitWithoutExt(config)
    configFilename = filename or config
  end
  return getConfigInfo(vehicleInfo.model, configFilename)
end

local function isTrailerVehicle(configInfo, model)
  local aggregates = configInfo and configInfo.aggregates
  if aggregates and aggregates.Type and aggregates.Type.Trailer then
    return true
  end
  local modelInfo = model and core_vehicles.getModel(model)
  local modelData = modelInfo and (modelInfo.model or modelInfo)
  return modelData and modelData.Type == "Trailer" or false
end

local function isMaterialsEquipment(item, configInfo)
  item = item or {}
  if career_modules_delivery_loanerCapabilities and career_modules_delivery_loanerCapabilities.isMaterialsEquipment then
    return career_modules_delivery_loanerCapabilities.isMaterialsEquipment(item)
  end
  return false
end
M.isMaterialsEquipment = isMaterialsEquipment

local function usesIndependentHourlyRental(organization)
  return getLoanerUnlockMode(organization) ~= LOANER_UNLOCK_MODE_SKILL_LEVEL
end
M.usesIndependentHourlyRental = usesIndependentHourlyRental

local function getHourlyRateForOffer(item, configInfo)
  local lvl = tonumber(item and item.reputationLvl) or -1
  local materials = isMaterialsEquipment(item, configInfo)
  local base = materials and 35 or 25
  return math.max(15, math.floor(base + 15 * (lvl + 1)))
end
M.getHourlyRateForOffer = getHourlyRateForOffer
M.initRentalBilling = initRentalBilling

local function getOrganizationReputationLevel(organization, level)
  if not organization or type(organization.reputationLevels) ~= "table" then return nil end
  local reputationLevel = level
  if reputationLevel == nil and organization.reputation then
    reputationLevel = organization.reputation.level
  end
  return organization.reputationLevels[(tonumber(reputationLevel) or 0) + 2]
end

local function getReputationUnlockLabel(organization, reputationLvl)
  local info = getOrganizationReputationLevel(organization, reputationLvl)
  if type(info) == "table" then
    if type(info.label) == "string" and info.label ~= "" then
      return info.label
    end
    for _, unlock in ipairs(info.unlocks or {}) do
      if type(unlock) == "table" and type(unlock.label) == "string" and unlock.label ~= "" then
        return unlock.label
      end
    end
  end
  return string.format("level %d", tonumber(reputationLvl) or 0)
end

local function flattenXY(dir, fallback)
  local flat = vec3(dir.x, dir.y, 0)
  if flat:squaredLength() > 1e-6 then
    flat:normalize()
    return flat
  end
  return fallback or vec3(0, -1, 0)
end

local function getDeliveryFacility(facilityId)
  if not facilityId then return nil end
  if career_modules_delivery_generator and career_modules_delivery_generator.getFacilityById then
    local fac = career_modules_delivery_generator.getFacilityById(facilityId)
    if fac then return fac end
  end
  if freeroam_facilities and freeroam_facilities.getFacility then
    return freeroam_facilities.getFacility("deliveryProvider", facilityId, true)
  end
  return nil
end

local function getInspectParkingSpot(fac)
  if not fac then return nil end
  if fac.inspectSpots and fac.inspectSpots[1] then
    return fac.inspectSpots[1]
  end
  if fac.accessPointsByName then
    for _, ap in pairs(fac.accessPointsByName) do
      if ap.isInspectSpot and ap.ps then
        return ap.ps
      end
    end
  end
  return nil
end

local LOANER_NO_SPACE_MSG = "There are no parking spots for loaner vehicles of this type."
local LOANER_OCCUPIED_MSG = "Vehicle spawn area is blocked. Clear the marked stalls, then retry."
local LOANER_BLOCKED_TASK = "loaner-spawn-blocked"
local lastSpawnBatchResult = { occupiedBlocked = false, hardFail = false }
local pendingBlockedOffers = {}
local spawnBlocked = nil
local spawnMarkerCorners = {}
local lastSpawnActionSignature = nil

local function resetSpawnBatchResult()
  lastSpawnBatchResult.occupiedBlocked = false
  lastSpawnBatchResult.hardFail = false
end

function M.consumeLastSpawnBatchResult()
  local result = {
    occupiedBlocked = lastSpawnBatchResult.occupiedBlocked and true or false,
    hardFail = lastSpawnBatchResult.hardFail and true or false,
  }
  resetSpawnBatchResult()
  return result
end

local function isEmploymentOffer(offer)
  return offer and (offer.loanType == "company" or offer._fromEmploymentPool)
end

local function employmentOwnsSpawnPrompt()
  local employment = career_modules_delivery_employment
  local status = employment and employment.getBlockedSpawnStatus and employment.getBlockedSpawnStatus()
  return status ~= nil
end

local function collectSpotsForOffers(offers)
  local spots, seen = {}, {}
  local function addSpot(spot)
    if type(spot) ~= "table" or not spot.pos then return end
    local key = (spot.getPath and spot:getPath()) or spot
    if seen[key] then return end
    seen[key] = true
    spots[#spots + 1] = spot
  end
  for _, offer in pairs(offers or {}) do
    local sourceFacId = offer.sourceFacility and offer.sourceFacility.id
    local fac = sourceFacId and getDeliveryFacility(sourceFacId)
    if fac then
      if offer.brokerRentalId then
        local brokerFac = {}
        for k, v in pairs(fac) do brokerFac[k] = v end
        local fallback = (fac.pickUpSpots and fac.pickUpSpots[1]) and fac.pickUpSpots or fac.inspectSpots or {}
        brokerFac.loanerNonTrailerSpots = (fac.loanerNonTrailerSpots and fac.loanerNonTrailerSpots[1]) and fac.loanerNonTrailerSpots or fallback
        brokerFac.loanerTrailerSpots = (fac.loanerTrailerSpots and fac.loanerTrailerSpots[1]) and fac.loanerTrailerSpots or fallback
        fac = brokerFac
      end
      local configInfo = getConfigInfo(offer.model, offer.config)
      local isTrailer = isTrailerVehicle(configInfo, offer.model)
      local list = isTrailer and fac.loanerTrailerSpots or fac.loanerNonTrailerSpots
      for _, spot in ipairs(list or {}) do addSpot(spot) end
      if not isTrailer then
        addSpot(getInspectParkingSpot(fac))
      end
    end
  end
  return spots
end

local function inspectBlockedOccupancy(blocked)
  local spots = (blocked and blocked.spots) or {}
  local occupantIds, seen, moving = {}, {}, false
  local occupied = false
  local speedThreshSq = 0.25 * 0.25
  for _, spot in ipairs(spots) do
    if spot.hasAnyVehicles then
      local hasVeh, ids = spot:hasAnyVehicles()
      if hasVeh then
        occupied = true
        for _, vehId in ipairs(ids or {}) do
          if not seen[vehId] then
            seen[vehId] = true
            occupantIds[#occupantIds + 1] = vehId
            local obj = getObjectByID(vehId)
            local vel = obj and obj.getVelocity and obj:getVelocity()
            if vel and vel:squaredLength() > speedThreshSq then
              moving = true
            end
          end
        end
      end
    end
  end
  return not occupied, moving, occupantIds, spots
end

local function routeToBlockedSpots(spots)
  local best
  for _, spot in ipairs(spots or {}) do
    if spot.pos then best = spot.pos; break end
  end
  if not best then return false end
  if freeroam_bigMapMode and freeroam_bigMapMode.setNavFocus then
    freeroam_bigMapMode.setNavFocus(best)
  end
  if core_groundMarkers and core_groundMarkers.setPath then
    core_groundMarkers.setPath({best}, {clearPathOnReachingTarget = false})
  end
  return true
end

local function refreshLoanerSpawnAction(force)
  local visible = spawnBlocked ~= nil and not employmentOwnsSpawnPrompt()
  local ready = visible and spawnBlocked.ready == true and not spawnBlocked.retryInFlight
  local signature = tostring(visible) .. tostring(ready)
  if force or signature ~= lastSpawnActionSignature then
    guihooks.trigger("EmploymentSpawnAction", {visible = visible, ready = ready})
    lastSpawnActionSignature = signature
  end
  if not spawnBlocked then
    guihooks.trigger("DiscardTasklistItem", LOANER_BLOCKED_TASK)
    return
  end
  if employmentOwnsSpawnPrompt() then return end
  if ui_appContainers and ui_appContainers.showApp then
    ui_appContainers.showApp("topLeft", "tasks")
  end
  local label = spawnBlocked.ready and "Ready to spawn" or "Clear the spawn area"
  local subtext = "Clear the highlighted stalls, then select Spawn vehicle"
  guihooks.trigger("SetTasklistHeader", { label = "Loaner vehicles" })
  guihooks.trigger("SetTasklistTask", {
    id = LOANER_BLOCKED_TASK,
    label = label,
    subtext = subtext,
    active = true,
    type = "message",
    clear = false,
  })
end

local function clearLoanerSpawnBlocked(success)
  if not spawnBlocked then return end
  spawnBlocked.token = (spawnBlocked.token or 0) + 1
  spawnBlocked = nil
  spawnMarkerCorners = {}
  pendingBlockedOffers = {}
  if success then
    if freeroam_bigMapMode and freeroam_bigMapMode.setNavFocus then
      freeroam_bigMapMode.setNavFocus(nil)
    end
    if core_groundMarkers and core_groundMarkers.setPath then
      core_groundMarkers.setPath(nil)
    end
  end
  refreshLoanerSpawnAction(true)
end

local function enterLoanerSpawnBlocked(offers)
  offers = offers or pendingBlockedOffers
  if not next(offers or {}) then return false end
  if employmentOwnsSpawnPrompt() then
    for id, offer in pairs(offers) do
      markedForSpawningLoaners[id] = offer
    end
    return false
  end
  if gameplay_phone and gameplay_phone.closePhone then gameplay_phone.closePhone() end
  if guihooks then guihooks.trigger("ChangeState", { state = "play" }) end
  local spots = collectSpotsForOffers(offers)
  local clear, moving, occupantIds = inspectBlockedOccupancy({spots = spots})
  local prevToken = spawnBlocked and spawnBlocked.token or 0
  local alreadyWaiting = spawnBlocked ~= nil
  spawnBlocked = {
    token = prevToken + 1,
    offers = {},
    spots = spots,
    occupantIds = occupantIds,
    occupantMoving = moving,
    ready = clear,
    accum = 0,
    retryInFlight = nil,
  }
  for id, offer in pairs(offers) do
    spawnBlocked.offers[id] = offer
    markedForSpawningLoaners[id] = offer
  end
  pendingBlockedOffers = {}
  spawnMarkerCorners = {}
  routeToBlockedSpots(spots)
  if not alreadyWaiting then
    ui_message("Clear the highlighted spawn area, then select Spawn vehicle.", 8, "warning")
  end
  refreshLoanerSpawnAction(true)
  if gameplay_markerInteraction then gameplay_markerInteraction.setForceReevaluateOpenPrompt() end
  return true
end

local function drawLoanerSpawnBlockedArea(blocked)
  if not debugDrawer or not blocked then return end
  local color = ColorF(1, 0.05, 0.05, 1)
  for _, spot in ipairs(blocked.spots or {}) do
    if spot.pos and spot.rot and spot.scl then
      local corners = spawnMarkerCorners[spot]
      if not corners then
        corners = {}
        local x = vec3(1, 0, 0):rotated(spot.rot)
        local y = vec3(0, 1, 0):rotated(spot.rot)
        for _, sx in ipairs({-1, 1}) do
          for _, sy in ipairs({-1, 1}) do
            local pos = spot.pos + x * sx * spot.scl.x * 0.5 + y * sy * spot.scl.y * 0.5
            local hit = Engine.castRay(pos + vec3(0, 0, 5), pos - vec3(0, 0, 10), true, false)
            pos = (hit and vec3(hit.pt) or pos) + vec3(0, 0, 0.12)
            corners[#corners + 1] = {pos = pos, x = x * -sx, y = y * -sy}
          end
        end
        spawnMarkerCorners[spot] = corners
      end
      local center = vec3(0, 0, 0)
      for _, corner in ipairs(corners) do center = center + corner.pos end
      center = center * 0.25
      local direction = vec3(0, 1, 0):rotated(spot.rot)
      local fill = blocked.ready and ColorF(0.15, 1, 0.25, 0.25) or ColorF(1, 0.6, 0.05, 0.25)
      debugDrawer:drawSquarePrism(center - direction * spot.scl.y * 0.5,
        center + direction * spot.scl.y * 0.5, Point2F(0.15, spot.scl.x), Point2F(0.15, spot.scl.x), fill)
      if not blocked.ready then
        for _, corner in ipairs(corners) do
          debugDrawer:drawCylinder(corner.pos, corner.pos + corner.x, 0.07, color)
          debugDrawer:drawCylinder(corner.pos, corner.pos + corner.y, 0.07, color)
          debugDrawer:drawCylinder(corner.pos, corner.pos + vec3(0, 0, 0.6), 0.07, color)
        end
      end
    end
  end
end

local function tickLoanerSpawnBlocked(dtSim)
  local blocked = spawnBlocked
  if not blocked or blocked.retryInFlight then return end
  drawLoanerSpawnBlockedArea(blocked)
  blocked.accum = (blocked.accum or 0) + (tonumber(dtSim) or 0)
  local interval = blocked.occupantMoving and 1 or 2
  if blocked.accum < interval then return end
  blocked.accum = 0
  local clear, moving, occupantIds, spots = inspectBlockedOccupancy(blocked)
  blocked.occupantMoving = moving
  blocked.occupantIds = occupantIds
  blocked.spots = spots
  if blocked.ready ~= clear then
    blocked.ready = clear
    refreshLoanerSpawnAction(true)
    if gameplay_markerInteraction then gameplay_markerInteraction.setForceReevaluateOpenPrompt() end
  end
end

function M.getBlockedSpawnStatus()
  if not spawnBlocked or employmentOwnsSpawnPrompt() then return nil end
  local veh = getPlayerVehicle(0)
  local pos = veh and veh:getPosition()
  local nearby = false
  for _, spot in ipairs(spawnBlocked.spots or {}) do
    if pos and spot.pos and (pos - spot.pos):squaredLength() <= 40 * 40 then nearby = true; break end
  end
  return {ready = spawnBlocked.ready == true and not spawnBlocked.retryInFlight, nearby = nearby}
end

function M.spawnBlockedOffers()
  local status = M.getBlockedSpawnStatus()
  local blocked = spawnBlocked
  if not status or not status.nearby or not blocked or blocked.retryInFlight then return false end
  local clear = inspectBlockedOccupancy(blocked)
  blocked.ready = clear
  if not clear then
    ui_message("The spawn area is still blocked. Clear the highlighted stalls first.", 6, "warning")
    refreshLoanerSpawnAction(true)
    return false
  end
  if gameplay_markerInteraction and gameplay_markerInteraction.closeWorldPrompt then
    pcall(gameplay_markerInteraction.closeWorldPrompt)
  end
  blocked.retryInFlight = true
  for id, offer in pairs(blocked.offers or {}) do
    markedForSpawningLoaners[id] = offer
  end
  local token = blocked.token
  M.spawnAllOffers(function()
    if not spawnBlocked or spawnBlocked.token ~= token then return end
    local batch = M.consumeLastSpawnBatchResult()
    spawnBlocked.retryInFlight = nil
    if batch.occupiedBlocked then
      enterLoanerSpawnBlocked(spawnBlocked.offers)
      return
    end
    if batch.hardFail then
      clearLoanerSpawnBlocked(false)
      return
    end
    clearLoanerSpawnBlocked(true)
  end)
  return true
end

function M.cancelBlockedSpawn()
  clearLoanerSpawnBlocked(false)
  markedForSpawningLoaners = {}
end

-- Use the parking spot's placement math (OOBB centering + facing correction).
-- Raw setPositionRotation on spot.pos/rot lands vehicles off-heading and half in the deck.
local function plantLoanerAt(spot, vehId, worldPos)
  if not spot or not vehId then return false end
  local offset = vec3(0, 0, 0)
  if worldPos then
    local pos = spot.pos
    local back = flattenXY(quat(spot.rot) * vec3(0, -1, 0), vec3(0, -1, 0))
    local right = flattenXY(vec3(-back.y, back.x, 0), vec3(1, 0, 0))
    local delta = worldPos - pos
    offset = vec3(right:dot(delta), back:dot(delta), 0)
  end
  spot:moveResetVehicleTo(vehId, false, false, offset, nil, false, true, true)
  return true
end

local function abortLoanerNoSpace(vehObj, offer, reason)
  log("W", "loanerVehicles", string.format("No space for loaner %s (%s)", tostring(offer and offer.id), tostring(reason or "noSpace")))
  if reason == "occupied" then
    lastSpawnBatchResult.occupiedBlocked = true
  else
    lastSpawnBatchResult.hardFail = true
  end
  if vehObj then
    pcall(function() vehObj:delete() end)
  end
  if reason == "occupied" then
    -- Employment owns its single waiting notice and automatic retry.
    if offer and not isEmploymentOffer(offer) then
      pendingBlockedOffers[offer.id] = offer
    elseif not (offer and isEmploymentOffer(offer)) then
      ui_message(LOANER_OCCUPIED_MSG, 8, "loanerSpawnBlocked")
    end
  else
    ui_message(LOANER_NO_SPACE_MSG, 5, "loanerNoSpace")
  end
end

-- Empty stall: plant at the marker. Occupied stalls report occupied (no XY nudge).
-- Ambient parked traffic may be relocated once, then rechecked.
local function teleportLoanerToSpot(vehObj, vehId, spot, isTrailer)
  if not vehObj or not spot or not spot.pos or not spot.rot then return false, "noSpace" end

  local occupied, occupantIds = spot:hasAnyVehicles(vehId)
  if occupied then
    local parkedData = gameplay_parking and gameplay_parking.getParkedCarsData and gameplay_parking.getParkedCarsData() or {}
    if gameplay_parking and gameplay_parking.forceTeleport then
      for _, occupantId in ipairs(occupantIds or {}) do
        if parkedData[occupantId] then
          pcall(gameplay_parking.forceTeleport, occupantId)
        end
      end
    end
    occupied = spot:hasAnyVehicles(vehId)
  end

  if occupied then
    return false, "occupied"
  end

  plantLoanerAt(spot, vehId, nil)
  return true
end

local function teleportLoanerNearInspect(fac, vehObj, vehId)
  local inspectSpot = getInspectParkingSpot(fac)
  if not inspectSpot then return false, "noSpace" end
  local occupied = inspectSpot.hasAnyVehicles and inspectSpot:hasAnyVehicles(vehId)
  if occupied then
    return false, "occupied"
  end
  plantLoanerAt(inspectSpot, vehId, nil)
  return true
end

local function teleportLoanerToFacility(fac, vehObj, vehId, offer, waitForPhysics)
  if not fac or not vehObj or not vehId then return false, nil, "noSpace" end
  local configInfo = offer and getConfigInfo(offer.model, offer.config) or nil
  local modelKey = offer and offer.model or vehObj:getField('JBeam', '0')
  local isTrailer = isTrailerVehicle(configInfo, modelKey)
  local spots = isTrailer and fac.loanerTrailerSpots or fac.loanerNonTrailerSpots
  local companyPlacement = offer and (offer.loanType == "company" or offer._fromEmploymentPool)
  if companyPlacement and not (spots and spots[1]) then
    local named, other = {}, {}
    for name, ap in pairs(fac.accessPointsByName or {}) do
      local spot = ap.ps
      if spot then
        local list = tostring(spot.name or name):lower():find("loaner", 1, true) and named or other
        list[#list + 1] = spot
      end
    end
    spots = named[1] and named or other
    table.sort(spots, function(a, b) return tostring(a.name) < tostring(b.name) end)
  end
  if spots and spots[1] then
    local ordered, seen = {}, {}
    local function addSpot(spot)
      if spot and not seen[spot] then
        seen[spot] = true
        ordered[#ordered + 1] = spot
      end
    end
    local preferred = isTrailer and spots[1]
      or (gameplay_sites_sitesManager and gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList
        and gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(vehId, spots))
      or spots[1]
    addSpot(preferred)
    for _, spot in ipairs(spots) do
      addSpot(spot)
    end
    local sawOccupied = false
    for _, parkingSpot in ipairs(ordered) do
      local placed, reason
      if companyPlacement then
        if not parkingSpot.hasAnyVehicles or not parkingSpot.pos or not parkingSpot.rot then
          reason = "noSpace"
        elseif parkingSpot:hasAnyVehicles(vehId) then
          reason = "occupied"
        else
          placed = plantLoanerAt(parkingSpot, vehId, nil)
        end
      else
        placed, reason = teleportLoanerToSpot(vehObj, vehId, parkingSpot, isTrailer)
      end
      if placed then
        return true, parkingSpot
      end
      if reason == "occupied" then
        sawOccupied = true
      end
    end
    if sawOccupied then
      return false, nil, "occupied"
    end
    return false, nil, "noSpace"
  end
  if not isTrailer and not companyPlacement then
    local placed, reason = teleportLoanerNearInspect(fac, vehObj, vehId)
    if placed then
      return true, getInspectParkingSpot(fac)
    end
    return false, nil, reason or "noSpace"
  end
  return false, nil, "noSpace"
end

local function startSpawnSequenceWhenReady(sequence, onComplete)
  core_jobsystem.create(function(job)
    job.sleep(0)
    local general = career_modules_delivery_general
    local waited = 0
    while general and general.isContainerWeightUpdatePending
        and general.isContainerWeightUpdatePending() and waited < 60 do
      job.sleep(0.05)
      waited = waited + 0.05
    end
    if general and general.isContainerWeightUpdatePending
        and general.isContainerWeightUpdatePending() then
      log("W", "loanerVehicles", "Cargo loading did not settle before loaner spawn timeout")
    elseif waited > 0 then
      job.sleep(0)
    end
    util_stepHandler.startStepSequence(sequence, onComplete)
  end)
end

local function spawnAllOffers(onComplete)
  if not next(markedForSpawningLoaners) then
    log("W", "loanerVehicles", "spawnAllOffers called with no marked loaners")
    if onComplete then onComplete() end
    return
  end
  resetSpawnBatchResult()
  pendingBlockedOffers = {}
  vehicleAdded = false
  local lookAtPos
  local sequence = {
    -- fade to black
    util_stepHandler.makeStepFadeToBlack(0.4),
  }
  for id, offer in pairs(markedForSpawningLoaners) do
    -- spawn vehicle and trigger initialization
    local options = {model = offer.model, config = offer.config, autoEnterVehicle = false, removeTraffic = false}
    local sourceFacId = offer.sourceFacility and offer.sourceFacility.id
    if not sourceFacId then
      log("E", "loanerVehicles", string.format("Loaner %s missing sourceFacility; skipping spawn", tostring(offer.id)))
      goto continueMarkedLoaner
    end
    local fac = getDeliveryFacility(sourceFacId)
    if not fac then
      log("E", "loanerVehicles", string.format("Loaner %s facility unavailable: %s", tostring(offer.id), tostring(sourceFacId)))
      goto continueMarkedLoaner
    end
    if offer.brokerRentalId then
      local brokerFac={}; for k,v in pairs(fac) do brokerFac[k]=v end
      local fallback=(fac.pickUpSpots and fac.pickUpSpots[1]) and fac.pickUpSpots or fac.inspectSpots or {}
      brokerFac.loanerNonTrailerSpots=(fac.loanerNonTrailerSpots and fac.loanerNonTrailerSpots[1]) and fac.loanerNonTrailerSpots or fallback
      brokerFac.loanerTrailerSpots=(fac.loanerTrailerSpots and fac.loanerTrailerSpots[1]) and fac.loanerTrailerSpots or fallback
      fac=brokerFac
    end
    if offer.loanType == "company" or offer._fromEmploymentPool then
      local anchor = (fac.loanerNonTrailerSpots or {})[1] or (fac.loanerTrailerSpots or {})[1] or getInspectParkingSpot(fac)
      if not anchor then
        for _, ap in pairs(fac.accessPointsByName or {}) do
          if ap.ps and ap.ps.pos then anchor = ap.ps; break end
        end
      end
      if anchor and anchor.pos then
        -- Initialize away from occupants; the placement callback resets the
        -- new vehicle onto validated ground before registering it in inventory.
        options.pos = anchor.pos + vec3(0, 0, 1000)
        options.rot = anchor.rot
        options.safeSpawn = false
      end
    end
    table.insert(sequence, util_stepHandler.makeStepReturnTrueFunction(function()
      vehicleAdded = false
      return true
    end))
    table.insert(sequence, util_stepHandler.makeStepSpawnVehicle(options,
      function(step, vehId)
        local vehObj = scenetree.findObjectById(vehId)
        if not fac or not vehObj then
          log("E", "loanerVehicles", string.format("Could not initialize loaner %s: facility or vehicle is unavailable", tostring(offer.id)))
          vehicleAdded = true
          return
        end
        local initOk, initErr = pcall(core_vehicleBridge.executeAction, vehObj, 'initPartConditions', {}, offer.vehMileage or 0, 1, 1)
        if not initOk then
          log("E", "loanerVehicles", string.format("Could not initialize loaner %s: %s", tostring(offer.id), tostring(initErr)))
        end
        local initializationFinished = false
        local registeredInventoryId
        core_vehicleBridge.requestValue(vehObj,
          function(res)
            if initializationFinished then return end
            core_jobsystem.create(function(placementJob)
              if initializationFinished then return end
              local callbackOk, callbackErr = pcall(function()
                if not vehObj or not scenetree.findObjectById(vehId) then
                  vehicleAdded = true
                  return
                end
                local placed, bestParkingSpot, placeReason = teleportLoanerToFacility(fac, vehObj, vehId, offer, function() placementJob.sleep(0) end)
                if initializationFinished then return end
                if not placed then
                  abortLoanerNoSpace(vehObj, offer, placeReason)
                  vehicleAdded = true
                  return
                end
                offer.vehPos = vehObj:getPosition() or (bestParkingSpot and bestParkingSpot.pos)
                lookAtPos = offer.vehPos

                local inventoryId = career_modules_inventory.addVehicle(vehId, nil, {owned = false})
                registeredInventoryId = inventoryId
                local vehInfo = inventoryId and career_modules_inventory.getVehicles()[inventoryId]
                if not vehInfo then
                  log("E", "loanerVehicles", string.format("Loaner %s was spawned but could not be added to inventory", tostring(offer.id)))
                  abortLoanerNoSpace(vehObj, offer, "inventory")
                  vehicleAdded = true
                  return
                end
                vehInfo.owningOrganization = fac.associatedOrganization
                vehInfo.loanType = offer.loanType
                vehInfo.brokerRentalId = offer.brokerRentalId
                vehInfo.brokerDepotId = offer.brokerDepotId
                vehInfo.brokerMap = offer.brokerMap
                if offer.loanType == "rental" then
                  vehInfo.rentalHourlyRate = offer.hourlyRate or getHourlyRateForOffer(offer)
                  initRentalBilling(vehInfo)
                end
              end)
              if not callbackOk then
                log("E", "loanerVehicles", string.format("Could not finish retrieving loaner %s: %s", tostring(offer.id), tostring(callbackErr)))
                if registeredInventoryId then
                  career_modules_inventory.removeVehicle(registeredInventoryId, true)
                else
                  abortLoanerNoSpace(vehObj, offer, "placement")
                end
                vehicleAdded = true
              end
              initializationFinished = true
            end)
          end
          , 'ping')
        if options.safeSpawn == false then
          -- A missing bridge reply must not leave an unregistered vehicle
          -- falling from its temporary initialization position.
          core_jobsystem.create(function(job)
            job.sleep(8)
            if initializationFinished then return end
            initializationFinished = true
            abortLoanerNoSpace(vehObj, offer, "initializationTimeout")
            vehicleAdded = true
          end)
        end
      end
      )
    )
    table.insert(sequence, util_stepHandler.makeStepReturnTrueFunction(
      function() return vehicleAdded end
    ))
    ::continueMarkedLoaner::
  end
  if #sequence <= 1 then
    log("W", "loanerVehicles", "spawnAllOffers had marked loaners but built no spawn steps")
    markedForSpawningLoaners = {}
    if onComplete then onComplete() end
    return
  end
  table.insert(sequence, util_stepHandler.makeStepReturnTrueFunction(
      function()
        -- markedForSpawningLoaners may already be empty: cargoScreen unmarks
        -- after spawnAllOffers returns, and we defer the sequence one tick.
        if lookAtPos then
          local playerVehicle = getPlayerVehicle(0)
          local camDir = playerVehicle and (lookAtPos - playerVehicle:getPosition()) or nil
          if camDir and gameplay_walk.isWalking() then
            gameplay_walk.setRot(camDir)
          end
        end
        markedForSpawningLoaners = {}
        return true
      end
    )
  )
  table.insert(sequence, util_stepHandler.makeStepFadeFromBlack(0.4))

  -- cargoScreen often calls this from a live stepHandler callback. Starting a
  -- nested sequence replaces taskData in-place and the outer onUpdate then
  -- skips our fade-to-black. Always start on the next job tick.
  startSpawnSequenceWhenReady(sequence, function()
    if lastSpawnBatchResult.occupiedBlocked and next(pendingBlockedOffers) then
      enterLoanerSpawnBlocked(pendingBlockedOffers)
    end
    if onComplete then onComplete() end
  end)
end
M.spawnAllOffers = spawnAllOffers

local function billRentalHours(vehInfo, hours)
  hours = math.max(0, tonumber(hours) or 0)
  if hours <= 0 then return 0 end
  local rate = tonumber(vehInfo.rentalHourlyRate) or 30
  local precision = vehInfo.brokerRentalId and 100 or 1
  local charge = math.floor(rate * hours * precision + 0.5) / precision
  if charge > 0 and career_modules_playerAttributes and career_modules_playerAttributes.addAttributes then
    career_modules_playerAttributes.addAttributes({ money = -charge }, {
      tags = { "fine", "rental" },
      label = "Hourly vehicle rental",
    })
    ui_message(string.format("Rental charge: $%.2f for %d sim hour%s.", charge, hours, hours == 1 and "" or "s"), 5, "info")
  end
  return charge
end

local function billRentalSimSeconds(vehInfo, simSeconds)
  simSeconds = math.max(0, tonumber(simSeconds) or 0)
  if simSeconds <= 0 then return 0 end
  local rate = tonumber(vehInfo.rentalHourlyRate) or 30
  local precision = vehInfo.brokerRentalId and 100 or 1
  local charge = math.floor(rate * (simSeconds / RENTAL_SIM_SECONDS_PER_HOUR) * precision + 0.5) / precision
  if charge > 0 and career_modules_playerAttributes and career_modules_playerAttributes.addAttributes then
    career_modules_playerAttributes.addAttributes({ money = -charge }, {
      tags = { "fine", "rental" },
      label = "Hourly vehicle rental",
    })
    local minutes = math.max(1, math.floor(simSeconds / 60 + 0.5))
    ui_message(string.format("Rental charge: $%.2f (%d sim min).", charge, minutes), 5, "info")
  end
  vehInfo.rentalBilledSimSeconds = rentalBilledSimSeconds(vehInfo) + simSeconds
  return charge
end

local function settleRentalOnReturn(vehInfo)
  if not vehInfo or vehInfo.loanType ~= "rental" then return end
  accrueRentalSimTime(vehInfo)
  local accrued = tonumber(vehInfo.rentalSimAccrued) or 0
  local billed = rentalBilledSimSeconds(vehInfo)
  local unbilled = accrued - billed
  if unbilled > 0 then
    billRentalSimSeconds(vehInfo, unbilled)
  end
end

local function returnVehicleActual(inventoryId)
  local delivery = career_modules_delivery_general
  if delivery and delivery.canRemoveLogisticsVehicle and not delivery.canRemoveLogisticsVehicle(inventoryId) then return false end
  local vehInfo = career_modules_inventory.getVehicles()[inventoryId]
  if not vehInfo then
    loanedVehiclesInfo[inventoryId] = nil
    return
  end
  settleRentalOnReturn(vehInfo)
  local loanType = vehInfo.loanType
  local brokerRentalId = vehInfo.brokerRentalId
  local owningOrg = vehInfo.owningOrganization
  -- Police-issued equipment is expected to take pursuit damage. Identify the
  -- issuing organization so the exemption also survives clock-out/reloading.
  local policeLoaner = (loanType == "company" or loanType == "work")
    and facilityRole.isPoliceOrganizationId(owningOrg)
  local needsRepair = career_modules_insurance_insurance
    and career_modules_insurance_insurance.inventoryVehNeedsRepair
    and career_modules_insurance_insurance.inventoryVehNeedsRepair(inventoryId)
  if needsRepair and owningOrg and not policeLoaner
    and (loanType == "work" or loanType == "company" or loanType == "rental") then
    local eventValue = career_modules_reputation.getValueForEvent("returnLoanerDamaged")
    if loanType == "rental" then
      eventValue = math.floor((eventValue or -20) * 0.5)
    end
    local fine = {}
    fine[owningOrg .. "Reputation"] = eventValue
    career_modules_playerAttributes.addAttributes(fine, {tags={"fine"}, label="ui.career.attributeLog.loanerDamagedReputationCost"})
    guihooks.trigger("toastrMsg", {type="warning", label = "loanReturnedDamaged", title="Loaner returned damaged", msg="Lost reputation due to returning a damaged loaned vehicle."})
    local emp = career_modules_delivery_employment
    if emp and emp.onIssuedVehicleReturnedDamaged and (loanType == "company" or loanType == "rental") then
      emp.onIssuedVehicleReturnedDamaged(inventoryId)
    end
  end
  career_modules_inventory.removeVehicle(inventoryId)
  if loanType == "company" then
    local emp = career_modules_delivery_employment
    if emp and emp.onIssuedVehicleReturned then
      emp.onIssuedVehicleReturned(inventoryId)
    end
  end
  if brokerRentalId then
    local broker = rawget(_G, "career_modules_delivery_broker")
    if broker and broker.onRentalVehicleReturned then
      broker.onRentalVehicleReturned(brokerRentalId)
    end
  end
end

local function returnVehicle(inventoryId, callback)
  local delivery = career_modules_delivery_general
  if delivery and delivery.canRemoveLogisticsVehicle and not delivery.canRemoveLogisticsVehicle(inventoryId) then
    if callback then callback(false) end
    return false
  end
  if career_modules_inventory.getVehicleIdFromInventoryId(inventoryId) then
    career_modules_inventory.updatePartConditions(nil, inventoryId,
    function()
      if returnVehicleActual(inventoryId) == false then
        if callback then callback(false) end
        return
      end
      unmarkAllForSpawning()
      if callback then callback() end
    end)
  else
    if returnVehicleActual(inventoryId) == false then
      if callback then callback(false) end
      return false
    end
    unmarkAllForSpawning()
    if callback then callback() end
  end
end

local function getLoanedVehicles()
  local result = {}
  for inventoryId, vehInfo in pairs(career_modules_inventory.getVehicles()) do
    if vehInfo.owningOrganization then
      local veh = deepcopy(vehInfo)
      local thumbnailOk, thumbnail = pcall(career_modules_inventory.getVehicleThumbnail, veh.id)
      veh.thumbnail = thumbnailOk and thumbnail or nil
      table.insert(result, veh)
    end
  end
  return result
end

function M.stepOutIfInCompanyVehicle()
  if not (career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId) then return end
  local vehId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0)
  if not vehId or vehId < 0 then return end
  local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
  local vehInfo = inventoryId and career_modules_inventory.getVehicles()[inventoryId]
  if not (vehInfo and vehInfo.loanType == "company") then return end
  if spawn then spawn.preventPlayerSpawning = nil end
  if gameplay_walk and gameplay_walk.setWalkingMode then
    gameplay_walk.setWalkingMode(true, nil, nil, true)
  end
end

function M.returnVehicles(inventoryIds, callback)
  local pending = #(inventoryIds or {})
  if pending == 0 then
    if callback then callback() end
    return
  end
  local failed = false
  local function doneOne(returned)
    if returned == false then failed = true end
    pending = pending - 1
    if pending == 0 and callback then
      if failed then callback(false) else callback() end
    end
  end
  for _, inventoryId in ipairs(inventoryIds) do
    M.returnVehicle(inventoryId, callback and doneOne or nil)
  end
end

function M.returnAllCompanyVehicles()
  if not career_modules_inventory then return 0 end
  M.stepOutIfInCompanyVehicle()
  local ids = {}
  for inventoryId, vehInfo in pairs(career_modules_inventory.getVehicles() or {}) do
    if vehInfo and vehInfo.loanType == "company" then
      table.insert(ids, inventoryId)
    end
  end
  M.returnVehicles(ids)
  return #ids
end

local function getLoanedVehiclesByOrg(organizationId)
  local result = {}
  for _, vehInfo in ipairs(getLoanedVehicles()) do
    if organizationId == vehInfo.owningOrganization then
      table.insert(result, vehInfo)
    end
  end
  return result
end

local vehPos = vec3()
local playerPos = vec3()

local UPDATE_INTERVAL = 0.25
local updateAccumulator = 0
local simAccumulator = 0
local walkAwayRadiusSq = walkAwayRadius * walkAwayRadius
local comeBackRadiusSq = comeBackRadius * comeBackRadius
local expiredLoaners = {}

local function onUpdate(dtReal, dtSim, dtRaw)
  -- This watch only has to notice a 100m walk-away, so run it on a fixed cadence
  -- rather than once per rendered frame. dtSim is banked across skipped frames so
  -- the return countdown still advances at exactly the same rate as before.
  simAccumulator = simAccumulator + (tonumber(dtSim) or 0)
  updateAccumulator = updateAccumulator + (tonumber(dtReal) or 0)
  if spawnBlocked then
    tickLoanerSpawnBlocked(dtSim)
  end
  if updateAccumulator < UPDATE_INTERVAL then return end
  local simElapsed = simAccumulator
  updateAccumulator = 0
  simAccumulator = 0

  if simElapsed > 0 and career_modules_inventory then
    for _, vehInfo in pairs(career_modules_inventory.getVehicles() or {}) do
      if vehInfo.loanType == "rental" then
        accrueRentalSimTime(vehInfo)
        local accrued = tonumber(vehInfo.rentalSimAccrued) or 0
        local billed = rentalBilledSimSeconds(vehInfo)
        local unbilled = accrued - billed
        local wholeHours = math.floor(unbilled / RENTAL_SIM_SECONDS_PER_HOUR)
        if wholeHours > 0 then
          billRentalHours(vehInfo, wholeHours)
          vehInfo.rentalBilledSimSeconds = billed + wholeHours * RENTAL_SIM_SECONDS_PER_HOUR
        end
      end
    end
  end

  local playerVehId = be:getPlayerVehicleID(0)
  local playerVeh = playerVehId and playerVehId >= 0 and be:getObjectByID(playerVehId) or nil
  if not playerVeh then return end
  playerPos:set(playerVeh:getPosition())

  local vehicles = career_modules_inventory.getVehicles()
  local inventoryIdToVehId = career_modules_inventory.getMapInventoryIdToVehId()

  -- Walk the inventory table itself and only resolve an engine object for entries
  -- that are actually work loaners. The usual case is that the player has none,
  -- which makes this a plain field compare per owned vehicle.
  for inventoryId, vehInfo in pairs(vehicles) do
    if not vehInfo.brokerRentalId and (vehInfo.loanType == "work" or vehInfo.loanType == "rental") and not loanedVehiclesInfo[inventoryId] then
      local vehId = inventoryIdToVehId[inventoryId]
      local vehObj = vehId and be:getObjectByID(vehId) or nil
      if vehObj then
        vehPos:set(vehObj:getPosition())
        if playerPos:squaredDistance(vehPos) > walkAwayRadiusSq then
          ui_message(string.format("You are leaving a loaned vehicle behind. After %d seconds, it will be returned to the owner.", walkAwayTimeLimit), 5, "loanedVehicleTime")
          loanedVehiclesInfo[inventoryId] = {time = walkAwayTimeLimit}
        end
      end
    end
  end

  table.clear(expiredLoaners)

  for inventoryId, loanedVehInfo in pairs(loanedVehiclesInfo) do
    if not vehicles[inventoryId] then
      loanedVehiclesInfo[inventoryId] = nil
    elseif not loanedVehInfo.returning then
      local vehId = inventoryIdToVehId[inventoryId]
      local vehObj = vehId and be:getObjectByID(vehId) or nil
      if vehObj then
        vehPos:set(vehObj:getPosition())
        if playerPos:squaredDistance(vehPos) < comeBackRadiusSq then
          loanedVehiclesInfo[inventoryId] = nil
        else
          loanedVehInfo.time = loanedVehInfo.time - simElapsed
          if loanedVehInfo.time < 0 then
            -- removeVehicle runs asynchronously behind a part condition update, so
            -- latch the entry rather than calling returnVehicle again on every tick
            -- until the inventory finally drops it.
            loanedVehInfo.returning = true
            table.insert(expiredLoaners, inventoryId)
          elseif not loanedVehInfo.warningShown and loanedVehInfo.time < walkAwayWarningTime then
            ui_message(string.format("After %d more seconds of not returning to the loaned vehicle, it will be returned to the owner.", walkAwayWarningTime), 5, "loanedVehicleTime")
            loanedVehInfo.warningShown = true
          end
        end
      end
    end
  end

  -- returnVehicle mutates the inventory, so it only runs once iteration is done.
  -- The latched entry is cleared above when the vehicle leaves the inventory.
  for _, inventoryId in ipairs(expiredLoaners) do
    returnVehicle(inventoryId)
  end
end

local function onCareerActive(active)
  table.clear(loanedVehiclesInfo)
  table.clear(expiredLoaners)
  updateAccumulator = 0
  simAccumulator = 0
  if active and career_modules_inventory then
    for _, vehInfo in pairs(career_modules_inventory.getVehicles() or {}) do
      if vehInfo.loanType == "work" and vehInfo.owningOrganization then
        local organization = freeroam_organizations.getOrganization(vehInfo.owningOrganization)
        if usesIndependentHourlyRental(organization) then
          vehInfo.loanType = "rental"
          vehInfo.rentalHourlyRate = vehInfo.rentalHourlyRate or getHourlyRateForOffer(vehInfo)
          initRentalBilling(vehInfo)
        end
      end
    end
  end
end

local function getNumberOfLoanedNonTrailers(organizationId)
  local counter = 0
  for inventoryId, vehicleInfo in pairs(career_modules_inventory.getVehicles()) do
    if vehicleInfo.owningOrganization == organizationId then
      local configInfo = getInventoryConfigInfo(vehicleInfo)
      if not isTrailerVehicle(configInfo, vehicleInfo.model) then
        counter = counter + 1
      end
    end
  end
  return counter
end

local function appliesRevenueShare(loanType)
  return not loanType or loanType == "work"
end
M.appliesRevenueShare = appliesRevenueShare

local function getLoaningOrgsOfVehicle(vehId)
  local res = {}
  if not vehId or vehId < 0 then return res end
  local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
  local vehInfo = career_modules_inventory.getVehicles()[inventoryId]
  if vehInfo and vehInfo.owningOrganization and appliesRevenueShare(vehInfo.loanType) then
    res[vehInfo.owningOrganization] = true
  end

  local pullingVehicleId = core_trailerRespawn and core_trailerRespawn.getAttachedNonTrailer and core_trailerRespawn.getAttachedNonTrailer(vehId)
  if pullingVehicleId then
    local pullingInventoryId = career_modules_inventory.getInventoryIdFromVehicleId(pullingVehicleId)
    local pullingVehInfo = career_modules_inventory.getVehicles()[pullingInventoryId]
    if pullingVehInfo and pullingVehInfo.owningOrganization and appliesRevenueShare(pullingVehInfo.loanType) then
      res[pullingVehInfo.owningOrganization] = true
    end
  end
  return res
end

local function getNumberOfLoanersToBeSpawned()
  local numberNonTrailers, numberTrailers = 0, 0
  for id, offer in pairs(markedForSpawningLoaners) do
    local configInfo = getConfigInfo(offer.model, offer.config)
    if isTrailerVehicle(configInfo, offer.model) then
      numberTrailers = numberTrailers + 1
    else
      numberNonTrailers = numberNonTrailers + 1
    end
  end
  return numberNonTrailers, numberTrailers
end

local function getRentalMileage(rentalVehicleInfo, organization)
  if rentalVehicleInfo.mileages then
    local reputationLevel = organization and organization.reputation and organization.reputation.level or 0
    if rentalVehicleInfo.mileages[tostring(reputationLevel)] then
      return rentalVehicleInfo.mileages[tostring(reputationLevel)]
    else
      return select(2, next(rentalVehicleInfo.mileages))
    end
  end
  if rentalVehicleInfo.mileage then
    return rentalVehicleInfo.mileage
  end
  return 0
end

local function formatSpawnedLoanersForUi()
  local result = {}
  for _, vehInfo in ipairs(getLoanedVehicles()) do
    local veh = deepcopy(vehInfo)
    local organization = freeroam_organizations.getOrganization(veh.owningOrganization)
    local configInfo = getInventoryConfigInfo(vehInfo)
    local reputationLevel = getOrganizationReputationLevel(organization)

    veh.loanerCut = (veh.loanType ~= "rental" and veh.loanType ~= "company") and (reputationLevel and reputationLevel.loanerCut or 0) or nil
    veh.hourlyRate = veh.loanType == "rental" and (veh.rentalHourlyRate or getHourlyRateForOffer(veh, configInfo)) or nil
    local nameOk, translatedName = pcall(career_modules_inventory.getVehicleNiceNameTranslated, veh.id)
    veh.name = configInfo and configInfo.loanerName or (nameOk and translatedName or veh.niceName)
    if type(veh.name) ~= "string" or veh.name == "" then
      local offerName = configInfo and configInfo.Name
      if core_locales and core_locales.translateWithOrWithoutContext then
        offerName = core_locales.translateWithOrWithoutContext(offerName)
      end
      veh.name = (type(offerName) == "string" and offerName ~= "") and offerName or (veh.model or "Loaner")
    end
    local mileageOk, mileage = pcall(career_modules_valueCalculator.getVehicleMileageById, veh.id)
    veh.vehMileage = mileageOk and mileage or 0
    veh.organizationName = organization and organization.name or veh.owningOrganization or "Unknown organization"
    veh.vehOfferType = isTrailerVehicle(configInfo, vehInfo.model) and "trailer" or "vehicle"
    veh.enabled = true
    veh.isSpawnedLoaner = true

    if configInfo and configInfo.capacity then
      veh.capacity = {}
      for _, cap in ipairs(configInfo.capacity) do
        if cap.type == "fluid" then
          table.insert(veh.capacity, {
            icon = career_modules_delivery_parcelMods.getModifierIcon(cap.type),
            labelShort = string.format("%dL", cap.amount),
            labelLong = string.format("Fluids: %dL", cap.amount),
          })
        end
      end
    end

    table.insert(result, veh)
  end
  return result
end

local function formatLoanerOfferForUi(facility)
  local employment=career_modules_delivery_employment
  if career_modules_delivery_broker and not (employment and employment.isEmployed and employment.isEmployed()) then return {} end
  facility = getDeliveryFacility(facility.id) or facility
  local organizationId = facility.associatedOrganization
  local organization = freeroam_organizations.getOrganization(organizationId)
  if not organization then return nil end
  local loanerUnlockMode = getLoanerUnlockMode(organization)
  local usesSkillUnlocks = loanerUnlockMode == LOANER_UNLOCK_MODE_SKILL_LEVEL
  if usesSkillUnlocks then
    return {}
  end
  local ret = {}
  local orgSkillLevel = 0
  local skillLabel, skillIcon = getLoanerUnlockSkillDisplayData(organization)

  local saveSlot, savePath = career_saveSystem.getCurrentProfile()
  local saveData = (savePath and jsonReadFile(savePath .. "/info.json")) or {}
  local secondsSinceSaveFileCreation = saveData.creationDate and dateUtils.timeSince(saveData.creationDate) or 0

  local loanableVehicleEntries = {}
  -- A delivery facility may define a purpose-built fleet without changing every
  -- other facility that shares its organization. Existing organization fleets
  -- remain the fallback for facilities that do not opt in.
  for idx, rentalVehicleInfo in ipairs(facility.loanableVehicles or organization.loanableVehicles or {}) do
    table.insert(loanableVehicleEntries, {idx = idx, vehicle = rentalVehicleInfo})
  end

  if usesSkillUnlocks then
    table.sort(loanableVehicleEntries, function(a, b)
      local levelA = tonumber(a.vehicle.requiredSkillLevel or a.vehicle.requiredPoliceLevel) or 0
      local levelB = tonumber(b.vehicle.requiredSkillLevel or b.vehicle.requiredPoliceLevel) or 0
      if levelA ~= levelB then
        return levelA > levelB
      end
      return a.idx < b.idx
    end)
  end

  for displayIdx, entry in ipairs(loanableVehicleEntries) do
    local rentalVehicleInfo = entry.vehicle
    local configInfo = getConfigInfo(rentalVehicleInfo.model, rentalVehicleInfo.config)
    local hasFreeParkingSpot = false
    local isTrailer = isTrailerVehicle(configInfo, rentalVehicleInfo.model)
    local spots = (isTrailer and facility.loanerTrailerSpots or facility.loanerNonTrailerSpots) or {}

    local numberNonTrailersToBeSpawned, numberTrailersToBeSpawned = getNumberOfLoanersToBeSpawned()
    local counterSpawnedVehiclesOfSameType = isTrailer and numberTrailersToBeSpawned or numberNonTrailersToBeSpawned

    -- Occupied stalls still count in the menu. Spawn highlights them and waits
    -- for Spawn vehicle once clear; it does not XY-nudge around blockers.
    for _ in ipairs(spots) do
      counterSpawnedVehiclesOfSameType = counterSpawnedVehiclesOfSameType - 1
      if counterSpawnedVehiclesOfSameType < 0 then
        hasFreeParkingSpot = true
        break
      end
    end
    if not hasFreeParkingSpot and not isTrailer and getInspectParkingSpot(facility) then
      hasFreeParkingSpot = true
    end

    local disableReason, unlockInfo
    local enabled = true
    if not hasFreeParkingSpot then
      enabled = false
      disableReason = {
        type = "noSpace",
        label  = "There are no parking spots for loaner vehicles of this type.",
      }
    end

    if not isTrailer and (getNumberOfLoanedNonTrailers(organizationId) + numberNonTrailersToBeSpawned) > 0 then
      enabled = false
      disableReason = {
        type = "limit",
        label = "You already have a loaned vehicle of that type from this organization.",
      }
    end

    local requiredSkillLevel = tonumber(rentalVehicleInfo.requiredSkillLevel or rentalVehicleInfo.requiredPoliceLevel) or 0
    local requiredReputationLvl = tonumber(rentalVehicleInfo.reputationLvl)
    local playerRepLevel = (organization.reputation and tonumber(organization.reputation.level)) or 0
    local failsSkillGate = usesSkillUnlocks and requiredSkillLevel > 0 and orgSkillLevel < requiredSkillLevel
    local failsRepGate = requiredReputationLvl ~= nil and requiredReputationLvl > playerRepLevel
    if usesSkillUnlocks and failsSkillGate then
      enabled = false
      disableReason = {
        type = "locked",
        icon = skillIcon,
        level = requiredSkillLevel,
        label = string.format("Requires %s level %d", skillLabel, requiredSkillLevel)
      }
      unlockInfo = {
        type = "minLevel",
        icon = skillIcon,
        longLabel = string.format("Requires %s level %d", skillLabel, requiredSkillLevel),
        shortLabel = string.format("lvl %d", requiredSkillLevel)
      }
    elseif failsRepGate then
      local repName = getReputationUnlockLabel(organization, requiredReputationLvl)
      local longLabel = string.format("Requires Reputation '%s' with %s", repName, organization.name)
      enabled = false
      disableReason = {
        type = "locked", icon = "peopleOutline", level = requiredReputationLvl,
        label = longLabel
      }
      unlockInfo = {
        type = "minLevel", icon = "peopleOutline", longLabel = longLabel,
        shortLabel = string.format("%s (lvl %d)", repName, requiredReputationLvl)
      }
    end

    local hourlyRental = usesIndependentHourlyRental(organization)

    local id = string.format("%s-%04d", organizationId, displayIdx)

    --ignore enable state when already bringin out this loaner
    if markedForSpawningLoaners[id] then
      enabled = true
      disableReason = nil
    end
    local offerName = configInfo and (configInfo.loanerName or configInfo.Name)
    if core_locales and core_locales.translateWithOrWithoutContext then
      offerName = core_locales.translateWithOrWithoutContext(offerName)
    end
    if type(offerName) ~= "string" or offerName == "" then
      offerName = rentalVehicleInfo.config or rentalVehicleInfo.model or "Loaner"
    end
    local hourlyRate = hourlyRental and getHourlyRateForOffer(rentalVehicleInfo, configInfo) or nil
    local item = {
      id = id,
      model = rentalVehicleInfo.model,
      config = rentalVehicleInfo.config,
      loanerCut = hourlyRental and nil or ((getOrganizationReputationLevel(organization) or {}).loanerCut or 0),
      hourlyRate = hourlyRate,
      vehOfferType = isTrailer and "trailer" or "vehicle",
      name = offerName,
      vehMileage = getRentalMileage(rentalVehicleInfo, organization) + (5.8 + 5.8 * ((math.random() * 0.2) - 0.1)) * secondsSinceSaveFileCreation, -- this roughly equates to adding 500km per day since the save was created
      thumbnail = configInfo and configInfo.preview or '/ui/images/appDefault.png',
      connector = rentalVehicleInfo.connector or "ConName",
      reputationLvl = rentalVehicleInfo.reputationLvl,
      deliveryLvl = rentalVehicleInfo.deliveryLvl,
      maxParcelPayloadKg = rentalVehicleInfo.maxParcelPayloadKg,
      enabled = enabled,
      disableReason = disableReason,
      unlockInfo = unlockInfo,
      organizationName = organization.name,
      capacity = rentalVehicleInfo.capacity or {},
      sourceFacility = {type = "deliveryProvider", id = facility.id},
      loanType = hourlyRental and "rental" or "work",
      rentalCategory = rentalVehicleInfo.rentalCategory,
      spawnWhenCommitingCargo = markedForSpawningLoaners[id] and true or false,
      requiredSkillLevel = requiredSkillLevel > 0 and requiredSkillLevel or nil,
      requiredPoliceLevel = rentalVehicleInfo.requiredPoliceLevel and (requiredSkillLevel > 0 and requiredSkillLevel or nil) or nil,
    }
    if configInfo and configInfo.capacity then
      item.capacity = {}
      for _, cap in ipairs(configInfo.capacity) do
        if cap.type == "fluid" then
          table.insert(item.capacity, {
            icon = career_modules_delivery_parcelMods.getModifierIcon(cap.type),
            labelShort = string.format("%dL", cap.amount),
            labelLong = string.format("Fluids: %dL", cap.amount),
          })
        end
      end
    end

    if enabled and usesSkillUnlocks then
      local unlockParts = {}
      if requiredSkillLevel > 0 then
        table.insert(unlockParts, string.format("%s level %d", skillLabel, requiredSkillLevel))
      end
      if requiredReputationLvl ~= nil then
        local repLabel = organization.reputationLevels[requiredReputationLvl + 2]
        if repLabel then
          table.insert(unlockParts, string.format("Reputation '%s' with %s", repLabel.label, organization.name))
        end
      end
      if #unlockParts > 0 then
        item.unlockInfo = {
          type = "minLevel",
          icon = skillIcon,
          longLabel = "Requires " .. table.concat(unlockParts, " and "),
          shortLabel = requiredSkillLevel > 0 and string.format("lvl %d", requiredSkillLevel) or "rep"
        }
      end
    elseif enabled and not usesSkillUnlocks then
      if requiredReputationLvl ~= nil then
        local repName = getReputationUnlockLabel(organization, requiredReputationLvl)
        local repLabel = string.format("%s (lvl %d)", repName, requiredReputationLvl)
        item.unlockInfo = {
          type = "minLevel", icon = "peopleOutline", longLabel = string.format("Requires reputation: %s",repLabel), shortLabel = repLabel
        }
      end
    end

    table.insert(ret, item)
  end
  return ret
end

M.spawnAndLoanVehicle = spawnAndLoanVehicle
M.returnVehicle = returnVehicle
M.getLoanedVehiclesByOrg = getLoanedVehiclesByOrg
M.formatLoanerOfferForUi = formatLoanerOfferForUi
M.formatSpawnedLoanersForUi = formatSpawnedLoanersForUi
M.getLoaningOrgsOfVehicle = getLoaningOrgsOfVehicle

M.onUpdate = onUpdate
M.onVehicleAdded = onVehicleAdded
M.onCareerActive = onCareerActive

return M
