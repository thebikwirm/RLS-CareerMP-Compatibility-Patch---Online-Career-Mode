-- Owner-operator phone contracts: hub logistics runs + new-vehicle distributor hauls.
local M = {}

M.dependencies = {
  "career_modules_delivery_generator",
  "career_modules_delivery_vehicleOfferManager",
  "career_modules_delivery_vehicleTasks",
  "career_modules_delivery_general",
  "career_modules_delivery_parcelManager",
  "career_modules_playerAttributes",
  "career_modules_delivery_employment",
}

local logTag = "ownerOpContracts"

local DISTRIBUTOR_MAX_CONTRACT_CARS = 10
local DISTRIBUTOR_LOGISTIC_TYPE = "vehDeliveryNew"
local DISTRIBUTOR_FILTER_ID = "newVehDistributorFilter"
-- Kept as save/UI kind id; any vehicleDistributor facility can generate these.
local CAR_HAUL_KIND = "finkHaul"
local balance = require("gameplay/delivery/logisticsBalance")

local contracts = {}
local active = nil
local lastGenAt = 0
local obsoleteHubContractNotice = false
local STORAGE_VERSION = 1
-- V3 distinguishes newly scaled offers from V2 quotes saved before the pay raise.
local QUOTE_VERSION = 3

local function getDeliveryLevel()
  if career_modules_delivery_employment and career_modules_delivery_employment.getDeliveryLevel then
    return career_modules_delivery_employment.getDeliveryLevel() or 0
  end
  return 0
end

local function ownerOpUnlocked()
  local emp = career_modules_delivery_employment
  if not emp then return true end
  if emp.isApprenticeshipEnabled and not emp.isApprenticeshipEnabled() then
    return true
  end
  if career_modules_unlockFlags and career_modules_unlockFlags.getFlag
      and career_modules_unlockFlags.getFlag("logisticsOwnerOp") then
    return true
  end
  return getDeliveryLevel() >= 30
end

local function facById(id)
  local gen = career_modules_delivery_generator
  return gen and gen.getFacilityById and gen.getFacilityById(id)
end


local function allFacilities()
  local gen = career_modules_delivery_generator
  return (gen and gen.getFacilities and gen.getFacilities()) or {}
end

local function isOwnerOpHubFacility(fac)
  local emp = career_modules_delivery_employment
  return emp and emp.isOwnerOpYardFacility and emp.isOwnerOpYardFacility(fac) or false
end

--- Recognize configured owner-op sources without changing their employment role.
-- @param fac Facility record, or nil.
-- @return Whether the facility can originate car-haul contracts.
local function isVehicleDistributorFacility(fac)
  if fac and type(fac.ownerOpCarHauling) == "table" then return true end
  local emp = career_modules_delivery_employment
  if emp and emp.isVehicleDistributorFacility then
    return emp.isVehicleDistributorFacility(fac)
  end
  return fac and (fac.vehicleDistributor == true or fac.carHaulFacility == true) or false
end


local function primaryPsPath(fac, preferName)
  if not fac then return nil end
  if preferName and fac.accessPointsByName and fac.accessPointsByName[preferName] then
    local ap = fac.accessPointsByName[preferName]
    local ps = ap.ps or ap
    if ps and ps.getPath then return ps:getPath() end
  end
  if fac.inspectSpots and fac.inspectSpots[1] and fac.inspectSpots[1].getPath then
    return fac.inspectSpots[1]:getPath()
  end
  for _, ap in pairs(fac.accessPointsByName or {}) do
    local ps = ap.ps or ap
    if ps and ps.getPath then return ps:getPath() end
  end
  return nil
end

local function dealerDropPsPath(dealer)
  if not dealer then return nil end
  local trailerKey = string.format("%s_trailer", dealer.id)
  if dealer.accessPointsByName and dealer.accessPointsByName[trailerKey] then
    local ap = dealer.accessPointsByName[trailerKey]
    local ps = ap.ps or ap
    if ps and ps.getPath then return ps:getPath() end
  end
  return primaryPsPath(dealer)
end

local function apProvidesType(ap, logisticType)
  if not ap or not logisticType then return false end
  local lookup = ap.logisticTypesProvidedLookup
  if type(lookup) == "table" and lookup[logisticType] then return true end
  for _, t in ipairs(ap.logisticTypesProvided or {}) do
    if t == logisticType then return true end
  end
  return false
end

local function facReceivesType(fac, logisticType)
  if not fac or not logisticType then return false end
  local lookup = fac.logisticTypesReceivedLookup
  if type(lookup) == "table" and lookup[logisticType] then return true end
  for _, t in ipairs(fac.logisticTypesReceived or {}) do
    if t == logisticType then return true end
  end
  for _, ap in pairs(fac.accessPointsByName or {}) do
    local recv = ap.logisticTypesReceivedLookup
    if type(recv) == "table" and recv[logisticType] then return true end
    for _, t in ipairs(ap.logisticTypesReceived or {}) do
      if t == logisticType then return true end
    end
  end
  return false
end

--- Resolve distinct pickup bays, excluding loaner bays.
-- An explicit stagingParkingSpotNames list is authoritative; unconfigured yards use legacy fallbacks.
-- @param fac Source facility, or nil.
-- @return Ordered bay records with name, path and optional parking-spot object.
local function distributorStagingPads(fac)
  local pads = {}
  if not fac then return pads end
  local configured = fac.ownerOpCarHauling and fac.ownerOpCarHauling.stagingParkingSpotNames
  if configured then
    local seen = {}
    for _, name in ipairs(configured) do
      local ap = fac.accessPointsByName and fac.accessPointsByName[name]
      local ps = ap and (ap.ps or ap)
      local path = ps and ps.getPath and ps:getPath()
      if path and not seen[path] and not ap.loanerNonTrailerPriority and not ap.loanerTrailerPriority then
        seen[path] = true
        table.insert(pads, { name = name, path = path, ps = ps })
      end
    end
    return pads
  end
  for name, ap in pairs(fac.accessPointsByName or {}) do
    if ap.isInspectSpot then goto continue end
    if ap.loanerNonTrailerPriority or ap.loanerTrailerPriority then goto continue end
    if apProvidesType(ap, DISTRIBUTOR_LOGISTIC_TYPE) then
      local ps = ap.ps or ap
      if ps and ps.getPath then
        table.insert(pads, { name = name, path = ps:getPath() })
      end
    end
    ::continue::
  end
  table.sort(pads, function(a, b) return tostring(a.name) < tostring(b.name) end)
  if not pads[1] then
    for name, ap in pairs(fac.accessPointsByName or {}) do
      if ap.isInspectSpot then goto continueFallback end
      if ap.loanerNonTrailerPriority or ap.loanerTrailerPriority then goto continueFallback end
      local ps = ap.ps or ap
      if ps and ps.getPath then
        table.insert(pads, { name = name, path = ps:getPath() })
      end
      ::continueFallback::
    end
    table.sort(pads, function(a, b) return tostring(a.name) < tostring(b.name) end)
  end
  if not pads[1] then
    local fallback = primaryPsPath(fac)
    if fallback then
      table.insert(pads, { name = "primary", path = fallback })
    end
  end
  return pads
end

local function facProvidesType(fac, logisticType)
  if not fac or not logisticType then return false end
  local lookup = fac.logisticTypesProvidedLookup
  if type(lookup) == "table" and lookup[logisticType] then return true end
  for _, t in ipairs(fac.logisticTypesProvided or {}) do
    if t == logisticType then return true end
  end
  for _, ap in pairs(fac.accessPointsByName or {}) do
    if apProvidesType(ap, logisticType) then return true end
  end
  return false
end

-- Cargo types that have their own owner-op pipeline (not hub distribute/A-B).
local HUB_CONTRACT_SKIP_TYPES = {
  vehDeliveryNew = true,
}

local function isVehicleHaulLogisticType(logisticType)
  if not logisticType then return false end
  if HUB_CONTRACT_SKIP_TYPES[logisticType] then return true end
  return type(logisticType) == "string" and logisticType:sub(1, 3) == "veh"
end

local function hasUnlockFlag(flag)
  return career_modules_unlockFlags
    and career_modules_unlockFlags.getFlag
    and career_modules_unlockFlags.getFlag(flag)
    and true or false
end

-- Biggest relevant vehicle for sizing = player's unlocked parcel slot cap.
local function playerMaxParcelSlots()
  if hasUnlockFlag("logisticsParcel128Slots") then return 128 end
  if hasUnlockFlag("logisticsParcel64Slots") then return 64 end
  if hasUnlockFlag("logisticsParcel32Slots") or hasUnlockFlag("largePackagesDelivery") then return 32 end
  return 16
end

local function logisticTypeHeatLeaf(logisticType)
  local t = tostring(logisticType or "")
  local lower = t:lower()
  if t:find("trailer", 1, true) then return "delivery_trailer" end
  if lower:find("cash", 1, true) or lower:find("money", 1, true)
      or lower:find("gold", 1, true) or lower:find("coin", 1, true) then return "delivery_cash" end
  if t:find("cement", 1, true) then return "delivery_cement" end
  if t:find("dryBulk", 1, true) or t:find("aggregate", 1, true) or t:find("lime", 1, true) or t:find("ash", 1, true) then
    return "delivery_dryBulk"
  end
  if t:find("fluid", 1, true) or t:find("Fluid", 1, true) then return "delivery_fluid" end
  if t:sub(1, 3) == "veh" then return "delivery_vehicle" end
  return "delivery_parcel"
end

local function surgeFactorForLeaf(leafId)
  if career_modules_activityHeat and career_modules_activityHeat.getDemandFactor then
    return math.max(0.05, tonumber(career_modules_activityHeat.getDemandFactor(leafId)) or 1)
  end
  return 1
end

local function playerCanTakeLogisticType(logisticType)
  if isVehicleHaulLogisticType(logisticType) then return false end
  local leaf = logisticTypeHeatLeaf(logisticType)
  if leaf == "delivery_trailer" then
    return hasUnlockFlag("smallTrailersDelivery")
      or hasUnlockFlag("logisticsTrailerMedium")
      or hasUnlockFlag("logisticsTrailerFlatbed")
      or hasUnlockFlag("logisticsTrailerFramelessDump")
      or hasUnlockFlag("largeTrailersDelivery")
      or hasUnlockFlag("logisticsTrailerDryvan")
      or hasUnlockFlag("logisticsTrailerDolly")
      or hasUnlockFlag("logisticsTrailerTanker")
      or hasUnlockFlag("logisticsTrailerContainer")
      or hasUnlockFlag("logisticsTrailerLog")
  end
  if leaf == "delivery_fluid" then
    return hasUnlockFlag("logisticsFluidDelivery") or hasUnlockFlag("hazardousMaterialsDelivery")
  end
  if leaf == "delivery_dryBulk" then
    return hasUnlockFlag("logisticsAggregateDelivery")
  end
  if leaf == "delivery_cement" then
    return hasUnlockFlag("logisticsCementDelivery")
  end
  if leaf == "delivery_cash" then
    return hasUnlockFlag("logisticsCashDelivery")
  end
  return hasUnlockFlag("smallPackagesDelivery")
end

local function sizeForLogisticType(logisticType)
  local leaf = logisticTypeHeatLeaf(logisticType)
  local surge = surgeFactorForLeaf(leaf)
  if leaf == "delivery_parcel" then
    local loadSlots = playerMaxParcelSlots()
    local trips = 2
    if loadSlots >= 128 then
      trips = 6 + math.floor(surge * 4)
    elseif loadSlots >= 64 then
      trips = 4 + math.floor(surge * 2)
    else
      trips = 2 + (surge > 1.2 and 1 or 0) + (surge > 1.5 and 1 or 0)
    end
    trips = math.max(2, trips)
    return {
      unit = "slots",
      loadSlots = loadSlots,
      trips = trips,
      amount = loadSlots * trips,
    }
  end
  local trips = 2 + (surge > 1.15 and 1 or 0) + (surge > 1.4 and 1 or 0)
  trips = math.max(2, trips)
  return {
    unit = "trips",
    loadSlots = 1,
    trips = trips,
    amount = trips,
  }
end

local function basePayForSizedContract(logisticType, size, extraStops)
  local leaf = logisticTypeHeatLeaf(logisticType)
  local trips = math.max(1, tonumber(size and size.trips) or 1)
  local base
  if size and size.unit == "slots" then
    local slots = math.max(1, tonumber(size.amount) or tonumber(size.loadSlots) or 16)
    local boxSlots = math.min(128, math.max(16, tonumber(size.loadSlots) or 16))
    base = math.ceil(slots / boxSlots) * balance.getParcelPay(boxSlots)
  else
    local perTrip = ({ delivery_trailer = 750, delivery_cash = 5000, delivery_cement = 6500,
      delivery_dryBulk = 7500, delivery_fluid = 7500 })[leaf] or 750
    base = balance.scaleBasePay(perTrip) * trips
  end
  base = base * (1 + 0.2 * math.max(0, (tonumber(extraStops) or 1) - 1))
  return base
end

local function payForSizedContract(logisticType, size, extraStops)
  return balance.applyLevelBonus(basePayForSizedContract(logisticType, size, extraStops), getDeliveryLevel())
end

local function summarizeSizedContract(logisticType, size)
  if size and size.unit == "slots" then
    return string.format(
      "Owner-operator %s run · %d slots (~%d loads of %d).",
      tostring(logisticType),
      size.amount or 0,
      size.trips or 0,
      size.loadSlots or 0
    )
  end
  return string.format(
    "Owner-operator %s run · %d trips minimum.",
    tostring(logisticType),
    size and size.trips or 2
  )
end

local function apReceivesType(ap, logisticType)
  if not ap or not logisticType then return false end
  local lookup = ap.logisticTypesReceivedLookup
  if type(lookup) == "table" and lookup[logisticType] then return true end
  for _, t in ipairs(ap.logisticTypesReceived or {}) do
    if t == logisticType then return true end
  end
  return false
end

local function listFacProvidedTypes(fac)
  local types, seen = {}, {}
  local function add(t)
    if not t or seen[t] or isVehicleHaulLogisticType(t) then return end
    seen[t] = true
    table.insert(types, t)
  end
  local lookup = fac and fac.logisticTypesProvidedLookup
  if type(lookup) == "table" then
    for t, on in pairs(lookup) do
      if on then add(t) end
    end
  end
  for _, t in ipairs(fac and fac.logisticTypesProvided or {}) do
    add(t)
  end
  for _, ap in pairs(fac and fac.accessPointsByName or {}) do
    for _, t in ipairs(ap.logisticTypesProvided or {}) do
      add(t)
    end
    local apLookup = ap.logisticTypesProvidedLookup
    if type(apLookup) == "table" then
      for t, on in pairs(apLookup) do
        if on then add(t) end
      end
    end
  end
  table.sort(types)
  return types
end

local function psPathForLogisticType(fac, logisticType, asProvider)
  if not fac or not logisticType then return primaryPsPath(fac) end
  local preferred, fallback
  for _, ap in pairs(fac.accessPointsByName or {}) do
    local match = asProvider and apProvidesType(ap, logisticType) or apReceivesType(ap, logisticType)
    if match then
      local ps = ap.ps or ap
      if ps and ps.getPath then
        local path = ps:getPath()
        local isLoaner = ap.loanerNonTrailerPriority or ap.loanerTrailerPriority
        if not ap.isInspectSpot and not isLoaner then
          preferred = preferred or path
        else
          fallback = fallback or path
        end
      end
    end
  end
  return preferred or fallback or primaryPsPath(fac)
end

local function findTypedReceivers(logisticType, excludeIds)
  local receivers = {}
  if not logisticType then return receivers end
  excludeIds = excludeIds or {}
  for _, fac in ipairs(allFacilities()) do
    if fac and fac.id and not excludeIds[fac.id] and facReceivesType(fac, logisticType) then
      local ps = psPathForLogisticType(fac, logisticType, false)
      if ps then
        table.insert(receivers, { fac = fac, ps = ps, logisticType = logisticType })
      end
    end
  end
  table.sort(receivers, function(a, b) return tostring(a.fac.id) < tostring(b.fac.id) end)
  return receivers
end

local function findTypedProviderReceiverPairs(excludeIds)
  local pairsList = {}
  excludeIds = excludeIds or {}
  local facilities = allFacilities()
  for _, origin in ipairs(facilities) do
    if origin and origin.id and not excludeIds[origin.id] then
      local provided = listFacProvidedTypes(origin)
      if provided[1] then
        for _, dest in ipairs(facilities) do
          if dest and dest.id and dest.id ~= origin.id and not excludeIds[dest.id] then
            for _, logisticType in ipairs(provided) do
              if facReceivesType(dest, logisticType) then
                local originPs = psPathForLogisticType(origin, logisticType, true)
                local destPs = psPathForLogisticType(dest, logisticType, false)
                if originPs and destPs then
                  table.insert(pairsList, {
                    origin = origin,
                    dest = dest,
                    originPs = originPs,
                    destPs = destPs,
                    logisticType = logisticType,
                  })
                end
              end
            end
          end
        end
      end
    end
  end
  return pairsList
end

--- Read ownerOpCarHauling.vehicleFilters or infer filters from independent generators.
-- @param fac Source facility.
-- @return Vehicle filter IDs; company-only sources return an empty list.
local function getDistributorFilters(fac)
  local configured = fac and fac.ownerOpCarHauling and fac.ownerOpCarHauling.vehicleFilters
  if configured then return configured end
  local filters, seen = {}, {}
  local companyOnly = false
  local hasIndependentGenerator = false
  for _, generator in ipairs(fac and fac.logisticGenerators or {}) do
    if generator.type == "vehOfferProvider" then
      if generator.offerMode == "employment" then companyOnly = true else hasIndependentGenerator = true end
    end
    if generator.type == "vehOfferProvider" and generator.filter and generator.offerMode ~= "employment" then
      local isDistributor = false
      for _, t in ipairs(generator.logisticTypes or {}) do
        if t == DISTRIBUTOR_LOGISTIC_TYPE then
          isDistributor = true
          break
        end
      end
      if isDistributor then
        for _,filterId in ipairs(type(generator.filter) == "table" and generator.filter or {generator.filter}) do
          if not seen[filterId] then
            seen[filterId] = true
            table.insert(filters, filterId)
          end
        end
      end
    end
  end
  if not filters[1] and isVehicleDistributorFacility(fac) and (not companyOnly or hasIndependentGenerator) then
    table.insert(filters, DISTRIBUTOR_FILTER_ID)
  end
  return filters
end

local function getDealerAcceptedFilters(dealer)
  local filters, seen = {}, {}
  for _, filterId in ipairs(dealer and dealer.acceptedVehicleFilters or {}) do
    if filterId and not seen[filterId] then
      seen[filterId] = true
      table.insert(filters, filterId)
    end
  end
  if filters[1] then return filters end
  for _, generator in ipairs(dealer and dealer.logisticGenerators or {}) do
    if generator.type == "vehOfferProvider" and generator.filter then
      for _, t in ipairs(generator.logisticTypes or {}) do
        if t == DISTRIBUTOR_LOGISTIC_TYPE then
          for _,filterId in ipairs(type(generator.filter) == "table" and generator.filter or {generator.filter}) do
            if not seen[filterId] then
              seen[filterId] = true
              table.insert(filters, filterId)
            end
          end
        end
      end
    end
  end
  if not filters[1] and facReceivesType(dealer, DISTRIBUTOR_LOGISTIC_TYPE) then
    table.insert(filters, DISTRIBUTOR_FILTER_ID)
  end
  return filters
end

--- List parcel hubs while retaining hubs that also opt into configured car hauling.
-- @return Eligible hub facilities sorted by ID.
local function listOwnerOpHubs()
  local hubs = {}
  for _, fac in ipairs(allFacilities()) do
    local configuredMixedYard = fac.ownerOpCarHauling and not (fac.vehicleDistributor or fac.carHaulFacility)
    if isOwnerOpHubFacility(fac) and (configuredMixedYard or not isVehicleDistributorFacility(fac)) then
      table.insert(hubs, fac)
    end
  end
  table.sort(hubs, function(a, b) return tostring(a.id) < tostring(b.id) end)
  return hubs
end

local function listVehicleDistributors()
  local list = {}
  for _, fac in ipairs(allFacilities()) do
    if isVehicleDistributorFacility(fac) then
      table.insert(list, fac)
    end
  end
  table.sort(list, function(a, b) return tostring(a.id) < tostring(b.id) end)
  return list
end

local function listNewVehicleDealers()
  local dealers = {}
  for _, fac in ipairs(allFacilities()) do
    if facReceivesType(fac, DISTRIBUTOR_LOGISTIC_TYPE) or (fac.acceptedVehicleFilters and fac.acceptedVehicleFilters[1]) then
      local filters = getDealerAcceptedFilters(fac)
      if filters[1] and dealerDropPsPath(fac) then
        table.insert(dealers, fac)
      end
    end
  end
  table.sort(dealers, function(a, b) return tostring(a.id) < tostring(b.id) end)
  return dealers
end

local function rollVehicleFromFilter(filterId)
  local gen = career_modules_delivery_generator
  if not gen or not gen.finalizeVehicleOffer then return nil end
  local stub = {
    vehicle = { filterId = filterId },
    locations = {},
    data = { type = "vehicle" },
  }
  gen.finalizeVehicleOffer(stub)
  local veh = stub.vehicle
  if not veh or not veh.model or not veh.config then return nil end
  local modelData = core_vehicles and core_vehicles.getModel and core_vehicles.getModel(veh.model)
  local cfg = modelData and modelData.configs and modelData.configs[veh.config]
  local tpl = require("gameplay/delivery/templates")
  if tpl.loadVehicleFilters then tpl.loadVehicleFilters() end
  local filter = tpl.getVehicleFilterById and tpl.getVehicleFilterById(filterId)
  return {
    model = veh.model,
    config = veh.config,
    label = veh.name or (cfg and cfg.Name) or veh.model,
    thumbnail = (cfg and cfg.preview) or "/ui/images/appDefault.png",
    filterId = filterId,
    filterName = (filter and filter.filterName) or filterId,
    unlockTag = filter and filter.unlockTag or nil,
  }
end

local function makeLoc(facId, psPath)
  return { type = "facilityParkingspot", facId = facId, psPath = psPath }
end

local function payMoney(amount, label)
  amount = math.floor(tonumber(amount) or 0)
  if amount <= 0 then return end
  if career_modules_playerAttributes and career_modules_playerAttributes.addAttributes then
    career_modules_playerAttributes.addAttributes({ money = amount }, {
      tags = { "gameplay", "deliveryReward", "ownerOp" },
      label = label or "Contract pay",
    })
  end
end

local function countVehiclesByStatus(vehicles, status)
  local n = 0
  for _, veh in ipairs(vehicles or {}) do
    if veh.status == status then n = n + 1 end
  end
  return n
end

local function buildDestinationSummary(vehicles)
  local byDealer = {}
  for _, veh in ipairs(vehicles or {}) do
    local id = veh.destFacId
    if id then
      if not byDealer[id] then
        byDealer[id] = {
          facId = id,
          name = veh.destFacName or id,
          count = 0,
        }
      end
      byDealer[id].count = byDealer[id].count + 1
    end
  end
  local list = {}
  for _, entry in pairs(byDealer) do
    table.insert(list, entry)
  end
  table.sort(list, function(a, b) return tostring(a.name) < tostring(b.name) end)
  return list
end

local function serializeVehicle(veh)
  return {
    key = veh.key,
    model = veh.model,
    config = veh.config,
    label = veh.label,
    thumbnail = veh.thumbnail,
    filterId = veh.filterId,
    filterName = veh.filterName,
    destFacId = veh.destFacId,
    destFacName = veh.destFacName,
    destPsPath = veh.destPsPath,
    status = veh.status or "pending",
    offerId = veh.offerId,
    pay = veh.pay,
    basePay = veh.basePay,
    logisticsBonusIncluded = veh.logisticsBonusIncluded == true,
  }
end

local function intersectFilters(a, b)
  local lookup, out = {}, {}
  for _, id in ipairs(b or {}) do lookup[id] = true end
  for _, id in ipairs(a or {}) do
    if lookup[id] then table.insert(out, id) end
  end
  return out
end

--- Roll cars for eligible destinations, respecting the source destinationFacilityIds allowlist.
-- @param count Maximum number of cars to generate.
-- @param seed Route and filter selection seed.
-- @param distributor Source facility.
-- @param dealers Candidate receiving facilities.
-- @return Pending vehicle records; may be empty when no route or vehicle is available.
local function buildDistributorVehicles(count, seed, distributor, dealers)
  local vehicles = {}
  local distributorFilters = getDistributorFilters(distributor)
  local eligibleDealers = {}
  local configured = distributor.ownerOpCarHauling and distributor.ownerOpCarHauling.destinationFacilityIds
  local destinations = {}
  for _, id in ipairs(configured or {}) do destinations[id] = true end
  for _, dealer in ipairs(dealers or {}) do
    if dealer.id ~= distributor.id and (not configured or destinations[dealer.id]) then
      eligibleDealers[#eligibleDealers + 1] = dealer
    end
  end
  if not distributorFilters[1] or not eligibleDealers[1] then return vehicles end
  local tries = 0
  local i = 0
  while #vehicles < count and tries < count * 12 do
    tries = tries + 1
    local dealerIdx = ((seed + tries - 1) % #eligibleDealers) + 1
    local dealer = eligibleDealers[dealerIdx]
    local accepted = getDealerAcceptedFilters(dealer)
    local filters = intersectFilters(distributorFilters, accepted)
    if not filters[1] and not (distributor.ownerOpCarHauling and distributor.ownerOpCarHauling.vehicleFilters) then
      filters = accepted
    end
    if filters[1] then
      local filterId = filters[((seed + #vehicles + tries) % #filters) + 1]
      local rolled = rollVehicleFromFilter(filterId)
      local destPs = dealerDropPsPath(dealer)
      if rolled and destPs then
        i = i + 1
        table.insert(vehicles, {
          key = string.format("%s|%s|%d", rolled.model, rolled.config, i),
          model = rolled.model,
          config = rolled.config,
          label = rolled.label,
          thumbnail = rolled.thumbnail,
          filterId = rolled.filterId,
          filterName = rolled.filterName,
          unlockTag = rolled.unlockTag,
          destFacId = dealer.id,
          destFacName = dealer.name or dealer.id,
          destPsPath = destPs,
          status = "pending",
        })
      end
    end
  end
  return vehicles
end

local function estimateDistributorPay(vehicles, distributor)
  local gen = career_modules_delivery_generator
  local pads = distributorStagingPads(distributor)
  local originPs = pads[1] and pads[1].path or primaryPsPath(distributor)
  if not originPs then
    local basePay = balance.getCarHaulPay()
    local each = balance.applyLevelBonus(basePay, getDeliveryLevel())
    for _, veh in ipairs(vehicles or {}) do
      veh.basePay = basePay
      veh.pay = each
      veh.logisticsBonusIncluded = true
    end
    return each * #(vehicles or {})
  end
  local origin = makeLoc(distributor.id, originPs)
  local total = 0
  for _, veh in ipairs(vehicles or {}) do
    local dest = makeLoc(veh.destFacId, veh.destPsPath)
    local distance = 0
    if gen and gen.getDistanceBetweenFacilities then
      distance = tonumber((gen.getDistanceBetweenFacilities(origin, dest))) or 0
    end
    if distance <= 0 then distance = balance.referenceDistance end
    local tpl = require("gameplay/delivery/templates")
    if tpl.loadVehicleFilters then tpl.loadVehicleFilters() end
    local filter = tpl.getVehicleFilterById and tpl.getVehicleFilterById(veh.filterId)
    local basePay = balance.getCarHaulPay()
    local base = balance.vehiclePayAtDistance(basePay, filter, distance, 1000) or basePay
    veh.basePay = base
    veh.pay = balance.applyLevelBonus(base, getDeliveryLevel())
    veh.logisticsBonusIncluded = true
    total = total + veh.pay
  end
  return total
end

-- Reprice offers in place after a skill gain. Rerolling the catalog invokes
-- vehicle selection repeatedly and can stall a loaded career. Active quotes
-- are held separately and never pass through here.
local function repriceUnacceptedContracts()
  local level = getDeliveryLevel()
  for id, contract in pairs(contracts) do
    local invalidSelfHaul = false
    if contract.kind == CAR_HAUL_KIND then
      for _, veh in ipairs(contract.vehicles or {}) do
        if veh.logisticsBonusIncluded == nil and (tonumber(contract.quoteVersion) or 0) >= 2 then
          veh.logisticsBonusIncluded = true
        end
        if veh.destFacId == contract.originFacId then invalidSelfHaul = true; break end
      end
    end
    if invalidSelfHaul or (contract.kind ~= CAR_HAUL_KIND
        and isVehicleHaulLogisticType(contract.logisticType)) then
      contracts[id] = nil
    elseif contract.quoteVersion ~= QUOTE_VERSION or contract.quoteLevel ~= level then
      if contract.kind == CAR_HAUL_KIND then
        local canScaleOldQuote = contract.quoteVersion == 2
        for _, veh in ipairs(contract.vehicles or {}) do
          if type(veh.basePay) ~= "number" then canScaleOldQuote = false; break end
        end
        if canScaleOldQuote then
          for _, veh in ipairs(contract.vehicles or {}) do
            veh.basePay = balance.scaleBasePay(veh.basePay)
          end
        elseif contract.quoteVersion ~= QUOTE_VERSION then
          estimateDistributorPay(contract.vehicles, facById(contract.originFacId))
        end
        local total = 0
        for _, veh in ipairs(contract.vehicles or {}) do
          local base = tonumber(veh.basePay) or tonumber(veh.pay) or balance.getCarHaulPay()
          veh.basePay = base
          veh.pay = balance.applyLevelBonus(base, level)
          veh.logisticsBonusIncluded = true
          total = total + veh.pay
        end
        contract.pay = total
      else
        if contract.quoteVersion == 2 and type(contract.basePay) == "number" then
          contract.basePay = balance.scaleBasePay(contract.basePay)
        elseif contract.quoteVersion ~= QUOTE_VERSION then
          contract.basePay = basePayForSizedContract(contract.logisticType,
            {unit = contract.sizeUnit, amount = contract.qty,
             trips = contract.trips, loadSlots = contract.loadSlots},
            contract.stopCount or 1)
        end
        contract.pay = balance.applyLevelBonus(contract.basePay or contract.pay or 0, level)
      end
      contract.quoteLevel = level
      contract.quoteVersion = QUOTE_VERSION
    end
  end
end

--- Refill sources that have no available haul and have a usable staging bay.
-- contractMultiplier is clamped to 1-2; unconfigured Fink keeps its doubled batch.
-- @param distributors Eligible source facilities.
-- @param dealers Candidate receiving facilities.
-- @param now Generation time used to vary batch counts and routes.
local function addDistributorContracts(distributors, dealers, now)
  local available = {}
  for _, contract in pairs(contracts) do
    if contract.kind == CAR_HAUL_KIND then available[contract.originFacId] = true end
  end
  for di, distributor in ipairs(distributors) do
    if dealers[1] and not available[distributor.id] and distributorStagingPads(distributor)[1] then
      local contractCount = 1 + ((now + di) % 2)
      local configured = distributor.ownerOpCarHauling and distributor.ownerOpCarHauling.contractMultiplier
      local multiplier = configured and math.max(1, math.min(2, math.floor(tonumber(configured) or 1)))
        or (distributor.id == "finkIndustries" and 2 or 1)
      contractCount = contractCount * multiplier
      for ci = 1, contractCount do
        local qty = math.min(DISTRIBUTOR_MAX_CONTRACT_CARS, 4 + ((now + ci * 3 + di) % 7))
        local vehicles = buildDistributorVehicles(qty, now + ci * 17 + di * 31, distributor, dealers)
        if vehicles[1] then
          local destinations = buildDestinationSummary(vehicles)
          local pay = estimateDistributorPay(vehicles, distributor)
          local id = string.format("carhaul_%s_%d_%d", distributor.id, ci, now)
          local destNames = {}
          for _, dest in ipairs(destinations) do
            table.insert(destNames, string.format("%s (%d)", dest.name, dest.count))
          end
          contracts[id] = {
            id = id,
            kind = CAR_HAUL_KIND,
            title = tostring(distributor.name or distributor.id),
            summary = string.format(
              "Haul %d cars to %d destinations. Stage cars per trip at the yard; rent equipment if needed.",
              #vehicles,
              #destinations
            ),
            detailSummary = table.concat(destNames, " · "),
            pay = pay,
            qty = #vehicles,
            destinationCount = #destinations,
            destinations = destinations,
            originFacId = distributor.id,
            vehicles = vehicles,
            quoteVersion = QUOTE_VERSION,
            quoteLevel = getDeliveryLevel(),
          }
        end
      end
    end
  end
end

local function rebuildContracts(force)
  local now = os.time()
  if not force then
    if active then
      return
    end
    if next(contracts) then
      local needsRegen = false
      for _, c in pairs(contracts) do
        if (c.kind == "hubDistribute" or c.kind == "hubAB") and not c.logisticType then
          needsRegen = true
          break
        end
      end
      if not needsRegen then
        repriceUnacceptedContracts()
        if next(contracts) then
          addDistributorContracts(listVehicleDistributors(), listNewVehicleDealers(), now)
          return
        end
      end
    elseif (now - lastGenAt) < 45 then
      return
    end
  end
  lastGenAt = now
  for k in pairs(contracts) do
    contracts[k] = nil
  end

  local hubs = listOwnerOpHubs()
  local distributors = listVehicleDistributors()
  local dealers = listNewVehicleDealers()
  local hubLookup = {}
  for _, hub in ipairs(hubs) do hubLookup[hub.id] = true end
  for _, dist in ipairs(distributors) do hubLookup[dist.id] = true end

  -- Candidates: every unlocked logistic type a hub can ship to a real receiver.
  local typeCandidates = {}
  local typeIndex = {}
  for _, hub in ipairs(hubs) do
    for _, logisticType in ipairs(listFacProvidedTypes(hub)) do
      if playerCanTakeLogisticType(logisticType) then
        local receivers = findTypedReceivers(logisticType, hubLookup)
        if receivers[1] then
          local entry = typeIndex[logisticType]
          if not entry then
            entry = {
              logisticType = logisticType,
              hubs = {},
              receiversByHub = {},
            }
            typeIndex[logisticType] = entry
            table.insert(typeCandidates, entry)
          end
          table.insert(entry.hubs, hub)
          entry.receiversByHub[hub.id] = receivers
        end
      end
    end
  end

  local function pickWeightedIndex(weights)
    local total = 0
    for _, w in ipairs(weights) do total = total + w end
    if total <= 0 then return 1 end
    local roll = math.random() * total
    for i, w in ipairs(weights) do
      roll = roll - w
      if roll <= 0 then return i end
    end
    return #weights
  end

  local function addHubDistribute(logisticType, hub, dest, seed)
    local hubPs = psPathForLogisticType(hub, logisticType, true)
    if not (hubPs and dest and dest.ps) then return false end
    local size = sizeForLogisticType(logisticType)
    local id = string.format("hub_%s_%s_%s", hub.id, logisticType, tostring(seed or now))
    local n = 1
    while contracts[id] do
      n = n + 1
      id = string.format("hub_%s_%s_%s_%d", hub.id, logisticType, tostring(seed or now), n)
    end
    contracts[id] = {
      id = id,
      kind = "hubDistribute",
      title = string.format("%s → %s", tostring(hub.name or hub.id), tostring(dest.fac.name or dest.fac.id)),
      summary = summarizeSizedContract(logisticType, size),
      pay = payForSizedContract(logisticType, size, 1),
      logisticType = logisticType,
      originFacId = hub.id,
      originPsPath = hubPs,
      destFacId = dest.fac.id,
      destPsPath = dest.ps,
      qty = size.amount,
      trips = size.trips,
      loadSlots = size.loadSlots,
      sizeUnit = size.unit,
    }
    return true
  end

  local function addHubParcelString(logisticType, hub, receivers, seed)
    if logisticTypeHeatLeaf(logisticType) ~= "delivery_parcel" then return false end
    if not (hub and receivers and receivers[1]) then return false end
    local hubPs = psPathForLogisticType(hub, logisticType, true)
    if not hubPs then return false end
    local loadSlots = playerMaxParcelSlots()
    local maxStops = 3
    if loadSlots >= 128 then
      maxStops = 5
    elseif loadSlots >= 64 then
      maxStops = 4
    elseif loadSlots >= 32 then
      maxStops = 3
    else
      maxStops = 2
    end
    maxStops = math.min(maxStops, #receivers)

    local picked = {}
    local seen = {}
    local start = ((tonumber(seed) or now) % #receivers) + 1
    for i = 0, #receivers - 1 do
      if #picked >= maxStops then break end
      local dest = receivers[((start + i - 1) % #receivers) + 1]
      local facId = dest and dest.fac and dest.fac.id
      if facId and not seen[facId] and dest.ps then
        seen[facId] = true
        table.insert(picked, dest)
      end
    end
    if not picked[1] then return false end

    local remaining = {}
    for _, dest in ipairs(picked) do table.insert(remaining, dest) end
    local ordered = {}
    local cursor = makeLoc(hub.id, hubPs)
    local gen = career_modules_delivery_generator
    while remaining[1] do
      local bestI, bestD = 1, math.huge
      for i, dest in ipairs(remaining) do
        local d = math.huge
        if gen and gen.getDistanceBetweenFacilities then
          d = tonumber((gen.getDistanceBetweenFacilities(cursor, makeLoc(dest.fac.id, dest.ps)))) or math.huge
        end
        if d < bestD then bestI, bestD = i, d end
      end
      local pick = table.remove(remaining, bestI)
      table.insert(ordered, pick)
      cursor = makeLoc(pick.fac.id, pick.ps)
    end

    local stopCount = #ordered
    local baseSlots = math.floor(loadSlots / stopCount)
    local remSlots = loadSlots - (baseSlots * stopCount)
    local stops = {}
    for i, dest in ipairs(ordered) do
      table.insert(stops, {
        destFacId = dest.fac.id,
        destPsPath = dest.ps,
        destName = tostring(dest.fac.name or dest.fac.id),
        slots = math.max(1, baseSlots + (i <= remSlots and 1 or 0)),
      })
    end
    local size = { unit = "slots", loadSlots = loadSlots, trips = 1, amount = loadSlots }
    local id = string.format("hub_str_%s_%s_%s", hub.id, logisticType, tostring(seed or now))
    local n = 1
    while contracts[id] do
      n = n + 1
      id = string.format("hub_str_%s_%s_%s_%d", hub.id, logisticType, tostring(seed or now), n)
    end
    local first = stops[1]
    contracts[id] = {
      id = id,
      kind = "hubDistribute",
      stringMode = true,
      title = string.format("Parcel string: %d stops · %s", stopCount, tostring(hub.name or hub.id)),
      summary = string.format(
        "Owner-operator parcel string · %d stops · %d slots. Pay on full completion.",
        stopCount,
        loadSlots
      ),
      pay = payForSizedContract(logisticType, size, stopCount),
      logisticType = logisticType,
      originFacId = hub.id,
      originPsPath = hubPs,
      destFacId = first.destFacId,
      destPsPath = first.destPsPath,
      qty = loadSlots,
      trips = 1,
      loadSlots = loadSlots,
      sizeUnit = "slots",
      stopCount = stopCount,
      stops = stops,
    }
    return true
  end

  local function offerHubTyped(logisticType, hub, receivers, seed)
    if logisticTypeHeatLeaf(logisticType) == "delivery_parcel" then
      return addHubParcelString(logisticType, hub, receivers, seed)
    end
    local dest = receivers and receivers[1]
    if not dest then return false end
    return addHubDistribute(logisticType, hub, dest, seed)
  end

  -- Floor: ≥1 contract per available logistic type.
  for ti, candidate in ipairs(typeCandidates) do
    local hub = candidate.hubs[((now + ti - 1) % #candidate.hubs) + 1]
    local receivers = candidate.receiversByHub[hub.id] or findTypedReceivers(candidate.logisticType, hubLookup)
    if receivers[1] then
      if logisticTypeHeatLeaf(candidate.logisticType) == "delivery_parcel" then
        offerHubTyped(candidate.logisticType, hub, receivers, now + ti)
      else
        local dest = receivers[((now + ti * 3) % #receivers) + 1]
        addHubDistribute(candidate.logisticType, hub, dest, now + ti)
      end
    end
  end

  -- Extra surge-weighted contracts (still typed). Parcel/high-slot types get more volume.
  local extraSlots = math.min(8, math.max(2, #typeCandidates + 1))
  if typeCandidates[1] then
    local weights = {}
    for _, candidate in ipairs(typeCandidates) do
      local leaf = logisticTypeHeatLeaf(candidate.logisticType)
      local w = surgeFactorForLeaf(leaf)
      if leaf == "delivery_parcel" and playerMaxParcelSlots() >= 64 then
        w = w * 1.75
      elseif leaf == "delivery_trailer" then
        w = w * 1.35
      end
      table.insert(weights, w)
    end
    for ei = 1, extraSlots do
      local idx = pickWeightedIndex(weights)
      local candidate = typeCandidates[idx]
      local hub = candidate.hubs[((now + ei * 7) % #candidate.hubs) + 1]
      local receivers = candidate.receiversByHub[hub.id] or findTypedReceivers(candidate.logisticType, hubLookup)
      if receivers[1] then
        if logisticTypeHeatLeaf(candidate.logisticType) == "delivery_parcel" then
          offerHubTyped(candidate.logisticType, hub, receivers, now + 1000 + ei)
        else
          local dest = receivers[((now + ei * 11) % #receivers) + 1]
          addHubDistribute(candidate.logisticType, hub, dest, now + 1000 + ei)
        end
      end
    end
  end

  if hubs[1] then
    local dispatchHub = hubs[((now - 1) % #hubs) + 1]
    local typedPairs = findTypedProviderReceiverPairs(hubLookup)
    local unlockedPairs = {}
    local pairWeights = {}
    for _, pair in ipairs(typedPairs) do
      if playerCanTakeLogisticType(pair.logisticType) then
        table.insert(unlockedPairs, pair)
        local leaf = logisticTypeHeatLeaf(pair.logisticType)
        table.insert(pairWeights, surgeFactorForLeaf(leaf))
      end
    end
    if unlockedPairs[1] then
      local pair = unlockedPairs[pickWeightedIndex(pairWeights)]
      local size = sizeForLogisticType(pair.logisticType)
      local id = string.format("hub_ab_%s_%s_%d", dispatchHub.id, pair.logisticType, now)
      contracts[id] = {
        id = id,
        kind = "hubAB",
        title = string.format("A→B: %s → %s", tostring(pair.origin.name or pair.origin.id), tostring(pair.dest.name or pair.dest.id)),
        summary = string.format(
          "%s via %s",
          summarizeSizedContract(pair.logisticType, size),
          tostring(dispatchHub.name or dispatchHub.id)
        ),
        pay = payForSizedContract(pair.logisticType, size, 1),
        logisticType = pair.logisticType,
        originFacId = pair.origin.id,
        originPsPath = pair.originPs,
        destFacId = pair.dest.id,
        destPsPath = pair.destPs,
        dispatchFacId = dispatchHub.id,
        qty = size.amount,
        trips = size.trips,
        loadSlots = size.loadSlots,
        sizeUnit = size.unit,
      }
    end
  end

  addDistributorContracts(distributors, dealers, now)
  local level = getDeliveryLevel()
  for _, contract in pairs(contracts) do
    contract.quoteVersion = QUOTE_VERSION
    contract.quoteLevel = level
    if contract.kind ~= CAR_HAUL_KIND then
      contract.basePay = basePayForSizedContract(contract.logisticType,
        {unit = contract.sizeUnit, amount = contract.qty,
         trips = contract.trips, loadSlots = contract.loadSlots},
        contract.stopCount or 1)
    end
  end
end


local function serializeContractForList(c)
  local payload = {
    id = c.id,
    kind = c.kind,
    title = c.title,
    summary = c.summary,
    pay = c.pay,
    qty = c.qty,
    trips = c.trips,
    loadSlots = c.loadSlots,
    sizeUnit = c.sizeUnit,
    logisticType = c.logisticType,
    originFacId = c.originFacId,
    destFacId = c.destFacId,
    dispatchFacId = c.dispatchFacId,
    stringMode = c.stringMode and true or false,
    stopCount = c.stopCount or (c.stops and #c.stops) or nil,
  }
  if c.kind == "finkHaul" then
    payload.detailSummary = c.detailSummary
    payload.destinationCount = c.destinationCount
    payload.destinations = c.destinations
    payload.vehicles = {}
    for _, veh in ipairs(c.vehicles or {}) do
      table.insert(payload.vehicles, serializeVehicle(veh))
    end
  end
  return payload
end

local function listContracts(facilityId)
  rebuildContracts(false)
  local list = {}
  for _, c in pairs(contracts) do
    local match = true
    if facilityId and facilityId ~= "" then
      match = c.originFacId == facilityId
        or c.dispatchFacId == facilityId
        or (c.kind == CAR_HAUL_KIND and c.originFacId == facilityId)
    end
    if match then
      table.insert(list, serializeContractForList(c))
    end
  end
  table.sort(list, function(a, b) return tostring(a.title) < tostring(b.title) end)
  return list
end

local function countContractsForFacility(facilityId)
  return #listContracts(facilityId)
end

local function isOwnerOpHubFacilityId(facId)
  local fac = facById(facId)
  return isOwnerOpHubFacility(fac) or isVehicleDistributorFacility(fac)
end

--- Combine parcel hubs and car-haul sources without repeating mixed facilities.
-- @return Facility IDs for owner-op board discovery.
local function getOwnerOpHubFacilityIds()
  local ids = {}
  local seen = {}
  for _, fac in ipairs(listOwnerOpHubs()) do
    table.insert(ids, fac.id)
    seen[fac.id] = true
  end
  for _, fac in ipairs(listVehicleDistributors()) do
    if not seen[fac.id] then table.insert(ids, fac.id) end
  end
  return ids
end


local function routeTo(facId, psPath)
  local gen = career_modules_delivery_generator
  if not (gen and gen.getLocationCoordinates and core_groundMarkers) then return end
  local pos = gen.getLocationCoordinates(makeLoc(facId, psPath))
  if pos then
    core_groundMarkers.setPath(pos, { clearPathOnReachingTarget = true })
  end
end

local function acceptBps(contract)
  local firstStop = contract.stringMode and contract.stops and contract.stops[1] or nil
  active = {
    id = contract.id,
    kind = contract.kind,
    pay = contract.pay,
    originFacId = contract.originFacId,
    originPsPath = contract.originPsPath,
    destFacId = (firstStop and firstStop.destFacId) or contract.destFacId,
    destPsPath = (firstStop and firstStop.destPsPath) or contract.destPsPath,
    phase = "pickup",
    stringMode = contract.stringMode and true or nil,
    stops = contract.stops,
    stopIndex = contract.stringMode and 1 or nil,
    stopCount = contract.stopCount or (contract.stops and #contract.stops) or nil,
    qty = contract.qty,
    logisticType = contract.logisticType,
    loadSlots = contract.loadSlots,
    tripsRequired = math.max(1, tonumber(contract.trips) or 1),
    tripsCompleted = 0,
    deliveredStops = 0,
  }
  routeTo(contract.originFacId, contract.originPsPath)
  if contract.stringMode then
    ui_message(
      string.format(
        "Parcel string accepted (%d stops). Load matching parcels for each stop through the cargo screen. Pay on full completion.",
        active.stopCount or #(contract.stops or {})
      ),
      8,
      "info"
    )
    return true, "Navigate to hub pickup."
  end
  ui_message("Contract accepted. Collect a matching native load at the marked facility, then complete its delivery.", 8, "info")
  return true, "Navigate to pickup."
end

--- Create a native vehicle offer for one broker car and its destination.
-- @param contract Broker contract record.
-- @param veh Pending vehicle record.
-- @param slotIndex One-based pickup bay index.
-- @param stagingPads Optional prefiltered clear bays; otherwise resolve the source bays.
-- @return Native offer, or nil when the source or delivery system is unavailable.
local function buildCarHaulOffer(contract, veh, slotIndex, stagingPads)
  local vom = career_modules_delivery_vehicleOfferManager
  if not vom then return nil end
  local now = (career_modules_delivery_general and career_modules_delivery_general.time and career_modules_delivery_general.time()) or os.time()
  local originFacId = (active and active.originFacId) or (contract and contract.originFacId)
  local distributor = facById(originFacId)
  local pads = stagingPads or distributorStagingPads(distributor)
  local pad = pads[((slotIndex - 1) % math.max(1, #pads)) + 1] or pads[1]
  local originPs = pad and pad.path or primaryPsPath(distributor)
  if not originFacId or not originPs then return nil end
  local origin = makeLoc(originFacId, originPs)
  local dest = makeLoc(veh.destFacId, veh.destPsPath)
  -- The native manager appends offers and resolves the first matching ID.
  -- Persist this counter with the active contract so retries, including after
  -- reload, cannot resolve to an earlier failed/expired offer.
  active.offerSequence = (tonumber(active.offerSequence) or 0) + 1
  local offerId = string.format("carHaulOffer_%s_%s_%d", contract.id, veh.key, active.offerSequence)
  local gen = career_modules_delivery_generator
  local routeDistance = 0
  if gen and gen.getDistanceBetweenFacilities then
    routeDistance = tonumber((gen.getDistanceBetweenFacilities(origin, dest))) or 0
  end
  local brand, name = tostring(distributor and distributor.name or "Distributor"), veh.label or veh.model
  local modelData = core_vehicles and core_vehicles.getModel and core_vehicles.getModel(veh.model)
  if modelData then
    local modelInfo = modelData.model or modelData
    if modelInfo and modelInfo.Brand and modelInfo.Brand ~= "" then
      brand = modelInfo.Brand
    end
    local cfg = modelData.configs and modelData.configs[veh.config]
    if cfg and cfg.Name and cfg.Name ~= "" then
      name = cfg.Name
    elseif modelInfo and modelInfo.Name and modelInfo.Name ~= "" then
      name = modelInfo.Name
    end
  end
  local tpl = require("gameplay/delivery/templates")
  if tpl.loadVehicleFilters then tpl.loadVehicleFilters() end
  local filter = tpl.getVehicleFilterById and tpl.getVehicleFilterById(veh.filterId)
  local offer = {
    id = offerId,
    name = string.format("%s: %s → %s", brand, name, veh.destFacName or veh.destFacId),
    data = {
      type = "vehicle",
      tag = filter and filter.unlockTag or "fleetVeh",
      originalDistance = routeDistance,
      finkContractId = contract.id,
      finkVehicleKey = veh.key,
      logisticsBonusIncluded = veh.logisticsBonusIncluded == true,
    },
    task = {
      type = "vehicleDropOff",
      destination = dest,
      dropOff = dest,
      lookupType = DISTRIBUTOR_LOGISTIC_TYPE,
    },
    locations = { origin, dest },
    origin = origin,
    destination = dest,
    dropOffFacId = veh.destFacId,
    spawnLocation = origin,
    offerExpiresAt = now + (6 * 3600),
    vehicle = {
      model = veh.model,
      config = veh.config,
      filterId = veh.filterId,
      unlockTag = veh.unlockTag or (filter and filter.unlockTag),
      name = name,
      brand = brand,
      mileage = math.random(0, 800),
    },
    rewards = { money = veh.pay or 0 },
  }
  return offer
end


--- Spawn queued cars sequentially, returning failed cars to pending for a later retry.
-- Callbacks ignore an abandoned or replaced active contract.
-- @return Whether the queue could be started.
local function spawnQueuedCarHaulOffers()
  if not active or active.kind ~= "finkHaul" or active.phase ~= "staging" then return false end
  if active.spawning then return true end
  local vom = career_modules_delivery_vehicleOfferManager
  if not (vom and vom.spawnOffer) then
    ui_message("Vehicle delivery system unavailable.", 6, "warning")
    return false
  end
  active.spawning = true
  local contractId = active.id
  local offerIds = active.pendingOfferIds or {}
  local idx = 0
  --- Process the previous spawn result and continue this contract queue.
  -- @param ok Previous result; nil starts the queue and false restores the failed car.
  local function spawnNext(ok)
    if not active or active.id ~= contractId or active.kind ~= CAR_HAUL_KIND then return end
    if ok == false then
      log("W", logTag, "Distributor offer spawn failed at index " .. tostring(idx))
      for _, veh in ipairs(active.vehicles or {}) do
        if veh.offerId == offerIds[idx] then
          veh.status = "pending"
          veh.offerId = nil
          break
        end
      end
      local failed = vom.getOfferById and vom.getOfferById(offerIds[idx])
      if failed then failed.offerExpiresAt = 0 end
    end
    idx = idx + 1
    local offerId = offerIds[idx]
    if not offerId then
      local staged = countVehiclesByStatus(active.vehicles, "staged")
      active.phase = staged > 0 and "hauling" or "planTrip"
      active.spawning = nil
      active.pendingOfferIds = nil
      if staged > 0 then
        ui_message("Cars ready at the pickup yard. Load the marked cars, then deliver to their destinations.", 8, "success")
      else
        ui_message("No cars could be staged. Clear the pickup bays and retry.", 8, "warning")
      end
      local vtasks = career_modules_delivery_vehicleTasks
      if vtasks and vtasks.navigateToNextTask then
        vtasks.navigateToNextTask()
      end
      if career_modules_delivery_general and career_modules_delivery_general.requestDeliveryPoiRefresh then
        career_modules_delivery_general.requestDeliveryPoiRefresh(true)
      end
      return
    end
    vom.spawnOffer(offerId, false, spawnNext)
  end
  ui_message(string.format("Staging %d cars at distributor pickup pads...", #offerIds), 5, "info")
  spawnNext()
  return true
end

local function cloneActiveVehicles()
  local list = {}
  for _, veh in ipairs(active and active.vehicles or {}) do
    table.insert(list, serializeVehicle(veh))
  end
  return list
end

local function getActiveCarHaulSnapshot()
  if not active or active.kind ~= "finkHaul" then return nil end
  local vehicles = cloneActiveVehicles()
  return {
    id = active.id,
    kind = active.kind,
    phase = active.phase,
    pay = active.pay,
    qty = #(active.vehicles or {}),
    pendingCount = countVehiclesByStatus(active.vehicles, "pending"),
    stagedCount = countVehiclesByStatus(active.vehicles, "staged"),
    deliveredCount = countVehiclesByStatus(active.vehicles, "delivered"),
    escrowedMoney = math.floor(tonumber(active.escrowedMoney) or 0),
    destinations = buildDestinationSummary(active.vehicles),
    vehicles = vehicles,
    originFacId = active.originFacId,
  }
end

local function acceptCarHaul(contract)
  local vehicles = {}
  for _, veh in ipairs(contract.vehicles or {}) do
    table.insert(vehicles, {
      key = veh.key,
      model = veh.model,
      config = veh.config,
      label = veh.label,
      thumbnail = veh.thumbnail,
      filterId = veh.filterId,
      filterName = veh.filterName,
      unlockTag = veh.unlockTag,
      destFacId = veh.destFacId,
      destFacName = veh.destFacName,
      destPsPath = veh.destPsPath,
      pay = veh.pay,
      basePay = veh.basePay,
      logisticsBonusIncluded = veh.logisticsBonusIncluded == true,
      status = "pending",
    })
  end
  if not vehicles[1] then
    return false, "This contract has no vehicles."
  end

  local originFacId = contract.originFacId
  local distributor = facById(originFacId)
  local yardPs = primaryPsPath(distributor) or (distributorStagingPads(distributor)[1] and distributorStagingPads(distributor)[1].path)

  active = {
    id = contract.id,
    kind = CAR_HAUL_KIND,
    pay = contract.pay,
    vehicles = vehicles,
    originFacId = originFacId,
    originPsPath = yardPs,
    phase = "planTrip",
    escrowedMoney = 0,
    escrowedRewards = {},
  }

  contracts[contract.id] = nil
  routeTo(originFacId, yardPs)
  if career_modules_delivery_general and career_modules_delivery_general.requestDeliveryPoiRefresh then
    career_modules_delivery_general.requestDeliveryPoiRefresh(true)
  end
  ui_message("Contract accepted. Open Logistics on your phone to plan each yard trip.", 10, "info")
  return true, "Plan your first trip in the Logistics app."
end

--- Stage unique pending cars up to the number of clear pickup bays.
-- Unselected and excess cars stay pending for subsequent trips.
-- @param selectedKeys Optional vehicle keys; an empty list selects the default trip.
-- @return Success flag and a player-facing status message.
local function stageCarHaulTrip(selectedKeys)
  selectedKeys = selectedKeys or {}
  if not active or active.kind ~= "finkHaul" then
    return false, "No active distributor contract."
  end
  if active.phase == "staging" or active.spawning then
    return false, "Cars are still staging."
  end

  local byKey = {}
  for _, veh in ipairs(active.vehicles or {}) do
    byKey[veh.key] = veh
  end

  local selected = {}
  local seen = {}
  if selectedKeys[1] then
    for _, key in ipairs(selectedKeys) do
      local veh = byKey[key]
      if veh and veh.status == "pending" and not seen[key] then
        seen[key] = true
        table.insert(selected, veh)
      end
    end
  else
    for _, veh in ipairs(active.vehicles or {}) do
      if veh.status == "pending" then
        table.insert(selected, veh)
        break
      end
    end
  end

  if not selected[1] then
    return false, "Select at least one pending car to stage."
  end

  local vom = career_modules_delivery_vehicleOfferManager
  if not (vom and vom.addOffer and vom.spawnOffer) then
    return false, "Vehicle delivery system unavailable."
  end

  local pads = {}
  local gen = career_modules_delivery_generator
  for _, pad in ipairs(distributorStagingPads(facById(active.originFacId))) do
    local ps = pad.ps or (gen and gen.getParkingSpotByPath and gen.getParkingSpotByPath(pad.path))
    if not (ps and ps.hasAnyVehicles and ps:hasAnyVehicles()) then
      table.insert(pads, pad)
    end
  end
  if not pads[1] then return false, "Clear the pickup bays before staging cars." end

  local offerIds = {}
  for i, veh in ipairs(selected) do
    if i > #pads then break end
    local offer = buildCarHaulOffer({ id = active.id }, veh, i, pads)
    if offer then
      local broker = career_modules_delivery_broker
      offer.brokerId = broker and broker.jobForNative('cars', active.id)
      vom.addOffer(offer)
      veh.offerId = offer.id
      veh.status = "staged"
      table.insert(offerIds, offer.id)
    end
  end

  if not offerIds[1] then
    return false, "Could not prepare selected cars."
  end

  active.pendingOfferIds = offerIds
  active.phase = "staging"
  spawnQueuedCarHaulOffers()
  return true, string.format("Staging %d car(s) at the yard. Remaining cars stay available for later trips.", #offerIds)
end

local function isCarHaulVehicleDelivered(veh)
  if not veh or not veh.offerId then return false end
  local vom = career_modules_delivery_vehicleOfferManager
  local vtasks = career_modules_delivery_vehicleTasks
  if not vom or not vtasks or not vom.getOfferById then return false end
  local offer = vom.getOfferById(veh.offerId)
  if not offer or not offer.spawned or offer.brokerRestoring then return false end
  local task = vtasks.getVehicleTaskForOffer and vtasks.getVehicleTaskForOffer(offer)
  return task == nil
end

local function addCarHaulEscrowRewards(rewards)
  if type(rewards) ~= "table" then return end
  active.escrowedRewards = active.escrowedRewards or {}
  for key, amount in pairs(rewards) do
    local value = tonumber(amount) or 0
    if value ~= 0 then
      active.escrowedRewards[key] = (tonumber(active.escrowedRewards[key]) or 0) + value
    end
  end
  active.escrowedMoney = math.floor(tonumber(active.escrowedRewards.money) or 0)
end

local function markCarHaulOfferDelivered(offerData)
  if not active or active.kind ~= "finkHaul" or type(offerData) ~= "table" then return false end
  local offer = offerData.offer or offerData
  local data = offer and offer.data
  if not data or tostring(data.finkContractId) ~= tostring(active.id) then return false end
  local vehKey = data.finkVehicleKey
  local veh
  for _, candidate in ipairs(active.vehicles or {}) do
    if tostring(candidate.key) == tostring(vehKey) then
      veh = candidate
      break
    end
  end
  if not veh then return false end
  if veh.status == "delivered" then return false end
  veh.status = "delivered"
  addCarHaulEscrowRewards(offerData.adjustedRewards or (offer and offer.rewards))
  return true
end

-- Drop-off pays into escrow until every car on the contract is delivered.
local function consumeVehicleDropOffForContractEscrow(payoutSum, dropOffData)
  if type(payoutSum) ~= "table" or not active or active.kind ~= "finkHaul" then
    return payoutSum, nil
  end
  local touched = false
  for _, offerData in ipairs((dropOffData and dropOffData.offers) or {}) do
    if markCarHaulOfferDelivered(offerData) then
      touched = true
      local rewards = offerData.adjustedRewards or {}
      for key, amount in pairs(rewards) do
        local value = tonumber(amount) or 0
        if value ~= 0 and payoutSum[key] ~= nil then
          payoutSum[key] = (tonumber(payoutSum[key]) or 0) - value
          if math.abs(payoutSum[key]) < 0.0001 then payoutSum[key] = nil end
        end
      end
    end
  end
  if not touched then return payoutSum, nil end

  local pending = countVehiclesByStatus(active.vehicles, "pending")
  local staged = countVehiclesByStatus(active.vehicles, "staged")
  local delivered = countVehiclesByStatus(active.vehicles, "delivered")
  local progress = {
    kind = "finkHaul",
    id = active.id,
    name = "Distributor contract",
    deliveredCount = delivered,
    totalCount = #(active.vehicles or {}),
    pendingCount = pending,
    stagedCount = staged,
    escrowedMoney = math.floor(tonumber(active.escrowedMoney) or 0),
    escrowedRewards = deepcopy(active.escrowedRewards or {}),
    complete = pending == 0 and staged == 0 and delivered > 0,
  }

  if progress.complete then
    for key, amount in pairs(active.escrowedRewards or {}) do
      local value = tonumber(amount) or 0
      if value ~= 0 then
        payoutSum[key] = (tonumber(payoutSum[key]) or 0) + value
      end
    end
    ui_message(string.format("Distributor contract complete. %d cars delivered.", delivered), 8, "success")
    active = nil
    rebuildContracts(false)
  elseif active.phase == "hauling" and pending > 0 and staged == 0 then
    active.phase = "planTrip"
    ui_message("Trip delivered. Pay is held until the full contract is finished.", 7, "info")
  end
  return payoutSum, progress
end

local function trackCarHaulDeliveries()
  if not active or active.kind ~= "finkHaul" then return end
  local dProgress = career_modules_delivery_progress
  if dProgress and dProgress.isSettlementPending and dProgress.isSettlementPending() then return end
  local changed = false
  for _, veh in ipairs(active.vehicles or {}) do
    if veh.status == "staged" and isCarHaulVehicleDelivered(veh) then
      veh.status = "delivered"
      changed = true
    end
  end
  if not changed then return end

  local pending = countVehiclesByStatus(active.vehicles, "pending")
  local staged = countVehiclesByStatus(active.vehicles, "staged")
  local delivered = countVehiclesByStatus(active.vehicles, "delivered")
  if pending == 0 and staged == 0 and delivered > 0 then
    local escrow = math.floor(tonumber(active.escrowedMoney) or 0)
    local rewards = deepcopy(active.escrowedRewards or {})
    if escrow > 0 or next(rewards) then
      for key, amount in pairs(rewards) do
        local value = tonumber(amount) or 0
        if value ~= 0 then
          -- Late completion outside drop-off UI (e.g. reload reconcile).
          if key == "money" then
            payMoney(value, "Owner-op contract")
          elseif career_modules_playerAttributes and career_modules_playerAttributes.addAttributes then
            career_modules_playerAttributes.addAttributes({ [key] = value }, {
              tags = { "gameplay", "deliveryReward" },
              label = "Owner-op contract",
            })
          end
        end
      end
      ui_message(string.format("Distributor contract complete. Paid $%d.", escrow), 8, "success")
    else
      ui_message(string.format("Distributor contract complete. %d cars delivered.", delivered), 8, "success")
    end
    active = nil
    rebuildContracts(false)
    return
  end

  if active.phase == "hauling" and pending > 0 and staged == 0 then
    active.phase = "planTrip"
    ui_message("Trip delivered. Plan your next yard run on the Logistics app.", 7, "info")
  end
end

local function acceptContract(contractId, opts)
  opts = opts or {}
  if not ownerOpUnlocked() then
    return false, "Reach Logistics level 30 for owner-operator contracts."
  end
  if active then
    return false, "Finish the active owner-operator contract first."
  end
  if career_modules_delivery_employment and career_modules_delivery_employment.isOnShift
      and career_modules_delivery_employment.isOnShift() then
    return false, "End your company shift before taking owner-operator contracts."
  end
  rebuildContracts(false)
  local contract = contracts[contractId]
  if not contract and active and active.id == contractId and active.kind == "finkHaul" then
    return false, "This distributor contract is already active."
  end
  if not contract then
    return false, "Contract expired. Refresh the board."
  end
  if contract.kind == "finkHaul" then
    return acceptCarHaul(contract)
  end
  return acceptBps(contract)
end

local function getActiveContract()
  if active and active.kind == "finkHaul" then
    return getActiveCarHaulSnapshot()
  end
  if active and active.stringMode then
    local stop = active.stops and active.stops[active.stopIndex or 1]
    return {
      id = active.id,
      kind = active.kind,
      pay = active.pay,
      phase = active.phase,
      stringMode = true,
      stopIndex = active.stopIndex or 1,
      stopCount = active.stopCount or #(active.stops or {}),
      deliveredStops = active.deliveredStops or 0,
      qty = active.qty,
      loadSlots = active.loadSlots,
      currentDestName = stop and stop.destName or nil,
      destFacId = active.destFacId,
      originFacId = active.originFacId,
    }
  end
  return active
end

local function isHubContract()
  return active and (active.kind == "hubDistribute" or active.kind == "hubAB"
    or active.kind == "bpsHub" or active.kind == "bpsAB" or active.kind == "bpsPort")
end

local function abandonHubContract(contractId)
  if not isHubContract() then return false, "No active hub contract to abandon." end
  if not contractId or tostring(active.id) ~= tostring(contractId) then
    return false, "The active hub contract changed. Please review it before abandoning."
  end
  contracts[active.id] = nil
  active = nil
  return true, "Hub contract abandoned. Your native delivery jobs remain active."
end

local function hubCargoKind(cargo)
  if not cargo.materialType then return "delivery_parcel" end
  local gen = career_modules_delivery_generator
  local material = gen and gen.getMaterialsTemplatesById and gen.getMaterialsTemplatesById(cargo.materialType)
  return material and "delivery_" .. tostring(material.type) or nil
end

local function hubCargoMatches(cargo, destFacId)
  if not (destFacId and cargo and cargo.id and cargo.origin and cargo.origin.facId == active.originFacId) then return false end
  if hubCargoKind(cargo) ~= logisticTypeHeatLeaf(active.logisticType) then return false end
  local dest = cargo.destination
  if dest and dest.facId == destFacId then return true end
  if dest and dest.type == "multi" then
    for _, loc in ipairs(dest.destinations or {}) do
      if loc.facId == destFacId then return true end
    end
  end
  return false
end

local function requiredHubLoad(cargo)
  if logisticTypeHeatLeaf(active.logisticType) == "delivery_parcel" then
    return math.max(1, tonumber(active.loadSlots) or 1)
  end
  local gen = career_modules_delivery_generator
  local material = cargo and gen and gen.getMaterialsTemplatesById and gen.getMaterialsTemplatesById(cargo.materialType)
  local _, capacity = balance.getMaterialPay(material)
  return capacity
end

-- A hub trip must be backed by native cargo or a native trailer task. The
-- native drop-off callback below is the only place that credits its delivery.
local function captureHubLoad()
  local kind = logisticTypeHeatLeaf(active.logisticType)
  local proof = { cargo = {}, trailers = {}, delivered = {}, amount = 0, byStop = {} }
  local gen = career_modules_delivery_generator
  local originPos = gen and gen.getLocationCoordinates and gen.getLocationCoordinates(makeLoc(active.originFacId, active.originPsPath))
  local function vehicleAtOrigin(vehId)
    local veh = vehId and be and be.getObjectByID and be:getObjectByID(vehId)
    return veh and originPos and veh:getPosition():squaredDistance(originPos) <= (35 * 35)
  end
  if kind == "delivery_trailer" then
    local tasks = career_modules_delivery_vehicleTasks
    for _, task in ipairs(tasks and tasks.getVehicleTasks and tasks.getVehicleTasks() or {}) do
      local offer = task.offer
      local dest = offer and (offer.destination or (offer.task and offer.task.destination))
      if not task.remove and offer and offer.id and offer.data and offer.data.type == "trailer"
          and offer.origin and offer.origin.facId == active.originFacId
          and dest and dest.facId == active.destFacId and vehicleAtOrigin(task.vehId) then
        proof.trailers[tostring(offer.id)] = active.destFacId
        proof.amount = proof.amount + 1
      end
    end
    proof.required = 1
  else
    local parcels = career_modules_delivery_parcelManager
    local materialType
    for _, cargo in ipairs(parcels and parcels.getAllCargoInVehicles and parcels.getAllCargoInVehicles() or {}) do
      if cargo.location and cargo.location.type == "vehicle" and vehicleAtOrigin(cargo.location.vehId) then
        local destFacId = active.destFacId
        if active.stringMode then
          destFacId = nil
          for _, stop in ipairs(active.stops or {}) do
            if hubCargoMatches(cargo, stop.destFacId) then destFacId = stop.destFacId; break end
          end
        end
        if destFacId and hubCargoMatches(cargo, destFacId)
            and (kind == "delivery_parcel" or not materialType or cargo.materialType == materialType) then
          materialType = materialType or cargo.materialType
          if cargo.materialType then
            cargo.data = cargo.data or {}
            cargo.data.ownerOpSourceCargoId = cargo.id
          end
          local amount = math.max(0, tonumber(cargo.slots) or 0)
          proof.cargo[tostring(cargo.id)] = { amount = amount, destFacId = destFacId }
          proof.amount = proof.amount + amount
          proof.byStop[destFacId] = (proof.byStop[destFacId] or 0) + amount
          proof.required = proof.required or requiredHubLoad(cargo)
        end
      end
    end
  end
  if not proof.required or proof.amount < proof.required then return nil end
  if active.stringMode then
    for _, stop in ipairs(active.stops or {}) do
      if (proof.byStop[stop.destFacId] or 0) < (tonumber(stop.slots) or 1) then return nil end
    end
  end
  return proof
end

local function completeHubStop()
  if active.stringMode and active.stops then
    local stopIndex = active.stopIndex or 1
    active.deliveredStops = (active.deliveredStops or 0) + 1
    if stopIndex < #active.stops then
      active.stopIndex = stopIndex + 1
      local nextStop = active.stops[active.stopIndex]
      active.destFacId, active.destPsPath = nextStop.destFacId, nextStop.destPsPath
      routeTo(nextStop.destFacId, nextStop.destPsPath)
      ui_message(string.format("Stop %d done. Pay held. Next: stop %d/%d · %s.",
        stopIndex, active.stopIndex, #active.stops, nextStop.destName or "destination"), 7, "info")
      return
    end
  else
    active.tripsCompleted = (active.tripsCompleted or 0) + 1
    if active.tripsCompleted < (active.tripsRequired or 1) then
      active.phase, active.loadProof = "pickup", nil
      routeTo(active.originFacId, active.originPsPath)
      ui_message(string.format("Load %d/%d delivered. Return for the next load.",
        active.tripsCompleted, active.tripsRequired), 7, "info")
      return
    end
  end
  -- The native delivery already awards its own money. The contract quote is
  -- the total target for these loads, so only pay the remaining difference.
  local topUp = math.max(0, math.floor((tonumber(active.pay) or 0) - (tonumber(active.nativeMoney) or 0)))
  payMoney(topUp, "Owner-op contract")
  ui_message(string.format("Contract complete. Contract top-up $%d.", topUp), 7, "success")
  contracts[active.id] = nil
  active = nil
end

local function creditHubDelivery(id, sourceId, destFacId, amount, trailer, nativeMoney)
  if not isHubContract() or active.phase ~= "dropoff" or not active.loadProof then return end
  if not active.stringMode and destFacId ~= active.destFacId then return end
  local proof = active.loadProof
  local key = tostring(id)
  if proof.delivered[key] then return end
  local sourceKey = tostring(sourceId or id)
  local loaded = trailer and proof.trailers[key] or proof.cargo[sourceKey]
  if not loaded or (trailer and loaded ~= destFacId) or (not trailer and loaded.destFacId ~= destFacId) then return end
  proof.creditedByCargo = proof.creditedByCargo or {}
  local credited = proof.creditedByCargo[sourceKey] or 0
  local credit = trailer and 1 or math.min(math.max(0, tonumber(amount) or 0), math.max(0, loaded.amount - credited))
  if credit <= 0 then return end
  proof.delivered[key] = true
  if not trailer then
    proof.creditedByCargo[sourceKey] = credited + credit
    proof.completedCargo = proof.completedCargo or {}
    if proof.creditedByCargo[sourceKey] >= loaded.amount then proof.completedCargo[sourceKey] = true end
  end
  active.nativeMoney = (tonumber(active.nativeMoney) or 0) + math.max(0, tonumber(nativeMoney) or 0)
  if active.stringMode then
    proof.deliveredByStop = proof.deliveredByStop or {}
    proof.deliveredByStop[destFacId] = (proof.deliveredByStop[destFacId] or 0) + credit
    while active and active.stringMode do
      local stop = active.stops[active.stopIndex]
      if (proof.deliveredByStop[stop.destFacId] or 0) < (tonumber(stop.slots) or 1) then break end
      completeHubStop()
    end
    return
  end
  proof.deliveredAmount = (proof.deliveredAmount or 0) + credit
  if proof.deliveredAmount >= proof.required then
    proof.deliveredAmount = 0
    completeHubStop()
  end
end

-- Persistence assigns fresh native IDs on reload to avoid colliding with
-- generated freight. Rebind only the current load's identity proof; keep the
-- accepted quote and already credited delivery totals intact.
function M.remapRestoredHubProofIds(cargoIds, offerIds, sourceIds)
  if not isHubContract() or active.phase ~= "dropoff" or not active.loadProof then return end
  local proof = active.loadProof
  cargoIds = cargoIds or {}
  offerIds = offerIds or {}
  sourceIds = sourceIds or cargoIds
  local function rekey(entries, ids)
    local result = {}
    for oldId, value in pairs(entries or {}) do
      local newId = ids[tostring(oldId)]
      if newId ~= nil then result[tostring(newId)] = value end
    end
    return result
  end
  proof.cargo = rekey(proof.cargo, sourceIds)
  proof.trailers = rekey(proof.trailers, offerIds)
  proof.creditedByCargo = rekey(proof.creditedByCargo, sourceIds)
  proof.completedCargo = rekey(proof.completedCargo, sourceIds)
  local oldDelivered = proof.delivered
  proof.delivered = rekey(oldDelivered, cargoIds)
  for key, value in pairs(rekey(oldDelivered, offerIds)) do
    proof.delivered[key] = value
  end
end

function M.onOwnerOpCargoDelivered(cargoItems)
  for _, cargo in ipairs(cargoItems or {}) do
    if not isHubContract() then break end
    if hubCargoMatches(cargo, cargo.location and cargo.location.facId) then
      local rewards = cargo.adjustedRewards or cargo.rewards or {}
      creditHubDelivery(cargo.id, cargo.data and cargo.data.ownerOpSourceCargoId, cargo.location.facId,
        tonumber(cargo.slots) or 0, false, rewards.money)
    end
  end
end

function M.onOwnerOpVehicleDelivered(items)
  for _, item in ipairs(items or {}) do
    if not isHubContract() then break end
    local offer = item.offer or item
    local dest = offer and (offer.destination or (offer.task and offer.task.destination))
    if offer and offer.data and offer.data.type == "trailer" then
      local rewards = item.adjustedRewards or offer.rewards or {}
      creditHubDelivery(offer.id, nil, dest and dest.facId, 1, true, rewards.money)
    end
  end
end

local function advanceBpsIfNear()
  if not isHubContract() then return end
  local gen = career_modules_delivery_generator
  if not gen or not gen.getLocationCoordinates then return end
  local playerVeh = getPlayerVehicle(0)
  if not playerVeh then return end
  local pos = playerVeh:getPosition()
  local function near(facId, psPath)
    local p = gen.getLocationCoordinates(makeLoc(facId, psPath))
    return p and pos:squaredDistance(p) <= (25 * 25)
  end
  if active.phase == "pickup" and near(active.originFacId, active.originPsPath) then
    local proof = captureHubLoad()
    if proof then
      active.loadProof = proof
      active.phase = "dropoff"
      routeTo(active.destFacId, active.destPsPath)
      ui_message("Load confirmed. Complete the native delivery at the marked destination.", 6, "info")
    end
  end
end

local function findCarHaulOfferForVehicle(contractId, veh)
  local vom = career_modules_delivery_vehicleOfferManager
  if not vom then return nil end
  if veh.offerId and vom.getOfferById then
    local offer = vom.getOfferById(veh.offerId)
    local data = offer and offer.data
    if data and data.finkContractId == contractId and data.finkVehicleKey == veh.key and offer.offerExpiresAt ~= 0 then
      return offer
    end
  end
  if not vom.getAllOfferCustomFilter then return nil end
  for _, offer in ipairs(vom.getAllOfferCustomFilter(function(o) return o.brokerId or not o.spawned end) or {}) do
    local data = offer.data
    if data and data.finkContractId == contractId and data.finkVehicleKey == veh.key and offer.offerExpiresAt ~= 0 then
      return offer
    end
  end
  return nil
end

local function reconcileCarHaulAfterLoad()
  if not active or active.kind ~= "finkHaul" then return end

  active.spawning = nil
  active.pendingOfferIds = nil

  if type(active.vehicles) ~= "table" or not active.vehicles[1] then
    active = nil
    return
  end

  for _, veh in ipairs(active.vehicles) do
    if veh.status == "staged" or veh.status == "delivered" then
      local offer = findCarHaulOfferForVehicle(active.id, veh)
      if offer then
        veh.offerId = offer.id
        if veh.status == "staged" and isCarHaulVehicleDelivered(veh) then
          veh.status = "delivered"
        end
      elseif veh.status == "staged" then
        veh.status = "pending"
        veh.offerId = nil
      end
    end
  end

  local pending = countVehiclesByStatus(active.vehicles, "pending")
  local staged = countVehiclesByStatus(active.vehicles, "staged")
  local delivered = countVehiclesByStatus(active.vehicles, "delivered")

  if active.phase == "staging" then
    active.phase = staged > 0 and "hauling" or "planTrip"
  end

  if pending == 0 and staged == 0 and delivered > 0 then
    local escrow = math.floor(tonumber(active.escrowedMoney) or 0)
    local rewards = deepcopy(active.escrowedRewards or {})
    if next(rewards) then
      for key, amount in pairs(rewards) do
        local value = tonumber(amount) or 0
        if value ~= 0 then
          if key == "money" then
            payMoney(value, "Owner-op contract")
          elseif career_modules_playerAttributes and career_modules_playerAttributes.addAttributes then
            career_modules_playerAttributes.addAttributes({ [key] = value }, {
              tags = { "gameplay", "deliveryReward" },
              label = "Owner-op contract",
            })
          end
        end
      end
      ui_message(string.format("Distributor contract complete. Paid $%d.", escrow), 8, "success")
    else
      ui_message(string.format("Distributor contract complete. %d cars delivered.", delivered), 8, "success")
    end
    active = nil
    rebuildContracts(false)
    return
  end

  if active.phase == "hauling" and pending > 0 and staged == 0 then
    active.phase = "planTrip"
  end
end

local function serializeContractRecord(c)
  if not c or not c.id then return nil end
  local copy = deepcopy(c)
  if copy.kind == "finkHaul" and type(copy.vehicles) == "table" then
    local vehicles = {}
    for _, veh in ipairs(copy.vehicles) do
      table.insert(vehicles, serializeVehicle(veh))
    end
    copy.vehicles = vehicles
  end
  return copy
end

local function serializeActiveRecord()
  if not active then return nil end
  local copy = deepcopy(active)
  copy.spawning = nil
  copy.pendingOfferIds = nil
  if copy.kind == "finkHaul" and type(copy.vehicles) == "table" then
    local vehicles = {}
    for _, veh in ipairs(copy.vehicles) do
      table.insert(vehicles, serializeVehicle(veh))
    end
    copy.vehicles = vehicles
  end
  return copy
end

local function serialize()
  local savedContracts = {}
  for id, contract in pairs(contracts) do
    local copy = serializeContractRecord(contract)
    if copy then
      savedContracts[id] = copy
    end
  end
  return {
    version = STORAGE_VERSION,
    contracts = savedContracts,
    active = serializeActiveRecord(),
    lastGenAt = lastGenAt,
  }
end
M.serialize = serialize
function M.abandonBrokerContract(id)
  if not active or active.id~=id then return false end
  local broker=career_modules_delivery_broker
  if not broker or not broker.jobForNative('cars',id) then return false end
  local tasks=career_modules_delivery_vehicleTasks
  for _,task in ipairs(tasks.getVehicleTasks()) do
    if task.offer.data and task.offer.data.finkContractId==id then tasks.giveBackDeliveryVehicle(task.vehId) end
  end
  contracts[id]=nil; active=nil
  return true
end

local function setup(savedState)
  contracts = {}
  active = nil
  lastGenAt = 0
  obsoleteHubContractNotice = false

  if type(savedState) == "table" then
    lastGenAt = tonumber(savedState.lastGenAt) or 0
    if type(savedState.contracts) == "table" then
      for id, contract in pairs(savedState.contracts) do
        if type(contract) == "table" then
          local copy = deepcopy(contract)
          copy.id = copy.id or id
          contracts[copy.id] = copy
        end
      end
    end
    if type(savedState.active) == "table" and savedState.active.id then
      active = deepcopy(savedState.active)
      active.logisticType = active.logisticType or (contracts[active.id] and contracts[active.id].logisticType)
      if isHubContract() and isVehicleHaulLogisticType(active.logisticType) then
        -- Old catalogs could offer vehicle types as parcel hub contracts.
        -- Those have no compatible cargo and cannot be resumed as hub work.
        contracts[active.id] = nil
        active = nil
        obsoleteHubContractNotice = true
      elseif isHubContract() and active.phase == "dropoff" and not active.loadProof then
        -- An old proximity-only pickup has no cargo identity to verify. Keep
        -- the accepted quote and completed trips, but require this load again.
        active.phase = "pickup"
      end
      if active then
        active.spawning = nil
        active.pendingOfferIds = nil
        if active.kind == "finkHaul" then
          active.escrowedRewards = active.escrowedRewards or {}
          active.escrowedMoney = math.floor(tonumber(active.escrowedMoney) or tonumber(active.escrowedRewards.money) or 0)
          for _, veh in ipairs(active.vehicles or {}) do
            if veh.logisticsBonusIncluded == nil then
              -- Pre-balance saves have no basePay; early balance saves have it.
              veh.logisticsBonusIncluded = veh.basePay ~= nil
            end
          end
        end
      end
    end
  end

  if not next(contracts) and not active then
    rebuildContracts(true)
    return
  end

  reconcileCarHaulAfterLoad()
end
M.setup = setup

local function onUpdate(dt)
  if obsoleteHubContractNotice then
    obsoleteHubContractNotice = false
    ui_message("An obsolete vehicle hub contract was removed. Choose a current car-hauling job instead.", 8, "warning")
  end
  advanceBpsIfNear()
  trackCarHaulDeliveries()
end

local function getBoardState(facilityId)
  local emp = career_modules_delivery_employment
  local onShift = emp and emp.isOnShift and emp.isOnShift() or false
  return {
    unlocked = ownerOpUnlocked(),
    level = getDeliveryLevel(),
    unlockLevel = 30,
    facilityId = facilityId,
    contracts = listContracts(facilityId),
    active = getActiveContract(),
    onShift = onShift,
  }
end

M.listContracts = listContracts
M.getBrokerOffer = function(id)
  rebuildContracts(false)
  return contracts[id] and deepcopy(contracts[id])
end
M.startBrokerContract = function(contract)
  if active then return false, 'Finish the current car-hauling contract before collecting another.' end
  if not ownerOpUnlocked() or not contract or contract.kind ~= 'finkHaul' then return false, 'Car-hauling work is locked.' end
  return acceptCarHaul(deepcopy(contract))
end
M.cancelUnstartedBrokerContract = function(id)
  if not active or active.id ~= id then return true end
  for _,veh in ipairs(active.vehicles or {}) do if veh.status ~= 'pending' then return false end end
  active=nil
  return true
end
M.countContractsForFacility = countContractsForFacility
M.isOwnerOpUnlocked = ownerOpUnlocked
M.isOwnerOpHubFacilityId = isOwnerOpHubFacilityId
M.getOwnerOpHubFacilityIds = getOwnerOpHubFacilityIds
M.acceptContract = acceptContract
M.abandonHubContract = abandonHubContract
M.stageCarHaulTrip = stageCarHaulTrip
M.getActiveContract = getActiveContract
M.getBoardState = getBoardState
M.rebuildContracts = function() rebuildContracts(true) end
M.spawnQueuedCarHaulOffers = spawnQueuedCarHaulOffers
M.consumeVehicleDropOffForContractEscrow = consumeVehicleDropOffForContractEscrow
M.onUpdate = onUpdate
M.onCareerActivated = function()
end

return M
