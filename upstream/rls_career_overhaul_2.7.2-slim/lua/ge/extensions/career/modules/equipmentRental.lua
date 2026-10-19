local M = {}

M.dependencies = {
  'career_career',
  'career_modules_loanerVehicles',
}

local activeFacId = nil
local activePsPath = nil

local CATEGORY_ORDER = {
  "pickups",
  "dSeries",
  "tiltDeckTrailers",
  "hSeries",
  "boxVans",
  "hSeriesRollbacks",
  "dSeriesRollbacks",
  "tSeriesRollbacks",
  "cargoBoxTrucks",
  "heavyHaul",
  "carHaulTrailers",
  "other",
}

local CATEGORY_LABELS = {
  pickups = "Pickups",
  dSeries = "D-Series",
  tiltDeckTrailers = "Tilt Deck Trailers",
  hSeries = "H-Series",
  boxVans = "Box Vans",
  hSeriesRollbacks = "H-Series Rollbacks",
  dSeriesRollbacks = "D-Series Rollbacks",
  tSeriesRollbacks = "T-Series Rollbacks",
  cargoBoxTrucks = "Cargo Box Trucks",
  heavyHaul = "Heavy Haul",
  carHaulTrailers = "Car Haul Trailers",
  other = "Other",
}

local function isCareerActive()
  return career_career and career_career.isActive and career_career.isActive()
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

local function inferCategory(offer)
  if offer.rentalCategory then return offer.rentalCategory end
  if offer.vehOfferType == "trailer" then
    if offer.model == "tiltdeck" then return "tiltDeckTrailers" end
    if offer.model == "dryvan" then return "carHaulTrailers" end
    return "other"
  end
  if offer.model == "pickup" then return "pickups" end
  if offer.model == "van" then return "hSeriesRollbacks" end
  if offer.model == "us_semi" then return "tSeriesRollbacks" end
  return "other"
end

local function categorySortIndex(category)
  for idx, id in ipairs(CATEGORY_ORDER) do
    if id == category then return idx end
  end
  return #CATEGORY_ORDER
end

local function buildActiveRentals(facility)
  local orgId = facility and facility.associatedOrganization
  if not orgId then return {} end
  local rentals = {}
  for _, veh in ipairs(career_modules_loanerVehicles.formatSpawnedLoanersForUi() or {}) do
    if veh.owningOrganization == orgId and veh.loanType == "rental" then
      table.insert(rentals, {
        inventoryId = veh.id,
        name = veh.name,
        hourlyRate = veh.hourlyRate,
        vehOfferType = veh.vehOfferType,
        organizationName = veh.organizationName,
      })
    end
  end
  return rentals
end

local function buildGroupedOffers(facility)
  local offers = career_modules_loanerVehicles.formatLoanerOfferForUi(facility) or {}
  local grouped = {}
  local lookup = {}

  for _, offer in ipairs(offers) do
    local category = inferCategory(offer)
    if not lookup[category] then
      lookup[category] = {
        id = category,
        label = CATEGORY_LABELS[category] or category,
        offers = {},
      }
      table.insert(grouped, lookup[category])
    end
    offer.rentalCategory = category
    table.insert(lookup[category].offers, offer)
  end

  table.sort(grouped, function(a, b)
    return categorySortIndex(a.id) < categorySortIndex(b.id)
  end)

  for _, group in ipairs(grouped) do
    table.sort(group.offers, function(a, b)
      local repA = tonumber(a.reputationLvl) or -99
      local repB = tonumber(b.reputationLvl) or -99
      if repA ~= repB then return repA < repB end
      return tostring(a.name) < tostring(b.name)
    end)
  end

  return grouped
end

local function getUiData()
  if not activeFacId then
    return { error = "no_facility" }
  end

  local fac = getDeliveryFacility(activeFacId)
  if not fac then
    return { error = "facility_not_found" }
  end

  local orgId = fac.associatedOrganization
  local organization = orgId and freeroam_organizations.getOrganization(orgId) or nil

  return {
    facilityId = activeFacId,
    facilityName = fac.name or activeFacId,
    organizationName = organization and organization.name or orgId,
    playerMoney = career_modules_playerAttributes and career_modules_playerAttributes.getAttributeValue("money") or 0,
    activeRentals = buildActiveRentals(fac),
    groups = buildGroupedOffers(fac),
  }
end

local function findOfferById(offerId)
  local fac = getDeliveryFacility(activeFacId)
  if not fac then return nil end
  for _, offer in ipairs(career_modules_loanerVehicles.formatLoanerOfferForUi(fac) or {}) do
    if offer.id == offerId then
      return offer
    end
  end
  return nil
end

local function rentOffer(offerId)
  if not isCareerActive() then
    return { ok = false, message = "Career is not active." }
  end

  local offer = findOfferById(offerId)
  if not offer then
    return { ok = false, message = "That rental is no longer available." }
  end
  if not offer.enabled then
    local reason = offer.disableReason and offer.disableReason.label
    return { ok = false, message = reason or "That rental is not available right now." }
  end

  career_modules_loanerVehicles.unmarkAllForSpawning()
  career_modules_loanerVehicles.setMarkedForSpawning(offer, true)
  career_modules_loanerVehicles.spawnAllOffers(function()
    if career_career and career_career.closeAllMenus then
      career_career.closeAllMenus()
    end
  end)

  return { ok = true }
end

local function returnRental(inventoryId)
  if not isCareerActive() then
    return { ok = false, message = "Career is not active." }
  end
  inventoryId = tonumber(inventoryId)
  if not inventoryId or not career_modules_loanerVehicles or not career_modules_loanerVehicles.returnVehicle then
    return { ok = false, message = "Return is unavailable." }
  end

  local fac = getDeliveryFacility(activeFacId)
  local orgId = fac and fac.associatedOrganization
  local vehicles = career_modules_inventory and career_modules_inventory.getVehicles and career_modules_inventory.getVehicles() or {}
  local vehInfo = vehicles[inventoryId]
  if not vehInfo or vehInfo.loanType ~= "rental" or (orgId and vehInfo.owningOrganization ~= orgId) then
    return { ok = false, message = "That rental cannot be returned here." }
  end

  career_modules_loanerVehicles.returnVehicle(inventoryId)
  return { ok = true }
end

local function ensureModuleLoaded()
  if career_modules_equipmentRental then return true end
  if extensions and extensions.load then
    pcall(extensions.load, "career_modules_equipmentRental")
  end
  return career_modules_equipmentRental ~= nil
end

local function openScreen(facilityId, parkingSpotPath)
  if not isCareerActive() then return false end
  if not facilityId then return false end

  if facilityId == "finkIndustries" then
    local oo = career_modules_delivery_ownerOpContracts
    if oo and oo.spawnQueuedCarHaulOffers then
      oo.spawnQueuedCarHaulOffers()
    end
  end

  if career_modules_loanerVehicles and career_modules_loanerVehicles.unmarkAllForSpawning then
    career_modules_loanerVehicles.unmarkAllForSpawning()
  end

  activeFacId = facilityId
  activePsPath = parkingSpotPath
  extensions.ui_router.navigate('equipment-rental')
  return true
end

local function closeScreen()
  activeFacId = nil
  activePsPath = nil
  if career_modules_loanerVehicles and career_modules_loanerVehicles.unmarkAllForSpawning then
    career_modules_loanerVehicles.unmarkAllForSpawning()
  end
  if career_career and career_career.closeAllMenus then
    career_career.closeAllMenus()
  end
end

M.openScreen = openScreen
M.closeScreen = closeScreen
M.getUiData = getUiData
M.rentOffer = rentOffer
M.returnRental = returnRental
M.ensureModuleLoaded = ensureModuleLoaded

return M
