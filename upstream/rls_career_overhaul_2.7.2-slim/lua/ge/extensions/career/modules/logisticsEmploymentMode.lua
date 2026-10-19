local M = {}

M.dependencies = {'career_career', 'career_saveSystem'}

local SAVE_FILE = "logisticsEmploymentMode.json"

local apprenticeship = false
local choiceLocked = false
local saveData = {}

local function getCurrentSavePath()
  local _, savePath = career_saveSystem.getCurrentProfile()
  return savePath
end

local function getSaveFilePath(savePath)
  return savePath .. "/career/rls_career/" .. SAVE_FILE
end

local function ensureSaveDirectory(savePath)
  local dirPath = savePath .. "/career/rls_career"
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
end

local function nowSim()
  if career_modules_delivery_general and career_modules_delivery_general.time then
    return career_modules_delivery_general.time()
  end
  return os.time()
end

local function readSaveFile(savePath)
  if not savePath then return nil end
  local data = jsonReadFile(getSaveFilePath(savePath))
  if type(data) ~= "table" or data.apprenticeship == nil then
    return nil
  end
  return data
end

local function writeSaveFile(savePath, enabled, source)
  if not savePath then return false end
  ensureSaveDirectory(savePath)
  local payload = {
    apprenticeship = enabled == true,
    chosenAt = nowSim(),
    source = source or "profile",
  }
  local ok = career_saveSystem.jsonWriteFileSafe(getSaveFilePath(savePath), payload, true) == true
  if ok then
    saveData = payload
    apprenticeship = payload.apprenticeship
    choiceLocked = true
  end
  return ok
end

local function applyState(data)
  if type(data) ~= "table" or data.apprenticeship == nil then
    apprenticeship = false
    choiceLocked = false
    saveData = {}
    return
  end
  saveData = data
  apprenticeship = data.apprenticeship == true
  choiceLocked = true
end

local function resolveSaveFolderPath(profileName, saveFolderName)
  if not profileName or profileName == "" then return nil, nil end
  local root = career_saveSystem.getSaveRootDirectory()
  local slotPath = root .. profileName
  if saveFolderName and saveFolderName ~= "" then
    local savePath = slotPath .. "/" .. saveFolderName
    if FS:fileExists(savePath .. "/info.json") then
      return savePath, saveFolderName
    end
    return nil, nil
  end
  local folders = career_saveSystem.getAllSaveFolders and career_saveSystem.getAllSaveFolders(profileName) or {}
  local bestPath, bestFolder, bestDate
  for _, data in ipairs(folders) do
    local folderName = data and data.name
    if folderName and folderName ~= "" then
      local savePath = slotPath .. "/" .. folderName
      local date = tostring(data.date or "0")
      if not bestDate or date > bestDate then
        bestDate = date
        bestPath = savePath
        bestFolder = folderName
      end
    end
  end
  return bestPath, bestFolder
end

local function loadPreferenceData()
  if career_career then career_career.pendingEmploymentApprenticeship = nil end
  local savePath = getCurrentSavePath()
  if not savePath then
    applyState(nil)
    return
  end

  local loaded = readSaveFile(savePath)
  if loaded and loaded.apprenticeship == true then
    applyState(loaded)
    return
  end

  -- Employment is no longer optional; migrate retired off/unset preferences.
  applyState({apprenticeship = true, chosenAt = nowSim(), source = "employmentAlwaysEnabled"})
  if not writeSaveFile(savePath, true, saveData.source) then
    log("W", "logisticsEmploymentMode", "Could not persist employment migration; will retry on save.")
  end
end

local function onSaveCurrentProfile(currentSavePath)
  if not choiceLocked or not currentSavePath then return end
  writeSaveFile(currentSavePath, apprenticeship, saveData.source or "profile")
end

local function onCareerActivated()
  if not career_career or not career_career.isActive() then return end
  loadPreferenceData()
end

local function onCareerActive(active)
  if not active then
    applyState(nil)
    return false
  end
  loadPreferenceData()
end

M.writeApprenticeshipToSave = function(savePath, enabled, source)
  return writeSaveFile(savePath, true, source)
end

M.getEmploymentModePreflight = function(profileName, saveFolderName)
  local savePath, folder = resolveSaveFolderPath(profileName, saveFolderName)
  if not savePath then
    return {needsChoice = false, profile = profileName, saveFolder = saveFolderName}
  end
  return {
    needsChoice = false,
    profile = profileName,
    saveFolder = folder or saveFolderName,
  }
end

M.isApprenticeshipEnabled = function()
  return choiceLocked and apprenticeship == true
end

M.isLegacyFreelance = function()
  return choiceLocked and apprenticeship ~= true
end

M.hasChosen = function()
  return choiceLocked == true
end

M.getSaveSnapshot = function()
  return {
    apprenticeship = apprenticeship == true,
    chosen = choiceLocked == true,
  }
end

M.onCareerActivated = onCareerActivated
M.onCareerActive = onCareerActive
M.onSaveCurrentProfile = onSaveCurrentProfile

return M
