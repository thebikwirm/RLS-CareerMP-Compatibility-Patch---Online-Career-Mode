-- Shared, data-driven ownership links. No independent entitlement save state.
local M = {}
local definitions

function M.getAll()
  definitions = definitions or jsonReadFile("gameplay/business/propertyBundles.json") or {}
  return definitions
end

function M.forGarage(garageId)
  for _, bundle in ipairs(M.getAll()) do
    if bundle.garageId == garageId then return bundle end
  end
end

function M.forBusiness(businessType, businessId)
  for _, bundle in ipairs(M.getAll()) do
    if bundle.businessType == businessType and bundle.businessId == businessId then return bundle end
  end
end

function M.isOwned(bundle)
  local manager = career_modules_business_businessManager
  return bundle ~= nil and career_career and career_career.isActive()
    and manager and manager.isBusinessOwnershipReady()
    and manager.isPurchasedBusiness(bundle.businessType, bundle.businessId) == true or false
end

function M.forDyno(mapId, triggerName, sitesFile, parkingSpotName)
  for _, bundle in ipairs(M.getAll()) do
    local dyno = bundle.dyno
    if bundle.mapId == mapId and dyno and dyno.triggerName == triggerName
      and dyno.sitesFile == sitesFile and dyno.parkingSpotName == parkingSpotName then
      return bundle
    end
  end
end

function M.saleBlockReason(bundle)
  if not bundle then return nil end
  local name = bundle.name or bundle.businessId
  local inventory = career_modules_inventory
  if not inventory or not inventory.getVehicles then return "Vehicle storage is not ready." end
  for _, vehicle in pairs(inventory.getVehicles() or {}) do
    if vehicle.location == bundle.garageId then
      return "Move all vehicles out of the " .. name .. " garage before selling the business."
    end
  end
  local dyno = career_modules_dynoSession
  if bundle.dyno and dyno and dyno.isBusinessSessionBusy
    and dyno.isBusinessSessionBusy(bundle.businessId) then
    return "Finish the " .. name .. " dyno session before selling the business."
  end
end

return M
