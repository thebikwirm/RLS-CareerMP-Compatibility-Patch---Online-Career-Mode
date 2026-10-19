local M = {}

local DEV_KIND_ORDER = { "parcel", "trailer", "materials", "vehicle", "repo" }
local DEV_KIND_LABELS = {
  parcel = "Parcel",
  trailer = "Trailer",
  materials = "Materials",
  vehicle = "Vehicle assignment",
  repo = "Car hauling",
  vehicle_repo_bundle = "Car hauling",
  police = "Police patrol",
  bus = "Bus route",
  paramedic = "Paramedic",
}

function M.summarizeKindMap(ctx, kinds)
  if not kinds then return "none" end
  local names = {}
  for kind in pairs(kinds) do
    table.insert(names, tostring(kind))
  end
  table.sort(names)
  return #names > 0 and table.concat(names, ", ") or "none"
end

function M.describeLoanerOffer(ctx, offer)
  if not offer then return "nil" end
  local model = offer.model or offer.vehId or "?"
  local config = offer.config or offer.configKey or "?"
  local rep = offer.reputationLvl
  if rep ~= nil then
    return string.format("%s/%s (rep<=%s)", model, config, tostring(rep))
  end
  return string.format("%s/%s", model, config)
end

function M.diagnoseDispatch(ctx, facId, context)
  context = context or "dispatch"
  local gen = ctx.services.generator()
  local fac = gen and gen.getFacilityById and gen.getFacilityById(facId)
  local caps = ctx.services.loanerCaps()
  local kinds = ctx.policy.assignableKinds(facId)
  local org = ctx.policy.getOrg(ctx.employment.employerOrgId)
  local orgRep = ctx.policy.repLevel(org)
  local assignmentTier = caps and caps.getEmploymentAssignmentRepTier and caps.getEmploymentAssignmentRepTier(fac, orgRep) or nil
  local lines = {
    string.format("ctx=%s facId=%s employer=%s home=%s employed=%s onShift=%s",
      context,
      tostring(facId),
      tostring(ctx.employment.employerOrgId),
      tostring(ctx.employment.homeFacId),
      tostring(ctx.policy.isEmployed()),
      tostring(ctx.policy.isOnShift())),
    string.format("facility=%s orgMatch=%s kinds=[%s] orgRep=%s assignmentRepTier=%s",
      fac and tostring(fac.id) or "missing",
      tostring(ctx.policy.facilityMatchesEmployer(facId)),
      M.summarizeKindMap(ctx, kinds),
      tostring(orgRep),
      tostring(assignmentTier)),
  }
  if ctx.employment.shift then
    table.insert(lines, string.format("shift phase=%s kind=%s paused=%s",
      tostring(ctx.employment.shift.phase),
      tostring(ctx.employment.shift.jobKind),
      tostring(ctx.employment.shift.paused)))
  end
  if not caps then
    table.insert(lines, "loanerCapabilities module not loaded")
    return table.concat(lines, "; ")
  end
  if not fac then
    table.insert(lines, "facility lookup failed")
    return table.concat(lines, "; ")
  end
  for _, kind in ipairs({ "repo", "vehicle", "parcel", "trailer", "materials" }) do
    local canIssue = caps.canIssueLoanersForFacility(fac, kind, {})
    local truck, trailer = caps.getIssuedLoanersForFacility(fac, kind, {})
    table.insert(lines, string.format("%s canIssue=%s truck=%s trailer=%s",
      kind,
      tostring(canIssue),
      M.describeLoanerOffer(ctx, truck),
      M.describeLoanerOffer(ctx, trailer)))
  end
  return table.concat(lines, "; ")
end

function M.diagnoseNoJob(ctx, facId)
  return M.diagnoseDispatch(ctx, facId, "chooseJob")
end

function M.diagnoseLoanerFailure(ctx, fac, job, opts)
  opts = opts or {}
  local caps = ctx.services.loanerCaps()
  if not caps then
    return "loanerCapabilities module not loaded"
  end
  if not fac then
    return "facility missing for loaner pick"
  end
  local jobKind = job and job.kind or "?"
  if not caps.canIssueLoanersForFacility(fac, jobKind, opts) then
    return string.format("canIssueLoanersForFacility(%s) is false; %s",
      jobKind, M.diagnoseDispatch(ctx, fac.id, "loanerGate"))
  end
  local truck, trailer = caps.getIssuedLoanersForFacility(fac, jobKind, opts)
  if not truck then
    return string.format("getIssuedLoanersForFacility(%s) returned no truck; %s",
      jobKind, M.diagnoseDispatch(ctx, fac.id, "loanerPick"))
  end
  if jobKind == "trailer" and not trailer then
    return string.format("trailer job missing org trailer; truck=%s; %s",
      M.describeLoanerOffer(ctx, truck), M.diagnoseDispatch(ctx, fac.id, "loanerPick"))
  end
  return M.diagnoseDispatch(ctx, fac.id, "loanerPick")
end

function M.facDistanceToHome(ctx, facId)
  local homeId = ctx.employment.homeFacId
  if not homeId or not facId then return math.huge end
  if facId == homeId then return 0 end
  local gen = ctx.services.generator()
  if gen and gen.getDistanceBetweenFacilities then
    -- getDistanceBetweenFacilities returns (distance, routeReliable); only take distance.
    local dist = gen.getDistanceBetweenFacilities(facId, homeId)
    return tonumber(dist) or math.huge
  end
  return math.huge
end

function M.destMovesTowardHome(ctx, destFacId, fromFacId)
  if not destFacId or not ctx.employment.homeFacId then return false end
  if destFacId == ctx.employment.homeFacId then return true end
  local fromDist = M.facDistanceToHome(ctx, fromFacId or destFacId)
  local destDist = M.facDistanceToHome(ctx, destFacId)
  return destDist < fromDist
end

function M.collectParcelGroups(ctx, facId, towardHomeOnly)
  local parcelMgr = ctx.services.parcels()
  if not (parcelMgr and parcelMgr.getAllCargoForFacilityUnexpiredUndelivered) then return {} end
  local cargo = parcelMgr.getAllCargoForFacilityUnexpiredUndelivered(facId, nil, nil, "employment") or {}
  local byDest = {}
  for _, item in ipairs(cargo) do
    local logisticType = item.logisticType or item.lookupType
    if logisticType and ctx.excludedParcelTypes[logisticType] then
      goto continueParcel
    end
    if item.offerMode == "independent" then
      goto continueParcel
    end
    if item.offerMode == "employment" and item.organization
        and item.organization ~= ctx.employment.employerOrgId then
      goto continueParcel
    end
    if item.type == "parcel" and ctx.policy.cargoItemUnlocked(item) and item.destination and item.destination.facId and item.destination.facId ~= facId then
      if ctx.prepare.cargoHasTimedModifier(item) then
        goto continueParcel
      end
      if towardHomeOnly and not M.destMovesTowardHome(ctx, item.destination.facId, facId) then
        goto continueParcel
      end
      local key = tostring(item.destination.facId) .. "|" .. tostring(item.destination.psPath)
      byDest[key] = byDest[key] or { destination = item.destination, items = {}, facId = facId }
      table.insert(byDest[key].items, item)
    end
    ::continueParcel::
  end
  local groups = {}
  for _, group in pairs(byDest) do
    table.insert(groups, group)
  end
  table.sort(groups, function(a, b) return #a.items > #b.items end)
  return groups
end

function M.applyParcelCapacity(ctx, facId, group)
  if not group then return nil end
  local trim = ctx.planning and ctx.planning.trimParcelItems
  if not trim then return group end
  local items = trim(facId or group.facId, group.items)
  if not items or not items[1] then return nil end
  if items == group.items then return group end
  return {
    destination = group.destination,
    items = items,
    facId = group.facId,
  }
end

function M.pickParcelGroup(ctx, facId)
  local groups = ctx.prepare.parcelGroups(facId)
  return M.applyParcelCapacity(ctx, facId, groups[1])
end

function M.pickReturnParcelGroup(ctx, fromFacId)
  local groups = M.collectParcelGroups(ctx, fromFacId, true)
  local homeId = ctx.employment.homeFacId
  -- Prefer a real return to the company yard over other toward-home destinations.
  if homeId then
    for _, group in ipairs(groups) do
      if group.destination and group.destination.facId == homeId then
        local trimmed = M.applyParcelCapacity(ctx, group.facId or fromFacId, group)
        if trimmed then return trimmed end
      end
    end
  end
  if groups[1] then return M.applyParcelCapacity(ctx, groups[1].facId or fromFacId, groups[1]) end
  local gen = ctx.services.generator()
  if not (gen and gen.getFacilityById) then return nil end
  local nearestFac, nearestDist
  for _, fac in ipairs(gen.getFacilities and gen.getFacilities() or {}) do
    if fac and fac.id and fac.id ~= fromFacId then
      local dist = math.huge
      if gen.getDistanceBetweenFacilities and fromFacId then
        local d = gen.getDistanceBetweenFacilities(fromFacId, fac.id)
        dist = tonumber(d) or math.huge
      end
      local groupsAtFac = M.collectParcelGroups(ctx, fac.id, true)
      local homeGroup = nil
      if homeId then
        for _, group in ipairs(groupsAtFac) do
          if group.destination and group.destination.facId == homeId then
            homeGroup = group
            break
          end
        end
      end
      local pick = homeGroup or groupsAtFac[1]
      if pick then
        pick = M.applyParcelCapacity(ctx, fac.id, pick)
      end
      if pick and (not nearestDist or dist < nearestDist) then
        nearestFac, nearestDist = pick, dist
      end
    end
  end
  return nearestFac
end

function M.pickReturnTrailerOffer(ctx, fromFacId)
  local mgr = ctx.services.vehicleOffers()
  if not (mgr and mgr.getAllOfferAtFacilityUnexpired) then return nil end
  local function scan(facId)
    for _, offer in ipairs(mgr.getAllOfferAtFacilityUnexpired(facId, nil, "employment") or {}) do
      if offer.data and offer.data.type ~= "vehicle" and ctx.policy.trailerOfferUnlocked(offer)
          and (offer.offerMode ~= "employment" or not offer.organization
            or offer.organization == ctx.employment.employerOrgId) then
        local destFacId = offer.destination and offer.destination.facId
          or (offer.locations and offer.locations[2] and offer.locations[2].facId)
        if M.destMovesTowardHome(ctx, destFacId, facId) then
          return offer
        end
      end
    end
    return nil
  end
  local offer = scan(fromFacId)
  if offer then return offer end
  local gen = ctx.services.generator()
  if not (gen and gen.getFacilities and gen.getDistanceBetweenFacilities) then return nil end
  local nearestOffer, nearestDist
  for _, fac in ipairs(gen.getFacilities() or {}) do
    if fac and fac.id and fac.id ~= fromFacId then
      local candidate = scan(fac.id)
      if candidate then
        local d = gen.getDistanceBetweenFacilities(fromFacId, fac.id)
        local dist = tonumber(d) or math.huge
        if not nearestDist or dist < nearestDist then
          nearestOffer, nearestDist = candidate, dist
        end
      end
    end
  end
  return nearestOffer
end

function M.pickReturnVehicleOffer(ctx, fromFacId, excludedOfferIds, opts)
  local mgr = ctx.services.vehicleOffers()
  if not (mgr and mgr.getAllOfferAtFacilityUnexpired) then return nil end
  excludedOfferIds = excludedOfferIds or {}
  opts = type(opts) == "table" and opts or {}
  local homeFacId = ctx.employment and ctx.employment.homeFacId
  local spawnContext = opts.requireHomeDest and "pickHaulBackhaulVehicleOffer" or "pickReturnVehicleOffer"
  local candidates = {}
  local seenFacilities = {}
  local function scan(facId, distance)
    if not facId or seenFacilities[facId] then return end
    seenFacilities[facId] = true
    for _, offer in ipairs(mgr.getAllOfferAtFacilityUnexpired(facId, nil, "employment") or {}) do
      if offer.id and not excludedOfferIds[offer.id]
          and offer.data and offer.data.type == "vehicle" and ctx.policy.vehicleOfferUnlocked(offer) then
        local destFacId = offer.destination and offer.destination.facId
          or (offer.locations and offer.locations[2] and offer.locations[2].facId)
        local destOk = M.destMovesTowardHome(ctx, destFacId, facId)
        if destOk and opts.requireHomeDest then
          destOk = destFacId == homeFacId
        end
        if destOk then
          local ready = true
          if mgr.ensureOfferSpawnReady then
            ready = mgr.ensureOfferSpawnReady(offer, spawnContext) and true or false
          elseif mgr.isOfferSpawnReady then
            ready = mgr.isOfferSpawnReady(offer) and true or false
          end
          if ready then
            candidates[#candidates + 1] = {
              offer = offer,
              distance = tonumber(distance) or math.huge,
            }
          end
        end
      end
    end
  end
  scan(fromFacId, 0)
  local gen = ctx.services.generator()
  if gen and gen.getFacilities then
    for _, fac in ipairs(gen.getFacilities() or {}) do
      if fac and fac.id and fac.id ~= fromFacId then
        scan(fac.id, ctx.planning.distance(fromFacId, fac.id))
      end
    end
  end
  table.sort(candidates, function(a, b)
    if a.distance == b.distance then
      return tostring(a.offer.id) < tostring(b.offer.id)
    end
    return a.distance < b.distance
  end)
  return candidates[1] and candidates[1].offer or nil
end

function M.pickHaulBackhaulVehicleOffer(ctx, fromFacId, excludedOfferIds)
  return M.pickReturnVehicleOffer(ctx, fromFacId, excludedOfferIds, { requireHomeDest = true })
end

function M.pickTrailerOffer(ctx, facId)
  local mgr = ctx.services.vehicleOffers()
  if not (mgr and mgr.getAllOfferAtFacilityUnexpired) then return nil end
  local function firstOffer()
    for _, offer in ipairs(mgr.getAllOfferAtFacilityUnexpired(facId, nil, "employment") or {}) do
      if offer.data and offer.data.type ~= "vehicle" and ctx.policy.trailerOfferUnlocked(offer) then
        return offer
      end
    end
    return nil
  end
  local offer = firstOffer()
  if offer then return offer end
  local gen = ctx.services.generator()
  local fac = gen and gen.getFacilityById and gen.getFacilityById(facId)
  if gen and fac and gen.triggerGenerator then
    for _, generator in ipairs(fac.logisticGenerators or {}) do
      if generator.type == "trailerOfferProvider" then
        gen.triggerGenerator(fac, generator)
      end
    end
  end
  return firstOffer()
end

function M.collectReadyVehicleOffers(ctx, facId, minCount)
  local mgr = ctx.services.vehicleOffers()
  if not (mgr and mgr.getAllOfferAtFacilityUnexpired) then return {} end
  local gen = ctx.services.generator()
  if gen and gen.triggerAllGenerators then
    gen.triggerAllGenerators()
  end
  local ready = {}
  local function scan()
    ready = {}
    for _, offer in ipairs(mgr.getAllOfferAtFacilityUnexpired(facId, nil, "employment") or {}) do
      if offer.data and offer.data.type == "vehicle" and ctx.policy.vehicleOfferUnlocked(offer) then
        local ok, err = true, nil
        if mgr.ensureOfferSpawnReady then
          ok, err = mgr.ensureOfferSpawnReady(offer, "collectReadyVehicleOffers")
        elseif mgr.isOfferSpawnReady then
          ok = mgr.isOfferSpawnReady(offer)
          err = ok and nil or "not spawnable"
        end
        if ok then
          table.insert(ready, offer)
        else
          ctx.log("pickVehicleOffer", string.format("skipped offer %s: %s", tostring(offer.id), err or "not spawnable"))
        end
      end
    end
  end
  scan()
  if minCount and #ready < minCount and gen and gen.triggerGenerator then
    local fac = gen.getFacilityById and gen.getFacilityById(facId)
    local prev = #ready
    for _ = 1, 8 do
      if #ready >= minCount then break end
      for _, generator in ipairs((fac and fac.logisticGenerators) or {}) do
        if generator.type == "vehOfferProvider" then
          gen.triggerGenerator(fac, generator)
        end
      end
      scan()
      if #ready <= prev then break end
      prev = #ready
    end
  end
  return ready
end

function M.pickDistributorVehicleOffers(ctx, facId, count)
  count = count or ctx.distributorCount
  local offers = M.collectReadyVehicleOffers(ctx, facId, count)
  if not offers[1] then return {} end
  local byDest = {}
  local largest = nil
  for _, offer in ipairs(offers) do
    local dest = offer.destination or (offer.locations and offer.locations[2])
    local key = dest and tostring(dest.facId or dest.psPath or offer.id) or tostring(offer.id)
    byDest[key] = byDest[key] or {}
    table.insert(byDest[key], offer)
    if not largest or #byDest[key] > #largest then
      largest = byDest[key]
    end
  end
  local picked = {}
  local used = {}
  local function takeFrom(group)
    for _, offer in ipairs(group or {}) do
      if #picked >= count then return end
      if offer and offer.id and not used[offer.id] then
        used[offer.id] = true
        table.insert(picked, offer)
      end
    end
  end
  takeFrom(largest)
  takeFrom(offers)
  if #picked < count then return {} end
  local gen = ctx.services.generator()
  local fac = gen and gen.getFacilityById and gen.getFacilityById(facId)
  ctx.prepare.stageDistributor(fac, picked)
  return picked
end

function M.pickVehicleOffer(ctx, facId)
  local offers = M.collectReadyVehicleOffers(ctx, facId)
  return offers[1]
end

function M.materialTripLimits(mgr)
  if mgr and mgr.getEmploymentTripLimits then
    local preferred, max = mgr.getEmploymentTripLimits()
    if preferred and max then return preferred, max end
  end
  return 4, 6
end

function M.materialCapacityLookup(ctx, fac)
  local cache = {}
  return function(cargoType)
    if not (fac and cargoType) then return nil end
    if cache[cargoType] == nil then
      local caps = ctx.services.loanerCaps()
      local capacity = 0
      if caps and caps.getIssuedLoanersForFacility and caps.getCapacity then
        local ok, truck, trailer = pcall(caps.getIssuedLoanersForFacility, fac, "materials", { cargoType = cargoType })
        if ok and truck then
          capacity = math.max(caps.getCapacity(truck, cargoType) or 0, trailer and caps.getCapacity(trailer, cargoType) or 0)
        end
      end
      cache[cargoType] = capacity
    end
    return cache[cargoType] > 0 and cache[cargoType] or nil
  end
end

function M.materialOfferTrips(offer, capacity)
  if not (offer and capacity and capacity > 0) then return nil end
  return math.ceil((tonumber(offer.totalAmount) or 0) / capacity - 1e-6)
end

function M.materialOfferFits(offer, capacity, maxTrips)
  local trips = M.materialOfferTrips(offer, capacity)
  return not trips or not maxTrips or trips <= maxTrips
end

function M.pickMaterialOffer(ctx, facId)
  local mgr = ctx.services.materials()
  if not mgr then return nil end
  local fac = ctx.services.generator() and ctx.services.generator().getFacilityById and ctx.services.generator().getFacilityById(facId)
  local caps = ctx.services.loanerCaps()
  local preferredTrips, maxTrips = M.materialTripLimits(mgr)
  local capacityFor = M.materialCapacityLookup(ctx, fac)
  local function offerIssuable(offer)
    if not offer or not ctx.policy.materialOfferUnlocked(offer) then return false end
    if offer.offerExpiresAt and offer.offerExpiresAt <= ctx.nowSim() then return false end
    if not (fac and caps) then return true end
    return ctx.policy.canIssueMaterials(fac, offer.cargoType)
  end
  local function fits(offer, trips)
    return M.materialOfferFits(offer, capacityFor(offer.cargoType), trips)
  end
  local function firstLiveOffer(trips)
    if not mgr.getOffersForFacility then return nil end
    for _, offer in ipairs(mgr.getOffersForFacility(facId, "employment") or {}) do
      if offerIssuable(offer) and fits(offer, trips) then
        return offer
      end
    end
    return nil
  end
  local offer = firstLiveOffer(preferredTrips)
  if offer then return offer end
  if mgr.generateSizedOffer then
    offer = mgr.generateSizedOffer(facId, {
      audience = "employment",
      allows = function(shape) return ctx.policy.materialOfferUnlocked(shape) and ctx.policy.canIssueMaterials(fac, shape.cargoType) end,
      tripCapacity = capacityFor,
      replaceable = function(existing) return not fits(existing, preferredTrips) end,
    })
    if offer and offerIssuable(offer) and fits(offer, maxTrips) then return offer end
  end
  if mgr.generateOfferForFacility then
    for _ = 1, 3 do
      offer = mgr.generateOfferForFacility(facId)
      if offer and offerIssuable(offer) and fits(offer, preferredTrips) then
        return offer
      end
    end
  end
  return firstLiveOffer(maxTrips)
end

function M.iterFacilitiesPreferOrg(ctx, homeFacId, orgId, fn)
  local gen = ctx.services.generator()
  if not (gen and gen.getFacilities) then return nil end
  local function pass(preferOrgOnly)
    for _, fac in ipairs(gen.getFacilities() or {}) do
      if fac and fac.id and fac.id ~= homeFacId then
        if (not preferOrgOnly) or (orgId and fac.associatedOrganization == orgId) then
          local result = fn(fac)
          if result then return result end
        end
      end
    end
    return nil
  end
  return pass(true) or pass(false)
end

function M.pickInboundParcelGroup(ctx, homeFacId)
  if not homeFacId then return nil end
  local orgId = ctx.employment.employerOrgId
  local gen = ctx.services.generator()
  local homeFac = gen and gen.getFacilityById and gen.getFacilityById(homeFacId)
  orgId = orgId or (homeFac and homeFac.associatedOrganization)
  return M.iterFacilitiesPreferOrg(ctx, homeFacId, orgId, function(fac)
    for _, group in ipairs(M.collectParcelGroups(ctx, fac.id, false)) do
      if group.destination and group.destination.facId == homeFacId then
        group.facId = group.facId or fac.id
        local trimmed = M.applyParcelCapacity(ctx, fac.id, group)
        if trimmed then return trimmed end
      end
    end
    return nil
  end)
end

function M.pickInboundTrailerOffer(ctx, homeFacId)
  if not homeFacId then return nil end
  local mgr = ctx.services.vehicleOffers()
  if not (mgr and mgr.getAllOfferAtFacilityUnexpired) then return nil end
  local orgId = ctx.employment.employerOrgId
  local gen = ctx.services.generator()
  local homeFac = gen and gen.getFacilityById and gen.getFacilityById(homeFacId)
  orgId = orgId or (homeFac and homeFac.associatedOrganization)
  return M.iterFacilitiesPreferOrg(ctx, homeFacId, orgId, function(fac)
    for _, offer in ipairs(mgr.getAllOfferAtFacilityUnexpired(fac.id, nil, "employment") or {}) do
      if offer.data and offer.data.type ~= "vehicle" and ctx.policy.trailerOfferUnlocked(offer) then
        local destFacId = offer.destination and offer.destination.facId
          or (offer.locations and offer.locations[2] and offer.locations[2].facId)
        if destFacId == homeFacId then
          return offer
        end
      end
    end
    return nil
  end)
end

function M.pickInboundMaterialOffer(ctx, homeFacId)
  if not homeFacId then return nil end
  local mgr = ctx.services.materials()
  local gen = ctx.services.generator()
  local caps = ctx.services.loanerCaps()
  if not (mgr and gen and gen.getFacilityById) then return nil end
  local homeFac = gen.getFacilityById(homeFacId)
  local orgId = ctx.employment.employerOrgId or (homeFac and homeFac.associatedOrganization)
  local _, maxTrips = M.materialTripLimits(mgr)
  local capacityFor = M.materialCapacityLookup(ctx, homeFac)
  local function offerOk(offer)
    if not offer or not ctx.policy.materialOfferUnlocked(offer) then return false end
    if offer.offerExpiresAt and offer.offerExpiresAt <= ctx.nowSim() then return false end
    local destId = offer.destinationFacId or (offer.destination and offer.destination.facId)
    if destId ~= homeFacId then return false end
    if not (homeFac and caps) then return true end
    return ctx.policy.canIssueMaterials(homeFac, offer.cargoType)
      and M.materialOfferFits(offer, capacityFor(offer.cargoType), maxTrips)
  end
  return M.iterFacilitiesPreferOrg(ctx, homeFacId, orgId, function(fac)
    if mgr.generateOfferForFacility and #(mgr.getOffersForFacility(fac.id, "employment") or {}) == 0 then
      for _ = 1, 2 do
        mgr.generateOfferForFacility(fac.id)
      end
    end
    for _, offer in ipairs(mgr.getOffersForFacility(fac.id, "employment") or {}) do
      if offerOk(offer) then
        return offer
      end
    end
    return nil
  end)
end

function M.pickInboundVehicleOffer(ctx, homeFacId)
  if not homeFacId then return nil end
  local mgr = ctx.services.vehicleOffers()
  if not (mgr and mgr.getAllOfferAtFacilityUnexpired) then return nil end
  local orgId = ctx.employment.employerOrgId
  local gen = ctx.services.generator()
  local homeFac = gen and gen.getFacilityById and gen.getFacilityById(homeFacId)
  orgId = orgId or (homeFac and homeFac.associatedOrganization)
  local function tryPick(requireHomeDest)
    return M.iterFacilitiesPreferOrg(ctx, homeFacId, orgId, function(fac)
      if not ctx.policy.facilityOffersKind(fac, "vehicle") then return nil end
      for _, offer in ipairs(mgr.getAllOfferAtFacilityUnexpired(fac.id, nil, "employment") or {}) do
        if offer.data and offer.data.type == "vehicle" and ctx.policy.vehicleOfferUnlocked(offer) then
          local destOk = true
          if requireHomeDest then
            local destFacId = offer.destination and offer.destination.facId
              or (offer.locations and offer.locations[2] and offer.locations[2].facId)
            destOk = destFacId == homeFacId
          end
          if destOk then
            local ready = true
            if mgr.ensureOfferSpawnReady then
              ready = mgr.ensureOfferSpawnReady(offer, "pickInboundVehicleOffer")
            elseif mgr.isOfferSpawnReady then
              ready = mgr.isOfferSpawnReady(offer)
            end
            if ready then
              return offer
            end
          end
        end
      end
      return nil
    end)
  end
  return tryPick(true) or tryPick(false)
end

function M.surgeLeaf(ctx, kind, cargoType)
  if kind == "parcel" then return "delivery_parcel" end
  if kind == "trailer" then return "delivery_trailer" end
  if kind == "vehicle" then return "delivery_vehicle" end
  if kind == "vehicle_repo_bundle" then return "delivery_vehicle" end
  if kind == "repo" then return "repo" end
  if kind == "materials" then
    if cargoType == "fluid" then return "delivery_fluid" end
    if cargoType == "dryBulk" then return "delivery_dryBulk" end
    if cargoType == "cement" then return "delivery_cement" end
    return "delivery_fluid"
  end
  return nil
end

function M.dispatchSurgeLeaf(ctx, kind, cargoType)
  return M.surgeLeaf(ctx, kind, cargoType) or "delivery_parcel"
end

function M.dispatchKindBaseWeight(ctx, kind, cargoType)
  return 1.0
end

function M.dispatchSurgeWeight(ctx, kind, cargoType)
  local base = M.dispatchKindBaseWeight(ctx, kind, cargoType)
  if career_modules_activityHeat and career_modules_activityHeat.getDemandFactor then
    local factor = career_modules_activityHeat.getDemandFactor(M.dispatchSurgeLeaf(ctx, kind, cargoType))
    local surge = math.max(0.05, tonumber(factor) or 1)
    return base * surge
  end
  return base
end

function M.chooseWeightedJobOption(ctx, options)
  if not options or not options[1] then return nil end
  if #options == 1 then return options[1] end
  local total = 0
  for _, option in ipairs(options) do
    option._weight = M.dispatchSurgeWeight(ctx, option.kind, option.cargoType)
    total = total + option._weight
  end
  if total <= 0 then return options[((math.floor(ctx.nowSim()) % #options) + 1)] end
  local roll = math.random() * total
  for _, option in ipairs(options) do
    roll = roll - option._weight
    if roll <= 0 then return option end
  end
  return options[#options]
end

function M.parcelGroupTargetLoad(ctx, group)
  local total = 0
  for _, item in ipairs((group and group.items) or {}) do
    total = total + math.max(1, math.floor(tonumber(item.slots) or 1))
  end
  return total
end

function M.vehicleOfferRollbackPolicy(ctx, vehicleOffer, fac, loanerCaps)
  local vehicle = vehicleOffer and vehicleOffer.vehicle or {}
  local filterId = vehicle.filterId or (vehicleOffer and vehicleOffer.filterId)
  local unlockTag = vehicle.unlockTag or (vehicleOffer and vehicleOffer.unlockTag)
  local model = vehicle.model or (vehicleOffer and vehicleOffer.model)
  local isHeavy = filterId == "heavyVehFilter" or unlockTag == "heavyVeh"
  local requireTSeriesRollback = not isHeavy and model == "pickup"
  if isHeavy then return false, false end
  if requireTSeriesRollback then
    local available = loanerCaps and loanerCaps.canIssueTSeriesRollbackRepoForFacility
      and loanerCaps.canIssueTSeriesRollbackRepoForFacility(fac, {})
    return available and true or false, true
  end
  return true, false
end

function M.buildJobOptions(ctx, facId)
  local fac = ctx.services.generator() and ctx.services.generator().getFacilityById and ctx.services.generator().getFacilityById(facId)
  local profile, org = ctx.policy.facilityProfile(facId)
  if not org then
    org = ctx.policy.getOrg(ctx.employment.employerOrgId)
  end
  if ctx.policy.isRoleplayProfile(profile) then
    local caps = ctx.services.loanerCaps()
    if caps and caps.canIssueRoleplayVehicleForFacility(fac, {}) then
      return { ctx.policy.makeRoleplayJob(profile) }
    end
    local _, fleet
    if caps and caps.getServiceFleetForFacility then _, fleet = caps.getServiceFleetForFacility(fac) end
    return {}, (fleet and fleet.unavailableReason) or "No company vehicle is unlocked yet"
  end

  org = ctx.policy.getOrg(ctx.employment.employerOrgId) or org
  -- Vehicle pick used to be the only path that refreshed generators, so parcel/trailer
  -- yards with empty boards always fell through to car jockeys on the first clock-in.
  local gen = ctx.services.generator()
  if gen and gen.triggerAllGenerators then
    gen.triggerAllGenerators()
  elseif gen and fac and gen.triggerGenerator then
    for _, generator in ipairs(fac.logisticGenerators or {}) do
      gen.triggerGenerator(fac, generator)
    end
  end

  local kinds = ctx.policy.assignableKinds(facId)
  if ctx.policy.distributorHaul(fac) then
    if not kinds.vehicle then
      return {}, M.diagnoseNoJob(ctx, facId)
    end
    local offers = M.pickDistributorVehicleOffers(ctx, facId, ctx.distributorCount)
    if #offers < ctx.distributorCount then
      return {}, M.diagnoseNoJob(ctx, facId)
    end
    local first = offers[1]
    local dest = first.destination or (first.locations and first.locations[2])
    local origin = first.origin or (first.locations and first.locations[1])
    local ids = {}
    for _, offer in ipairs(offers) do
      table.insert(ids, offer.id)
    end
    local destName = ctx.labels.destination(dest)
    return {
      {
        kind = "vehicle",
        distributorHaul = true,
        offerId = ids[1],
        offerIds = ids,
        destFacId = dest and dest.facId,
        destPsPath = dest and dest.psPath,
        destLocation = dest,
        originLocation = origin,
        label = #ids > 1
          and string.format("Haul %d vehicles to %s", #ids, destName)
          or string.format("Deliver %s to %s", first.name or "assigned vehicle", destName),
        subtext = "Company truck and trailer issued — no return freight",
      }
    }
  end
  if ctx.policy.isParcelStringEmployer(facId) then
    local stringJob = ctx.planning.parcelString(facId)
    if stringJob then
      return { stringJob }
    end
  end
  local parcelGroup = kinds.parcel and M.pickParcelGroup(ctx, facId) or nil
  local parcelInbound = false
  if kinds.parcel and not parcelGroup then
    parcelGroup = M.pickInboundParcelGroup(ctx, facId)
    parcelInbound = parcelGroup ~= nil
  end
  local trailerOffer = kinds.trailer and M.pickTrailerOffer(ctx, facId) or nil
  local trailerInbound = false
  if kinds.trailer and not trailerOffer then
    trailerOffer = M.pickInboundTrailerOffer(ctx, facId)
    trailerInbound = trailerOffer ~= nil
  end
  local vehicleOffer = kinds.vehicle and M.pickVehicleOffer(ctx, facId) or nil
  if kinds.vehicle and not vehicleOffer then
    vehicleOffer = M.pickInboundVehicleOffer(ctx, facId)
  end
  local materialOffer = kinds.materials and M.pickMaterialOffer(ctx, facId) or nil
  local materialInbound = false
  if kinds.materials and not materialOffer then
    materialOffer = M.pickInboundMaterialOffer(ctx, facId)
    materialInbound = materialOffer ~= nil
  end
  local options = {}
  if parcelGroup then
    local ids = {}
    for _, item in ipairs(parcelGroup.items) do table.insert(ids, item.id) end
    local targetLoad = M.parcelGroupTargetLoad(ctx, parcelGroup)
    if fac and ctx.services.loanerCaps() and ctx.services.loanerCaps().canIssueLoanersForFacility(fac, "parcel", { targetLoad = targetLoad }) then
      local pickupFacId = parcelGroup.facId
        or (parcelGroup.items[1] and parcelGroup.items[1].origin and parcelGroup.items[1].origin.facId)
        or facId
      local pickupName = ctx.labels.facility(pickupFacId)
      local destName = ctx.labels.destination(parcelGroup.destination)
      table.insert(options, {
        kind = "parcel",
        cargoIds = ids,
        destFacId = parcelGroup.destination.facId,
        destPsPath = parcelGroup.destination.psPath,
        destLocation = parcelGroup.destination,
        originLocation = parcelGroup.items[1] and parcelGroup.items[1].origin
          or { type = "facilityParkingspot", facId = pickupFacId },
        needsRemotePickup = parcelInbound or (pickupFacId ~= facId),
        pickupFacId = pickupFacId,
        label = (parcelInbound or pickupFacId ~= facId)
          and string.format("Pick up parcels at %s, deliver to %s", pickupName, destName)
          or string.format("Deliver assigned parcels to %s", destName),
        subtext = string.format("%d assigned parcels", #ids),
      })
    end
  end
  if trailerOffer and fac and ctx.services.loanerCaps() and ctx.services.loanerCaps().canIssueLoanersForFacility(fac, "trailer", {
    couplerClass = ctx.services.loanerCaps().getOfferCouplerClass and ctx.services.loanerCaps().getOfferCouplerClass(trailerOffer) or nil,
  }) then
    local dest = trailerOffer.destination or (trailerOffer.locations and trailerOffer.locations[2])
    local origin = trailerOffer.origin or (trailerOffer.locations and trailerOffer.locations[1])
    local pickupFacId = origin and origin.facId or facId
    local pickupName = ctx.labels.facility(pickupFacId)
    local destName = ctx.labels.destination(dest)
    table.insert(options, {
      kind = "trailer",
      offerId = trailerOffer.id,
      destFacId = dest and dest.facId,
      destPsPath = dest and dest.psPath,
      destLocation = dest,
      originLocation = origin,
      couplerClass = ctx.services.loanerCaps().getOfferCouplerClass and ctx.services.loanerCaps().getOfferCouplerClass(trailerOffer) or nil,
      label = (trailerInbound or pickupFacId ~= facId)
        and string.format("Pick up trailer at %s, deliver to %s", pickupName, destName)
        or string.format("Tow the assigned trailer to %s", destName),
      subtext = trailerOffer.name or "Assigned trailer",
    })
  end
  local yardName = (fac and ctx.labels.translate(fac.name, fac.id))
    or ctx.labels.organization(ctx.policy.getOrg(fac and fac.associatedOrganization or ctx.employment.employerOrgId), ctx.employment.employerOrgId)
  local loanerCaps = ctx.services.loanerCaps()
  if vehicleOffer and fac and loanerCaps then
    local dest = vehicleOffer.destination or (vehicleOffer.locations and vehicleOffer.locations[2])
    local vehName = vehicleOffer.name or "assigned vehicle"
    local useRollback, requireTSeriesRollback = M.vehicleOfferRollbackPolicy(ctx, vehicleOffer, fac, loanerCaps)
    local option = {
      offerId = vehicleOffer.id,
      destFacId = dest and dest.facId,
      destPsPath = dest and dest.psPath,
      destLocation = dest,
      originLocation = vehicleOffer.origin or (vehicleOffer.locations and vehicleOffer.locations[1]),
    }
    if useRollback then
      option.kind = "vehicle_repo_bundle"
      option.requireTSeriesRollback = requireTSeriesRollback and true or nil
      option.vehicleLabel = string.format("Deliver %s to %s", vehName, ctx.labels.destination(dest))
      option.vehicleSubtext = "Car hauling"
      option.repoLabel = "Pickup — haul a vehicle back to the yard"
      option.repoSubtext = "Company rollback"
      option.label = "Car hauling"
      option.subtext = string.format("Deliver the %s, then pick up another vehicle for %s", vehName, yardName)
    else
      option.kind = "vehicle"
      option.label = "Vehicle delivery"
      option.subtext = string.format("Drive the %s to %s", vehName, ctx.labels.destination(dest))
    end
    table.insert(options, option)
  end
  if materialOffer and fac and ctx.policy.canIssueMaterials(fac, materialOffer.cargoType) then
    local materialName = ctx.labels.translate(materialOffer.materialName, materialOffer.materialType or "material")
    local destName = ctx.labels.translate(materialOffer.destinationName, "the receiver")
    local sourceName = ctx.labels.translate(materialOffer.sourceName, materialOffer.sourceFacId or "the loader")
    local pickupFacId = materialOffer.sourceFacId
      or (materialOffer.origin and materialOffer.origin.facId)
      or facId
    table.insert(options, {
      kind = "materials",
      contractId = materialOffer.id,
      cargoType = materialOffer.cargoType,
      standardLoad = math.min(materialOffer.totalAmount or math.huge, materialOffer.standardLoad),
      materialName = materialName,
      destFacId = materialOffer.destination and materialOffer.destination.facId,
      destPsPath = materialOffer.destination and materialOffer.destination.psPath,
      originLocation = materialOffer.origin,
      destLocation = materialOffer.destination,
      label = (materialInbound or pickupFacId ~= facId)
        and string.format("Pick up %s at %s, deliver to %s", materialName, sourceName, destName)
        or string.format("Load %s, then deliver to %s", materialName, destName),
      subtext = (materialInbound or pickupFacId ~= facId)
        and string.format("Company truck at the yard — load at %s", sourceName)
        or "Go to the marked loading point",
    })
  end
  if kinds.repo and not vehicleOffer and fac and ctx.services.loanerCaps() and ctx.services.loanerCaps().canIssueRepoForFacility(fac, {}) then
    table.insert(options, {
      kind = "repo",
      label = "Pickup — haul a vehicle back to the yard",
      subtext = string.format("Company rollback for %s", yardName),
    })
  end
  if #options == 0 then
    return {}, M.diagnoseNoJob(ctx, facId)
  end
  return options
end

function M.chooseJob(ctx, facId)
  local options, err = M.buildJobOptions(ctx, facId)
  if not options or #options == 0 then
    return nil, err or M.diagnoseNoJob(ctx, facId)
  end
  return M.chooseWeightedJobOption(ctx, options)
end

function M.selectedJobKind(ctx, selection)
  if type(selection) == "string" then return selection end
  if type(selection) == "table" and selection.kind then return tostring(selection.kind) end
  return nil
end

function M.resolveSelectedJob(ctx, facId, selection)
  local kind = M.selectedJobKind(ctx, selection)
  if not kind or kind == "" then
    return nil, "No job selected."
  end
  local options, err = M.buildJobOptions(ctx, facId)
  if kind == "parcel" and (not options or not options[1]) then
    ctx.prepare.parcelGroups(facId)
    options, err = M.buildJobOptions(ctx, facId)
  end
  if not options or #options == 0 then
    if kind == "parcel" then
      return nil, "No parcel loads are ready at this yard yet. Try again in a moment."
    end
    return nil, err or M.diagnoseNoJob(ctx, facId)
  end
  for _, option in ipairs(options) do
    if option.kind == kind then
      return option
    end
  end
  if kind == "vehicle" or kind == "hauling" then
    for _, option in ipairs(options) do
      if option.kind == "vehicle_repo_bundle" then
        return option
      end
    end
  end
  if kind == "vehicle_repo_bundle" then
    for _, option in ipairs(options) do
      if option.kind == "vehicle_repo_bundle" then
        return option
      end
    end
  end
  return nil, string.format("No live %s job ready at this yard.", DEV_KIND_LABELS[kind] or kind)
end

function M.getDevJobOptions(ctx, facId)
  if not ctx.policy.isDevToolsEnabled() then
    return { ok = false, message = "Dev key required.", options = {} }
  end
  local list = {}
  local profile = select(1, ctx.policy.facilityProfile(facId))
  if ctx.policy.isRoleplayProfile(profile) then
    list[1] = {
      id = profile,
      kind = profile,
      label = DEV_KIND_LABELS[profile] or profile,
      subtext = "Roleplay shift",
    }
    return { ok = true, options = list }
  end
  local gen = ctx.services.generator()
  local fac = gen and gen.getFacilityById and gen.getFacilityById(facId)
  if fac and ctx.policy.distributorHaul(fac) then
    list[1] = {
      id = "vehicle",
      kind = "vehicle",
      label = "Car hauling",
      subtext = "Multiple vehicles to one dealer — truck and trailer by rep",
    }
    return { ok = true, options = list }
  end
  local kinds = ctx.policy.assignableKinds(facId)
  for _, kind in ipairs(DEV_KIND_ORDER) do
    if kinds[kind] then
      -- Vehicle + repo at the same yard is issued as one bundle; don't list repo twice.
      if kind == "repo" and kinds.vehicle then
        goto continue
      end
      list[#list + 1] = {
        id = kind,
        kind = kind,
        label = DEV_KIND_LABELS[kind] or kind,
        subtext = "Force this job type on clock-in",
      }
    end
    ::continue::
  end
  return {
    ok = true,
    options = list,
    message = (#list == 0) and "No job types available at this yard." or nil,
  }
end

return M
