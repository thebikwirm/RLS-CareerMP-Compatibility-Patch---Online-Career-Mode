local M = {}
local runtime = {}

function M.issuedVehicleNeedsRepair(ctx)
  local shift = ctx.getState().shift
  if not shift or not ctx.services.insurance() then return false end
  for _, inventoryId in ipairs(shift.issuedInventoryIds or {}) do
    if ctx.services.insurance().inventoryVehNeedsRepair(inventoryId) then
      return true
    end
  end
  return false
end

function M.collectCompanyInventoryIds(ctx)
  local ids, seen = {}, {}
  local function add(id)
    id = tonumber(id) or id
    if id and not seen[id] then
      seen[id] = true
      table.insert(ids, id)
    end
  end
  if ctx.getState().shift then
    for _, id in ipairs(ctx.getState().shift.issuedInventoryIds or {}) do add(id) end
  end
  if ctx.services.inventory() and ctx.services.inventory().getVehicles then
    for inventoryId, vehInfo in pairs(ctx.services.inventory().getVehicles() or {}) do
      if vehInfo and vehInfo.loanType == "company" then
        local orgId = ctx.callbacks.getActiveShiftOrgId()
        if orgId and vehInfo.owningOrganization == orgId then
          add(inventoryId)
        end
      end
    end
  end
  return ids
end

function M.deleteCargoOnCompanyVehicles(ctx)
  local parcelMgr = ctx.services.parcels()
  if not (parcelMgr and parcelMgr.getAllCargoInVehicles and parcelMgr.changeCargoLocation) then return end
  local issuedInv = {}
  for _, inventoryId in ipairs(M.collectCompanyInventoryIds(ctx) or {}) do
    issuedInv[tonumber(inventoryId) or inventoryId] = true
  end
  if not next(issuedInv) then return end
  local inventory = ctx.services.inventory()
  for _, cargo in ipairs(parcelMgr.getAllCargoInVehicles(true) or {}) do
    local vehId = cargo and cargo.location and cargo.location.vehId
    local invId = vehId and inventory and inventory.getInventoryIdFromVehicleId and inventory.getInventoryIdFromVehicleId(vehId)
    if invId and issuedInv[tonumber(invId) or invId] and cargo.id then
      parcelMgr.changeCargoLocation(cargo.id, { type = "deleted" })
    end
  end
end

function M.deleteOrphanedVehicleCargo(ctx)
  local parcelMgr = ctx.services.parcels()
  if not (parcelMgr and parcelMgr.getAllCargoInVehicles and parcelMgr.changeCargoLocation) then return end
  for _, cargo in ipairs(parcelMgr.getAllCargoInVehicles(true) or {}) do
    local vehId = cargo and cargo.location and cargo.location.vehId
    if cargo.id and vehId and not (be and be.getObjectByID and be:getObjectByID(vehId)) then
      if cargo._transientMove and parcelMgr.clearTransientMoveForCargo then
        parcelMgr.clearTransientMoveForCargo(cargo.id)
      end
      parcelMgr.changeCargoLocation(cargo.id, { type = "deleted" })
    end
  end
end

function M.returnIssuedVehicles(ctx)
  if not ctx.services.loaners() then return end
  ctx.services.loaners().stepOutIfInCompanyVehicle()
  ctx.services.loaners().returnVehicles(M.collectCompanyInventoryIds(ctx))
end

function M.clearCompanyEquipmentThen(ctx, callback)
  if core_groundMarkers and core_groundMarkers.setPath then
    core_groundMarkers.setPath(nil)
  end
  if freeroam_bigMapMode and freeroam_bigMapMode.resetRoute then
    freeroam_bigMapMode.resetRoute()
  end
  if not ctx.services.loaners() or not ctx.services.loaners().returnVehicle then
    if callback then callback() end
    return
  end
  local ids = M.collectCompanyInventoryIds(ctx)
  if not ids[1] then
    if callback then callback() end
    return
  end
  M.deleteCargoOnCompanyVehicles(ctx)
  M.deleteOrphanedVehicleCargo(ctx)
  ctx.services.loaners().stepOutIfInCompanyVehicle()
  ctx.services.loaners().returnVehicles(ids, callback)
end

function M.handoffCompanyEquipmentThen(ctx, callback)
  local previousHandoff = ctx.getState().companyEquipmentHandoff
  ctx.getState().companyEquipmentHandoff = true
  M.clearCompanyEquipmentThen(ctx, function(returned)
    ctx.getState().companyEquipmentHandoff = previousHandoff
    if callback then callback(returned) end
  end)
end

function M.playerInIssuedCompanyTruck(ctx)
  if not (ctx.services.inventory() and ctx.services.inventory().getInventoryIdFromVehicleId) then
    return false
  end
  local vehId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0)
  if not vehId or vehId < 0 then return false end
  local inventoryId = ctx.services.inventory().getInventoryIdFromVehicleId(vehId)
  local vehInfo = inventoryId and ctx.services.inventory().getVehicles()[inventoryId]
  return vehInfo and vehInfo.loanType == "company" and vehInfo.owningOrganization == ctx.callbacks.getActiveShiftOrgId()
end

function M.markIssued(ctx, offer)
  if not offer or not ctx.services.loaners() then return end
  local serviceFacId = ctx.getState().shift and ctx.getState().shift.shiftOrgId and ctx.getState().shift.originFacId
  ctx.services.loaners().markCompanyOfferForSpawning(offer,
    serviceFacId or ctx.getState().homeFacId or (ctx.getState().shift and ctx.getState().shift.originFacId), "employment")
end

function M.captureIssuedInventoryIds(ctx)
  local ids = {}
  if not ctx.services.inventory() then return ids end
  local orgId = ctx.callbacks.getActiveShiftOrgId()
  for inventoryId, vehInfo in pairs(ctx.services.inventory().getVehicles() or {}) do
    if orgId and vehInfo.owningOrganization == orgId and vehInfo.loanType == "company" then
      table.insert(ids, inventoryId)
    end
  end
  return ids
end

function M.shiftLoanerKind(ctx, shift)
  if ctx.callbacks.isBundleShift(shift) then return "repo" end
  if ctx.callbacks.isDistributorHaulShift(shift) then return "trailer" end
  return shift and shift.jobKind
end

function M.bundleNeedsRepoTruckSpawn(ctx, shift)
  if not ctx.callbacks.isBundleShift(shift) then return false end
  return not M.companyInventoryHasRepoTruck(ctx, shift.requireTSeriesRollback)
end

function M.issueBundleRepoTruck(ctx, fac, onReady)
  local caps = ctx.services.loanerCaps()
  local loanerOpts = {
    requireTSeriesRollback = ctx.getState().shift and ctx.getState().shift.requireTSeriesRollback or nil,
  }
  local truck = caps and caps.getIssuedLoanersForFacility(fac, "repo", loanerOpts) or nil
  if not truck then
    return false, ctx.callbacks.diagnoseLoanerFailure(fac, { kind = "repo" }, loanerOpts)
  end
  M.markIssued(ctx, truck)
  M.spawnCompanyOffers(ctx, onReady)
  return true
end

function M.forEachSpot(ctx, spots, fn)
  if type(spots) ~= "table" then return end
  if spots[1] then
    for _, spot in ipairs(spots) do fn(spot) end
  else
    for _, spot in pairs(spots) do
      if type(spot) == "table" then fn(spot) end
    end
  end
end

function M.inventoryEntriesForIds(ctx, ids)
  local vehicles = {}
  if not ctx.services.inventory() then return vehicles end
  for _, inventoryId in ipairs(ids or {}) do
    table.insert(vehicles, {
      vehInfo = ctx.services.inventory().getVehicles()[inventoryId],
      vehId = ctx.services.inventory().getVehicleIdFromInventoryId
        and ctx.services.inventory().getVehicleIdFromInventoryId(inventoryId),
    })
  end
  return vehicles
end

function M.isCompanyTrailer(ctx, vehInfo, vehId)
  local caps = ctx.services.loanerCaps()
  if caps and caps.isInventoryTrailer then
    return caps.isInventoryTrailer(vehInfo, vehId)
  end
  if vehInfo and vehInfo.model and core_vehicles and core_vehicles.getModel then
    local modelInfo = core_vehicles.getModel(vehInfo.model)
    local modelData = modelInfo and (modelInfo.model or modelInfo)
    if modelData and modelData.Type == "Trailer" then return true end
  end
  local obj = vehId and getObjectByID(vehId)
  if obj and obj.getField then
    local jbeam = obj:getField("JBeam", "0")
    if jbeam and core_vehicles and core_vehicles.getModel then
      local modelInfo = core_vehicles.getModel(jbeam)
      local modelData = modelInfo and (modelInfo.model or modelInfo)
      if modelData and modelData.Type == "Trailer" then return true end
    end
  end
  return false
end

function M.inventoryVehAsLoanerOffer(ctx, vehInfo)
  local caps = ctx.services.loanerCaps()
  if caps and caps.inventoryVehAsOffer then
    return caps.inventoryVehAsOffer(vehInfo)
  end
  if not vehInfo or not vehInfo.model then return nil end
  local config = vehInfo.config
  if type(config) == "table" then
    if config.partConfigFilename and path and path.splitWithoutExt then
      local _, configKey = path.splitWithoutExt(config.partConfigFilename)
      config = configKey
    else
      config = config.key or config.config
    end
  end
  if type(config) ~= "string" or config == "" then return nil end
  return { model = vehInfo.model, config = config }
end

function M.companyInventoryHasTrailer(ctx)
  if not ctx.services.inventory() then return false end
  local vehicles = M.inventoryEntriesForIds(ctx, M.collectCompanyInventoryIds(ctx))
  local caps = ctx.services.loanerCaps()
  if caps and caps.inventoryHasTrailer then
    return caps.inventoryHasTrailer(vehicles)
  end
  for _, entry in ipairs(vehicles) do
    if M.isCompanyTrailer(ctx, entry.vehInfo, entry.vehId) then
      return true
    end
  end
  return false
end

function M.companyInventoryHasTowTractor(ctx, couplerClass)
  if not ctx.services.inventory() then return false end
  local vehicles = M.inventoryEntriesForIds(ctx, M.collectCompanyInventoryIds(ctx))
  local caps = ctx.services.loanerCaps()
  if caps and caps.inventoryHasTowTractor then
    return caps.inventoryHasTowTractor(vehicles, couplerClass)
  end
  if not (caps and caps.canTowTrailer) then return false end
  local towOpts = couplerClass and { couplerClass = couplerClass } or nil
  for _, entry in ipairs(vehicles) do
    local offer = M.inventoryVehAsLoanerOffer(ctx, entry.vehInfo)
    if offer and caps.canTowTrailer(offer, towOpts) then
      return true
    end
  end
  return false
end

function M.companyInventoryHasRepoTruck(ctx, requireTSeriesRollback)
  if not ctx.services.inventory() then return false end
  local vehicles = M.inventoryEntriesForIds(ctx, M.collectCompanyInventoryIds(ctx))
  local caps = ctx.services.loanerCaps()
  local inventoryHelper = requireTSeriesRollback and caps and caps.inventoryHasTSeriesRollbackRepoTruck
    or caps and caps.inventoryHasRepoTruck
  if inventoryHelper then
    return inventoryHelper(vehicles)
  end
  local repoCheck = requireTSeriesRollback and caps and caps.canDoTSeriesRollbackRepoJob
    or caps and caps.canDoRepoJob
  if not repoCheck then return false end
  for _, entry in ipairs(vehicles) do
    local offer = M.inventoryVehAsLoanerOffer(ctx, entry.vehInfo)
    if offer and repoCheck(offer) then
      return true
    end
  end
  return false
end

function M.canReuseIssuedEquipmentForJob(ctx, jobKind, couplerClass, jobOpts)
  local ids = M.captureIssuedInventoryIds(ctx)
  if not ids[1] then return false end
  local caps = ctx.services.loanerCaps()
  if caps and caps.canReuseIssuedEquipmentForJob then
    return caps.canReuseIssuedEquipmentForJob(jobKind, couplerClass, {
      issuedVehicles = M.inventoryEntriesForIds(ctx, ids),
      companyVehicles = M.inventoryEntriesForIds(ctx, M.collectCompanyInventoryIds(ctx)),
      cargoType = jobOpts and jobOpts.cargoType,
      targetLoad = jobOpts and jobOpts.targetLoad,
    })
  end
  if jobKind == "trailer" then
    return M.companyInventoryHasTowTractor(ctx, couplerClass)
  end
  if jobKind == "repo" then
    local issued = M.inventoryEntriesForIds(ctx, ids)
    if caps and caps.inventoryHasRepoTruck then
      return caps.inventoryHasRepoTruck(issued)
    end
    if not (caps and caps.canDoRepoJob) then return false end
    for _, entry in ipairs(issued) do
      local offer = M.inventoryVehAsLoanerOffer(ctx, entry.vehInfo)
      if offer and caps.canDoRepoJob(offer) then
        return true
      end
    end
    return false
  end
  if jobKind == "materials" then
    return false
  end
  if jobKind == "parcel"
      or jobKind == "police" or jobKind == "bus" or jobKind == "paramedic" then
    if not ctx.services.inventory() then return false end
    for _, inventoryId in ipairs(ids) do
      local vehInfo = ctx.services.inventory().getVehicles()[inventoryId]
      local vehId = ctx.services.inventory().getVehicleIdFromInventoryId
        and ctx.services.inventory().getVehicleIdFromInventoryId(inventoryId)
      if vehInfo and not M.isCompanyTrailer(ctx, vehInfo, vehId) then
        return true
      end
    end
    return false
  end
  return true
end

function M.routeToCompanyTruck(ctx)
  if ctx.services.inventory() and ctx.services.inventory().getVehicleIdFromInventoryId then
    for _, inventoryId in ipairs(M.collectCompanyInventoryIds(ctx)) do
      local vehId = ctx.services.inventory().getVehicleIdFromInventoryId(inventoryId)
      if vehId and vehId >= 0 then
        local vehInfo = ctx.services.inventory().getVehicles()[inventoryId]
        if not M.isCompanyTrailer(ctx, vehInfo, vehId) then
          local obj = getObjectByID(vehId)
          if obj then
            local pos = obj:getPosition()
            if freeroam_bigMapMode and freeroam_bigMapMode.setNavFocus then
              freeroam_bigMapMode.setNavFocus(pos)
            end
            if core_groundMarkers and core_groundMarkers.setPath then
              core_groundMarkers.setPath({pos}, {clearPathOnReachingTarget = false})
            end
            ctx.callbacks.refreshDeliveryPois()
            return true
          end
        end
      end
    end
  end
  return ctx.callbacks.routeToYard()
end

function M.beginCompanyVehiclePickupRoute(ctx)
  local shift = ctx.getState().shift
  if not shift or M.playerInIssuedCompanyTruck(ctx) then return false end
  shift.awaitingCompanyVehicleEntry = true
  return M.routeToCompanyTruck(ctx)
end

function M.vehicleParkedInSpots(ctx, vehId, spots)
  local parked = false
  M.forEachSpot(ctx, spots, function(spot)
    if parked or not spot then return end
    if spot.checkParking then
      local valid = spot:checkParking(vehId, 0, 8, 2.5)
      if valid then parked = true end
    elseif spot.containsPoint and be and be.getObjectOOBBCenterXYZ then
      local center = vec3(be:getObjectOOBBCenterXYZ(vehId))
      if spot:containsPoint(center) then parked = true end
    elseif spot.pos then
      local obj = getObjectByID(vehId)
      if obj then
        local pos = obj:getPosition()
        local maxDim = 8
        if spot.scl then
          maxDim = math.max(math.abs(spot.scl.x or 8), math.abs(spot.scl.y or 8), 8)
        end
        if pos:squaredDistance(spot.pos) <= (maxDim * maxDim) then parked = true end
      end
    end
  end)
  return parked
end

function M.companyVehiclesParked(ctx)
  if not ctx.services.inventory() then return true end
  local world = {}
  for _, inventoryId in ipairs(M.collectCompanyInventoryIds(ctx)) do
    local vehId = ctx.services.inventory().getVehicleIdFromInventoryId and ctx.services.inventory().getVehicleIdFromInventoryId(inventoryId)
    if vehId and vehId >= 0 and getObjectByID(vehId) then
      table.insert(world, {
        vehId = vehId,
        vehInfo = ctx.services.inventory().getVehicles()[inventoryId],
      })
    end
  end
  if #world == 0 then return true end

  local truckSpots = M.getLoanerTruckSpots(ctx)
  local fac = ctx.callbacks.getEmployerFacility()
  local trailerSpots = (fac and fac.loanerTrailerSpots) or truckSpots
  if not truckSpots or not truckSpots[1] then
    return false
  end

  local parkedTrucks = {}
  for _, entry in ipairs(world) do
    if not M.isCompanyTrailer(ctx, entry.vehInfo, entry.vehId) then
      if not M.vehicleParkedInSpots(ctx, entry.vehId, truckSpots) then return false end
      parkedTrucks[entry.vehId] = true
    end
  end
  for _, entry in ipairs(world) do
    if M.isCompanyTrailer(ctx, entry.vehInfo, entry.vehId) then
      local puller = core_trailerRespawn and core_trailerRespawn.getAttachedNonTrailer and core_trailerRespawn.getAttachedNonTrailer(entry.vehId)
      if not (puller and parkedTrucks[puller]) then
        if not M.vehicleParkedInSpots(ctx, entry.vehId, trailerSpots) then return false end
      end
    end
  end
  return true
end

function M.getLoanerTruckSpots(ctx)
  local spots = {}
  local seen = {}
  local function addFrom(fac)
    if not fac then return end
    M.forEachSpot(ctx, fac.loanerNonTrailerSpots, function(spot)
      if type(spot) == "table" and spot.pos and not seen[spot] then
        seen[spot] = true
        table.insert(spots, spot)
      end
    end)
  end
  local facId = ctx.getState().homeFacId or (ctx.getState().shift and ctx.getState().shift.originFacId)
  if freeroam_facilities and freeroam_facilities.getFacility and facId then
    addFrom(freeroam_facilities.getFacility("deliveryProvider", facId))
  end
  local gen = ctx.services.generator()
  addFrom(gen and gen.getFacilityById and gen.getFacilityById(facId))
  addFrom(ctx.callbacks.getEmployerFacility())
  return spots
end

function M.getParkRoutePos(ctx)
  local spots = M.getLoanerTruckSpots(ctx)
  local playerVehId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0)
  local fromPos
  if playerVehId and playerVehId >= 0 then
    local obj = getObjectByID(playerVehId)
    fromPos = obj and obj:getPosition() or nil
  end
  local best, bestDist
  for _, spot in ipairs(spots) do
    if spot.pos then
      local dist = fromPos and fromPos:squaredDistance(spot.pos) or 0
      if not best or dist < bestDist then
        best, bestDist = spot.pos, dist
      end
    end
  end
  return best
end

function M.routeToParkStall(ctx)
  local pos = M.getParkRoutePos(ctx)
  if not pos then return false end
  if freeroam_bigMapMode and freeroam_bigMapMode.setNavFocus then
    freeroam_bigMapMode.setNavFocus(pos)
  end
  if core_groundMarkers and core_groundMarkers.setPath then
    core_groundMarkers.setPath({pos}, {clearPathOnReachingTarget = false})
  end
  if freeroam_bigMapMode and freeroam_bigMapMode.resetRoute then
    freeroam_bigMapMode.resetRoute()
  end
  ctx.callbacks.refreshDeliveryPois()
  return true
end

function M.spawnAssignedWork(ctx, onSpawned)
  local shift = ctx.getState().shift
  if not shift then return false end
  if shift.jobKind == "trailer" and shift.assignedOfferId then
    local mgr = ctx.services.vehicleOffers()
    if mgr and mgr.spawnAssignedOffer then
      mgr.spawnAssignedOffer(shift.assignedOfferId, false, onSpawned)
      return true
    end
  end
  if (shift.jobKind == "vehicle" or ctx.callbacks.isBundleShift(shift))
      and (shift.assignedOfferId or (shift.assignedOfferIds and shift.assignedOfferIds[1])) then
    local mgr = ctx.services.vehicleOffers()
    if mgr and mgr.spawnAssignedOffer then
      M.spawnAssignedVehicleOffers(ctx, onSpawned)
      return true
    end
  end
  return false
end

function M.spawnCompanyOffers(ctx, onReady)
  local loaners = ctx.services.loaners()
  if loaners and loaners.spawnAllOffers then
    loaners.spawnAllOffers(onReady)
  else
    onReady()
  end
end

function M.spawnAssignedVehicleOffers(ctx, onDone)
  local shift = ctx.getState().shift
  local mgr = ctx.services.vehicleOffers()
  if not (shift and mgr and mgr.spawnAssignedOffer) then
    if onDone then onDone(false) end
    return
  end
  local delivered = {}
  for _, id in ipairs(shift.deliveredOfferIds or {}) do
    delivered[id] = true
  end
  local ids = {}
  for _, id in ipairs(shift.assignedOfferIds or { shift.assignedOfferId }) do
    if id and not delivered[id] then
      table.insert(ids, id)
    end
  end
  if not ids[1] then
    if onDone then onDone(true) end
    return
  end
  if ctx.callbacks.isDistributorHaulShift(shift) then
    local gen = ctx.services.generator()
    local facId = shift.originFacId or ctx.getState().homeFacId
    local fac = gen and gen.getFacilityById and facId and gen.getFacilityById(facId)
    local toStage = {}
    for _, id in ipairs(ids) do
      local offer = mgr.getOfferById and mgr.getOfferById(id)
      if offer then table.insert(toStage, offer) end
    end
    ctx.callbacks.stageDistributorHaulOffers(fac, toStage)
  end
  local left = #ids
  local ok = true
  local failReason = nil
  for _, id in ipairs(ids) do
    mgr.spawnAssignedOffer(id, false, function(success, reason)
      if success == false then
        ok = false
        if reason == "occupied" then failReason = "occupied" end
      end
      left = left - 1
      if left <= 0 and onDone then
        onDone(ok, failReason)
      end
    end)
  end
end

function M.cancelSpawnBlockedWatch(ctx)
  runtime.markerOwner, runtime.markerCorners = nil, nil
  local shift = ctx.getState().shift
  if not shift or not shift.spawnBlocked then return end
  shift.spawnBlocked.token = (shift.spawnBlocked.token or 0) + 1
  shift.spawnBlocked = nil
  if freeroam_bigMapMode and freeroam_bigMapMode.setNavFocus then
    freeroam_bigMapMode.setNavFocus(nil)
  end
  if core_groundMarkers and core_groundMarkers.setPath then
    core_groundMarkers.setPath(nil)
  end
end

function M.extendAssignedOfferExpiryWhileBlocked(ctx, shift)
  shift = shift or ctx.getState().shift
  if not shift then return end
  local mgr = ctx.services.vehicleOffers()
  if not (mgr and mgr.getOfferById) then return end
  local ids = {}
  if shift.assignedOfferId then ids[#ids + 1] = shift.assignedOfferId end
  for _, id in ipairs(shift.assignedOfferIds or {}) do
    ids[#ids + 1] = id
  end
  local now = (ctx.services.general() and ctx.services.general().time and ctx.services.general().time()) or 0
  for _, offerId in ipairs(ids) do
    local offer = mgr.getOfferById(offerId)
    if offer then
      offer.offerExpiresAt = math.max(tonumber(offer.offerExpiresAt) or 0, now + 3600)
      offer._spawning = nil
    end
  end
end

function M.collectSpawnBlockedSpots(ctx, shift, needs)
  shift = shift or ctx.getState().shift
  local spots, seen = {}, {}
  local function addSpot(spot)
    if type(spot) ~= "table" or not spot.pos then return end
    local key = (spot.getPath and spot:getPath()) or spot
    if seen[key] then return end
    seen[key] = true
    spots[#spots + 1] = spot
  end
  local facId = (shift and shift.originFacId) or ctx.getState().homeFacId
  local fac = ctx.services.generator() and ctx.services.generator().getFacilityById and ctx.services.generator().getFacilityById(facId)
  if freeroam_facilities and freeroam_facilities.getFacility and facId then
    fac = freeroam_facilities.getFacility("deliveryProvider", facId) or fac
  end
  if fac and (not needs or needs.needCompanyLoaner) then
    if not ctx.callbacks.isDistributorHaulShift(shift) or not M.companyInventoryHasTowTractor(ctx) then
      for _, spot in ipairs(fac.loanerNonTrailerSpots or {}) do addSpot(spot) end
    end
    if not ctx.callbacks.isDistributorHaulShift(shift) or not M.companyInventoryHasTrailer(ctx) then
      for _, spot in ipairs(fac.loanerTrailerSpots or {}) do addSpot(spot) end
    end
    if #spots == 0 then
      local named, other = {}, {}
      for name, accessPoint in pairs(fac.accessPointsByName or {}) do
        local spot = accessPoint.ps
        if spot then
          local list = tostring(spot.name or name):lower():find("loaner", 1, true) and named or other
          list[#list + 1] = spot
        end
      end
      for _, spot in ipairs(named[1] and named or other) do addSpot(spot) end
    end
  end
  if shift and (not needs or needs.needAssignedOffers)
      and (shift.jobKind == "trailer" or shift.jobKind == "vehicle" or ctx.callbacks.isBundleShift(shift)) then
    local mgr = ctx.services.vehicleOffers()
    local offerIds = {}
    if shift.assignedOfferId then offerIds[#offerIds + 1] = shift.assignedOfferId end
    for _, id in ipairs(shift.assignedOfferIds or {}) do offerIds[#offerIds + 1] = id end
    for _, offerId in ipairs(offerIds) do
      local offer = mgr and mgr.getOfferById and mgr.getOfferById(offerId)
      if offer and offer.spawned then goto continueBlockedOffer end
      local psPath = offer and offer.spawnLocation and offer.spawnLocation.psPath
      local ps = psPath and ctx.services.generator() and ctx.services.generator().getParkingSpotByPath and ctx.services.generator().getParkingSpotByPath(psPath)
      addSpot(ps)
      local originFac = offer and offer.origin and offer.origin.facId
        and ctx.services.generator() and ctx.services.generator().getFacilityById and ctx.services.generator().getFacilityById(offer.origin.facId)
      local logisticType = offer and offer.task and offer.task.lookupType
      if originFac and logisticType then
        for _, accessPoint in pairs(originFac.accessPointsByName or {}) do
          if accessPoint.logisticTypesProvidedLookup and accessPoint.logisticTypesProvidedLookup[logisticType] then
            addSpot(accessPoint.ps)
          end
        end
      end
      ::continueBlockedOffer::
    end
  end
  return spots
end

function M.inspectSpawnBlockedOccupancy(ctx, blocked)
  local shift = ctx.getState().shift
  local mgr = ctx.services.vehicleOffers and ctx.services.vehicleOffers()
  if blocked and not blocked.needCompanyLoaner and shift and shift.jobKind == "trailer"
      and shift.phase == "return" and mgr and mgr.getAvailableTrailerSpawnSpot then
    local offer = shift.assignedOfferId and mgr.getOfferById(shift.assignedOfferId)
    if offer and offer._employmentReturnTrailer and mgr.getAvailableTrailerSpawnSpot(offer) then
      return true, false, {}, blocked.spots or {}
    end
  end
  local spots = (blocked and blocked.spots) or M.collectSpawnBlockedSpots(ctx)
  if blocked and blocked.needCompanyLoaner ~= nil and ctx.getState().shift then
    local needCompanyLoaner = blocked.needCompanyLoaner
    if blocked.retryKind ~= "accidentReplacement" then
      needCompanyLoaner = needCompanyLoaner and M.spawnBlockedNeedsCompanyLoaner(ctx, ctx.getState().shift)
    end
    spots = M.collectSpawnBlockedSpots(ctx, ctx.getState().shift, {
      needCompanyLoaner = needCompanyLoaner,
      needAssignedOffers = blocked.needAssignedOffers and M.spawnBlockedNeedsAssignedOffers(ctx, ctx.getState().shift),
    })
    blocked.spots = spots
  end
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

function M.routeToSpawnBlockedArea(ctx, spots)
  spots = spots or M.collectSpawnBlockedSpots(ctx)
  local best
  for _, spot in ipairs(spots or {}) do
    if spot.pos then
      best = spot.pos
      break
    end
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

function M.clearSpawnBlockedState(ctx, success)
  local shift = ctx.getState().shift
  if not shift or not shift.spawnBlocked then return end
  shift.spawnBlocked.token = (shift.spawnBlocked.token or 0) + 1
  shift.spawnBlocked = nil
  runtime.markerOwner, runtime.markerCorners = nil, nil
  if success then
    if freeroam_bigMapMode and freeroam_bigMapMode.setNavFocus then
      freeroam_bigMapMode.setNavFocus(nil)
    end
  end
  ctx.callbacks.refreshTaskGuidance(true)
  ctx.callbacks.notifyUi()
end

function M.enterSpawnBlockedState(ctx, opts)
  opts = opts or {}
  local shift = ctx.getState().shift
  if not shift then return false end
  local spots = M.collectSpawnBlockedSpots(ctx, shift, opts)
  local clear, moving, occupantIds = M.inspectSpawnBlockedOccupancy(ctx, {spots = spots})
  local prevToken = shift.spawnBlocked and shift.spawnBlocked.token or 0
  local alreadyWaiting = shift.spawnBlocked ~= nil
  shift.spawnBlocked = {
    token = prevToken + 1,
    needCompanyLoaner = opts.needCompanyLoaner and true or false,
    needAssignedOffers = opts.needAssignedOffers and true or false,
    retryKind = opts.retryKind,
    spots = spots,
    occupantIds = occupantIds,
    occupantMoving = moving,
    ready = clear,
    accum = 0,
    retryInFlight = nil,
  }
  M.extendAssignedOfferExpiryWhileBlocked(ctx, shift)
  M.routeToSpawnBlockedArea(ctx, spots)
  ctx.callbacks.purgeIndependentTasklist()
  ctx.callbacks.refreshTaskGuidance(true)
  if not alreadyWaiting then
    ui_message("Clear the highlighted spawn area, then select Spawn vehicle at the facility or in Employment.", 8, "warning")
  end
  ctx.callbacks.notifyUi()
  ctx.callbacks.shiftLog("spawn blocked", string.format("needLoaner=%s needOffers=%s clear=%s occupants=%d",
    tostring(shift.spawnBlocked.needCompanyLoaner), tostring(shift.spawnBlocked.needAssignedOffers),
    tostring(clear), #(occupantIds or {})))
  return true
end

function M.spawnBlockedNeedsCompanyLoaner(ctx, shift)
  shift = shift or ctx.getState().shift
  if not shift then return false end
  if shift.jobKind == "trailer" then
    return not M.companyInventoryHasTowTractor(ctx, shift.couplerClass)
  end
  if ctx.callbacks.isDistributorHaulShift(shift) then
    return not M.companyInventoryHasTowTractor(ctx) or not M.companyInventoryHasTrailer(ctx)
  end
  if shift.jobKind == "parcel" or shift.jobKind == "materials" or shift.jobKind == "repo"
      or ctx.callbacks.isBundleShift(shift) or shift.jobKind == "police" or shift.jobKind == "bus" or shift.jobKind == "paramedic" then
    local hasIssued = shift.issuedInventoryIds and shift.issuedInventoryIds[1]
    if hasIssued then return false end
    return not (M.collectCompanyInventoryIds and M.collectCompanyInventoryIds(ctx)[1])
  end
  return false
end

function M.spawnBlockedNeedsAssignedOffers(ctx, shift)
  shift = shift or ctx.getState().shift
  if not shift then return false end
  if not (shift.jobKind == "trailer" or shift.jobKind == "vehicle" or ctx.callbacks.isBundleShift(shift)) then
    return false
  end
  local mgr = ctx.services.vehicleOffers()
  if not (mgr and mgr.getOfferById) then return false end
  local ids = {}
  if shift.assignedOfferId then ids[#ids + 1] = shift.assignedOfferId end
  for _, id in ipairs(shift.assignedOfferIds or {}) do ids[#ids + 1] = id end
  if not ids[1] then return false end
  for _, offerId in ipairs(ids) do
    local offer = mgr.getOfferById(offerId)
    if offer and not offer.spawned then
      return true
    end
  end
  return false
end

function M.jobFromShiftForActivation(ctx, shift)
  shift = shift or ctx.getState().shift
  if not shift then return nil end
  return {
    kind = shift.jobKind,
    offerId = shift.assignedOfferId,
    offerIds = shift.assignedOfferIds,
    assignedContractId = shift.assignedContractId,
    cargoIds = shift.assignedCargoIds,
    couplerClass = shift.couplerClass,
    distributorHaul = shift.distributorHaul,
    label = shift.outboundLabel,
  }
end

function M.attemptSpawnBlockedRetry(ctx)
  local shift = ctx.getState().shift
  local blocked = shift and shift.spawnBlocked
  if not blocked or blocked.retryInFlight then return end
  local clear = M.inspectSpawnBlockedOccupancy(ctx, blocked)
  if not clear then return end
  local token = blocked.token
  local isCurrent = ctx.callbacks.makeAssignmentGuard()
  local function stillValid()
    return isCurrent() and ctx.getState().shift and ctx.getState().shift.spawnBlocked == blocked
      and blocked.token == token
  end

  blocked.retryInFlight = true
  M.extendAssignedOfferExpiryWhileBlocked(ctx, shift)
  ctx.callbacks.shiftLog("spawn blocked retry", "area clear; retrying missing equipment")

  local function afterLoanerRetry()
    if not stillValid() then return end
    shift.issuedInventoryIds = M.captureIssuedInventoryIds(ctx)
    local batch = ctx.services.loaners() and ctx.services.loaners().consumeLastSpawnBatchResult
      and ctx.services.loaners().consumeLastSpawnBatchResult()
    if M.spawnBlockedNeedsCompanyLoaner(ctx, shift) then
      blocked.retryInFlight = nil
      if batch and batch.occupiedBlocked then
        M.routeToSpawnBlockedArea(ctx, blocked.spots)
        return
      end
      M.cancelSpawnBlockedWatch(ctx)
      ctx.callbacks.handleAssignmentStartFailure("Company vehicle did not spawn at the yard.")
      return
    end
    if M.spawnBlockedNeedsAssignedOffers(ctx, shift) then
      if shift.jobKind == "vehicle" and shift.phase == "return"
          and shift.returnIsBackhaul and not ctx.callbacks.isDistributorHaulShift(shift) then
        M.clearSpawnBlockedState(ctx, true)
        ctx.callbacks.trySpawnAssignedReturnVehicle()
        return
      end
      if ctx.callbacks.isBundleHaulBackhaulPending(shift) and shift.returnIsBackhaul then
        M.clearSpawnBlockedState(ctx, true)
        ctx.callbacks.trySpawnAssignedReturnVehicle()
        return
      end
      local job = M.jobFromShiftForActivation(ctx, shift)
      if ctx.services.general() and ctx.services.general().startDeliveryMode then
        ctx.services.general().startDeliveryMode()
      end
      if ctx.callbacks.activateAssignedWork then ctx.callbacks.activateAssignedWork(job) end
      return
    end
    blocked.retryInFlight = nil
    M.clearSpawnBlockedState(ctx, true)
    if ctx.services.general() and ctx.services.general().startDeliveryMode then
      ctx.services.general().startDeliveryMode()
    end
    local job = M.jobFromShiftForActivation(ctx, shift)
    if job and (job.kind == "parcel" or job.kind == "materials" or job.kind == "repo"
        or job.kind == "police" or job.kind == "bus" or job.kind == "paramedic") then
      if ctx.callbacks.activateAssignedWork then ctx.callbacks.activateAssignedWork(job) end
    else
      ctx.callbacks.routeCurrentAssignment()
      ctx.callbacks.refreshActiveTaskGuidance()
    end
  end

  if M.spawnBlockedNeedsCompanyLoaner(ctx, shift) then
    local facId = ctx.getState().homeFacId or shift.originFacId
    local fac = ctx.services.generator() and ctx.services.generator().getFacilityById and ctx.services.generator().getFacilityById(facId)
    local caps = ctx.services.loanerCaps()
    local loanerOpts = {
      cargoType = shift.cargoType,
      targetLoad = shift.targetLoad,
      couplerClass = shift.couplerClass,
    }
    local truck, trailer
    if ctx.callbacks.isRoleplayProfile(shift.jobKind) then
      loanerOpts.selection = shift.roleplayVehicleSelection
      truck = caps and caps.getIssuedRoleplayVehicleForFacility(fac, loanerOpts) or nil
    elseif ctx.callbacks.isDistributorHaulShift(shift) then
      if caps then truck, trailer = caps.getIssuedLoanersForFacility(fac, "trailer", loanerOpts) end
    elseif M.shiftLoanerKind(ctx, shift) == "materials" then
      truck, trailer = ctx.callbacks.getIssuedEmploymentMaterials(fac, shift.cargoType, shift.targetLoad)
    else
      truck = caps and caps.getIssuedLoanersForFacility(fac, M.shiftLoanerKind(ctx, shift), loanerOpts) or nil
    end
    if not truck or (ctx.callbacks.isDistributorHaulShift(shift) and not trailer) then
      blocked.retryInFlight = nil
      M.cancelSpawnBlockedWatch(ctx)
      ctx.callbacks.handleAssignmentStartFailure("No company truck is available for this assignment.")
      return
    end
    if not ctx.callbacks.isDistributorHaulShift(shift) or not M.companyInventoryHasTowTractor(ctx) then M.markIssued(ctx, truck) end
    if trailer and (shift.jobKind ~= "trailer" or ctx.callbacks.isDistributorHaulShift(shift)) then
      if not M.companyInventoryHasTrailer(ctx) then M.markIssued(ctx, trailer) end
    end
    M.spawnCompanyOffers(ctx, afterLoanerRetry)
    return
  end

  if M.spawnBlockedNeedsAssignedOffers(ctx, shift) then
    if (shift.jobKind == "vehicle" and shift.phase == "return" and shift.returnIsBackhaul
        and not ctx.callbacks.isDistributorHaulShift(shift))
        or (ctx.callbacks.isBundleHaulBackhaulPending(shift) and shift.returnIsBackhaul) then
      M.clearSpawnBlockedState(ctx, true)
      ctx.callbacks.trySpawnAssignedReturnVehicle()
      return
    end
    local job = M.jobFromShiftForActivation(ctx, shift)
    if ctx.services.general() and ctx.services.general().startDeliveryMode then
      ctx.services.general().startDeliveryMode()
    end
    if ctx.callbacks.activateAssignedWork then ctx.callbacks.activateAssignedWork(job) end
    return
  end

  blocked.retryInFlight = nil
  M.clearSpawnBlockedState(ctx, true)
  ctx.callbacks.routeCurrentAssignment()
  ctx.callbacks.refreshActiveTaskGuidance()
end

function M.tickSpawnBlockedWatch(ctx, dtSim)
  local shift = ctx.getState().shift
  local blocked = shift and shift.spawnBlocked
  if not blocked or blocked.retryInFlight or not ctx.callbacks.isOnShift() then return end
  M.drawSpawnBlockedArea(ctx, blocked)
  blocked.accum = (blocked.accum or 0) + (tonumber(dtSim) or 0)
  local interval = blocked.occupantMoving and 1 or 2
  if blocked.accum < interval then return end
  blocked.accum = 0
  local clear, moving, occupantIds, spots = M.inspectSpawnBlockedOccupancy(ctx, blocked)
  blocked.occupantMoving = moving
  blocked.occupantIds = occupantIds
  blocked.spots = spots
  M.extendAssignedOfferExpiryWhileBlocked(ctx, shift)
  if blocked.ready ~= clear then
    blocked.ready = clear
    ctx.callbacks.refreshTaskGuidance(true)
    ctx.callbacks.notifyUi()
    if gameplay_markerInteraction then gameplay_markerInteraction.setForceReevaluateOpenPrompt() end
  end
end

function M.drawSpawnBlockedArea(ctx, blocked)
  if not debugDrawer then return end
  if runtime.markerOwner ~= blocked then
    runtime.markerOwner = blocked
    runtime.markerCorners = {}
  end
  local color = ColorF(1, 0.05, 0.05, 1)
  for _, spot in ipairs(blocked.spots or {}) do
    if spot.pos and spot.rot and spot.scl then
      local corners = runtime.markerCorners[spot]
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
        runtime.markerCorners[spot] = corners
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

function M.getBlockedSpawnStatus(ctx)
  local blocked = ctx.getState().shift and ctx.getState().shift.spawnBlocked
  if not blocked or not ctx.callbacks.isOnShift() then return nil end
  local veh = getPlayerVehicle(0)
  local pos = veh and veh:getPosition()
  local nearby = false
  for _, spot in ipairs(blocked.spots or {}) do
    if pos and spot.pos and (pos - spot.pos):squaredLength() <= 40 * 40 then nearby = true; break end
  end
  return {ready = blocked.ready == true and not blocked.retryInFlight, nearby = nearby}
end

return M
