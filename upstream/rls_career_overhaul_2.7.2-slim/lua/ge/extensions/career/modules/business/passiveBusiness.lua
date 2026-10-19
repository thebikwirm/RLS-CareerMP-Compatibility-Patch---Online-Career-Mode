local M = {}

local SAVE_VERSION = 2

local legacyBalance = {
  miniMart = {storageUpgradeCosts = {8000, 12000, 18000, 26000}, wholesaleUpgradeCost = 18000},
  cafe = {storageUpgradeCosts = {9000, 14000, 21000, 30000}, wholesaleUpgradeCost = 22000},
  boutique = {storageUpgradeCosts = {14000, 22000, 34000, 50000}, wholesaleUpgradeCost = 35000},
  supermarket = {storageUpgradeCosts = {26000, 42000, 68000, 100000}, wholesaleUpgradeCost = 75000},
  nailSalon = {storageUpgradeCosts = {11000, 17000, 25000, 36000}, wholesaleUpgradeCost = 22000},
  giftShop = {storageUpgradeCosts = {10000, 16000, 24000, 34000}, wholesaleUpgradeCost = 28000},
  jewelryStore = {storageUpgradeCosts = {35000, 60000, 95000, 140000}, wholesaleUpgradeCost = 120000},
  dryCleaner = {storageUpgradeCosts = {10000, 16000, 24000, 34000}, wholesaleUpgradeCost = 18000},
  specialtyRetail = {storageUpgradeCosts = {18000, 28000, 42000, 62000}, wholesaleUpgradeCost = 48000},
}

M.dependencies = {
  "career_career",
  "career_saveSystem",
  "career_modules_payment",
  "career_modules_playerAttributes",
  "career_modules_business_businessManager",
  "career_modules_business_businessTabRegistry",
  "freeroam_facilities",
}

local archetypes = {}
local properties = {}
local reservations = {}
local nextReservationId = 1
local activeBusinessId = nil
local supplyPickupOpen = false
local supplyPickupFacId, supplyPickupPsPath = nil, nil
local supplyLoadInProgress = false
local saveVersion = SAVE_VERSION
local refundPaidThisLoad = false
local refundPaidForSavePath = nil

local function indexed(baseValue)
  local index = career_modules_globalEconomy and career_modules_globalEconomy.getGlobalIndex() or 1
  return math.floor((tonumber(baseValue) or 0) * index + 0.0001)
end

local function notify(kind, title, message)
  if guihooks then
    guihooks.trigger("toastrMsg", {type = kind, title = title, msg = message})
  end
end

local function loadArchetypes()
  archetypes = jsonReadFile("gameplay/business/passiveBusinessArchetypes.json") or {}
end

local function normalizeState(id, state)
  state = type(state) == "table" and state or {}
  state.id = tostring(id)
  state.archetypeId = state.archetypeId or "miniMart"
  state.mapId = state.mapId or "west_coast_usa"
  state.stock = math.max(0, math.floor(tonumber(state.stock) or 0))
  state.storageLevel = math.max(1, math.floor(tonumber(state.storageLevel) or 1))
  state.cycleProgress = math.max(0, tonumber(state.cycleProgress) or 0)
  state.uncollectedEarnings = math.max(0, math.floor(tonumber(state.uncollectedEarnings) or 0))
  state.wholesaleOwned = state.wholesaleOwned == true
  state.operating = state.operating ~= false
  -- v1 migration: Gate 1 is a freight endpoint but not an inspect spot, so it
  -- cannot expose the cargo interaction. Existing paid orders must follow the
  -- property to Spearleaf's inspect-enabled Warehouse Parking instead.
  if state.archetypeId == "miniMart" and state.supplierParkingSpotName == "spearleafLogistics_gate1" then
    state.supplierParkingSpotName = "spearleafLogistics_parkingA"
  end
  if state.archetypeId == "miniMart" and state.receivingParkingSpotName == "Parking 696" then
    state.receivingParkingSpotName = "miniMart"
  end
  if state.outOfStockNotified == nil then state.outOfStockNotified = true end
  return state
end

local function saveData(currentSavePath)
  if not currentSavePath then return end
  jsonWriteFile(currentSavePath .. "/career/rls_career/passiveBusinesses.json", {
    version = saveVersion,
    properties = properties,
    reservations = reservations,
    nextReservationId = nextReservationId,
  }, true)
end

local function balanceRefundForState(state)
  local old = state and legacyBalance[state.archetypeId]
  local current = state and archetypes[state.archetypeId]
  if not old or not current then return 0 end
  local refund = 0
  local purchasedStorageLevels = math.max(0, math.min(#old.storageUpgradeCosts, (tonumber(state.storageLevel) or 1) - 1))
  for level = 1, purchasedStorageLevels do
    refund = refund + math.max(0, indexed(old.storageUpgradeCosts[level]) - indexed(current.storageUpgradeCosts[level]))
  end
  if state.wholesaleOwned then
    refund = refund + math.max(0, indexed(old.wholesaleUpgradeCost) - indexed(current.wholesaleUpgradeCost))
  end
  return math.floor(refund + 0.5)
end

local function loadData()
  properties, reservations, nextReservationId = {}, {}, 1
  local _, currentSavePath = career_saveSystem.getCurrentProfile()
  if not currentSavePath then return 0 end
  local data = jsonReadFile(currentSavePath .. "/career/rls_career/passiveBusinesses.json") or {}
  local loadedVersion = math.max(1, math.floor(tonumber(data.version) or 1))
  saveVersion = loadedVersion < SAVE_VERSION and loadedVersion or SAVE_VERSION
  for id, state in pairs(data.properties or {}) do
    properties[tostring(id)] = normalizeState(id, state)
  end
  for id, reservation in pairs(data.reservations or {}) do
    if type(reservation) == "table" then
      reservation.id = tostring(reservation.id or id)
      local property = properties[tostring(reservation.orderedByPropertyId)]
      reservation.mapId = reservation.mapId or (property and property.mapId) or "west_coast_usa"
      local archetype = archetypes[reservation.archetypeId]
      if archetype then
        reservation.supplyType = reservation.supplyType or archetype.supplyType
        reservation.supplyName = reservation.supplyName or archetype.supplyName
        reservation.supplyTemplateId = reservation.supplyTemplateId or archetype.supplyTemplateId
        reservation.supplySlots = reservation.supplySlots or archetype.supplySlots
      end
      reservation.status = "available"
      reservation.cargoId = nil
      if reservation.archetypeId == "miniMart" and reservation.supplierParkingSpotName == "spearleafLogistics_gate1" then
        reservation.supplierParkingSpotName = "spearleafLogistics_parkingA"
      end
      reservations[reservation.id] = reservation
    end
  end
  nextReservationId = math.max(1, math.floor(tonumber(data.nextReservationId) or 1))
  local refund = 0
  if loadedVersion < SAVE_VERSION then
    for _, state in pairs(properties) do refund = refund + balanceRefundForState(state) end
  end
  return refund
end

local function owned(id)
  return career_modules_business_businessManager
    and career_modules_business_businessManager.isPurchasedBusiness("passiveBusiness", id) == true
end

local function getArchetype(stateOrId)
  local state = type(stateOrId) == "table" and stateOrId or properties[tostring(stateOrId)]
  return state and archetypes[state.archetypeId] or nil
end

local function supplyName(stateOrId)
  local archetype = getArchetype(stateOrId)
  return archetype and archetype.supplyName or "Business Supplies"
end

local function getCapacity(state)
  local archetype = getArchetype(state)
  if not archetype then return 0 end
  return tonumber(archetype.storageCapacities[state.storageLevel]) or 0
end

local function currentFacility(id)
  return freeroam_facilities.getFacilityIfExists
    and freeroam_facilities.getFacilityIfExists("passiveBusiness", id)
    or nil
end

local function businessName(stateOrId)
  local state = type(stateOrId) == "table" and stateOrId or properties[tostring(stateOrId)]
  local facility = state and currentFacility(state.id) or nil
  local archetype = getArchetype(state)
  return (facility and facility.name) or (archetype and archetype.name) or "Business"
end

-- ---- finance history (per store, saved with the property state) ----
-- Every money event this module causes is recorded on the state: collections, supply orders and
-- upgrades as history rows, and those plus pallets sold as lifetime totals. Stores bought before this
-- existed get a one-time backfill from the money log where its label names this store.
local HISTORY_LIMIT = 60

local function financeTotals(state)
  local totals = type(state.financeTotals) == "table" and state.financeTotals or {}
  for _, key in ipairs({"collected", "supplies", "upgrades", "palletsSold", "salesRevenue"}) do
    totals[key] = math.max(0, math.floor(tonumber(totals[key]) or 0))
  end
  state.financeTotals = totals
  return totals
end

local function recordFinance(state, kind, amount, quantity)
  if not state then return end
  amount = math.max(0, math.floor(tonumber(amount) or 0))
  state.financeHistory = type(state.financeHistory) == "table" and state.financeHistory or {}
  table.insert(state.financeHistory, {t = os.time(), kind = kind, amount = amount, qty = quantity})
  while #state.financeHistory > HISTORY_LIMIT do table.remove(state.financeHistory, 1) end
  local totals = financeTotals(state)
  if kind == "collect" then
    totals.collected = totals.collected + amount
  elseif kind == "order" then
    totals.supplies = totals.supplies + amount
  elseif kind == "storage" or kind == "wholesale" then
    totals.upgrades = totals.upgrades + amount
  end
end

local function backfillFinanceHistory(state, name, ordersAreOurs)
  if state.financeBackfilled then return end
  state.financeBackfilled = true
  local log = career_modules_playerAttributes.getAttributeLog and career_modules_playerAttributes.getAttributeLog()
  if type(log) ~= "table" then return end
  local labels = {
    ["Collected " .. name .. " earnings"] = "collect",
    [name .. " storage upgrade"] = "storage",
    [name .. " wholesale agreement"] = "wholesale",
  }
  -- order labels only name the supply, so they are ours only when no other store shares the supply
  if ordersAreOurs then labels["Ordered " .. supplyName(state)] = "order" end
  local found = {}
  for _, change in ipairs(log) do
    local reason = type(change) == "table" and change.reason or nil
    local kind = reason and labels[reason.label]
    local money = kind and change.attributeChange and tonumber(change.attributeChange.money)
    if money then
      found[#found + 1] = {t = tonumber(change.time) or 0, kind = kind, amount = math.floor(math.abs(money) + 0.5), backfilled = true}
    end
  end
  if #found == 0 then return end
  local totals = financeTotals(state)
  for _, row in ipairs(found) do
    if row.kind == "collect" then totals.collected = totals.collected + row.amount
    elseif row.kind == "order" then totals.supplies = totals.supplies + row.amount
    else totals.upgrades = totals.upgrades + row.amount end
  end
  -- older rows go before anything recorded live, keeping the newest HISTORY_LIMIT
  local merged = {}
  for _, row in ipairs(found) do merged[#merged + 1] = row end
  for _, row in ipairs(state.financeHistory or {}) do merged[#merged + 1] = row end
  while #merged > HISTORY_LIMIT do table.remove(merged, 1) end
  state.financeHistory = merged
end

-- Run the one-time backfill before this module adds anything to the money log or the history itself,
-- so no event is counted twice.
local function ensureFinanceBackfill(state)
  if not state or state.financeBackfilled then return end
  local sharesSupply = 0
  for _, other in pairs(properties) do
    if other.archetypeId == state.archetypeId then sharesSupply = sharesSupply + 1 end
  end
  backfillFinanceHistory(state, businessName(state), sharesSupply <= 1)
end

local function ensureProperty(id)
  id = tostring(id)
  if properties[id] then return properties[id] end
  local facility = currentFacility(id)
  properties[id] = normalizeState(id, {
    archetypeId = facility and facility.archetypeId or "miniMart",
    mapId = facility and facility.mapId or (getCurrentLevelIdentifier and getCurrentLevelIdentifier()) or nil,
    supplierFacilityId = facility and facility.supplierFacilityId,
    supplierParkingSpotName = facility and facility.supplierParkingSpotName,
    receivingFacilityId = facility and facility.receivingFacilityId,
    receivingParkingSpotName = facility and facility.receivingParkingSpotName,
    outOfStockNotified = true,
  })
  return properties[id]
end

local function isCurrentMap(record)
  return record and record.mapId == (getCurrentLevelIdentifier and getCurrentLevelIdentifier())
end

local function getOwnedStates(archetypeId, allMaps)
  local result = {}
  for id, state in pairs(properties) do
    if owned(id) and (allMaps or isCurrentMap(state)) and (not archetypeId or state.archetypeId == archetypeId) then
      result[#result + 1] = state
    end
  end
  return result
end

local function reservationCount(archetypeId, status)
  local count = 0
  for _, reservation in pairs(reservations) do
    if isCurrentMap(reservation) and (not archetypeId or reservation.archetypeId == archetypeId) and (not status or reservation.status == status) then
      count = count + 1
    end
  end
  return count
end

local function chainTotals(archetypeId)
  local capacity, stored = 0, 0
  for _, state in ipairs(getOwnedStates(archetypeId)) do
    capacity = capacity + getCapacity(state)
    stored = stored + state.stock
  end
  local reserved = reservationCount(archetypeId)
  return capacity, stored, reserved
end

local function hasWholesale(archetypeId)
  for _, state in ipairs(getOwnedStates(archetypeId)) do
    if state.wholesaleOwned then return true end
  end
  return false
end

local function unitCost(archetypeId)
  local archetype = archetypes[archetypeId]
  if not archetype then return 0 end
  return indexed(hasWholesale(archetypeId) and archetype.wholesaleUnitCost or archetype.unitCost)
end

local function getSourceLocation(state)
  if not isCurrentMap(state) then return nil end
  local generator = career_modules_delivery_generator
  local fac = generator and generator.getFacilityById(state.supplierFacilityId)
  local ap = fac and fac.accessPointsByName and fac.accessPointsByName[state.supplierParkingSpotName]
  return ap and {type = "facilityParkingspot", facId = fac.id, psPath = ap.psPath} or nil
end

local function getDestinationLocations(archetypeId)
  local result = {}
  local generator = career_modules_delivery_generator
  if not generator then return result end
  for _, state in ipairs(getOwnedStates(archetypeId)) do
    local fac = state.receivingFacilityId and generator.getFacilityById(state.receivingFacilityId)
    local ap = fac and fac.accessPointsByName and fac.accessPointsByName[state.receivingParkingSpotName]
    if ap then
      result[#result + 1] = {type = "facilityParkingspot", facId = fac.id, psPath = ap.psPath}
    end
  end
  return result
end

local function getReservationForCargo(cargo)
  local id = cargo and cargo.data and cargo.data.passiveBusinessSupplyReservationId
  return id and reservations[tostring(id)] or nil
end

local function getSupplyRouteDestination(cargo)
  local reservation = getReservationForCargo(cargo)
  local propertyId = reservation and reservation.orderedByPropertyId
  local state = propertyId and properties[tostring(propertyId)]
  local generator = career_modules_delivery_generator
  if not isCurrentMap(state) or not isCurrentMap(reservation) or not owned(state.id) or state.archetypeId ~= reservation.archetypeId or not generator then return nil end
  local fac = state.receivingFacilityId and generator.getFacilityById(state.receivingFacilityId)
  local ap = fac and fac.accessPointsByName and fac.accessPointsByName[state.receivingParkingSpotName]
  return ap and {type = "facilityParkingspot", facId = fac.id, psPath = ap.psPath} or nil
end
M.getSupplyRouteDestination = getSupplyRouteDestination

local function returnCargoToSupplier(cargo, forfeited)
  local reservation = getReservationForCargo(cargo)
  if not reservation then return false end
  if forfeited then
    reservations[reservation.id] = nil
  else
    reservation.status = "available"
    reservation.cargoId = nil
  end
  if cargo and cargo.id and career_modules_delivery_parcelManager then
    career_modules_delivery_parcelManager.changeCargoLocation(cargo.id, {type = "deleted"})
  end
  return true
end

local function returnAllCargoToSuppliers()
  if not career_modules_delivery_parcelManager then return end
  local cargoList = career_modules_delivery_parcelManager.getAllCargoCustomFilter(function(cargo)
    return cargo.data and cargo.data.passiveBusinessSupplyReservationId ~= nil
  end) or {}
  for _, cargo in ipairs(cargoList) do returnCargoToSupplier(cargo, false) end
  if career_modules_delivery_general then
    career_modules_delivery_general.requestUpdateContainerWeights()
  end
end

local function propertyForLocation(location, archetypeId)
  if not location then return nil end
  for _, state in ipairs(getOwnedStates(archetypeId)) do
    if state.receivingFacilityId == location.facId then
      return state
    end
  end
  return nil
end

local function canDeliverSupplyCargo(cargo, location)
  local reservation = getReservationForCargo(cargo)
  if not isCurrentMap(reservation) then return false end
  local state = propertyForLocation(location, reservation.archetypeId)
  return state ~= nil and state.stock < getCapacity(state)
end

local function deliverSupplyCargo(cargo, location)
  local reservation = getReservationForCargo(cargo)
  if not isCurrentMap(reservation) then return false end
  local state = propertyForLocation(location, reservation.archetypeId)
  if not state or state.stock >= getCapacity(state) then return false end
  state.stock = state.stock + 1
  state.outOfStockNotified = false
  reservations[reservation.id] = nil
  return true
end

local function ensureTabsRegistered()
  if not career_modules_business_businessTabRegistry then return end
  if #career_modules_business_businessTabRegistry.getTabs("passiveBusiness") > 0 then return end
  career_modules_business_businessTabRegistry.registerTab("passiveBusiness", {
    id = "dashboard",
    label = "Dashboard",
    icon = '<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M8 17v-5M12 17V7M16 17v-8"/>',
    component = "PassiveBusinessDashboard",
    section = "BUSINESS",
    order = 1,
  })
end

local function supplierFacilityInfo(facId)
  local gen = career_modules_delivery_generator
  local fac = gen and gen.getFacilityById and facId and gen.getFacilityById(facId)
  return fac and fac.name or "Business supplier", fac and fac.preview or nil
end

local function getDashboardData(id)
  id = tostring(id)
  if not owned(id) then return {success = false, message = "This property is not owned."} end
  local state = ensureProperty(id)
  if not isCurrentMap(state) then return {success = false, message = "Visit this property's map to manage it."} end
  local archetype = getArchetype(state)
  if not archetype then return {success = false, message = "Passive business archetype is missing."} end
  local capacity = getCapacity(state)
  local nextCost = archetype.storageUpgradeCosts[state.storageLevel]
  local nextCapacity = archetype.storageCapacities[state.storageLevel + 1]
  local chainCapacity, chainStored, chainReserved = chainTotals(state.archetypeId)
  local chainFree = math.max(0, chainCapacity - chainStored - chainReserved)
  local price = unitCost(state.archetypeId)
  local revenue = indexed(archetype.unitRevenue)
  local baseCost = indexed(archetype.unitCost)
  local wholesaleCost = indexed(archetype.wholesaleUnitCost)
  local currentProfit = math.max(0, revenue - price)
  local baseProfitPerHour = archetype.cycleSeconds > 0 and math.floor((revenue - baseCost) * 3600 / archetype.cycleSeconds + 0.5) or 0
  local wholesaleProfitPerHour = archetype.cycleSeconds > 0 and math.floor((revenue - wholesaleCost) * 3600 / archetype.cycleSeconds + 0.5) or 0
  local wholesaleImprovementPerHour = math.max(0, wholesaleProfitPerHour - baseProfitPerHour)
  local wholesaleUpgradeCost = indexed(archetype.wholesaleUpgradeCost)
  local money = career_modules_playerAttributes.getAttributeValue("money") or 0
  local affordable = price > 0 and math.floor(money / price) or 0
  return {
    success = true,
    businessId = id,
    businessName = (currentFacility(id) and currentFacility(id).name) or archetype.name,
    supplierName = supplierFacilityInfo(state.supplierFacilityId),
    supplyName = archetype.supplyName,
    supplyType = archetype.supplyType,
    supplySlots = archetype.supplySlots,
    stock = state.stock,
    capacity = capacity,
    operating = state.operating,
    storageLevel = state.storageLevel,
    maxStorageLevel = #archetype.storageCapacities,
    remainingRuntimeSeconds = state.stock > 0
      and ((state.stock - 1) * archetype.cycleSeconds + (archetype.cycleSeconds - state.cycleProgress)) or 0,
    cycleSeconds = archetype.cycleSeconds,
    cycleProgress = state.cycleProgress,
    cycleRemainingSeconds = state.stock > 0 and math.max(0, archetype.cycleSeconds - state.cycleProgress) or 0,
    uncollectedEarnings = state.uncollectedEarnings,
    unitRevenue = revenue,
    unitCost = unitCost(state.archetypeId),
    netProfitPerPallet = currentProfit,
    netProfitPerHour = archetype.cycleSeconds > 0 and math.floor(currentProfit * 3600 / archetype.cycleSeconds + 0.5) or 0,
    baseNetProfitPerHour = baseProfitPerHour,
    wholesaleNetProfitPerHour = wholesaleProfitPerHour,
    wholesaleImprovementPerHour = wholesaleImprovementPerHour,
    wholesalePaybackSeconds = wholesaleImprovementPerHour > 0 and math.floor(wholesaleUpgradeCost / wholesaleImprovementPerHour * 3600 + 0.5) or 0,
    nextStorageCapacity = nextCapacity,
    nextStorageRuntimeAddedSeconds = nextCapacity and math.max(0, nextCapacity - capacity) * archetype.cycleSeconds or 0,
    nextStorageUpgradeCost = nextCost and indexed(nextCost) or nil,
    wholesaleOwned = state.wholesaleOwned,
    wholesaleUpgradeCost = state.wholesaleOwned and nil or wholesaleUpgradeCost,
    baseUnitCost = baseCost,
    wholesaleUnitCost = wholesaleCost,
    chainCapacity = chainCapacity,
    chainStored = chainStored,
    chainReserved = chainReserved,
    chainFree = chainFree,
    paidAtSupplier = reservationCount(state.archetypeId, "available"),
    inTransit = reservationCount(state.archetypeId, "inTransit"),
    affordableQuantity = affordable,
    maximumOrder = math.min(chainFree, affordable),
  }
end

-- History newest first plus lifetime totals for the Finances section.
local function getFinanceData(id)
  id = tostring(id)
  if not owned(id) then return {success = false, message = "This property is not owned."} end
  local state = ensureProperty(id)
  ensureFinanceBackfill(state)
  local totals = financeTotals(state)
  local history, since = {}, nil
  local rows = state.financeHistory or {}
  for i = #rows, 1, -1 do
    local row = rows[i]
    history[#history + 1] = {
      time = row.t,
      kind = row.kind,
      amount = row.amount,
      quantity = row.qty,
      income = row.kind == "collect",
    }
    if row.t and row.t > 0 and (not since or row.t < since) then since = row.t end
  end
  return {
    success = true,
    history = history,
    since = since,
    now = os.time(),
    totals = {
      collected = totals.collected,
      supplies = totals.supplies,
      upgrades = totals.upgrades,
      net = totals.collected - totals.supplies - totals.upgrades,
      palletsSold = totals.palletsSold,
      salesRevenue = totals.salesRevenue,
    },
  }
end

local function requirePhysicalManagement(id)
  id = tostring(id)
  return activeBusinessId == id and currentFacility(id) ~= nil and owned(id) and isCurrentMap(properties[id])
end

local function collectEarnings(id)
  id = tostring(id)
  if not requirePhysicalManagement(id) then return {success = false, message = "Visit this property to collect earnings."} end
  local state = ensureProperty(id)
  local amount = state.uncollectedEarnings
  if amount <= 0 then return {success = false, message = "There are no earnings to collect."} end
  ensureFinanceBackfill(state)
  state.uncollectedEarnings = 0
  career_modules_payment.reward({money = {amount = amount}}, {label = "Collected " .. businessName(state) .. " earnings"}, true)
  recordFinance(state, "collect", amount)
  career_saveSystem.saveCurrent()
  return {success = true, amount = amount, dashboard = getDashboardData(id)}
end

local function setOperating(id, operating)
  id = tostring(id)
  if not requirePhysicalManagement(id) then return {success = false, message = "Visit this property to change store operations."} end
  local state = ensureProperty(id)
  state.operating = operating == true
  career_saveSystem.saveCurrent()
  return {
    success = true,
    message = state.operating and "The business is open and processing stock." or "The business is closed. Stock processing is paused.",
    dashboard = getDashboardData(id),
  }
end

local function purchaseStorageUpgrade(id)
  id = tostring(id)
  if not requirePhysicalManagement(id) then return {success = false, message = "Visit this property to purchase upgrades."} end
  local state = ensureProperty(id)
  local archetype = getArchetype(state)
  local baseCost = archetype and archetype.storageUpgradeCosts[state.storageLevel]
  if not baseCost then return {success = false, message = "Storage is already at its maximum."} end
  local cost = indexed(baseCost)
  ensureFinanceBackfill(state)
  if not career_modules_payment.pay({money = {amount = cost, canBeNegative = false}}, {label = businessName(state) .. " storage upgrade"}) then
    return {success = false, message = "You cannot afford this storage upgrade."}
  end
  recordFinance(state, "storage", cost)
  state.storageLevel = state.storageLevel + 1
  career_saveSystem.saveCurrent()
  return {success = true, dashboard = getDashboardData(id)}
end

local function purchaseWholesale(id)
  id = tostring(id)
  if not requirePhysicalManagement(id) then return {success = false, message = "Visit this property to purchase upgrades."} end
  local state = ensureProperty(id)
  if state.wholesaleOwned then return {success = false, message = "Wholesale purchasing is already unlocked."} end
  local cost = indexed(getArchetype(state).wholesaleUpgradeCost)
  ensureFinanceBackfill(state)
  if not career_modules_payment.pay({money = {amount = cost, canBeNegative = false}}, {label = businessName(state) .. " wholesale agreement"}) then
    return {success = false, message = "You cannot afford the wholesale agreement."}
  end
  recordFinance(state, "wholesale", cost)
  state.wholesaleOwned = true
  career_saveSystem.saveCurrent()
  return {success = true, dashboard = getDashboardData(id)}
end


-- Preview image of a spawned vehicle (its current config), for the pickup UI.
local function vehicleThumb(vehId)
  if not vehId then return nil end
  -- Player-owned vehicles carry their own thumbnail (their real parts/paint); the stock config
  -- preview is only a fallback for vehicles outside the inventory.
  local inv = career_modules_inventory
  if inv and inv.getInventoryIdFromVehicleId and inv.getVehicleThumbnail then
    local invId = inv.getInventoryIdFromVehicleId(vehId)
    if invId then
      -- no captured picture yet: render one now and push the screen data again when it lands
      if inv.ensureVehicleThumbnail then
        inv.ensureVehicleThumbnail(invId, function() if M.requestSupplyPickupData then M.requestSupplyPickupData() end end)
      end
      local ok, thumb = pcall(inv.getVehicleThumbnail, invId)
      if ok and type(thumb) == "string" and thumb ~= "" then return thumb end
    end
  end
  if not core_vehicles or not core_vehicles.getVehicleDetails then return nil end
  local ok, d = pcall(core_vehicles.getVehicleDetails, vehId)
  if not ok or type(d) ~= "table" then return nil end
  local cfg = d.configs
  return type(cfg) == "table" and cfg.preview or nil
end
local function formatEquipment(containers)
  local equipment, palletCapacity = {}, 0
  for _, con in ipairs(containers or {}) do
    local supportsParcel = con.cargoTypesLookup and con.cargoTypesLookup.parcel
    local free = math.max(0, tonumber(con.freeCargoSlots) or 0)
    local pallets = supportsParcel and math.floor(free / 128) or 0
    palletCapacity = palletCapacity + pallets
    equipment[#equipment + 1] = {
      vehId = con.vehId,
      containerId = con.containerId,
      vehicleName = con.vehName or "Vehicle",
      containerName = con.name or "Cargo container",
      thumbnail = vehicleThumb(con.vehId),
      used = math.max(0, tonumber(con.usedCargoSlots) or 0),
      capacity = math.max(0, tonumber(con.totalCargoSlots) or 0),
      free = free,
      pallets = pallets,
      eligible = pallets > 0,
      reason = supportsParcel and (pallets > 0 and nil or "Less than 128 slots free") or "Parcel freight is not supported",
    }
  end
  return equipment, palletCapacity
end

local function sourceStateAt(facId, psPath)
  for _, state in ipairs(getOwnedStates()) do
    local source = getSourceLocation(state)
    if source and source.facId == facId and source.psPath == psPath then return state end
  end
  return nil
end

local function reservationAtSource(reservation, facId, psPath)
  if not isCurrentMap(reservation) then return false end
  if not facId then return true end
  if reservation.supplierFacilityId ~= facId then return false end
  if reservation.supplierParkingSpotName == psPath then return true end
  local states = getOwnedStates(reservation.archetypeId)
  for _, state in ipairs(states) do
    local source = getSourceLocation(state)
    if source and source.facId == facId and source.psPath == psPath then return true end
  end
  return false
end

local function procurementData(containers, facId, psPath)
  local capacity, stored, reserved = chainTotals()
  local availablePaid = 0
  for _, reservation in pairs(reservations) do
    if reservation.status == "available" and reservationAtSource(reservation, facId, psPath) then availablePaid = availablePaid + 1 end
  end
  local equipment, vehicleCapacity = formatEquipment(containers)
  local maximum = math.min(vehicleCapacity, availablePaid)
  local facilityName, facilityPreview = supplierFacilityInfo(facId)
  return {
    facilityName = facilityName,
    facilityPreview = facilityPreview,
    available = #getOwnedStates() > 0,
    reason = capacity <= 0 and "Own a passive business before collecting supplies." or nil,
    supplyName = "Business Supplies",
    slotsPerPallet = 128,
    unitCost = 0,
    wholesaleActive = false,
    chainCapacity = capacity,
    chainStored = stored,
    chainReserved = reserved,
    chainFree = math.max(0, capacity - stored - reserved),
    paidAtSupplier = availablePaid,
    vehicleCapacity = vehicleCapacity,
    maximumLoad = maximum,
    equipment = equipment,
    loading = supplyLoadInProgress,
  }
end

local function requestSupplyPickupData()
  if not supplyPickupOpen or not career_modules_delivery_general then return false end
  career_modules_delivery_general.getNearbyVehicleCargoContainers(function(containers)
    if supplyPickupOpen and guihooks then
      guihooks.trigger("passiveBusinessSupplyPickupData", procurementData(containers, supplyPickupFacId, supplyPickupPsPath))
    end
  end)
  return true
end

local function getPaidSupplyPickupLocations()
  local locations, seen = {}, {}
  if reservationCount(nil, "available") <= 0 then return locations end
  for _, state in ipairs(getOwnedStates()) do
    local source = getSourceLocation(state)
    if source and source.facId and source.psPath then
      local key = source.facId .. "|" .. source.psPath
      if not seen[key] then
        seen[key] = true
        locations[#locations + 1] = source
      end
    end
  end
  return locations
end

local function requestSupplyWorldMarkers()
  local general = career_modules_delivery_general
  if general and general.requestDeliveryPoiRefresh then
    general.requestDeliveryPoiRefresh(true)
  end
end

local function hasPaidSupplyAt(facId, psPath)
  for _, reservation in pairs(reservations) do
    if reservation.status == "available" and reservationAtSource(reservation, facId, psPath) then
      return true
    end
  end
  return false
end

local function enterSupplyPickupScreen(facId, psPath)
  if not sourceStateAt(facId, psPath) then
    notify("error", "Business Supplies", "Park at the supplier selected by an owned business and choose Pickup business supplies.")
    return false
  end
  supplyPickupOpen = true
  supplyPickupFacId, supplyPickupPsPath = facId, psPath
  supplyLoadInProgress = false
  gameplay_markerInteraction.closeViewDetailPrompt(true)
  simTimeAuthority.pause(true)
  guihooks.trigger("ChangeState", {state = "career.passiveBusinessSupplyPickup"})
  return true
end

local function closeSupplyPickupScreen()
  supplyPickupOpen = false
  supplyPickupFacId, supplyPickupPsPath = nil, nil
  supplyLoadInProgress = false
  simTimeAuthority.pause(false)
  guihooks.trigger("ChangeState", {state = "play"})
  gameplay_markerInteraction.setForceReevaluateOpenPrompt()
end

local function onSupplyPickupRouteLeave()
  supplyPickupOpen = false
  supplyPickupFacId, supplyPickupPsPath = nil, nil
  supplyLoadInProgress = false
  simTimeAuthority.pause(false)
end

local function setSupplierRoute(id, showMessage)
  id = tostring(id)
  if not owned(id) then return {success = false, message = "This property is not owned."} end
  local state = ensureProperty(id)
  if not isCurrentMap(state) then return {success = false, message = "Travel to this property's map to collect supplies."} end
  if not hasPaidSupplyAt(state.supplierFacilityId, state.supplierParkingSpotName) then
    return {success = false, message = "There is no paid order waiting at this supplier."}
  end
  local source = getSourceLocation(state)
  local toPos = source and career_modules_delivery_generator
    and career_modules_delivery_generator.getLocationCoordinates(source) or nil
  if not toPos or not core_groundMarkers or not core_groundMarkers.setPath then
    return {success = false, message = "The business supplier pickup location is unavailable."}
  end
  if freeroam_bigMapMode and freeroam_bigMapMode.setNavFocus then freeroam_bigMapMode.setNavFocus(toPos) end
  core_groundMarkers.setPath({toPos}, {clearPathOnReachingTarget = false})
  local message = "Route set to " .. supplierFacilityInfo(state.supplierFacilityId) .. ". Park there and choose Pickup business supplies."
  if showMessage ~= false then notify("info", supplyName(state) .. " pickup marked", message) end
  requestSupplyWorldMarkers()
  return {success = true, message = message}
end

local function newReservation(state, cost)
  local id = string.format("passive-supply-%d", nextReservationId)
  nextReservationId = nextReservationId + 1
  local reservation = {
    id = id,
    archetypeId = state.archetypeId,
    supplyType = getArchetype(state).supplyType,
    supplyName = getArchetype(state).supplyName,
    supplyTemplateId = getArchetype(state).supplyTemplateId,
    supplySlots = getArchetype(state).supplySlots,
    supplierFacilityId = state.supplierFacilityId,
    supplierParkingSpotName = state.supplierParkingSpotName,
    paidCost = cost,
    orderedByPropertyId = state.id,
    mapId = state.mapId,
    status = "available",
  }
  reservations[id] = reservation
  return reservation
end

local function availableReservations(archetypeId, facId, psPath)
  local result = {}
  for _, reservation in pairs(reservations) do
    if (not archetypeId or reservation.archetypeId == archetypeId)
      and reservation.status == "available"
      and reservationAtSource(reservation, facId, psPath) then
      result[#result + 1] = reservation
    end
  end
  table.sort(result, function(a, b) return a.id < b.id end)
  return result
end

local function orderSupply(id, quantity)
  id = tostring(id)
  if not requirePhysicalManagement(id) then return {success = false, message = "Visit this property to order stock."} end
  local state = ensureProperty(id)
  if not getSourceLocation(state) then return {success = false, message = "The business supplier pickup location is unavailable."} end
  local requested = math.floor(tonumber(quantity) or 0)
  if requested <= 0 then return {success = false, message = "Choose at least one pallet."} end

  local capacity, stored, reserved = chainTotals(state.archetypeId)
  local freeChain = math.max(0, capacity - stored - reserved)
  local price = unitCost(state.archetypeId)
  local money = career_modules_playerAttributes.getAttributeValue("money") or 0
  local affordable = price > 0 and math.floor(money / price) or 0
  local maximum = math.min(freeChain, affordable)
  if requested > maximum then
    return {
      success = false,
      message = maximum > 0
        and string.format("You can order at most %d pallet%s.", maximum, maximum == 1 and "" or "s")
        or "No additional pallets can be ordered with the current wallet and chain capacity.",
    }
  end

  local total = requested * price
  ensureFinanceBackfill(state)
  if not career_modules_payment.pay({money = {amount = total, canBeNegative = false}}, {label = "Ordered " .. supplyName(state)}) then
    return {success = false, message = "You cannot afford that order."}
  end
  recordFinance(state, "order", total, requested)
  for _ = 1, requested do newReservation(state, price) end
  career_saveSystem.saveCurrent()
  requestSupplyWorldMarkers()
  local routeResult = setSupplierRoute(id, true)
  return {
    success = true,
    amount = total,
    quantity = requested,
    routeSet = routeResult.success == true,
    message = string.format("Ordered %d pallet%s for $%d. Pick up the paid order at %s.", requested, requested == 1 and "" or "s", total, supplierFacilityInfo(state.supplierFacilityId)),
    dashboard = getDashboardData(id),
  }
end

local function loadSupply(quantity)
  if not supplyPickupOpen or supplyLoadInProgress then return false end
  supplyLoadInProgress = true
  career_modules_delivery_general.getNearbyVehicleCargoContainers(function(containers)
    local limits = procurementData(containers, supplyPickupFacId, supplyPickupPsPath)
    local requested = math.max(0, math.floor(tonumber(quantity) or 0))
    local count = math.min(requested, limits.maximumLoad)
    if count <= 0 then
      supplyLoadInProgress = false
      guihooks.trigger("passiveBusinessSupplyPickupResult", {success = false, message = "No paid order can be loaded. Order stock at an owned business, then bring at least 128 slots of nearby freight capacity."})
      requestSupplyPickupData()
      return
    end

    local sourceState = sourceStateAt(supplyPickupFacId, supplyPickupPsPath)
    local source = sourceState and getSourceLocation(sourceState)
    if not source then
      supplyLoadInProgress = false
      guihooks.trigger("passiveBusinessSupplyPickupResult", {success = false, message = "The supplier is unavailable."})
      requestSupplyPickupData()
      return
    end

    local paid = availableReservations(nil, supplyPickupFacId, supplyPickupPsPath)
    local toLoad = {}
    for _, reservation in ipairs(paid) do
      if #toLoad >= count then break end
      local destinations = getDestinationLocations(reservation.archetypeId)
      if #destinations > 0 then
        toLoad[#toLoad + 1] = {reservation = reservation, destinations = destinations}
      end
    end
    if #toLoad == 0 then
      supplyLoadInProgress = false
      guihooks.trigger("passiveBusinessSupplyPickupResult", {success = false, message = "No receiving point is available for the paid business supplies."})
      requestSupplyPickupData()
      return
    end

    -- Starting delivery mode can trigger a career save. Do it before creating
    -- physical supply cargo so the save-safety hook cannot immediately return
    -- the newly loaded pallets to the supplier.
    if not career_modules_delivery_general.isDeliveryModeActive() then
      career_modules_delivery_general.startDeliveryMode()
    end

    local eligible = {}
    for _, con in ipairs(containers or {}) do
      local palletSpace = con.cargoTypesLookup and con.cargoTypesLookup.parcel and math.floor(math.max(0, con.freeCargoSlots or 0) / 128) or 0
      if palletSpace > 0 then eligible[#eligible + 1] = {container = con, pallets = palletSpace} end
    end
    local loaded = 0
    for _, slot in ipairs(eligible) do
      while slot.pallets > 0 and loaded < #toLoad do
        local loadItem = toLoad[loaded + 1]
        local reservation = loadItem.reservation
        local cargo = career_modules_delivery_generator.addPassiveBusinessSupplyCargo(slot.container, reservation, source, loadItem.destinations)
        if not cargo then break end
        reservation.status = "inTransit"
        reservation.cargoId = cargo.id
        loaded = loaded + 1
        slot.pallets = slot.pallets - 1
      end
    end
    if loaded > 0 then
      career_modules_delivery_parcelManager.applyTransientMoves(source)
      career_modules_delivery_general.requestUpdateContainerWeights()
      if career_modules_delivery_tasklist and career_modules_delivery_tasklist.sendCargoToTasklist then career_modules_delivery_tasklist.sendCargoToTasklist() end
      if career_modules_delivery_cargoScreen and career_modules_delivery_cargoScreen.onCargoPickedUp then
        career_modules_delivery_cargoScreen.onCargoPickedUp(true)
      end
      local _, currentSavePath = career_saveSystem.getCurrentProfile()
      saveData(currentSavePath)
      guihooks.trigger("passiveBusinessSupplyPickupResult", {success = true, message = string.format("Loaded %d business supply pallet%s.", loaded, loaded == 1 and "" or "s")})
      closeSupplyPickupScreen()
    else
      supplyLoadInProgress = false
      guihooks.trigger("passiveBusinessSupplyPickupResult", {success = false, message = "No compatible 128-slot space was available."})
      requestSupplyPickupData()
    end
  end)
  return true
end

local function getSupplyOfferCard(facId, psPath, containers)
  local sourceState = sourceStateAt(facId, psPath)
  local source = sourceState and getSourceLocation(sourceState)
  if not source then return nil end
  local distance = math.huge
  for archetypeId in pairs(archetypes) do
    for _, destination in ipairs(getDestinationLocations(archetypeId)) do
      local routeDistance = career_modules_delivery_generator.getDistanceBetweenFacilities(source, destination)
      if routeDistance then distance = math.min(distance, routeDistance) end
    end
  end
  if distance == math.huge then distance = 0 end
  local limits = procurementData(containers, facId, psPath)
  local enabled = limits.maximumLoad > 0
  local reason
  if limits.paidAtSupplier <= 0 then reason = "Order and pay for stock at an owned business first."
  elseif limits.vehicleCapacity <= 0 then reason = "Bring a freight container with at least 128 free parcel slots."
  end
  return {
    id = "passiveBusinessSupplies",
    cardType = "passiveBusinessSupplyOffer",
    isFacilityCard = true,
    name = "Business Supplies Pickup",
    type = "parcel",
    rewardMoney = 0,
    destinationName = "Owned Business",
    destinationNameLong = "A compatible owned business with free storage",
    distance = distance,
    slots = 128,
    enabled = enabled,
    disableReason = not enabled and {type = "noSpace", label = reason or "Supplies are unavailable."} or nil,
    modifiers = {},
    bigMapIds = {},
    supplyLimits = limits,
    sourceFacId = facId,
    origin = {facId = facId, psPath = psPath},
  }
end

local function getUIData(id)
  ensureTabsRegistered()
  local dashboard = getDashboardData(id)
  dashboard.businessId = tostring(id)
  dashboard.businessType = "passiveBusiness"
  dashboard.businessName = dashboard.businessName or "Business"
  dashboard.tabs = career_modules_business_businessTabRegistry.getTabs("passiveBusiness")
  dashboard.showBusinessAccount = false
  dashboard.playerInZone = currentFacility(id) ~= nil
  return dashboard
end

local function openMenu(id)
  id = tostring(id)
  activeBusinessId = id
  ensureProperty(id)
  ensureTabsRegistered()
  extensions.ui_router.navigate("business-computer", {businessType = "passiveBusiness", businessId = id})
end

local function closeManagementSession(id)
  if id == nil or activeBusinessId == tostring(id) then activeBusinessId = nil end
  return true
end

local function requestSaleQuote(id)
  id = tostring(id)
  if not requirePhysicalManagement(id) then return {success = false, message = "Visit this property to sell it."} end
  return career_modules_business_businessManager.requestBusinessSaleData("passiveBusiness", id)
end

local function sellStore(id)
  id = tostring(id)
  if not requirePhysicalManagement(id) then return {success = false, message = "Visit this property to sell it."} end
  return career_modules_business_businessManager.sellBusiness("passiveBusiness", id)
end

local function resetBusinessForSale(id)
  id = tostring(id)
  local state = properties[id]
  local archetypeId = state and state.archetypeId or "miniMart"
  properties[id] = nil
  local noRemainingProperties = #getOwnedStates(archetypeId) == 0
  local forfeited = {}
  for reservationId, reservation in pairs(reservations) do
    if isCurrentMap(reservation) and reservation.archetypeId == archetypeId
      and (reservation.orderedByPropertyId == id or (reservation.orderedByPropertyId == nil and noRemainingProperties)) then
      forfeited[reservationId] = true
    end
  end
  if career_modules_delivery_parcelManager then
    local cargoList = career_modules_delivery_parcelManager.getAllCargoCustomFilter(function(cargo)
      local reservation = getReservationForCargo(cargo)
      return reservation and forfeited[reservation.id] == true
    end) or {}
    for _, cargo in ipairs(cargoList) do returnCargoToSupplier(cargo, true) end
  end
  for reservationId in pairs(forfeited) do reservations[reservationId] = nil end
  if activeBusinessId == id then activeBusinessId = nil end
end

local businessObject = {
  businessType = "passiveBusiness",
  features = {
    bankAccount = false,
    skillTrees = false,
    inventory = false,
    personalVehicle = false,
    finances = false,
    xpSystem = false,
    operatingCosts = false,
  },
  getUIData = getUIData,
  resetBusinessForSale = resetBusinessForSale,
}

local function onCareerActivated()
  loadArchetypes()
  local _, currentSavePath = career_saveSystem.getCurrentProfile()
  if refundPaidForSavePath ~= currentSavePath then
    refundPaidThisLoad = false
    refundPaidForSavePath = currentSavePath
  end
  local balanceRefund = loadData()
  career_modules_business_businessManager.registerBusiness("passiveBusiness", businessObject)
  career_modules_business_businessManager.registerBusinessCallback("passiveBusiness", {
    onPurchase = function(id) ensureProperty(id) end,
    onMenuOpen = openMenu,
  })
  ensureTabsRegistered()
  if balanceRefund > 0 then
    if refundPaidThisLoad then
      saveVersion = SAVE_VERSION
    else
      local refunded = career_modules_payment.reward({money = {amount = balanceRefund}},
        {label = "Small-business balance refund", description = "Refunded the reduced cost of previously purchased storage and wholesale upgrades."}, true)
      if refunded ~= false then
        refundPaidThisLoad = true
        saveVersion = SAVE_VERSION
        career_saveSystem.saveCurrent()
        notify("success", "Small-business balance refund", string.format("Refunded $%d for repriced storage and wholesale upgrades.", balanceRefund))
      else
        notify("error", "Small-business balance refund", "The refund could not be applied and will be retried next time this career loads.")
      end
    end
  elseif saveVersion < SAVE_VERSION then
    saveVersion = SAVE_VERSION
    saveData(select(2, career_saveSystem.getCurrentProfile()))
  end
end

local function advanceState(state, archetype, elapsed, revenuePerCycle)
  if not archetype or state.stock <= 0 or elapsed <= 0 then return 0 end
  state.cycleProgress = state.cycleProgress + elapsed
  local processed = 0
  while state.stock > 0 and state.cycleProgress >= archetype.cycleSeconds do
    state.cycleProgress = state.cycleProgress - archetype.cycleSeconds
    state.stock = state.stock - 1
    state.uncollectedEarnings = state.uncollectedEarnings + revenuePerCycle
    processed = processed + 1
  end
  if processed > 0 then
    local totals = financeTotals(state)
    totals.palletsSold = totals.palletsSold + processed
    totals.salesRevenue = totals.salesRevenue + processed * revenuePerCycle
  end
  if state.stock <= 0 then state.cycleProgress = 0 end
  return processed
end

local function onUpdate(dtReal, dtSim)
  if not (career_career and career_career.isActive()) then return end
  local elapsed = math.max(0, tonumber(dtSim) or 0)
  if elapsed <= 0 then return end
  for _, state in ipairs(getOwnedStates(nil, true)) do
    local archetype = getArchetype(state)
    if archetype and state.operating and state.stock > 0 then
      advanceState(state, archetype, elapsed, indexed(archetype.unitRevenue))
      if state.stock <= 0 then
        if not state.outOfStockNotified then
          state.outOfStockNotified = true
          notify("warning", businessName(state) .. " out of stock", "Production has stopped. Order more " .. supplyName(state) .. ", then collect it from the property's supplier.")
        end
      end
    end
  end
end

local function onSaveCurrentProfile(currentSavePath)
  -- Do not mutate live cargo during an autosave. Saved in-transit reservations
  -- are normalized back to supplier-ready reservations by loadData(), while
  -- mission/map teardown uses onClientEndMission below to return them now.
  saveData(currentSavePath)
end

M.onCareerActivated = onCareerActivated
M.onUpdate = onUpdate
M.onSaveCurrentProfile = onSaveCurrentProfile
M.onClientEndMission = function()
  returnAllCargoToSuppliers()
  activeBusinessId = nil
  supplyPickupOpen = false
  supplyPickupFacId, supplyPickupPsPath = nil, nil
  supplyLoadInProgress = false
end
M.openMenu = openMenu
M.closeManagementSession = closeManagementSession
M.getUIData = getUIData
M.getDashboardData = getDashboardData
M.getFinanceData = getFinanceData
M.collectEarnings = collectEarnings
M.setOperating = setOperating
M.purchaseStorageUpgrade = purchaseStorageUpgrade
M.purchaseWholesale = purchaseWholesale
M.orderSupply = orderSupply
M.setSupplierRoute = setSupplierRoute
M.requestSaleQuote = requestSaleQuote
M.sellStore = sellStore
M.getSupplyOfferCard = getSupplyOfferCard
M.hasPaidSupplyAt = hasPaidSupplyAt
M.getPaidSupplyPickupLocations = getPaidSupplyPickupLocations
M.enterSupplyPickupScreen = enterSupplyPickupScreen
M.requestSupplyPickupData = requestSupplyPickupData
M.loadSupply = loadSupply
M.closeSupplyPickupScreen = closeSupplyPickupScreen
M.onSupplyPickupRouteLeave = onSupplyPickupRouteLeave
M.returnCargoToSupplier = returnCargoToSupplier
M.returnAllCargoToSuppliers = returnAllCargoToSuppliers
M.canDeliverSupplyCargo = canDeliverSupplyCargo
M.deliverSupplyCargo = deliverSupplyCargo
M.isSupplyCargo = function(cargo) return getReservationForCargo(cargo) ~= nil end
M.getChainTotals = chainTotals
M.getSupplyProcurementLimits = procurementData
M.runInvariantTests = function()
  loadArchetypes()
  local failures = {}
  local function check(value, label) if not value then failures[#failures + 1] = label end end
  local archetypeCount = 0
  local profitPerHourByArchetype = {}
  for archetypeId, archetype in pairs(archetypes) do
    archetypeCount = archetypeCount + 1
    local cycle = tonumber(archetype.cycleSeconds) or 0
    local cost = tonumber(archetype.unitCost) or 0
    local revenue = tonumber(archetype.unitRevenue) or 0
    local wholesaleCost = tonumber(archetype.wholesaleUnitCost) or 0
    local baseProfitPerHour = cycle > 0 and ((revenue - cost) * 3600 / cycle) or 0
    local wholesaleProfitPerHour = cycle > 0 and ((revenue - wholesaleCost) * 3600 / cycle) or 0
    local wholesaleGainPerHour = wholesaleProfitPerHour - baseProfitPerHour
    local wholesalePaybackHours = wholesaleGainPerHour > 0
      and ((tonumber(archetype.wholesaleUpgradeCost) or 0) / wholesaleGainPerHour) or 0
    local storageTotal = 0
    for _, upgradeCost in ipairs(archetype.storageUpgradeCosts or {}) do storageTotal = storageTotal + (tonumber(upgradeCost) or 0) end
    local storageCostHours = baseProfitPerHour > 0 and storageTotal / baseProfitPerHour or 0
    profitPerHourByArchetype[archetypeId] = baseProfitPerHour

    check(archetype.supplySlots == 128, archetypeId .. " supply pallet must use 128 slots")
    check(cycle >= 300 and cycle <= 900, archetypeId .. " cycle is outside the five-to-fifteen-minute range")
    check(cost > 0 and revenue > cost, archetypeId .. " base unit economics are invalid")
    check(wholesaleCost > 0 and wholesaleCost < cost, archetypeId .. " wholesale price must discount supplies")
    check(baseProfitPerHour >= 5000 and baseProfitPerHour <= 30000,
      archetypeId .. " base hourly profit is outside the balance range")
    check(wholesaleProfitPerHour > baseProfitPerHour and wholesaleProfitPerHour <= 40000,
      archetypeId .. " wholesale hourly profit is outside the balance range")
    check(wholesalePaybackHours >= 6 and wholesalePaybackHours <= 10,
      archetypeId .. " wholesale upgrade payback is outside the balance range")
    check(storageCostHours >= 4 and storageCostHours <= 6,
      archetypeId .. " total storage upgrade cost is outside the balance range")
    check(type(archetype.storageCapacities) == "table" and #archetype.storageCapacities == 5,
      archetypeId .. " must define five storage levels")
    check(type(archetype.storageUpgradeCosts) == "table" and #archetype.storageUpgradeCosts == 4,
      archetypeId .. " must define four storage upgrade prices")
    for index = 2, #(archetype.storageCapacities or {}) do
      check(archetype.storageCapacities[index] > archetype.storageCapacities[index - 1],
        archetypeId .. " storage capacities must increase")
    end
    for index = 2, #(archetype.storageUpgradeCosts or {}) do
      check(archetype.storageUpgradeCosts[index] > archetype.storageUpgradeCosts[index - 1],
        archetypeId .. " storage upgrade prices must increase")
    end
  end
  check(archetypeCount == 10, "expected ten passive business archetypes")

  local facilityData = jsonReadFile("levels/west_coast_usa/facilities/business.facilities.json") or {}
  local businessCount = 0
  local earlyGameCount = 0
  local priceByArchetype = {}
  for _, facility in ipairs(facilityData.passiveBusinesses or {}) do
    businessCount = businessCount + 1
    local archetypeId = facility.archetypeId
    local price = tonumber(facility.price) or 0
    local profitPerHour = profitPerHourByArchetype[archetypeId] or 0
    local purchasePaybackHours = profitPerHour > 0 and (price / profitPerHour) or 0
    check(archetypes[archetypeId] ~= nil, tostring(facility.id) .. " references a missing archetype")
    if archetypeId == "dinoShop" then
      check(price == 1000000 and math.abs(purchasePaybackHours - 83.333333) < 0.01,
        "Dino Cafe premium bundle base payback must be 83.3 stocked operating hours")
      local a = archetypes.dinoShop
      local wholesalePayback = (price + a.wholesaleUpgradeCost) / ((a.unitRevenue - a.wholesaleUnitCost) * 3600 / a.cycleSeconds)
      check(math.abs(wholesalePayback - 68.266667) < 0.01,
        "Dino Cafe premium bundle wholesale payback must be 68.3 stocked operating hours")
    else
      check(purchasePaybackHours >= 12 and purchasePaybackHours <= 18,
        tostring(facility.id) .. " purchase payback is outside the balance range")
    end
    check(priceByArchetype[archetypeId] == nil or priceByArchetype[archetypeId] == price,
      archetypeId .. " locations must share a purchase price")
    priceByArchetype[archetypeId] = price
    if price <= 110000 then earlyGameCount = earlyGameCount + 1 end
  end
  check(businessCount == 18, "expected eighteen passive business locations")
  check(earlyGameCount >= 11, "most passive business locations must remain early-game purchases")

  local jewelry = archetypes.jewelryStore
  check(jewelry and jewelry.unitCost >= 10000 and jewelry.cycleSeconds == 900
    and (priceByArchetype.jewelryStore or 0) >= 400000,
    "jewelry must retain its high-capital identity at the timer cap")

  local refundState = {archetypeId = "miniMart", storageLevel = 5, wholesaleOwned = true}
  local expectedRefund = 0
  for index = 1, 4 do
    expectedRefund = expectedRefund + indexed(legacyBalance.miniMart.storageUpgradeCosts[index])
      - indexed(archetypes.miniMart.storageUpgradeCosts[index])
  end
  expectedRefund = expectedRefund + indexed(legacyBalance.miniMart.wholesaleUpgradeCost)
    - indexed(archetypes.miniMart.wholesaleUpgradeCost)
  check(balanceRefundForState(refundState) == expectedRefund, "balance refund must return every repriced owned upgrade exactly once")

  local miniMart = archetypes.miniMart
  if miniMart then
    local startingStock = miniMart.storageCapacities[1]
    local simulation = {stock = startingStock, cycleProgress = 0, uncollectedEarnings = 0}
    check(advanceState(simulation, miniMart, miniMart.cycleSeconds - 1, miniMart.unitRevenue) == 0
      and simulation.stock == startingStock and simulation.cycleProgress == miniMart.cycleSeconds - 1,
      "partial cycle timing mismatch")
    check(advanceState(simulation, miniMart, 1, miniMart.unitRevenue) == 1
      and simulation.stock == startingStock - 1 and simulation.uncollectedEarnings == miniMart.unitRevenue,
      "single cycle timing mismatch")
    check(advanceState(simulation, miniMart, (startingStock - 1) * miniMart.cycleSeconds, miniMart.unitRevenue) == startingStock - 1
      and simulation.stock == 0 and simulation.cycleProgress == 0
      and simulation.uncollectedEarnings == startingStock * miniMart.unitRevenue,
      "full starting stock production mismatch")
  end
  return {
    success = #failures == 0,
    failures = failures,
    archetypeCount = archetypeCount,
    businessCount = businessCount,
    earlyGameCount = earlyGameCount
  }
end

return M
