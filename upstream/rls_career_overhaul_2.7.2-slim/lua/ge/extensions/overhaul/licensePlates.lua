local M = {}

local logTag = "licensePlates"

-- Stock plate material samples @licenseplate-default. Until Skia binds that tag,
-- the mesh draws the engine placeholder ("no Texture"). Two cases leave it unbound:
-- the plate mesh lives on another part, so license-plate processing never runs,
-- and a pooled vehicle comes back active without a new render.
local RETRY_DELAY = 0.4
local MAX_TRIES = 8

local pending = {}

local function hasPlateMesh(veh)
  local ok, meshes = pcall(function()
    return veh:getMeshesContainingMaterial("licenseplate")
  end)
  return ok and type(meshes) == "string" and meshes:find("licenseplate", 1, true) ~= nil
end

local function refreshPlate(vehId)
  local veh = getObjectByID(vehId)
  if not veh then return false end
  if veh.JBeam == "unicycle" then return true end
  if not veh:getActive() or not veh:isRenderMaterialsReady() then return false end
  if not hasPlateMesh(veh) then return true end
  if settings.getValue("SkipGenerateLicencePlate") then return true end
  if not core_vehicles or not core_vehicles.setPlateText then return false end

  local text = veh:getDynDataFieldbyName("licenseText", 0)
  if text == "" then text = nil end
  -- Clear first so a future string-to-string early-out cannot skip the rebind.
  veh:setDynDataFieldbyName("licenseText", 0, "")
  local ok, err = pcall(core_vehicles.setPlateText, text, vehId)
  if not ok then
    log("W", logTag, "Plate refresh failed for " .. tostring(vehId) .. ": " .. tostring(err))
    return false
  end
  return true
end

local function schedule(vehId)
  if not vehId then return end
  pending[vehId] = { tries = 0, wait = RETRY_DELAY }
end

local function onUpdate(dt)
  if not next(pending) then return end
  local step = math.min(dt or 0, 0.25)
  for vehId, job in pairs(pending) do
    job.wait = job.wait - step
    if job.wait <= 0 then
      if refreshPlate(vehId) then
        pending[vehId] = nil
      else
        job.tries = job.tries + 1
        if job.tries >= MAX_TRIES or not getObjectByID(vehId) then
          pending[vehId] = nil
        else
          job.wait = RETRY_DELAY
        end
      end
    end
  end
end

local function onVehicleSpawned(vehId)
  schedule(vehId)
end

local function onVehicleActiveChanged(vehId, active)
  if active then schedule(vehId) end
end

local function onVehicleDestroyed(vehId)
  pending[vehId] = nil
end

local function scheduleSpawnedVehicles()
  for i = 0, be:getObjectCount() - 1 do
    local veh = be:getObject(i)
    if veh then schedule(veh:getID()) end
  end
end

M.onUpdate = onUpdate
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleActiveChanged = onVehicleActiveChanged
M.onVehicleDestroyed = onVehicleDestroyed
M.onExtensionLoaded = scheduleSpawnedVehicles
M.requestRefresh = schedule

return M
