local M = {}

M.dependencies = {'career_career', 'career_saveSystem'}

local saveDir = "/career/rls_career"
local saveFile = saveDir .. "/guide.json"
local settingsRoot = "settings/RLS/"
local globalGuideFile = settingsRoot .. "guideGlobal.json"

local SPLASH_DELAY_S = 0.5
local VETERAN_PHONE_TUTORIAL_DELAY_S = 3.0
local PHONE_OPEN_DELAY_S = 0.35
local PHONE_TUTORIAL_EVENT_DELAY_S = 0.65
-- Bump this when the phone tutorial gains steps so old global completions replay.
local PHONE_TUTORIAL_VERSION = 3

local guideShown = false
local phoneTutorialComplete = false
local phoneTutorialVersion = 0
local globalPhoneTutorialComplete = false
local globalPhoneTutorialVersion = 0
local splashVisible = false
local splashStartGeneration = 0
local pendingSplash = false
local skipDemoDirtIntro = false
local phoneTutorialStartScheduled = false
local phoneTutorialStartGeneration = 0
local phoneTutorialLaunchAttempted = false
local returnToOverhaulManagerPending = false
local startPhoneTutorialIfNeeded

local function getUiRouteName()
  if type(extensions) ~= "table" or type(extensions.ui_router) ~= "table"
      or type(extensions.ui_router.getCurrent) ~= "function" then
    return nil
  end
  local current = extensions.ui_router.getCurrent()
  if not current then
    return nil
  end
  if current.resolved and type(current.resolved.name) == "string" then
    return current.resolved.name
  end
  if current.request and type(current.request.name) == "string" then
    return current.request.name
  end
  return nil
end

local function isCareerActiveAndNotLoading()
  if not career_career or not career_career.isActive or not career_career.isActive() then
    return false
  end
  if core_gamestate and core_gamestate.getLoadingStatus then
    if core_gamestate.getLoadingStatus("careerLoading") then return false end
    if core_gamestate.getLoadingStatus("careerActivate") then return false end
  end
  return true
end

local function isPlayRoute()
  local routeName = getUiRouteName()
  return routeName == "play"
end

local function isCareerUiReady()
  if not isCareerActiveAndNotLoading() then
    return false
  end
  if gameplay_phone and gameplay_phone.isPhoneUiAllowed and not gameplay_phone.isPhoneUiAllowed() then
    return false
  end
  return isPlayRoute()
end

local function isPhoneTutorialUiReady()
  if not isCareerActiveAndNotLoading() then
    return false
  end
  if gameplay_phone and gameplay_phone.isPhoneUiAllowed and not gameplay_phone.isPhoneUiAllowed() then
    return false
  end
  local routeName = getUiRouteName()
  return type(routeName) == "string" and (routeName:find("^phone%-") == 1 or routeName == "car-meets-phone")
end

local function isWelcomeSplashReady()
  if not isCareerActiveAndNotLoading() then
    return false
  end
  local routeName = getUiRouteName()
  if type(routeName) == "string" then
    if routeName == "menu" or routeName:find("^menu%.") == 1 then
      return false
    end
    if routeName:find("^career%.profiles") == 1 then
      return false
    end
  end
  return true
end

local function cancelPhoneTutorialStart()
  phoneTutorialStartScheduled = false
  phoneTutorialStartGeneration = phoneTutorialStartGeneration + 1
end

-- Stock fade tutorials (cargo / delivery help, etc.) already use
-- career/tutorialData.json, but that is per-save only and easy to lose.
-- Mirror the phone-tutorial pattern: remember them in RLS guide + global
-- settings so they stay suppressed after the first time.
local STOCK_INTRO_TIP_IDS = {
  "delivery/cargoScreen",
  "delivery/parcelDeliveryHelp",
  "delivery/vehicleDeliveryHelp",
  "delivery/trailerDeliveryHelp",
  "delivery/materialsDeliveryHelp",
  "delivery/loanerHelp",
  "delivery/cargoDelivered",
  "delivery/postDeliveryTaxi",
  "delivery/intro",
}

local STOCK_INTRO_TIP_HOOKS = {
  onEnterCargoOverviewScreen = "delivery/cargoScreen",
}

local seenStockIntroTips = {}
local globalSeenStockIntroTips = {}

local INTRO_SKIP_FIELDS = {
  demo_dirt = "skipDemoDirtIntro",
}

local function copySeenTipMap(source)
  local out = {}
  if type(source) ~= "table" then
    return out
  end
  for _, id in ipairs(STOCK_INTRO_TIP_IDS) do
    if source[id] == true then
      out[id] = true
    end
  end
  -- Also accept any extra string keys already stored.
  for key, value in pairs(source) do
    if type(key) == "string" and value == true then
      out[key] = true
    end
  end
  return out
end

local function mergeSeenTipMaps(...)
  local out = {}
  for i = 1, select("#", ...) do
    local map = select(i, ...)
    if type(map) == "table" then
      for key, value in pairs(map) do
        if value == true then
          out[key] = true
        end
      end
    end
  end
  return out
end

local function isTrackedStockIntroTip(id)
  if type(id) ~= "string" or id == "" then
    return false
  end
  for _, tipId in ipairs(STOCK_INTRO_TIP_IDS) do
    if tipId == id then
      return true
    end
  end
  return false
end

local function ensureGlobalSettingsDir()
  if not FS:directoryExists(settingsRoot) then
    FS:directoryCreate(settingsRoot, true)
  end
end

local function loadGlobalGuideData()
  ensureGlobalSettingsDir()
  local data = jsonReadFile(globalGuideFile) or {}
  globalPhoneTutorialComplete = data.phoneTutorialComplete == true
  globalPhoneTutorialVersion = tonumber(data.phoneTutorialVersion) or 0
  globalSeenStockIntroTips = copySeenTipMap(data.seenStockIntroTips)
end

local function writeGlobalGuideFile(data)
  if career_saveSystem and career_saveSystem.jsonWriteFileSafe then
    if career_saveSystem.jsonWriteFileSafe(globalGuideFile, data, true) then
      return true
    end
  end
  if jsonWriteFileSafe and jsonWriteFileSafe(globalGuideFile, data, true) then
    return true
  end
  if jsonWriteFile and jsonWriteFile(globalGuideFile, data, true) then
    return true
  end
  return false
end

local function saveGlobalGuideData()
  ensureGlobalSettingsDir()
  local data = {
    phoneTutorialComplete = globalPhoneTutorialComplete == true,
    phoneTutorialVersion = tonumber(globalPhoneTutorialVersion) or 0,
    seenStockIntroTips = copySeenTipMap(globalSeenStockIntroTips),
  }
  if writeGlobalGuideFile(data) then
    return true
  end
  log("E", "guide", "failed to write global guide data: " .. tostring(globalGuideFile))
  return false
end

local function tutorialVersionIsCurrent(version)
  return (tonumber(version) or 0) >= PHONE_TUTORIAL_VERSION
end

local function promotePerSaveTutorialToGlobal()
  if not tutorialVersionIsCurrent(phoneTutorialVersion) then
    return
  end
  if globalPhoneTutorialComplete and tutorialVersionIsCurrent(globalPhoneTutorialVersion) then
    return
  end
  globalPhoneTutorialComplete = true
  globalPhoneTutorialVersion = PHONE_TUTORIAL_VERSION
  saveGlobalGuideData()
end

local function applyStockIntroTipsToTutorialPopups()
  local tutorialPopups = rawget(_G, "career_modules_tutorialPopups")
  if not (tutorialPopups and tutorialPopups.setTutorialFlag) then
    return
  end
  local merged = mergeSeenTipMaps(seenStockIntroTips, globalSeenStockIntroTips)
  for id, seen in pairs(merged) do
    if seen == true then
      tutorialPopups.setTutorialFlag(id, true)
    end
  end
end

local function syncSeenTipsFromStockTutorialFlags()
  local tutorialPopups = rawget(_G, "career_modules_tutorialPopups")
  if not (tutorialPopups and tutorialPopups.getTutorialFlag) then
    return false
  end
  local changed = false
  for _, id in ipairs(STOCK_INTRO_TIP_IDS) do
    if tutorialPopups.getTutorialFlag(id) and not seenStockIntroTips[id] then
      seenStockIntroTips[id] = true
      changed = true
    end
    if tutorialPopups.getTutorialFlag(id) and not globalSeenStockIntroTips[id] then
      globalSeenStockIntroTips[id] = true
      changed = true
    end
  end
  return changed
end

local function isPhoneTutorialCompleteGlobally()
  return globalPhoneTutorialComplete == true and tutorialVersionIsCurrent(globalPhoneTutorialVersion)
end

local function isForcePhoneTutorial()
  local settings = rawget(_G, "overhaul_settings")
  if not settings or not settings.getSetting then
    return false
  end
  return settings.getSetting("forcePhoneTutorial") == true
end

local function ensureSaveDir(currentSavePath)
  local dirPath = currentSavePath .. saveDir
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
end

local function readSkipFlagFromData(data, eventKey)
  if type(data) ~= "table" or not eventKey or eventKey == "" then
    return false
  end
  local field = INTRO_SKIP_FIELDS[eventKey]
  if field and data[field] == true then
    return true
  end
  if type(data.demoIntroSkip) == "table" and data.demoIntroSkip[eventKey] == true then
    return true
  end
  return false
end

local function resetPerSaveGuideState()
  guideShown = false
  phoneTutorialComplete = false
  phoneTutorialVersion = 0
  skipDemoDirtIntro = false
  seenStockIntroTips = {}
end

local function loadGuideData()
  resetPerSaveGuideState()
  if not career_career.isActive() then
    return
  end

  local _, currentSavePath = career_saveSystem.getCurrentProfile()
  if not currentSavePath then
    return
  end

  local data = jsonReadFile(currentSavePath .. saveFile) or {}
  guideShown = data.guideShown == true
  phoneTutorialComplete = data.phoneTutorialComplete == true
  phoneTutorialVersion = tonumber(data.phoneTutorialVersion) or 0
  if phoneTutorialComplete and not tutorialVersionIsCurrent(phoneTutorialVersion) then
    phoneTutorialComplete = false
  end
  skipDemoDirtIntro = readSkipFlagFromData(data, "demo_dirt")
  seenStockIntroTips = copySeenTipMap(data.seenStockIntroTips)
  if phoneTutorialComplete then
    promotePerSaveTutorialToGlobal()
  end
end

local function saveGuideData(currentSavePath)
  if not currentSavePath then
    local _, path = career_saveSystem.getCurrentProfile()
    currentSavePath = path
  end

  if not currentSavePath then
    return false
  end

  local existing = jsonReadFile(currentSavePath .. saveFile)
  if skipDemoDirtIntro ~= true and readSkipFlagFromData(existing, "demo_dirt") then
    skipDemoDirtIntro = true
  end

  ensureSaveDir(currentSavePath)

  local data = {
    guideShown = guideShown,
    phoneTutorialComplete = phoneTutorialComplete == true,
    phoneTutorialVersion = tonumber(phoneTutorialVersion) or 0,
    skipDemoDirtIntro = skipDemoDirtIntro == true,
    seenStockIntroTips = copySeenTipMap(mergeSeenTipMaps(seenStockIntroTips, globalSeenStockIntroTips)),
  }

  if career_saveSystem.jsonWriteFileSafe(currentSavePath .. saveFile, data, true) then
    return true
  end
  log("E", "guide", "failed to write guide save: " .. tostring(currentSavePath .. saveFile))
  return false
end

local function markStockIntroTipSeen(id)
  if not isTrackedStockIntroTip(id) then
    return false
  end
  local changed = false
  if not seenStockIntroTips[id] then
    seenStockIntroTips[id] = true
    changed = true
  end
  if not globalSeenStockIntroTips[id] then
    globalSeenStockIntroTips[id] = true
    changed = true
  end

  local tutorialPopups = rawget(_G, "career_modules_tutorialPopups")
  if tutorialPopups and tutorialPopups.setTutorialFlag then
    tutorialPopups.setTutorialFlag(id, true)
  end

  if not changed then
    return false
  end

  saveGlobalGuideData()
  local _, currentSavePath = career_saveSystem.getCurrentProfile()
  if currentSavePath then
    saveGuideData(currentSavePath)
  end
  return true
end

local function refreshStockIntroTipSuppression()
  loadGlobalGuideData()
  loadGuideData()
  if syncSeenTipsFromStockTutorialFlags() then
    saveGlobalGuideData()
    local _, currentSavePath = career_saveSystem.getCurrentProfile()
    if currentSavePath then
      saveGuideData(currentSavePath)
    end
  end
  applyStockIntroTipsToTutorialPopups()
end

local function checkGuideShown()
  return guideShown
end

local function markGuideShown()
  guideShown = true
  local _, currentSavePath = career_saveSystem.getCurrentProfile()
  if currentSavePath then
    saveGuideData(currentSavePath)
  end
end

local function shouldSkipDemoIntro(eventKey)
  if not eventKey or eventKey == "" then
    return false
  end
  if not INTRO_SKIP_FIELDS[eventKey] then
    return false
  end
  local _, currentSavePath = career_saveSystem.getCurrentProfile()
  if not currentSavePath then
    return false
  end
  return readSkipFlagFromData(jsonReadFile(currentSavePath .. saveFile), eventKey)
end

-- Writes guide.json into one autosave folder; returns true on success.
local function writeSkipToSlot(basePath, field)
  local dirPath = basePath .. saveDir
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
  local data = jsonReadFile(basePath .. saveFile) or {}
  data[field] = true
  if data.guideShown == nil then
    data.guideShown = guideShown == true
  end
  data.demoIntroSkip = nil
  return career_saveSystem.jsonWriteFileSafe(basePath .. saveFile, data, true) == true
end

-- BeamNG rotates autosave slots and loads the newest on restart, so the skip
-- flag must land in every autosave of the current save, not just the live one.
local function markDemoIntroSkipped(eventKey)
  if not eventKey or eventKey == "" then
    return false
  end
  local field = INTRO_SKIP_FIELDS[eventKey]
  if not field then
    return false
  end

  if eventKey == "demo_dirt" then
    skipDemoDirtIntro = true
  end

  local wroteAny = false
  local slotName = career_saveSystem.getCurrentProfile()
  if slotName and career_saveSystem.getSaveRootDirectory and career_saveSystem.getAllAutosaves then
    local saveRoot = career_saveSystem.getSaveRootDirectory()
    local autosaves = career_saveSystem.getAllAutosaves(slotName) or {}
    for _, info in ipairs(autosaves) do
      if info and info.name then
        if writeSkipToSlot(saveRoot .. slotName .. "/" .. info.name, field) then
          wroteAny = true
        end
      end
    end
  end

  if not wroteAny then
    local _, currentSavePath = career_saveSystem.getCurrentProfile()
    if currentSavePath then
      wroteAny = writeSkipToSlot(currentSavePath, field)
    end
  end

  if wroteAny then
    print("[guide] marked demo intro skipped (all autosaves): " .. tostring(eventKey))
    log("I", "guide", "marked demo intro skipped: " .. tostring(eventKey))
    return true
  end
  print("[guide] failed to mark demo intro skipped: " .. tostring(eventKey))
  log("E", "guide", "failed to mark demo intro skipped: " .. tostring(eventKey))
  return false
end

local function showSplash()
  splashVisible = true
  guihooks.trigger('GuideShowSplash')
end

M.resyncSplash = function()
  if splashVisible then
    guihooks.trigger('GuideShowSplash')
  end
end

local function onSaveCurrentProfile(currentSavePath)
  if not currentSavePath then
    return
  end
  local success, err = pcall(function()
    saveGuideData(currentSavePath)
  end)
  if not success then
    log("E", "guide", "onSaveCurrentProfile failed: " .. tostring(err))
  end
end

M.onCareerActivated = function()
  cancelPhoneTutorialStart()
  phoneTutorialLaunchAttempted = false
  refreshStockIntroTipSuppression()
end

M.onCareerModulesActivated = function()
  cancelPhoneTutorialStart()
  phoneTutorialLaunchAttempted = false
  refreshStockIntroTipSuppression()
end

M.onCareerDeactivated = function()
  cancelPhoneTutorialStart()
  splashStartGeneration = splashStartGeneration + 1
  pendingSplash = false
  if splashVisible then
    splashVisible = false
    guihooks.trigger('GuideHideSplash')
  end
end

M.onCareerDeactivatedWhileLevelLoaded = M.onCareerDeactivated

M.showSplashIfNeeded = function()
  refreshStockIntroTipSuppression()

  if checkGuideShown() then
    pendingSplash = false
    startPhoneTutorialIfNeeded({ initialDelay = VETERAN_PHONE_TUTORIAL_DELAY_S })
    return
  end

  pendingSplash = true
  splashStartGeneration = splashStartGeneration + 1
  local startGeneration = splashStartGeneration

  core_jobsystem.create(function(job)
    job.sleep(SPLASH_DELAY_S)
    local waited = 0
    while startGeneration == splashStartGeneration and not isWelcomeSplashReady() and waited < 8 do
      job.sleep(0.25)
      waited = waited + 0.25
    end
    if startGeneration ~= splashStartGeneration then
      return
    end
    if checkGuideShown() then
      pendingSplash = false
      return
    end
    if not isWelcomeSplashReady() then
      log("W", "guide", "Welcome splash waiting; career UI not ready yet")
      return
    end
    pendingSplash = false
    showSplash()
  end)
end

M.onWorldReadyState = function(state)
  if state ~= 2 then
    return
  end
  if pendingSplash and not splashVisible and not checkGuideShown() then
    M.showSplashIfNeeded()
  end
end

local function returnToOverhaulManagerIfNeeded()
  if not returnToOverhaulManagerPending then
    return
  end
  returnToOverhaulManagerPending = false
  if gameplay_phone and gameplay_phone.markClosed then
    gameplay_phone.markClosed()
  end
  extensions.ui_router.navigate('menu.overhaulManager')
end

M.markPhoneTutorialComplete = function()
  cancelPhoneTutorialStart()
  if isForcePhoneTutorial() then
    returnToOverhaulManagerIfNeeded()
    return true
  end
  phoneTutorialComplete = true
  phoneTutorialVersion = PHONE_TUTORIAL_VERSION
  globalPhoneTutorialComplete = true
  globalPhoneTutorialVersion = PHONE_TUTORIAL_VERSION
  saveGlobalGuideData()
  local _, currentSavePath = career_saveSystem.getCurrentProfile()
  local saved
  if currentSavePath then
    saved = saveGuideData(currentSavePath)
  else
    saved = saveGlobalGuideData()
  end
  returnToOverhaulManagerIfNeeded()
  return saved
end

M.isPhoneTutorialComplete = function()
  loadGlobalGuideData()
  return isPhoneTutorialCompleteGlobally()
end

local function formatControlName(control, deviceName)
  if not control or control == "" then
    return "Not bound"
  end

  control = tostring(control)

  if deviceName and deviceName:find("mouse") then
    local btnNum = tonumber(control:match("button(%d+)"))
    if btnNum then
      if btnNum == 0 then return "Mouse Left"
      elseif btnNum == 1 then return "Mouse Right"
      elseif btnNum == 2 then return "Mouse Middle"
      else return "Mouse Button " .. (btnNum + 1) end
    end
    return "Mouse " .. control
  end

  local symbolMap = {
    backslash = "\\", slash = "/", comma = ",", period = ".",
    semicolon = ";", apostrophe = "'", grave = "`", minus = "-",
    equals = "=", leftbracket = "[", rightbracket = "]"
  }
  if symbolMap[control] then
    return symbolMap[control]
  end
  if control:len() == 1 then
    return control:upper()
  elseif control:match("^f%d+$") then
    return control:upper()
  elseif control == "space" then
    return "Space"
  elseif control == "enter" then
    return "Enter"
  elseif control == "tab" then
    return "Tab"
  elseif control:find("arrow") then
    local direction = control:gsub("arrow", "")
    if direction == "left" then return "Arrow Left"
    elseif direction == "right" then return "Arrow Right"
    elseif direction == "up" then return "Arrow Up"
    elseif direction == "down" then return "Arrow Down"
    else return "Arrow " .. direction:gsub("^%l", string.upper) end
  end

  return control:gsub("^%l", string.upper):gsub("_", " ")
end

local function getPhoneBinding()
  if not core_input_bindings then
    return {binding = "Not bound"}
  end

  if core_input_bindings.notifyUI then
    pcall(function() core_input_bindings.notifyUI("guide refresh") end)
  end

  if core_input_bindings.bindings then
    for _, device in ipairs(core_input_bindings.bindings) do
      if device.contents and device.contents.bindings and type(device.contents.bindings) == "table" then
        for _, b in ipairs(device.contents.bindings) do
          if b.action == "openPhone" and b.control and b.control ~= "" then
            return {binding = formatControlName(b.control, device.devname)}
          end
        end
      end
    end
  end

  return {binding = "Not bound"}
end

startPhoneTutorialIfNeeded = function(opts)
  opts = opts or {}
  loadGlobalGuideData()
  loadGuideData()

  local forceTutorial = isForcePhoneTutorial() or opts.force == true
  if isPhoneTutorialCompleteGlobally() and not forceTutorial then
    return
  end
  -- One auto-launch attempt per session. Failed opens must not retry later mid-gameplay.
  if phoneTutorialLaunchAttempted and not forceTutorial then
    return
  end
  if phoneTutorialStartScheduled then
    return
  end

  phoneTutorialStartScheduled = true
  phoneTutorialStartGeneration = phoneTutorialStartGeneration + 1
  local startGeneration = phoneTutorialStartGeneration
  local initialDelay = tonumber(opts.initialDelay) or PHONE_OPEN_DELAY_S

  core_jobsystem.create(function(job)
    job.sleep(initialDelay)

    while startGeneration == phoneTutorialStartGeneration and not isCareerUiReady() do
      job.sleep(0.25)
    end

    if startGeneration ~= phoneTutorialStartGeneration then
      return
    end
    if isPhoneTutorialCompleteGlobally() and not (isForcePhoneTutorial() or forceTutorial) then
      phoneTutorialStartScheduled = false
      return
    end
    if not isCareerUiReady() then
      phoneTutorialStartScheduled = false
      log("W", "guide", "Skipped phone tutorial start; career UI was not ready")
      return
    end
    if not (gameplay_phone and gameplay_phone.openForTutorial and gameplay_phone.openForTutorial()) then
      phoneTutorialStartScheduled = false
      log("W", "guide", "Skipped phone tutorial start; phone UI refused to open")
      return
    end
    if ui_phone_layout and ui_phone_layout.ensureEmploymentAppPlaced then
      ui_phone_layout.ensureEmploymentAppPlaced()
    end
    job.sleep(PHONE_TUTORIAL_EVENT_DELAY_S)
    if startGeneration ~= phoneTutorialStartGeneration then
      if gameplay_phone and gameplay_phone.closePhone then
        gameplay_phone.closePhone()
      end
      return
    end
    if isPhoneTutorialCompleteGlobally() and not (isForcePhoneTutorial() or forceTutorial) then
      phoneTutorialStartScheduled = false
      if gameplay_phone and gameplay_phone.closePhone then
        gameplay_phone.closePhone()
      end
      return
    end
    local waited = 0
    while startGeneration == phoneTutorialStartGeneration and not isPhoneTutorialUiReady() and waited < 8 do
      job.sleep(0.25)
      waited = waited + 0.25
    end
    if startGeneration ~= phoneTutorialStartGeneration then
      if gameplay_phone and gameplay_phone.closePhone then
        gameplay_phone.closePhone()
      end
      return
    end
    if not isPhoneTutorialUiReady() then
      phoneTutorialStartScheduled = false
      if gameplay_phone and gameplay_phone.closePhone then
        gameplay_phone.closePhone()
      end
      return
    end
    phoneTutorialLaunchAttempted = true
    local bindingInfo = getPhoneBinding()
    guihooks.trigger('PhoneTutorialStart', {
      binding = bindingInfo and bindingInfo.binding or 'Not bound',
    })
    phoneTutorialStartScheduled = false
  end)
end

M.forceStartPhoneTutorial = function()
  local em = rawget(_G, "overhaul_extensionManager")
  if not (em and em.isDevKeyValid and em.isDevKeyValid()) then
    return false
  end
  cancelPhoneTutorialStart()
  phoneTutorialLaunchAttempted = false
  returnToOverhaulManagerPending = true
  startPhoneTutorialIfNeeded({
    initialDelay = PHONE_OPEN_DELAY_S,
    force = true,
  })
  return true
end

M.cancelPhoneTutorialStart = cancelPhoneTutorialStart

M.onContinue = function()
  if splashVisible then
    splashVisible = false
    markGuideShown()
    guihooks.trigger('GuideHideSplash')
    startPhoneTutorialIfNeeded()
  end
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
    local input = rawget(_G, "Input") or rawget(_G, "WinInput")
    if input and input.setForwardRawEvents then
      input.setForwardRawEvents(enabled == true)
    end
  end)
end

local function findBindingDevice(deviceName)
  if not core_input_bindings or type(core_input_bindings.bindings) ~= "table" then
    return nil
  end
  deviceName = tostring(deviceName or "keyboard0")
  local fallback = nil
  local wantKeyboard = deviceName:find("keyboard", 1, true) ~= nil
  local wantMouse = deviceName:find("mouse", 1, true) ~= nil
  for _, device in ipairs(core_input_bindings.bindings) do
    local name = tostring(device and device.devname or "")
    if name == deviceName then
      return device
    end
    if not fallback and device and device.contents then
      if wantKeyboard and name:find("keyboard", 1, true) then
        fallback = device
      elseif wantMouse and name:find("mouse", 1, true) then
        fallback = device
      end
    end
  end
  return fallback
end

local function setPhoneBinding(controlString, deviceName)
  if not controlString or controlString == "" then
    return {success = false, binding = "Not bound"}
  end

  local activeActions = core_input_actions and core_input_actions.getActiveActions()
  if not activeActions or not activeActions.openPhone then
    if overhaul_extensionManager and overhaul_extensionManager.ensureInputActionsRegistered then
      overhaul_extensionManager.ensureInputActionsRegistered()
      activeActions = core_input_actions and core_input_actions.getActiveActions()
    end
  end
  if not activeActions or not activeActions.openPhone then
    log("E", "guide", "Cannot bind phone because the openPhone input action is unavailable")
    return {success = false, binding = "Not bound"}
  end

  if not deviceName or deviceName == "" then
    deviceName = "keyboard0"
  end

  local targetDevice = findBindingDevice(deviceName)
  if not targetDevice or not targetDevice.contents then
    log("E", "guide", "Could not find device: " .. tostring(deviceName))
    return {success = false, binding = "Not bound"}
  end

  local deviceContents = targetDevice.contents
  if type(deviceContents.bindings) ~= "table" then
    deviceContents.bindings = {}
  end

  local bindings = deviceContents.bindings
  for i = #bindings, 1, -1 do
    if bindings[i].action == "openPhone" then
      table.remove(bindings, i)
    end
  end

  local newBinding = {
    action = "openPhone",
    control = controlString,
    player = 0,
  }
  local bindingTemplate = core_input_bindings.bindingTemplate
  if type(bindingTemplate) == "table" then
    for k, v in pairs(bindingTemplate) do
      if newBinding[k] == nil then
        newBinding[k] = v
      end
    end
  end
  table.insert(bindings, newBinding)

  local ok = pcall(function()
    core_input_bindings.saveBindingsToDisk(deviceContents)
  end)

  if not ok then
    log("E", "guide", "Failed to save phone binding to disk")
  end

  local bindingName = formatControlName(controlString, targetDevice.devname or deviceName)
  return {success = ok, binding = bindingName}
end

M.beginPhoneRebind = function()
  if overhaul_extensionManager and overhaul_extensionManager.ensureInputActionsRegistered then
    overhaul_extensionManager.ensureInputActionsRegistered()
  end
  setBindingCapture(true)
  return true
end

M.endPhoneRebind = function()
  setBindingCapture(false)
  return true
end

M.getPhoneBinding = getPhoneBinding
M.setPhoneBinding = setPhoneBinding
M.onRecordingActionDown = function() end
M.shouldSkipDemoIntro = shouldSkipDemoIntro
M.markDemoIntroSkipped = markDemoIntroSkipped
M.markStockIntroTipSeen = markStockIntroTipSeen

-- After stock shows/closes a tip, mirror into RLS guide + global so new saves skip it.
M.onIntroPopupCareerClosed = function(id)
  markStockIntroTipSeen(id)
end

for hookName, tipId in pairs(STOCK_INTRO_TIP_HOOKS) do
  M[hookName] = function()
    -- Wait a tick so stock tutorialPopups can open + set its own flag first.
    -- Marking immediately can race and suppress the first-ever show.
    if not core_jobsystem or not core_jobsystem.create then
      markStockIntroTipSeen(tipId)
      return
    end
    core_jobsystem.create(function(job)
      job.sleep(0.15)
      local tutorialPopups = rawget(_G, "career_modules_tutorialPopups")
      if tutorialPopups and tutorialPopups.getTutorialFlag and tutorialPopups.getTutorialFlag(tipId) then
        markStockIntroTipSeen(tipId)
      end
    end)
  end
end

M.onSaveCurrentProfile = onSaveCurrentProfile

return M
