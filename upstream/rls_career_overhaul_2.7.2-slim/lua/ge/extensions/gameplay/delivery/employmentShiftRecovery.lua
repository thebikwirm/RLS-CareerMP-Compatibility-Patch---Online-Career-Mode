local M = {}

function M.pauseShift(ctx)
  local shift = ctx.getState().shift
  if not shift or not ctx.callbacks.isOnShift() then return false end
  ctx.callbacks.cancelSpawnBlockedWatch()
  shift.issuedInventoryIds = ctx.callbacks.collectCompanyInventoryIds()
  shift.paused = true
  shift.awaitingPark = nil
  shift.parkedNotified = nil
  shift.pendingClockOut = nil
  ctx.callbacks.touchLastWorkAt()
  -- Do not exitDeliveryMode here: it abandons vehicle tasks and deletes cargo,
  -- which destroys the held backhaul/outbound load.
  if freeroam_bigMapMode and freeroam_bigMapMode.setNavFocus then
    freeroam_bigMapMode.setNavFocus(nil)
  end
  if core_groundMarkers and core_groundMarkers.setPath then
    core_groundMarkers.setPath(nil)
  end
  ctx.callbacks.refreshTaskGuidance(true)
  ctx.callbacks.firePhoneNotification("employment.shiftEnded", "Day ended", "Assignment held. Company vehicle stays in the world. Clock in to continue — pay stays held until the job is finished.", "info")
  ui_message("Day ended. Assignment held; company vehicle stays where it is until you finish the job.", 7, "info")
  ctx.callbacks.notifyUi()
  ctx.callbacks.closeShiftUi()
  ctx.callbacks.closeDropOffUi()
  return true
end

function M.restageHeldAssignment(ctx)
  local shift = ctx.getState().shift
  if not shift then return false end
  local mgr = ctx.services.vehicleOffers()

  if ctx.callbacks.isBundleShift(shift) and shift.assignments and shift.assignments.vehicle
      and shift.assignments.vehicle.complete then
    if ctx.callbacks.isBundleHaulBackhaulPending(shift) then
      ctx.callbacks.cancelEmploymentRepoJob()
      if shift.returnIsBackhaul and shift.assignedOfferId then
        local offer = mgr and mgr.getOfferById and mgr.getOfferById(shift.assignedOfferId)
        if offer then
          ctx.callbacks.resetOfferSpawnFlags(offer)
          ctx.callbacks.extendOfferExpiry(offer, 3600)
          ctx.callbacks.trySpawnAssignedReturnVehicle()
        else
          ctx.callbacks.beginBundleRepoLeg()
        end
      else
        ctx.callbacks.beginBundleRepoLeg()
      end
    end
    ctx.callbacks.routeCurrentAssignment()
    ctx.callbacks.refreshTaskGuidance(true)
    return true
  end

  if shift.jobKind == "materials" then
    if shift.assignedContractId then
      local mats = ctx.services.materials()
      if mats and mats.acceptAssignedOffer then
        mats.acceptAssignedOffer(shift.assignedContractId)
      end
    end
    ctx.callbacks.routeCurrentAssignment()
    ctx.callbacks.refreshTaskGuidance(true)
    return true
  end

  if shift.jobKind == "repo" then
    shift.repoPendingStart = true
    ctx.callbacks.tryStartEmploymentRepo()
    ctx.callbacks.refreshTaskGuidance(true)
    return true
  end

  if shift.jobKind == "parcel" then
    if shift.accident and (shift.accident.needReload or shift.accident.needCouple) then
      ctx.callbacks.routeCurrentAssignment()
      ctx.callbacks.refreshTaskGuidance(true)
      return true
    end
    if ctx.callbacks.assignedParcelFreightAlive(shift) then
      if shift.needsRemotePickup or (shift.phase == "return" and shift.returnNeedsPickup) then
        ctx.callbacks.stageAssignedReturnPickup()
      elseif shift.phase ~= "return" or not shift.returnNeedsPickup then
        ctx.callbacks.bindAssignedCargoToIssuedTruck()
      end
      ctx.callbacks.routeCurrentAssignment()
      ctx.callbacks.refreshTaskGuidance(true)
      return true
    end
    if shift.phase == "return" then
      ui_message("Held return parcels are gone — finding another return load.", 6, "info")
      ctx.callbacks.assignReturnLoad(shift.returnPickupFacId or ctx.getState().homeFacId)
      ctx.callbacks.refreshTaskGuidance(true)
      return true
    end
    ui_message("Held parcel load is gone. End day or start a new assignment from the shift screen.", 7, "warning")
    shift.phase = "loopComplete"
    shift.returnLabel = "Assignment interrupted"
    shift.returnSubtext = "Take another job or end your day"
    ctx.callbacks.routeToYard()
    ctx.callbacks.refreshTaskGuidance(true)
    return true
  end

  if shift.jobKind == "trailer" then
    if shift.phase == "return" then
      if ctx.callbacks.assignedReturnCargoInVehicle(shift) then
        ctx.callbacks.trySetShiftRoute()
        ctx.callbacks.refreshTaskGuidance(true)
        return true
      end
      local offer = shift.assignedOfferId and mgr and mgr.getOfferById and mgr.getOfferById(shift.assignedOfferId)
      if offer then
        ctx.callbacks.resetOfferSpawnFlags(offer)
        ctx.callbacks.extendOfferExpiry(offer, 3600)
        shift.returnNeedsPickup = true
        shift._returnTrailerSpawned = nil
        shift._returnTrailerSpawning = nil
        shift.originLocation = offer.spawnLocation or offer.origin or shift.originLocation
        shift.returnPickupFacId = (offer.origin and offer.origin.facId)
          or (offer.locations and offer.locations[1] and offer.locations[1].facId)
          or shift.returnPickupFacId
        shift.returnLabel = string.format("Pick up return trailer at %s",
          ctx.callbacks.describeFacilityName(shift.returnPickupFacId))
        ctx.callbacks.routeToReturnPickup()
        ctx.callbacks.trySpawnAssignedReturnTrailer()
        ctx.callbacks.refreshTaskGuidance(true)
        return true
      end
      ui_message("Held return trailer is gone — finding another return load.", 6, "info")
      ctx.callbacks.assignReturnLoad(shift.returnPickupFacId or ctx.getState().homeFacId)
      ctx.callbacks.refreshTaskGuidance(true)
      return true
    end

    if ctx.callbacks.vehicleOfferTaskActive(shift.assignedOfferId) then
      ctx.callbacks.routeCurrentAssignment()
      ctx.callbacks.refreshTaskGuidance(true)
      return true
    end
    local offer = shift.assignedOfferId and mgr and mgr.getOfferById and mgr.getOfferById(shift.assignedOfferId)
    if offer then
      ctx.callbacks.resetOfferSpawnFlags(offer)
      ctx.callbacks.extendOfferExpiry(offer, 3600)
      mgr.spawnAssignedOffer(offer.id, false, function(success, reason)
        if ctx.getState().shift ~= shift or shift.paused then return end
        if success == false then
          if reason == "occupied" then
            ctx.callbacks.handleVehicleSpawnResult(false, reason)
            return
          end
          ui_message("Could not re-stage the held trailer — finding another load.", 7, "warning")
          local replacement = ctx.callbacks.pickTrailerOffer(ctx.getState().homeFacId or shift.originFacId)
          if replacement then
            shift.assignedOfferId = replacement.id
            local dest = replacement.destination or (replacement.locations and replacement.locations[2])
            shift.destFacId = dest and dest.facId
            shift.destPsPath = dest and dest.psPath
            shift.destLocation = dest
            ctx.callbacks.resetOfferSpawnFlags(replacement)
            ctx.callbacks.extendOfferExpiry(replacement, 3600)
            mgr.spawnAssignedOffer(replacement.id, false, ctx.callbacks.handleVehicleSpawnResult)
          else
            ctx.callbacks.handleVehicleSpawnResult(false)
          end
          return
        end
        ctx.callbacks.handleVehicleSpawnResult(true)
      end)
      ctx.callbacks.refreshTaskGuidance(true)
      return true
    end
    local replacement = ctx.callbacks.pickTrailerOffer(ctx.getState().homeFacId or shift.originFacId)
    if replacement then
      ui_message("Held trailer is gone — staging a replacement.", 6, "info")
      shift.assignedOfferId = replacement.id
      local dest = replacement.destination or (replacement.locations and replacement.locations[2])
      shift.destFacId = dest and dest.facId
      shift.destPsPath = dest and dest.psPath
      shift.destLocation = dest
      shift.outboundLabel = "Deliver the assigned trailer"
      ctx.callbacks.resetOfferSpawnFlags(replacement)
      ctx.callbacks.extendOfferExpiry(replacement, 3600)
      mgr.spawnAssignedOffer(replacement.id, false, ctx.callbacks.handleVehicleSpawnResult)
      ctx.callbacks.refreshTaskGuidance(true)
      return true
    end
    ui_message("Held trailer assignment is gone. End day or start a new assignment.", 7, "warning")
    shift.phase = "loopComplete"
    ctx.callbacks.routeToYard()
    ctx.callbacks.refreshTaskGuidance(true)
    return true
  end

  if shift.jobKind == "vehicle" or ctx.callbacks.isBundleShift(shift) then
    if ctx.callbacks.isDistributorHaulShift(shift) then
      if shift.phase == "return" or shift.awaitingLoopChoice then
        ctx.callbacks.routeToYard()
        ctx.callbacks.refreshTaskGuidance(true)
        return true
      end
      local delivered = {}
      for _, id in ipairs(shift.deliveredOfferIds or {}) do
        delivered[id] = true
      end
      local anyLive = false
      for id in pairs(ctx.callbacks.shiftVehicleOfferIdSet(shift)) do
        if not delivered[id] then
          if ctx.callbacks.vehicleOfferTaskActive(id) then
            anyLive = true
          end
          local offer = id and mgr and mgr.getOfferById and mgr.getOfferById(id)
          if offer then
            anyLive = true
            ctx.callbacks.resetOfferSpawnFlags(offer)
            ctx.callbacks.extendOfferExpiry(offer, 3600)
          end
        end
      end
      if anyLive then
        ctx.callbacks.spawnAssignedVehicleOffers(ctx.callbacks.handleVehicleSpawnResult)
        ctx.callbacks.refreshTaskGuidance(true)
        return true
      end
      ui_message("Held vehicle assignment is gone. End day or start a new assignment from the shift screen.", 7, "warning")
      shift.phase = "loopComplete"
      ctx.callbacks.routeToYard()
      ctx.callbacks.refreshTaskGuidance(true)
      return true
    end
    local offerId = ctx.callbacks.getShiftVehicleOfferId(shift) or shift.assignedOfferId
    if offerId and ctx.callbacks.vehicleOfferTaskActive(offerId) then
      ctx.callbacks.routeCurrentAssignment()
      ctx.callbacks.refreshTaskGuidance(true)
      return true
    end
    local offer = offerId and mgr and mgr.getOfferById and mgr.getOfferById(offerId)
    if offer then
      ctx.callbacks.resetOfferSpawnFlags(offer)
      ctx.callbacks.extendOfferExpiry(offer, 3600)
      mgr.spawnAssignedOffer(offer.id, false, ctx.callbacks.handleVehicleSpawnResult)
      ctx.callbacks.refreshTaskGuidance(true)
      return true
    end
    ui_message("Held vehicle assignment is gone. End day or start a new assignment from the shift screen.", 7, "warning")
    if ctx.callbacks.isBundleShift(shift) and shift.assignments and shift.assignments.vehicle then
      shift.assignments.vehicle.complete = true
      if shift.assignments.repo and not shift.assignments.repo.complete then
        ctx.callbacks.beginBundleRepoLeg()
      else
        ctx.callbacks.maybeCompleteBundleShift({ atYard = true })
      end
    else
      shift.phase = "loopComplete"
      ctx.callbacks.routeToYard()
    end
    ctx.callbacks.refreshTaskGuidance(true)
    return true
  end

  ctx.callbacks.routeCurrentAssignment()
  ctx.callbacks.refreshTaskGuidance(true)
  return true
end

function M.hasMissingSavedVehicles(ctx, shift)
  local inventory, mgr = ctx.services.inventory(), ctx.services.vehicleOffers()
  if not inventory then return false end
  local ids = {}
  for _, id in ipairs(shift.issuedInventoryIds or {}) do ids[#ids + 1] = id end
  for _, id in ipairs(shift.assignedOfferIds or {shift.assignedOfferId}) do
    local offer = mgr and mgr.getOfferById(id)
    if offer and offer.vehicle and offer.vehicle.inventoryId then ids[#ids + 1] = offer.vehicle.inventoryId end
  end
  for _, id in ipairs(ids) do
    if inventory.getVehicle(id) then
      local vehId = inventory.getVehicleIdFromInventoryId(id)
      if not vehId or not getObjectByID(vehId) then return true end
    end
  end
  return false
end

function M.resumeShift(ctx, facId)
  if ctx.getState().restoringFreight then
    ui_message("Please wait for the saved assignment to finish restoring.", 5, "info")
    return false
  end
  local shift = ctx.getState().shift
  if not shift or not shift.paused then return false end
  if shift.legacyFreightUnavailable then
    ui_message('This older save did not retain the assignment cargo. The assignment and held pay are preserved; explicitly abandon it in Employment if the missing freight cannot be restored.', 10, 'warning')
    return false
  end
  if M.hasMissingSavedVehicles(ctx, shift) then
    ui_message("A saved assignment vehicle could not be restored. Retry its vehicle in Logistics, then continue the assignment in Employment.", 10, "warning")
    return false
  end
  ctx.getState().ignoreCompanyDamageStrikes = nil
  if facId then
    local fac = ctx.services.generator() and ctx.services.generator().getFacilityById and ctx.services.generator().getFacilityById(facId)
    local shiftOrg = shift.shiftOrgId
    local okFac = ctx.callbacks.facilityMatchesEmployer(facId)
      or (shiftOrg and fac and fac.associatedOrganization == shiftOrg)
      or (shift.originFacId and shift.originFacId == facId)
    if not okFac then
      ui_message("Clock in at the company yard.", 5, "warning")
      return false
    end
  end
  shift.paused = false
  ctx.callbacks.touchLastWorkAt()
  local needsCompanyRig = not ctx.callbacks.issuedVehiclesStillPresent()
    or (shift.jobKind == "trailer" and not ctx.callbacks.companyInventoryHasTowTractor(shift.couplerClass))
    or (ctx.callbacks.isDistributorHaulShift(shift) and (not ctx.callbacks.companyInventoryHasTowTractor(shift.couplerClass) or not ctx.callbacks.companyInventoryHasTrailer()))
  if needsCompanyRig then
    local fac = ctx.services.generator() and ctx.services.generator().getFacilityById and ctx.services.generator().getFacilityById(facId or ctx.getState().homeFacId)
    local caps = ctx.services.loanerCaps()
    local truck, trailer = nil, nil
    local kind = shift.jobKind
    if kind == "police" or kind == "bus" or kind == "paramedic" then
      truck = fac and caps and caps.getIssuedRoleplayVehicleForFacility and caps.getIssuedRoleplayVehicleForFacility(fac, {}) or nil
    else
      local loanerKind = ctx.callbacks.shiftLoanerKind(shift)
      if fac and caps then
        if ctx.callbacks.isDistributorHaulShift(shift) then
          truck, trailer = caps.getIssuedLoanersForFacility(fac, loanerKind, {
            cargoType = shift.cargoType,
            targetLoad = shift.targetLoad,
            couplerClass = shift.couplerClass,
          })
        elseif loanerKind == "materials" then
          truck, trailer = ctx.callbacks.getIssuedEmploymentMaterials(fac, shift.cargoType, shift.targetLoad)
        else
          truck = caps.getIssuedLoanersForFacility(fac, loanerKind, {
            cargoType = shift.cargoType,
            targetLoad = shift.targetLoad,
            couplerClass = shift.couplerClass,
          })
        end
      end
    end
    if not truck or (ctx.callbacks.isDistributorHaulShift(shift) and not trailer) then
      shift.paused = true
      ui_message("No company truck is available to continue this assignment.", 6, "warning")
      return false
    end
    ctx.callbacks.markIssued(truck)
    if trailer and (kind ~= "trailer" or ctx.callbacks.isDistributorHaulShift(shift)) then ctx.callbacks.markIssued(trailer) end
    local function afterSpawn()
      if ctx.getState().shift ~= shift or shift.paused then return end
      shift.issuedInventoryIds = ctx.callbacks.captureIssuedInventoryIds()
      if ctx.callbacks.spawnBlockedNeedsCompanyLoaner(shift) then
        ctx.callbacks.handleMissingCompanySpawn("Company vehicle did not spawn at the yard.", {
          needAssignedOffers = ctx.callbacks.spawnBlockedNeedsAssignedOffers(shift),
        })
        return
      end
      if ctx.services.general() and ctx.services.general().startDeliveryMode and not ctx.callbacks.isOpenEndedJobKind(shift.jobKind) then
        ctx.services.general().startDeliveryMode()
      end
      local function restage()
        if ctx.getState().shift ~= shift or shift.paused then return end
        M.restageHeldAssignment(ctx)
        ctx.callbacks.notifyUi()
        ctx.callbacks.closeShiftUi()
      end
      if core_jobsystem and core_jobsystem.create then
        core_jobsystem.create(function(job)
          job.sleep(0)
          restage()
        end)
      else
        restage()
      end
    end
    if ctx.services.loaners() and ctx.services.loaners().spawnAllOffers then
      ctx.services.loaners().spawnAllOffers(afterSpawn)
    else
      afterSpawn()
    end
    ui_message("Clocked in. Continue the held assignment.", 6, "info")
    return true
  end
  if ctx.services.general() and ctx.services.general().startDeliveryMode then
    ctx.services.general().startDeliveryMode()
  end
  M.restageHeldAssignment(ctx)
  ctx.callbacks.firePhoneNotification("employment.shiftStarted", "Clocked in", "Continue the held assignment.", "success")
  ui_message("Clocked in. Continue the held assignment.", 6, "info")
  ctx.callbacks.notifyUi()
  ctx.callbacks.closeShiftUi()
  return true
end

function M.isAssignedFreight(ctx, shift, item, kind)
  if not shift or not item then return false end
  local ids = kind == 'parcel' and shift.assignedCargoIds or shift.assignedOfferIds or {shift.assignedOfferId}
  for _, id in ipairs(ids or {}) do if id == item.id then return true end end
  return false
end

function M.captureFreight(ctx, shift, api)
  if not shift then return end
  if shift.jobKind == "police" or shift.jobKind == "bus" or shift.jobKind == "paramedic" then return end
  local persistence = ctx.services.general()
  if persistence.capturePersistentCargo then persistence.capturePersistentCargo() end
  local snapshot = {parcels={}, offers={}, phase=shift.phase, sessionVehicles=true}
  for _, id in ipairs(shift.assignedCargoIds or {}) do
    local cargo = api.parcels.getCargoById(id)
    if cargo and cargo.location and (cargo.location.type == 'vehicle'
      or (cargo.location.type == 'facilityParkingspot' and cargo.origin and cargo.location.facId == cargo.origin.facId)) then
      local saved = deepcopy(cargo)
      if cargo.location.type == "vehicle" and ctx.services.inventory() then
        saved.savedInventoryId = cargo.logisticsBinding and cargo.logisticsBinding.inventoryId
          or ctx.services.inventory().getInventoryIdFromVehicleId(cargo.location.vehId)
      end
      snapshot.parcels[#snapshot.parcels+1] = saved
    end
  end
  local delivered = {}; for _, id in ipairs(shift.deliveredOfferIds or {}) do delivered[id]=true end
  if shift.assignments and shift.assignments.vehicle and shift.assignments.vehicle.complete and shift.assignedOfferId then
    delivered[shift.assignedOfferId]=true
  end
  for _, id in ipairs(shift.assignedOfferIds or {shift.assignedOfferId}) do
    local offer = not delivered[id] and api.vehicles.getOfferById(id)
    if offer then
      local saved = deepcopy(offer)
      local tasks = ctx.services.vehicleTasks()
      local task = tasks and tasks.getVehicleTaskForOffer and tasks.getVehicleTaskForOffer(offer)
      if task and persistence.capturePersistentTask then saved.logisticsTask = persistence.capturePersistentTask(task) end
      snapshot.offers[#snapshot.offers+1] = saved
    end
  end
  return snapshot
end

function M.restoreFreight(ctx, shift, api)
  local snapshot = shift and (shift.freight or shift.plannerFreight)
  if not snapshot then return false end
  local cargoIds, offerIds, cargoIdMap = {}, {}, {}
  for _, saved in ipairs(snapshot.parcels or {}) do
    local cargo = deepcopy(saved)
    cargo.id=api.newId(); cargo.location=deepcopy(cargo.origin)
    if saved.location and saved.location.type == 'vehicle' then
      cargo.location = deepcopy(saved.location)
      cargo.location.vehId = -1
      cargo.logisticsBinding = cargo.logisticsBinding or {inventoryId = saved.savedInventoryId, containerId = saved.location.containerId}
      cargo.logisticsPending = true
    end
    local inventory = ctx.services.inventory()
    local vehId = saved.savedInventoryId and inventory and inventory.getVehicleIdFromInventoryId(saved.savedInventoryId)
    if vehId and getObjectByID(vehId) then
      cargo.location = deepcopy(saved.location)
      cargo.location.vehId = vehId
      cargo.logisticsPending = nil
    end
    cargo.savedInventoryId = nil
    cargo._transientMove=nil; cargo.employmentAssigned=true
    ctx.services.general().migrateOfferAccess(cargo)
    cargo.offerExpiresAt=math.max(cargo.offerExpiresAt or 0,api.now()+3600)
    api.parcels.addCargo(cargo); cargoIds[#cargoIds+1]=cargo.id; cargoIdMap[saved.id]=cargo.id
  end
  for _, saved in ipairs(snapshot.offers or {}) do
    local offer=deepcopy(saved)
    offer.id=api.newId(); offer.spawned=nil; offer._spawning=nil; offer.employmentAssigned=true
    ctx.services.general().migrateOfferAccess(offer)
    offer.spawnWhenCommitingCargo=nil
    if offer.vehicle then offer.vehicle.vehId=nil end
    local inventory = ctx.services.inventory()
    local inventoryId = offer.vehicle and offer.vehicle.inventoryId
    local info = inventoryId and inventory and inventory.getVehicle(inventoryId)
    local vehId = info and info.loanType == "delivery" and inventory.getVehicleIdFromInventoryId(inventoryId)
    if inventoryId then
      offer.spawned = true
      offer.vehicle.vehId = -1
    end
    if vehId and getObjectByID(vehId) then
      offer.vehicle.vehId = vehId
      offer.spawned = true
    end
    offer.offerExpiresAt=math.max(offer.offerExpiresAt or 0,api.now()+3600)
    api.vehicles.addOffer(offer); offerIds[#offerIds+1]=offer.id
  end
  shift.assignedCargoIds=cargoIds
  if shift.stringMode then
    shift.stringCargoIds=deepcopy(cargoIds)
    for _,stop in ipairs(shift.stops or {}) do
      local ids={}
      for _,id in ipairs(stop.cargoIds or {}) do
        if cargoIdMap[id] then ids[#ids+1]=cargoIdMap[id] end
      end
      stop.cargoIds=ids
    end
  end
  if shift.distributorHaul or shift.assignedOfferIds then shift.assignedOfferIds=offerIds;shift.deliveredOfferIds={} end
  shift.assignedOfferId=offerIds[1]
  if shift.assignments and shift.assignments.vehicle then shift.assignments.vehicle.offerId=offerIds[1] end
  shift.phase=snapshot.phase or shift.phase
  shift.freight=nil; shift.plannerFreight=nil
  shift.plannerLineId=nil; shift.plannerMode=nil; shift.plannerRepoOfferId=nil
  return true
end

function M.reconcileLoadedShift(ctx)
  local shift = ctx.getState().shift
  if not shift then return end
  if not (ctx.callbacks.isOnShift() or shift.paused) then return end
  if shift.freight or shift.plannerFreight then
    local snapshot = shift.freight or shift.plannerFreight
    local resumeInWorld = snapshot.sessionVehicles == true and not shift.paused
    M.restoreFreight(ctx, shift, {
      parcels=ctx.services.parcelManager(), vehicles=ctx.services.vehicleOfferManager(),
      newId=ctx.services.deliveryGenerator().allocateCargoId, now=ctx.services.general().time,
    })
    shift.paused = not resumeInWorld
    shift.sessionVehicles = true
    shift._returnTrailerSpawning = nil
    shift._returnTrailerSpawned = nil
    ctx.getState().ignoreCompanyDamageStrikes = nil
    local mgr, tasks = ctx.services.vehicleOffers(), ctx.services.vehicleTasks()
    for _, id in ipairs(shift.assignedOfferIds or {shift.assignedOfferId}) do
      local offer = mgr and mgr.getOfferById(id)
      if offer and offer.spawned and offer.vehicle and tasks then
        tasks.addVehicleTask(offer.vehicle.vehId, offer)
      end
    end
    if M.hasMissingSavedVehicles(ctx, shift) then
      shift.paused = true
      ui_message("A saved assignment vehicle could not be restored. Retry it from Logistics; the assignment is held.", 10, "warning")
    elseif resumeInWorld then
      if ctx.services.general() and ctx.services.general().startDeliveryMode then ctx.services.general().startDeliveryMode() end
      M.restageHeldAssignment(ctx)
    end
    if ctx.services.general() and ctx.services.general().requestUpdateContainerWeights then ctx.services.general().requestUpdateContainerWeights() end
    ctx.callbacks.flushEmploymentCache()
    ctx.callbacks.notifyUi()
    return
  end
  M.abortInterruptedShiftOnLoad(ctx)
end

function M.abortInterruptedShiftOnLoad(ctx)
  local held = ctx.getState().shift
  if held and held.jobKind ~= 'police' and held.jobKind ~= 'bus' and held.jobKind ~= 'paramedic' then
    held.paused = true
    if held.phase ~= 'return' and held.phase ~= 'loopComplete' and not held.awaitingLoopChoice then
      -- Older saves may contain assignment metadata without its freight. Keep
      -- that metadata and escrow, but never manufacture a replacement load.
      local parcels, offers, materials = ctx.services.parcels(), ctx.services.vehicleOffers(), ctx.services.materials()
      for _, id in ipairs(held.assignedCargoIds or {}) do
        if not (parcels and parcels.getCargoById(id)) then held.legacyFreightUnavailable = true end
      end
      for _, id in ipairs(held.assignedOfferIds or {held.assignedOfferId}) do
        if not (offers and offers.getOfferById(id)) then held.legacyFreightUnavailable = true end
      end
      if held.assignedContractId and not (materials and materials.getContractById(held.assignedContractId)) then
        held.legacyFreightUnavailable = true
      end
    end
    ui_message('Your saved assignment is held. Continue it from Employment; unavailable equipment can be retried from Logistics.', 10, 'warning')
    return true
  end
  local shift = ctx.getState().shift
  if not shift then return false end
  if not (ctx.callbacks.isOnShift() or shift.paused) then return false end

  ctx.callbacks.shiftLog("abortInterruptedShiftOnLoad", tostring(shift.jobKind or "?"))
  if spawn then spawn.preventPlayerSpawning = nil end

  if ctx.services.materials() and ctx.services.materials().abandonContract then
    ctx.services.materials().abandonContract(nil, { noFine = true, silent = true })
  end
  if ctx.services.materials() and ctx.services.materials().clearTaskGuidance then
    ctx.services.materials().clearTaskGuidance()
  end
  ctx.callbacks.cancelEmploymentRepoJob()
  local vt = ctx.services.vehicleTasks()
  if vt and vt.abandonAllVehicleTasks then
    vt.abandonAllVehicleTasks()
  end
  ctx.callbacks.exitDeliveryModeIfActive()

  ctx.getState().ignoreCompanyDamageStrikes = true
  ctx.callbacks.reconcileEscrowMoney("abortInterruptedShiftOnLoad")
  local total, wages, bonus = ctx.callbacks.payEscrow()
  local removed = ctx.callbacks.returnAllCompanyVehicles()
  ctx.callbacks.emptyShift()

  if core_groundMarkers and core_groundMarkers.setPath then
    core_groundMarkers.setPath(nil)
  end
  if freeroam_bigMapMode and freeroam_bigMapMode.resetRoute then
    freeroam_bigMapMode.resetRoute()
  end
  ctx.callbacks.flushEmploymentCache()

  local recovery = "garage"
  if ctx.services.inventory() and ctx.services.inventory().recoverPlayerAfterCompanyReturn then
    recovery = ctx.services.inventory().recoverPlayerAfterCompanyReturn() or "garage"
  elseif gameplay_walk and gameplay_walk.setWalkingMode then
    gameplay_walk.setWalkingMode(true, nil, nil, true)
  end

  local wagesMsg = ctx.callbacks.formatTodaysWagesMessage(total, wages, bonus)
  local detail = string.format(
    "%s Company equipment returned (%d). You were moved to your %s.",
    wagesMsg,
    removed,
    recovery == "vehicle" and "vehicle" or "garage")
  ctx.callbacks.firePhoneNotification("employment.shiftEnded", "Shift ended", detail, "info")
  ui_message(detail, 8, "info")
  ctx.callbacks.notifyUi()
  ctx.callbacks.closeShiftUi()
  ctx.callbacks.closeDropOffUi()
  if career_saveSystem and career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
  return true
end

return M

