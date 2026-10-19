-- Temporarily remove the vehicle's brakes on dyno-equipped axles.
-- Saved choices travel with the config and are restored when normal wheels return.
local M = {}
local pending = {}
local grounding = {}
local ignoreReset = {}
local configBuilderOwner, originalConfigBuilder, configBuilderWrapper
local migrationEnabled = false
local legacyParts = {
  wheel_dyno_rls_fixed_F5 = 'wheel_dyno_rls_F5',
  wheel_dyno_rls_fixed_R5 = 'wheel_dyno_rls_R5',
  rls_hubdyno_fixed_case_F = 'rls_hubdyno_case_F',
  rls_hubdyno_fixed_case_R = 'rls_hubdyno_case_R'
}

local function migratePath(path)
  if type(path) ~= 'string' then return path end
  return (path:gsub('[^/]+', legacyParts))
end

local function dynoAxle(origin)
  if origin == 'wheel_dyno_rls_F5' or origin == 'rls_hubdyno_case_F' then return 'F' end
  if origin == 'wheel_dyno_rls_R5' or origin == 'rls_hubdyno_case_R' then return 'R' end
end

-- Different wheel-slot heights must not move the axle attachment away from
-- the stock suspension. Extend only the feet to the lowest support plane.
M.onJbeamLoadingPhase1 = function(_, _, vehicle)
  local floors = {}
  for _,n in pairs(vehicle.nodes or {}) do
    local axle = dynoAxle(n.partOrigin)
    -- Apply hub tuning after all inherited frame/axle transforms. A per-node
    -- nodeMove table replaces the parent's wheelbase/ride-height adjustment
    -- and can leave this bearing off-axis, mechanically locking the rotor.
    if axle and n.rlsDynoHubOffset then
      n.pos.x = n.pos.x + n.rlsDynoHubOffset
    end
    if axle and n.name and n.name:match('^[fr]wdb[23]') then
      floors[axle] = math.min(floors[axle] or math.huge, n.pos.z)
    end
  end
  if not floors.F or not floors.R then return end
  local floor = math.min(floors.F, floors.R)
  for _,n in pairs(vehicle.nodes or {}) do
    local axle = dynoAxle(n.partOrigin)
    if axle and n.name and n.name:match('^[fr]wdb[23]') then
      n.pos.z = n.pos.z + floor - floors[axle]
    end
  end
  for _,f in pairs(vehicle.flexbodies or {}) do
    local axle = dynoAxle(f.partOrigin)
    if axle and f.pos and (f.mesh or ''):match('^rls_hubdyno_feetD*$') then
      -- Authored feet bounds in rls_hubdyno.dae; scale about the upper mount
      -- so it stays attached to the housing while the sole reaches the floor.
      local top, bottom = 0.1929932, -0.2753192
      local extension = floors[axle] - floor
      f.scale = f.scale or {x=1, y=1, z=1}
      local scale = f.scale.z or 1
      local newScale = scale + extension / (top - bottom)
      f.pos.z = (f.pos.z or 0) + top * (scale - newScale)
      f.scale.z = newScale
    end
  end
end

local function walk(node, fn)
  if type(node) ~= 'table' then return end
  fn(node)
  for _, child in pairs(node.children or {}) do walk(child, fn) end
end

-- Retired fixed-family configs resolve to the remaining parts before JBeam
-- selection; waiting until onVehicleSpawned would already lose missing hubs.
M.migrateConfig = function(sourceConfig)
  if type(sourceConfig) ~= 'table' then return sourceConfig, false end
  local needed = sourceConfig.rlsHubDynoSavedBrakes ~= nil
  for slot, part in pairs(sourceConfig.parts or {}) do
    if legacyParts[slot] or legacyParts[part] then needed = true end
  end
  walk(sourceConfig.partsTree, function(n)
    if legacyParts[n.chosenPartName] or legacyParts[n.id] or migratePath(n.path) ~= n.path then needed = true end
  end)
  if not needed then return sourceConfig, false end
  local config = deepcopy(sourceConfig)
  if config.parts then
    local parts = {}
    for slot, part in pairs(config.parts) do
      if not legacyParts[slot] then parts[slot] = legacyParts[part] or part end
    end
    for slot, part in pairs(config.parts) do
      if legacyParts[slot] and parts[legacyParts[slot]] == nil then
        parts[legacyParts[slot]] = legacyParts[part] or part
      end
    end
    config.parts = parts
  end
  local function migrateNode(n)
    n.chosenPartName = legacyParts[n.chosenPartName] or n.chosenPartName
    n.id = legacyParts[n.id] or n.id
    n.path = migratePath(n.path)
  end
  walk(config.partsTree, migrateNode)
  local saved = config.rlsOverhaulDynoSavedBrakes or {}
  for key, choice in pairs(config.rlsHubDynoSavedBrakes or {}) do
    key = migratePath(key)
    if saved[key] == nil then
      saved[key] = choice
      walk(choice, migrateNode)
    end
  end
  config.rlsOverhaulDynoSavedBrakes = next(saved) and saved or nil
  config.rlsHubDynoSavedBrakes = nil
  return config, true
end

-- Prepare before a career spawn so removing brakes does not trigger a second
-- respawn after the session has positioned and initialized its vehicle.
M.prepareConfig = function(sourceConfig)
  local migrated, changed = M.migrateConfig(sourceConfig)
  local config = deepcopy(migrated)
  if not config or not config.partsTree then return config, changed, {} end
  local axles = {}
  walk(config.partsTree, function(n)
    if n.chosenPartName == 'wheel_dyno_rls_F5' then axles.F = true end
    if n.chosenPartName == 'wheel_dyno_rls_R5' then axles.R = true end
  end)
  local saved = config.rlsOverhaulDynoSavedBrakes or {}
  if not next(axles) and not next(saved) then return config, changed, axles end
  walk(config.partsTree, function(n)
    local slot = n.id or ''
    local axle = slot:match('_brakes?_([FR])$') or slot:match('_brakes?_([FR])_')
    if not axle then return end
    local key = n.path or slot
    if axles[axle] and (n.chosenPartName or '') ~= '' then
      saved[key] = {part = n.chosenPartName, children = n.children}
      n.chosenPartName, n.children, n.decisionMethod = '', nil, 'user-empty'
      changed = true
    elseif not axles[axle] and saved[key] then
      if (n.chosenPartName or '') == '' then
        n.chosenPartName = saved[key].part
        n.children = saved[key].children
        n.decisionMethod = 'user'
      end
      saved[key] = nil
      changed = true
    end
  end)
  if changed then
    config.rlsOverhaulDynoSavedBrakes = next(saved) and saved or nil
  end
  return config, changed, axles
end

local function updateVehicle(id)
  local veh = be:getObjectByID(id)
  local data = core_vehicle_manager.getVehicleData(id)
  if not veh or not data or not data.config or not data.config.partsTree then return end
  local config, changed, axles = M.prepareConfig(data.config)
  if changed then
    veh:respawn(serialize(config))
  elseif next(axles) then
    grounding[id] = {delay=0.15, level=true}
  end
end

M.onVehicleSpawned = function(id) pending[id] = true end
M.onVehicleDestroyed = function(id) pending[id] = nil; grounding[id] = nil; ignoreReset[id] = nil end
M.onVehicleResetted = function(id)
  if not grounding[id] and not ignoreReset[id] then pending[id] = true end
end
M.onUpdate = function(dtReal)
  for id, t in pairs(ignoreReset) do
    ignoreReset[id] = t - (dtReal or 0)
    if ignoreReset[id] <= 0 then ignoreReset[id] = nil end
  end
  local work = pending
  pending = {}
  for id in pairs(work) do updateVehicle(id) end
  for id, state in pairs(grounding) do
    state.delay = state.delay - (dtReal or 0)
    if state.delay <= 0 then
      local veh = be:getObjectByID(id)
      local data = core_vehicle_manager.getVehicleData(id)
      if veh and data and data.vdata then
        local pos = veh:getPosition()
        -- Normal suspension may leave the old wheel configuration pitched or rolled.
        -- A bolted-down dyno needs a level base before its vertical placement.
        if state.level then
          local a,b
          for _,n in pairs(data.vdata.nodes) do
            if n.name == 'fwdb1l' or (not a and n.name == 'rwdb1l') then a=veh:getNodePosition(n.cid) end
            if n.name == 'fwdb4l' or (not b and n.name == 'rwdb4l') then b=veh:getNodePosition(n.cid) end
          end
          local dir = a and b and (b-a) or veh:getDirectionVector()
          dir.z = 0
          if dir:squaredLength() > 0.01 then
            local rot = quat(0,0,1,0) * quatFromDir(dir:normalized(), vec3(0,0,1))
            ignoreReset[id] = 1
            veh:setPosRot(pos.x,pos.y,pos.z,rot.x,rot.y,rot.z,rot.w)
          end
          state.level=false
          state.delay=0.15
        else
        local correction = -math.huge
        for _, n in pairs(data.vdata.nodes or {}) do
          if n.name and n.name:match('^[fr]wdb[23]') and
              (n.partOrigin == 'wheel_dyno_rls_F5' or n.partOrigin == 'wheel_dyno_rls_R5') then
            local foot = pos + veh:getNodePosition(n.cid)
            local rayStart = foot + vec3(0,0,2)
            local distance = castRayStatic(rayStart, vec3(0,0,-1), 10)
            -- Leave a 2 mm visual/contact clearance instead of accepting up to
            -- 2 mm of penetration as the previous placement tolerance did.
            if distance and distance < 10 then correction = math.max(correction, 2 - distance + 0.002) end
          end
        end
        if correction > -math.huge and math.abs(correction) > 0.0005 then
          ignoreReset[id] = 1
          local target = pos + vec3(0,0,correction)
          -- Translate all fixed clusters without resetting suspension deflection.
          veh:setClusterPosRelRot(veh:getRefNodeId(),target.x,target.y,target.z,0,0,0,1)
        end
        state.passes = (state.passes or 0) + 1
        state.stablePasses = math.abs(correction) <= 0.0005 and (state.stablePasses or 0) + 1 or 0
        -- The chassis reference keeps moving while suspension settles after
        -- the brake-removal respawn. Three immediate attempts can finish with
        -- the fixed bases underground; require several settled observations.
        if correction > -math.huge and state.passes < 20 and
            (state.passes < 8 or state.stablePasses < 3) then state.delay=0.15
        else grounding[id] = nil end
        end
      else
        grounding[id] = nil
      end
    end
  end
end
M.onExtensionLoaded = function()
  migrationEnabled = true
  local owner = core_vehicle_partmgmt or (extensions and extensions.core_vehicle_partmgmt)
  if owner and type(owner.buildConfigFromString) == 'function' and owner.buildConfigFromString ~= configBuilderWrapper then
    configBuilderOwner = owner
    originalConfigBuilder = owner.buildConfigFromString
    local previous = originalConfigBuilder
    configBuilderWrapper = function(...)
      local config, chosen = previous(...)
      if migrationEnabled then config = M.migrateConfig(config) end
      return config, chosen
    end
    owner.buildConfigFromString = configBuilderWrapper
  end
  for i = 0, be:getObjectCount() - 1 do pending[be:getObject(i):getID()] = true end
end
M.onExtensionUnloaded = function()
  migrationEnabled = false
  if configBuilderOwner and configBuilderOwner.buildConfigFromString == configBuilderWrapper then
    configBuilderOwner.buildConfigFromString = originalConfigBuilder
  end
end
return M
