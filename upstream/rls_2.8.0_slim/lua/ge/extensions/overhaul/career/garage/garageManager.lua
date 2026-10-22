-- Garage ownership and transactions; garageManager/ holds the named parts.
-- Read config/state, capacity helpers, shared parts construction, then the public API and hooks.
local M = {}
M.dependencies = {"overhaul_career_career"}

local bundles = require("overhaul/lib/business/bundles")

local saveFile = "purchasedGarages.json"
local CLOSING_FEE_RATE = 0.03
local PROPERTY_TAX_RATE = 0.012
local NEGOTIATION_COOLDOWN_SECONDS = 30 * 60

local garageState = {
  purchasedGarages = {},
  discoveredGarages = {},
  garageAcquisitions = {},
  -- Relinquished grants stay relinquished until the player reclaims or buys them.
  relinquishedGrants = {},
  garageSize = {},
  negotiationCooldowns = {},
  frozenPrices = {},
}
local pendingNegotiatedPrices = {}

local parts = {}

function M.getStoredLocations()
  local storedLocation = {}
  for id, vehicle in pairs(overhaul_career_garage_inventory.getVehicles()) do
    if vehicle.location then
      if not storedLocation[vehicle.location] then storedLocation[vehicle.location] = {} end
      table.insert(storedLocation[vehicle.location], id)
    end
  end
  return storedLocation
end

function M.getVehiclesInGarage(garageId)
  if not garageId then return {} end
  return M.getStoredLocations()[garageId] or {}
end

local function isAwaitingFreight(vehicle)
  return string.find(tostring(vehicle.location or ""), "freightPickup:", 1, true) == 1
end

local function vehicleUsesGarageCapacity(vehicle, garageId)
  if not vehicle or vehicle.takesNoInventorySpace then return false end
  local homeGarage = isAwaitingFreight(vehicle) and vehicle.freightHomeGarageId or vehicle.location
  if garageId then return homeGarage == garageId end
  return not (vehicle.lastKnownLevel and vehicle.lastKnownLevel ~= getCurrentLevelIdentifier()
    and not garageState.garageSize[tostring(homeGarage)])
end

function M.vehicleUsesGarageCapacity(vehicle, garageId)
  parts.ownership.buildGarageSizes()
  return vehicleUsesGarageCapacity(vehicle, garageId)
end

local function countGarageReservations(garageId, inventoryId, includeExempt)
  local count = 0
  for id, vehicle in pairs(overhaul_career_garage_inventory.getVehicles() or {}) do
    if id ~= inventoryId and (includeExempt or not vehicle.takesNoInventorySpace)
        and (vehicle.location == garageId or (isAwaitingFreight(vehicle) and vehicle.freightHomeGarageId == garageId)) then
      count = count + 1
    end
  end
  local shopping = overhaul_career_market_vehicleShopping
  if shopping and shopping.getPendingInventorySlotCount then
    count = count + (tonumber(shopping.getPendingInventorySlotCount(nil, garageId, includeExempt)) or 0)
  end
  return count
end

function M.getGarageOccupancy(garageId)
  return countGarageReservations(garageId, nil, true)
end

function M.isGarageSpace(garage, inventoryId)
  if parts.ownership.isGarageForSale(garage) then return {false, 0} end
  if not garageState.garageSize[garage] then
    parts.ownership.buildGarageSizes()
    if not garageState.garageSize[garage] then return {false, 0} end
  end
  -- A move/collection replaces this vehicle's reservation rather than requiring a second slot.
  local carsInGarage = countGarageReservations(garage, inventoryId)
  local incoming = inventoryId and overhaul_career_garage_inventory.getVehicles()[inventoryId]
  return {(incoming and incoming.takesNoInventorySpace) or (garageState.garageSize[garage] - carsInGarage) > 0,
    garageState.garageSize[garage] - carsInGarage}
end

function M.getGarageCapacityData()
  parts.ownership.buildGarageSizes()
  local data = {}
  for garageId, owned in pairs(garageState.purchasedGarages) do
    if owned and not parts.ownership.isGarageForSale(garageId) then
      local garage = overhaul_world_facilities.getFacility("garage", garageId)
      local capacity = garageState.garageSize[tostring(garageId)]
      if not capacity and garage and garage.capacity then
        capacity = math.ceil(garage.capacity / (parts.ownership.isHardcoreMode() and 2 or 1))
      end
      data[tostring(garageId)] = {
        id = garageId,
        name = garage and garage.name or tostring(garageId),
        capacity = capacity or 0,
        count = countGarageReservations(garageId),
      }
    end
  end
  return data
end

function M.getFreeSlots(excludedPurchaseToken)
  parts.ownership.buildGarageSizes()
  local totalCapacity = 0
  for garage, owned in pairs(garageState.purchasedGarages) do
    if owned and not parts.ownership.isGarageForSale(garage) then
      totalCapacity = totalCapacity + (garageState.garageSize[tostring(garage)] or 0)
    end
  end
  for garageId in pairs(overhaul_career_garage_property_propertyRentals.getActiveRentals()) do
    if not garageState.purchasedGarages[garageId] and not parts.ownership.isGarageForSale(garageId) then
      totalCapacity = totalCapacity + (garageState.garageSize[tostring(garageId)] or 0)
    end
  end
  -- Count inventory once, regardless of its virtual pickup or legacy location. Do not
  -- discard overflow in one garage while advertising another garage's empty slots.
  for _, vehicle in pairs(overhaul_career_garage_inventory.getVehicles() or {}) do
    if vehicleUsesGarageCapacity(vehicle) then totalCapacity = totalCapacity - 1 end
  end
  local shopping = overhaul_career_market_vehicleShopping
  if shopping and shopping.getPendingInventorySlotCount then
    totalCapacity = totalCapacity - (tonumber(shopping.getPendingInventorySlotCount(excludedPurchaseToken)) or 0)
  end
  return math.max(0, totalCapacity)
end

function M.getGarageAvailabilityReason()
  if M.getFreeSlots() > 0 then return "ok" end
  for garageId, owned in pairs(garageState.purchasedGarages) do
    if owned and not parts.ownership.isGarageForSale(garageId) then return "full" end
  end
  for garageId in pairs(overhaul_career_garage_property_propertyRentals.getActiveRentals()) do
    if not parts.ownership.isGarageForSale(garageId) then return "full" end
  end
  return "none"
end

function M.removePurchasedGarage(garageId)
  if bundles.forGarage(garageId) then return false end
  if not garageId then return false end
  if not garageState.purchasedGarages[garageId] then return false end
  garageState.purchasedGarages[garageId] = nil
  garageState.discoveredGarages[garageId] = nil
  parts.ownership.clearGarageAcquisition(garageId)
  parts.ownership.reloadRecoveryPrompt()
  parts.ownership.buildGarageSizes()
  overhaul_career_saveSystem.saveCurrent()
  return true
end

function M.getPurchasedGarages()
  parts.ownership.syncBusinessGarages()
  local result = {}
  for garageId in pairs(garageState.purchasedGarages) do table.insert(result, garageId) end
  return result
end

function M.garageIdToName(garageId)
  local garage = overhaul_world_facilities.getFacilityIfExists("garage", garageId)
  if garage then return garage.name end
  return garageId and tostring(garageId) or nil
end

function M.computerIdToGarageId(computerId)
  local computer = overhaul_world_facilities.getFacility("computer", computerId)
  if computer then return computer.garageId end
  return nil
end

function M.getGaragePurchasePrice(garageId)
  return parts.purchase.calculateGaragePurchasePrice(garageId)
end

parts.ownership = require('overhaul/career/garage/garageManager/ownership').new({
  state = garageState,
  parts = parts,
  NEGOTIATION_COOLDOWN_SECONDS = NEGOTIATION_COOLDOWN_SECONDS,
  bundles = bundles,
  pendingNegotiatedPrices = pendingNegotiatedPrices,
  saveFile = saveFile,
})
parts.purchase = require('overhaul/career/garage/garageManager/purchase').new({
  state = garageState,
  parts = parts,
  CLOSING_FEE_RATE = CLOSING_FEE_RATE,
  PROPERTY_TAX_RATE = PROPERTY_TAX_RATE,
  bundles = bundles,
})
parts.capacity = M
parts.sales = require('overhaul/career/garage/garageManager/sales').new({state = garageState, bundles = bundles, parts = parts})
parts.ui = require('overhaul/career/garage/garageManager/ui').new({state = garageState, parts = parts})

M.purchaseDefaultGarage = parts.ownership.purchaseDefaultGarage

M.showPurchaseGaragePrompt = parts.purchase.showPurchaseGaragePrompt
M.requestGarageData = parts.purchase.requestGarageData
M.canPay = parts.purchase.canPay
M.buyGarage = parts.purchase.buyGarage
M.cancelGaragePurchase = parts.purchase.cancelGaragePurchase
M.getGaragePrice = parts.purchase.getGaragePrice

M.completePurchaseWithNegotiatedPrice = parts.purchase.completePurchaseWithNegotiatedPrice
M.purchaseGarageAtNegotiatedPrice = parts.purchase.purchaseGarageAtNegotiatedPrice

-- The UI price argument is ignored: the price frozen is always the pending negotiated one.
function M.freezeNegotiatedPrice(garageId, _uiPrice)
  local price = parts.ownership.getPendingNegotiatedPrice(garageId)
  if price then parts.ownership.freezeNegotiatedPrice(garageId, price) end
end

M.requestGarageListing = parts.purchase.requestGarageListing
M.getPendingGarageListing = parts.purchase.getPendingGarageListing
M.startGarageNegotiation = parts.purchase.startGarageNegotiation
M.purchaseGarageAtListedPrice = parts.purchase.purchaseGarageAtListedPrice
M.canNegotiateGarage = parts.ownership.canNegotiateGarage
M.setNegotiationCooldown = parts.ownership.setNegotiationCooldown
M.canSellGarage = parts.sales.canSellGarage
M.canMoveOutOfGarage = parts.sales.canMoveOutOfGarage
M.canMoveOutOfGarageByComputerId = parts.sales.canMoveOutOfGarageByComputerId
M.moveOutOfGarage = parts.sales.moveOutOfGarage
M.moveOutOfGarageByComputerId = parts.sales.moveOutOfGarageByComputerId
M.canReclaimGrantedGarage = parts.sales.canReclaimGrantedGarage
M.reclaimGrantedGarage = parts.sales.reclaimGrantedGarage
M.isGrantedGarageOwnership = parts.ownership.isGrantedGarageOwnership
M.wasGaragePurchasedWithMoney = parts.ownership.wasGaragePurchasedWithMoney
M.getGarageAcquisition = parts.ownership.getGarageAcquisition
M.listGarageForSale = parts.sales.listGarageForSale
M.listGarageForSaleByGarageId = parts.sales.listGarageForSaleByGarageId
M.sellGarage = parts.sales.sellGarage
M.completePropertySaleFromListing = parts.sales.completePropertySaleFromListing
M.getGarageListingPriceGuidance = parts.sales.getGarageListingPriceGuidance
M.getGarageListingPriceGuidanceByGarageId = parts.sales.getGarageListingPriceGuidanceByGarageId
M.getGarageActiveListing = parts.sales.getGarageActiveListing
M.removeGarageListing = parts.sales.removeGarageListing
M.startGarageSellingNegotiation = parts.sales.startGarageSellingNegotiation

M.getOwnedGaragesListingData = parts.ui.getOwnedGaragesListingData
M.getGarageOffersData = parts.ui.getGarageOffersData
M.acceptOffer = parts.ui.acceptOffer
M.declineOffer = parts.ui.declineOffer

M.onOverhaulModulesActivated = parts.ownership.onOverhaulModulesActivated
M.onExtensionLoaded = parts.ownership.onExtensionLoaded
M.isPurchasedGarage = parts.ownership.isPurchasedGarage
M.isAccessibleGarage = parts.ownership.isAccessibleGarage
M.isNotPurchasableGarage = parts.ownership.isNotPurchasableGarage
M.addPurchasedGarage = parts.ownership.addPurchasedGarage
M.addDiscoveredGarage = parts.ownership.addDiscoveredGarage
M.isDiscoveredGarage = parts.ownership.isDiscoveredGarage
M.loadPurchasedGarages = parts.ownership.loadPurchasedGarages
M.savePurchasedGarages = parts.ownership.savePurchasedGarages
M.onOverhaulSaveCurrentProfile = parts.ownership.onOverhaulSaveCurrentProfile

M.getNextAvailableSpace = parts.sales.getNextAvailableSpace
M.getEffectiveStartingGarages = parts.ownership.getEffectiveStartingGarages
M.getPrimaryStartingGarageId = parts.ownership.getPrimaryStartingGarageId
M.buildGarageSizes = parts.ownership.buildGarageSizes
M.fillGarages = parts.ownership.fillGarages
M.isGarageForSale = parts.ownership.isGarageForSale
M.isStarterGaragePurchasable = parts.ownership.isStarterGaragePurchasable

function M.syncBusinessGarages()
  parts.ownership.buildGarageSizes()
  parts.ownership.reloadRecoveryPrompt()
end

function M.onWorldReadyState(worldReadyState)
  if worldReadyState == 2 and overhaul_career_career.isActive() then
    parts.ownership.buildGarageSizes()
    parts.ownership.fillGarages()
    parts.ownership.purchaseDefaultGarage()
  end
end

M.onExtensionUnloaded = parts.ownership.disposeSaveFeature

return M
