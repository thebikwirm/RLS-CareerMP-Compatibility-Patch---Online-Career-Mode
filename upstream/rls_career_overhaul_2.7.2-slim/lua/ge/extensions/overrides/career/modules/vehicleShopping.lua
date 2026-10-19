-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
-- The legacy career_modules_insurance API no longer exists in 0.39; look it up with rawget so the
-- extension autoloader does not log "extension unavailable" on every vehicle-shopping call.
local legacyInsurance = rawget(_G, "career_modules_insurance")

M.dependencies =
  {'career_career', 'career_modules_inspectVehicle', 'career_modules_valueCalculator', 'util_configListGenerator',
   'freeroam_organizations', 'career_modules_bank', 'career_modules_business_businessInventory'}

M.limitedMileageDealerSchemaVersion = 1

-- Bag for config/state/helpers so this chunk stays under LuaJIT's 200-local limit.
local C = {
  moduleVersion = 69,
  valuationSchemaVersion = 12,
  vehicleDeliveryDelay = 60,
  vehicleOfferTimeToLive = 10 * 60,
  timeToRemoveSoldVehicle = 5 * 60,
  dealershipTimeBetweenOffers = 1 * 60,
  salesTax = 0.07,
  customLicensePlatePrice = 300,
  dealershipPurchaseReputationGain = 2000,
  missingYearsFallbackModelYear = 2023,
  refreshInterval = 5,
  tetherRange = 4,
  POLICE_DEALERSHIP_UNLOCK_LEVEL = 10,
  POLICE_DEALERSHIP_IDS = {
    policeDealership = true,
    poliziaAuto = true,
  },
  MILES_TO_METERS = 1609.344,
  BASE_ANNUAL_MILES = 11500,
  MAX_USED_MILES = 300000,
  FACTORY_MIN_MILES = 5,
  FACTORY_MAX_MILES = 500,
  REMOTE_PURCHASE_LEVEL = 2,
  DELIVERY_DISCOUNT_LEVEL = 3,
  DELIVERY_DISCOUNT_AT_LEVEL_3 = 0.25,
  mileageProfiles = {
    fastAutomotiveDealership = {annualMiles = 2500, minFactor = 0.5, maxFactor = 1.4, minMiles = 2000, maxMiles = 40000, wearFactor = 3.0},
    jeffersonmotors = {minFactor = 0.28, maxFactor = 0.62, minMiles = 18000, maxMiles = 130000, timeCapsuleChance = 0.05},
    belascoAuto = {minFactor = 0.70, maxFactor = 1.05, minMiles = 250, maxMiles = 220000},
    richsmotorcompany = {minFactor = 0.22, maxFactor = 0.60, minMiles = 1000, maxMiles = 80000, timeCapsuleChance = 0.05},
    quarrysideAutoSales = {minFactor = 1.00, maxFactor = 1.45, minMiles = 60000, maxMiles = 280000},
    discountedDealership = {minFactor = 1.15, maxFactor = 1.75, minMiles = 70000, maxMiles = 350000},
    policeDealership = {annualMiles = 18000, minFactor = 0.85, maxFactor = 1.25, minMiles = 60000, maxMiles = 180000},
    serviceDealership = {annualMiles = 17000, minFactor = 0.85, maxFactor = 1.30, minMiles = 50000, maxMiles = 200000},
    frameDealership = {minFactor = 1.05, maxFactor = 1.65, minMiles = 90000, maxMiles = 320000},
    trailerShop = {annualMiles = 7000, minFactor = 0.65, maxFactor = 1.25, minMiles = 10000, maxMiles = 150000},
    truckShop = {annualMiles = 30000, minFactor = 0.85, maxFactor = 1.35, minMiles = 80000, maxMiles = 600000},
    importDealer = {minFactor = 0.75, maxFactor = 1.20, minMiles = 10000, maxMiles = 300000},
    loanerDealership = {annualMiles = 18000, minFactor = 0.95, maxFactor = 1.35, minMiles = 80000, maxMiles = 240000},
    joesJunkDealership = {minFactor = 1.35, maxFactor = 2.05, minMiles = 120000, maxMiles = 400000},
    raceTab = {annualMiles = 2500, minFactor = 0.50, maxFactor = 1.00, minMiles = 10000, maxMiles = 40000},
    asotv = {annualMiles = 2500, minFactor = 0.50, maxFactor = 1.00, minMiles = 10000, maxMiles = 40000},
    private = {minFactor = 0.75, maxFactor = 1.55, minMiles = 500, maxMiles = 350000, timeCapsuleChance = 0.015},
  },
  POLICE_SKILL_PATH_IDS = {"careerSkills-emergency", "emergency"},
  privateSellersPreview = "/levels/west_coast_usa/facilities/privateSeller_dealership.jpg",
  TUTORIAL_BUY_VEHICLE_DEALERSHIP_ID = "apmStarterVehicles",
}
C.vehiclesPerDealership = C.vehicleOfferTimeToLive / C.dealershipTimeBetweenOffers

local state = {
  vehiclesInShop = {},
  sellersInfos = {},
  otherMapsData = {},
  discoveredDealers = {},
  vehicleWatchlist = {},
  buyingAvailable = true,
  marketplaceAvailable = true,
  lastSnapshotByShopId = {},
  lastDelta = { seq = 0, added = {}, removed = {}, sold = {}, updated = {} },
  deltaSeq = 0,
  pendingSoldShopIds = {},
  soldVehicles = {},
  uiOpen = false,
  shoppingUiOpenCount = 0,
  refreshAccumulator = 0,
  nextShopUpdateTime = 0,
  rtPendingFleetPurchases = {},
  rtPendingFleetProcessing = false,
  rtPendingTimerFailureGraceSec = 20,
  rtPendingDriveStaleSec = 20 * 60,
  vehicleCache = {
    regularVehicles = {},
    dealershipCache = {},
    lastCacheTime = 0,
    cacheValid = false,
  },
  badConfigQuarantine = {},
  badConfigLogOnce = {},
  validationStats = {
    quarantined = 0,
    loadDropped = 0,
    cacheDropped = 0,
    generationDropped = 0,
  },
  purchaseMenuOpen = false,
  fleetBusinessType = "racingTeam",
  inspectingVehicleShopId = nil,
  spawnFollowUpActions = nil,
  rewardVehicleGrantData = nil,
  deleteAddedVehicle = nil,
  removeNonUsedPlayerVehicles = nil,
}

local U = {}
U.populationSelector = require('gameplay/vehiclePopulationSelector')

-- Utility functions
U.generateShopId = function()
  local shopId = 0
  while true do
    shopId = math.floor(math.random() * 1000000)
    local found = false
    for _, vehInfo in ipairs(state.vehiclesInShop) do
      if vehInfo.shopId == shopId then
        found = true
        break
      end
    end
    if not found then
      return shopId
    end
  end
end

U.getBranchLevelByPathIds = function(pathIds)
  if not career_branches or not career_branches.getBranchLevel then
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

U.getPoliceSkillLevel = function()
  local level = U.getBranchLevelByPathIds(C.POLICE_SKILL_PATH_IDS)
  if level > 0 then
    return level
  end

  if career_modules_playerAttributes and career_modules_playerAttributes.getAttributeValue and career_branches and career_branches.calcBranchLevelFromValue then
    local value = tonumber(career_modules_playerAttributes.getAttributeValue("careerSkills-emergency")) or 0
    for _, skillPathId in ipairs(C.POLICE_SKILL_PATH_IDS) do
      local branchLevel = career_branches.calcBranchLevelFromValue(value, skillPathId)
      level = math.max(level, tonumber(branchLevel) or 0)
    end
  end

  return math.max(0, math.floor(level))
end

U.isPoliceDealershipLocked = function(dealershipId)
  return C.POLICE_DEALERSHIP_IDS[dealershipId] and U.getPoliceSkillLevel() < C.POLICE_DEALERSHIP_UNLOCK_LEVEL or false
end

U.getPoliceDealershipLockLabel = function()
  return string.format("Police Dealership requires Police Skill level %d", C.POLICE_DEALERSHIP_UNLOCK_LEVEL)
end

U.getVehicleInfoByShopId = function(shopId)
  if not shopId then
    return nil
  end
  local numShopId = tonumber(shopId)
  if not numShopId then
    log("W", "Career", "getVehicleInfoByShopId: Invalid shopId type: " .. tostring(shopId))
    return nil
  end
  for _, vehInfo in ipairs(state.vehiclesInShop) do
    if vehInfo.shopId == numShopId then
      return vehInfo
    end
  end
  return nil
end

U.isCarMeetShopVehicle = function(vehicleInfo)
  return vehicleInfo and (vehicleInfo.source == "carMeet" or vehicleInfo.sellerId == "carMeet")
end

U.normalizeVehicleShopTiming = function(vehicleInfo, currentTime)
  if not vehicleInfo then return end
  currentTime = currentTime or os.time()
  vehicleInfo.generationTime = tonumber(vehicleInfo.generationTime) or currentTime
  vehicleInfo.offerTTL = tonumber(vehicleInfo.offerTTL) or (24 * 60 * 60)
end


U.registerCarMeetVehicle = function(vehicleInfo)
  if not vehicleInfo then return nil end
  local info = deepcopy(vehicleInfo)
  info.shopId = info.shopId or U.generateShopId()
  info.sellerId = "carMeet"
  info.sellerName = info.sellerName or "Car Meet Owner"
  info.negotiationPossible = true
  info.playerStartsNegotiation = true
  info.hideMarketValue = true
  info.tax = tonumber(info.tax) or 0
  info.fees = tonumber(info.fees) or 0
  info.Value = tonumber(info.Value) or tonumber(info.marketValue) or 10000
  info.marketValue = tonumber(info.marketValue) or info.Value
  info.marketValueBase = info.marketValue
  info.Mileage = tonumber(info.Mileage) or 0
  info.mapId = getCurrentLevelIdentifier()
  U.normalizeVehicleShopTiming(info)
  if career_modules_marketplace and career_modules_marketplace.generatePersonality then
    info.negotiationPersonality = info.negotiationPersonality or career_modules_marketplace.generatePersonality(false)
    if info.negotiationPersonality and info.negotiationPersonality.name then
      info.sellerName = info.negotiationPersonality.name
    end
  end
  local priceMultiplier = (info.negotiationPersonality and info.negotiationPersonality.priceMultiplier) or 1
  priceMultiplier = math.max(0.95, math.min(1.05, tonumber(priceMultiplier) or 1))
  info.priceMultiplier = priceMultiplier
  info.valueBase = tonumber(info.valueBase) or info.marketValue * priceMultiplier
  local vehicleBuyMult = career_modules_valueCalculator.getVehicleBuyMarketMultiplier()
  info.Value = U.getRoundedPrice(info.valueBase * vehicleBuyMult, info.priceRoundingType or "private")
  table.insert(state.vehiclesInShop, info)
  return info.shopId
end

U.removeCarMeetVehicles = function()
  for i = #state.vehiclesInShop, 1, -1 do
    if state.vehiclesInShop[i].sellerId == "carMeet" or state.vehiclesInShop[i].source == "carMeet" then
      table.remove(state.vehiclesInShop, i)
    end
  end
end

U.generateSoldVehicleValue = function(shopId)
  local vehicleInfo = U.getVehicleInfoByShopId(shopId)
  if not vehicleInfo then return 0 end
  local value = vehicleInfo.Value * (0.9 + math.random() * 0.1)
  return round(value / 10) * 10
end

U.getRoundedPrice = function(value, priceRoundingType)
  if priceRoundingType == "prestige" then
    local thousands = math.floor(value / 1000)
    local candidate495 = thousands * 1000 + 495
    if value <= candidate495 then return candidate495 end
    local candidate995 = thousands * 1000 + 995
    if value <= candidate995 then return candidate995 end
    return (thousands + 1) * 1000 + 495
  elseif priceRoundingType == "private" then
    return math.ceil(value / 100) * 100
  elseif priceRoundingType == "dealer" then
    return math.ceil(value / 20) * 20
  else
    return math.ceil(value / 10) * 10
  end
end

U.getEligibleVehiclesWithoutDealershipVehicles = function(eligibleVehicles, seller)
  local eligibleVehiclesWithoutDealershipVehicles = deepcopy(eligibleVehicles)
  local configsInDealership = {}
  for _, vehicleInfo in ipairs(state.vehiclesInShop) do
    if vehicleInfo.sellerId == seller.id then
      configsInDealership[vehicleInfo.model_key] = configsInDealership[vehicleInfo.model_key] or {}
      configsInDealership[vehicleInfo.model_key][vehicleInfo.key] = true
    end
  end

  for i = #eligibleVehiclesWithoutDealershipVehicles, 1, -1 do
    local vehicleInfo = eligibleVehiclesWithoutDealershipVehicles[i]
    if configsInDealership[vehicleInfo.model_key] and configsInDealership[vehicleInfo.model_key][vehicleInfo.key] then
      table.remove(eligibleVehiclesWithoutDealershipVehicles, i)
    end
  end
  return eligibleVehiclesWithoutDealershipVehicles
end

U.getUiDealershipsData = function(unsoldVehicles)
  local dealerships = freeroam_facilities.getFacilitiesByType("dealership")
  local isInTutorial = career_modules_tutorial and career_modules_tutorial.isActive()
    and career_modules_tutorial.getCurrentStep() == "09spmSignup"
  local vehicleCountPerDealership = {}
  for _, vehicle in ipairs(unsoldVehicles) do
    if not U.isCarMeetShopVehicle(vehicle) then
      vehicleCountPerDealership[vehicle.sellerId] = (vehicleCountPerDealership[vehicle.sellerId] or 0) + 1
    end
  end
  local data = {}
  if dealerships then
    for _, dealership in ipairs(dealerships) do
      local policeLocked = U.isPoliceDealershipLocked(dealership.id)
      local tutorialLocked = isInTutorial and dealership.id ~= C.TUTORIAL_BUY_VEHICLE_DEALERSHIP_ID
      local discovered = U.isDealerDiscovered(dealership)
      local accessInfo = U.getSellerAccessInfo(dealership)
      table.insert(data, {
        id = dealership.id,
        name = _tr(dealership.name),
        description = _tr(dealership.description),
        vehicleCount = vehicleCountPerDealership[dealership.id] or 0,
        preview = dealership.preview,
        icon = "carDealer",
        remotePurchaseOnly = dealership.remotePurchaseOnly or false,
        hiddenFromDealerList = dealership.hiddenFromDealerList or not discovered,
        undiscovered = not discovered,
        salesChannel = accessInfo.salesChannel,
        remotePurchaseAllowed = accessInfo.remotePurchaseAllowed,
        garageDeliveryAllowed = accessInfo.garageDeliveryAllowed,
        deliveryDiscount = accessInfo.deliveryDiscount,
        disabled = policeLocked or tutorialLocked,
        disabledReason = policeLocked and U.getPoliceDealershipLockLabel()
          or (tutorialLocked and _tr("ui.career.vehicleShopping.disabledDuringOnboarding") or nil),
      })
    end
  end
  table.sort(data, function(a,b) return a.name < b.name end)
  table.insert(data, {
    id = "private",
    name = _tr("ui.career.vehicleShopping.privateSellers"),
    vehicleCount = vehicleCountPerDealership["private"] or 0,
    preview = C.privateSellersPreview,
    icon = "personSolid",
    disabled = isInTutorial,
    disabledReason = isInTutorial and _tr("ui.career.vehicleShopping.disabledDuringOnboarding") or nil,
  })
  return data
end

U.sanitizeVehicleForUi = function(v)
  local t = {}
  t.shopId = v.shopId

  for k, val in pairs(v) do
    local ty = type(val)
    if k == "pos" then
      if val and val.x then
        t.pos = {
          x = val.x,
          y = val.y,
          z = val.z
        }
      end
    elseif k == "precomputedFilter" or k == "filter" or k == "distanceVec" then
    elseif ty == "function" or ty == "userdata" then
    else
      t[k] = val
    end
  end
  -- core_vehicles substitutes the generic app icon when a config has no image.
  -- Fall back to the model image, or send nothing so the UI hides the picture.
  if type(t.preview) == "string" and t.preview:find("appDefault.png", 1, true) then
    local modelData = t.model_key and core_vehicles.getModel(t.model_key) or nil
    local modelPreview = modelData and modelData.model and modelData.model.preview
    if type(modelPreview) == "string" and not modelPreview:find("appDefault.png", 1, true) then
      t.preview = modelPreview
    else
      t.preview = nil
    end
  end
  return t
end

U.convertKeysToStrings = function(t)
  local unsoldVehicles = {}
  local soldVehiclesResult = {}
  for k, v in ipairs(t) do
    if v.soldViewCounter and v.soldViewCounter > 0 then
      table.insert(soldVehiclesResult, v)
    else
      table.insert(unsoldVehicles, v)
    end
  end
  return unsoldVehicles, soldVehiclesResult
end

U.sanitizeOrganizationForUi = function(org)
  if not org then
    return nil
  end

  local sanitizedOrg = {
    reputationLevels = {},
    reputation = {}
  }

  if org.reputation then
    local repLevel = org.reputation.level or 0
    if type(repLevel) ~= "number" then
      repLevel = 0
    end
    sanitizedOrg.reputation.level = repLevel
    sanitizedOrg.reputation.levelIndex = repLevel + 2
    sanitizedOrg.reputation.value = org.reputation.value
    sanitizedOrg.reputation.curLvlProgress = org.reputation.curLvlProgress
    sanitizedOrg.reputation.neededForNext = org.reputation.neededForNext
    sanitizedOrg.reputation.prevThreshold = org.reputation.prevThreshold
    sanitizedOrg.reputation.nextThreshold = org.reputation.nextThreshold
  else
    sanitizedOrg.reputation.level = 0
    sanitizedOrg.reputation.levelIndex = 2
  end

  if org.reputationLevels then
    for idx, lvl in pairs(org.reputationLevels) do
      sanitizedOrg.reputationLevels[idx] = {
        hiddenFromDealerList = lvl and lvl.hiddenFromDealerList or nil
      }
    end
  end

  return sanitizedOrg
end

U.collectOrganizationsForUi = function(facilities)
  local organizations = {}
  if not facilities or not facilities.dealerships then
    return organizations
  end

  local organizationsById = freeroam_organizations.getOrganizations()
  for _, dealer in ipairs(facilities.dealerships) do
    local orgId = dealer.associatedOrganization
    if orgId and not organizations[orgId] then
      local org = organizationsById and organizationsById[orgId]
      local sanitizedOrg = U.sanitizeOrganizationForUi(org)
      if sanitizedOrg then
        organizations[orgId] = sanitizedOrg
      end
    end
  end

  return organizations
end

U.getVisualValueFromMileage = function(mileage)
  mileage = clamp(mileage, 0, 2000000000)
  if mileage <= 10000000 then
    return 1
  elseif mileage <= 50000000 then
    return rescale(mileage, 10000000, 50000000, 1, 0.95)
  elseif mileage <= 100000000 then
    return rescale(mileage, 50000000, 100000000, 0.95, 0.925)
  elseif mileage <= 200000000 then
    return rescale(mileage, 100000000, 200000000, 0.925, 0.88)
  elseif mileage <= 500000000 then
    return rescale(mileage, 200000000, 500000000, 0.88, 0.825)
  elseif mileage <= 1000000000 then
    return rescale(mileage, 500000000, 1000000000, 0.825, 0.8)
  else
    return rescale(mileage, 1000000000, 2000000000, 0.8, 0.75)
  end
end

U.getDeliveryDelay = function(distance)
  distance = math.max(0, tonumber(distance) or 0)
  return clamp(C.vehicleDeliveryDelay + math.floor((distance / 1000) * 10 + 0.5), C.vehicleDeliveryDelay, 600)
end

U.getSellerReputationLevel = function(dealership)
  if not dealership or not dealership.associatedOrganization then return 0 end
  local org = freeroam_organizations.getOrganization(dealership.associatedOrganization)
  local level = org and org.reputation and tonumber(org.reputation.level) or 0
  return math.max(0, math.floor(level or 0))
end

U.getSellerAccessInfo = function(dealership)
  dealership = dealership or {}
  local salesChannel = dealership.salesChannel or (dealership.remotePurchaseOnly and "factory" or "local")
  local repLevel = U.getSellerReputationLevel(dealership)
  local isOnline = salesChannel == "factory" or salesChannel == "remanufactured"
  local remotePurchaseAllowed = isOnline or repLevel >= (tonumber(dealership.remotePurchaseLevel) or C.REMOTE_PURCHASE_LEVEL)
  local garageDeliveryAllowed = repLevel >= (tonumber(dealership.garageDeliveryLevel) or C.REMOTE_PURCHASE_LEVEL)
  local discount = 0
  if type(dealership.deliveryDiscounts) == "table" then
    for requiredLevel, configuredDiscount in pairs(dealership.deliveryDiscounts) do
      if repLevel >= (tonumber(requiredLevel) or math.huge) then
        discount = math.max(discount, tonumber(configuredDiscount) or 0)
      end
    end
  elseif repLevel >= (tonumber(dealership.deliveryDiscountLevel) or C.DELIVERY_DISCOUNT_LEVEL) then
    discount = tonumber(dealership.deliveryDiscount) or C.DELIVERY_DISCOUNT_AT_LEVEL_3
  end
  return {
    salesChannel = salesChannel,
    reputationLevel = repLevel,
    isOnline = isOnline,
    remotePurchaseAllowed = remotePurchaseAllowed,
    garageDeliveryAllowed = garageDeliveryAllowed,
    deliveryDiscount = clamp(discount, 0, 0.95)
  }
end

U.getDealershipForSellerId = function(sellerId)
  if not sellerId or sellerId == "private" or sellerId == "carMeet" then
    return nil
  end
  return freeroam_facilities.getDealership(sellerId)
end

U.isOnlineSellerId = function(sellerId)
  local dealership = U.getDealershipForSellerId(sellerId)
  if not dealership then return false end
  return U.getSellerAccessInfo(dealership).isOnline
end

U.getExpectedMileageMiles = function(age, annualMiles)
  age = math.max(0, tonumber(age) or 0)
  annualMiles = tonumber(annualMiles) or C.BASE_ANNUAL_MILES
  if age <= 25 then
    return age * annualMiles
  end
  -- Survivors accumulate much more slowly after 25 years. This avoids turning
  -- every classic into a 400k-mile car while preserving a broad driver market.
  return 25 * annualMiles + (age - 25) * math.min(annualMiles, 2500)
end

U.generateAgeDrivenMileage = function(seller, vehicleInfo, year)
  local currentYear = tonumber(os.date("%Y")) or 2026
  local age = math.max(0, currentYear - (tonumber(year) or currentYear))
  local channel = seller.salesChannel or "local"

  if channel == "factory" then
    return (C.FACTORY_MIN_MILES + math.random() * (C.FACTORY_MAX_MILES - C.FACTORY_MIN_MILES)) * C.MILES_TO_METERS,
      nil, "factoryDelivery"
  end

  if channel == "remanufactured" then
    local commercial = seller.remanCommercial == true
    local minMiles = commercial and 60000 or 20000
    local maxMiles = commercial and 180000 or 80000
    return (minMiles + randomGauss3() / 3 * (maxMiles - minMiles)) * C.MILES_TO_METERS,
      nil, commercial and "commercialReman" or "certifiedReman"
  end

  local profile = C.mileageProfiles[seller.id] or {}
  local configType = tostring(vehicleInfo["Config Type"] or "")
  local bodyStyle = tostring(vehicleInfo["Body Style"] or "")
  if configType == "Race" or configType == "Rally" then
    profile = C.mileageProfiles.fastAutomotiveDealership
  elseif configType == "Frame" then
    profile = C.mileageProfiles.frameDealership
  elseif bodyStyle == "Semi Truck" or bodyStyle == "Tanker Truck" or bodyStyle == "Dump Truck" then
    profile = C.mileageProfiles.truckShop
  end

  if age >= 25 and math.random() < (tonumber(profile.timeCapsuleChance) or 0) then
    return (5000 + randomGauss3() / 3 * 15000) * C.MILES_TO_METERS, nil, "timeCapsule"
  end

  local expected = U.getExpectedMileageMiles(age, profile.annualMiles)
  local minFactor = tonumber(profile.minFactor) or 0.75
  local maxFactor = tonumber(profile.maxFactor) or 1.25
  local factor = minFactor + randomGauss3() / 3 * (maxFactor - minFactor)
  local miles = expected * factor

  if age == 0 then
    miles = math.max(50, math.min(miles, 15000))
  elseif age >= 15 then
    miles = math.max(miles, tonumber(profile.minMiles) or 5000)
  end
  miles = clamp(miles, tonumber(profile.minMiles) or 0, tonumber(profile.maxMiles) or C.MAX_USED_MILES)
  if miles >= C.MAX_USED_MILES then
    -- Compress extreme-use vehicles into a varied 270k-300k survivor band
    -- instead of stacking every listing on the same hard-cap odometer.
    miles = C.MAX_USED_MILES - math.random() * 30000
  end

  local odometer = math.max(0, miles * C.MILES_TO_METERS)
  local wearMileage = nil
  local mileageCategory = "ageCurve"
  if profile.wearFactor and profile.wearFactor > 1 then
    wearMileage = odometer * profile.wearFactor
    mileageCategory = "competitionWear"
  elseif seller.id == "jeffersonmotors" and age >= 25 then
    if math.random() < 0.35 then
      wearMileage = math.max(5000 * C.MILES_TO_METERS, odometer * 0.25)
      mileageCategory = "restoredClassic"
    else
      wearMileage = odometer * 0.70
      mileageCategory = "collectorDriver"
    end
  end
  return odometer, wearMileage, mileageCategory
end

U.getDiscoveredDealersForMap = function(mapId)
  mapId = mapId or getCurrentLevelIdentifier()
  state.discoveredDealers[mapId] = state.discoveredDealers[mapId] or {}
  return state.discoveredDealers[mapId]
end

U.isDealerDiscovered = function(dealership)
  if not dealership then return false end
  local accessInfo = U.getSellerAccessInfo(dealership)
  if dealership.discoverable == false or accessInfo.isOnline then return true end
  return U.getDiscoveredDealersForMap()[dealership.id] == true
end

U.discoverDealer = function(dealershipId)
  local dealership = freeroam_facilities.getDealership(dealershipId)
  if not dealership or dealership.discoverable == false then return false end
  if U.getSellerAccessInfo(dealership).isOnline then return false end
  local mapDiscoveries = U.getDiscoveredDealersForMap()
  if mapDiscoveries[dealershipId] then return false end
  mapDiscoveries[dealershipId] = true
  -- Discovery is durable career progress. Queue a save now instead of relying
  -- on an unrelated purchase or later autosave to eventually flush it.
  if career_saveSystem and career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
  ui_message(string.format("%s is now available in the vehicle-shopping computer.",
    dealership.name or "Dealership"), 6, "Dealership discovered", "info")
  return true
end

U.applyPurchaseAdjustedMarketValue = function(vehicleInfo)
  if not vehicleInfo then return end
  local vehicleBuyMult = career_modules_valueCalculator.getVehicleBuyMarketMultiplier()
  local marketValue = vehicleInfo.marketValueBase or vehicleInfo.marketValue or vehicleInfo.Value
  vehicleInfo.marketValueAdjusted = math.floor((marketValue or 0) * vehicleBuyMult + 0.5)

  local valueBase = vehicleInfo.valueBase
  if not valueBase then
    if vehicleInfo.marketValue and vehicleInfo.negotiationPersonality and vehicleInfo.negotiationPersonality.priceMultiplier then
      valueBase = vehicleInfo.marketValue * vehicleInfo.negotiationPersonality.priceMultiplier
    else
      valueBase = vehicleInfo.Value
    end
  end
  if valueBase then
    vehicleInfo.valueAdjusted = U.getRoundedPrice(valueBase * vehicleBuyMult, vehicleInfo.priceRoundingType or "default")
  else
    vehicleInfo.valueAdjusted = vehicleInfo.Value
  end
end

U.getOrgLevelData = function(org, offset)
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

M.addModelBlacklistToLookup = function(lookup, filter)
  local modelKeys = type(filter) == "table" and type(filter.blackList) == "table" and
    filter.blackList.model_key or nil
  if type(modelKeys) ~= "table" then return end

  for _, modelKey in ipairs(modelKeys) do
    local normalized = string.lower(tostring(modelKey or ""))
    if normalized ~= "" then
      lookup[normalized] = true
    end
  end
end

-- Saved offers can outlive a facility edit or an organization level change.
-- Remove listings that the seller's current global model blacklist no longer
-- permits before counting stock and drawing replacements from the rebuilt cache.
M.pruneBlacklistedSellerStock = function(sellers)
  local blacklistedBySeller = {}
  for _, seller in ipairs(sellers or {}) do
    local lookup = {}
    M.addModelBlacklistToLookup(lookup, seller.filter)

    if seller.associatedOrganization then
      local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
      local level = U.getOrgLevelData(org)
      if level then
        M.addModelBlacklistToLookup(lookup, level.filter)
      end
    end

    if next(lookup) ~= nil then
      blacklistedBySeller[seller.id] = lookup
    end
  end

  local removed = 0
  for i = #state.vehiclesInShop, 1, -1 do
    local vehicleInfo = state.vehiclesInShop[i]
    local lookup = blacklistedBySeller[vehicleInfo.sellerId]
    local modelKey = string.lower(tostring(vehicleInfo.model_key or vehicleInfo.model or ""))
    if lookup and lookup[modelKey] then
      if vehicleInfo.shopId ~= nil then
        state.vehicleWatchlist[vehicleInfo.shopId] = nil
      end
      table.remove(state.vehiclesInShop, i)
      removed = removed + 1
    end
  end

  if removed > 0 then
    log("I", "Career", string.format("Removed %d dealer listings blocked by current model blacklists", removed))
  end
  return removed
end

U.resetVehicleValidationState = function()
  state.badConfigQuarantine = {}
  state.badConfigLogOnce = {}
  state.validationStats = {
    quarantined = 0,
    loadDropped = 0,
    cacheDropped = 0,
    generationDropped = 0
  }
end

U.incrementValidationStat = function(statKey, amount)
  if statKey and state.validationStats[statKey] ~= nil then
    state.validationStats[statKey] = state.validationStats[statKey] + (amount or 1)
  end
end

U.getVehicleConfigId = function(vehicleInfo)
  if type(vehicleInfo) ~= "table" then
    return nil
  end
  if type(vehicleInfo.model_key) ~= "string" or vehicleInfo.model_key == "" then
    return nil
  end
  if type(vehicleInfo.key) ~= "string" or vehicleInfo.key == "" then
    return nil
  end
  return vehicleInfo.model_key .. "|" .. vehicleInfo.key
end

U.getVehicleConfigTrackingKey = function(vehicleInfo)
  local configId = U.getVehicleConfigId(vehicleInfo)
  if configId then
    return configId
  end

  if type(vehicleInfo) ~= "table" then
    return "invalid:" .. tostring(vehicleInfo)
  end

  return string.format("invalid:%s|%s", tostring(vehicleInfo.model_key), tostring(vehicleInfo.key))
end

U.quarantineVehicleConfig = function(vehicleInfo, reason, context)
  local configId = U.getVehicleConfigId(vehicleInfo) or U.getVehicleConfigTrackingKey(vehicleInfo)
  if not state.badConfigQuarantine[configId] then
    state.badConfigQuarantine[configId] = true
    state.validationStats.quarantined = state.validationStats.quarantined + 1
  end

  if not state.badConfigLogOnce[configId] then
    state.badConfigLogOnce[configId] = true
    log("W", "Career", string.format("Quarantined vehicle config %s during %s: %s",
      tostring(configId), tostring(context), tostring(reason)))
  end

  return configId
end

U.isQuarantined = function(vehicleInfo)
  local trackingKey = U.getVehicleConfigTrackingKey(vehicleInfo)
  return state.badConfigQuarantine[trackingKey] == true
end

U.isValidVehicleInfoShape = function(vehicleInfo)
  if type(vehicleInfo) ~= "table" then
    return false, "vehicleInfo is not a table"
  end
  if type(vehicleInfo.model_key) ~= "string" or vehicleInfo.model_key == "" then
    return false, "missing model_key"
  end
  if type(vehicleInfo.key) ~= "string" or vehicleInfo.key == "" then
    return false, "missing key"
  end
  if type(vehicleInfo.Value) ~= "number" then
    local profile = career_modules_valueCalculator.getVehicleCatalogProfile and
      career_modules_valueCalculator.getVehicleCatalogProfile(
        vehicleInfo.model_key, vehicleInfo.key, vehicleInfo) or nil
    if profile and tonumber(profile.catalogValue) and profile.catalogValue > 0 then
      vehicleInfo.Value = profile.catalogValue
    else
      return false, "missing numeric Value and no parts-derived catalog"
    end
  end

  if vehicleInfo.aggregates == nil then
    vehicleInfo.aggregates = {}
  elseif type(vehicleInfo.aggregates) ~= "table" then
    return false, "malformed aggregates"
  end

  if type(vehicleInfo.Brand) ~= "string" then
    vehicleInfo.Brand = ""
  end
  if type(vehicleInfo.Name) ~= "string" then
    vehicleInfo.Name = ""
  end

  return true
end

U.safeYearsRange = function(vehicleInfo)
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

U.safeNumericAttribute = function(vehicleInfo, attrName)
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

U.normalizeVehicleCatalogValue = function(vehicleInfo, logContext)
  if type(vehicleInfo) ~= "table" then
    return false
  end

  local rawCatalogValue = tonumber(vehicleInfo.rawCatalogValue)
  if rawCatalogValue == nil then
    rawCatalogValue = tonumber(vehicleInfo.Value)
  end

  local profile = career_modules_valueCalculator.getVehicleCatalogProfile and
    career_modules_valueCalculator.getVehicleCatalogProfile(
      vehicleInfo.model_key, vehicleInfo.key, vehicleInfo) or nil
  local cachedPartsValue = profile and profile.partsRetailValue
    or career_modules_valueCalculator.getVehiclePcPartsCatalogSum(
      vehicleInfo.model_key, vehicleInfo.key, logContext)
    or 0
  local partsCatalogValue = profile and profile.catalogValue
    or (career_modules_valueCalculator.getVehiclePartsCatalogValue and
      career_modules_valueCalculator.getVehiclePartsCatalogValue(cachedPartsValue))
    or 0
  if rawCatalogValue == nil and partsCatalogValue <= 0 then
    return false
  end
  rawCatalogValue = rawCatalogValue or 0
  local effectiveCatalogValue = partsCatalogValue > 0 and partsCatalogValue or rawCatalogValue

  vehicleInfo.rawCatalogValue = rawCatalogValue
  vehicleInfo.cachedPartsValue = cachedPartsValue
  vehicleInfo.partsCatalogValue = partsCatalogValue
  vehicleInfo.catalogValueSource = profile and profile.catalogSource or
    (partsCatalogValue > 0 and "parts" or "configFallback")
  vehicleInfo.haloScore = profile and profile.haloScore or 0
  vehicleInfo.haloSignals = profile and profile.haloSignals or nil
  vehicleInfo.haloCohortSize = profile and profile.cohortSize or 0
  vehicleInfo.effectiveCatalogValue = effectiveCatalogValue
  vehicleInfo.Value = vehicleInfo.effectiveCatalogValue
  return true
end

M.isRichsStreetVehicle = function(vehicleInfo)
  if type(vehicleInfo) ~= "table" then
    return false
  end

  -- Some otherwise-factory configs are competition cars in their names and
  -- descriptions. Keep Rich's focused on valuable street cars.
  local identity = string.lower(table.concat({
    tostring(vehicleInfo["Config Type"] or ""),
    tostring(vehicleInfo.Configuration or ""),
    tostring(vehicleInfo.Name or ""),
    tostring(vehicleInfo.key or "")
  }, " "))
  local excludedWords = {
    "race", "rally", "drag", "drift", "police", "service",
    "commercial", "semi", "trailer", "frame", "taxi",
    "nascar", "track car", "cup car"
  }
  for _, word in ipairs(excludedWords) do
    if string.find(identity, "%f[%a]" .. word) then
      return false
    end
  end

  local aggregates = type(vehicleInfo.aggregates) == "table" and vehicleInfo.aggregates or {}
  local configTypes = type(aggregates["Config Type"]) == "table" and aggregates["Config Type"] or {}
  local vehicleTypes = type(aggregates.Type) == "table" and aggregates.Type or {}
  local isFactory = vehicleInfo["Config Type"] == "Factory" or configTypes.Factory == true
  local isCar = vehicleInfo.Type == "Car" or vehicleTypes.Car == true
  return isFactory and isCar
end

M.buildRichsTopTrimLookup = function(vehicleInfos)
  local modelGroups = {}
  for _, vehicleInfo in ipairs(vehicleInfos or {}) do
    local years = U.safeYearsRange(vehicleInfo)
    if M.isRichsStreetVehicle(vehicleInfo) and years and years.max >= 2000 then
      local effectiveValue = tonumber(vehicleInfo.effectiveCatalogValue) or 0
      local originalValue = tonumber(vehicleInfo.rawCatalogValue) or tonumber(vehicleInfo.Value) or 0
      local bestCatalogValue = math.max(effectiveValue, originalValue)
      local haloScore = tonumber(vehicleInfo.haloScore) or 0
      local insuranceClasses = type(vehicleInfo.aggregates) == "table"
        and vehicleInfo.aggregates.InsuranceClass or nil
      local prestigeClass = type(insuranceClasses) == "table" and insuranceClasses.prestige == true

      -- Rich's still has a price floor: being the best trim of an economy car
      -- is not enough unless that trim is genuinely special.
      if bestCatalogValue >= 45000
          or (bestCatalogValue >= 35000 and (haloScore >= 0.75 or prestigeClass)) then
        local modelKey = vehicleInfo.model_key
        modelGroups[modelKey] = modelGroups[modelKey] or {}
        table.insert(modelGroups[modelKey], {
          key = U.getVehicleConfigTrackingKey(vehicleInfo),
          value = bestCatalogValue,
          score = bestCatalogValue * (1 + 0.35 * haloScore) + (prestigeClass and 7500 or 0)
        })
      end
    end
  end

  local lookup = {}
  for _, configs in pairs(modelGroups) do
    table.sort(configs, function(a, b)
      if a.score == b.score then
        return tostring(a.key) < tostring(b.key)
      end
      return a.score > b.score
    end)

    local selectedCount = math.max(1, math.min(5, math.ceil(#configs * 0.20)))
    for rank = 1, selectedCount do
      local config = configs[rank]
      lookup[config.key] = {
        rank = rank,
        cohortSize = #configs,
        score = config.score,
        value = config.value
      }
    end
  end
  return lookup
end

M.isRichsPrestigeVehicle = function(vehicleInfo, topTrimLookup)
  if not M.isRichsStreetVehicle(vehicleInfo) then
    return false
  end

  local effectiveValue = tonumber(vehicleInfo.effectiveCatalogValue) or 0
  local originalValue = tonumber(vehicleInfo.rawCatalogValue) or tonumber(vehicleInfo.Value) or 0
  local haloScore = tonumber(vehicleInfo.haloScore) or 0
  local insuranceClasses = type(vehicleInfo.aggregates) == "table"
    and vehicleInfo.aggregates.InsuranceClass or nil
  local prestigeClass = type(insuranceClasses) == "table" and insuranceClasses.prestige == true

  local bestCatalogValue = math.max(effectiveValue, originalValue)
  local topTrimData = type(topTrimLookup) == "table"
    and topTrimLookup[U.getVehicleConfigTrackingKey(vehicleInfo)] or nil
  if topTrimData then
    return true, "modernTopTrim", topTrimData
  end
  if bestCatalogValue >= 100000 then
    return true, "sixFigureCatalog"
  end

  local years = U.safeYearsRange(vehicleInfo)
  if years and years.max < 2000 and bestCatalogValue >= 50000
      and (haloScore >= 0.75 or prestigeClass) then
    return true, "collectorHalo"
  end
  return false
end

U.safeBoundingBoxDimensions = function(vehicleInfo)
  if type(vehicleInfo) ~= "table" then
    return nil
  end

  local boundingBox = vehicleInfo.BoundingBox
  local dimensions = type(boundingBox) == "table" and boundingBox[2] or nil
  if type(dimensions) ~= "table" then
    return nil
  end

  local x = tonumber(dimensions[1])
  local y = tonumber(dimensions[2])
  local z = tonumber(dimensions[3])
  if not x or not y or not z then
    return nil
  end

  return x, y, z
end

U.safeVehicleOp = function(context, vehicleInfo, fn)
  local ok, result = pcall(fn)
  if not ok then
    U.quarantineVehicleConfig(vehicleInfo, result, context)
    return nil, result
  end
  return result, nil
end

U.sanitizeVehicleInfoList = function(rawVehicles, context, dropStatKey)
  local sanitizedVehicles = {}
  local summary = {
    raw = 0,
    kept = 0,
    malformed = 0,
    quarantined = 0
  }

  if type(rawVehicles) ~= "table" then
    return sanitizedVehicles, summary
  end

  for _, vehicleInfo in ipairs(rawVehicles) do
    summary.raw = summary.raw + 1
    if U.isQuarantined(vehicleInfo) then
      summary.quarantined = summary.quarantined + 1
      U.incrementValidationStat(dropStatKey)
    else
      local ok, reason = U.isValidVehicleInfoShape(vehicleInfo)
      if not ok then
        summary.malformed = summary.malformed + 1
        U.incrementValidationStat(dropStatKey)
        U.quarantineVehicleConfig(vehicleInfo, reason, context)
      else
        U.normalizeVehicleCatalogValue(vehicleInfo, context)
        table.insert(sanitizedVehicles, vehicleInfo)
        summary.kept = summary.kept + 1
      end
    end
  end

  return sanitizedVehicles, summary
end

U.logVehicleSanitizationSummary = function(context, summary)
  local logLevel = (summary.kept > 0 or summary.raw == 0) and "I" or "W"
  log(logLevel, "Career", string.format("%s summary: raw=%d kept=%d malformed=%d quarantined=%d",
    tostring(context), summary.raw, summary.kept, summary.malformed, summary.quarantined))
end

U.validateSavedVehicleRuntimeFields = function(vehicleInfo)
  local sellerIdType = type(vehicleInfo.sellerId)
  if (sellerIdType ~= "string" and sellerIdType ~= "number") or tostring(vehicleInfo.sellerId) == "" then
    return false, "missing saved sellerId"
  end

  local generationTime = tonumber(vehicleInfo.generationTime)
  if not generationTime then
    return false, "missing saved generationTime"
  end

  local offerTTL = tonumber(vehicleInfo.offerTTL)
  if not offerTTL then
    return false, "missing saved offerTTL"
  end

  local shopId = tonumber(vehicleInfo.shopId)
  if not shopId then
    return false, "missing saved shopId"
  end

  local fees = vehicleInfo.fees
  if fees == nil then
    fees = 0
  else
    fees = tonumber(fees)
    if not fees or fees < 0 then
      return false, "invalid saved fees"
    end
  end

  local tax = vehicleInfo.tax
  if tax == nil then
    tax = C.salesTax
  else
    tax = tonumber(tax)
    if not tax or tax < 0 then
      return false, "invalid saved tax"
    end
  end

  vehicleInfo.generationTime = generationTime
  vehicleInfo.offerTTL = offerTTL
  vehicleInfo.shopId = shopId
  vehicleInfo.fees = fees
  vehicleInfo.tax = tax

  return true
end

U.coerceVehiclePricingFields = function(vehicleInfo)
  if type(vehicleInfo) ~= "table" then
    return 0, C.salesTax
  end

  local fees = tonumber(vehicleInfo.fees)
  if not fees or fees < 0 then
    fees = 0
  end

  local tax = tonumber(vehicleInfo.tax)
  if not tax or tax < 0 then
    tax = C.salesTax
  end

  vehicleInfo.fees = fees
  vehicleInfo.tax = tax
  return fees, tax
end

U.sanitizeSavedVehicleEntries = function(savedVehicles, context)
  local sanitizedVehicles = {}
  local summary = {
    raw = 0,
    kept = 0,
    malformed = 0,
    quarantined = 0
  }

  if type(savedVehicles) ~= "table" then
    return sanitizedVehicles, summary
  end

  for _, vehicleInfo in ipairs(savedVehicles) do
    summary.raw = summary.raw + 1
    if U.isQuarantined(vehicleInfo) then
      summary.quarantined = summary.quarantined + 1
      U.incrementValidationStat("loadDropped")
    else
      local ok, reason = U.isValidVehicleInfoShape(vehicleInfo)
      if ok then
        ok, reason = U.validateSavedVehicleRuntimeFields(vehicleInfo)
      end
      if not ok then
        local logKey = "loaddrop:" .. U.getVehicleConfigTrackingKey(vehicleInfo)
        summary.malformed = summary.malformed + 1
        U.incrementValidationStat("loadDropped")
        if not state.badConfigLogOnce[logKey] then
          state.badConfigLogOnce[logKey] = true
          log("W", "Career", string.format("Dropped malformed saved vehicle entry %s during %s: %s",
            tostring(U.getVehicleConfigTrackingKey(vehicleInfo)), tostring(context), tostring(reason)))
        end
      else
        table.insert(sanitizedVehicles, vehicleInfo)
        summary.kept = summary.kept + 1
      end
    end
  end

  for _, vehicleInfo in ipairs(sanitizedVehicles) do
    if vehicleInfo.pos ~= nil then
      local posOk, posOrErr = pcall(function()
        return vec3(vehicleInfo.pos)
      end)
      if posOk then
        vehicleInfo.pos = posOrErr
      else
        local posLogKey = U.getVehicleConfigTrackingKey(vehicleInfo) .. "|savedPos"
        if not state.badConfigLogOnce[posLogKey] then
          state.badConfigLogOnce[posLogKey] = true
          log("W", "Career", string.format("Clearing malformed saved vehicle position for %s during %s: %s",
            tostring(U.getVehicleConfigId(vehicleInfo) or U.getVehicleConfigTrackingKey(vehicleInfo)),
            tostring(context), tostring(posOrErr)))
        end
        vehicleInfo.pos = nil
      end
    end
  end

  return sanitizedVehicles, summary
end

-- Delta tracking functions
U.buildSnapshot = function()
  local snap = {}
  for _, veh in ipairs(state.vehiclesInShop) do
    if not U.isCarMeetShopVehicle(veh) then
      snap[veh.shopId] = veh
    end
  end
  return snap
end

U.commitDelta = function(newSnap, justExpiredShopIds)
  justExpiredShopIds = justExpiredShopIds or {}
  local added, removed, sold, updated = {}, {}, {}, {}
  for shopId, veh in pairs(newSnap) do
    if not state.lastSnapshotByShopId[shopId] then
      table.insert(added, U.sanitizeVehicleForUi(veh))
    end
  end
  for shopId, veh in pairs(newSnap) do
    local prev = state.lastSnapshotByShopId[shopId]
    if prev and veh then
      local wasMarkedSold = prev.markedSold == true
      local isMarkedSold = veh.markedSold == true
      local prevSold = (prev.soldViewCounter or 0)
      local currSold = (veh.soldViewCounter or 0)

      if justExpiredShopIds[shopId] or (isMarkedSold and not wasMarkedSold) or (currSold > prevSold) then
        local soldVeh = U.sanitizeVehicleForUi(veh)
        soldVeh.__sold = true
        table.insert(updated, soldVeh)
      end
    end
  end
  for shopId, _ in pairs(state.lastSnapshotByShopId) do
    if not newSnap[shopId] then
      if state.pendingSoldShopIds[shopId] then
        local prevVeh = state.lastSnapshotByShopId[shopId]
        if prevVeh then
          local soldVeh = U.sanitizeVehicleForUi(prevVeh)
          soldVeh.shopId = shopId
          soldVeh.__sold = true
          table.insert(sold, soldVeh)
        else
          table.insert(sold, shopId)
        end
        state.pendingSoldShopIds[shopId] = nil
      else
        table.insert(removed, shopId)
      end
    end
  end
  state.lastSnapshotByShopId = newSnap
  state.deltaSeq = state.deltaSeq + 1
  state.lastDelta = {
    seq = state.deltaSeq,
    added = added,
    removed = removed,
    sold = sold,
    updated = updated,
    organizations = U.collectOrganizationsForUi(freeroam_facilities.getFacilities(getCurrentLevelIdentifier())),
    dealershipPurchaseReputationGain = C.dealershipPurchaseReputationGain
  }
end

-- UI state management
-- Phone buy and computer shop both restock through this. Count so closing one
-- does not stop refresh while the other is still open.
U.setShoppingUiOpen = function(isOpen)
  if isOpen then
    state.shoppingUiOpenCount = state.shoppingUiOpenCount + 1
  else
    state.shoppingUiOpenCount = math.max(0, state.shoppingUiOpenCount - 1)
  end
  state.uiOpen = state.shoppingUiOpenCount > 0
  state.refreshAccumulator = 0
  if isOpen then
    M.updateVehicleList(false)
    state.nextShopUpdateTime = 0
  end
end

U.onUiChangedState = function(toState)
  state.currentUiState = toState
end


U.onUpdate = function(dt)
  U.processPendingRacingTeamFleetPurchases()
  state.refreshAccumulator = state.refreshAccumulator + dt
  if state.refreshAccumulator < 5 then
    return
  end
  state.refreshAccumulator = 0

  -- Watchlist expiration check
  if not tableIsEmpty(state.vehicleWatchlist) and (not state.currentUiState or state.currentUiState == "play") then
    local currentTime = os.time()
    local inspectedVehicleInfo = career_modules_inspectVehicle.getSpawnedVehicleInfo()
    for shopId, status in pairs(state.vehicleWatchlist) do
      if status == "unsold" and (not inspectedVehicleInfo or inspectedVehicleInfo.shopId ~= shopId) then
        local vehicleInfo = U.getVehicleInfoByShopId(shopId)
        if vehicleInfo then
          U.normalizeVehicleShopTiming(vehicleInfo, currentTime)
          local offerTime = currentTime - vehicleInfo.generationTime
          if offerTime > vehicleInfo.offerTTL then
            vehicleInfo.soldFor = U.generateSoldVehicleValue(shopId)
            state.vehicleWatchlist[shopId] = "sold"
            guihooks.trigger("toastrMsg", {type="info", title="A vehicle you were interested in has been sold.", msg = vehicleInfo.Name .. " for $" .. string.format("%.2f", vehicleInfo.soldFor)})
            break
          end
        end
      end
    end
  end

  -- UI refresh logic
  if not state.uiOpen then
    return
  end
  local now = os.time()
  if (state.nextShopUpdateTime == 0) or (now >= state.nextShopUpdateTime) then
    M.updateVehicleList(false)
  end

  M.checkSpawnedVehicleStatus()
end

-- Data access functions
U.rtFleetCap = function(bid)
  local obj = career_modules_business_businessManager
    and career_modules_business_businessManager.getBusinessObject(state.fleetBusinessType)
  if obj and obj.getMaxPulledOutVehicles then
    return tonumber(obj.getMaxPulledOutVehicles(bid)) or 3
  end
  if obj and obj.getMaxActiveJobs then
    return tonumber(obj.getMaxActiveJobs(bid)) or 3
  end
  return 3
end

U.getRacingTeamGarageZones = function(businessId, businessType)
  local inv = career_modules_business_businessInventory
  if not inv or not inv.getBusinessGarage then return nil end
  local garage = inv.getBusinessGarage(businessType or state.fleetBusinessType, businessId)
  if not garage or not garage.sitesFile then return nil end
  local sites = gameplay_sites_sitesManager.loadSites(garage.sitesFile)
  return sites and sites.zones or nil
end

U.isVehicleInRacingTeamGarageZone = function(businessId, vehId, businessType)
  if not businessId or not vehId then return false end
  local vehObj = be:getObjectByID(vehId)
  if not vehObj then return false end
  local pos = vehObj:getPosition()
  if not pos then return false end
  local zones = U.getRacingTeamGarageZones(businessId, businessType)
  if not zones or not zones.sorted then return false end
  for _, zone in ipairs(zones.sorted or {}) do
    if zone and zone.containsPoint2D and zone:containsPoint2D(pos) then
      return true
    end
  end
  return false
end

U.getRacingTeamDeliveryDelaySeconds = function(businessId, vehicleInfo, businessType)
  if not vehicleInfo or not vehicleInfo.pos then
    return 1
  end
  local inv = career_modules_business_businessInventory
  if not inv or not inv.getBusinessGarage then
    return 1
  end
  local garage = inv.getBusinessGarage(businessType or state.fleetBusinessType, businessId)
  if not garage or not freeroam_facilities or not freeroam_facilities.getAverageDoorPositionForFacility then
    return 1
  end
  local garagePos = freeroam_facilities.getAverageDoorPositionForFacility(garage)
  if not garagePos then
    return 1
  end
  return U.getDeliveryDelay(vehicleInfo.pos:distance(garagePos))
end

U.storeRacingTeamFleetVehicleFromPending = function(businessId, pending)
  local inv = career_modules_business_businessInventory
  if not inv or not inv.storeVehicle then
    return false
  end
  local ok, vehicleId = inv.storeVehicle(businessId, {
    vehicleConfig = {
      model_key = pending.model_key,
      key = pending.key
    },
    mileage = pending.mileage or 0,
    purchasePrice = pending.purchasePrice or 0
  })
  if not ok then
    return false
  end
  local rtmod = rawget(_G, "career_modules_business_racingTeam")
  if rtmod and rtmod.notifyFleetFromShop then
    rtmod.notifyFleetFromShop(businessId)
  end

  return true, vehicleId
end

U.addPendingRacingTeamFleetPurchase = function(businessId, entry)
  local bid = tostring(businessId)
  state.rtPendingFleetPurchases[bid] = state.rtPendingFleetPurchases[bid] or {}
  entry = entry or {}
  entry.businessType = entry.businessType or state.fleetBusinessType
  entry.purchasedEpoch = tonumber(entry.purchasedEpoch) or os.time()
  table.insert(state.rtPendingFleetPurchases[bid], entry)
end

U.processPendingRacingTeamFleetPurchases = function()
  if state.rtPendingFleetProcessing or not next(state.rtPendingFleetPurchases) then
    return
  end
  state.rtPendingFleetProcessing = true
  local ok, err = pcall(function()
  local now = os.time()
  for bid, entries in pairs(state.rtPendingFleetPurchases) do
    if type(entries) == "table" then
      local keep = {}
      for _, pending in ipairs(entries) do
        local handled = false
        local purchasedEpoch = tonumber(pending and pending.purchasedEpoch) or now
        if pending.kind == "timer" then
          local dueEpoch = tonumber(pending.dueEpoch) or 0
          if dueEpoch > 0 and now >= dueEpoch then
            local stored, fleetVehicleId = U.storeRacingTeamFleetVehicleFromPending(bid, pending)
            handled = stored == true
            if handled and fleetVehicleId then
              local inv = career_modules_business_businessInventory
              if inv and inv.deliverFleetVehicleAtPurchase then
                inv.deliverFleetVehicleAtPurchase(pending.businessType or "racingTeam", bid, fleetVehicleId)
              end
            end
            if not handled then
              local overdue = now - dueEpoch
              if overdue >= state.rtPendingTimerFailureGraceSec then
                -- Prevent perma-"finalizing delivery" cards for invalid/failed timer entries.
                handled = true
                log("W", "Career", string.format(
                  "Dropping stale racing-team timer pending entry for business %s after %ds overdue.",
                  tostring(bid), math.floor(overdue)
                ))
              end
            end
          end
        elseif pending.kind == "drive" then
          local spawnedVehId = tonumber(pending.spawnedVehId)
          if spawnedVehId and U.isVehicleInRacingTeamGarageZone(bid, spawnedVehId, pending.businessType) then
            local stored, fleetVehicleId = U.storeRacingTeamFleetVehicleFromPending(bid, pending)
            if stored then
              handled = true
              local inv = career_modules_business_businessInventory
              if fleetVehicleId and inv and inv.registerFleetVehicleDeliveredDriveIn then
                inv.registerFleetVehicleDeliveredDriveIn(pending.businessType or "racingTeam", bid, fleetVehicleId, spawnedVehId)
                if inv.requestFleetVehicleStatsRead then
                  inv.requestFleetVehicleStatsRead(bid, fleetVehicleId)
                end
              end
            end
          else
            local age = now - purchasedEpoch
            if age >= state.rtPendingDriveStaleSec then
              -- Stale drive-in pending entries can survive across sessions after world-vehicle loss.
              handled = true
              log("W", "Career", string.format(
                "Dropping stale racing-team drive pending entry for business %s after %ds age.",
                tostring(bid), math.floor(age)
              ))
            end
          end
        end
        if not handled then
          table.insert(keep, pending)
        end
      end
      if #keep > 0 then
        state.rtPendingFleetPurchases[bid] = keep
      else
        state.rtPendingFleetPurchases[bid] = nil
      end
    end
  end
  end)
  state.rtPendingFleetProcessing = false
  if not ok then
    log("E", "Career", "processPendingRacingTeamFleetPurchases failed: " .. tostring(err))
  end
end

U.clearPendingRacingTeamFleetPurchases = function(businessId)
  if businessId == nil then return end
  local bid = tostring(tonumber(businessId) or businessId)
  state.rtPendingFleetPurchases[bid] = nil
end

U.getPendingRacingTeamFleetPurchases = function(businessId)
  -- Ensure UI never sees stale pending entries after delivery.
  U.processPendingRacingTeamFleetPurchases()
  if businessId == nil then
    return {}
  end
  local bid = tostring(tonumber(businessId) or businessId)
  local list = state.rtPendingFleetPurchases[bid]
  if type(list) ~= "table" then
    return {}
  end
  local out = {}
  local now = os.time()
  for i, p in ipairs(list) do
    if type(p) == "table" then
      out[#out + 1] = {
        pendingId = tostring(p.purchasedEpoch or now) .. "_" .. tostring(i),
        kind = p.kind,
        dueEpoch = tonumber(p.dueEpoch),
        secondsRemaining = math.max(0, math.floor((tonumber(p.dueEpoch) or now) - now)),
        model_key = p.model_key,
        key = p.key,
        mileage = p.mileage or 0,
        purchasePrice = p.purchasePrice or 0,
        spawnedVehId = tonumber(p.spawnedVehId),
        purchasedEpoch = tonumber(p.purchasedEpoch) or now
      }
    end
  end
  return out
end

U.getShoppingData = function()
  local data = {}

  local unsoldVehicles, soldVehiclesResult = U.convertKeysToStrings(state.vehiclesInShop)
  for i = #unsoldVehicles, 1, -1 do
    if U.isCarMeetShopVehicle(unsoldVehicles[i]) then
      table.remove(unsoldVehicles, i)
    end
  end
  for i = #soldVehiclesResult, 1, -1 do
    if U.isCarMeetShopVehicle(soldVehiclesResult[i]) then
      table.remove(soldVehiclesResult, i)
    end
  end
  for _, vehicleInfo in ipairs(unsoldVehicles) do
    U.applyPurchaseAdjustedMarketValue(vehicleInfo)
  end
  for _, vehicleInfo in ipairs(soldVehiclesResult) do
    U.applyPurchaseAdjustedMarketValue(vehicleInfo)
  end
  data.vehiclesInShop = unsoldVehicles
  data.soldVehicles = soldVehiclesResult
  data.uiDealershipsData = U.getUiDealershipsData(unsoldVehicles)
  data.currentSeller = state.currentSeller
  if state.currentSeller then
    local dealership = freeroam_facilities.getDealership(state.currentSeller)
    if dealership then
      data.currentSellerNiceName = dealership.name
    end
  end
  data.selectedSellerId = state.selectedSellerId
  data.screenTag = state.shoppingScreenTag
  data.buyingAvailable = state.buyingAvailable
  data.marketplaceAvailable = state.marketplaceAvailable
  data.playerAttributes = career_modules_playerAttributes.getAllAttributes()
  if state.rtBizId and career_modules_bank and career_modules_bank.getBusinessAccount then
    local acct = career_modules_bank.getBusinessAccount(state.fleetBusinessType, state.rtBizId)
    local bal = acct and (tonumber(acct.balance) or tonumber(acct.balanceMoney))
    if bal == nil and type(acct) == "table" then
      bal = tonumber(acct.money)
    end
    bal = tonumber(bal) or 0
    data.racingTeamBusinessId = state.rtBizId
    data.racingTeamBusinessMoney = bal
    data.fleetBusinessType = state.fleetBusinessType
    local inv = career_modules_business_businessInventory
    local n = 0
    if inv and inv.getBusinessVehicles then
      n = #(inv.getBusinessVehicles(state.rtBizId) or {})
    end
    local cap = U.rtFleetCap(state.rtBizId)
    data.inventoryHasFreeSlot = n < cap
    data.numberOfFreeSlots = math.max(0, cap - n)
  else
    data.racingTeamBusinessId = nil
    data.racingTeamBusinessMoney = nil
    data.inventoryHasFreeSlot = career_modules_inventory.hasFreeSlot()
    data.numberOfFreeSlots = career_modules_inventory.getNumberOfFreeSlots()
  end

  -- Racing-team shop: do not expose personal wallet in playerAttributes (UI uses racingTeamBusinessMoney).
  -- Taxi / personal fees still use playerPersonalMoneyForTaxi when present.
  if state.rtBizId then
    data.playerPersonalMoneyForTaxi = career_modules_playerAttributes.getAttributeValue("money")
    if data.playerAttributes then
      data.playerAttributes = deepcopy(data.playerAttributes)
      if type(data.playerAttributes.money) == "table" then
        data.playerAttributes.money = deepcopy(data.playerAttributes.money)
        data.playerAttributes.money.value = nil
      else
        data.playerAttributes.money = nil
      end
    end
  end

  data.cheatsMode = career_modules_cheats and career_modules_cheats.isCheatsMode() or false
  data.dealershipPurchaseReputationGain = C.dealershipPurchaseReputationGain

  data.tutorialPurchase = (not career_career.hasBoughtStarterVehicle()) or nil
  data.hasboughtStarterVehicle = career_career.hasBoughtStarterVehicle()

  data.disableShopping = false
  local reason = career_modules_permissions.getStatusForTag("vehicleShopping")
  if not reason.allow then
    data.disableShopping = true
  end
  if reason.permission ~= "allowed" then
    data.disableShoppingReason = reason.label or "not allowed (TODO)"
  end

  local facilities = freeroam_facilities.getFacilities(getCurrentLevelIdentifier())
  data.dealerships = {}
  data.dealershipDiscovery = {discovered = 0, total = 0}
  data.organizations = U.collectOrganizationsForUi(facilities)
  if facilities and facilities.dealerships then
    for _, d in ipairs(facilities.dealerships) do
      local policeLocked = U.isPoliceDealershipLocked(d.id)
      local discovered = U.isDealerDiscovered(d)
      local accessInfo = U.getSellerAccessInfo(d)
      -- Count every dealership the picker can list. Online and always-visible
      -- dealers count as discovered, so the header tracks the cards on screen.
      data.dealershipDiscovery.total = data.dealershipDiscovery.total + 1
      if discovered then
        data.dealershipDiscovery.discovered = data.dealershipDiscovery.discovered + 1
      end
      table.insert(data.dealerships, {
        id = d.id,
        name = d.name,
        description = d.description,
        preview = d.preview,
        hiddenFromDealerList = d.hiddenFromDealerList or policeLocked or not discovered,
        undiscovered = not discovered,
        salesChannel = accessInfo.salesChannel,
        remotePurchaseAllowed = accessInfo.remotePurchaseAllowed,
        garageDeliveryAllowed = accessInfo.garageDeliveryAllowed,
        deliveryDiscount = accessInfo.deliveryDiscount,
        associatedOrganization = d.associatedOrganization,
        disabled = policeLocked,
        disabledReason = policeLocked and U.getPoliceDealershipLockLabel() or nil
      })
    end
  end

  if facilities and facilities.privateSellers then
    for _, d in ipairs(facilities.privateSellers) do
      local policeLocked = U.isPoliceDealershipLocked(d.id)
      table.insert(data.dealerships, {
        id = d.id,
        name = d.name,
        description = d.description,
        preview = d.preview,
        hiddenFromDealerList = d.hiddenFromDealerList or policeLocked,
        associatedOrganization = d.associatedOrganization,
        disabled = policeLocked,
        disabledReason = policeLocked and U.getPoliceDealershipLockLabel() or nil
      })
    end
  end

  -- Seller access changes with reputation, while shop listings can persist across
  -- sessions. Copy the freshly computed dealer access onto every existing card,
  -- not only stock generated after the reputation change.
  for _, vehicleInfo in ipairs(data.vehiclesInShop) do
    for _, dealership in ipairs(data.dealerships) do
      if dealership.id == vehicleInfo.sellerId then
        vehicleInfo.salesChannel = dealership.salesChannel
        vehicleInfo.remotePurchaseAllowed = dealership.remotePurchaseAllowed
        vehicleInfo.garageDeliveryAllowed = dealership.garageDeliveryAllowed
        vehicleInfo.deliveryDiscount = dealership.deliveryDiscount
        break
      end
    end
  end

  -- Strip vec3 userdata so the phone can read shop stock without the computer
  -- having already sent a sanitized vehicleShopDelta.
  local sanitizedUnsold = {}
  for _, vehicleInfo in ipairs(data.vehiclesInShop) do
    table.insert(sanitizedUnsold, U.sanitizeVehicleForUi(vehicleInfo))
  end
  local sanitizedSold = {}
  for _, vehicleInfo in ipairs(data.soldVehicles) do
    table.insert(sanitizedSold, U.sanitizeVehicleForUi(vehicleInfo))
  end
  data.vehiclesInShop = sanitizedUnsold
  data.soldVehicles = sanitizedSold

  return data
end

U.sendShoppingDataToUI = function()
  guihooks.trigger("vehicleShoppingData", U.getShoppingData())
end

-- Price calculation functions
U.getRandomizedPrice = function(price, range)
  local boundedRange = career_modules_valueCalculator.getVehicleListingPriceRange and
    career_modules_valueCalculator.getVehicleListingPriceRange(range) or
    {tailLow = 0.70, normalLow = 0.88, normalHigh = 1.12, tailHigh = 1.30}
  local normalLow = boundedRange.normalLow
  local normalHigh = boundedRange.normalHigh

  if isReallyRandom then
    math.randomseed(os.time() + os.clock() * 10000)
    for _ = 1, 3 do
      math.random()
    end
  end

  local rand = math.random(0, 1000) / 1000
  if rand < 0 then
    rand = 0
  end
  if rand > 1 then
    rand = 1
  end

  local multiplier
  local priceBand
  if rand <= 0.01 then
    multiplier = boundedRange.tailLow + (normalLow - boundedRange.tailLow) * (rand / 0.01)
    priceBand = "lowTail"
  elseif rand <= 0.99 then
    multiplier = normalLow + (normalHigh - normalLow) * ((rand - 0.01) / 0.98)
    priceBand = "normal"
  else
    multiplier = normalHigh + (boundedRange.tailHigh - normalHigh) * ((rand - 0.99) / 0.01)
    priceBand = "highTail"
  end

  local finalPriceInt = math.floor(multiplier * price + 0.5)
  return math.max(finalPriceInt, 500), priceBand, multiplier
end

-- Vehicle filtering and processing functions
U.doesVehiclePassFiltersList = function(vehicleInfo, filters)
  if type(vehicleInfo) ~= "table" or type(filters) ~= "table" then
    return false
  end

  for filterName, parameters in pairs(filters) do
    if filterName == "Years" then
      local vehicleYears = U.safeYearsRange(vehicleInfo)
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
        local value = U.safeNumericAttribute(vehicleInfo, filterName)
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

        -- Empty filter objects are emitted by the facility editor to mean
        -- "no constraint" (for example the private-market Value field).
        if next(parameters) ~= nil then
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
  end
  return true
end

U.doesVehiclePassFilter = function(vehicleInfo, filter)
  if type(filter) ~= "table" then
    return false
  end
  if filter.whiteList and not U.doesVehiclePassFiltersList(vehicleInfo, filter.whiteList) then
    return false
  end
  local blacklist = filter.blackList
  if type(blacklist) == "table" and type(blacklist.model_key) == "table" then
    local modelKey = string.lower(tostring(vehicleInfo.model_key or vehicleInfo.model or ""))
    for _, excluded in ipairs(blacklist.model_key) do
      if modelKey == string.lower(tostring(excluded)) then return false end
    end
    blacklist = {}
    for key, value in pairs(filter.blackList) do
      if key ~= "model_key" then blacklist[key] = value end
    end
    if not next(blacklist) then blacklist = nil end
  end
  if blacklist and U.doesVehiclePassFiltersList(vehicleInfo, blacklist) then
    return false
  end
  return true
end

-- A configuration can match more than one sub-filter (for example a model
-- produced across two decades). Keep one cache entry per real configuration,
-- while preserving the combined probability and the matching filters used to
-- generate attributes such as model year.
function M.addVehicleToDealerCache(cache, cacheIndexByConfig, vehicleInfo)
  local configKey = U.getVehicleConfigTrackingKey(vehicleInfo)
  local probability = math.max(0, tonumber(vehicleInfo.subFilterProbability) or 1)
  local matchingFilter = {
    filter = vehicleInfo.precomputedFilter,
    probability = probability,
    selectionIndex = vehicleInfo.precomputedFilter and vehicleInfo.precomputedFilter._selectionIndex or 1
  }
  local existingIndex = cacheIndexByConfig[configKey]

  if existingIndex then
    local existing = cache[existingIndex]
    existing.subFilterProbability = (tonumber(existing.subFilterProbability) or 0) + probability
    existing.precomputedFilters = existing.precomputedFilters or {}
    table.insert(existing.precomputedFilters, matchingFilter)
    return false
  end

  vehicleInfo.subFilterProbability = probability
  vehicleInfo.precomputedFilters = {matchingFilter}
  table.insert(cache, vehicleInfo)
  cacheIndexByConfig[configKey] = #cache
  return true
end

function M.choosePrecomputedFilter(vehicleInfo)
  local filters = vehicleInfo and vehicleInfo.precomputedFilters
  if type(filters) ~= "table" or tableIsEmpty(filters) then
    return vehicleInfo and vehicleInfo.precomputedFilter or nil
  end

  -- The stock lottery may already have selected a weighted sub-filter. Keep
  -- the generated year and other filter-derived attributes in that category.
  if vehicleInfo.selectedSubFilterIndex then
    for _, entry in ipairs(filters) do
      local selectionIndex = entry.selectionIndex or (entry.filter and entry.filter._selectionIndex) or 1
      if selectionIndex == vehicleInfo.selectedSubFilterIndex then
        return entry.filter
      end
    end
  end

  local totalWeight = 0
  for _, entry in ipairs(filters) do
    totalWeight = totalWeight + math.max(0, tonumber(entry.probability) or 1)
  end
  if totalWeight <= 0 then
    return filters[math.random(#filters)].filter
  end

  local cursor = math.random() * totalWeight
  local accumulated = 0
  for _, entry in ipairs(filters) do
    accumulated = accumulated + math.max(0, tonumber(entry.probability) or 1)
    if accumulated >= cursor then
      return entry.filter
    end
  end
  return filters[#filters].filter
end

-- Cache management functions
U.cacheDealers = function()
  local startTime = os.clock()
  state.vehicleCache.cacheValid = false
  state.vehicleCache.dealershipCache = {}
  local totalPartsCalculated = 0

  local rawEligibleVehicles = util_configListGenerator.getEligibleVehicles() or {}
  local regularEligibleVehicles, eligibleSummary = U.sanitizeVehicleInfoList(rawEligibleVehicles, "cacheDealers",
    "cacheDropped")
  U.logVehicleSanitizationSummary("cacheDealers eligible vehicles", eligibleSummary)
  state.vehicleCache.regularVehicles = regularEligibleVehicles
  local richsTopTrimLookup = M.buildRichsTopTrimLookup(regularEligibleVehicles)

  local facilities = freeroam_facilities.getFacilities(getCurrentLevelIdentifier())

  if facilities and facilities.dealerships then
    for _, dealership in ipairs(facilities.dealerships) do
      local dealershipId = dealership.id

      local filter = dealership.filter or {}
      if dealership.associatedOrganization then
        local org = freeroam_organizations.getOrganization(dealership.associatedOrganization)
        local level = U.getOrgLevelData(org)
        if level and level.filter then
          filter = deepcopy(filter)
          tableMergeRecursive(filter, level.filter)
        end
      end

      local subFilters = dealership.subFilters or {}
      if dealership.associatedOrganization then
        local org = freeroam_organizations.getOrganization(dealership.associatedOrganization)
        local level = U.getOrgLevelData(org)
        if level and level.subFilters then
          subFilters = level.subFilters
        end
      end
      if dealershipId == "richsmotorcompany" then
        -- Rich's prestige rule is value/halo driven and intentionally spans
        -- all model years. Reputation changes stock and terms, not eligibility.
        subFilters = {}
      end

      if filter or subFilters then
        local filteredRegular = {}
        local filteredRegularByConfig = {}
        local filters = {}
        local droppedForDealership = 0

        if subFilters and not tableIsEmpty(subFilters) then
          for selectionIndex, subFilter in ipairs(subFilters) do
            local aggregateFilter = deepcopy(filter or {})
            tableMergeRecursive(aggregateFilter, subFilter)
            aggregateFilter._probability = (type(subFilter.probability) == "number" and subFilter.probability) or 1
            aggregateFilter._selectionIndex = selectionIndex
            table.insert(filters, aggregateFilter)
          end
        else
          local aggregateFilter = deepcopy(filter or {})
          aggregateFilter._probability = 1
          aggregateFilter._selectionIndex = 1
          table.insert(filters, aggregateFilter)
        end

        for _, filter in ipairs(filters) do
          local subProb = filter._probability or filter.probability or 1
          for _, vehicleInfo in ipairs(regularEligibleVehicles) do
            if not U.isQuarantined(vehicleInfo) then
              local cachedVehicle, err = U.safeVehicleOp("cacheDealers", vehicleInfo, function()
                if not U.doesVehiclePassFilter(vehicleInfo, filter) then
                  return false
                end

                local cacheEntry = deepcopy(vehicleInfo)
                cacheEntry.precomputedFilter = filter
                cacheEntry.subFilterProbability = subProb
                U.normalizeVehicleCatalogValue(cacheEntry, "cacheDealers")
                if dealershipId == "richsmotorcompany" then
                  local qualifies, reason, topTrimData =
                    M.isRichsPrestigeVehicle(cacheEntry, richsTopTrimLookup)
                  if not qualifies then return false end
                  cacheEntry.richsSelectionReason = reason
                  cacheEntry.richsTopTrimData = topTrimData
                end
                return cacheEntry
              end)

              if err then
                droppedForDealership = droppedForDealership + 1
                U.incrementValidationStat("cacheDropped")
              elseif cachedVehicle then
                if M.addVehicleToDealerCache(filteredRegular, filteredRegularByConfig, cachedVehicle) then
                  totalPartsCalculated = totalPartsCalculated + 1
                end
              end
            end
          end
        end

        state.vehicleCache.dealershipCache[dealershipId] = state.vehicleCache.dealershipCache[dealershipId] or {}
        if tableIsEmpty(filteredRegular) then
          log("W", "Career", string.format("Dealership not configured: %s (kept=0 dropped=%d)", dealershipId,
            droppedForDealership))
          state.vehicleCache.dealershipCache[dealershipId].notConfigured = true
        end
        state.vehicleCache.dealershipCache[dealershipId].regularVehicles = filteredRegular
        state.vehicleCache.dealershipCache[dealershipId].filters = filters
        U.buildPopulationSelector(state.vehicleCache.dealershipCache[dealershipId])

        log("I", "Career", string.format("cacheDealers dealership %s: kept=%d dropped=%d",
          tostring(dealershipId), #filteredRegular, droppedForDealership))
      end
    end
  end

  local privateVehicles = {}
  local privateVehiclesByConfig = {}
  local privateDropped = 0
  local privateSeller = facilities and facilities.privateSellers and facilities.privateSellers[1] or nil
  local privateBaseFilter = privateSeller and privateSeller.filter or {}
  local privateSubFilters = privateSeller and privateSeller.subFilters or {}
  local privateFilters = {}
  if privateSubFilters and not tableIsEmpty(privateSubFilters) then
    for selectionIndex, subFilter in ipairs(privateSubFilters) do
      local aggregateFilter = deepcopy(privateBaseFilter)
      tableMergeRecursive(aggregateFilter, subFilter)
      aggregateFilter._probability = tonumber(subFilter.probability) or 1
      aggregateFilter._selectionIndex = selectionIndex
      table.insert(privateFilters, aggregateFilter)
    end
  else
    local aggregateFilter = deepcopy(privateBaseFilter)
    aggregateFilter._probability = 1
    aggregateFilter._selectionIndex = 1
    table.insert(privateFilters, aggregateFilter)
  end

  for _, privateFilter in ipairs(privateFilters) do
    for _, sourceVehicle in ipairs(regularEligibleVehicles) do
      local cachedVehicle, err = U.safeVehicleOp("cacheDealers:private", sourceVehicle, function()
        if not U.doesVehiclePassFilter(sourceVehicle, privateFilter) then return false end
        local vehicleInfo = deepcopy(sourceVehicle)
        U.normalizeVehicleCatalogValue(vehicleInfo, "cacheDealers:private")
        vehicleInfo.precomputedFilter = privateFilter
        vehicleInfo.subFilterProbability = privateFilter._probability or 1
        return vehicleInfo
      end)
      if err then
        privateDropped = privateDropped + 1
        U.incrementValidationStat("cacheDropped")
      elseif cachedVehicle then
        M.addVehicleToDealerCache(privateVehicles, privateVehiclesByConfig, cachedVehicle)
      end
    end
  end
  totalPartsCalculated = totalPartsCalculated + #privateVehicles

  state.vehicleCache.dealershipCache["private"] = {
    regularVehicles = privateVehicles,
    filters = privateFilters
  }
  U.buildPopulationSelector(state.vehicleCache.dealershipCache["private"])
  if tableIsEmpty(privateVehicles) then
    state.vehicleCache.dealershipCache["private"].notConfigured = true
  end

  state.vehicleCache.lastCacheTime = os.time()
  state.vehicleCache.map = getCurrentLevelIdentifier()
  state.vehicleCache.cacheValid = true
  log("I", "Career", string.format(
    "cacheDealers complete: raw=%d kept=%d malformed=%d quarantined=%d privateKept=%d privateDropped=%d partsCalculated=%d time=%.3fs",
    eligibleSummary.raw, eligibleSummary.kept, eligibleSummary.malformed, eligibleSummary.quarantined,
    #privateVehicles, privateDropped, totalPartsCalculated, os.clock() - startTime))
end

U.careerStockPopulationWeight = function(value)
  -- Some eligible mods use zero to stay out of traffic. Give them a career
  -- stock chance without changing their metadata or seller category odds.
  if tonumber(value) == 0 then return 50 end
  return U.populationSelector.populationWeight(value)
end

U.buildPopulationSelector = function(dealershipData)
  dealershipData.populationSelector = U.populationSelector.build(dealershipData.regularVehicles or {},
    U.getVehicleConfigTrackingKey, U.careerStockPopulationWeight)
end

U.prepareVehicleCache = function()
  local currentMap = getCurrentLevelIdentifier()
  if currentMap and (not state.vehicleCache.cacheValid or state.vehicleCache.map ~= currentMap) then
    U.cacheDealers()
  end
end

U.getRandomVehicleFromCache = function(sellerId, count, excludedConfigKeys, modelLimit, stockedModels)
  if (tonumber(count) or 0) <= 0 then return {} end
  if not state.vehicleCache.cacheValid then
    log("W", "Career", "Vehicle cache invalid, rebuilding...")
    U.cacheDealers()
  end
  local dealershipData = state.vehicleCache.dealershipCache[sellerId]
  if not dealershipData then
    log("W", "Career", "No cached data for seller: " .. tostring(sellerId))
    return {}
  end
  if not dealershipData.populationSelector then U.buildPopulationSelector(dealershipData) end

  -- Eligibility/valuation were checked when the catalog was built. Only inspect
  -- selected entries here; cloning and sanitizing every config on every draw
  -- previously made stock refresh cost grow with the entire installed catalog.
  local selected = U.populationSelector.draw(dealershipData.populationSelector, count, excludedConfigKeys,
    function(vehicle)
      if U.isQuarantined(vehicle) then return false end
      local ok, reason = U.isValidVehicleInfoShape(vehicle)
      if not ok then
        U.quarantineVehicleConfig(vehicle, reason, "getRandomVehicleFromCache")
        U.incrementValidationStat("cacheDropped")
      end
      return ok
    end, sellerId == "richsmotorcompany", nil, modelLimit, stockedModels)
  local vehicles = {}
  for _, entry in ipairs(selected) do
    local vehicle = deepcopy(entry.vehicle)
    vehicle.selectedSubFilterIndex = entry.selectionIndex
    table.insert(vehicles, vehicle)
  end
  return vehicles
end

U.invalidateVehicleCache = function()
  state.vehicleCache.cacheValid = false
  state.vehicleCache.regularVehicles = {}
  state.vehicleCache.dealershipCache = {}
  state.vehicleCache.map = nil
  career_modules_valueCalculator.clearVehiclePcPartsCatalogSumCache()
  U.resetVehicleValidationState()
end

U.rebuildDealershipCache = function(dealershipId)
  if not state.vehicleCache.cacheValid then
    U.cacheDealers()
    return
  end

  local facilities = freeroam_facilities.getFacilities(getCurrentLevelIdentifier())
  if not facilities or not facilities.dealerships then
    return
  end

  local dealership = nil
  for _, d in ipairs(facilities.dealerships) do
    if d.id == dealershipId then
      dealership = d
      break
    end
  end

  if not dealership then
    return
  end

  local regularEligibleVehicles, eligibleSummary = U.sanitizeVehicleInfoList(state.vehicleCache.regularVehicles or {},
    "rebuildDealershipCache:cachedEligible", "cacheDropped")
  if eligibleSummary.raw > 0 then
    state.vehicleCache.regularVehicles = regularEligibleVehicles
  end
  if not regularEligibleVehicles or tableIsEmpty(regularEligibleVehicles) then
    local rawEligibleVehicles = util_configListGenerator.getEligibleVehicles() or {}
    regularEligibleVehicles, eligibleSummary = U.sanitizeVehicleInfoList(rawEligibleVehicles, "rebuildDealershipCache",
      "cacheDropped")
    U.logVehicleSanitizationSummary("rebuildDealershipCache eligible vehicles", eligibleSummary)
    state.vehicleCache.regularVehicles = regularEligibleVehicles
  end
  local richsTopTrimLookup = M.buildRichsTopTrimLookup(regularEligibleVehicles)

  local filter = dealership.filter or {}
  if dealership.associatedOrganization then
    local org = freeroam_organizations.getOrganization(dealership.associatedOrganization)
    local level = U.getOrgLevelData(org)
    if level and level.filter then
      filter = deepcopy(filter)
      tableMergeRecursive(filter, level.filter)
    end
  end

  local subFilters = dealership.subFilters or {}
  if dealership.associatedOrganization then
    local org = freeroam_organizations.getOrganization(dealership.associatedOrganization)
    local level = U.getOrgLevelData(org)
    if level and level.subFilters then
      subFilters = level.subFilters
    end
  end
  if dealershipId == "richsmotorcompany" then
    subFilters = {}
  end

  local filteredRegular = {}
  local filteredRegularByConfig = {}
  local filters = {}
  local droppedForDealership = 0

  if subFilters and not tableIsEmpty(subFilters) then
    for selectionIndex, subFilter in ipairs(subFilters) do
      local aggregateFilter = deepcopy(filter or {})
      tableMergeRecursive(aggregateFilter, subFilter)
      aggregateFilter._probability = (type(subFilter.probability) == "number" and subFilter.probability) or 1
      aggregateFilter._selectionIndex = selectionIndex
      table.insert(filters, aggregateFilter)
    end
  else
    local aggregateFilter = deepcopy(filter or {})
    aggregateFilter._probability = 1
    aggregateFilter._selectionIndex = 1
    table.insert(filters, aggregateFilter)
  end

  for _, f in ipairs(filters) do
    local subProb = f._probability or f.probability or 1
    for _, vehicleInfo in ipairs(regularEligibleVehicles) do
      if not U.isQuarantined(vehicleInfo) then
        local cachedVehicle, err = U.safeVehicleOp("rebuildDealershipCache", vehicleInfo, function()
          if not U.doesVehiclePassFilter(vehicleInfo, f) then
            return false
          end

          local cacheEntry = deepcopy(vehicleInfo)
          cacheEntry.precomputedFilter = f
          cacheEntry.subFilterProbability = subProb
          U.normalizeVehicleCatalogValue(cacheEntry, "rebuildDealershipCache")
          if dealershipId == "richsmotorcompany" then
            local qualifies, reason, topTrimData =
              M.isRichsPrestigeVehicle(cacheEntry, richsTopTrimLookup)
            if not qualifies then return false end
            cacheEntry.richsSelectionReason = reason
            cacheEntry.richsTopTrimData = topTrimData
          end
          return cacheEntry
        end)

        if err then
          droppedForDealership = droppedForDealership + 1
          U.incrementValidationStat("cacheDropped")
        elseif cachedVehicle then
          M.addVehicleToDealerCache(filteredRegular, filteredRegularByConfig, cachedVehicle)
        end
      end
    end
  end

  local notConfigured = tableIsEmpty(filteredRegular)
  if notConfigured then
    log("W", "Career", string.format("Dealership not configured: %s (kept=0 dropped=%d)", dealershipId,
      droppedForDealership))
  end

  state.vehicleCache.dealershipCache[dealershipId] = {
    regularVehicles = filteredRegular,
    filters = filters,
    notConfigured = notConfigured
  }
  U.buildPopulationSelector(state.vehicleCache.dealershipCache[dealershipId])

  log("I", "Career", string.format(
    "Rebuilt cache for dealership %s: kept=%d dropped=%d rawEligible=%d validEligible=%d malformed=%d quarantined=%d",
    dealershipId, #filteredRegular, droppedForDealership, eligibleSummary.raw, eligibleSummary.kept,
    eligibleSummary.malformed, eligibleSummary.quarantined))
end

-- Vehicle list management functions
U.updateVehicleList = function(fromScratch)
  fromScratch = not not fromScratch
  local sellers = {}
  local currentMap = getCurrentLevelIdentifier()
  local onlyStarterVehicles = not career_career.hasBoughtStarterVehicle()
  local changed = false
  local updateSummary = {
    attempted = 0,
    inserted = 0,
    dropped = 0
  }

  if fromScratch then
    U.invalidateVehicleCache()
    state.vehiclesInShop = {}
    state.sellersInfos = {}
    state.vehicleWatchlist = {}
    changed = true
  end

  -- If there are already vehicles in the shop, don't generate starter vehicles
  if onlyStarterVehicles and not tableIsEmpty(state.vehiclesInShop) then
    state.nextShopUpdateTime = os.time() + 3600
    return
  end

  local filteredVehiclesInShop = {}
  for i, vehicleInfo in ipairs(state.vehiclesInShop) do
    if vehicleInfo.mapId == currentMap then
      table.insert(filteredVehiclesInShop, vehicleInfo)
    else
      changed = true
    end
  end
  state.vehiclesInShop = filteredVehiclesInShop

  local filteredSellersInfos = {}
  for sellerId, sellerInfo in pairs(state.sellersInfos) do
    if sellerInfo.mapId == currentMap then
      filteredSellersInfos[sellerId] = sellerInfo
    else
      changed = true
    end
  end
  state.sellersInfos = filteredSellersInfos

  if not state.vehicleCache.cacheValid then
    U.cacheDealers()
    changed = true
  end

  local facilitiesData = freeroam_facilities.getFacilities(getCurrentLevelIdentifier())
  if not facilitiesData then
    log("W", "Career", "No facilities data available for current map; skipping vehicle list update")
    state.nextShopUpdateTime = os.time() + 60
    return
  end
  local facilities = facilitiesData

  if facilities.dealerships then
    for _, dealership in ipairs(facilities.dealerships) do
      if onlyStarterVehicles then
        if dealership.containsStarterVehicles then
          table.insert(sellers, {
            id = dealership.id,
            name = dealership.name,
            description = dealership.description,
            preview = dealership.preview,
            hiddenFromDealerList = dealership.hiddenFromDealerList or U.isPoliceDealershipLocked(dealership.id),
            associatedOrganization = dealership.associatedOrganization,
            vehicleGenerationMultiplier = dealership.vehicleGenerationMultiplier,
            stock = dealership.stock,
            maxStockPerModel = dealership.maxStockPerModel,
            salesChannel = dealership.salesChannel or (dealership.remotePurchaseOnly and "factory"),
            range = dealership.range,
            fees = dealership.fees,
            salesTax = dealership.salesTax,
            priceRoundingType = dealership.priceRoundingType,
            filter = {whiteList = {careerStarterVehicle = {true}}},
            subFilters = nil
          })
        end
      else
        table.insert(sellers, {
          id = dealership.id,
          name = dealership.name,
          description = dealership.description,
          preview = dealership.preview,
          hiddenFromDealerList = dealership.hiddenFromDealerList or U.isPoliceDealershipLocked(dealership.id),
          associatedOrganization = dealership.associatedOrganization,
          vehicleGenerationMultiplier = dealership.vehicleGenerationMultiplier,
          stock = dealership.stock,
          maxStockPerModel = dealership.maxStockPerModel,
          range = dealership.range,
          fees = dealership.fees,
          salesTax = dealership.salesTax,
            priceRoundingType = dealership.priceRoundingType,
            salesChannel = dealership.salesChannel or (dealership.remotePurchaseOnly and "factory"),
            mileageProfile = dealership.mileageProfile,
            remanCommercial = dealership.remanCommercial,
            remotePurchaseLevel = dealership.remotePurchaseLevel,
            garageDeliveryLevel = dealership.garageDeliveryLevel,
            deliveryDiscountLevel = dealership.deliveryDiscountLevel,
            deliveryDiscount = dealership.deliveryDiscount,
            freightPickupSpotNames = dealership.freightPickupSpotNames,
            filter = dealership.filter or {},
            subFilters = dealership.subFilters
        })
      end
    end
  end

  if not onlyStarterVehicles and facilities.privateSellers then
    for _, dealership in ipairs(facilities.privateSellers) do
      table.insert(sellers, {
        id = dealership.id,
        name = dealership.name,
        description = dealership.description,
        preview = dealership.preview,
        hiddenFromDealerList = dealership.hiddenFromDealerList,
        associatedOrganization = dealership.associatedOrganization,
        vehicleGenerationMultiplier = dealership.vehicleGenerationMultiplier,
        stock = dealership.stock,
        maxStockPerModel = dealership.maxStockPerModel,
        range = dealership.range,
        fees = dealership.fees,
        salesTax = dealership.salesTax,
          priceRoundingType = dealership.priceRoundingType,
          salesChannel = dealership.salesChannel or "private",
          filter = dealership.filter or {},
          subFilters = dealership.subFilters
      })
    end
  end
  table.sort(sellers, function(a, b)
    return a.id < b.id
  end)

  if M.pruneBlacklistedSellerStock(sellers) > 0 then
    changed = true
  end

  local currentTime = os.time()

  -- Track which vehicles are being marked as sold this update
  local justExpiredShopIds = {}

  -- Remove vehicles that have expired using v38 watchlist logic
  for i = #state.vehiclesInShop, 1, -1 do
    local vehicleInfo = state.vehiclesInShop[i]
    U.normalizeVehicleShopTiming(vehicleInfo, currentTime)
    local offerTime = currentTime - vehicleInfo.generationTime
    if offerTime > vehicleInfo.offerTTL then
      if state.vehicleWatchlist[vehicleInfo.shopId] then
        if type(state.vehicleWatchlist[vehicleInfo.shopId]) ~= "number" then
          state.vehicleWatchlist[vehicleInfo.shopId] = currentTime + C.timeToRemoveSoldVehicle
          if not vehicleInfo.soldFor then
            vehicleInfo.soldFor = U.generateSoldVehicleValue(vehicleInfo.shopId)
          end
        end
        vehicleInfo.soldViewCounter = vehicleInfo.soldViewCounter or 0
        vehicleInfo.soldViewCounter = vehicleInfo.soldViewCounter + 1
        vehicleInfo.markedSold = true
        justExpiredShopIds[vehicleInfo.shopId] = true
        changed = true
        if currentTime > state.vehicleWatchlist[vehicleInfo.shopId] then
          state.vehicleWatchlist[vehicleInfo.shopId] = nil
          table.remove(state.vehiclesInShop, i)
          changed = true
        end
      else
        table.remove(state.vehiclesInShop, i)
        changed = true
      end
    end
  end

  local unsoldCountBySellerId = {}
  local stockedConfigsBySeller = {}
  local duplicateStockRemoved = 0
  for i = #state.vehiclesInShop, 1, -1 do
    local vehicleInfo = state.vehiclesInShop[i]
    if vehicleInfo.sellerId and not vehicleInfo.soldViewCounter then
      if U.isCarMeetShopVehicle(vehicleInfo) then
        unsoldCountBySellerId[vehicleInfo.sellerId] = (unsoldCountBySellerId[vehicleInfo.sellerId] or 0) + 1
      else
        local sellerConfigKeys = stockedConfigsBySeller[vehicleInfo.sellerId] or {}
        stockedConfigsBySeller[vehicleInfo.sellerId] = sellerConfigKeys
        local configKey = U.getVehicleConfigTrackingKey(vehicleInfo)
        if sellerConfigKeys[configKey] then
          table.remove(state.vehiclesInShop, i)
          duplicateStockRemoved = duplicateStockRemoved + 1
          changed = true
        else
          sellerConfigKeys[configKey] = true
          unsoldCountBySellerId[vehicleInfo.sellerId] = (unsoldCountBySellerId[vehicleInfo.sellerId] or 0) + 1
        end
      end
    end
  end
  if duplicateStockRemoved > 0 then
    log("I", "Career", string.format("Removed %d duplicate dealer configuration listings", duplicateStockRemoved))
  end

  local sellerMeta = {}

  for _, seller in ipairs(sellers) do
    local sellerAttemptedStart = updateSummary.attempted
    local sellerInsertedStart = updateSummary.inserted
    local sellerDroppedStart = updateSummary.dropped
    local dealershipData = state.vehicleCache.dealershipCache[seller.id]
    if dealershipData and dealershipData.notConfigured then
      goto continue
    end

    if not state.sellersInfos[seller.id] then
      state.sellersInfos[seller.id] = {
        lastGenerationTime = 0,
        mapId = currentMap,
        lastOrgLevel = nil
      }
      changed = true
    end
    if fromScratch then
      state.sellersInfos[seller.id].lastGenerationTime = 0
    end

    local randomVehicleInfos = {}
    local currentVehicleCount = unsoldCountBySellerId[seller.id] or 0
    local stockedConfigKeys = {}
    local stockedModels = {}
    local modelLimit = tonumber(seller.maxStockPerModel)
    if not modelLimit or modelLimit ~= modelLimit or modelLimit == math.huge then
      modelLimit = seller.salesChannel == "factory" and 0 or 3
    end
    modelLimit = math.max(0, math.floor(modelLimit))
    for _, stockedVehicle in ipairs(state.vehiclesInShop) do
      if stockedVehicle.sellerId == seller.id and not stockedVehicle.soldViewCounter then
        stockedConfigKeys[U.getVehicleConfigTrackingKey(stockedVehicle)] = true
        local model = stockedVehicle.model_key
        if model then stockedModels[model] = (stockedModels[model] or 0) + 1 end
      end
    end

    local function drawUnstockedSellerVehicles(drawCount)
      local selected = U.getRandomVehicleFromCache(seller.id, drawCount, stockedConfigKeys, modelLimit, stockedModels)
      for _, selectedVehicle in ipairs(selected) do
        stockedConfigKeys[U.getVehicleConfigTrackingKey(selectedVehicle)] = true
      end
      return selected
    end

    local currentOrgLevel = nil
    if seller.associatedOrganization then
      local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
      if org and org.reputation then
        local repLevel = org.reputation.level or 0
        if type(repLevel) ~= "number" then
          repLevel = 0
        end
        currentOrgLevel = repLevel
      end
    end

    local storedLevel = state.sellersInfos[seller.id].lastOrgLevel
    local levelChanged = (currentOrgLevel ~= nil) and (storedLevel ~= nil) and (storedLevel ~= currentOrgLevel)

    local maxStock = tonumber(seller.stock) or 10
    if seller.associatedOrganization then
      local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
      local level = U.getOrgLevelData(org)
      local levelStock = level and tonumber(level.stock) or nil
      if levelStock then
        maxStock = levelStock
      end
    end
    maxStock = math.max(math.floor(maxStock), 1)
    local availableSlots = math.max(0, maxStock - currentVehicleCount)

    local numberOfVehiclesToGenerate = 0
    local adjustedTimeBetweenOffers = C.vehicleOfferTimeToLive / maxStock
    local generationMultiplier = tonumber(seller.vehicleGenerationMultiplier)
    if generationMultiplier and generationMultiplier > 0 then
      adjustedTimeBetweenOffers = adjustedTimeBetweenOffers / generationMultiplier
    end

    if onlyStarterVehicles then
      -- Generate the starter vehicles
      local eligibleVehiclesStarterRaw = util_configListGenerator.getEligibleVehicles(onlyStarterVehicles) or {}
      local eligibleVehiclesStarter, starterSummary = U.sanitizeVehicleInfoList(eligibleVehiclesStarterRaw,
        "updateVehicleList:starterEligible", "generationDropped")
      if starterSummary.malformed > 0 or starterSummary.quarantined > 0 then
        U.logVehicleSanitizationSummary("updateVehicleList starter eligible vehicles", starterSummary)
      end
      randomVehicleInfos = util_configListGenerator.getRandomVehicleInfos(seller, 3, eligibleVehiclesStarter,
        "adjustedPopulation") or {}
    else
      -- vehicleGenerationMultiplier lowers the time between offers
      local maxVehicles = math.floor(C.vehicleOfferTimeToLive / adjustedTimeBetweenOffers)
      numberOfVehiclesToGenerate = math.min(math.floor((currentTime - state.sellersInfos[seller.id].lastGenerationTime) / adjustedTimeBetweenOffers), maxVehicles)

      if levelChanged then
        U.rebuildDealershipCache(seller.id)
        numberOfVehiclesToGenerate = availableSlots
        state.sellersInfos[seller.id].lastGenerationTime = 0
        log("I", "Career", string.format("Level changed for %s (from %d to %d), restocking to %d vehicles", 
          seller.id, storedLevel, currentOrgLevel, availableSlots))
      elseif fromScratch or state.sellersInfos[seller.id].lastGenerationTime == 0 then
        numberOfVehiclesToGenerate = availableSlots
        log("D", "Career",
          string.format("Initial stock fill for %s: generating %d vehicles", seller.id, numberOfVehiclesToGenerate))
      elseif availableSlots > 0 and numberOfVehiclesToGenerate < availableSlots then
        numberOfVehiclesToGenerate = availableSlots
        log("D", "Career",
          string.format("Stock below target for %s: generating %d vehicles to reach %d", seller.id, availableSlots, maxStock))
      end

      -- Generate unique configurations that are not already stocked by this seller.
      local newRandomVehicleInfos = drawUnstockedSellerVehicles(numberOfVehiclesToGenerate)
      arrayConcat(randomVehicleInfos, newRandomVehicleInfos)

      local numberOfMissingVehicles = numberOfVehiclesToGenerate - tableSize(newRandomVehicleInfos)
      if numberOfMissingVehicles > 0 then
        log("W", "Career", string.format(
          "Seller %s is short %d unique eligible configurations; leaving those stock slots empty",
          tostring(seller.id), numberOfMissingVehicles))
      end
    end

    local starterVehicleMileages = {bx = 165746239, etki = 285817342, covet = 80174611}
    local starterVehicleYears = {bx = 1990, etki = 1989, covet = 1989}
    local targetVehicleCount = onlyStarterVehicles and tableSize(randomVehicleInfos) or numberOfVehiclesToGenerate
    local successfulGenerationsForSeller = 0
    local replacementCycles = 0
    local maxReplacementCycles = onlyStarterVehicles and 0 or 2
    local nextBatchStartIndex = 1
    local attemptedGenerationForSeller = false

    if onlyStarterVehicles then
      attemptedGenerationForSeller = not tableIsEmpty(randomVehicleInfos)
    elseif numberOfVehiclesToGenerate > 0 then
      attemptedGenerationForSeller = true
    end

    while nextBatchStartIndex <= #randomVehicleInfos and successfulGenerationsForSeller < targetVehicleCount do
      local batchEndIndex = #randomVehicleInfos
      for i = nextBatchStartIndex, batchEndIndex do
        if successfulGenerationsForSeller >= targetVehicleCount then
          break
        end

        local randomVehicleInfo = randomVehicleInfos[i]
        updateSummary.attempted = updateSummary.attempted + 1
        if U.isQuarantined(randomVehicleInfo) then
          updateSummary.dropped = updateSummary.dropped + 1
          U.incrementValidationStat("generationDropped")
        else
          local shapeOk, shapeReason = U.isValidVehicleInfoShape(randomVehicleInfo)
          if not shapeOk then
            U.quarantineVehicleConfig(randomVehicleInfo, shapeReason, "updateVehicleList")
            updateSummary.dropped = updateSummary.dropped + 1
            U.incrementValidationStat("generationDropped")
          else
            local generatedVehicle, err = U.safeVehicleOp("updateVehicleList", randomVehicleInfo, function()
              randomVehicleInfo.generationTime = currentTime - (successfulGenerationsForSeller * adjustedTimeBetweenOffers)
              randomVehicleInfo.offerTTL = onlyStarterVehicles and math.huge or C.vehicleOfferTimeToLive

              randomVehicleInfo.sellerId = seller.id
              randomVehicleInfo.sellerName = seller.name
              randomVehicleInfo.salesChannel = seller.salesChannel or (seller.id == "private" and "private" or "local")

              local filter = M.choosePrecomputedFilter(randomVehicleInfo)
              if not filter and seller.associatedOrganization then
                local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
                local level = U.getOrgLevelData(org)
                if level and level.filter then
                  filter = level.filter
                end
              end
              filter = filter or (seller.filter or {})
              randomVehicleInfo.filter = filter

              local years = U.safeYearsRange(randomVehicleInfo)

              if not onlyStarterVehicles then
                if years then
                  local minYear = years.min
                  local filterMinYear = filter.whiteList and filter.whiteList.Years and tonumber(filter.whiteList.Years.min)
                  if filterMinYear then
                    minYear = math.max(minYear, filterMinYear)
                  end
                  local maxYear = years.max
                  local filterMaxYear = filter.whiteList and filter.whiteList.Years and tonumber(filter.whiteList.Years.max)
                  if filterMaxYear then
                    maxYear = math.min(maxYear, filterMaxYear)
                  end
                  if minYear > maxYear then
                    error("invalid year bounds after filtering")
                  end
                  randomVehicleInfo.year = math.random(minYear, maxYear)
                else
                  randomVehicleInfo.year = tonumber(randomVehicleInfo.year) or C.missingYearsFallbackModelYear
                end

                randomVehicleInfo.Mileage, randomVehicleInfo.wearMileage, randomVehicleInfo.mileageClass =
                  U.generateAgeDrivenMileage(seller, randomVehicleInfo, randomVehicleInfo.year)
              else
                randomVehicleInfo.year = starterVehicleYears[randomVehicleInfo.model_key]
                if not randomVehicleInfo.year then
                  if years then
                    randomVehicleInfo.year = math.random(years.min, years.max)
                  else
                    randomVehicleInfo.year = tonumber(randomVehicleInfo.year) or C.missingYearsFallbackModelYear
                  end
                end
                randomVehicleInfo.Mileage = starterVehicleMileages[randomVehicleInfo.model_key] or 100000000
              end

              local valuationYear = tonumber(os.date("%Y")) or 2026
              local vehicleAge = math.max(0, valuationYear - (tonumber(randomVehicleInfo.year) or valuationYear))
              local catalogBaseValue = randomVehicleInfo.effectiveCatalogValue or randomVehicleInfo.Value
              local valuation = career_modules_valueCalculator.getVehicleValuation and
                career_modules_valueCalculator.getVehicleValuation({
                  catalogBaseValue = catalogBaseValue,
                  mileageMeters = randomVehicleInfo.Mileage,
                  age = vehicleAge,
                  modelName = randomVehicleInfo.model_key,
                  configKey = randomVehicleInfo.key,
                  configInfo = randomVehicleInfo,
                  partsCatalogSum = randomVehicleInfo.cachedPartsValue,
                  logContext = "updateVehicleList",
                  applyVehicleBuyMarket = false
                }) or nil
              local baseValue = valuation and valuation.bookValue or
                career_modules_valueCalculator.getVehicleCatalogIntrinsicBookValue({
                catalogBaseValue = catalogBaseValue,
                mileageMeters = randomVehicleInfo.Mileage,
                age = vehicleAge,
                modelName = randomVehicleInfo.model_key,
                configKey = randomVehicleInfo.key,
                partsCatalogSum = randomVehicleInfo.cachedPartsValue,
                logContext = "updateVehicleList",
                applyVehicleBuyMarket = false
              }) or math.max(1500,
                math.floor(career_modules_valueCalculator.getAdjustedVehicleBaseValue(catalogBaseValue, {
                  mileage = randomVehicleInfo.Mileage,
                  age = vehicleAge
                }) / 1000) * 1000)
              randomVehicleInfo.valuation = valuation
              if valuation then
                randomVehicleInfo.haloScore = valuation.haloScore
                randomVehicleInfo.haloSignals = valuation.haloSignals
              end

              local range = seller.range
              if seller.associatedOrganization then
                local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
                local level = U.getOrgLevelData(org)
                if level and level.range then
                  range = level.range
                end
              end

              if seller.id == "private" then
                if career_modules_marketplace and career_modules_marketplace.generatePersonality then
                  randomVehicleInfo.negotiationPersonality = career_modules_marketplace.generatePersonality(false)
                  randomVehicleInfo.sellerName = randomVehicleInfo.negotiationPersonality.name
                end
              else
                if career_modules_marketplace and career_modules_marketplace.generatePersonality then
                  local personalityKey = seller.id
                  randomVehicleInfo.negotiationPersonality = career_modules_marketplace.generatePersonality(false,
                    {personalityKey})
                end
              end

              local randomizedValue, priceBand, dealerPriceMultiplier = U.getRandomizedPrice(baseValue, range)
              randomVehicleInfo.marketValue = randomizedValue
              randomVehicleInfo.marketValueBase = randomVehicleInfo.marketValue
              randomVehicleInfo.priceRoundingType = seller.priceRoundingType
              randomVehicleInfo.priceBand = priceBand
              randomVehicleInfo.dealerPriceMultiplier = dealerPriceMultiplier

              local priceMultiplier = (randomVehicleInfo.negotiationPersonality and
                                        randomVehicleInfo.negotiationPersonality.priceMultiplier) or 1
              priceMultiplier = math.max(0.95, math.min(1.05, tonumber(priceMultiplier) or 1))
              local combinedMultiplier = dealerPriceMultiplier * priceMultiplier
              if priceBand == "lowTail" then
                combinedMultiplier = math.max(0.70, math.min(0.88, combinedMultiplier))
              elseif priceBand == "highTail" then
                combinedMultiplier = math.max(1.12, math.min(1.30, combinedMultiplier))
              else
                combinedMultiplier = math.max(0.88, math.min(1.12, combinedMultiplier))
              end
              randomVehicleInfo.valueBase = baseValue * combinedMultiplier
              randomVehicleInfo.priceMultiplier = priceMultiplier
              randomVehicleInfo.combinedSellerMultiplier = combinedMultiplier

              local vehicleBuyMult = career_modules_valueCalculator.getVehicleBuyMarketMultiplier()
              randomVehicleInfo.Value = U.getRoundedPrice(randomVehicleInfo.valueBase * vehicleBuyMult,
                seller.priceRoundingType)

              randomVehicleInfo.negotiationPossible = not onlyStarterVehicles
              randomVehicleInfo.shopId = U.generateShopId()
              randomVehicleInfo.associatedOrganization = seller.associatedOrganization
              local dealership = U.getDealershipForSellerId(seller.id)
              local accessInfo = U.getSellerAccessInfo(dealership or seller)
              randomVehicleInfo.remotePurchaseAllowed = accessInfo.remotePurchaseAllowed
              randomVehicleInfo.garageDeliveryAllowed = accessInfo.garageDeliveryAllowed
              randomVehicleInfo.deliveryDiscount = accessInfo.deliveryDiscount

              local fees = seller.fees or 0
              if seller.associatedOrganization then
                local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
                local level = U.getOrgLevelData(org)
                if level and level.fees ~= nil then
                  fees = level.fees
                end
              end
              fees = tonumber(fees)
              randomVehicleInfo.fees = fees or 0

              local tax = seller.salesTax or C.salesTax
              if seller.associatedOrganization then
                local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
                local level = U.getOrgLevelData(org)
                if level and level.tax ~= nil then
                  tax = level.tax
                end
              end
              tax = tonumber(tax)
              randomVehicleInfo.tax = tax or C.salesTax

              if seller.id == "private" then
                local parkingData = gameplay_parking.getParkingSpots()
                local parkingSpots = parkingData and parkingData.byName or {}
                local sizeMatches, allowedSpots = {}, {}
                local boxX, boxY, boxZ = U.safeBoundingBoxDimensions(randomVehicleInfo)
                for name, spot in pairs(parkingSpots) do
                  local tags = (spot.customFields and spot.customFields.tags) or {}
                  if not tags.notprivatesale then
                    table.insert(allowedSpots, {
                      name = name,
                      spot = spot
                    })
                    if boxX and spot.boxFits and spot:boxFits(boxX, boxY, boxZ) then
                      table.insert(sizeMatches, {
                        name = name,
                        spot = spot
                      })
                    end
                  end
                end

                local pool = (#sizeMatches > 0) and sizeMatches or allowedSpots
                local chosen = nil
                if #pool > 0 then
                  chosen = pool[math.random(#pool)]
                end
                if chosen then
                  randomVehicleInfo.parkingSpotName = chosen.name
                  randomVehicleInfo.pos = chosen.spot.pos
                else
                  log("W", "Career",
                    string.format("No parking spot available for private sale vehicle %s",
                      tostring(randomVehicleInfo.shopId)))
                end
              else
                local dealership = U.getDealershipForSellerId(seller.id)
                randomVehicleInfo.pos = freeroam_facilities.getAverageDoorPositionForFacility(dealership)
              end

              if career_modules_insurance_insurance and
                career_modules_insurance_insurance.getInsuranceClassFromVehicleShoppingData then
                local vehicleInsuranceClass =
                  career_modules_insurance_insurance.getInsuranceClassFromVehicleShoppingData(randomVehicleInfo)
                if vehicleInsuranceClass then
                  randomVehicleInfo.insuranceClass = vehicleInsuranceClass
                end
              end

              if legacyInsurance and legacyInsurance.getMinApplicablePolicyFromVehicleShoppingData then
                local requiredInsurance =
                  legacyInsurance.getMinApplicablePolicyFromVehicleShoppingData(randomVehicleInfo)
                if requiredInsurance then
                  randomVehicleInfo.requiredInsurance = requiredInsurance
                end
              end

              randomVehicleInfo.mapId = currentMap
              return randomVehicleInfo
            end)

            if err or not generatedVehicle then
              updateSummary.dropped = updateSummary.dropped + 1
              U.incrementValidationStat("generationDropped")
            else
              table.insert(state.vehiclesInShop, generatedVehicle)
              if generatedVehicle.sellerId and not generatedVehicle.soldViewCounter then
                unsoldCountBySellerId[generatedVehicle.sellerId] = (unsoldCountBySellerId[generatedVehicle.sellerId] or 0) + 1
                local model = generatedVehicle.model_key
                if model then stockedModels[model] = (stockedModels[model] or 0) + 1 end
              end
              changed = true
              updateSummary.inserted = updateSummary.inserted + 1
              successfulGenerationsForSeller = successfulGenerationsForSeller + 1
            end
          end
        end
      end

      nextBatchStartIndex = batchEndIndex + 1
      if successfulGenerationsForSeller >= targetVehicleCount or replacementCycles >= maxReplacementCycles then
        break
      end

      local replacementCount = targetVehicleCount - successfulGenerationsForSeller
      if replacementCount <= 0 then
        break
      end

      replacementCycles = replacementCycles + 1
      local replacementVehicles = drawUnstockedSellerVehicles(replacementCount)
      if tableIsEmpty(replacementVehicles) then
        break
      end

      attemptedGenerationForSeller = true
      arrayConcat(randomVehicleInfos, replacementVehicles)
    end
    if successfulGenerationsForSeller >= targetVehicleCount then
      state.sellersInfos[seller.id].lastGenerationTime = currentTime
      changed = true
    elseif attemptedGenerationForSeller and targetVehicleCount == 0 then
      state.sellersInfos[seller.id].lastGenerationTime = currentTime
      changed = true
    end
    if updateSummary.attempted > sellerAttemptedStart then
      log("I", "Career", string.format("updateVehicleList seller %s: attempted=%d inserted=%d dropped=%d",
        tostring(seller.id),
        updateSummary.attempted - sellerAttemptedStart,
        updateSummary.inserted - sellerInsertedStart,
        updateSummary.dropped - sellerDroppedStart))
    end

    if currentOrgLevel ~= nil then
      state.sellersInfos[seller.id].lastOrgLevel = currentOrgLevel
    end

    sellerMeta[seller.id] = {
      maxStock = maxStock,
      adjustedTimeBetweenOffers = adjustedTimeBetweenOffers
    }

    ::continue::
  end

  local minNext = math.huge
  for _, veh in ipairs(state.vehiclesInShop) do
    if veh.generationTime and veh.offerTTL then
      local expiryTime = veh.generationTime + veh.offerTTL
      if expiryTime > currentTime and expiryTime < minNext then
        minNext = expiryTime
      end
    end
  end
  for _, seller in ipairs(sellers) do
    local meta = sellerMeta[seller.id]
    local fallbackMaxStock = math.max(math.floor(tonumber(seller.stock) or 10), 1)
    local maxStock = meta and meta.maxStock or fallbackMaxStock
    local currentCount = unsoldCountBySellerId[seller.id] or 0
    local availableSlotsAfter = math.max(0, maxStock - currentCount)
    if availableSlotsAfter > 0 then
      local lastGen = (state.sellersInfos[seller.id] and state.sellersInfos[seller.id].lastGenerationTime) or 0
      local interval = meta and meta.adjustedTimeBetweenOffers or (C.vehicleOfferTimeToLive / maxStock)
      local nextGen = (lastGen > 0 and (lastGen + interval)) or currentTime
      if nextGen < minNext then
        minNext = nextGen
      end
    end
  end
  if minNext == math.huge then
    minNext = currentTime + 60
  end
  state.nextShopUpdateTime = minNext

  if not changed then
    return
  end

  state.vehicleShopDirtyDate = os.date("!%Y-%m-%dT%H:%M:%SZ")
  log("I", "Career", "Vehicles in shop: " .. tableSize(state.vehiclesInShop))
  log("I", "Career", string.format("updateVehicleList summary: attempted=%d inserted=%d dropped=%d",
    updateSummary.attempted, updateSummary.inserted, updateSummary.dropped))

  local newSnap = U.buildSnapshot()
  U.commitDelta(newSnap, justExpiredShopIds)
  guihooks.trigger("vehicleShopDelta", state.lastDelta)
end

-- Vehicle spawning and delivery functions

-- Private listings advertise a real parking spot (chosen in updateVehicleList) - that is the spot
-- the taxi and the route marker point at, so a bought vehicle has to actually turn up there.
function M.moveVehicleToListingSpot(vehObj, vehicleInfo)
  if not vehObj or not vehicleInfo or not vehicleInfo.parkingSpotName then return false end
  local parkingData = gameplay_parking.getParkingSpots()
  local spot = parkingData and parkingData.byName and parkingData.byName[vehicleInfo.parkingSpotName]
  if not spot then
    log("D", "Career", "Listing parking spot '" .. tostring(vehicleInfo.parkingSpotName) .. "' not found")
    return false
  end
  spot:moveResetVehicleTo(vehObj:getID(), nil, nil, nil, nil, true)
  return true
end

-- Not every seller has a facility: private sellers park in the world, so getDealership("private")
-- returns nil and the old unguarded chain threw while spawning a just-purchased vehicle.
-- Leave the vehicle where it spawned rather than taking the whole purchase down with it.
U.moveVehicleToDealership = function(vehObj, dealershipId, useFreightPickup)
  if not vehObj or not dealershipId then return false end
  local dealership = U.getDealershipForSellerId(dealershipId)
  if not dealership then
    log("D", "Career", "No dealership facility for '" .. tostring(dealershipId) .. "'; leaving vehicle at spawn")
    return false
  end
  if useFreightPickup and type(dealership.freightPickupSpotNames) == "table" then
    dealership = deepcopy(dealership)
    dealership.parkingSpotNames = dealership.freightPickupSpotNames
  end
  local parkingSpots = freeroam_facilities.getParkingSpotsForFacility(dealership)
  if not parkingSpots or not next(parkingSpots) then return false end
  local parkingSpot = gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(vehObj:getID(), parkingSpots)
  if not parkingSpot then return false end
  parkingSpot:moveResetVehicleTo(vehObj:getID(), nil, nil, nil, nil, true)
  return true
end

U.moveVehicleToRewardTransform = function(vehObj, transform)
  if not vehObj or type(transform) ~= "table" then return end
  local loaded, placer = pcall(require, "gameplay/rewardVehiclePlacement")
  if loaded and placer and placer.place and placer.place(vehObj, transform) then return end

  local pos = transform.pos or transform.position
  if not pos then return end

  local rot = transform.rot or transform.rotation or {}
  local px = tonumber(pos.x or pos[1])
  local py = tonumber(pos.y or pos[2])
  local pz = tonumber(pos.z or pos[3])
  if not px or not py or not pz then return end

  local qx = tonumber(rot.x or rot[1]) or 0
  local qy = tonumber(rot.y or rot[2]) or 0
  local qz = tonumber(rot.z or rot[3]) or 0
  local qw = tonumber(rot.w or rot[4]) or 1
  if spawn and spawn.safeTeleport then
    local rewardRot = quat(qx, qy, qz, qw)
    local safeTeleportRot = quat(0, 0, -1, 0) * rewardRot
    spawn.safeTeleport(vehObj, vec3(px, py, pz), safeTeleportRot, false, nil, false, true, false)
  else
    vehObj:setPosRot(px, py, pz + 0.5, qx, qy, qz, qw)
  end
end

U.getConfigKeyFromPath = function(configPath)
  if type(configPath) ~= "string" then return nil end
  local normalized = configPath:gsub("\\", "/")
  local key = normalized:match("/configurations/([^/]+)%.pc$")
  if key then return key end
  return normalized:match("/([^/]+)%.pc$")
end

U.applyRandomPaintToSpawnOptions = function(options, modelKey, configPath)
  if not options or not modelKey then return nil end
  if not core_vehiclePaints or not core_vehiclePaints.getRandomPaints then return nil end

  local paintResult = core_vehiclePaints.getRandomPaints(modelKey, U.getConfigKeyFromPath(configPath))
  if type(paintResult) ~= "table" then return nil end

  local modelData = core_vehicles.getModel(modelKey)
  local modelPaints = modelData and modelData.model and modelData.model.paints
  if type(modelPaints) ~= "table" then return nil end

  local paintNames = {
    paintResult.paintName1,
    paintResult.paintName2 or paintResult.paintName1,
    paintResult.paintName3 or paintResult.paintName2 or paintResult.paintName1
  }
  if not paintNames[1] or not modelPaints[paintNames[1]] then return nil end

  options.paintName = paintNames[1]
  options.paintName2 = paintNames[2]
  options.paintName3 = paintNames[3]
  options.paint = deepcopy(modelPaints[paintNames[1]])
  options.paint2 = paintNames[2] and modelPaints[paintNames[2]] and deepcopy(modelPaints[paintNames[2]]) or nil
  options.paint3 = paintNames[3] and modelPaints[paintNames[3]] and deepcopy(modelPaints[paintNames[3]]) or nil

  if type(configPath) == "string" then
    local cfg = jsonReadFile(configPath)
    if type(cfg) == "table" and cfg.format ~= 4 then
      cfg = deepcopy(cfg)
      cfg.partConfigFilename = configPath
      cfg.colors = nil
      local paints = type(cfg.paints) == "table" and deepcopy(cfg.paints) or {}
      paints[1] = deepcopy(options.paint)
      if options.paint2 then paints[2] = deepcopy(options.paint2) end
      if options.paint3 then paints[3] = deepcopy(options.paint3) end
      cfg.paints = paints
      options.config = cfg
    end
  end

  return paintNames
end

U.applyRandomPaintToSpawnedVehicle = function(vehId, modelKey, paintNames)
  if not vehId or type(paintNames) ~= "table" or not paintNames[1] then return end
  if not core_vehicle_manager or not core_vehicle_manager.setVehiclePaintsNames then return end

  core_vehicle_manager.setVehiclePaintsNames(vehId, paintNames)

  local vehicleData = core_vehicle_manager.getVehicleData(vehId)
  if not vehicleData or type(vehicleData.config) ~= "table" then return end

  local modelData = modelKey and core_vehicles.getModel(modelKey) or nil
  if not modelData and vehicleData.ioCtx and vehicleData.ioCtx.modelKey then
    modelData = core_vehicles.getModel(vehicleData.ioCtx.modelKey)
  end
  local modelPaints = modelData and modelData.model and modelData.model.paints
  if type(modelPaints) ~= "table" then return end

  local config = vehicleData.config
  config.colors = nil
  local paints = type(config.paints) == "table" and deepcopy(config.paints) or {}
  for i, paintName in ipairs(paintNames) do
    if paintName and modelPaints[paintName] then
      paints[i] = deepcopy(modelPaints[paintName])
    end
  end
  config.paints = paints
  config.paintName = paintNames[1]
  config.paintName2 = paintNames[2]
  config.paintName3 = paintNames[3]
end

-- spawnFinishedCallbackName: exported M function name (e.g. onVehicleSpawnFinished adds personal inventory).
U.spawnShopVehicleInternal = function(vehicleInfo, dealershipToMoveTo, spawnFinishedCallbackName, rewardTransform, randomPaint, useFreightPickup)
  local spawnOptions = {}
  spawnOptions.config = vehicleInfo.key
  spawnOptions.autoEnterVehicle = false
  if rewardTransform then
    local loaded, placer = pcall(require, "gameplay/rewardVehiclePlacement")
    local airPos = loaded and placer and placer.airSpawnPos and placer.airSpawnPos(rewardTransform)
    if airPos then
      spawnOptions.pos = airPos
      spawnOptions.safeSpawn = false
      spawnOptions.cling = false
    end
  end
  local randomPaintNames
  if randomPaint then
    randomPaintNames = U.applyRandomPaintToSpawnOptions(spawnOptions, vehicleInfo.model_key, vehicleInfo.key)
  end
  local newVeh = core_vehicles.spawnNewVehicle(vehicleInfo.model_key, spawnOptions)
  if rewardTransform then
    U.moveVehicleToRewardTransform(newVeh, rewardTransform)
  elseif dealershipToMoveTo then
    U.moveVehicleToDealership(newVeh, dealershipToMoveTo, useFreightPickup)
  else
    -- no dealership lot: put it on the listing's own parking spot so it is where the map said
    M.moveVehicleToListingSpot(newVeh, vehicleInfo)
  end
  core_vehicleBridge.executeAction(newVeh, 'setIgnitionLevel', 0)

  newVeh:queueLuaCommand(string.format(
    "partCondition.initConditions(nil, %d, nil, %f) obj:queueGameEngineLua('career_modules_vehicleShopping.%s(%d)')",
    vehicleInfo.wearMileage or vehicleInfo.Mileage,
    U.getVisualValueFromMileage(vehicleInfo.wearMileage or vehicleInfo.Mileage),
    spawnFinishedCallbackName, newVeh:getID()))
  return newVeh, randomPaintNames
end

U.spawnVehicle = function(vehicleInfo, dealershipToMoveTo, useFreightPickup)
  return U.spawnShopVehicleInternal(vehicleInfo, dealershipToMoveTo, "onVehicleSpawnFinished", nil, nil, useFreightPickup)
end

-- Racing team fleet drive-in: world vehicle only until business inventory takes ownership (no personal addVehicle).
U.rtFleetSpawnVehicle = function(vehicleInfo, dealershipToMoveTo)
  return U.spawnShopVehicleInternal(vehicleInfo, dealershipToMoveTo, "onRacingTeamFleetVehicleSpawnFinished")
end

U.onRacingTeamFleetVehicleSpawnFinished = function(_vehId)
end

function M.completeFreightPickup(inventoryId)
  local inventoryVehicle = inventoryId and career_modules_inventory.getVehicles()[inventoryId]
  if not inventoryVehicle or
    string.find(tostring(inventoryVehicle.location or ""), "freightPickup:", 1, true) ~= 1 then
    return false
  end

  local vehId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
  local vehObj = vehId and getObjectByID(vehId)
  local closestGarage = not inventoryVehicle.freightHomeGarageId and
    career_modules_inventory.getClosestOwnedGarageWithSpace(
      vehObj and vehObj:getPosition() or nil) or nil
  if not career_modules_inventory.moveVehicleToGarage(
    inventoryId, inventoryVehicle.freightHomeGarageId or (closestGarage and closestGarage.id) or nil) then
    return false
  end
  inventoryVehicle.freightHomeGarageId = nil

  if core_groundMarkers then
    core_groundMarkers.setPath(nil)
  end
  ui_message(
    "Freight pickup complete. Home garage: " ..
      tostring(inventoryVehicle.niceLocation or "Assigned garage") .. ".",
    6, "Vehicle collected", "info")
  if career_career.isAutosaveEnabled() then
    career_saveSystem.saveCurrent()
  end
  return true
end

U.onVehicleSpawnFinished = function(vehId)
  local purchase = state.purchaseData
  local inventoryId = career_modules_inventory.addVehicle(vehId, nil, {
    year = purchase and purchase.vehicleInfo and purchase.vehicleInfo.year,
    finalPrice = purchase and purchase.prices and purchase.prices.finalPrice
  })

  if state.spawnFollowUpActions then
    if state.spawnFollowUpActions.delayAccess then
      career_modules_inventory.delayVehicleAccess(inventoryId, state.spawnFollowUpActions.delayAccess, "bought")
    end
    if state.spawnFollowUpActions.licensePlateText then
      career_modules_inventory.setLicensePlateText(inventoryId, state.spawnFollowUpActions.licensePlateText)
    end
    if state.spawnFollowUpActions.dealershipId and
      (state.spawnFollowUpActions.dealershipId == "policeDealership" or state.spawnFollowUpActions.dealershipId == "poliziaAuto") then
      career_modules_inventory.setVehicleRole(inventoryId, "police")
    end
    if state.spawnFollowUpActions.policyId ~= nil then
      local policyId = tonumber(state.spawnFollowUpActions.policyId) or 0
      if legacyInsurance and legacyInsurance.changeVehPolicy then
        legacyInsurance.changeVehPolicy(inventoryId, policyId)
      end
    end
    if state.spawnFollowUpActions.freightPickup then
      local inventoryVehicle = career_modules_inventory.getVehicles()[inventoryId]
      if inventoryVehicle then
        inventoryVehicle.location = "freightPickup:" .. tostring(state.spawnFollowUpActions.dealershipId or "online")
        inventoryVehicle.niceLocation = "Freight Pickup"
        inventoryVehicle.freightHomeGarageId = state.spawnFollowUpActions.targetGarageId
      end
      local freightVehicle = getObjectByID(vehId)
      if freightVehicle then
        if core_groundMarkers then
          core_groundMarkers.setPath(freightVehicle:getPosition())
        end
        if career_modules_playerDriving and career_modules_playerDriving.showPosition then
          career_modules_playerDriving.showPosition(freightVehicle:getPosition())
        end
      end
      ui_message("Order ready at Freight Pickup. It is listed in Vehicle Inventory under Freight Pickup, and a route has been set.", 10,
        "Freight order ready", "info")
    else
      career_modules_inventory.moveVehicleToGarage(inventoryId, state.spawnFollowUpActions.targetGarageId)
    end
    state.spawnFollowUpActions = nil
  end
end

U.onRewardVehicleSpawnFinished = function(vehId)
  local data = state.rewardVehicleGrantData or {}
  state.rewardVehicleGrantData = nil

  if data.randomPaintNames then
    U.applyRandomPaintToSpawnedVehicle(vehId, data.vehicleInfo and data.vehicleInfo.model_key, data.randomPaintNames)
  end

  local addOptions = { owned = true, year = data.vehicleInfo and data.vehicleInfo.year }
  if data.ignoreGarageLimit then
    addOptions.takesNoInventorySpace = true
  end
  local inventoryId = career_modules_inventory.addVehicle(vehId, nil, addOptions)
  if not inventoryId then return end

  local inventoryVehicle = career_modules_inventory.getVehicles and career_modules_inventory.getVehicles()[inventoryId]
  if inventoryVehicle then
    local vehicleData = core_vehicle_manager and core_vehicle_manager.getVehicleData(vehId)
    if vehicleData and type(vehicleData.config) == "table" then
      inventoryVehicle.config = deepcopy(vehicleData.config)
    end
    inventoryVehicle.mileage = data.vehicleInfo and data.vehicleInfo.Mileage or inventoryVehicle.mileage or 0
    inventoryVehicle.purchasePrice = 0
    inventoryVehicle.rewardSource = data.source or "Reward"
  end

  -- Reward grants are not dealership purchases; start uninsured like car-meet buys.
  extensions.hook("onVehicleAddedToInventory", {
    inventoryId = inventoryId,
    vehicleInfo = data.vehicleInfo,
    purchaseData = {insuranceId = -1},
  })

  local vehObj = getObjectByID(vehId)
  if vehObj then
    vehObj:queueLuaCommand('ai.setMode("disabled")')
    vehObj:queueLuaCommand('electrics.setIgnitionLevel(0)')
    vehObj:queueLuaCommand("input.event('parkingbrake', 1, 1)")
    vehObj:queueLuaCommand('if electrics.setLightsState then electrics.setLightsState(0) end')
    vehObj:queueLuaCommand('if electrics.set_warn_signal then electrics.set_warn_signal(0) end')
  end

  if career_career.isAutosaveEnabled() then
    career_saveSystem.saveCurrent()
  end
end

U.grantRewardVehicle = function(vehicleInfo, source, options)
  if not vehicleInfo or not vehicleInfo.model_key or not vehicleInfo.key then return false end
  options = options or {}
  if not options.ignoreGarageLimit and not U.canPurchaseCarMeetVehicle(true) then return false end
  if state.rewardVehicleGrantData then return false end

  state.rewardVehicleGrantData = {
    vehicleInfo = deepcopy(vehicleInfo),
    source = source or "Reward",
    ignoreGarageLimit = options.ignoreGarageLimit == true
  }
  local _, randomPaintNames = U.spawnShopVehicleInternal(vehicleInfo, nil, "onRewardVehicleSpawnFinished", options.spawnTransform, options.randomPaint == true)
  state.rewardVehicleGrantData.randomPaintNames = randomPaintNames
  return true
end

-- Purchase and payment functions
-- Trade-in surplus past vehicle+fees reduces finalPrice below zero (cash back to the player).
-- Tax is still only charged on a non-negative taxable base.
function M.computePurchaseTaxAndFinalPrice(vehicleShopInfo, tradeInValue)
  tradeInValue = tonumber(tradeInValue) or 0
  local vehicleAndFees = (tonumber(vehicleShopInfo.Value) or 0) + (tonumber(vehicleShopInfo.fees) or 0)
  local taxes = math.max((vehicleAndFees - tradeInValue) * (vehicleShopInfo.tax or C.salesTax), 0)
  if vehicleShopInfo.sellerId == "discountedDealership" or vehicleShopInfo.sellerId == "joesJunkDealership" then
    taxes = 0
  end
  return taxes, vehicleAndFees + taxes - tradeInValue
end

function M.tradeInFreesInventorySlot()
  local info = state.purchaseData and state.purchaseData.tradeInVehicleInfo
  return info ~= nil and info.id ~= nil and not info.takesNoInventorySpace
end

function M.hasInventorySlotForPurchase()
  return career_modules_inventory.hasFreeSlot() or M.tradeInFreesInventorySlot()
end

function M.applyDeliveryCharge(quote)
  local previousDelivery = tonumber(state.purchaseData.prices.delivery) or 0
  local deliveryPrice = tonumber(quote and quote.finalPrice) or 0
  state.purchaseData.prices.finalPrice =
    (tonumber(state.purchaseData.prices.finalPrice) or 0) - previousDelivery + deliveryPrice
  state.purchaseData.prices.delivery = deliveryPrice
end

-- Validate before removing a trade-in so a failed purchase cannot eat the traded vehicle.
function M.canCompletePersonalVehiclePurchase(options)
  options = options or {}
  local cheats = career_modules_cheats and career_modules_cheats.isCheatsMode and career_modules_cheats.isCheatsMode()
  local prices = state.purchaseData.prices or {}
  local price = (tonumber(prices.finalPrice) or 0) - (tonumber(prices.delivery) or 0)
  if options.makeDelivery then
    local quote = M.getDeliveryQuote(options.targetGarageId)
    if not quote or quote.disabled then
      return false, "delivery"
    end
    price = price + (tonumber(quote.finalPrice) or 0)
  end
  if options.licensePlateText then
    price = price + (tonumber(prices.customLicensePlate) or 0)
  end
  if not cheats and (tonumber(career_modules_playerAttributes.getAttributeValue("money")) or 0) < price then
    return false, "funds"
  end
  local garageAvailability = career_modules_garageManager and career_modules_garageManager.getGarageAvailabilityReason and
                               career_modules_garageManager.getGarageAvailabilityReason() or "ok"
  if garageAvailability == "none" then
    return false, "garage"
  end
  if not M.hasInventorySlotForPurchase() then
    return false, "slot"
  end
  return true
end

U.payForVehicle = function()
  if state.rtBizId then
    return
  end
  local label = string.format("Bought a vehicle: %s", state.purchaseData.vehicleInfo.niceName)
  if state.purchaseData.tradeInVehicleInfo then
    label = label .. string.format(" and traded in vehicle id %d: %s", state.purchaseData.tradeInVehicleInfo.id,
      state.purchaseData.tradeInVehicleInfo.niceName)
  end
  career_modules_playerAttributes.addAttributes({
    money = -state.purchaseData.prices.finalPrice
  }, {
    tags = {"vehicleBought", "buying"},
    label = label
  })
  if career_modules_carmeets and career_modules_carmeets.addTransactionReputation then
    local vehicleInfo = state.purchaseData.vehicleInfo or {}
    local marketValue = vehicleInfo.marketValue or vehicleInfo.Value or state.purchaseData.prices.finalPrice
    career_modules_carmeets.addTransactionReputation("buy", state.purchaseData.prices.finalPrice, marketValue)
  end
  if state.purchaseData.vehicleInfo and state.purchaseData.vehicleInfo.source == "carMeet" and career_modules_carmeets and career_modules_carmeets.onCarMeetVehiclePurchased then
    career_modules_carmeets.onCarMeetVehiclePurchased(state.purchaseData.shopId, state.purchaseData.keepCarMeetWorldVehicle == true)
  end
  Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')
  state.vehicleWatchlist[state.purchaseData.shopId] = nil
end

U.buyVehicleAndSendToGarage = function(options)
  if state.rtBizId then
    return false
  end
  local targetGarageId = options and options.targetGarageId
  local targetGarage = targetGarageId and freeroam_facilities.getFacility("garage", targetGarageId) or nil
  if not targetGarage or not career_modules_garageManager.isPurchasedGarage(targetGarageId) then
    return false
  end
  local spaceInfo = career_modules_garageManager.isGarageSpace(targetGarageId)
  if not spaceInfo or not spaceInfo[1] then
    return false
  end
  local quote = M.getDeliveryQuote(targetGarageId)
  if not quote or quote.disabled then
    return false
  end
  M.applyDeliveryCharge(quote)
  local canAfford = career_modules_cheats and career_modules_cheats.isCheatsMode() or
    career_modules_playerAttributes.getAttributeValue("money") >= state.purchaseData.prices.finalPrice
  if not canAfford or not career_modules_inventory.hasFreeSlot() then
    return false
  end
  U.payForVehicle()
  state.spawnFollowUpActions = {
    delayAccess = quote.etaSeconds,
    targetGarageId = targetGarageId,
    licensePlateText = options.licensePlateText,
    dealershipId = options.dealershipId,
    policyId = options.policyId
  }
  U.spawnVehicle(state.purchaseData.vehicleInfo)
  state.deleteAddedVehicle = true
  return true
end

U.buyVehicleAndSpawnInParkingSpot = function(options)
  if state.rtBizId then
    return false
  end
  local canAfford = career_modules_cheats and career_modules_cheats.isCheatsMode() or career_modules_playerAttributes.getAttributeValue("money") >= state.purchaseData.prices.finalPrice
  if not canAfford or not career_modules_inventory.hasFreeSlot() then
    return false
  end
  U.payForVehicle()

  local dealershipId = options.dealershipId or (state.purchaseData.vehicleInfo and state.purchaseData.vehicleInfo.sellerId)
  local dealership = U.getDealershipForSellerId(dealershipId)
  local freightPickup = dealership and U.getSellerAccessInfo(dealership).isOnline or false
  local targetGarage =
    career_modules_inventory.getClosestOwnedGarageWithSpace() or career_modules_inventory.getClosestGarage()

  state.spawnFollowUpActions = {
    targetGarageId = targetGarage and targetGarage.id or nil,
    licensePlateText = options.licensePlateText,
    dealershipId = dealershipId,
    freightPickup = freightPickup,
    policyId = options.policyId
  }
  -- "private" is a seller id, not a facility, so it must not be used as a dealership to move to
  local sellerId = state.purchaseData.vehicleInfo.sellerId
  local moveToDealership = (sellerId ~= "private" and sellerId ~= "carMeet") and dealershipId or nil
  local newVehObj = U.spawnVehicle(state.purchaseData.vehicleInfo, moveToDealership, freightPickup)
  if gameplay_walk.isWalking() then
    gameplay_walk.setRot(newVehObj:getPosition() - getPlayerVehicle(0):getPosition())
  end
  return true
end

-- TODO At this point, the part conditions of the previous vehicle should have already been saved. for example when entering the garage
U.openShop = function(seller, _originComputerId, screenTag)
  if seller and U.isPoliceDealershipLocked(seller) then
    ui_message(U.getPoliceDealershipLockLabel(), 8, "Police", "info")
    return
  end

  if seller then U.discoverDealer(seller) end
  state.currentSeller = seller
  state.originComputerId = _originComputerId

  if not career_modules_inspectVehicle.getSpawnedVehicleInfo() then
    U.updateVehicleList()
  end

  local sellerInfos = {}
  for id, vehicleInfo in ipairs(state.vehiclesInShop) do
    if vehicleInfo.pos then
      if vehicleInfo.sellerId ~= "private" then
        local sellerInfo = sellerInfos[vehicleInfo.sellerId]
        if sellerInfo then
          vehicleInfo.distance = sellerInfo.distance
          vehicleInfo.quickTravelPrice = sellerInfo.quicktravelPrice
        else
          local quicktravelPrice, distance = career_modules_quickTravel.getPriceForQuickTravel(vehicleInfo.pos)
          sellerInfos[vehicleInfo.sellerId] = {
            distance = distance,
            quicktravelPrice = quicktravelPrice
          }
          vehicleInfo.distance = distance
          vehicleInfo.quickTravelPrice = quicktravelPrice
        end
      else
        local quicktravelPrice, distance = career_modules_quickTravel.getPriceForQuickTravel(vehicleInfo.pos)
        vehicleInfo.distance = distance
        vehicleInfo.quickTravelPrice = quicktravelPrice
      end
    else
      vehicleInfo.distance = 0
    end
  end

  local computer
  if state.currentSeller then
    local dealership = freeroam_facilities.getFacility("dealership", state.currentSeller)
    local tetherPos
    if dealership then
      tetherPos = freeroam_facilities.getAverageDoorPositionForFacility(dealership)
    else
      for _, vehicleInfo in ipairs(state.vehiclesInShop) do
        if vehicleInfo.sellerId == state.currentSeller and vehicleInfo.pos then
          tetherPos = vehicleInfo.pos
          break
        end
      end
    end
    if tetherPos then
      state.tether = career_modules_tether.startSphereTether(tetherPos, C.tetherRange, M.endShopping)
    end
  elseif state.originComputerId then
    computer = freeroam_facilities.getFacility("computer", state.originComputerId)
    state.tether = career_modules_tether.startDoorTether(computer.doors[1], nil, M.endShopping)
  end

  state.shoppingScreenTag = screenTag
  state.buyingAvailable = (not computer or computer.functions.vehicleShop) and true or false
  state.marketplaceAvailable = (career_career.hasBoughtStarterVehicle() and not state.currentSeller) and true or false
  state.selectedSellerId = state.currentSeller

  if state.currentSeller then
    extensions.ui_router.navigate("career.computer.vehicleShopping.vehicles")
  else
    extensions.ui_router.navigate("career.computer.vehicleShopping")
  end
  extensions.hook("onVehicleShoppingMenuOpened", {
    seller = state.currentSeller
  })
end

U.navigateToDealership = function(dealershipId)
  if U.isPoliceDealershipLocked(dealershipId) then
    ui_message(U.getPoliceDealershipLockLabel(), 8, "Police", "info")
    return
  end
  if U.isOnlineSellerId(dealershipId) then
    return
  end

  local dealership = freeroam_facilities.getDealership(dealershipId)
  if not dealership then
    return
  end
  local pos = freeroam_facilities.getAverageDoorPositionForFacility(dealership)
  if not pos then
    return
  end
  U.navigateToPos(pos)
end

U.taxiToDealership = function(dealershipId)
  if U.isPoliceDealershipLocked(dealershipId) then
    ui_message(U.getPoliceDealershipLockLabel(), 8, "Police", "info")
    return
  end
  if U.isOnlineSellerId(dealershipId) then
    return
  end

  local dealership = freeroam_facilities.getDealership(dealershipId)
  if not dealership then
    return
  end
  local pos = freeroam_facilities.getAverageDoorPositionForFacility(dealership)
  if not pos then
    return
  end
  local lookAt = pos
  local spotRot
  local parkingSpots = freeroam_facilities.getParkingSpotsForFacility(dealership)
  if parkingSpots and parkingSpots[1] then
    local center, count = vec3(0, 0, 0), 0
    for _, spot in ipairs(parkingSpots) do
      if spot.pos then
        center = center + spot.pos
        count = count + 1
      end
    end
    if count > 0 then
      lookAt = center / count
    end
    spotRot = parkingSpots[1].rot
  end
  career_modules_quickTravel.quickTravelToPos(pos, true,
    string.format("Took a taxi to %s", dealership.name or "dealership"), spotRot, lookAt)
  -- Racing team computer shop: player is now at the lot; scope shopping to this seller so
  -- inspect/instant purchase matches in-person flow (Vue refreshes shopping data after taxi).
  if state.rtBizId then
    state.currentSeller = dealershipId
    state.originComputerId = nil
  end
end

U.getTaxiPriceToDealership = function(dealershipId)
  if U.isPoliceDealershipLocked(dealershipId) then
    return 0
  end
  if U.isOnlineSellerId(dealershipId) then
    return 0
  end

  local dealership = freeroam_facilities.getDealership(dealershipId)
  if not dealership then
    log("W", "Career", "getTaxiPriceToDealership: Dealership not found: " .. tostring(dealershipId))
    return 0
  end
  local pos = freeroam_facilities.getAverageDoorPositionForFacility(dealership)
  if not pos then
    log("W", "Career", "getTaxiPriceToDealership: No position found for dealership: " .. tostring(dealershipId))
    return 0
  end

  local playerPos = getPlayerVehicle(0):getPosition()
  local distance = (pos - playerPos):length()

  local price, calcDistance = career_modules_quickTravel.getPriceForQuickTravel(pos)

  if (not price or price <= 0) and (calcDistance and calcDistance > 0) then
    local basePrice = 5
    local pricePerM = 0.08
    local est = basePrice + round(calcDistance * pricePerM * 100) / 100
    log("W", "Career",
      string.format("getTaxiPriceToDealership: fallback price used=%.2f (distance=%.2f)", est, calcDistance))
    price = est
  end

  return price * 5 or 0
end

U.endShopping = function()
  career_career.closeAllMenus()
  extensions.hook("onVehicleShoppingMenuClosed", {})
end

U.cancelShopping = function()
  if state.originComputerId then
    local computer = freeroam_facilities.getFacility("computer", state.originComputerId)
    career_modules_computer.openMenu(computer)
  else
    career_career.closeAllMenus()
  end
end

U.requestExit = function()
  if state.rtBizId then
    local businessId = state.rtBizId
    state.rtBizId = nil
    state.currentSeller = nil
    state.originComputerId = nil
    state.selectedSellerId = nil
    return extensions.ui_router.navigate("business-computer", {
      businessType = state.fleetBusinessType,
      businessId = tostring(businessId)
    })
  end
  return U.cancelShopping()
end

U.onRouteMount = function(context, toRoute, fromRoute, data)
  U.sendShoppingDataToUI()
end

U.selectSeller = function(sellerId)
  if type(sellerId) ~= "string" or sellerId == "" then return end
  if U.isPoliceDealershipLocked(sellerId) then
    ui_message(U.getPoliceDealershipLockLabel(), 8, "Police", "info")
    return
  end
  local dealership = U.getDealershipForSellerId(sellerId)
  if dealership and not U.isDealerDiscovered(dealership) then return end
  state.selectedSellerId = sellerId
  extensions.hook("onVehicleShoppingSelectedSellerIdChanged", sellerId)
  U.sendShoppingDataToUI()
  return extensions.ui_router.navigate("career.computer.vehicleShopping.vehicles")
end

U.clearSelectedSeller = function()
  state.selectedSellerId = nil
  extensions.hook("onVehicleShoppingSelectedSellerIdChanged", nil)
  U.sendShoppingDataToUI()
end

U.requestVehicleListExit = function()
  if state.currentSeller then
    return U.cancelShopping()
  end
  U.clearSelectedSeller()
  return extensions.ui_router.navigate("career.computer.vehicleShopping")
end

U.getSelectedSellerBreadcrumbTitle = function()
  if not state.selectedSellerId then return nil end
  if state.selectedSellerId == "private" then
    return _tr("ui.career.vehicleShopping.privateSellers")
  end
  local dealership = freeroam_facilities.getDealership(state.selectedSellerId)
  if dealership and dealership.name then
    return _tr(dealership.name)
  end
  return nil
end

U.onShoppingMenuClosed = function()
  if state.tether then
    state.tether.remove = true
    state.tether = nil
  end
  state.inspectingVehicleShopId = nil
  state.purchaseMenuOpen = false
end

U.getVehiclesInShop = function()
  return state.vehiclesInShop
end

U.removeUnusedPlayerVehicles = function()
  for inventoryId, vehId in pairs(career_modules_inventory.getMapInventoryIdToVehId()) do
    if inventoryId ~= career_modules_inventory.getCurrentVehicle() then
      career_modules_inventory.removeVehicleObject(inventoryId)
    end
  end
end

U.buySpawnedVehicle = function(buyVehicleOptions)
  if state.rtBizId then
    return false
  end
  buyVehicleOptions = buyVehicleOptions or {}
  local deliveryQuote
  if buyVehicleOptions.makeDelivery then
    deliveryQuote = M.getDeliveryQuote(buyVehicleOptions.targetGarageId)
    if not deliveryQuote or deliveryQuote.disabled then
      return false
    end
    M.applyDeliveryCharge(deliveryQuote)
  end
  local canAfford = career_modules_cheats and career_modules_cheats.isCheatsMode() or career_modules_playerAttributes.getAttributeValue("money") >= state.purchaseData.prices.finalPrice
  local garageAvailability = career_modules_garageManager and career_modules_garageManager.getGarageAvailabilityReason and career_modules_garageManager.getGarageAvailabilityReason() or "ok"
  if not canAfford then
    return false
  end
  if garageAvailability == "none" then
    ui_message("Buy or rent a garage before purchasing a vehicle.", nil, "vehicleShopping")
    return false
  end
  if not career_modules_inventory.hasFreeSlot() then
    return false
  end

  local vehObj = getObjectByID(state.purchaseData.vehId)
  if not vehObj then
    return false
  end
  U.payForVehicle()
  local newInventoryId = career_modules_inventory.addVehicle(vehObj:getID(), nil, {
    year = state.purchaseData.vehicleInfo and state.purchaseData.vehicleInfo.year,
    finalPrice = state.purchaseData.prices.finalPrice
  })
  local inventoryVehicle = career_modules_inventory.getVehicles and
                             career_modules_inventory.getVehicles()[newInventoryId] or nil
  if inventoryVehicle and vehicleMaintenance and vehicleMaintenance.applyInspectionSnapshotToVehicleData then
    vehicleMaintenance.applyInspectionSnapshotToVehicleData(state.purchaseData.vehicleInfo, inventoryVehicle)
  end
  if buyVehicleOptions.licensePlateText then
    career_modules_inventory.setLicensePlateText(newInventoryId, buyVehicleOptions.licensePlateText)
  end
  if buyVehicleOptions.dealershipId == "policeDealership" then
    career_modules_inventory.setVehicleRole(newInventoryId, "police")
  end
  local stored
  if deliveryQuote then
    stored = career_modules_inventory.moveVehicleToGarage(newInventoryId, buyVehicleOptions.targetGarageId)
    if stored then
      career_modules_inventory.delayVehicleAccess(newInventoryId, deliveryQuote.etaSeconds, "bought")
    end
  else
    stored = career_modules_inventory.storeVehicle(newInventoryId)
  end
  if not stored then
    return false
  end
  state.removeNonUsedPlayerVehicles = true
  if not deliveryQuote and be:getPlayerVehicleID(0) == vehObj:getID() then
    career_modules_inventory.enterVehicle(newInventoryId)
  end
  return true
end

U.getDeliveryOrigin = function(dealership)
  if not dealership then return nil, "Dealership is unavailable." end
  local accessInfo = U.getSellerAccessInfo(dealership)
  if accessInfo.isOnline then
    local freightFacility = dealership
    if type(dealership.freightPickupSpotNames) == "table" then
      freightFacility = deepcopy(dealership)
      freightFacility.parkingSpotNames = dealership.freightPickupSpotNames
    end
    local parkingSpots = freeroam_facilities.getParkingSpotsForFacility(freightFacility) or {}
    if not parkingSpots[1] then
      return nil, "This map has no freight pickup point configured for online vehicle orders."
    end
    return parkingSpots[1].pos
  end
  local pos = freeroam_facilities.getAverageDoorPositionForFacility(dealership)
  if not pos then return nil, "The dealership has no delivery origin configured." end
  return pos
end

U.getDeliveryGarages = function(dealership)
  local result = {}
  if not dealership or not U.getSellerAccessInfo(dealership).garageDeliveryAllowed then return result end
  local capacityData = career_modules_garageManager.getGarageCapacityData() or {}
  for garageId, info in pairs(capacityData) do
    if (tonumber(info.capacity) or 0) > (tonumber(info.count) or 0) then
      local garage = freeroam_facilities.getFacility("garage", garageId)
      if garage then
        table.insert(result, {
          id = tostring(garageId),
          name = garage.name or info.name or tostring(garageId),
          freeSlots = (tonumber(info.capacity) or 0) - (tonumber(info.count) or 0)
        })
      end
    end
  end
  table.sort(result, function(a, b) return tostring(a.name) < tostring(b.name) end)
  return result
end

U.getDeliveryQuote = function(garageId)
  if not state.purchaseData or not state.purchaseData.vehicleInfo then
    return {disabled = true, reason = "No active vehicle purchase."}
  end
  local vehicleInfo = state.purchaseData.vehicleInfo
  local dealership = U.getDealershipForSellerId(vehicleInfo.sellerId)
  local accessInfo = U.getSellerAccessInfo(dealership or vehicleInfo)
  if not accessInfo.garageDeliveryAllowed then
    return {disabled = true, reason = "Garage delivery unlocks at dealer reputation level 2."}
  end
  if not garageId or not career_modules_garageManager.isPurchasedGarage(garageId) then
    return {disabled = true, reason = "Choose an owned garage."}
  end
  local spaceInfo = career_modules_garageManager.isGarageSpace(garageId)
  if not spaceInfo or not spaceInfo[1] then
    return {disabled = true, reason = "The selected garage has no free space."}
  end
  local garage = freeroam_facilities.getFacility("garage", garageId)
  local garagePos = garage and freeroam_facilities.getGaragePosRot(garage) or nil
  local origin, reason = U.getDeliveryOrigin(dealership)
  if not origin or not garagePos then
    return {disabled = true, reason = reason or "Delivery route is unavailable."}
  end
  local routeQuote = career_modules_quickTravel.getRoadRouteQuote(origin, garagePos)
  local fullPrice = routeQuote.price
  local roadDistance = routeQuote.roadDistance
  local discount = accessInfo.deliveryDiscount
  local finalPrice = math.floor((tonumber(fullPrice) or 0) * (1 - discount) * 100 + 0.5) / 100
  return {
    disabled = false,
    garageId = tostring(garageId),
    garageName = garage.name or tostring(garageId),
    roadDistance = roadDistance or 0,
    fullPrice = fullPrice or 0,
    discount = discount,
    finalPrice = finalPrice,
    etaSeconds = U.getDeliveryDelay(roadDistance)
  }
end

U.sendPurchaseDataToUi = function()
  local rtBid = state.purchaseData.racingTeamBusinessId or state.rtBizId
  local vehicleShopInfo = deepcopy(U.getVehicleInfoByShopId(state.purchaseData.shopId))
  if not vehicleShopInfo then
    log("E", "Career", "sendPurchaseDataToUi: Vehicle not found for shopId: " .. tostring(state.purchaseData.shopId))
    return
  end
  vehicleShopInfo.shopId = state.purchaseData.shopId
  vehicleShopInfo.niceName = vehicleShopInfo.Brand .. " " .. vehicleShopInfo.Name
  vehicleShopInfo.deliveryDelay = U.getDeliveryDelay(vehicleShopInfo.distance)
  U.applyPurchaseAdjustedMarketValue(vehicleShopInfo)
  vehicleShopInfo.Value = vehicleShopInfo.valueAdjusted or vehicleShopInfo.Value
  U.coerceVehiclePricingFields(vehicleShopInfo)
  state.purchaseData.vehicleInfo = vehicleShopInfo

  local tradeInValue = state.purchaseData.tradeInVehicleInfo and state.purchaseData.tradeInVehicleInfo.Value or 0
  local taxes, finalPrice = M.computePurchaseTaxAndFinalPrice(vehicleShopInfo, tradeInValue)
  state.purchaseData.prices = {fees = vehicleShopInfo.fees, taxes = taxes, finalPrice = finalPrice, customLicensePlate = C.customLicensePlatePrice}
  local spawnedVehicleInfo = career_modules_inspectVehicle.getSpawnedVehicleInfo()
  state.purchaseData.vehId = spawnedVehicleInfo and spawnedVehicleInfo.vehId

  -- Insurance options from v38
  if vehicleShopInfo.source == "carMeet" then
    state.purchaseData.insuranceId = -1
  elseif not state.purchaseData.insuranceId then
    if vehicleShopInfo.insuranceClass and vehicleShopInfo.insuranceClass.id then
      if career_modules_insurance_insurance and career_modules_insurance_insurance.getDefaultInsuranceForClassId then
        local defaultInsurance = career_modules_insurance_insurance.getDefaultInsuranceForClassId(vehicleShopInfo.insuranceClass.id)
        if defaultInsurance then
          state.purchaseData.insuranceId = defaultInsurance.id
        end
      end
    end
  end

  state.purchaseData.insuranceOptions = {
    insuranceId = state.purchaseData.insuranceId,
    shopId = state.purchaseData.shopId,
  }

  if state.purchaseData.insuranceId and state.purchaseData.insuranceId >= 0 then
    if career_modules_insurance_insurance and career_modules_insurance_insurance.getInsuranceDataById then
      local insuranceInfo = career_modules_insurance_insurance.getInsuranceDataById(state.purchaseData.insuranceId)
      if insuranceInfo then
        state.purchaseData.insuranceOptions.name = insuranceInfo.name
        state.purchaseData.insuranceOptions.spendingReason = string.format("Insurance Policy: \"%s\"", insuranceInfo.name)
        if career_modules_insurance_insurance.calculateAddVehiclePrice then
          state.purchaseData.insuranceOptions.priceMoney = career_modules_insurance_insurance.calculateAddVehiclePrice(state.purchaseData.insuranceId, state.purchaseData.vehicleInfo.Value)
        end
      end
    end
  end

  local playerMoney = career_modules_playerAttributes.getAttributeValue("money")
  local racingTeamBusinessMoney = nil
  local invFree = career_modules_inventory.hasFreeSlot()
  if rtBid and career_modules_bank and career_modules_bank.getBusinessAccount then
    local purchaseFleetType = state.purchaseData.fleetBusinessType or state.fleetBusinessType
    local acct = career_modules_bank.getBusinessAccount(purchaseFleetType, rtBid)
    racingTeamBusinessMoney = tonumber(acct and acct.balance) or tonumber(acct and acct.balanceMoney) or tonumber(acct and acct.money) or 0
    local inv = career_modules_business_businessInventory
    local n = 0
    if inv and inv.getBusinessVehicles then
      n = #(inv.getBusinessVehicles(rtBid) or {})
    end
    invFree = n < U.rtFleetCap(rtBid)
  end

  local data = {
    vehicleInfo = state.purchaseData.vehicleInfo,
    playerMoney = playerMoney,
    racingTeamBusinessMoney = racingTeamBusinessMoney,
    racingTeamFleetPurchase = rtBid ~= nil,
    inventoryHasFreeSlot = invFree,
    garageAvailability = career_modules_garageManager and career_modules_garageManager.getGarageAvailabilityReason and career_modules_garageManager.getGarageAvailabilityReason() or "ok",
    purchaseType = state.purchaseData.purchaseType,
    forceTradeIn = (not rtBid) and (not career_career.hasBoughtStarterVehicle()) or nil,
    tradeInVehicleInfo = state.purchaseData.tradeInVehicleInfo,
    prices = state.purchaseData.prices,
    dealershipId = vehicleShopInfo.sellerId,
    alreadyDidTestDrive = career_modules_inspectVehicle.getDidTestDrive() or false,
    vehId = state.purchaseData.vehId,
    cheatsMode = career_modules_cheats and career_modules_cheats.isCheatsMode() or false,
    insuranceOptions = state.purchaseData.insuranceOptions
  }
  local dealership = U.getDealershipForSellerId(vehicleShopInfo.sellerId)
  local accessInfo = U.getSellerAccessInfo(dealership or vehicleShopInfo)
  local _, freightReason = U.getDeliveryOrigin(dealership)
  data.salesChannel = accessInfo.salesChannel
  data.remotePurchaseAllowed = accessInfo.remotePurchaseAllowed
  data.garageDeliveryAllowed = accessInfo.garageDeliveryAllowed
  data.deliveryDiscount = accessInfo.deliveryDiscount
  data.deliveryGarages = U.getDeliveryGarages(dealership)
  data.freightAvailable = not accessInfo.isOnline or freightReason == nil
  data.freightUnavailableReason = accessInfo.isOnline and freightReason or nil

  if not data.vehicleInfo.requiredInsurance then
    data.ownsRequiredInsurance = false
  else
    if legacyInsurance and legacyInsurance.getPlayerPolicyData then
      local playerInsuranceData = legacyInsurance.getPlayerPolicyData()[data.vehicleInfo.requiredInsurance.id]
      if playerInsuranceData then
        data.ownsRequiredInsurance = playerInsuranceData.owned
      else
        data.ownsRequiredInsurance = false
      end
    else
      data.ownsRequiredInsurance = false
    end
  end

  local atDealership = (state.purchaseData.purchaseType == "instant" and state.currentSeller) or
                         (state.purchaseData.purchaseType == "inspect" and vehicleShopInfo.sellerId ~= "private")

  if atDealership and not rtBid and vehicleShopInfo.source ~= "carMeet" then
    data.tradeInEnabled = true
  end

  if (atDealership or accessInfo.isOnline or accessInfo.remotePurchaseAllowed or vehicleShopInfo.sellerId == "private")
      and vehicleShopInfo.source ~= "carMeet" then
    data.locationSelectionEnabled = true
  end

  if not career_career.hasBoughtStarterVehicle() then
    data.forceNoDelivery = true
  end

  guihooks.trigger("vehiclePurchaseData", data)
end

U.updateInsuranceSelection = function(insuranceId)
  if state.purchaseData then
    state.purchaseData.insuranceId = insuranceId
    U.sendPurchaseDataToUi()
  end
end

U.onClientStartMission = function()
  state.vehiclesInShop = {}
end

U.onAddedVehiclePartsToInventory = function(inventoryId, newParts)
  local vehicle = career_modules_inventory.getVehicles()[inventoryId]

  -- The inventory record owns the year. Shared dealer UI state may belong to
  -- another purchase (or be absent entirely for auctions and rewards).
  vehicle.year = tonumber(vehicle.year) or tonumber(os.date("%Y"))

  vehicle.originalParts = {}
  local allSlotsInVehicle = {
    main = true
  }

  for partName, part in pairs(newParts) do
    part.year = vehicle.year
    vehicle.originalParts[part.containingSlot] = {
      name = part.name,
      value = part.value
    }

    if part.description.slotInfoUi then
      for slot, _ in pairs(part.description.slotInfoUi) do
        allSlotsInVehicle[slot] = true
      end
    end
  end

  vehicle.changedSlots = {}

  if state.deleteAddedVehicle then
    career_modules_inventory.removeVehicleObject(inventoryId)
    state.deleteAddedVehicle = nil
  end

  U.endShopping()

  extensions.hook("onVehicleAddedToInventory", {
    inventoryId = inventoryId,
    vehicleInfo = state.purchaseData and state.purchaseData.vehicleInfo,
    selectedPolicyId = state.purchaseData and state.purchaseData.selectedPolicyId,
    purchaseData = state.purchaseData
  })

  if career_career.isAutosaveEnabled() then
    career_saveSystem.saveCurrent(nil, {deferUntilStopped = true})
  end
end

U.onEnterVehicleFinished = function(inventoryId)
  if state.removeNonUsedPlayerVehicles then
    state.removeNonUsedPlayerVehicles = nil
  end
  M.completeFreightPickup(inventoryId)
end

U.startInspectionWorkitem = function(job, vehicleInfo, teleportToVehicle)
  if U.isOnlineSellerId(vehicleInfo and vehicleInfo.sellerId) then
    return
  end
  ui_fadeScreen.start(0.5)
  job.sleep(1.0)
  extensions.ui_router.navigate("play")
  career_modules_inspectVehicle.startInspection(vehicleInfo, teleportToVehicle)
  job.sleep(0.5)
  ui_fadeScreen.stop(0.5)
  job.sleep(1.0)

  state.inspectingVehicleShopId = vehicleInfo.shopId

  extensions.hook("onVehicleShoppingVehicleShown", {
    vehicleInfo = vehicleInfo
  })
end

-- Navigation functions
U.navigateToPos = function(pos, shopId)
  if shopId then
    local vehicleInfo = U.getVehicleInfoByShopId(shopId)
    if not vehicleInfo then
      log("E", "Career", "Failed to find vehicle for inspection with shopId: " .. tostring(shopId))
      return
    end
    if U.isOnlineSellerId(vehicleInfo.sellerId) then
      return
    end
    if not pos then return end
    core_groundMarkers.setPath(vec3(pos.x, pos.y, pos.z))
    core_jobsystem.create(U.startInspectionWorkitem, nil, vehicleInfo, false)
    return
  end
  if not pos then return end
  core_groundMarkers.setPath(vec3(pos.x, pos.y, pos.z))
  extensions.ui_router.navigate("play")
end

U.showVehicle = function(shopId)
  local vehicleInfo = U.getVehicleInfoByShopId(shopId)
  if not vehicleInfo then
    log("E", "Career", "Failed to find vehicle for inspection with shopId: " .. tostring(shopId))
    return
  end
  if U.isOnlineSellerId(vehicleInfo.sellerId) then
    return
  end
  core_jobsystem.create(U.startInspectionWorkitem, nil, vehicleInfo, true)
end

U.quickTravelToVehicle = function(shopId)
  if not shopId then
    log("E", "Career", "quickTravelToVehicle: shopId is nil")
    return
  end
  log("D", "Career", "quickTravelToVehicle called with shopId: " .. tostring(shopId) .. " (type: " .. type(shopId) .. ")")
  local vehicleInfo = U.getVehicleInfoByShopId(shopId)
  if not vehicleInfo then
    log("E", "Career", "Failed to find vehicle for quick travel with shopId: " .. tostring(shopId))
    log("D", "Career", "Vehicles in shop: " .. tableSize(state.vehiclesInShop))
    if tableSize(state.vehiclesInShop) > 0 then
      log("D", "Career", "Sample shopIds in state.vehiclesInShop:")
      for i = 1, math.min(5, #state.vehiclesInShop) do
        log("D", "Career", "  Vehicle " .. i .. ": shopId=" .. tostring(state.vehiclesInShop[i].shopId) .. " (type: " .. type(state.vehiclesInShop[i].shopId) .. ")")
      end
    end
    return
  end
  if U.isOnlineSellerId(vehicleInfo.sellerId) then
    return
  end
  core_jobsystem.create(U.startInspectionWorkitem, nil, vehicleInfo, true)
end

U.openPurchaseMenu = function(purchaseType, shopId, insuranceId, silent)
  log("D", "Career",
    "openPurchaseMenu called with purchaseType: " .. tostring(purchaseType) .. ", shopId: " .. tostring(shopId))

  if not purchaseType then
    log("E", "Career", "openPurchaseMenu: purchaseType is nil")
    return
  end

  if not shopId then
    log("E", "Career", "openPurchaseMenu: shopId is nil")
    return
  end

  local vehicle = U.getVehicleInfoByShopId(shopId)
  if not vehicle then
    log("E", "Career", "Failed to find vehicle for purchase with shopId: " .. tostring(shopId))
    if #state.vehiclesInShop > 0 then
      log("D", "Career", "Available vehicles in shop:")
      for i, v in ipairs(state.vehiclesInShop) do
        log("D", "Career", "  Vehicle " .. i .. ": shopId=" .. tostring(v.shopId) .. ", key=" .. tostring(v.key))
      end
    else
      log("E", "Career", "No vehicles available in shop")
    end
    return
  end
  if purchaseType == "instant" and not state.currentSeller and vehicle.sellerId ~= "private" and vehicle.source ~= "carMeet" then
    local dealership = freeroam_facilities.getDealership(vehicle.sellerId)
    local accessInfo = U.getSellerAccessInfo(dealership)
    if not accessInfo.remotePurchaseAllowed then
      ui_message("Visit this dealership to purchase. Remote checkout unlocks at reputation level 2.",
        6, "In-person purchase required", "info")
      return
    end
    if accessInfo.isOnline then
      local origin, reason = U.getDeliveryOrigin(dealership)
      if not origin then
        ui_message(reason, 8, "Online ordering unavailable", "warning")
        return
      end
    end
  end

  state.vehicleWatchlist[shopId] = "unsold"
  -- Snapshot before switching UI: leaving vehicle shopping can remount the view and clear global state.rtBizId.
  local racingTeamPurchaseBizId = state.rtBizId

  local vehicleShopInfo = deepcopy(vehicle)
  vehicleShopInfo.niceName = vehicleShopInfo.Brand .. " " .. vehicleShopInfo.Name
  U.coerceVehiclePricingFields(vehicleShopInfo)

  local distance = vehicleShopInfo.distance
  if not distance or type(distance) ~= "number" then
    if vehicleShopInfo.pos then
      local qtPrice, dist = career_modules_quickTravel.getPriceForQuickTravel(vehicleShopInfo.pos)
      vehicleShopInfo.quickTravelPrice = vehicleShopInfo.quickTravelPrice or qtPrice
      distance = dist
    else
      distance = 0
    end
    vehicleShopInfo.distance = distance
  end
  vehicleShopInfo.deliveryDelay = U.getDeliveryDelay(distance)

  local taxes, finalPrice = M.computePurchaseTaxAndFinalPrice(vehicleShopInfo, 0)

  state.purchaseData = {
    shopId = shopId,
    purchaseType = purchaseType,
    vehicleInfo = vehicleShopInfo,
    insuranceId = vehicleShopInfo.source == "carMeet" and -1 or insuranceId,
    racingTeamBusinessId = racingTeamPurchaseBizId,
    fleetBusinessType = state.fleetBusinessType,
    prices = {
      fees = vehicleShopInfo.fees,
      taxes = taxes,
      finalPrice = finalPrice,
      customLicensePlate = C.customLicensePlatePrice
    }
  }

  if racingTeamPurchaseBizId then
    state.purchaseData.insuranceId = -1
  end

  state.purchaseMenuOpen = true
  log("D", "Career", "Successfully opened purchase menu for vehicle: " .. tostring(shopId))
  if not silent then
    extensions.ui_router.navigate("career.computer.vehicleShopping.vehicles.vehiclePurchase")
    extensions.hook("onVehicleShoppingPurchaseMenuOpened", {
      purchaseType = purchaseType,
      shopId = shopId
    })
  end
end

U.buyFromPurchaseMenu = function(purchaseType, options)
  options = options or {}

  if not state.purchaseData then
    log("E", "Career", "buyFromPurchaseMenu: state.purchaseData is nil")
    return
  end
  if not state.purchaseData.vehicleInfo then
    log("E", "Career", "buyFromPurchaseMenu: state.purchaseData.vehicleInfo is nil")
    return
  end
  if options.makeDelivery then
    local quote = U.getDeliveryQuote(options.targetGarageId)
    if not quote or quote.disabled then
      ui_message(quote and quote.reason or "Delivery quote is unavailable.", 6, "Delivery unavailable", "warning")
      return
    end
  end
  if not state.purchaseData.prices then
    log("W", "Career", "buyFromPurchaseMenu: state.purchaseData.prices is nil, calculating prices as fallback")
    local vehicleShopInfo = state.purchaseData.vehicleInfo
    U.coerceVehiclePricingFields(vehicleShopInfo)
    local tradeInValue = state.purchaseData.tradeInVehicleInfo and state.purchaseData.tradeInVehicleInfo.Value or 0
    local taxes, finalPrice = M.computePurchaseTaxAndFinalPrice(vehicleShopInfo, tradeInValue)
    state.purchaseData.prices = {
      fees = vehicleShopInfo.fees,
      taxes = taxes,
      finalPrice = finalPrice,
      customLicensePlate = C.customLicensePlatePrice
    }
  end

  local bid = state.purchaseData.racingTeamBusinessId or state.rtBizId
  if bid then
    local inv = career_modules_business_businessInventory
    local cap = U.rtFleetCap(bid)
    local n = 0
    if inv and inv.getBusinessVehicles then
      n = #(inv.getBusinessVehicles(bid) or {})
    end
    if n >= cap then
      return
    end
    local price = tonumber(state.purchaseData.prices.finalPrice) or 0
    if options.licensePlateText then
      price = price + (tonumber(state.purchaseData.prices.customLicensePlate) or 0)
    end
    -- Racing team purchases always debit the business account; cheats mode does not waive this.
    local bank = career_modules_bank
    local purchaseFleetType = state.purchaseData.fleetBusinessType or state.fleetBusinessType
    local acct = bank and bank.getBusinessAccount and bank.getBusinessAccount(purchaseFleetType, bid)
    local accountId = acct and (acct.id or acct.accountId)
    if not bank or not bank.payFromAccount or not accountId then
      return
    end
    local paid = bank.payFromAccount({
      money = { amount = price, canBeNegative = false }
    }, accountId, "Vehicle Purchase", purchaseFleetType .. " fleet vehicle")
    if not paid then
      return
    end
    local orgId = state.purchaseData.vehicleInfo and state.purchaseData.vehicleInfo.associatedOrganization
    if not orgId then
      local dealershipId = options.dealershipId or (state.purchaseData.vehicleInfo and state.purchaseData.vehicleInfo.sellerId)
      if dealershipId and dealershipId ~= "private" then
        local dealership = freeroam_facilities.getDealership(dealershipId)
        orgId = dealership and dealership.associatedOrganization
      end
    end
    if orgId then
      local org = freeroam_organizations.getOrganization(orgId)
      if org then
        career_modules_playerAttributes.addAttributes({
          [orgId .. "Reputation"] = C.dealershipPurchaseReputationGain
        }, {
          tags = {"buying"},
          label = string.format("Bought vehicle from %s", orgId)
        })
      end
    end
    local vehInfo = state.purchaseData.vehicleInfo
    local spawnedVehId = tonumber(state.purchaseData.vehId) or state.purchaseData.vehId
    -- Match the same in-person dealership detection used by purchase UI wiring:
    -- - instant purchase while currently at a seller
    -- - inspect purchase for non-private seller vehicles
    local effectivePurchaseType = purchaseType or state.purchaseData.purchaseType
    local isInPersonSellerFlow =
      (effectivePurchaseType == "inspect") or
      ((effectivePurchaseType == "instant" and state.currentSeller ~= nil) and vehInfo and vehInfo.sellerId ~= "private")
    if isInPersonSellerFlow then
      local spawnedVehObj = spawnedVehId and be and be:getObjectByID(spawnedVehId) or nil
      if not spawnedVehObj then
        local dealershipId = options.dealershipId or (vehInfo and vehInfo.sellerId)
        local respawnedVehObj = U.rtFleetSpawnVehicle(vehInfo, dealershipId)
        spawnedVehId = respawnedVehObj and respawnedVehObj:getID() or nil
      end
      if not spawnedVehId then
        local delay = U.getRacingTeamDeliveryDelaySeconds(bid, vehInfo)
        U.addPendingRacingTeamFleetPurchase(bid, {
          kind = "timer",
          dueEpoch = os.time() + delay,
          model_key = vehInfo.model_key,
          key = vehInfo.key,
          mileage = vehInfo.Mileage or 0,
          purchasePrice = price,
          purchasedEpoch = os.time()
        })
      else
      U.addPendingRacingTeamFleetPurchase(bid, {
        kind = "drive",
        spawnedVehId = spawnedVehId,
        model_key = vehInfo.model_key,
        key = vehInfo.key,
        mileage = vehInfo.Mileage or 0,
        purchasePrice = price,
        purchasedEpoch = os.time()
      })
      -- Clear inspect/test-drive state without deleting the purchased world vehicle.
      if career_modules_inspectVehicle.leaveSaleCallback then
        career_modules_inspectVehicle.leaveSaleCallback(
          "dontDespawn",
          false,
          false,
          "You purchased the vehicle."
        )
      end
      end
    else
      local delay = U.getRacingTeamDeliveryDelaySeconds(bid, vehInfo)
      U.addPendingRacingTeamFleetPurchase(bid, {
        kind = "timer",
        dueEpoch = os.time() + delay,
        model_key = vehInfo.model_key,
        key = vehInfo.key,
        mileage = vehInfo.Mileage or 0,
        purchasePrice = price,
        purchasedEpoch = os.time()
      })
      -- Remote/instant flow has no world car to drive; keep inspect cleanup behavior if present.
      if effectivePurchaseType ~= "inspect" and career_modules_inspectVehicle.leaveSaleCallback then
        career_modules_inspectVehicle.leaveSaleCallback(
          "despawn",
          false,
          false,
          "You purchased the vehicle."
        )
      end
    end
    Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')
    state.vehicleWatchlist[state.purchaseData.shopId] = nil
    local targetShopId = tonumber(state.purchaseData.shopId) or state.purchaseData.shopId
    for i, v in ipairs(state.vehiclesInShop) do
      local vid = tonumber(v.shopId) or v.shopId
      if vid == targetShopId then
        v.markedSold = true
        v.soldViewCounter = 1
        state.pendingSoldShopIds[state.purchaseData.shopId] = true
        table.remove(state.vehiclesInShop, i)
        break
      end
    end
    state.purchaseMenuOpen = false
    state.inspectingVehicleShopId = nil
    if state.uiOpen then
      U.commitDelta(U.buildSnapshot())
      guihooks.trigger("vehicleShopDelta", state.lastDelta)
    end
    career_career.closeAllMenus()
    return
  end

  local canPurchase, blockReason = M.canCompletePersonalVehiclePurchase(options)
  if not canPurchase then
    if blockReason == "garage" then
      ui_message("Buy or rent a garage before purchasing a vehicle.", nil, "vehicleShopping")
    elseif blockReason == "slot" then
      ui_message("No free garage space for another vehicle.", nil, "vehicleShopping")
    end
    return
  end

  -- Only remove the trade-in after purchase preconditions pass.
  if state.purchaseData.tradeInVehicleInfo then
    career_modules_inventory.removeVehicle(state.purchaseData.tradeInVehicleInfo.id)
  end

  local selectedPolicyId = options.policyId or 0
  if options.purchaseInsurance and selectedPolicyId > 0 then
    if legacyInsurance and legacyInsurance.purchasePolicy then
      legacyInsurance.purchasePolicy(selectedPolicyId)
    end
  end

  state.purchaseData.selectedPolicyId = selectedPolicyId
  local buyVehicleOptions = {
    makeDelivery = options.makeDelivery == true,
    targetGarageId = options.targetGarageId,
    licensePlateText = options.licensePlateText,
    dealershipId = options.dealershipId or (state.purchaseData.vehicleInfo and state.purchaseData.vehicleInfo.sellerId),
    policyId = selectedPolicyId
  }
  local purchaseSucceeded = false
  if purchaseType == "inspect" then
    if options.makeDelivery then
      state.deleteAddedVehicle = true
    end
    purchaseSucceeded = career_modules_inspectVehicle.buySpawnedVehicle(buyVehicleOptions) == true
  elseif purchaseType == "instant" then
    career_modules_inspectVehicle.showVehicle(nil)
    if options.makeDelivery then
      purchaseSucceeded = U.buyVehicleAndSendToGarage(buyVehicleOptions) == true
    else
      purchaseSucceeded = U.buyVehicleAndSpawnInParkingSpot(buyVehicleOptions) == true
    end
  end

  if not purchaseSucceeded then
    log("E", "Career", "buyFromPurchaseMenu: purchase failed after trade-in was removed")
    return
  end

  local orgId = state.purchaseData.vehicleInfo and state.purchaseData.vehicleInfo.associatedOrganization
  if not orgId then
    local dealershipId = options.dealershipId or (state.purchaseData.vehicleInfo and state.purchaseData.vehicleInfo.sellerId)
    if dealershipId and dealershipId ~= "private" then
      local dealership = freeroam_facilities.getDealership(dealershipId)
      if dealership and dealership.associatedOrganization then
        orgId = dealership.associatedOrganization
      end
    end
  end

  if orgId then
    local org = freeroam_organizations.getOrganization(orgId)
    if org then
      career_modules_playerAttributes.addAttributes({
        [orgId .. "Reputation"] = C.dealershipPurchaseReputationGain
      }, {
        tags = {"buying"},
        label = string.format("Bought vehicle from %s", orgId)
      })
    end
  end

  if options.licensePlateText then
    career_modules_playerAttributes.addAttributes({
      money = -state.purchaseData.prices.customLicensePlate
    }, {
      tags = {"buying"},
      label = string.format("Bought custom license plate for new vehicle")
    })
  end

  -- Remove the vehicle from the shop
  local targetShopId = tonumber(state.purchaseData.shopId) or state.purchaseData.shopId
  for i, vehInfo in ipairs(state.vehiclesInShop) do
    local vehShopId = tonumber(vehInfo.shopId) or vehInfo.shopId
    if vehShopId == targetShopId then
      vehInfo.markedSold = true
      vehInfo.soldViewCounter = 1
      state.pendingSoldShopIds[state.purchaseData.shopId] = true
      table.remove(state.vehiclesInShop, i)
      break
    end
  end

  state.purchaseMenuOpen = false
  state.inspectingVehicleShopId = nil
  state.rtPendingFleetPurchases = {}

  if state.uiOpen then
    U.commitDelta(U.buildSnapshot())
    guihooks.trigger("vehicleShopDelta", state.lastDelta)
  end
  if purchaseType == "inspect" then
    career_career.closeAllMenus()
  elseif purchaseType == "instant" then
    career_career.closeAllMenus()
  end
end

U.cancelPurchase = function(purchaseType)
  state.purchaseMenuOpen = false
  if purchaseType == "inspect" then
    career_career.closeAllMenus()
  elseif purchaseType == "instant" then
    -- Phone-initiated purchases open this screen without the computer shop UI
    -- (state.uiOpen). Routing back to vehicleShopping.vehicles leaves an orphan
    -- computer route that blocks the phone with no computer on screen.
    if state.uiOpen then
      extensions.ui_router.navigate("career.computer.vehicleShopping.vehicles")
    else
      career_career.closeAllMenus()
    end
  end
end

U.requestPurchaseExit = function()
  local purchaseType = state.purchaseData and state.purchaseData.purchaseType
  state.purchaseMenuOpen = false
  if purchaseType == "inspect" then
    career_career.closeAllMenus()
    return
  end
  if state.uiOpen then
    return extensions.ui_router.navigate("career.computer.vehicleShopping.vehicles")
  end
  return career_career.closeAllMenus()
end

U.getCarMeetPurchaseBlockReason = function()
  local garageAvailability = career_modules_garageManager and career_modules_garageManager.getGarageAvailabilityReason and career_modules_garageManager.getGarageAvailabilityReason() or "ok"
  if garageAvailability == "none" then
    return "Buy or rent a garage before purchasing a vehicle."
  end
  if not career_modules_inventory.hasFreeSlot() then
    return "No free garage space for another vehicle."
  end
  return nil
end

U.canPurchaseCarMeetVehicle = function(showMessage)
  local reason = U.getCarMeetPurchaseBlockReason()
  if reason then
    if showMessage then
      ui_message(reason, nil, "vehicleShopping")
    end
    return false
  end
  return true
end

U.buyCarMeetVehicleNow = function(shopId)
  local function fail(reason)
    return false, reason
  end

  U.openPurchaseMenu("instant", shopId, -1, true)
  if not state.purchaseData or not state.purchaseData.vehicleInfo or state.purchaseData.vehicleInfo.source ~= "carMeet" then
    return fail("This vehicle is no longer available for purchase.")
  end

  local blockReason = U.getCarMeetPurchaseBlockReason()
  if blockReason then
    return fail(blockReason)
  end

  local canAfford = career_modules_cheats and career_modules_cheats.isCheatsMode() or career_modules_playerAttributes.getAttributeValue("money") >= state.purchaseData.prices.finalPrice
  if not canAfford then
    return fail("You cannot afford this vehicle.")
  end

  state.purchaseData.keepCarMeetWorldVehicle = true
  local vehId
  if career_modules_carmeets and career_modules_carmeets.prepareCarMeetVehicleForPurchase then
    vehId = career_modules_carmeets.prepareCarMeetVehicleForPurchase(shopId, state.purchaseData.vehicleInfo)
  else
    vehId = career_modules_carmeets and career_modules_carmeets.getCarMeetVehicleIdForShopId and career_modules_carmeets.getCarMeetVehicleIdForShopId(shopId)
    if career_modules_carmeets and career_modules_carmeets.snapshotCarMeetVehicleForPurchase then
      career_modules_carmeets.snapshotCarMeetVehicleForPurchase(vehId)
    end
  end
  local vehObj = vehId and getObjectByID(vehId)
  if not vehObj then
    return fail("The vehicle could not be found at the meet. Try again before the event ends.")
  end

  -- Use the normal inventory initialization path so the installed parts are
  -- registered with partInventory before this vehicle can be modified later.
  local inventoryId = career_modules_inventory.addVehicle(vehId, nil, {
    owned = true, year = state.purchaseData.vehicleInfo.year,
    finalPrice = state.purchaseData.prices and state.purchaseData.prices.finalPrice
  })
  if not inventoryId then
    return fail("Could not add the vehicle to your garage.")
  end

  local inventoryVehicle = career_modules_inventory.getVehicles and career_modules_inventory.getVehicles()[inventoryId]
  if inventoryVehicle then
    local vehicleData = core_vehicle_manager and core_vehicle_manager.getVehicleData(vehId)
    if vehicleData and type(vehicleData.config) == "table" then
      inventoryVehicle.config = deepcopy(vehicleData.config)
    end
    inventoryVehicle.mileage = state.purchaseData.vehicleInfo.Mileage or inventoryVehicle.mileage or 0
    inventoryVehicle.purchasePrice = state.purchaseData.prices and state.purchaseData.prices.finalPrice or state.purchaseData.vehicleInfo.Value
  end

  if not career_modules_inventory.moveVehicleToGarage(inventoryId) then
    career_modules_inventory.removeVehicle(inventoryId)
    return fail("No free garage space for another vehicle.")
  end

  vehObj:queueLuaCommand('ai.setMode("disabled")')
  vehObj:queueLuaCommand('electrics.setIgnitionLevel(0)')
  vehObj:queueLuaCommand('if electrics.setLightsState then electrics.setLightsState(0) end')
  vehObj:queueLuaCommand('if electrics.set_warn_signal then electrics.set_warn_signal(0) end')

  U.payForVehicle()

  -- Register with insurance as uninsured; coverage can be added later at a garage/computer.
  state.purchaseData.insuranceId = -1
  extensions.hook("onVehicleAddedToInventory", {
    inventoryId = inventoryId,
    vehicleInfo = state.purchaseData.vehicleInfo,
    selectedPolicyId = 0,
    purchaseData = state.purchaseData
  })

  local targetShopId = tonumber(state.purchaseData.shopId) or state.purchaseData.shopId
  for i, vehInfo in ipairs(state.vehiclesInShop) do
    local vehShopId = tonumber(vehInfo.shopId) or vehInfo.shopId
    if vehShopId == targetShopId then
      vehInfo.markedSold = true
      vehInfo.soldViewCounter = 1
      state.pendingSoldShopIds[state.purchaseData.shopId] = true
      table.remove(state.vehiclesInShop, i)
      break
    end
  end

  state.purchaseMenuOpen = false
  state.inspectingVehicleShopId = nil
  if career_career.isAutosaveEnabled() then
    career_saveSystem.saveCurrent(nil, {force = true})
  end
  career_career.closeAllMenus()
  return true
end

U.removeTradeInVehicle = function()
  state.purchaseData.tradeInVehicleInfo = nil
  U.sendPurchaseDataToUi()
end

U.openInventoryMenuForTradeIn = function()
  career_modules_inventory.openMenu({{
    callback = function(inventoryId)
      local vehicle = career_modules_inventory.getVehicles()[inventoryId]
      if vehicle then
        local niceName = career_modules_inventory.getVehicleNiceNameTranslated
          and career_modules_inventory.getVehicleNiceNameTranslated(inventoryId)
        if type(niceName) ~= "string" or niceName == "" then
          niceName = vehicle.niceName
        end
        if type(niceName) == "table" and core_locales and core_locales.translateWithOrWithoutContext then
          niceName = core_locales.translateWithOrWithoutContext(niceName)
        end
        if type(niceName) ~= "string" then
          niceName = tostring(niceName or "Trade-In Vehicle")
        end
        state.purchaseData.tradeInVehicleInfo = {
          id = inventoryId,
          niceName = niceName,
          Value = career_modules_valueCalculator.getInventoryVehicleValue(inventoryId) *
            (career_modules_difficultyMode and career_modules_difficultyMode.isHardcoreMode and career_modules_difficultyMode.isHardcoreMode() and 0.33 or 0.66),
          takesNoInventorySpace = vehicle.takesNoInventorySpace
        }
        guihooks.trigger('UINavigation', 'back', 1)
        U.sendPurchaseDataToUi()
      end
    end,
    buttonText = "Trade-In",
    repairRequired = true,
    ownedRequired = true
  }}, "Trade-In", {
    repairEnabled = false,
    sellEnabled = false,
    favoriteEnabled = false,
    storingEnabled = false,
    returnLoanerEnabled = false
  }, "career.computer.vehicleShopping.vehicles.vehiclePurchase")
end

U.onExtensionLoaded = function()
  if not career_career.isActive() then
    return false
  end

  U.resetVehicleValidationState()
  -- Prepare once during career activation/world readiness, after dependencies.
  -- Building here as well repeated the full catalog work during career load.

  state.purchaseMenuOpen = false
  state.inspectingVehicleShopId = nil

  local saveSlot, savePath = career_saveSystem.getCurrentProfile()
  if not saveSlot or not savePath then
    return
  end

  local savedData = jsonReadFile(savePath .. "/career/vehicleShop.json")
  -- vehicleShop.json owns C.moduleVersion. info.json uses the independent career
  -- save-system version, so comparing that value to C.moduleVersion made every
  -- current save look outdated (for example, save-system 64 vs shop module 69).
  local outdated = not savedData or (tonumber(savedData.version) or 0) < C.moduleVersion

  -- Discovery is durable player progress, not generated shop inventory. Load it
  -- even when a career/module version or valuation schema change invalidates the
  -- saved offers below.
  state.discoveredDealers = savedData and type(savedData.discoveredDealers) == "table"
    and savedData.discoveredDealers or {}

  local data = not outdated and savedData
  if data and tonumber(data.valuationSchemaVersion) ~= C.valuationSchemaVersion then
    log("I", "vehicleShopping", string.format(
      "Discarding saved shop offers from valuation schema %s; current schema is %d",
      tostring(data.valuationSchemaVersion), C.valuationSchemaVersion))
    data = nil
    state.otherMapsData = {}
    state.vehiclesInShop = {}
    state.sellersInfos = {}
    state.vehicleWatchlist = {}
  end
  if data then
    local currentMap = getCurrentLevelIdentifier()
    local limitedMileageSchemaOutdated =
      tonumber(data.limitedMileageDealerSchemaVersion) ~= M.limitedMileageDealerSchemaVersion
    state.vehicleWatchlist = data.vehicleWatchlist or {}
    state.rtPendingFleetPurchases = data.rtPendingFleetPurchases or {}

    -- New format with 'maps' key
    if data.maps then
      state.otherMapsData = data.maps
      for mapId, mapData in pairs(state.otherMapsData) do
        if mapData.vehiclesInShop then
          local sanitizedVehicles, loadSummary = U.sanitizeSavedVehicleEntries(mapData.vehiclesInShop,
            "load:" .. tostring(mapId))
          if limitedMileageSchemaOutdated then
            for i = #sanitizedVehicles, 1, -1 do
              local sellerId = sanitizedVehicles[i].sellerId
              if sellerId == "raceTab" or sellerId == "asotv" then
                table.remove(sanitizedVehicles, i)
              end
            end
          end
          mapData.vehiclesInShop = sanitizedVehicles
          if loadSummary.raw > 0 then
            U.logVehicleSanitizationSummary("saved vehicle load " .. tostring(mapId), loadSummary)
          end
        end
      end
    else
      -- Migration from old flat format
      local oldVehicles = data.vehiclesInShop or {}
      local oldSellers = data.sellersInfos or {}
      local oldDirtyDate = data.dirtyDate

      for _, vehicleInfo in ipairs(oldVehicles) do
        local sanitizedVehicles, _ = U.sanitizeSavedVehicleEntries({vehicleInfo}, "load:migration")
        local sanitizedVehicle = sanitizedVehicles[1]
        if sanitizedVehicle and not (limitedMileageSchemaOutdated and
          (sanitizedVehicle.sellerId == "raceTab" or sanitizedVehicle.sellerId == "asotv")) then
          local mId = sanitizedVehicle.mapId or currentMap
          if not state.otherMapsData[mId] then state.otherMapsData[mId] = {vehiclesInShop = {}, sellersInfos = {}} end
          table.insert(state.otherMapsData[mId].vehiclesInShop, sanitizedVehicle)
        end
      end

      for sellerId, sellerInfo in pairs(oldSellers) do
        local mId = sellerInfo.mapId or currentMap
        if not state.otherMapsData[mId] then state.otherMapsData[mId] = {vehiclesInShop = {}, sellersInfos = {}} end
        state.otherMapsData[mId].sellersInfos[sellerId] = sellerInfo
      end

      -- Assign dirty date to the current map if it was migration
      if state.otherMapsData[currentMap] then
        state.otherMapsData[currentMap].dirtyDate = oldDirtyDate
      end
    end

    -- Set current map data
    local currentData = state.otherMapsData[currentMap] or {}
    local sanitizedVehicles, loadSummary = U.sanitizeSavedVehicleEntries(currentData.vehiclesInShop or {},
      "load:current:" .. tostring(currentMap))
    if loadSummary.raw > 0 then
      U.logVehicleSanitizationSummary("saved vehicle load current " .. tostring(currentMap), loadSummary)
    end
    currentData.vehiclesInShop = sanitizedVehicles
    state.vehiclesInShop = sanitizedVehicles
    state.sellersInfos = currentData.sellersInfos or {}
    state.vehicleShopDirtyDate = currentData.dirtyDate
    state.lastMap = currentMap
  end
end

U.onSaveCurrentProfile = function(currentSavePath)
  local currentMap = getCurrentLevelIdentifier()

  -- Update the stash for the current map
  state.otherMapsData[currentMap] = {
    vehiclesInShop = state.vehiclesInShop,
    sellersInfos = state.sellersInfos,
    dirtyDate = state.vehicleShopDirtyDate
  }

  local data = {}
  data.maps = state.otherMapsData
  data.vehicleWatchlist = state.vehicleWatchlist
  data.rtPendingFleetPurchases = state.rtPendingFleetPurchases
  data.discoveredDealers = state.discoveredDealers
  data.version = C.moduleVersion
  data.valuationSchemaVersion = C.valuationSchemaVersion
  data.limitedMileageDealerSchemaVersion = M.limitedMileageDealerSchemaVersion

  career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/vehicleShop.json", data, true)
end

U.getCurrentSellerId = function()
  return state.currentSeller
end

U.onComputerAddFunctions = function(menuData, computerFunctions)
  local computerFunctionData = {
    id = "vehicleShop",
    label = "Vehicle Marketplace",
    routeTarget = "career.computer.vehicleShopping",
    callback = function()
      U.openShop(nil, menuData.computerFacility.id)
    end,
    order = 10
  }
  if menuData.tutorialPartShoppingActive or menuData.tutorialTuningActive then
    computerFunctionData.disabled = true
    computerFunctionData.reason = career_modules_computer.reasons.tutorialActive
  end
  local reason = career_modules_permissions.getStatusForTag("vehicleShopping")
  if not reason.allow then
    computerFunctionData.disabled = true
  end
  if reason.permission ~= "allowed" then
    computerFunctionData.reason = reason
  end

  computerFunctions.general[computerFunctionData.id] = computerFunctionData
end

U.onModActivated = function()
  -- Coalesce mod activation bursts; rebuild once on the next stock update.
  U.invalidateVehicleCache()
end

U.onWorldReadyState = function(worldReadyState)
  if worldReadyState == 2 then
    local currentMap = getCurrentLevelIdentifier()

    -- Stash previous map data if it exists
    if state.lastMap and state.lastMap ~= currentMap then
      state.otherMapsData[state.lastMap] = {
        vehiclesInShop = state.vehiclesInShop,
        sellersInfos = state.sellersInfos,
        dirtyDate = state.vehicleShopDirtyDate
      }
    end

    -- Load new map data
    if state.otherMapsData[currentMap] then
      local currentData = state.otherMapsData[currentMap]
      local sanitizedVehicles, loadSummary = U.sanitizeSavedVehicleEntries(currentData.vehiclesInShop or {},
        "onWorldReadyState:" .. tostring(currentMap))
      if loadSummary.raw > 0 then
        U.logVehicleSanitizationSummary("world load " .. tostring(currentMap), loadSummary)
      end
      currentData.vehiclesInShop = sanitizedVehicles
      state.vehiclesInShop = sanitizedVehicles
      state.sellersInfos = currentData.sellersInfos or {}
      state.vehicleShopDirtyDate = currentData.dirtyDate
    else
      -- If no data for this map, start fresh but keep watchlist
      state.vehiclesInShop = {}
      state.sellersInfos = {}
      state.vehicleShopDirtyDate = nil
    end

    state.lastMap = currentMap
    U.prepareVehicleCache()

    -- Repair freight purchases made before pickup completion assigned a home
    -- garage. A current/last vehicle proves the player has already collected it.
    local collectedInventoryId =
      (career_modules_inventory.getCurrentVehicle and career_modules_inventory.getCurrentVehicle()) or
      (career_modules_inventory.getLastVehicle and career_modules_inventory.getLastVehicle())
    M.completeFreightPickup(collectedInventoryId)
  end
end

-- Statistics and utility functions
U.getCacheStats = function()
  if not state.vehicleCache.cacheValid then
    return {
      valid = false,
      message = "Cache not initialized"
    }
  end

  local stats = {
    valid = true,
    cacheTime = state.vehicleCache.lastCacheTime,
    dealerships = {},
    totalVehicles = 0
  }

  for dealershipId, data in pairs(state.vehicleCache.dealershipCache) do
    local regularCount = data.regularVehicles and #data.regularVehicles or 0
    stats.dealerships[dealershipId] = {
      regularVehicles = regularCount,
      total = regularCount
    }
    stats.totalVehicles = stats.totalVehicles + regularCount
  end

  return stats
end

U.getMapStats = function()
  local stats = {
    currentMap = getCurrentLevelIdentifier(),
    vehiclesByMap = {},
    sellersByMap = {},
    totalVehicles = #state.vehiclesInShop,
    totalSellers = tableSize(state.sellersInfos)
  }

  for _, vehicleInfo in ipairs(state.vehiclesInShop) do
    local mapId = vehicleInfo.mapId or "unknown"
    stats.vehiclesByMap[mapId] = (stats.vehiclesByMap[mapId] or 0) + 1
  end

  for sellerId, sellerInfo in pairs(state.sellersInfos) do
    local mapId = sellerInfo.mapId or "unknown"
    stats.sellersByMap[mapId] = (stats.sellersByMap[mapId] or 0) + 1
  end

  return stats
end

U.clearDataFromOtherMaps = function(targetMap)
  targetMap = targetMap or getCurrentLevelIdentifier()

  local filteredVehicles = {}
  for _, vehicleInfo in ipairs(state.vehiclesInShop) do
    if vehicleInfo.mapId == targetMap then
      table.insert(filteredVehicles, vehicleInfo)
    end
  end
  local removedVehicles = #state.vehiclesInShop - #filteredVehicles
  state.vehiclesInShop = filteredVehicles

  local filteredSellers = {}
  local removedSellers = 0
  for sellerId, sellerInfo in pairs(state.sellersInfos) do
    if sellerInfo.mapId == targetMap then
      filteredSellers[sellerId] = sellerInfo
    else
      removedSellers = removedSellers + 1
    end
  end
  state.sellersInfos = filteredSellers

  return {
    vehiclesRemoved = removedVehicles,
    sellersRemoved = removedSellers
  }
end

-- Public API
M.openShop = U.openShop
M.showVehicle = U.showVehicle
M.navigateToPos = U.navigateToPos
M.navigateToDealership = U.navigateToDealership
M.taxiToDealership = U.taxiToDealership
M.getTaxiPriceToDealership = U.getTaxiPriceToDealership
M.buySpawnedVehicle = U.buySpawnedVehicle
M.quickTravelToVehicle = U.quickTravelToVehicle
M.updateVehicleList = U.updateVehicleList
M.getShoppingData = U.getShoppingData
M.sendShoppingDataToUI = U.sendShoppingDataToUI
M.onRouteMount = U.onRouteMount
M.selectSeller = U.selectSeller
M.getSelectedSellerBreadcrumbTitle = U.getSelectedSellerBreadcrumbTitle
M.sendPurchaseDataToUi = U.sendPurchaseDataToUi
M.getDeliveryQuote = U.getDeliveryQuote
M.getCurrentSellerId = U.getCurrentSellerId
M.getSellerAccessInfo = U.getSellerAccessInfo
M.isOnlineSellerId = U.isOnlineSellerId
M.getVisualValueFromMileage = U.getVisualValueFromMileage
M.invalidateVehicleCache = U.invalidateVehicleCache
M.getLastDelta = function()
  return state.lastDelta
end
M.setShoppingUiOpen = U.setShoppingUiOpen
M.getVehicleInfoByShopId = U.getVehicleInfoByShopId
M.registerCarMeetVehicle = U.registerCarMeetVehicle
M.removeCarMeetVehicles = U.removeCarMeetVehicles
M.canPurchaseCarMeetVehicle = U.canPurchaseCarMeetVehicle
M.getCarMeetPurchaseBlockReason = U.getCarMeetPurchaseBlockReason
M.buyCarMeetVehicleNow = U.buyCarMeetVehicleNow
M.grantRewardVehicle = U.grantRewardVehicle
M.getPendingRacingTeamFleetPurchases = U.getPendingRacingTeamFleetPurchases
M.clearPendingRacingTeamFleetPurchases = U.clearPendingRacingTeamFleetPurchases
M.openPurchaseMenu = U.openPurchaseMenu
M.updateInsuranceSelection = U.updateInsuranceSelection
M.buyFromPurchaseMenu = U.buyFromPurchaseMenu
M.openInventoryMenuForTradeIn = U.openInventoryMenuForTradeIn
M.removeTradeInVehicle = U.removeTradeInVehicle
M.endShopping = U.endShopping
M.cancelShopping = U.cancelShopping
M.requestExit = U.requestExit
M.requestVehicleListExit = U.requestVehicleListExit
M.cancelPurchase = U.cancelPurchase
M.requestPurchaseExit = U.requestPurchaseExit
M.getVehiclesInShop = U.getVehiclesInShop
M.onWorldReadyState = U.onWorldReadyState
M.onCareerModulesActivated = U.prepareVehicleCache
M.onModActivated = U.onModActivated
M.onModDeactivated = U.onModActivated
M.onModManagerReady = U.onModActivated
M.onClientStartMission = U.onClientStartMission
M.onVehicleSpawnFinished = U.onVehicleSpawnFinished
M.onRewardVehicleSpawnFinished = U.onRewardVehicleSpawnFinished
M.onRacingTeamFleetVehicleSpawnFinished = U.onRacingTeamFleetVehicleSpawnFinished
M.onAddedVehiclePartsToInventory = U.onAddedVehiclePartsToInventory
M.onEnterVehicleFinished = U.onEnterVehicleFinished
M.onExtensionLoaded = U.onExtensionLoaded
M.onSaveCurrentProfile = U.onSaveCurrentProfile
M.onShoppingMenuClosed = U.onShoppingMenuClosed
M.onComputerAddFunctions = U.onComputerAddFunctions
M.onUpdate = U.onUpdate
M.onUiChangedState = U.onUiChangedState
M.onVehicleInspectionFinished = function(shopId)
  if state.inspectingVehicleShopId == shopId then
    state.inspectingVehicleShopId = nil
    log("D", "Career", "Inspection finished for vehicle: " .. tostring(shopId))
  end
end

M.checkSpawnedVehicleStatus = function()
  local spawnedVehicleInfo = career_modules_inspectVehicle.getSpawnedVehicleInfo()
  if spawnedVehicleInfo and state.inspectingVehicleShopId and spawnedVehicleInfo.shopId == state.inspectingVehicleShopId then
    return true
  elseif state.inspectingVehicleShopId then
    log("D", "Career", "Clearing inspection state for vehicle: " .. tostring(state.inspectingVehicleShopId))
    state.inspectingVehicleShopId = nil
    return false
  end
  return false
end

M.cacheDealers = U.cacheDealers
M.rebuildDealershipCache = U.rebuildDealershipCache
M.getRandomVehicleFromCache = U.getRandomVehicleFromCache
M.getCacheStats = U.getCacheStats
M.getMapStats = U.getMapStats
M.clearDataFromOtherMaps = U.clearDataFromOtherMaps
M.getEligibleVehiclesWithoutDealershipVehicles = U.getEligibleVehiclesWithoutDealershipVehicles
function M.setRtBiz(id)
  if id == nil or id == "" then
    state.rtBizId = nil
    -- Do not clear state.currentSeller/state.originComputerId here:
    -- VehicleShoppingMain always calls setRtBiz(""), including normal in-person dealer flow.
    -- Clearing seller scope here unintentionally widens in-person shopping to global marketplace.
    return true
  end
  state.rtBizId = tonumber(id) or id
  state.fleetBusinessType = "racingTeam"
  -- Entering the racing team computer's vehicle shopping context; drop any stale
  -- dealer scope so the shop isn't silently filtered to the last visited dealer.
  state.currentSeller = nil
  state.originComputerId = nil
  state.selectedSellerId = nil
  state.shoppingScreenTag = "buying"
  state.buyingAvailable = true
  state.marketplaceAvailable = false
  U.sendShoppingDataToUI()
  return true
end

function M.setFleetBiz(businessType, id)
  if id == nil or id == "" then
    state.rtBizId = nil
    state.fleetBusinessType = "racingTeam"
    return true
  end
  state.fleetBusinessType = tostring(businessType or "racingTeam")
  state.rtBizId = tonumber(id) or id
  state.currentSeller, state.originComputerId, state.selectedSellerId = nil, nil, nil
  state.shoppingScreenTag, state.buyingAvailable, state.marketplaceAvailable = "buying", true, false
  U.sendShoppingDataToUI()
  return true
end

return M
