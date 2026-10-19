local M = {}

local ENTER_WRAP = "__rlsTaxiRideAssistEnterBigMap"
local enterWrapped = false

local function vecFromWaypoint(wp)
  if wp == nil then return nil end
  if wp.x and wp.y then
    return vec3(wp.x, wp.y, wp.z or 0)
  end
  if type(wp) == "string" then
    local nodes = map.getMap() and map.getMap().nodes
    local node = nodes and nodes[wp]
    return node and node.pos and vec3(node.pos) or nil
  end
  if type(wp) == "table" and wp[1] and wp[2] then
    return vec3(wp[1], wp[2], wp[3] or 0)
  end
  return nil
end

local function getExistingNavDestination()
  local gm = core_groundMarkers
  if not gm then return nil end
  if gm.currentlyHasTarget and not gm.currentlyHasTarget() then
    return nil
  end
  local endWP = gm.endWP
  if type(endWP) == "table" and endWP[1] then
    return vecFromWaypoint(endWP[#endWP]) or vecFromWaypoint(endWP[1])
  end
  if gm.getTargetPos then
    return vecFromWaypoint(gm.getTargetPos())
  end
  return nil
end

local function tryConfirmExistingTaxiDestination()
  local dest = getExistingNavDestination()
  local taxi = gameplay_taxi
  if not dest or not taxi then return false end
  if not taxi.onSetBigmapNavFocus then return false end
  local playerVeh = be and be.getPlayerVehicle and be:getPlayerVehicle(0)
  if playerVeh and playerVeh.getPosition then
    local here = playerVeh:getPosition()
    if here and here.distance and here:distance(dest) < 12 then
      return false
    end
  end
  taxi.onSetBigmapNavFocus(dest)
  if taxi.startTaxiWithCurrentRoute then
    taxi.startTaxiWithCurrentRoute()
  elseif taxi.confirmTaxiDestination then
    taxi.confirmTaxiDestination()
  else
    return false
  end
  return true
end

local function wrapEnterBigMap()
  if not freeroam_bigMapMode or type(freeroam_bigMapMode.enterBigMap) ~= "function" then
    return false
  end
  if type(freeroam_bigMapMode[ENTER_WRAP]) == "function" then
    enterWrapped = true
    return true
  end
  local original = freeroam_bigMapMode.enterBigMap
  freeroam_bigMapMode[ENTER_WRAP] = original
  freeroam_bigMapMode.enterBigMap = function(opts)
    opts = opts or {}
    if opts.mode == "taxi" and tryConfirmExistingTaxiDestination() then
      return
    end
    return original(opts)
  end
  enterWrapped = true
  return true
end

local function unwrapEnterBigMap()
  if not freeroam_bigMapMode then
    enterWrapped = false
    return
  end
  local original = freeroam_bigMapMode[ENTER_WRAP]
  if type(original) == "function" then
    freeroam_bigMapMode.enterBigMap = original
  end
  freeroam_bigMapMode[ENTER_WRAP] = nil
  enterWrapped = false
end

function M.onExtensionLoaded()
  wrapEnterBigMap()
end

function M.onClientStartMission()
  wrapEnterBigMap()
end

function M.onExtensionUnloaded()
  unwrapEnterBigMap()
end

function M.onUpdate()
  if not enterWrapped then
    wrapEnterBigMap()
  end
end

M.getExistingNavDestination = getExistingNavDestination

return M
