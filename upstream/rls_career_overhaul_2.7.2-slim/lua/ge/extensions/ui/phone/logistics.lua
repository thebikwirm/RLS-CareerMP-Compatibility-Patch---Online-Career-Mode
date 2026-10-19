local M = {}
local xpConfig = require('gameplay/delivery/logisticsXPConfig')

local function broker()
  if not career_modules_delivery_broker then extensions.load('career_modules_delivery_broker') end
  return career_modules_delivery_broker
end
function M.requestBrokerState()
  local data=broker().getState()
  guihooks.trigger('phoneBrokerState',data)
  return data
end
function M.requestBrokerContainers()
  broker().requestContainers(function(data) guihooks.trigger('phoneBrokerContainers',data) end)
end
function M.requestRoutePreview(id)
  local ok,result=pcall(function() return broker().routePreview(id) end)
  return ok and result or nil
end
function M.requestPlanPreview()
  local ok,result=pcall(function() return broker().planPreview() end)
  return ok and result or nil
end
function M.brokerAction(action,payload)
  payload=payload or {}
  local b=broker()
  local function done(ok,message)
    guihooks.trigger('phoneBrokerResult',{ok=ok==true,message=message})
    M.requestBrokerState()
  end
  local ok,message,id
  if action=='reserve' then ok,message,id=b.reserve(payload.id,payload.signature)
  elseif action=='reserveMany' then ok,message,id=b.reserveMany(payload.items)
  elseif action=='cancel' then ok,message=b.cancel(payload.id)
  elseif action=='abandon' then ok,message=b.abandon(payload.id)
  elseif action=='abandonMany' then ok,message=b.abandonMany(payload.ids)
  elseif action=='cancelMany' then ok,message=b.cancelMany(payload.ids)
  elseif action=='plan' then ok,message=b.plan(payload.id)
  elseif action=='navigate' then ok,message=b.navigate(payload.id,payload.leg,payload.stopId)
  elseif action=='moveStop' then ok,message=b.moveStop(payload.index,payload.delta)
  elseif action=='showRoute' then ok,message=b.showRoute()
  elseif action=='clearRoute' then ok,message=b.clearRoute()
  elseif action=='optimizeStops' then ok,message=b.optimizeStops()
  elseif action=='preferences' then b.setPreferences(payload.value); return {ok=true}
  elseif action=='pickup' then ok,message=b.pickup(payload.id,payload.amount,payload.container,payload.cars,done)
  elseif action=='pickupBatch' then ok,message=b.pickupBatch(payload.items,done)
  elseif action=='loadHere' then ok,message=b.loadHere(payload.items,done)
  elseif action=='reserveRental' then ok,message=b.reserveRental(payload.id)
  elseif action=='cancelRental' then ok,message=b.cancelRental(payload.id)
  elseif action=='collectRental' then ok,message=b.collectRental(payload.id,done)
  elseif action=='returnRental' then ok,message=b.returnRental(payload.id,done)
  elseif action=='navigateDepot' then ok,message=b.navigateDepot()
  elseif action=='navigateRental' then ok,message=b.navigateRental(payload.id)
  else return {ok=false,message='Unknown Job Broker action.'} end
  local result={ok=ok==true,message=message,id=id}
  guihooks.trigger('phoneBrokerResult',result)
  M.requestBrokerState()
  return result
end

M.dependencies = {
  'career_modules_delivery_generator',
  'career_modules_delivery_parcelManager',
  'career_modules_delivery_parcelMods',
  'career_modules_delivery_vehicleOfferManager',
  'career_modules_delivery_progress',
  'career_modules_delivery_tutorial',
  'career_modules_delivery_materialContractManager',
  'career_modules_delivery_general',
  'career_modules_delivery_ownerOpContracts',
  'career_modules_playerAttributes',
  'freeroam_organizations'
}

local dGenerator, dParcelManager, dParcelMods, dVehOfferManager, dProgress, dTutorial, dMaterialContracts, dGeneral

local function onCareerActivated()
  dGenerator = career_modules_delivery_generator
  dParcelManager = career_modules_delivery_parcelManager
  dParcelMods = career_modules_delivery_parcelMods
  dVehOfferManager = career_modules_delivery_vehicleOfferManager
  dProgress = career_modules_delivery_progress
  dTutorial = career_modules_delivery_tutorial
  dMaterialContracts = career_modules_delivery_materialContractManager
  dGeneral = career_modules_delivery_general
end
M.onCareerActivated = onCareerActivated

local function ensureModules()
  onCareerActivated()
end

local function getCurrentLevel()
  if getCurrentLevelIdentifier and getCurrentLevelIdentifier() then
    return getCurrentLevelIdentifier()
  end
  if core_levels and getMissionFilename and getMissionFilename() ~= '' then
    return core_levels.getLevelName(getMissionFilename())
  end
  return nil
end

local function isCareerActive()
  local state = core_gamestate and core_gamestate.state and core_gamestate.state.state
  if state == 'freeroam' then return false end
  if state == 'career' then return true end
  return career_career and career_career.isActive()
end

local function sendError(code, extras)
  local payload = extras or {}
  payload.code = code
  guihooks.trigger('phoneLogisticsError', payload)
end

local function getPlayerPos()
  local veh = getPlayerVehicle(0)
  if veh then
    return veh:getPosition()
  end
  return nil
end

local function getDistanceToPos(pos, playerPos)
  if not pos or not playerPos then return -1 end
  return math.floor((pos - playerPos):length())
end

local function sortPsEntries(a, b)
  return tostring(a.path) < tostring(b.path)
end

local function collectPsEntries(list, source)
  if not source then return end
  for key, value in pairs(source) do
    local ps = value.ps or value
    if ps and ps.getPath then
      table.insert(list, {
        ps = ps,
        path = ps:getPath(),
        name = value.name or key,
        isInspectSpot = value.isInspectSpot == true
      })
    end
  end
end

local function getPrimaryParkingSpotForFacility(fac)
  if not fac then return nil, nil end

  local inspectEntries = {}
  local regularEntries = {}
  collectPsEntries(regularEntries, fac.accessPointsByName or {})
  for _, entry in ipairs(regularEntries) do
    if entry.isInspectSpot then
      table.insert(inspectEntries, entry)
    end
  end

  if #inspectEntries > 0 then
    table.sort(inspectEntries, sortPsEntries)
    return inspectEntries[1].path, inspectEntries[1].ps
  end

  if #regularEntries > 0 then
    table.sort(regularEntries, sortPsEntries)
    return regularEntries[1].path, regularEntries[1].ps
  end

  local pickupEntries = {}
  collectPsEntries(pickupEntries, fac.pickUpSpots or {})
  if #pickupEntries > 0 then
    table.sort(pickupEntries, sortPsEntries)
    return pickupEntries[1].path, pickupEntries[1].ps
  end

  local dropoffEntries = {}
  collectPsEntries(dropoffEntries, fac.dropOffSpots or {})
  if #dropoffEntries > 0 then
    table.sort(dropoffEntries, sortPsEntries)
    return dropoffEntries[1].path, dropoffEntries[1].ps
  end

  return nil, nil
end

local function getOrganizationName(fac)
  if not fac or not fac.associatedOrganization then return nil end
  local org = freeroam_organizations.getUIDataForOrg(fac.associatedOrganization)
  return (org and org.name) or fac.associatedOrganization
end

local function buildAvailableSystems(fac)
  local available = {}
  for key, value in pairs(fac.providedSystemsLookup or {}) do
    available[key] = value and true or false
  end

  local received = fac.receivedSystemsLookup or {}
  available.largeFluidDelivery = available.largeFluidDelivery or received.largeFluidDelivery or false
  available.largeDryBulkDelivery = available.largeDryBulkDelivery or received.largeDryBulkDelivery or false
  available.largeCementDelivery = available.largeCementDelivery or received.largeCementDelivery or false
  available.largeCashDelivery = available.largeCashDelivery or received.largeCashDelivery or false
  return available
end

local function hasTimedModifier(cargo)
  for _, mod in ipairs(cargo.modifiers or {}) do
    if mod.type == 'timed' then
      return true
    end
  end
  return false
end

local function getSortedKeys(tbl)
  local keys = {}
  for key in pairs(tbl or {}) do
    table.insert(keys, key)
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

local function buildLocationLabelShort(loc)
  return dParcelManager.getLocationLabelShort(loc)
end

local function buildLocationKey(loc)
  if not loc then
    return 'unknown'
  end
  if loc.type == 'multi' then
    local names = {}
    for _, dest in ipairs(loc.destinations or {}) do
      table.insert(names, buildLocationLabelShort(dest))
    end
    return 'multi:' .. table.concat(names, '|')
  end
  if loc.facId then
    return tostring(loc.facId)
  end
  return tostring(buildLocationLabelShort(loc))
end

local function buildDestinationSummary(loc, distance)
  local label = loc and buildLocationLabelShort(loc) or 'Unknown'
  local summary = {
    destinationKey = buildLocationKey(loc),
    destinationName = label,
    destinationFacilityId = loc and loc.type ~= 'multi' and loc.facId or nil,
    distance = distance or -1,
  }

  if loc and loc.type == 'multi' then
    local names = {}
    for _, dest in ipairs(loc.destinations or {}) do
      table.insert(names, buildLocationLabelShort(dest))
    end
    if #names > 0 then
      summary.destinationName = table.concat(names, ', ')
    end
    summary.destinationFacilityId = nil
  end

  return summary
end

local function buildModifierSignature(cargo)
  local modifierTypes = {}
  for _, mod in ipairs(cargo.modifiers or {}) do
    if mod.type ~= 'timed' then
      table.insert(modifierTypes, tostring(mod.type))
    end
  end
  table.sort(modifierTypes)
  return table.concat(modifierTypes, '+')
end

local function buildModifierKeys(cargo)
  local modifierKeys = {}
  for _, mod in ipairs(cargo and cargo.modifiers or {}) do
    modifierKeys[mod.type] = true
  end
  return modifierKeys
end

local function getLogisticsProgressionSnapshot()
  local attributeKey = xpConfig.LOGISTICS_ATTRIBUTE_KEY
  if not career_modules_playerAttributes or not career_branches or not career_branches.calcBranchLevelFromValue then
    return nil
  end

  local value = career_modules_playerAttributes.getAttributeValue(attributeKey)
  if type(value) ~= 'number' then
    return nil
  end

  local level, _, _, prevThreshold, nextThreshold = career_branches.calcBranchLevelFromValue(value, xpConfig.LOGISTICS_SKILL_PATH_ID)
  if type(level) ~= 'number' then
    return nil
  end

  return {
    attributeKey = attributeKey,
    level = level,
    value = value,
    prevThreshold = type(prevThreshold) == 'number' and prevThreshold or nil,
    nextThreshold = type(nextThreshold) == 'number' and nextThreshold or nil,
  }
end

local function buildUnlockMetadata(unlocked, flagDefinition, unlockFlag)
  return {
    unlockFlag = unlockFlag,
    unlockLevel = flagDefinition and flagDefinition.level or nil,
    unlockInfo = flagDefinition and flagDefinition.unlockInfo or nil,
    isUnlockedByLevel = unlocked ~= false,
    lockedReason = flagDefinition and flagDefinition.lockedReason or nil,
  }
end

local function getParcelUnlockMetadata(modifierKeys)
  local lockedBecauseOfMods, flagDefinition = dParcelMods.lockedBecauseOfMods(modifierKeys)
  local selectedFlag, selectedLevel = nil, -math.huge

  for modKey in pairs(modifierKeys or {}) do
    local modData = dParcelMods.getModData(modKey)
    local unlockFlag = modData and modData.unlockFlag or nil
    if unlockFlag and career_modules_unlockFlags and career_modules_unlockFlags.getFlagDefinition then
      local definition = career_modules_unlockFlags.getFlagDefinition(unlockFlag)
      local level = definition and definition.level or -math.huge
      if level > selectedLevel then
        selectedFlag = unlockFlag
        selectedLevel = level
      end
    elseif unlockFlag and not selectedFlag then
      selectedFlag = unlockFlag
    end
  end

  return buildUnlockMetadata(not lockedBecauseOfMods, flagDefinition, selectedFlag)
end

local function getOfferUnlockMetadata(offer)
  local unlockTag = offer and offer.vehicle and offer.vehicle.unlockTag or nil
  local enabled, flagDefinition = true, nil
  if unlockTag then
    enabled, flagDefinition = dVehOfferManager.isVehicleTagUnlocked(unlockTag)
  end
  return buildUnlockMetadata(enabled, flagDefinition, unlockTag)
end

local function buildFacilityLocation(facId, psPath)
  if not facId or not psPath then return nil end
  return {
    type = 'facilityParkingspot',
    facId = facId,
    psPath = psPath,
  }
end

local function getMaterialTemplate(materialType)
  if not materialType then return nil end
  return dGenerator.getMaterialsTemplatesById(materialType)
end

local function finalizeParcelForPhone(cargo)
  if cargo and cargo.type == 'parcel' and dGenerator.finalizeParcelItemDistanceAndRewards then
    dGenerator.finalizeParcelItemDistanceAndRewards(cargo)
  end
end

local function finalizeOfferPreview(offer)
  if dGenerator and dGenerator.finalizeVehicleOffer then
    dGenerator.finalizeVehicleOffer(offer)
  end
end

local function getVehicleThumb(offer)
  if not offer or not offer.vehicle then return '/ui/images/appDefault.png' end
  local vehicle = offer.vehicle
  local model = core_vehicles.getModel(vehicle.model)
  if not model or not model.configs or not vehicle.config then
    return '/ui/images/appDefault.png'
  end
  local config = model.configs[vehicle.config]
  return (config and config.preview) or '/ui/images/appDefault.png'
end

local function buildOfferPayload(offer)
  finalizeOfferPreview(offer)
  local unlockMetadata = getOfferUnlockMetadata(offer)

  return {
    offerId = offer.id,
    name = offer.vehicle and offer.vehicle.name or (offer.data and offer.data.type) or 'Offer',
    originName = buildLocationLabelShort(offer.origin),
    destinationName = offer.task and offer.task.destination and buildLocationLabelShort(offer.task.destination) or 'Unknown',
    reward = offer.rewards and offer.rewards.money or 0,
    distance = offer.data and offer.data.originalDistance or 0,
    requiredSkill = offer.data and offer.data.type == 'vehicle' and 'vehicleDelivery' or 'delivery',
    offerType = offer.data and offer.data.type or 'trailer',
    unlockTag = unlockMetadata.unlockFlag,
    vehicleName = offer.vehicle and offer.vehicle.name or nil,
    vehicleBrand = offer.vehicle and offer.vehicle.brand or nil,
    vehicleMileage = offer.vehicle and offer.vehicle.mileage or nil,
    thumbnail = getVehicleThumb(offer),
    unlockLevel = unlockMetadata.unlockLevel,
    unlockInfo = unlockMetadata.unlockInfo,
    isUnlockedByLevel = unlockMetadata.isUnlockedByLevel,
    lockedReason = unlockMetadata.lockedReason,
  }
end

local function countParcelRowsForFacility(facilityId, availableOnly)
  local outgoingCargo = dParcelManager.getAllCargoForFacilityUnexpiredUndelivered(facilityId) or {}
  local rowsByKey = {}

  for _, cargo in ipairs(outgoingCargo) do
    if cargo.type == 'parcel' then
      finalizeParcelForPhone(cargo)
      local unlockMetadata = getParcelUnlockMetadata(buildModifierKeys(cargo))
      if not availableOnly or unlockMetadata.isUnlockedByLevel then
        local timed = hasTimedModifier(cargo)
        local modifierSignature = buildModifierSignature(cargo)
        local rowKey = table.concat({
          buildLocationKey(cargo.destination),
          tostring(cargo.name or 'Parcel'),
          tostring(cargo.slots or 0),
          timed and 'timed' or 'plain',
          modifierSignature,
        }, '|')
        rowsByKey[rowKey] = true
      end
    end
  end

  local count = 0
  for _ in pairs(rowsByKey) do
    count = count + 1
  end
  return count
end

local function countMaterialSourcesForFacility(fac)
  local count = #(dMaterialContracts.getOffersForFacility(fac.id) or {})
  for _, active in ipairs(dMaterialContracts.getActiveContracts() or {}) do
    if active.sourceFacId == fac.id then count = count + 1 end
  end
  return count
end

local function countOffersForFacility(facilityId, offerType, availableOnly)
  local count = 0

  for _, offer in ipairs(dVehOfferManager.getAllOfferAtFacilityUnexpired(facilityId) or {}) do
    local currentType = offer.data and offer.data.type or 'trailer'
    local unlockMetadata = getOfferUnlockMetadata(offer)
    if currentType == offerType and offer.task and offer.task.destination and (not availableOnly or unlockMetadata.isUnlockedByLevel) then
      count = count + 1
    end
  end

  return count
end

local function buildParcelDestinationSections(facilityId)
  local outgoingCargo = dParcelManager.getAllCargoForFacilityUnexpiredUndelivered(facilityId) or {}
  local sectionsByKey = {}
  local orderedSections = {}

  for _, cargo in ipairs(outgoingCargo) do
    if cargo.type == 'parcel' then
      finalizeParcelForPhone(cargo)
      local distance = cargo.data and cargo.data.originalDistance or -1
      local destination = buildDestinationSummary(cargo.destination, distance)
      local section = sectionsByKey[destination.destinationKey]
      if not section then
        section = {
          destinationKey = destination.destinationKey,
          destinationName = destination.destinationName,
          destinationFacilityId = destination.destinationFacilityId,
          distance = destination.distance,
          rows = {},
          _rowsByKey = {},
        }
        sectionsByKey[destination.destinationKey] = section
        table.insert(orderedSections, section)
      elseif (section.distance or -1) < 0 and (distance or -1) >= 0 then
        section.distance = distance
      end

      local timed = hasTimedModifier(cargo)
      local modifierSignature = buildModifierSignature(cargo)
      local rowKey = table.concat({
        tostring(cargo.name or 'Parcel'),
        tostring(cargo.slots or 0),
        timed and 'timed' or 'plain',
        modifierSignature,
      }, '|')

      local row = section._rowsByKey[rowKey]
      if not row then
        local modifierKeys = buildModifierKeys(cargo)
        local unlockMetadata = getParcelUnlockMetadata(modifierKeys)
        row = {
          rowId = table.concat({
            destination.destinationKey,
            tostring(cargo.name or 'Parcel'),
            tostring(cargo.slots or 0),
            timed and 'timed' or 'plain',
            modifierSignature,
          }, '|'),
          representativeCargoId = cargo.id,
          parcelName = cargo.name or 'Parcel',
          quantity = 0,
          slotSize = cargo.slots or 0,
          rewardPerItem = cargo.rewards and cargo.rewards.money or 0,
          rewardTotal = 0,
          weightPerItem = cargo.weight or 0,
          weightTotal = 0,
          timed = timed,
          unlockFlag = unlockMetadata.unlockFlag,
          unlockLevel = unlockMetadata.unlockLevel,
          unlockInfo = unlockMetadata.unlockInfo,
          isUnlockedByLevel = unlockMetadata.isUnlockedByLevel,
          lockedReason = unlockMetadata.lockedReason,
        }
        section._rowsByKey[rowKey] = row
        table.insert(section.rows, row)
      end

      row.quantity = row.quantity + 1
      row.rewardTotal = row.rewardTotal + (cargo.rewards and cargo.rewards.money or 0)
      row.weightTotal = row.weightTotal + (cargo.weight or 0)
    end
  end

  for _, section in ipairs(orderedSections) do
    section.rowCount = #section.rows
    section._rowsByKey = nil
    table.sort(section.rows, function(a, b)
      if (a.slotSize or 0) ~= (b.slotSize or 0) then
        return (a.slotSize or 0) < (b.slotSize or 0)
      end
      if tostring(a.parcelName) ~= tostring(b.parcelName) then
        return tostring(a.parcelName) < tostring(b.parcelName)
      end
      return (a.rewardTotal or 0) > (b.rewardTotal or 0)
    end)
  end

  table.sort(orderedSections, function(a, b)
    local distA = a.distance and a.distance >= 0 and a.distance or math.huge
    local distB = b.distance and b.distance >= 0 and b.distance or math.huge
    if distA ~= distB then return distA < distB end
    return tostring(a.destinationName) < tostring(b.destinationName)
  end)

  return orderedSections
end

local function buildMaterialSourceSections(fac)
  local sources = {}

  local function appendContract(contract, isActive)
    local material = getMaterialTemplate(contract.materialType)
    if not material then return end
    local amount = isActive and contract.remainingAmount or contract.totalAmount
    local destination = buildDestinationSummary(contract.destination, contract.routeDistance or -1)
    destination.destinationFacilityId = contract.destinationFacId
    destination.destinationParkingSpotPath = contract.destination and contract.destination.psPath
    destination.estimatedRewardPerUnit = (contract.quotedRewards.money or 0) / math.max(1, contract.totalAmount)
    table.insert(sources, {
      storageId = contract.id,
      contractId = contract.id,
      isActiveContract = isActive,
      materialType = contract.materialType,
      materialName = material.name or contract.materialType,
      amountAvailable = amount,
      totalAmount = contract.totalAmount,
      units = contract.units or material.units or 'L',
      rewardTotal = contract.quotedRewards.money or 0,
      rewardPerUnit = (contract.quotedRewards.money or 0) / math.max(1, contract.totalAmount),
      rewardPerKg = (contract.quotedRewards.money or 0) / math.max(1, contract.totalAmount * (material.density or 1)),
      density = material.density,
      weightAvailable = amount * (material.density or 0),
      standardLoad = contract.standardLoad,
      standardLoadCount = contract.quantityMode ~= "exact" and contract.loadCount or nil,
      distance = contract.routeDistance,
      expiresIn = not isActive and math.max(0, (contract.offerExpiresAt or 0) - dGeneral.time()) or nil,
      deliveredAmount = isActive and contract.deliveredAmount or nil,
      inTransitAmount = isActive and contract.inTransitAmount or nil,
      remainingAmount = isActive and contract.remainingAmount or nil,
      paidMoney = isActive and contract.paidMoney or nil,
      remainingValue = isActive and contract.remainingValue or nil,
      abandonmentFine = isActive and contract.abandonmentFine or nil,
      destinationCount = 1,
      destinations = {destination},
    })
  end

  for _, active in ipairs(dMaterialContracts.getActiveContracts() or {}) do
    if active.sourceFacId == fac.id then appendContract(active, true) end
  end
  for _, offer in ipairs(dMaterialContracts.getOffersForFacility(fac.id) or {}) do appendContract(offer, false) end

  table.sort(sources, function(a, b)
    if a.isActiveContract ~= b.isActiveContract then return a.isActiveContract end
    if (a.distance or 0) ~= (b.distance or 0) then return (a.distance or 0) < (b.distance or 0) end
    return tostring(a.materialName) < tostring(b.materialName)
  end)

  return sources
end

local function buildOfferDestinationSections(facilityId, offerType)
  local rawOffers = dVehOfferManager.getAllOfferAtFacilityUnexpired(facilityId) or {}
  local sectionsByKey = {}
  local orderedSections = {}

  for _, offer in ipairs(rawOffers) do
    local payload = buildOfferPayload(offer)
    if payload.offerType == offerType and offer.task and offer.task.destination then
      local destination = buildDestinationSummary(offer.task.destination, payload.distance)
      local section = sectionsByKey[destination.destinationKey]
      if not section then
        section = {
          destinationKey = destination.destinationKey,
          destinationName = destination.destinationName,
          destinationFacilityId = destination.destinationFacilityId,
          distance = destination.distance,
          rows = {},
        }
        sectionsByKey[destination.destinationKey] = section
        table.insert(orderedSections, section)
      elseif (section.distance or -1) < 0 and (payload.distance or -1) >= 0 then
        section.distance = payload.distance
      end

      table.insert(section.rows, payload)
    end
  end

  for _, section in ipairs(orderedSections) do
    table.sort(section.rows, function(a, b)
      if (a.reward or 0) ~= (b.reward or 0) then
        return (a.reward or 0) > (b.reward or 0)
      end
      return tostring(a.name) < tostring(b.name)
    end)
    section.rowCount = #section.rows
  end

  table.sort(orderedSections, function(a, b)
    local distA = a.distance and a.distance >= 0 and a.distance or math.huge
    local distB = b.distance and b.distance >= 0 and b.distance or math.huge
    if distA ~= distB then return distA < distB end
    return tostring(a.destinationName) < tostring(b.destinationName)
  end)

  return orderedSections
end

local function buildFacilityBadges(parcelCount, materialCount, vehicleCount, trailerCount)
  local badges = {}
  if parcelCount > 0 then table.insert(badges, 'parcel') end
  if materialCount > 0 then table.insert(badges, 'material') end
  if vehicleCount > 0 then table.insert(badges, 'vehicle') end
  if trailerCount > 0 then table.insert(badges, 'trailer') end
  return badges
end

local function buildFacilitySummary(fac, playerPos)
  local primaryParkingSpotPath, primaryPs = getPrimaryParkingSpotForFacility(fac)
  local position = primaryPs and primaryPs.pos or nil
  if not position and primaryParkingSpotPath then
    position = dGenerator.getLocationCoordinates({
      type = 'facilityParkingspot',
      facId = fac.id,
      psPath = primaryParkingSpotPath
    })
  end

  local parcelCount = countParcelRowsForFacility(fac.id)
  local materialCount = countMaterialSourcesForFacility(fac)
  local vehicleCount = countOffersForFacility(fac.id, 'vehicle')
  local trailerCount = countOffersForFacility(fac.id, 'trailer')
  local availableParcelCount = countParcelRowsForFacility(fac.id, true)
  local availableVehicleCount = countOffersForFacility(fac.id, 'vehicle', true)
  local availableTrailerCount = countOffersForFacility(fac.id, 'trailer', true)

  local oo = career_modules_delivery_ownerOpContracts
  local contractCount = oo and oo.countContractsForFacility and oo.countContractsForFacility(fac.id) or 0
  local ownerOpHub = false
  local emp = career_modules_delivery_employment
  if emp and emp.isOwnerOpYardFacility and emp.isOwnerOpYardFacility(fac) then
    ownerOpHub = true
  elseif oo and oo.isOwnerOpHubFacilityId then
    ownerOpHub = oo.isOwnerOpHubFacilityId(fac.id) and true or false
  end

  return {
    id = fac.id,
    name = fac.name,
    organizationId = fac.associatedOrganization,
    organizationName = getOrganizationName(fac),
    preview = fac.preview,
    primaryParkingSpotPath = primaryParkingSpotPath,
    position = position and { x = position.x, y = position.y, z = position.z } or nil,
    distance = getDistanceToPos(position, playerPos),
    availableSystems = buildAvailableSystems(fac),
    ownerOpHub = ownerOpHub,
    contractCount = contractCount,
    counts = {
      parcelGroups = parcelCount,
      materialGroups = materialCount,
      vehicleOffers = vehicleCount,
      trailerOffers = trailerCount,
      availableParcelGroups = availableParcelCount,
      availableVehicleOffers = availableVehicleCount,
      availableTrailerOffers = availableTrailerCount,
      contracts = contractCount,
    },
    totalVisibleJobs = parcelCount + materialCount + vehicleCount + trailerCount,
    totalAvailableByLevelJobs = availableParcelCount + availableVehicleCount + availableTrailerCount,
    badges = buildFacilityBadges(parcelCount, materialCount, vehicleCount, trailerCount)
  }
end

local function ensureOwnerOp()
  if not career_modules_delivery_ownerOpContracts and extensions and extensions.load then
    pcall(extensions.load, "career_modules_delivery_ownerOpContracts")
  end
  return career_modules_delivery_ownerOpContracts
end

local function isOwnerOpHubFacility(fac)
  if not fac then return false end
  local emp = career_modules_delivery_employment
  if emp and emp.isOwnerOpYardFacility and emp.isOwnerOpYardFacility(fac) then
    return true
  end
  local oo = ensureOwnerOp()
  return oo and oo.isOwnerOpHubFacilityId and oo.isOwnerOpHubFacilityId(fac.id)
end

local function requestFacilityList()
  ensureModules()
  if not isCareerActive() then
    guihooks.trigger('phoneLogisticsFacilityList', {
      careerActive = false,
      levelId = getCurrentLevel() or '',
      generatedAt = os.time(),
      facilities = {}
    })
    return
  end

  ensureOwnerOp()
  dGenerator.triggerAllGenerators()

  local tutorialActive = dTutorial.isCargoDeliveryTutorialActive and dTutorial.isCargoDeliveryTutorialActive() or false
  local playerPos = getPlayerPos()
  local facilities = {}

  for _, fac in ipairs(dGenerator.getFacilities() or {}) do
    if dProgress.isFacilityVisible(fac.id, tutorialActive) then
      local summary = buildFacilitySummary(fac, playerPos)
      if (summary.totalVisibleJobs or 0) > 0 or summary.ownerOpHub then
        table.insert(facilities, summary)
      end
    end
  end

  table.sort(facilities, function(a, b)
    local distA = a.distance and a.distance >= 0 and a.distance or math.huge
    local distB = b.distance and b.distance >= 0 and b.distance or math.huge
    if distA ~= distB then return distA < distB end
    return tostring(a.name) < tostring(b.name)
  end)

  guihooks.trigger('phoneLogisticsFacilityList', {
    careerActive = true,
    levelId = getCurrentLevel() or '',
    generatedAt = os.time(),
    facilities = facilities
  })
end
M.requestFacilityList = requestFacilityList

local function requestFacilityDetail(facilityId)
  ensureModules()
  if not isCareerActive() then
    sendError('career_inactive', { facilityId = facilityId })
    return
  end

  ensureOwnerOp()
  dGenerator.triggerAllGenerators()

  local fac = dGenerator.getFacilityById(facilityId)
  if not fac then
    sendError('facility_not_found', { facilityId = facilityId })
    return
  end

  local playerPos = getPlayerPos()
  local primaryParkingSpotPath, primaryPs = getPrimaryParkingSpotForFacility(fac)
  local position = primaryPs and primaryPs.pos or nil
  if not position and primaryParkingSpotPath then
    position = dGenerator.getLocationCoordinates({
      type = 'facilityParkingspot',
      facId = fac.id,
      psPath = primaryParkingSpotPath
    })
  end

  local oo = career_modules_delivery_ownerOpContracts
  local board = oo and oo.getBoardState and oo.getBoardState(facilityId) or {
    unlocked = false,
    unlockLevel = 30,
    level = 0,
    contracts = {},
    active = nil,
  }

  guihooks.trigger('phoneLogisticsFacilityDetail', {
    facilityId = facilityId,
    generatedAt = os.time(),
    progression = {
      logistics = getLogisticsProgressionSnapshot()
    },
    facility = {
      id = fac.id,
      name = fac.name,
      organizationId = fac.associatedOrganization,
      organizationName = getOrganizationName(fac),
      preview = fac.preview,
      longDescription = fac.facilityInformation or fac.description,
      primaryParkingSpotPath = primaryParkingSpotPath,
      availableSystems = buildAvailableSystems(fac),
      distance = getDistanceToPos(position, playerPos),
      ownerOpHub = isOwnerOpHubFacility(fac),
    },
    contractsUnlocked = board.unlocked == true,
    contractsUnlockLevel = board.unlockLevel or 30,
    contractsLevel = board.level or 0,
    contracts = board.contracts or {},
    activeContract = board.active,
    onShift = board.onShift == true,
    parcelDestinations = buildParcelDestinationSections(fac.id),
    materialSources = buildMaterialSourceSections(fac),
    vehicleOfferDestinations = buildOfferDestinationSections(fac.id, 'vehicle'),
    trailerOfferDestinations = buildOfferDestinationSections(fac.id, 'trailer')
  })
end
M.requestFacilityDetail = requestFacilityDetail

local function navigateToFacility(facilityId, parkingSpotPath)
  ensureModules()
  local fac = dGenerator.getFacilityById(facilityId)
  if not fac then
    sendError('facility_not_found', { facilityId = facilityId })
    return
  end

  local targetParkingSpotPath = parkingSpotPath
  if not targetParkingSpotPath or targetParkingSpotPath == '' then
    targetParkingSpotPath = select(1, getPrimaryParkingSpotForFacility(fac))
  end

  if not targetParkingSpotPath then
    sendError('facility_missing_route_target', { facilityId = facilityId })
    return
  end

  local toPos = dGenerator.getLocationCoordinates({
    type = 'facilityParkingspot',
    facId = fac.id,
    psPath = targetParkingSpotPath
  })
  if toPos then
    core_groundMarkers.setPath(toPos, { clearPathOnReachingTarget = true })
  end
end
M.navigateToFacility = navigateToFacility

local function requestContracts(facilityId)
  local oo = ensureOwnerOp()
  if not oo or not oo.getBoardState then
    sendError('owner_op_unavailable')
    return
  end
  guihooks.trigger('phoneLogisticsContracts', oo.getBoardState(facilityId))
end
M.requestContracts = requestContracts

local function acceptContract(contractId, opts)
  local oo = ensureOwnerOp()
  if not oo or not oo.acceptContract then
    sendError('owner_op_unavailable')
    return
  end
  local ok, msg = oo.acceptContract(contractId, opts or {})
  guihooks.trigger('phoneLogisticsContractResult', {
    ok = ok and true or false,
    message = msg,
    contractId = contractId,
    board = oo.getBoardState and oo.getBoardState() or nil,
  })
end
M.acceptContract = acceptContract

local function abandonHubContract(contractId)
  local oo = ensureOwnerOp()
  if not oo or not oo.abandonHubContract then
    sendError('owner_op_unavailable')
    return
  end
  local ok, msg = oo.abandonHubContract(contractId)
  guihooks.trigger('phoneLogisticsContractResult', {
    ok = ok and true or false,
    message = msg,
    abandoned = ok and true or false,
    board = oo.getBoardState and oo.getBoardState() or nil,
  })
end
M.abandonHubContract = abandonHubContract

local function stageCarHaulTrip(opts)
  local oo = ensureOwnerOp()
  if not oo or not oo.stageCarHaulTrip then
    sendError('owner_op_unavailable')
    return
  end
  opts = opts or {}
  local ok, msg = oo.stageCarHaulTrip(opts.selectedVehicleKeys or opts.selectedKeys)
  guihooks.trigger('phoneLogisticsContractResult', {
    ok = ok and true or false,
    message = msg,
    board = oo.getBoardState and oo.getBoardState() or nil,
  })
end
M.stageCarHaulTrip = stageCarHaulTrip

return M
