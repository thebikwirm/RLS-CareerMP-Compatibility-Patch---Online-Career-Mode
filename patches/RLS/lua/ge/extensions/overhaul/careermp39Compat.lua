-- RLS CareerMP compatibility bridge for BeamNG.drive 0.39.x.
--
-- RLS 2.6.x still contains calls to the pre-0.39 save-slot API. CareerMP 0.39
-- already owns the game-version mapping, so RLS should consume that mapping
-- instead of recreating or globally monkey-patching career_saveSystem.
--
-- This extension is intentionally small and read-only: it translates API names
-- and reports what it resolved.

local M = {}

local logTag = "RLSCareerMP39"

local function loaded(name)
  if type(extensions) ~= "table" then return nil end
  return rawget(extensions, name)
end

local function careerMPCompat()
  return loaded("careerMP_compat") or rawget(_G, "careerMP_compat")
end

function M.isAvailable()
  local compat = careerMPCompat()
  return compat ~= nil and type(compat.getCurrentProfile) == "function"
end

function M.getCurrentProfile()
  -- Prefer BeamNG 0.39's native API here. CareerMP-0.39's generic callPick()
  -- currently returns "fn(...), matched"; because fn(...) is not the final
  -- expression, Lua collapses its multiple returns. That turns
  -- (profileName, savePath) into (profileName, "getCurrentProfile").
  if career_saveSystem and type(career_saveSystem.getCurrentProfile) == "function" then
    return career_saveSystem.getCurrentProfile()
  end

  local compat = careerMPCompat()
  if compat and type(compat.getCurrentProfile) == "function" then
    local profile = compat.getCurrentProfile()
    return profile, nil
  end

  log("E", logTag, "No current-profile API is available")
  return nil, nil
end

function M.getAllProfiles()
  local compat = careerMPCompat()
  if compat and type(compat.getAllProfiles) == "function" then
    return compat.getAllProfiles()
  end

  if career_saveSystem and type(career_saveSystem.getAllProfiles) == "function" then
    return career_saveSystem.getAllProfiles()
  end

  log("E", logTag, "No profile-list API is available")
  return {}
end

function M.setProfile(name, specificSaveFolder)
  local compat = careerMPCompat()
  if compat and type(compat.setProfile) == "function" then
    return compat.setProfile(name, specificSaveFolder)
  end

  if career_saveSystem and type(career_saveSystem.setProfile) == "function" then
    return career_saveSystem.setProfile(name, specificSaveFolder)
  end

  log("E", logTag, "No set-profile API is available")
  return nil
end

function M.getAllSaveFolders(profile)
  local compat = careerMPCompat()
  if compat and type(compat.getAllSaveFolders) == "function" then
    return compat.getAllSaveFolders(profile)
  end

  if career_saveSystem and type(career_saveSystem.getAllSaveFolders) == "function" then
    return career_saveSystem.getAllSaveFolders(profile)
  end

  log("E", logTag, "No save-folder API is available")
  return {}
end

function M.getNewestSave(path)
  local compat = careerMPCompat()
  if compat and type(compat.getNewestSave) == "function" then
    return compat.getNewestSave(path)
  end

  if career_saveSystem and type(career_saveSystem.getNewestSave) == "function" then
    return career_saveSystem.getNewestSave(path)
  end

  log("E", logTag, "No newest-save API is available")
  return nil
end

function M.report()
  local compat = careerMPCompat()
  local profileOk = career_saveSystem and type(career_saveSystem.getCurrentProfile) == "function"
  local slotPresent = career_saveSystem and type(career_saveSystem.getCurrentSaveSlot) == "function"

  log("I", logTag,
    "save bridge: careerMP_compat=" .. tostring(compat ~= nil) ..
    " getCurrentProfile=" .. tostring(profileOk) ..
    " legacyGetCurrentSaveSlot=" .. tostring(slotPresent))

  return compat ~= nil or profileOk
end

function M.onExtensionLoaded()
  M.report()
end

function M.onInit()
  setExtensionUnloadMode(M, "manual")
end

return M
