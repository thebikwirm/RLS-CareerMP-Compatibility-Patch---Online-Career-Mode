-- Validate the entire selection before progress moves cargo or credits rewards.
local M = {}

function M.capture(cargo)
  local loc = cargo.location or {}
  return {cargo = cargo, vehId = loc.vehId, containerId = loc.containerId,
    slots = cargo.slots, materialType = cargo.materialType, type = cargo.type}
end

function M.validate(elements, allCargo, getCargoById, accepts, expected, allowRecoveryCargo)
  local counts, seen = {}, {}
  for _, cargo in ipairs(allCargo) do
    counts[cargo.id] = (counts[cargo.id] or 0) + 1
  end
  for _, elem in ipairs(elements) do
    local ids = type(elem.ids) == 'table' and elem.ids[1] and elem.ids or (elem.id and {elem.id} or {})
    if not ids[1] then return false, 'empty cargo selection' end
    local total = 0
    for _, id in ipairs(ids) do
      if counts[id] ~= 1 or seen[id] then return false, 'missing or duplicate cargo ID ' .. tostring(id) end
      seen[id] = true
      local cargo = getCargoById(id)
      local loc = cargo and cargo.location
      if not loc then return false, 'cargo ' .. tostring(id) .. ' has no location' end
      if loc.type ~= 'vehicle' and not (allowRecoveryCargo and allowRecoveryCargo(cargo)) then
        return false, 'cargo ' .. tostring(id) .. ' is not loaded in a vehicle'
      end
      if cargo.logisticsPending and not (allowRecoveryCargo and allowRecoveryCargo(cargo)) then
        return false, 'cargo ' .. tostring(id) .. ' is waiting for vehicle restoration'
      end
      if expected then
        local saved = expected[id]
        if not saved or saved.cargo ~= cargo or saved.vehId ~= loc.vehId
          or saved.containerId ~= loc.containerId or saved.slots ~= cargo.slots
          or saved.materialType ~= cargo.materialType or saved.type ~= cargo.type then
          return false, 'cargo changed since opening the drop-off screen'
        end
      end
      if not accepts(cargo) then return false, 'cargo does not belong at this destination' end
      local data = cargo.data or {}
      local recalculatesRewards = data.materialContractId or data.passiveBusinessSupplyReservationId
        or data.engineShopSupplyReservationId or (cargo.materialType and not cargo.automaticDropOff)
      if not recalculatesRewards and (type(cargo.rewards) ~= 'table' or type(cargo.rewards.money) ~= 'number') then
        return false, 'cargo reward data is missing'
      end
      total = total + (tonumber(cargo.slots) or 0)
    end
    if elem.amount ~= nil then
      local amount = tonumber(elem.amount)
      if not amount or amount ~= amount or amount < 0 or amount == math.huge or amount > total + 0.0001 then
        return false, 'requested amount exceeds the selected cargo'
      end
    end
  end
  return true
end

return M
