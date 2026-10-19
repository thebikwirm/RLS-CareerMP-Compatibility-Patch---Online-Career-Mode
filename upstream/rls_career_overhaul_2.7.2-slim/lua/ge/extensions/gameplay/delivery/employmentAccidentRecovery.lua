local M = {}

function M.accidentTaskGuidance(ctx, shift)
  local acc = shift and shift.accident
  if not acc or acc.done then return nil end
  if acc.spawning then
    return {
      label = "Accident reported",
      subtext = "Issuing replacement equipment",
    }
  end
  if acc.needYardPickup then
    return {
      label = "Pick up replacement trailer at the yard",
      subtext = acc.yardSubtext or "Your truck and load are waiting at the accident scene",
    }
  end
  if acc.needReload then
    return {
      label = "Reload the stranded cargo",
      subtext = "Drive the replacement to the marked crate",
    }
  end
  if acc.needCouple then
    return {
      label = "Couple the stranded trailer",
      subtext = "Drive back to the accident scene — trailer and load are still there",
    }
  end
  return nil
end

function M.accidentUi(ctx, shift)
  local acc = shift and shift.accident
  if not acc or acc.done then return nil end
  local task = M.accidentTaskGuidance(ctx, shift)
  return ctx.services.ui().formatAccident({
    label = task and task.label or nil,
    subtext = task and task.subtext or nil,
    canClaim = acc.pendingOffers and acc.pendingOffers[1] and not acc.spawning and true or false,
    spawning = acc.spawning and true or false,
  })
end

function M.inventorySpawnedVehId(ctx, inventoryId)
  if not inventoryId or not ctx.services.inventory() then return nil end
  local vehId = ctx.services.inventory().getVehicleIdFromInventoryId
    and ctx.services.inventory().getVehicleIdFromInventoryId(inventoryId)
  vehId = tonumber(vehId) or vehId
  if vehId and vehId >= 0 then return vehId end
  if not (ctx.services.inventory().getInventoryIdFromVehicleId and getAllVehicles) then
    return nil
  end
  local want = tonumber(inventoryId) or inventoryId
  for _, veh in ipairs(getAllVehicles()) do
    local id = veh.getId and veh:getId()
    if id then
      local inv = ctx.services.inventory().getInventoryIdFromVehicleId(id)
      if (tonumber(inv) or inv) == want then return id end
    end
  end
  return nil
end

function M.vehIsFlipped(ctx, vehId)
  if not vehId then return false end
  local obj = getObjectByID(tonumber(vehId) or vehId)
  if not (obj and obj.getDirectionVectorUp) then return false end
  local up = obj:getDirectionVectorUp()
  return up and up.z < 0.35 or false
end

function M.spawnedVehLiveDamage(ctx, vehId)
  if not vehId then return 0 end
  local live = 0
  local want = tonumber(vehId) or vehId
  if map and map.objects then
    local data = map.objects[vehId] or map.objects[want] or map.objects[tostring(vehId)]
    if data then live = tonumber(data.damage) or 0 end
    if live == 0 then
      for id, objData in pairs(map.objects) do
        if (tonumber(id) or id) == want or id == vehId then
          live = math.max(live, tonumber(objData.damage) or 0)
        end
      end
    end
  end
  local obj = getObjectByID(want or vehId)
  if obj and obj.getSectionDamageSum then
    local ok, sum = pcall(function() return tonumber(obj:getSectionDamageSum()) or 0 end)
    if ok and sum and sum > live then live = sum end
  end
  return live
end

function M.companyInventoryIsWrecked(ctx, inventoryId)
  if not inventoryId then return false end
  if ctx.services.insurance() and ctx.services.insurance().inventoryVehNeedsRepair
      and ctx.services.insurance().inventoryVehNeedsRepair(inventoryId) then
    return true
  end
  local vehId = M.inventorySpawnedVehId(ctx, inventoryId)
  if M.vehIsFlipped(ctx, vehId) then return true end
  return M.spawnedVehLiveDamage(ctx, vehId) >= ctx.constants.ACCIDENT_LIVE_DAMAGE
end

function M.canReportAccident(ctx)
  if ctx.getState().accidentReportInProgress then return false end
  if not ctx.callbacks.isOnShift() then return false end
  local shift = ctx.getState().shift
  if not shift then return false end
  -- This reports stranded company equipment/cargo, not police incidents.
  if shift.jobKind == "police" then return false end
  if shift.accident and shift.accident.spawning then return false end
  if ctx.callbacks.collectCompanyInventoryIds()[1] then return true end
  if not (ctx.services.inventory() and ctx.services.inventory().getInventoryIdFromVehicleId) then
    return false
  end
  local vehId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0)
  local inventoryId = vehId and ctx.services.inventory().getInventoryIdFromVehicleId(vehId)
  local vehInfo = inventoryId and ctx.services.inventory().getVehicles()[inventoryId]
  return vehInfo and vehInfo.loanType == "company" or false
end

function M.routeToWorldPos(ctx, pos)
  if not pos then return false end
  local v = vec3(pos.x or pos[1], pos.y or pos[2], pos.z or pos[3] or 0)
  if freeroam_bigMapMode and freeroam_bigMapMode.setNavFocus then
    freeroam_bigMapMode.setNavFocus(v)
  end
  if core_groundMarkers and core_groundMarkers.setPath then
    core_groundMarkers.setPath({v}, {clearPathOnReachingTarget = false})
  end
  ctx.callbacks.refreshDeliveryPois()
  return true
end

function M.routeAccidentRecovery(ctx)
  local shift = ctx.getState().shift
  local acc = shift and shift.accident
  if not acc or acc.done or acc.spawning then return false end
  if acc.needYardPickup then
    return ctx.callbacks.routeToYard()
  end
  if acc.needReload and acc.pos then
    return M.routeToWorldPos(ctx, acc.pos)
  end
  if acc.needCouple then
    if acc.strandedTrailerInvId and ctx.services.inventory() and ctx.services.inventory().getVehicleIdFromInventoryId then
      local vehId = ctx.services.inventory().getVehicleIdFromInventoryId(acc.strandedTrailerInvId)
      local obj = vehId and getObjectByID(vehId)
      if obj and obj.getPosition then
        return M.routeToWorldPos(ctx, obj:getPosition())
      end
    end
    if acc.pos then
      return M.routeToWorldPos(ctx, acc.pos)
    end
  end
  return false
end

function M.accidentVehIdMatches(ctx, vehId, idSet)
  if not vehId or not idSet then return false end
  if idSet[vehId] then return true end
  local n = tonumber(vehId)
  if n and idSet[n] then return true end
  return idSet[tostring(vehId)] and true or false
end

function M.markAccidentVehId(ctx, idSet, vehId)
  if not vehId then return end
  idSet[vehId] = true
  idSet[tostring(vehId)] = true
  local n = tonumber(vehId)
  if n then idSet[n] = true end
end

function M.groundAccidentPos(ctx, pos)
  if not pos then return pos end
  local z
  if be and be.getSurfaceHeightBelow then
    z = be:getSurfaceHeightBelow(pos)
  end
  if (not z or z < -1000 or z > 10000) and core_terrain and core_terrain.getTerrainHeight then
    z = core_terrain.getTerrainHeight(pos)
  end
  if type(z) == "number" and z > -1000 and z < 10000 then
    pos.z = z + 0.05
  end
  return pos
end

function M.accidentBoxPosFromScene(ctx, origin)
  local pos = vec3(origin.x or origin[1], origin.y or origin[2], origin.z or origin[3] or 0)
  local roadMap = map
  if roadMap and roadMap.findClosestRoad and roadMap.getMap then
    local _, nodeIdx = roadMap.findClosestRoad(pos)
    local mapData = roadMap.getMap()
    local node = nodeIdx and mapData and mapData.nodes and mapData.nodes[nodeIdx]
    if node and node.pos then
      local roadPos = vec3(node.pos)
      local side = pos - roadPos
      side.z = 0
      if side:squaredLength() < 0.25 then
        side = vec3(1, 0, 0)
      else
        side:normalize()
      end
      pos = pos + side * ctx.constants.ACCIDENT_ROAD_OFFSET_M
    else
      pos = pos + vec3(ctx.constants.ACCIDENT_ROAD_OFFSET_M, 0, 0)
    end
  else
    pos = pos + vec3(ctx.constants.ACCIDENT_ROAD_OFFSET_M, 0, 0)
  end
  return M.groundAccidentPos(ctx, pos)
end

function M.deleteNamedStatic(ctx, name)
  if not name or not scenetree or not scenetree.findObject then return end
  local obj = scenetree.findObject(name)
  if obj and obj.delete then obj:delete() end
end

function M.deleteAccidentCargoBox(ctx)
  local acc = ctx.getState().shift and ctx.getState().shift.accident
  if not acc then return end
  M.deleteNamedStatic(ctx, acc.boxName)
  M.deleteNamedStatic(ctx, acc.markerName)
  acc.boxName = nil
  acc.markerName = nil
end

function M.spawnAccidentStatic(ctx, name, shapeName, pos, scale, color)
  if not (name and shapeName and pos) then return nil end
  if scenetree and scenetree.findObject and scenetree.findObject(name) then
    M.deleteNamedStatic(ctx, name)
  end
  local obj = createObject("TSStatic")
  if not obj then return nil end
  if obj.setField then
    obj:setField("shapeName", 0, shapeName)
  else
    obj.shapeName = shapeName
  end
  obj.shapeName = shapeName
  if obj.setPosition then
    obj:setPosition(vec3(pos.x, pos.y, pos.z))
  elseif obj.setPosRot then
    obj:setPosRot(pos.x, pos.y, pos.z, 0, 0, 0, 1)
  end
  obj.scale = scale or vec3(1, 1, 1)
  obj.useInstanceRenderData = true
  if color then
    if obj.setField then
      obj:setField("instanceColor", 0, string.format("%s %s %s %s", color[1], color[2], color[3], color[4] or 1))
    elseif ColorF then
      obj.instanceColor = ColorF(color[1], color[2], color[3], color[4] or 1):asLinear4F()
    end
  end
  obj.canSave = false
  if obj.setCanSave then obj:setCanSave(false) end
  local ok = pcall(function()
    obj:registerObject(name)
  end)
  if not ok then return nil end
  if scenetree and scenetree.MissionGroup then
    pcall(function() scenetree.MissionGroup:addObject(obj) end)
  end
  return name
end

function M.spawnAccidentCargoBox(ctx, pos)
  if not pos then return nil, nil end
  M.deleteAccidentCargoBox(ctx)
  local stamp = tostring(math.floor(((os.clock and os.clock()) or 0) * 1000))
  local boxName = "rlsAccCargoBox" .. stamp
  local markerName = "rlsAccCargoMark" .. stamp
  local cratePos = M.groundAccidentPos(ctx, vec3(pos.x, pos.y, pos.z))
  local crateShape = "/levels/west_coast_usa/art/shapes/objects/s_containers_20_beamng.dae"
  if FS and FS.fileExists and not FS:fileExists(crateShape) then
    crateShape = "art/shapes/objects/s_box_wood_01.dae"
    if FS.fileExists and not FS:fileExists(crateShape) then
      crateShape = nil
    end
  end
  if crateShape then
    M.spawnAccidentStatic(ctx, boxName, crateShape, cratePos, vec3(0.45, 0.45, 0.45))
  end
  local markPos = vec3(cratePos.x, cratePos.y, cratePos.z + 2.4)
  M.spawnAccidentStatic(ctx, 
    markerName,
    "art/shapes/interface/checkpoint_marker.dae",
    markPos,
    vec3(6, 6, 6),
    {0.95, 0.45, 0.08, 0.9}
  )
  return boxName, markerName
end

function M.restoreAccidentCargoBox(ctx)
  local acc = ctx.getState().shift and ctx.getState().shift.accident
  if not acc then return end
  acc.spawning = nil
  acc.rebindBusy = nil
  if not acc.needReload or not acc.pos then return end
  local boxAlive = acc.boxName and scenetree.findObject and scenetree.findObject(acc.boxName)
  if boxAlive then return end
  local boxName, markerName = M.spawnAccidentCargoBox(ctx, vec3(acc.pos.x, acc.pos.y, acc.pos.z))
  acc.boxName = boxName
  acc.markerName = markerName
end

function M.setCargoLocation(ctx, cargoId, location)
  local parcelMgr = ctx.services.parcels()
  if not (parcelMgr and cargoId and location) then return end
  local cargo = parcelMgr.getCargoById and (
    parcelMgr.getCargoById(cargoId)
    or parcelMgr.getCargoById(tonumber(cargoId))
    or parcelMgr.getCargoById(tostring(cargoId))
  )
  if cargo and cargo._transientMove and parcelMgr.clearTransientMoveForCargo then
    parcelMgr.clearTransientMoveForCargo(cargo.id)
  end
  if parcelMgr.changeCargoLocation then
    parcelMgr.changeCargoLocation(cargo and cargo.id or cargoId, location)
  elseif cargo then
    cargo.location = location
  end
end

function M.cargoTiedToWreckedVeh(ctx, cargo, wreckedVehIds, wreckedInvIds)
  if not cargo then return false end
  local function tiedVeh(vehId)
    if not vehId then return false end
    if wreckedVehIds and M.accidentVehIdMatches(ctx, vehId, wreckedVehIds) then return true end
    if wreckedInvIds and ctx.services.inventory() and ctx.services.inventory().getInventoryIdFromVehicleId then
      local invId = ctx.services.inventory().getInventoryIdFromVehicleId(vehId)
        or ctx.services.inventory().getInventoryIdFromVehicleId(tonumber(vehId) or vehId)
      if invId and M.accidentVehIdMatches(ctx, invId, wreckedInvIds) then return true end
    end
    return false
  end
  local loc = cargo.location
  if loc and loc.type == "vehicle" and tiedVeh(loc.vehId) then
    return true
  end
  if loc and loc.type == "vehicle" and loc.vehId and wreckedInvIds and next(wreckedInvIds)
      and not (ctx.services.inventory() and ctx.services.inventory().getInventoryIdFromVehicleId
        and ctx.services.inventory().getInventoryIdFromVehicleId(loc.vehId)) then
    return true
  end
  local target = cargo._transientMove and cargo._transientMove.targetLocation
  if target and tiedVeh(target.vehId) then
    return true
  end
  return false
end

function M.relocateCargoOffWrecked(ctx, wreckedVehIds, wreckedInvIds)
  local salvaged, dumped, seen = {}, {}, {}
  local parcelMgr = ctx.services.parcels()
  if not parcelMgr then return salvaged, dumped end
  local function cargoById(id)
    if not (id and parcelMgr.getCargoById) then return nil end
    return parcelMgr.getCargoById(id)
      or parcelMgr.getCargoById(tonumber(id))
      or parcelMgr.getCargoById(tostring(id))
  end
  local function consider(cargo)
    if not cargo or not cargo.id or seen[cargo.id] then return end
    if not M.cargoTiedToWreckedVeh(ctx, cargo, wreckedVehIds, wreckedInvIds) then return end
    seen[cargo.id] = true
    if cargo.materialType then
      M.setCargoLocation(ctx, cargo.id, { type = "deleted" })
      table.insert(dumped, cargo.id)
    else
      M.setCargoLocation(ctx, cargo.id, { type = "accident" })
      table.insert(salvaged, cargo.id)
    end
  end
  if parcelMgr.getAllCargoInVehicles then
    for _, cargo in ipairs(parcelMgr.getAllCargoInVehicles(true) or {}) do
      consider(cargo)
    end
  end
  local shift = ctx.getState().shift
  for _, cargoId in ipairs(shift and shift.assignedCargoIds or {}) do
    consider(cargoById(cargoId))
  end
  for _, cargoId in ipairs(shift and shift.stringCargoIds or {}) do
    consider(cargoById(cargoId))
  end
  return salvaged, dumped
end

function M.tryRebindAccidentCargo(ctx)
  local shift = ctx.getState().shift
  local acc = shift and shift.accident
  if not acc or not acc.needReload or acc.rebindBusy then return end
  if not acc.pos then return end
  local boxPos = vec3(acc.pos.x, acc.pos.y, acc.pos.z)
  local limit = ctx.constants.ACCIDENT_REBIND_M
  local near = false
  if ctx.services.inventory() and ctx.services.inventory().getVehicleIdFromInventoryId then
    for _, inventoryId in ipairs(ctx.callbacks.collectCompanyInventoryIds()) do
      local vehId = ctx.services.inventory().getVehicleIdFromInventoryId(inventoryId)
      local obj = vehId and getObjectByID(vehId)
      if obj and obj.getPosition and (obj:getPosition() - boxPos):length() <= limit then
        near = true
        break
      end
    end
  end
  if not near then return end
  local g = ctx.services.general()
  local parcelMgr = ctx.services.parcels()
  if not (g and g.getNearbyVehicleCargoContainers and parcelMgr) then return end
  acc.rebindBusy = true
  g.getNearbyVehicleCargoContainers(function(containers)
    local live = ctx.getState().shift and ctx.getState().shift.accident
    if live then live.rebindBusy = nil end
    if not live or live ~= acc then return end
    local slots = ctx.callbacks.buildCompanyParcelLoadSlots(containers)
    if not slots[1] then return end
    for _, cargoId in ipairs(acc.cargoIds or {}) do
      local cargo = parcelMgr.getCargoById and parcelMgr.getCargoById(cargoId)
      local dest = ctx.callbacks.takeParcelLoadLocation(slots, cargo or { slots = 1, weight = 0 })
      if dest then
        M.setCargoLocation(ctx, cargoId, dest)
      end
    end
    M.deleteAccidentCargoBox(ctx)
    acc.needReload = nil
    acc.cargoIds = nil
    if g.requestUpdateContainerWeights then
      g.requestUpdateContainerWeights()
    end
    local cs = ctx.services.cargoScreen()
    if cs and cs.onCargoPickedUp then
      cs.onCargoPickedUp()
    end
    ui_message("Stranded cargo loaded.", 6, "success")
    ctx.callbacks.refreshTaskGuidance(true)
    ctx.callbacks.notifyUi()
  end)
end

function M.tickAccidentRecovery(ctx, dtSim)
  if not ctx.callbacks.isOnShift() then return end
  local shift = ctx.getState().shift
  local acc = shift and shift.accident
  if not acc or acc.done or acc.spawning then return end
  acc.tickAcc = (tonumber(acc.tickAcc) or 0) + (dtSim or 0)
  if acc.tickAcc < 0.35 then return end
  acc.tickAcc = 0
  if acc.needYardPickup and ctx.callbacks.playerNearHomeYard(50) then
    acc.needYardPickup = nil
    ctx.callbacks.refreshTaskGuidance(true)
    M.routeAccidentRecovery(ctx)
    ctx.callbacks.notifyUi()
  end
  if acc.needCouple and acc.pos then
    local player = getPlayerVehicle(0)
    local scene = vec3(acc.pos.x, acc.pos.y, acc.pos.z)
    if player and player.getPosition and (player:getPosition() - scene):length() <= ctx.constants.ACCIDENT_ARRIVE_M then
      acc.needCouple = nil
      ctx.callbacks.refreshTaskGuidance(true)
      ctx.callbacks.notifyUi()
    end
  end
  if acc.needReload then
    M.tryRebindAccidentCargo(ctx)
  end
  if not acc.needYardPickup and not acc.needReload and not acc.needCouple then
    shift.accident = nil
    ctx.callbacks.routeCurrentAssignment()
    ctx.callbacks.refreshTaskGuidance(true)
    ctx.callbacks.notifyUi()
    ctx.callbacks.saveEmploymentProgress()
  end
end

function M.accidentEntryForInventory(ctx, inventoryId)
  local vehInfo = ctx.services.inventory().getVehicles()[inventoryId]
  local vehId = M.inventorySpawnedVehId(ctx, inventoryId)
  local obj = vehId and getObjectByID(vehId)
  return {
    inventoryId = inventoryId,
    vehId = vehId,
    isTrailer = ctx.callbacks.isCompanyTrailer(vehInfo, vehId),
    offer = ctx.callbacks.inventoryVehAsLoanerOffer(vehInfo),
    pos = obj and obj.getPosition and obj:getPosition() or nil,
  }
end

function M.collectAccidentWreckage(ctx, preferredVehId)
  local wrecked, survivors = {}, {}
  if not ctx.services.inventory() then
    return wrecked, survivors
  end
  local entries = {}
  for _, inventoryId in ipairs(ctx.callbacks.collectCompanyInventoryIds()) do
    local entry = M.accidentEntryForInventory(ctx, inventoryId)
    entry.liveDamage = M.spawnedVehLiveDamage(ctx, entry.vehId)
    entry.wrecked = M.companyInventoryIsWrecked(ctx, inventoryId)
    table.insert(entries, entry)
  end
  local vehId = preferredVehId
  if not vehId or vehId < 0 then
    vehId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0)
  end
  local preferInv = vehId and ctx.services.inventory().getInventoryIdFromVehicleId
    and ctx.services.inventory().getInventoryIdFromVehicleId(vehId)
  preferInv = tonumber(preferInv) or preferInv
  local preferVehN = tonumber(vehId)

  -- Report accident writes off only the unit the player reported, not coupled
  -- trailers / other company gear that may also be damaged nearby.
  if preferInv or preferVehN then
    for _, entry in ipairs(entries) do
      local inv = tonumber(entry.inventoryId) or entry.inventoryId
      local entryVehN = tonumber(entry.vehId)
      local isPreferred = (preferInv and inv == preferInv)
        or (preferVehN and entryVehN and entryVehN == preferVehN)
      if isPreferred then
        table.insert(wrecked, entry)
      else
        table.insert(survivors, entry)
      end
    end
    if wrecked[1] then return wrecked, survivors end
  end

  for _, entry in ipairs(entries) do
    if entry.wrecked then
      table.insert(wrecked, entry)
    else
      table.insert(survivors, entry)
    end
  end
  if wrecked[1] or not preferInv then return wrecked, survivors end

  local vehInfo = ctx.services.inventory().getVehicles()[preferInv]
  if vehInfo and vehInfo.loanType == "company" then
    table.insert(wrecked, M.accidentEntryForInventory(ctx, preferInv))
  end
  return wrecked, survivors
end

function M.fallbackAccidentOffer(ctx, entry, shift)
  local facId = (shift and shift.originFacId) or ctx.getState().homeFacId
  local gen = ctx.services.generator()
  local fac = gen and gen.getFacilityById and gen.getFacilityById(facId)
  local caps = ctx.services.loanerCaps()
  if not (fac and caps and caps.getIssuedLoanersForFacility) then return nil end
  if ctx.callbacks.isRoleplayProfile(shift.jobKind) then
    return not entry.isTrailer and caps.getIssuedRoleplayVehicleForFacility(fac, {}) or nil
  end
  local loanerKind = ctx.callbacks.shiftLoanerKind(shift)
  local truck, trailer
  if loanerKind == "materials" then
    truck, trailer = ctx.callbacks.getIssuedEmploymentMaterials(fac, shift.cargoType, shift.targetLoad)
  else
    truck, trailer = caps.getIssuedLoanersForFacility(fac, loanerKind, {
      cargoType = shift.cargoType,
      targetLoad = shift.targetLoad,
      couplerClass = shift.couplerClass,
    })
  end
  if entry.isTrailer then return trailer end
  return truck
end

function M.enterAccidentReplacementTractor(ctx)
  return ctx.callbacks.enterCompanyTractor()
end

function M.getMissingAccidentReplacementOffers(ctx, shift)
  shift = shift or ctx.getState().shift
  local acc = shift and shift.accident
  if not acc then return {}, false, false end
  local hasTractor, hasTrailer = false, false
  for _, inventoryId in ipairs(ctx.callbacks.captureIssuedInventoryIds()) do
    local vehInfo = ctx.services.inventory() and ctx.services.inventory().getVehicles()[inventoryId]
    local vehId = ctx.services.inventory() and ctx.services.inventory().getVehicleIdFromInventoryId
      and ctx.services.inventory().getVehicleIdFromInventoryId(inventoryId)
    if ctx.callbacks.isCompanyTrailer(vehInfo, vehId) then hasTrailer = true else hasTractor = true end
  end
  local caps = ctx.services.loanerCaps()
  local missing = {}
  for _, offer in ipairs(acc.pendingOffers or {}) do
    local isTrailer = caps and caps.isTrailer and caps.isTrailer(offer) or offer.vehOfferType == "trailer"
    if (isTrailer and not hasTrailer) or (not isTrailer and not hasTractor) then
      missing[#missing + 1] = offer
    end
  end
  return missing, hasTractor, hasTrailer
end

function M.finishAccidentSpawn(ctx, replacedTractor)
  local shift = ctx.getState().shift
  if not shift then return end
  local acc = shift.accident
  shift.issuedInventoryIds = ctx.callbacks.captureIssuedInventoryIds()
  local missingOffers = M.getMissingAccidentReplacementOffers(ctx, shift)
  if acc then
    acc.spawning = nil
    acc.pendingOffers = missingOffers[1] and missingOffers or nil
  end
  if shift.jobKind == "bus" and gameplay_bus and gameplay_bus.cancelActiveRoute then
    gameplay_bus.cancelActiveRoute("accident replacement")
  elseif shift.jobKind == "paramedic" and gameplay_ambulance and gameplay_ambulance.cancelActiveCall then
    gameplay_ambulance.cancelActiveCall("accident replacement")
  end
  if replacedTractor then
    -- Truck write-off: leave trailer + load at the scene and put the player
    -- straight into the replacement truck at the yard.
    M.enterAccidentReplacementTractor(ctx)
  end
  if acc and (acc.needCouple or acc.needYardPickup or acc.needReload) then
    M.routeAccidentRecovery(ctx)
  else
    if ctx.callbacks.isRoleplayProfile(shift.jobKind) then
      shift.accident = nil
    end
    ctx.callbacks.routeCurrentAssignment()
  end
  ctx.callbacks.refreshTaskGuidance(true)
  ctx.callbacks.notifyUi()
  ctx.callbacks.saveEmploymentProgress()
end

function M.claimAccidentReplacement(ctx)
  local shift = ctx.getState().shift
  local acc = shift and shift.accident
  if not acc or not acc.pendingOffers or not acc.pendingOffers[1] then return false end
  if acc.spawning then return false end
  local pendingOffers = M.getMissingAccidentReplacementOffers(ctx, shift)
  if not pendingOffers[1] then
    M.finishAccidentSpawn(ctx, acc.replacedTractor == true)
    return true
  end
  acc.pendingOffers = pendingOffers
  acc.spawning = true
  for _, offer in ipairs(acc.pendingOffers) do
    ctx.callbacks.markIssued(offer)
  end
  local replacedTractor = acc.replacedTractor and true or false
  if ctx.services.loaners() and ctx.services.loaners().spawnAllOffers then
    ctx.services.loaners().spawnAllOffers(function()
      local batch = ctx.services.loaners().consumeLastSpawnBatchResult
        and ctx.services.loaners().consumeLastSpawnBatchResult()
      M.finishAccidentSpawn(ctx, replacedTractor)
      if batch and batch.occupiedBlocked and ctx.getState().shift and ctx.getState().shift.accident
          and ctx.getState().shift.accident.pendingOffers and ctx.getState().shift.accident.pendingOffers[1] then
        ctx.callbacks.enterSpawnBlockedState({needCompanyLoaner = true, retryKind = "accidentReplacement"})
      end
    end)
  else
    M.finishAccidentSpawn(ctx, replacedTractor)
  end
  return true
end

function M.reportAccident(ctx, preferredVehId)
  if not M.canReportAccident(ctx) then
    ui_message("No company equipment to report.", 6, "warning")
    return false
  end
  local shift = ctx.getState().shift
  if shift and shift.jobKind == "bus" and gameplay_bus and gameplay_bus.cancelActiveRoute then
    gameplay_bus.cancelActiveRoute("accident report")
  elseif shift and shift.jobKind == "paramedic" and gameplay_ambulance and gameplay_ambulance.cancelActiveCall then
    gameplay_ambulance.cancelActiveCall("accident report")
  end
  local wrecked, survivors = M.collectAccidentWreckage(ctx, preferredVehId)
  if not wrecked[1] then
    ui_message("No damaged company equipment to report.", 6, "warning")
    return false
  end
  local replacedTractor, replacedTrailer = false, false
  local pendingOffers = {}
  for _, entry in ipairs(wrecked) do
    local offer = entry.offer or M.fallbackAccidentOffer(ctx, entry, shift)
    if not offer or not offer.model then
      ui_message("Could not reissue that company vehicle.", 7, "warning")
      return false
    end
    entry.offer = offer
    table.insert(pendingOffers, offer)
    if entry.isTrailer then replacedTrailer = true else replacedTractor = true end
  end
  local wreckedVehIds, wreckedInvIds = {}, {}
  local scenePos
  for _, entry in ipairs(wrecked) do
    wreckedInvIds[entry.inventoryId] = true
    M.markAccidentVehId(ctx, wreckedVehIds, entry.vehId)
    if not scenePos and entry.pos then scenePos = entry.pos end
  end
  local playerVehId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0)
  if playerVehId and playerVehId >= 0 and ctx.services.inventory() and ctx.services.inventory().getInventoryIdFromVehicleId then
    local playerInvId = ctx.services.inventory().getInventoryIdFromVehicleId(playerVehId)
    if playerInvId and wreckedInvIds[playerInvId] then
      M.markAccidentVehId(ctx, wreckedVehIds, playerVehId)
    end
  end
  if not scenePos then
    local playerVeh = getPlayerVehicle(0)
    scenePos = playerVeh and playerVeh.getPosition and playerVeh:getPosition() or nil
  end
  local strandedTrailerInvId
  for _, entry in ipairs(survivors) do
    if entry.isTrailer then strandedTrailerInvId = entry.inventoryId end
  end
  local salvaged = M.relocateCargoOffWrecked(ctx, wreckedVehIds, wreckedInvIds)
  local existing = shift.accident
  if existing and existing.cargoIds and existing.cargoIds[1] then
    for _, cargoId in ipairs(salvaged) do
      table.insert(existing.cargoIds, cargoId)
    end
    salvaged = existing.cargoIds
  end
  local needReload = salvaged[1] and true or false
  local boxPos = scenePos and M.accidentBoxPosFromScene(ctx, scenePos) or nil
  local boxName, markerName
  if needReload and boxPos then
    boxName, markerName = M.spawnAccidentCargoBox(ctx, boxPos)
  elseif existing then
    boxName, markerName = existing.boxName, existing.markerName
    boxPos = existing.pos and vec3(existing.pos.x, existing.pos.y, existing.pos.z) or boxPos
  end
  shift.accident = {
    pos = boxPos and { x = boxPos.x, y = boxPos.y, z = boxPos.z }
      or (scenePos and { x = scenePos.x, y = scenePos.y, z = scenePos.z })
      or nil,
    cargoIds = needReload and salvaged or nil,
    boxName = boxName,
    markerName = markerName,
    needReload = needReload,
    needCouple = replacedTractor and strandedTrailerInvId and true or nil,
    needYardPickup = replacedTrailer and not replacedTractor and true or nil,
    yardSubtext = replacedTrailer and not replacedTractor
      and "Truck and load stay at the scene — pick up the new trailer at the yard"
      or nil,
    strandedTrailerInvId = strandedTrailerInvId,
    replacedTractor = replacedTractor,
    replacedTrailer = replacedTrailer,
    pendingOffers = pendingOffers,
    spawning = true,
  }
  ctx.callbacks.stepOutIfInInventoryIds(wreckedInvIds)
  for _, entry in ipairs(wrecked) do
    ctx.callbacks.detachVehicleTrailers(entry.vehId)
  end
  for _, entry in ipairs(survivors) do
    if not entry.isTrailer then
      ctx.callbacks.detachVehicleTrailers(entry.vehId)
    end
  end
  ctx.getState().accidentReportInProgress = true
  local pending = #wrecked
  local function afterReturns()
    ctx.getState().accidentReportInProgress = nil
    if not ctx.callbacks.isEmployed() or not ctx.getState().shift then
      M.deleteAccidentCargoBox(ctx)
      return
    end
    ctx.callbacks.handleCompanyVehicleDamaged()
    if not ctx.callbacks.isEmployed() or not ctx.getState().shift then
      M.deleteAccidentCargoBox(ctx)
      return
    end
    local msg
    if replacedTractor and replacedTrailer then
      msg = "Accident reported. Replacement equipment is at the yard."
    elseif replacedTractor and strandedTrailerInvId then
      msg = "Accident reported. You're in the replacement truck at the yard — go couple the stranded trailer and load."
    elseif replacedTrailer then
      msg = "Accident reported. Truck and load stay at the scene — drive back to the yard for a replacement trailer."
    else
      msg = "Accident reported. Replacement equipment is at the yard."
    end
    if needReload then
      msg = msg .. " Reload the stranded cargo at the marked crate."
    end
    ui_message(msg, 8, "info")
    if ctx.getState().shift and ctx.getState().shift.accident then
      ctx.getState().shift.accident.spawning = nil
    end
    M.claimAccidentReplacement(ctx)
  end
  local function startReturns()
    if not ctx.services.loaners() or not ctx.services.loaners().returnVehicle then
      afterReturns()
      return
    end
    for _, entry in ipairs(wrecked) do
      ctx.services.loaners().returnVehicle(entry.inventoryId, function()
        pending = pending - 1
        if pending <= 0 then afterReturns() end
      end)
    end
  end
  if core_jobsystem and core_jobsystem.create then
    core_jobsystem.create(function(job)
      job.sleep(0.3)
      startReturns()
    end)
  else
    startReturns()
  end
  ctx.callbacks.notifyUi()
  return true
end

return M

