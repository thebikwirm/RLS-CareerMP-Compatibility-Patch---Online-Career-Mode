-- Persist independent work against inventory IDs, never temporary scene IDs.
local M = {}
local function inventoryId(vehId)
  local inventory = career_modules_inventory
  return inventory and inventory.getInventoryIdFromVehicleId(vehId)
end
function M.canPersistCargo(cargo)
  return cargo.data and cargo.data.brokerId and cargo.location
    and cargo.location.type == 'vehicle'
    and ((cargo.logisticsBinding and cargo.logisticsBinding.inventoryId) or inventoryId(cargo.location.vehId)) ~= nil
end
function M.capture(pending)
  local result = deepcopy(pending or {cargo={}, tasks={}})
  result.cargo = result.cargo or {}; result.tasks = result.tasks or {}
  for _, cargo in ipairs(career_modules_delivery_parcelManager.getAllCargoInVehicles() or {}) do
    if M.canPersistCargo(cargo) and not cargo._transientMove then
      cargo.data.brokerCargoKey = cargo.data.brokerCargoKey or (cargo.data.brokerId .. ':' .. cargo.id)
      result.cargo[cargo.data.brokerCargoKey] = {cargo=deepcopy(cargo),
        inventoryId=(cargo.logisticsBinding and cargo.logisticsBinding.inventoryId) or inventoryId(cargo.location.vehId)}
    end
  end
  local manager = career_modules_delivery_vehicleTasks
  for _, task in ipairs(manager and manager.getVehicleTasks() or {}) do
    if task.offer.brokerId and not task.remove and not task.finished and not task.giveBack then
      local invId = task.offer.vehicle.inventoryId or inventoryId(task.vehId)
      if invId then
        local key = task.offer.brokerId .. ':' .. tostring((task.offer.data or {}).finkVehicleKey or 'trailer')
        result.tasks[key] = {inventoryId=invId, offer=deepcopy(task.offer),
          tasks=deepcopy(task.tasks), activeTaskIndex=task.activeTaskIndex, startedTimestamp=task.startedTimestamp}
      end
    end
  end
  return result
end
-- Terminal work must never be resurrected, including work saved on another map.
local function pruneTerminalJobs(pending, jobs)
  for key, saved in pairs((pending or {}).cargo or {}) do
    local job = jobs[saved.cargo.data.brokerId]
    if job and (job.status == 'complete' or job.status == 'cancelled') then
      pending.cargo[key] = nil
    end
  end
  for key, saved in pairs((pending or {}).tasks or {}) do
    local job = jobs[saved.offer.brokerId]
    if job and (job.status == 'complete' or job.status == 'cancelled') then
      pending.tasks[key] = nil
    end
  end
end
function M.prepare(pending, jobs)
  pruneTerminalJobs(pending, jobs)
  for _, saved in pairs((pending or {}).tasks or {}) do
    local offer = saved.offer
    local job = jobs[offer.brokerId]
    if job and job.map == getCurrentLevelIdentifier() then
      offer.id = career_modules_delivery_generator.allocateCargoId()
      offer.spawned = true; offer.brokerRestoring = true; offer.vehicle.vehId = nil
      career_modules_delivery_vehicleOfferManager.addOffer(offer)
      if job.kind == 'trailer' then job.nativeId = offer.id end
    end
  end
end
function M.restore(pending, jobs)
  pruneTerminalJobs(pending, jobs)
  local inv, pm = career_modules_inventory, career_modules_delivery_parcelManager
  if not inv or not pm then return end
  local changed = false
  for key, saved in pairs(pending.cargo or {}) do
    local job = jobs[saved.cargo.data.brokerId]
    local vehId = inv.getVehicleIdFromInventoryId(saved.inventoryId)
    if job and job.map == getCurrentLevelIdentifier() and vehId and be:getObjectByID(vehId) then
      local exists = pm.getAllCargoCustomFilter(function(c) return c.data and c.data.brokerCargoKey == key end)
      if not exists[1] then
        local cargo = deepcopy(saved.cargo)
        cargo.id = career_modules_delivery_generator.allocateCargoId()
        cargo.location.vehId = vehId; cargo._transientMove = nil
        pm.addCargo(cargo)
      end
      pending.cargo[key] = nil; changed = true
    end
  end
  for key, saved in pairs(pending.tasks or {}) do
    local job = jobs[saved.offer.brokerId]
    local vehId = inv.getVehicleIdFromInventoryId(saved.inventoryId)
    if job and job.map == getCurrentLevelIdentifier() and vehId and be:getObjectByID(vehId) then
      saved.offer.vehicle.vehId = vehId
      career_modules_delivery_vehicleTasks.restoreBrokerTask(saved, vehId)
      saved.offer.brokerRestoring = nil
      pending.tasks[key] = nil; changed = true
    end
  end
  if changed then
    local general = career_modules_delivery_general
    if not general.isDeliveryModeActive() then general.startDeliveryMode() end
    general.requestUpdateContainerWeights()
    career_modules_delivery_tasklist.sendCargoToTasklist()
  end
end
return M
