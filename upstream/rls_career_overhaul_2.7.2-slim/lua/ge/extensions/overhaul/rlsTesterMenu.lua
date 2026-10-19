local M = {}

-- Not a career_modules_* file: career must not auto-load this. F9 loads it.

local logTag = "rlsTesterMenu"
local SETTINGS_PATH = "settings/RLS/testerMenu.json"
local DEFAULT_TOGGLE_CONTROL = "f9"
local ACTION_NAME = "rlsTesterMenuToggle"
local ACTION_FILE = "/lua/ge/extensions/overhaul/rlsTesterMenu.actions.json"

local menuVisible = false
local keyOk = false
local lastKeyCheck = -1e9
local statusText = ""
local statusIsError = false
local toggleControl = DEFAULT_TOGGLE_CONTROL
local bindDeviceName = "keyboard0"
local rebindArmed = false

local SPAWN_PRESETS = {
  {id = "drift", label = "Drift", model = "fullsize", config = "custom2"},
  {id = "race", label = "Race", model = "vivace", config = "adente_race"},
  {id = "rally", label = "Rally", model = "vivace", config = "gravel_SQ"},
  {id = "work", label = "Work Truck", model = "md_series", config = "info_md_career_shuffleboard_flatbed"},
}

local TIME_PRESETS = {
  {label = "Morning", minute = 7 * 60},
  {label = "Noon", minute = 12 * 60},
  {label = "Dusk", minute = 19 * 60},
  {label = "Night", minute = 0},
}

local function toast(kind, msg)
  statusText = msg or ""
  statusIsError = kind == "error"
  if guihooks and guihooks.trigger then
    guihooks.trigger("toastrMsg", {
      type = kind == "error" and "error" or "info",
      title = "RLS Tester",
      msg = msg,
    })
  end
  log(kind == "error" and "W" or "I", logTag, msg or "")
end

local function refreshCreatorKey(force)
  local now = os.clock()
  if not force and (now - lastKeyCheck) < 1 then return keyOk end
  lastKeyCheck = now
  keyOk = overhaul_extensionManager and overhaul_extensionManager.isDevKeyValid
    and overhaul_extensionManager.isDevKeyValid() == true
  return keyOk
end

local function sanitizeControl(value)
  local control = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if control == "" then return nil end
  if #control > 64 then return nil end
  if control:find("[%c\"']") then return nil end
  return control:lower()
end

local function formatControlLabel(control, deviceName)
  control = tostring(control or "")
  if control == "" then return "unbound" end
  if tostring(deviceName or ""):find("mouse", 1, true) then
    local btnNum = tonumber(control:match("button(%d+)"))
    if btnNum == 0 then return "Mouse Left" end
    if btnNum == 1 then return "Mouse Right" end
    if btnNum == 2 then return "Mouse Middle" end
    if btnNum then return "Mouse Button " .. (btnNum + 1) end
    return "Mouse " .. control
  end
  local symbolMap = {
    backslash = "\\", slash = "/", comma = ",", period = ".",
    semicolon = ";", apostrophe = "'", grave = "`", minus = "-",
    equals = "=", leftbracket = "[", rightbracket = "]"
  }
  if symbolMap[control] then return symbolMap[control] end
  if control:match("^f%d+$") then return control:upper() end
  if control == "space" then return "Space" end
  if control == "enter" or control == "return" then return "Enter" end
  if control == "tab" then return "Tab" end
  if control:len() == 1 then return control:upper() end
  return control:gsub("^%l", string.upper):gsub("_", " ")
end

local function findKeyboardDevice()
  if not (core_input_bindings and core_input_bindings.bindings) then return nil end
  local fallback = nil
  for _, device in ipairs(core_input_bindings.bindings) do
    local name = tostring(device.devname or ""):lower()
    if name == "keyboard0" then return device end
    if not fallback and name:find("keyboard", 1, true) then fallback = device end
  end
  return fallback
end

local function findDevice(deviceName)
  if not (core_input_bindings and core_input_bindings.bindings) then return nil end
  if type(deviceName) == "string" and deviceName ~= "" then
    for _, device in ipairs(core_input_bindings.bindings) do
      if device.devname == deviceName then return device end
    end
    return nil
  end
  return findKeyboardDevice()
end

local function readLiveBinding()
  if not (core_input_bindings and core_input_bindings.bindings) then return nil end
  local found = {}
  for _, device in ipairs(core_input_bindings.bindings) do
    if device and device.contents and type(device.contents.bindings) == "table" then
      for _, binding in ipairs(device.contents.bindings) do
        if binding.action == ACTION_NAME then
          local control = sanitizeControl(binding.control)
          if control then
            found[#found + 1] = {control = control, deviceName = device.devname}
          end
        end
      end
    end
  end
  if #found == 0 then return nil end
  if #found > 1 then
    for _, row in ipairs(found) do
      local name = tostring(row.deviceName or ""):lower()
      if name:find("mouse", 1, true) then return row end
    end
  end
  for _, row in ipairs(found) do
    if row.deviceName == bindDeviceName then return row end
  end
  return found[1]
end

local function refreshFromLive()
  local live = readLiveBinding()
  if not live then return false end
  toggleControl = live.control
  if type(live.deviceName) == "string" and live.deviceName ~= "" then
    bindDeviceName = live.deviceName
  end
  return true
end

local function setBindingCapture(enabled)
  pcall(function()
    if ActionMap and ActionMap.enableBindingCapturing then
      ActionMap.enableBindingCapturing(enabled == true)
    end
  end)
  pcall(function()
    setCEFTyping(enabled == true)
  end)
  pcall(function()
    if WinInput and WinInput.setForwardRawEvents then
      WinInput.setForwardRawEvents(enabled == true)
    end
  end)
end

local function stripActionFromAllDevices()
  if not (core_input_bindings and core_input_bindings.bindings) then return end
  for _, device in ipairs(core_input_bindings.bindings) do
    local contents = device and device.contents
    if contents and type(contents.bindings) == "table" then
      local removed = false
      for i = #contents.bindings, 1, -1 do
        if contents.bindings[i].action == ACTION_NAME then
          table.remove(contents.bindings, i)
          removed = true
        end
      end
      if removed then
        pcall(function()
          core_input_bindings.saveBindingsToDisk(contents)
        end)
      end
    end
  end
end

local function saveBindSettings()
  local payload = {toggleControl = toggleControl, deviceName = bindDeviceName}
  local dir = SETTINGS_PATH:match("^(.*)/[^/]+$")
  if dir and FS.directoryCreate then FS:directoryCreate(dir, true) end
  if career_saveSystem and career_saveSystem.jsonWriteFileSafe then
    career_saveSystem.jsonWriteFileSafe(SETTINGS_PATH, payload, true)
  else
    jsonWriteFile(SETTINGS_PATH, payload, true)
  end
end

local function loadBindSettings()
  local raw = jsonReadFile(SETTINGS_PATH)
  if type(raw and raw.deviceName) == "string" and raw.deviceName ~= "" then
    bindDeviceName = raw.deviceName
  end
  if refreshFromLive() then return end
  local fromFile = sanitizeControl(raw and raw.toggleControl)
  toggleControl = fromFile or DEFAULT_TOGGLE_CONTROL
end

local OVERLAY_VFS = "/lua/ge/extensions/core/input/actions/rls_tester_menu.json"

local function injectTesterAction(def)
  if type(def) ~= "table" then return end
  local actions = core_input_actions.getActiveActions and core_input_actions.getActiveActions() or {}
  for name, data in pairs(def) do
    actions[name] = data
    for _, field in ipairs({"uniqueActions", "normalActions", "activeActions", "actions"}) do
      local t = core_input_actions[field]
      if type(t) == "table" then
        t[name] = data
      end
    end
  end
end

local function registerTesterAction()
  if not core_input_actions then return false end
  local def = jsonReadFile(ACTION_FILE)
  if type(def) ~= "table" then
    log("E", logTag, "Missing tester action definition at " .. tostring(ACTION_FILE))
    return false
  end

  local wrote = false
  pcall(function()
    if FS.directoryCreate then
      FS:directoryCreate("/lua/ge/extensions/core/input/actions", true)
    end
    wrote = jsonWriteFile(OVERLAY_VFS, def, true) == true
  end)
  if wrote and type(core_input_actions.onFileChanged) == "function" then
    pcall(core_input_actions.onFileChanged, OVERLAY_VFS)
  end

  injectTesterAction(def)

  local actions = core_input_actions.getActiveActions and core_input_actions.getActiveActions() or {}
  if actions[ACTION_NAME] and core_input_bindings and type(core_input_bindings.onFileChanged) == "function" then
    pcall(core_input_bindings.onFileChanged, "/settings/inputmaps/mouse.diff")
    pcall(core_input_bindings.onFileChanged, "/settings/inputmaps/keyboard.diff")
  end
  return actions[ACTION_NAME] ~= nil
end

local function applyToggleBind(deviceName)
  if not keyOk then return false end
  if not registerTesterAction() then
    log("D", logTag, "Tester input action is not registered")
    return false
  end
  local control = sanitizeControl(toggleControl) or DEFAULT_TOGGLE_CONTROL
  toggleControl = control
  if type(deviceName) == "string" and deviceName ~= "" then
    bindDeviceName = deviceName
  end
  stripActionFromAllDevices()
  local device = findDevice(bindDeviceName)
  if not device or not device.contents or type(device.contents.bindings) ~= "table" then
    log("W", logTag, "No input device to bind tester shortcut")
    return false
  end
  bindDeviceName = device.devname or bindDeviceName
  local bindings = device.contents.bindings
  local newBinding = {action = ACTION_NAME, control = control, player = 0}
  local bindingTemplate = core_input_bindings.bindingTemplate
  if type(bindingTemplate) == "table" then
    for k, v in pairs(bindingTemplate) do
      if newBinding[k] == nil then newBinding[k] = v end
    end
  end
  table.insert(bindings, newBinding)
  pcall(function()
    core_input_bindings.saveBindingsToDisk(device.contents)
  end)
  saveBindSettings()
  return true
end

local function requireCareer()
  if not (career_career and career_career.isActive and career_career.isActive()) then
    toast("error", "Start or resume a career first.")
    return false
  end
  return true
end

local function testerReason(label)
  return {label = label or "RLS tester", tags = {"tester"}, testerForce = true}
end

local function currentMoney()
  if career_modules_playerAttributes and career_modules_playerAttributes.getAttributeValue then
    return tonumber(career_modules_playerAttributes.getAttributeValue("money")) or 0
  end
  return 0
end

local function addMoney(amount)
  if not requireCareer() then return end
  if not (career_modules_playerAttributes and career_modules_playerAttributes.addAttributes) then
    toast("error", "Player attributes are not loaded.")
    return
  end
  career_modules_playerAttributes.addAttributes({money = amount}, testerReason("RLS tester money"))
  toast("info", string.format("Added $%s. Balance: $%s", tostring(amount), tostring(math.floor(currentMoney() + 0.5))))
end

local function addSkillXp(amount)
  if not requireCareer() then return end
  if not (career_modules_playerAttributes and career_modules_playerAttributes.addAttributes) then
    toast("error", "Player attributes are not loaded.")
    return
  end
  local change = {}
  local count = 0
  if career_branches and career_branches.getSortedBranches then
    for _, branch in ipairs(career_branches.getSortedBranches() or {}) do
      if branch and branch.attributeKey and (branch.isSkill or branch.isBranch) then
        local key = branch.attributeKey
        if key ~= "money" and key ~= "vouchers" then
          change[key] = (change[key] or 0) + amount
          count = count + 1
        end
      end
    end
  end
  change["careerSkills-stamina"] = change["careerSkills-stamina"] or amount
  if not change["stamina"] then
    change["stamina"] = amount
  end
  if count == 0 then
    toast("error", "No skill attributes found.")
    return
  end
  career_modules_playerAttributes.addAttributes(change, testerReason("RLS tester XP"))
  toast("info", string.format("Added %s XP to %d skill tracks.", tostring(amount), count))
end

local function fileExists(path)
  return path and FS and FS.fileExists and FS:fileExists(path)
end

local function lookupModelConfig(model, configKey)
  if not (core_vehicles and core_vehicles.getModel) then return nil end
  local modelData = core_vehicles.getModel(model)
  local configs = modelData and (modelData.configs or (modelData.model and modelData.model.configs))
  if type(configs) ~= "table" then return nil end
  local cfg = configs[configKey]
  if type(cfg) ~= "table" then
    local wanted = tostring(configKey or ""):lower()
    for key, value in pairs(configs) do
      if tostring(key):lower() == wanted then
        cfg = value
        configKey = key
        break
      end
    end
  end
  if type(cfg) ~= "table" then return nil end
  return {
    model = model,
    configKey = configKey,
    pc = cfg.pcFilename or ("/vehicles/" .. model .. "/" .. configKey .. ".pc"),
    name = cfg.Name or cfg.Configuration or configKey,
  }
end

local function configNameCandidates(config)
  local name = tostring(config or "")
  local names = {name}
  if name:find("^info_", 1) then
    names[#names + 1] = name:gsub("^info_", "")
  end
  if name == "adente_race" then
    names[#names + 1] = "ardente_race"
  end
  return names
end

local function resolvePresetConfig(preset)
  local model = preset.model
  local names = configNameCandidates(preset.config)
  for _, name in ipairs(names) do
    local found = lookupModelConfig(model, name)
    if found then return found end
    local pc = "/vehicles/" .. model .. "/" .. name .. ".pc"
    if fileExists(pc) then
      return {model = model, configKey = name, pc = pc, name = preset.label}
    end
  end
  local fallback = names[1]
  return {
    model = model,
    configKey = fallback,
    pc = "/vehicles/" .. model .. "/" .. fallback .. ".pc",
    name = preset.label,
  }
end

local function spawnPose()
  local player = getPlayerVehicle(0)
  if player then
    local pos = player:getPosition()
    local dir = player:getDirectionVector()
    return pos + dir * 8, quatFromDir(dir)
  end
  if core_camera and core_camera.getPosition then
    return core_camera.getPosition(), quat(0, 0, 1, 0)
  end
  return vec3(0, 0, 0), quat(0, 0, 1, 0)
end

local function grantSpawnedVehicle(veh)
  if not veh or not career_modules_inventory or not career_modules_inventory.addVehicle then
    return nil
  end
  local inventoryId = career_modules_inventory.addVehicle(veh:getID(), nil, {
    owned = true,
    takesNoInventorySpace = true,
  })
  if inventoryId then
    local record = career_modules_inventory.getVehicle and career_modules_inventory.getVehicle(inventoryId)
    if record then
      record.owned = true
      record.loanType = nil
    end
    extensions.hook("onVehicleAddedToInventory", {
      inventoryId = inventoryId,
      purchaseData = {insuranceId = -1},
    })
  end
  return inventoryId
end

local function spawnPreset(preset)
  if not requireCareer() then return end
  local found = resolvePresetConfig(preset)
  local pos, rot = spawnPose()
  local options = {config = found.pc, pos = pos, rot = rot, autoEnterVehicle = true}
  if sanitizeVehicleSpawnOptions then
    options = sanitizeVehicleSpawnOptions(found.model, options)
    options.config = found.pc
    options.autoEnterVehicle = true
  end
  local ok, veh = pcall(core_vehicles.spawnNewVehicle, found.model, options)
  if not ok or not veh then
    toast("error", string.format("Spawn failed for %s/%s.", tostring(found.model), tostring(found.configKey)))
    return
  end
  local inventoryId = grantSpawnedVehicle(veh)
  toast("info", string.format("Spawned %s (%s/%s)%s", found.name, found.model, found.configKey, inventoryId and (" owned #" .. tostring(inventoryId)) or " (not added to garage)"))
end

local function ownCurrentVehicle()
  if not requireCareer() then return end
  local veh = getPlayerVehicle(0)
  if not veh then
    toast("error", "You are not in a vehicle.")
    return
  end
  if gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking() then
    toast("error", "Enter a vehicle first.")
    return
  end
  local vehId = veh:getID()
  local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId and career_modules_inventory.getInventoryIdFromVehicleId(vehId)
  if inventoryId then
    local record = career_modules_inventory.getVehicle(inventoryId)
    if record then
      record.owned = true
      record.loanType = nil
    end
    toast("info", "Marked inventory vehicle #" .. tostring(inventoryId) .. " as owned.")
    return
  end
  inventoryId = grantSpawnedVehicle(veh)
  if inventoryId then
    toast("info", "Added current vehicle to ownership as #" .. tostring(inventoryId) .. ".")
  else
    toast("error", "Could not add the current vehicle to inventory.")
  end
end

local function setWeather(condition, label)
  if not requireCareer() then return end
  local weather = rawget(_G, "career_modules_dynamicWeather")
  if not (weather and weather.forceCondition) then
    toast("error", "Dynamic weather is not loaded.")
    return
  end
  if weather.forceCondition(condition) then
    if condition == "clear" then
      toast("info", "Weather set to a bright sunny noon with no clouds or fog.")
    else
      toast("info", "Weather set to " .. label .. ".")
    end
  else
    toast("error", "Could not change weather (external override?).")
  end
end

local function setTimePreset(preset)
  if not requireCareer() then return end
  local weather = rawget(_G, "career_modules_dynamicWeather")
  if not (weather and weather.setMinuteOfDay) then
    toast("error", "Dynamic weather is not loaded.")
    return
  end
  if weather.setMinuteOfDay(preset.minute, true) then
    toast("info", "Time set to " .. preset.label .. ".")
  else
    toast("error", "Could not change time of day.")
  end
end

local function openMapSwitcher()
  if not requireCareer() then return end
  if not (career_modules_switchMap and career_modules_switchMap.openForTester) then
    toast("error", "Map switcher is not loaded.")
    return
  end
  local ok, err = career_modules_switchMap.openForTester()
  if ok then
    toast("info", "Map switcher opened.")
  else
    toast("error", err or "Could not open the map switcher.")
  end
end

local function recoverAndRepair()
  if not requireCareer() then return end
  local veh = getPlayerVehicle(0)
  if not veh then
    toast("error", "You are not in a vehicle.")
    return
  end
  local vehId = veh:getID()
  local inventoryId = career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId and career_modules_inventory.getInventoryIdFromVehicleId(vehId)
  if inventoryId and career_modules_tireSystem and career_modules_tireSystem.forceFreshForVehicle then
    career_modules_tireSystem.forceFreshForVehicle(inventoryId)
  end
  if inventoryId and vehicleMaintenance and vehicleMaintenance.resetAllCategories then
    vehicleMaintenance.resetAllCategories(inventoryId)
  end
  if inventoryId and career_modules_damageManager and career_modules_damageManager.clearDamageState then
    career_modules_damageManager.clearDamageState(inventoryId)
  end
  veh:queueLuaCommand([[
    if maintenanceManager then
      maintenanceManager.debugResetCategory('engine')
      maintenanceManager.debugResetCategory('radiator')
      maintenanceManager.debugResetCategory('transmission')
    end
    if energyStorage then
      for _, storage in pairs(energyStorage.getStorages() or {}) do
        if storage.energyCapacity then storage.storedEnergy = storage.energyCapacity end
      end
    end
    extensions.load('individualRepair')
    if individualRepair then individualRepair.reset() end
    if recovery then recovery.recoverInPlace() end
    if rlsTireProvider and rlsTireProvider.applyFreshAndInflate then
      rlsTireProvider.applyFreshAndInflate()
    end
  ]])
  toast("info", "Repaired and refueled in place.")
end

local function saveCareer()
  if not requireCareer() then return end
  if career_saveSystem and career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
    toast("info", "Career save requested.")
  else
    toast("error", "Save system is not available.")
  end
end

local function skipLevelUpNotifications()
  if not requireCareer() then return end
  if guihooks and guihooks.trigger then
    guihooks.trigger("SkipCareerLevelUpCelebrations")
  end
  toast("info", "Skipped queued level-up notifications.")
end

local function toggleDayCycle()
  if not requireCareer() then return end
  local weather = rawget(_G, "career_modules_dynamicWeather")
  if not (weather and weather.getDayNightCycle and weather.toggleDayNightCycle) then
    toast("error", "Dynamic weather is not loaded.")
    return
  end
  local clock = weather.getDayNightCycle() or {}
  local nextPlay = not (clock.play == true)
  weather.toggleDayNightCycle(nextPlay)
  toast("info", nextPlay and "Day/night cycle running." or "Day/night cycle frozen.")
end

local function pushUi()
  if not guihooks or not guihooks.trigger then return end
  guihooks.trigger("RlsTesterMenu", {
    visible = menuVisible == true,
    money = currentMoney(),
    status = statusText,
    statusIsError = statusIsError,
    toggleControl = toggleControl,
    toggleLabel = formatControlLabel(toggleControl, bindDeviceName),
    deviceName = bindDeviceName,
    rebindArmed = rebindArmed == true,
  })
end

local function requireCleanupClub()
  if not requireCareer() then return nil end
  local club = rawget(_G, "gameplay_cleanupClub")
  if not club then
    toast("error", "Clean Up Club is not loaded.")
    return nil
  end
  return club
end

local function spawnCleanupVehicle()
  local club = requireCleanupClub()
  if not club or not club.debugForceSpawn then
    if club then toast("error", "Clean Up Club debug spawn is unavailable.") end
    return
  end
  local ok, result = club.debugForceSpawn(1, "vehicle_project")
  if not ok then
    toast("error", tostring(result or "Could not spawn a cleanup container."))
  end
end

local function focusCleanup()
  local club = requireCleanupClub()
  if not club or not club.debugFocusCleanup then
    if club then toast("error", "Clean Up Club debug focus is unavailable.") end
    return
  end
  local ok, result = club.debugFocusCleanup()
  if not ok then
    toast("error", tostring(result or "Could not focus a cleanup."))
  end
end

local actions = {
  sunny = function() setWeather("clear", "Sunny") end,
  rain = function() setWeather("storm", "Heavy Rain") end,
  overcast = function() setWeather("overcast", "Overcast") end,
  morning = function() setTimePreset(TIME_PRESETS[1]) end,
  noon = function() setTimePreset(TIME_PRESETS[2]) end,
  dusk = function() setTimePreset(TIME_PRESETS[3]) end,
  night = function() setTimePreset(TIME_PRESETS[4]) end,
  cycle = toggleDayCycle,
  money = function() addMoney(1000000) end,
  moneySmall = function() addMoney(10000) end,
  xp = function() addSkillXp(100000) end,
  xpSmall = function() addSkillXp(1000) end,
  skipLevelUps = skipLevelUpNotifications,
  drift = function() spawnPreset(SPAWN_PRESETS[1]) end,
  race = function() spawnPreset(SPAWN_PRESETS[2]) end,
  rally = function() spawnPreset(SPAWN_PRESETS[3]) end,
  work = function() spawnPreset(SPAWN_PRESETS[4]) end,
  own = ownCurrentVehicle,
  switcher = openMapSwitcher,
  repair = recoverAndRepair,
  save = saveCareer,
  cleanupSpawn = spawnCleanupVehicle,
  cleanupFocus = focusCleanup,
}

function M.run(actionId)
  if not refreshCreatorKey(true) then
    menuVisible = false
    return false
  end
  local fn = actions[tostring(actionId or "")]
  if not fn then
    toast("error", "Unknown tester action: " .. tostring(actionId))
    pushUi()
    return false
  end
  fn()
  pushUi()
  return true
end

function M.toggle()
  if rebindArmed then return false end
  if not refreshCreatorKey(true) then
    menuVisible = false
    return false
  end
  menuVisible = not menuVisible
  if menuVisible and not (career_career and career_career.isActive and career_career.isActive()) then
    toast("error", "Menu opened, but career is not active yet.")
  end
  refreshFromLive()
  pushUi()
  if menuVisible then
    core_jobsystem.create(function(job)
      job.sleep(0.25)
      pushUi()
    end)
  end
  return menuVisible
end

function M.beginRebind()
  if not refreshCreatorKey(true) then return false end
  rebindArmed = true
  statusText = "Press a key for the tester menu shortcut."
  statusIsError = false
  setBindingCapture(true)
  pushUi()
  return true
end

function M.cancelRebind()
  rebindArmed = false
  statusText = ""
  statusIsError = false
  setBindingCapture(false)
  pushUi()
  return true
end

function M.setToggleControl(control, deviceName)
  if not refreshCreatorKey(true) then return false end
  local sanitized = sanitizeControl(control)
  if not sanitized then
    rebindArmed = false
    toast("error", "That key cannot be used as a shortcut.")
    pushUi()
    return false
  end
  toggleControl = sanitized
  rebindArmed = false
  setBindingCapture(false)
  if not applyToggleBind(deviceName) then
    toast("error", "Could not save that shortcut on that device.")
    pushUi()
    return false
  end
  toast("info", "Tester menu shortcut saved as " .. formatControlLabel(toggleControl, bindDeviceName) .. ".")
  pushUi()
  return true
end

function M.hasCreatorKey()
  return refreshCreatorKey(false)
end

function M.ensureBound()
  if not refreshCreatorKey(true) then return false end
  loadBindSettings()
  return applyToggleBind()
end

function M.isVisible()
  return menuVisible
end

function M.onExtensionLoaded()
  loadBindSettings()
  if refreshCreatorKey(true) then
    applyToggleBind()
  end
end

function M.onWorldReadyState(state)
  if state == 2 and refreshCreatorKey(true) then
    applyToggleBind()
  end
end

function M.onCareerActivated()
  if refreshCreatorKey(true) then
    applyToggleBind()
  end
end

return M
