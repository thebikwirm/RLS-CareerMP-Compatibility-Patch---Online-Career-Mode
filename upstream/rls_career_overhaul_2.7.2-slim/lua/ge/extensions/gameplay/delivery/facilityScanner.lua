-- Shared facility discovery functions
-- Extracted from career/modules/delivery/generator.lua
-- These functions require the map to be loaded but NOT career mode.

local M = {}

-------------------------------
-- Facility Scanning
-------------------------------

-- Gets ALL delivery facilities on the current map.
-- Tries gameplay_sites_sitesManager.getFacilities() first (returns all facilities),
-- falls back to freeroam_facilities.getFacilitiesByType("deliveryProvider").
-- Returns the facilities list, or empty table if unavailable.
function M.scanFacilities()
  -- Primary: sitesManager has all facilities
  if gameplay_sites_sitesManager and gameplay_sites_sitesManager.getFacilities then
    local facs = gameplay_sites_sitesManager.getFacilities()
    if facs and next(facs) then
      return facs
    end
  end

  -- Fallback: freeroam_facilities
  if freeroam_facilities then
    if freeroam_facilities.getFacilities then
      local grouped = freeroam_facilities.getFacilities(getCurrentLevelIdentifier())
      local facs = grouped and grouped.deliveryProviders
      if facs and next(facs) then
        return facs
      end
    end
    -- Last resort: get by type
    if freeroam_facilities.getFacilitiesByType then
      return freeroam_facilities.getFacilitiesByType("deliveryProvider") or {}
    end
  end

  log("W", "facilityScanner", "No facility source available")
  return {}
end

-------------------------------
-- Facility Processing
-------------------------------

-- Helper: convert array values to lookup dict {val=true}
local function tableValuesAsLookupDict(t)
  local lookup = {}
  if t then
    for _, v in ipairs(t) do
      lookup[v] = true
    end
  end
  return lookup
end

-- Mirrors generator.lua setupFacilities() logic for building logistic type lookups.
-- Takes raw facilities list and builds logisticTypesProvidedLookup / logisticTypesReceivedLookup
-- on each facility from their logistic types and generator definitions.
-- Also maps generatorType -> direction for lookup validation.
local generatorTypeToDirection = {
  parcelProvider = "providedSystemsLookup",
  parcelReceiver = "receivedSystemsLookup",
  vehOfferProvider = "providedSystemsLookup",
  trailerOfferProvider = "providedSystemsLookup",
  materialProvider = "providedSystemsLookup",
  materialReceiver = "receivedSystemsLookup",
}

function M.processFacilities(rawFacilities)
  if not rawFacilities then return {} end

  for _, fac in ipairs(rawFacilities) do
    -- Build logistic type lookups from facility data
    fac.logisticTypesProvided = fac.logisticTypesProvided or {}
    fac.logisticTypesReceived = fac.logisticTypesReceived or {}

    fac.logisticTypesProvidedLookup = tableValuesAsLookupDict(fac.logisticTypesProvided)
    fac.logisticTypesReceivedLookup = tableValuesAsLookupDict(fac.logisticTypesReceived)

    fac.providedSystemsLookup = fac.providedSystemsLookup or {}
    fac.receivedSystemsLookup = fac.receivedSystemsLookup or {}

    fac.logisticGenerators = fac.logisticGenerators or {}

    -- Validate generator logistic types against facility lookups
    for _, generator in ipairs(fac.logisticGenerators) do
      generator.logisticTypes = generator.logisticTypes or {}
      generator.logisticTypesLookup = tableValuesAsLookupDict(generator.logisticTypes)

      for _, logisticType in ipairs(generator.logisticTypes) do
        if generatorTypeToDirection[generator.type] == "providedSystemsLookup" then
          if not fac.logisticTypesProvidedLookup[logisticType] then
            fac.logisticTypesProvidedLookup[logisticType] = true
          end
        end
        if generatorTypeToDirection[generator.type] == "receivedSystemsLookup" then
          if not fac.logisticTypesReceivedLookup[logisticType] then
            fac.logisticTypesReceivedLookup[logisticType] = true
          end
        end
      end

      if generator.type == "vehOfferProvider" then
        fac.providedSystemsLookup.vehicleDelivery = true
      end
      if generator.type == "trailerOfferProvider" then
        fac.providedSystemsLookup.trailerDelivery = true
      end
    end

    -- Build access point logistic type lookups
    if fac.accessPointsByName then
      for _, ap in pairs(fac.accessPointsByName) do
        if ap.logisticTypesProvided then
          ap.logisticTypesProvidedLookup = tableValuesAsLookupDict(ap.logisticTypesProvided)
        end
        if ap.logisticTypesReceived then
          ap.logisticTypesReceivedLookup = tableValuesAsLookupDict(ap.logisticTypesReceived)
        end
      end
    end
  end

  return rawFacilities
end

-------------------------------
-- Facilities by Logistic Type
-------------------------------

-- Returns facilities that can provide or receive a given logistic type.
-- direction: "provided" or "received"
function M.getFacilitiesByLogisticType(logisticType, direction)
  local facilities = M.scanFacilities()
  facilities = M.processFacilities(facilities)
  local lookupKey = direction == "received" and "logisticTypesReceivedLookup" or "logisticTypesProvidedLookup"
  local result = {}
  for _, fac in ipairs(facilities) do
    if fac[lookupKey] and fac[lookupKey][logisticType] then
      table.insert(result, fac)
    end
  end
  return result
end

function M.generatorProvidesParcels(generator, allowedTypes, excludedTypes)
  if not generator or generator.type ~= "parcelProvider" then return false end
  local types = generator.logisticTypes or {}
  if not types[1] then
    return not allowedTypes
  end
  for _, logisticType in ipairs(types) do
    if not (excludedTypes and excludedTypes[logisticType]) then
      if allowedTypes then
        if allowedTypes[logisticType] then return true end
      else
        return true
      end
    end
  end
  return false
end

function M.facilityOffersKind(fac, kind, parcelTypes, audience, excludedParcelTypes)
  if not fac then return false end
  if audience then
    local wanted=({parcel="parcelProvider", materials="materialProvider", trailer="trailerOfferProvider", vehicle="vehOfferProvider"})[kind]
    local configured=false
    for _,generator in ipairs(fac.logisticGenerators or {}) do
      if generator.type == wanted then
        if generator.offerMode then
          configured=true
          if generator.offerMode == audience or generator.offerMode == "shared" then
            if kind ~= "parcel" or M.generatorProvidesParcels(generator, parcelTypes, excludedParcelTypes) then
              return true
            end
          end
        elseif kind ~= "parcel" or M.generatorProvidesParcels(generator, parcelTypes, excludedParcelTypes) then
          return true
        end
      end
    end
    if configured then return false end
  end
  if kind == "parcel" then
    for _, generator in ipairs(fac.logisticGenerators or {}) do
      if M.generatorProvidesParcels(generator, parcelTypes, excludedParcelTypes) then return true end
    end
    return fac.logisticTypesProvidedLookup and fac.logisticTypesProvidedLookup.parcel == true
  end
  if kind == "trailer" then
    if fac.providedSystemsLookup and fac.providedSystemsLookup.trailerDelivery then return true end
    for _, generator in ipairs(fac.logisticGenerators or {}) do
      if generator.type == "trailerOfferProvider" then return true end
    end
    return false
  end
  if kind == "materials" then
    if type(fac.materialStorages) == "table" and next(fac.materialStorages) then return true end
    for _, generator in ipairs(fac.logisticGenerators or {}) do
      if generator.type == "materialProvider" then return true end
    end
    local lookup = fac.logisticTypesProvidedLookup or {}
    return lookup.fluid == true or lookup.dryBulk == true or lookup.cement == true or lookup.cash == true
  end
  if kind == "vehicle" then
    if fac.providedSystemsLookup and fac.providedSystemsLookup.vehicleDelivery then return true end
    for _, generator in ipairs(fac.logisticGenerators or {}) do
      if generator.type == "vehOfferProvider" then return true end
    end
    return false
  end
  return false
end

function M.facilityMaterialTypes(fac, resolveType, allowedTypes, audience)
  local types = {}
  if not fac then return types end
  resolveType = resolveType or require("gameplay/delivery/templates").resolveMaterialBulkType
  local function note(key)
    local bulk = resolveType(key)
    if bulk and (not allowedTypes or allowedTypes[bulk]) then
      types[bulk] = true
    end
  end
  if audience then
    local configured=false
    for _,generator in ipairs(fac.logisticGenerators or {}) do
      if generator.type == "materialProvider" and generator.offerMode then configured=true end
    end
    if configured then
      for _,generator in ipairs(fac.logisticGenerators or {}) do
        if generator.type == "materialProvider" and (not generator.offerMode or generator.offerMode == audience or generator.offerMode == "shared") then note(generator.materialType) end
      end
      return types
    end
  end
  for key, enabled in pairs(fac.logisticTypesProvidedLookup or {}) do
    if enabled then note(key) end
  end
  for materialType in pairs(fac.materialStorages or {}) do
    note(materialType)
  end
  for _, generator in ipairs(fac.logisticGenerators or {}) do
    if (generator.type == "materialProvider" or generator.type == "materialReceiver") and generator.materialType then
      note(generator.materialType)
    end
  end
  for _, ap in pairs(fac.accessPointsByName or {}) do
    for key, enabled in pairs(ap.logisticTypesProvidedLookup or {}) do
      if enabled then note(key) end
    end
  end
  return types
end

function M.facilitySupportsMaterialType(fac, cargoType, resolveType, allowedTypes)
  if not fac or not cargoType then return false end
  return M.facilityMaterialTypes(fac, resolveType, allowedTypes)[cargoType] == true
end

function M.accessPointProvidesLogisticType(ap, logisticType)
  if not ap or not logisticType then return false end
  local lookup = ap.logisticTypesProvidedLookup
  if type(lookup) == "table" and lookup[logisticType] then return true end
  for _, t in ipairs(ap.logisticTypesProvided or {}) do
    if t == logisticType then return true end
  end
  return false
end

-------------------------------
-- Distance Between Locations
-------------------------------

-- Returns distance in metres plus a boolean indicating whether it came from a
-- complete navgraph route. Callers may use the direct-distance fallback for a
-- temporary estimate, but must not cache it as a finished driving route.
local tmpVec = vec3()
local function getDirectDistance(posA, posB)
  if not posA or not posB then return 0 end
  return posA:distance(posB)
end

function M.getDistanceBetweenLocations(posA, posB)
  local directDistance = getDirectDistance(posA, posB)
  if not map or not map.findClosestRoad or not map.getPath or not map.getMap then
    return directDistance, false
  end
  local name_a,_,distance_a = map.findClosestRoad(posA)
  local name_b,_,distance_b = map.findClosestRoad(posB)
  if not name_a or not name_b then return directDistance, false end
  local path = map.getPath(name_a, name_b)
  if type(path) ~= "table" or #path == 0 or (#path == 1 and name_a ~= name_b) then
    return directDistance, false
  end
  local mapData = map.getMap()
  if not mapData or not mapData.nodes then return directDistance, false end

  local d = 0
  for i = 1, #path-1 do
    local nodeA = mapData.nodes[path[i]]
    local nodeB = mapData.nodes[path[i+1]]
    if not nodeA or not nodeA.pos or not nodeB or not nodeB.pos then
      return directDistance, false
    end
    tmpVec:set(nodeA.pos)
    tmpVec:setSub(nodeB.pos)
    d = d + tmpVec:length()
  end
  d = d + (tonumber(distance_a) or 0) + (tonumber(distance_b) or 0)
  return d, true
end

return M
