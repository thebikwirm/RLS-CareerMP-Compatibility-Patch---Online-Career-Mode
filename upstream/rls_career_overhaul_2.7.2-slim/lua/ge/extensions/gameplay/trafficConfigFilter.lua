-- Traffic config eligibility: part/metadata rules evaluated once per model/config.
-- Wraps core_multiSpawn.createGroup so broken rollers / square-wheel configs never
-- enter traffic (or parked) pools.

local M = {}

M.dependencies = { 'core_multiSpawn' }

local logTag = 'trafficConfigFilter'
local RULES_PATH = '/gameplay/traffic/trafficConfigPartRules.json'

local rules = nil
local cache = {} -- [model/config] = { ok = bool, reason = string|nil }
local wrapped = false
local originalCreateGroup = nil

local function loadRules()
  local data = jsonReadFile(RULES_PATH)
  if type(data) ~= 'table' then
    log('W', logTag, 'Missing or invalid rules at ' .. RULES_PATH .. '; using built-in defaults')
    data = {
      rejectConfigTypes = { 'Frame', 'joesJunkshell' },
      rejectTrafficConfigTypes = { 'Police' },
      trafficConfigTypeWeights = { joesjunkcar = 0.05, joesjunk = 0.05 },
      rejectConfigNamePatterns = { 'police' },
      rejectIfPowerAtMost = 0,
      rejectIfPowerBelow = 60,
      rejectPartValuePatterns = { 'wheel_square' },
      engineSlotNameMustInclude = 'engine',
      engineSlotNameMustNotInclude = { 'ecu', 'internal', 'mount', 'cover', 'lid', 'bay', 'sound' },
      rejectEmptyMainEngineSlot = true,
      requireFrontAndRearWheels = true,
      wheelSlotNamePattern = '^wheel_[FR]',
    }
  end
  rules = data
  table.clear(cache)
  return rules
end

local function getRules()
  if not rules then
    loadRules()
  end
  return rules
end

local function cacheKey(model, config)
  return tostring(model or '') .. '/' .. tostring(config or '')
end

local function lower(s)
  return string.lower(tostring(s or ''))
end

-- "lid" must be a standalone token so slots like "bolide_engine" are not rejected.
local function slotNameHasBannedFragment(slotName, banned)
  local b = lower(banned)
  if b == 'lid' then
    return string.find(slotName, '%f[%w]lid%f[%W]') ~= nil or string.find(slotName, '%f[%w]lid$') ~= nil
  end
  return string.find(slotName, b, 1, true) ~= nil
end

local function isMainEngineSlot(slotName, r)
  local s = lower(slotName)
  local must = lower(r.engineSlotNameMustInclude or 'engine')
  if not string.find(s, must, 1, true) then
    return false
  end
  for _, banned in ipairs(r.engineSlotNameMustNotInclude or {}) do
    if slotNameHasBannedFragment(s, banned) then
      return false
    end
  end
  return true
end

local function partValueRejected(value, r)
  local v = lower(value)
  if v == '' then
    return false
  end
  for _, pat in ipairs(r.rejectPartValuePatterns or {}) do
    if string.find(v, lower(pat), 1, true) then
      return true, pat
    end
  end
  return false
end

local function readParts(model, config)
  if not model or not config or config == '' then
    return nil
  end
  local path = '/vehicles/' .. model .. '/' .. config .. '.pc'
  local ok, data = pcall(jsonReadFile, path)
  if not ok or type(data) ~= 'table' then
    return nil
  end
  return data.parts or data.slotMap or nil
end

local function getConfigInfo(model, config)
  if not core_vehicles or not core_vehicles.getModel then
    return nil
  end
  local modelData = core_vehicles.getModel(model)
  if not modelData or type(modelData.configs) ~= 'table' then
    return nil
  end
  return modelData.configs[config]
end

local function isPoliceSpawnIntent(params)
  if type(params) ~= 'table' then return false end
  local ctFilter = params.filters and params.filters['Config Type']
  if type(ctFilter) ~= 'table' then return false end
  local policeWeight = tonumber(ctFilter.police) or tonumber(ctFilter.Police) or 0
  if policeWeight <= 0 then return false end
  local otherWeight = ctFilter.other
  if otherWeight == nil then return true end
  return tonumber(otherWeight) == 0
end

local function applyTrafficConfigTypeWeights(params)
  if type(params) ~= 'table' or isPoliceSpawnIntent(params) then
    return params
  end
  local weights = getRules().trafficConfigTypeWeights
  if type(weights) ~= 'table' then
    return params
  end
  local hasWeight = false
  for _, w in pairs(weights) do
    if tonumber(w) ~= nil then
      hasWeight = true
      break
    end
  end
  if not hasWeight then
    return params
  end

  local out = {}
  for k, v in pairs(params) do
    out[k] = v
  end
  out.filters = {}
  for k, v in pairs(params.filters or {}) do
    out.filters[k] = v
  end
  local srcCt = out.filters['Config Type']
  local ct = {}
  if type(srcCt) == 'table' then
    for k, v in pairs(srcCt) do
      ct[k] = v
    end
  else
    ct.other = 1
  end
  for configType, weight in pairs(weights) do
    local w = tonumber(weight)
    if w ~= nil then
      ct[lower(configType)] = w
    end
  end
  out.filters['Config Type'] = ct
  return out
end

local function isReservedTrafficConfig(model, config, r)
  local info = getConfigInfo(model, config)
  local configType = info and (info['Config Type'] or info.configType) or nil
  if configType then
    local ct = lower(configType)
    for _, reserved in ipairs(r.rejectTrafficConfigTypes or { 'Police' }) do
      if ct == lower(reserved) then
        return true, 'trafficConfigType:' .. tostring(configType)
      end
    end
  end
  local cfgName = lower(config)
  if cfgName ~= '' then
    for _, pat in ipairs(r.rejectConfigNamePatterns or { 'police' }) do
      if string.find(cfgName, lower(pat), 1, true) then
        return true, 'configName:' .. tostring(pat)
      end
    end
  end
  return false
end

--- Returns ok, reason. Cached.
local function isConfigEligible(model, config, params)
  local policePool = isPoliceSpawnIntent(params)
  local key = cacheKey(model, config) .. (policePool and '|police' or '|traffic')
  local hit = cache[key]
  if hit ~= nil then
    return hit.ok, hit.reason
  end

  local r = getRules()
  local info = getConfigInfo(model, config)
  local configType = info and (info['Config Type'] or info.configType) or nil
  local power = info and tonumber(info.Power or info.power) or nil

  if not policePool then
    local reserved, reservedReason = isReservedTrafficConfig(model, config, r)
    if reserved then
      cache[key] = { ok = false, reason = reservedReason }
      return false, reservedReason
    end
  end

  if configType then
    local ct = lower(configType)
    for _, bad in ipairs(r.rejectConfigTypes or {}) do
      if ct == lower(bad) then
        cache[key] = { ok = false, reason = 'configType:' .. tostring(configType) }
        return false, cache[key].reason
      end
    end
  end

  if power ~= nil then
    local atMost = tonumber(r.rejectIfPowerAtMost)
    if atMost ~= nil and power <= atMost then
      cache[key] = { ok = false, reason = 'powerAtMost:' .. tostring(power) }
      return false, cache[key].reason
    end
    local below = tonumber(r.rejectIfPowerBelow)
    if below ~= nil and power > 0 and power < below then
      cache[key] = { ok = false, reason = 'powerBelow:' .. tostring(power) }
      return false, cache[key].reason
    end
  end

  local parts = readParts(model, config)
  if type(parts) == 'table' then
    local hasFrontWheel, hasRearWheel = false, false
    local sawMainEngine, mainEngineEmpty = false, false

    for slot, value in pairs(parts) do
      local slotName = tostring(slot)
      local val = value == nil and '' or tostring(value)

      local badVal, pat = partValueRejected(val, r)
      if badVal then
        cache[key] = { ok = false, reason = 'partValue:' .. pat .. ':' .. slotName }
        return false, cache[key].reason
      end

      if isMainEngineSlot(slotName, r) then
        sawMainEngine = true
        if val == '' then
          mainEngineEmpty = true
        end
      end

      if r.requireFrontAndRearWheels ~= false then
        local wheelPat = r.wheelSlotNamePattern or '^wheel_[FR]'
        if string.match(slotName, wheelPat) then
          if val == '' then
            cache[key] = { ok = false, reason = 'emptyWheel:' .. slotName }
            return false, cache[key].reason
          end
          if string.match(slotName, '^wheel_F') then
            hasFrontWheel = true
          elseif string.match(slotName, '^wheel_R') then
            hasRearWheel = true
          end
        end
      end
    end

    if r.rejectEmptyMainEngineSlot ~= false and sawMainEngine and mainEngineEmpty then
      cache[key] = { ok = false, reason = 'emptyEngine' }
      return false, cache[key].reason
    end

    -- No main engine slot at all + zero/missing power → treat as roller/shell.
    if r.rejectEmptyMainEngineSlot ~= false and not sawMainEngine and (power == nil or power <= 0) then
      cache[key] = { ok = false, reason = 'noEngine' }
      return false, cache[key].reason
    end

    if r.requireFrontAndRearWheels ~= false and (hasFrontWheel or hasRearWheel) then
      if not hasFrontWheel or not hasRearWheel then
        cache[key] = { ok = false, reason = 'incompleteWheels' }
        return false, cache[key].reason
      end
    end
  end

  cache[key] = { ok = true, reason = nil }
  return true, nil
end

local function wrapMultiSpawn()
  if wrapped then
    return true
  end
  if not core_multiSpawn or type(core_multiSpawn.createGroup) ~= 'function' then
    return false
  end
  if core_multiSpawn._rlsTrafficConfigFilterWrapped then
    wrapped = true
    return true
  end

  -- createGroup uses a *local* getInstalledVehicleData, so wrapping the export is
  -- not enough. Wrap createGroup, oversample, and keep only eligible configs.
  originalCreateGroup = core_multiSpawn.createGroup
  core_multiSpawn.createGroup = function(amount, params)
    amount = amount or 10
    local want = math.max(1, amount)
    params = applyTrafficConfigTypeWeights(params)
    local policePool = isPoliceSpawnIntent(params)
    local out, seen = {}, {}
    local lastBatch = nil
    for _ = 1, 4 do
      if #out >= want then
        break
      end
      local batch = originalCreateGroup(math.max(want * 3, want), params) or {}
      if #batch > 0 then
        lastBatch = batch
      end
      for _, entry in ipairs(batch) do
        local model = entry and entry.model
        local config = entry and entry.config
        local key = tostring(model) .. '/' .. tostring(config)
        if not seen[key] and isConfigEligible(model, config, params) then
          seen[key] = true
          out[#out + 1] = entry
          if #out >= want then
            break
          end
        end
      end
    end
    if #out == 0 and lastBatch and #lastBatch > 0 then
      local r = getRules()
      for _, entry in ipairs(lastBatch) do
        local model = entry and entry.model
        local config = entry and entry.config
        local key = tostring(model) .. '/' .. tostring(config)
        if not seen[key] then
          local allow = policePool
          if not allow then
            local reserved = isReservedTrafficConfig(model, config, r)
            allow = not reserved
          end
          if allow and isConfigEligible(model, config, params) then
            seen[key] = true
            out[#out + 1] = entry
            if #out >= want then
              break
            end
          end
        end
      end
      if #out == 0 then
        log('W', logTag, 'Traffic filter removed all candidates; returning empty group')
      end
    end
    if #out < want then
      log('W', logTag, string.format('Traffic group short after filter: want %d, got %d', want, #out))
    end
    return out
  end

  core_multiSpawn._rlsTrafficConfigFilterWrapped = true
  wrapped = true
  log('I', logTag, 'Wrapped core_multiSpawn.createGroup for part-based traffic filter')
  return true
end

local function onExtensionUnloaded()
  if originalCreateGroup and core_multiSpawn and core_multiSpawn._rlsTrafficConfigFilterWrapped then
    core_multiSpawn.createGroup = originalCreateGroup
    core_multiSpawn._rlsTrafficConfigFilterWrapped = nil
  end
  originalCreateGroup = nil
  wrapped = false
end

local function onExtensionLoaded()
  loadRules()
  wrapMultiSpawn()
end

local function onCareerActivated()
  wrapMultiSpawn()
end

local function onModActivated()
  table.clear(cache)
  loadRules()
end

local function onFileChanged(filename)
  if type(filename) == 'string' and filename:find('trafficConfigPartRules', 1, true) then
    loadRules()
  end
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onCareerActivated = onCareerActivated
M.onModActivated = onModActivated
M.onFileChanged = onFileChanged

M.isConfigEligible = isConfigEligible
M.reloadRules = loadRules
M.getRules = getRules
M.wrapMultiSpawn = wrapMultiSpawn

return M
