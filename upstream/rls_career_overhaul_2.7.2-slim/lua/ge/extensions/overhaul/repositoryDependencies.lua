local M = {}

local logTag = "rlsRepositoryDependencies"
local retryInterval = 1
local retryTimeout = 30

local dependencies = {
  {
    repoId = "M3KGZF2SN",
    modName = "yb_pro_pull_sled",
    title = "Youngblood Pro Pulling Sled Trailer",
  },
}

local runtimeState = {
  resolved = {},
  subscriptionRequested = {},
}
local retryElapsed = 0
local totalWait = 0
local waitingForServices = false

local function writeLog(logger, level, message)
  if type(logger) == "function" then
    pcall(logger, level, logTag, message)
  end
end

local function normalizeId(value)
  if value == nil then return nil end
  return string.upper(tostring(value))
end

local function getModRepoId(mod)
  if type(mod) ~= "table" then return nil end
  if mod.modID ~= nil then return mod.modID end
  if mod.tagid ~= nil then return mod.tagid end
  if type(mod.modData) == "table" then
    return mod.modData.tagid or mod.modData.modID
  end
  return nil
end

local function isModActive(mod)
  if type(mod) ~= "table" then return false end
  if mod.active ~= nil then return mod.active == true end
  if type(mod.modData) == "table" and mod.modData.active ~= nil then
    return mod.modData.active == true
  end
  return false
end

local function findInstalledMod(mods, dependency)
  if type(mods[dependency.modName]) == "table" then
    return dependency.modName, mods[dependency.modName]
  end

  local wantedId = normalizeId(dependency.repoId)
  for installedName, mod in pairs(mods) do
    if normalizeId(getModRepoId(mod)) == wantedId then
      return installedName, mod
    end
  end

  return nil, nil
end

local function defaultServices()
  return {
    modManager = rawget(_G, "core_modmanager"),
    repository = rawget(_G, "core_repository"),
    loadRepository = function()
      local setUnloadMode = rawget(_G, "setExtensionUnloadMode")
      if type(setUnloadMode) == "function" then
        setUnloadMode("core_repository", "manual")
      end

      local extensionSystem = rawget(_G, "extensions")
      if type(extensionSystem) == "table" and type(extensionSystem.load) == "function" then
        extensionSystem.load("core_repository")
      end
      return rawget(_G, "core_repository")
    end,
    logger = rawget(_G, "log"),
  }
end

-- This function is public so the dependency behavior can be tested without
-- starting BeamNG or changing the player's installed mods.
function M.ensureRepositoryMod(dependency, services, state)
  services = services or defaultServices()
  state = state or runtimeState
  state.resolved = state.resolved or {}
  state.subscriptionRequested = state.subscriptionRequested or {}

  local repoId = dependency.repoId
  local logger = services.logger
  if state.resolved[repoId] then
    return {ready = true, action = "resolved"}
  end

  local manager = services.modManager
  if type(manager) ~= "table" or type(manager.getMods) ~= "function" then
    return {ready = false, retry = true, reason = "modManagerUnavailable"}
  end

  if type(manager.isReady) == "function" then
    local readyOk, managerReady = pcall(manager.isReady)
    if not readyOk or managerReady == false then
      return {ready = false, retry = true, reason = "modManagerNotReady"}
    end
  end

  local modsOk, mods = pcall(manager.getMods)
  if not modsOk or type(mods) ~= "table" then
    return {ready = false, retry = true, reason = "modListUnavailable"}
  end

  local installedName, installedMod = findInstalledMod(mods, dependency)
  if installedMod then
    if isModActive(installedMod) then
      state.resolved[repoId] = true
      writeLog(logger, "I", dependency.title .. " is already installed and active")
      return {ready = true, action = "active", modName = installedName}
    end

    local activateOk = false
    local activateResult
    if type(manager.activateMod) == "function" and installedName ~= nil then
      activateOk, activateResult = pcall(manager.activateMod, installedName)
    elseif type(manager.activateModId) == "function" then
      activateOk, activateResult = pcall(manager.activateModId, repoId)
    else
      return {ready = false, retry = true, reason = "activationUnavailable"}
    end

    if not activateOk or activateResult == false then
      local reason = activateOk and "mod manager rejected the request" or tostring(activateResult)
      writeLog(logger, "E", "Could not activate " .. dependency.title .. ": " .. reason)
      return {ready = false, retry = true, reason = "activationFailed"}
    end

    state.resolved[repoId] = true
    writeLog(logger, "I", "Activated required repository mod: " .. dependency.title)
    return {ready = true, action = "activated", modName = installedName}
  end

  if state.subscriptionRequested[repoId] then
    state.resolved[repoId] = true
    return {ready = true, action = "subscriptionRequested"}
  end

  local repository = services.repository
  if (type(repository) ~= "table" or type(repository.modSubscribe) ~= "function")
      and type(services.loadRepository) == "function" then
    local loadOk, loadedRepository = pcall(services.loadRepository)
    if loadOk and type(loadedRepository) == "table" then
      repository = loadedRepository
      services.repository = loadedRepository
    end
  end
  if type(repository) ~= "table" or type(repository.modSubscribe) ~= "function" then
    return {ready = false, retry = true, reason = "repositoryUnavailable"}
  end

  local subscribeOk, subscribeResult = pcall(repository.modSubscribe, repoId)
  if not subscribeOk or subscribeResult == false then
    local reason = subscribeOk and "repository rejected the request" or tostring(subscribeResult)
    writeLog(logger, "E", "Could not subscribe to " .. dependency.title .. ": " .. reason)
    return {ready = false, retry = true, reason = "subscriptionFailed"}
  end

  state.subscriptionRequested[repoId] = true
  state.resolved[repoId] = true
  writeLog(logger, "I", "Requested BeamNG repository download: " .. dependency.title .. " (" .. repoId .. ")")
  return {ready = true, action = "subscribed"}
end

local function ensureDependenciesInternal(services, state)
  local allReady = true
  for _, dependency in ipairs(dependencies) do
    local result = M.ensureRepositoryMod(dependency, services, state)
    if not result.ready then
      allReady = false
    end
  end
  return allReady
end

function M.ensureDependencies()
  waitingForServices = not ensureDependenciesInternal()
  if waitingForServices then
    retryElapsed = 0
    totalWait = 0
  end
  return not waitingForServices
end

function M.onExtensionLoaded()
  M.ensureDependencies()
end

function M.onUpdate(dtReal)
  if not waitingForServices then return end

  local dt = tonumber(dtReal) or 0
  retryElapsed = retryElapsed + dt
  totalWait = totalWait + dt
  if retryElapsed < retryInterval then return end

  retryElapsed = 0
  waitingForServices = not ensureDependenciesInternal()
  if waitingForServices and totalWait >= retryTimeout then
    waitingForServices = false
    writeLog(rawget(_G, "log"), "E", "Timed out waiting for BeamNG repository services; required mod download was not requested")
  end
end

M.repositoryDependencies = dependencies

return M
