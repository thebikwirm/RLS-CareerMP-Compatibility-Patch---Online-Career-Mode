-- Company logistics employment. Independent cargo-board, material-contract
-- accept/pickup, and skill-unlock loaners keep their existing functions.
local M = {}

local saveDir = "/career/rls_career"
local saveFile = saveDir .. "/logisticsEmployment.json"
local C = {
  SAVE_VERSION = 6,
  HIRE_DELAY_SIM = 10, -- short while iterating employment; restore ~180 for release
  HIRE_DELAY_SIM_RELEASE = 180,
  SIM_SECONDS_PER_GAME_DAY = 1200,
  WORLD_MINUTES_PER_DAY = 1440,
  INACTIVITY_FIRE_DAYS = 3,
  REHIRE_COOLDOWN_DAYS = 10,
  EMPLOYMENT_SURGE_BONUS_AMOUNT = 250,
  DAMAGE_STRIKE_WARN_COUNT = 2,
  DAMAGE_STRIKE_DOCK_COUNT = 2,
  DAMAGE_STRIKE_DOCK_PERCENT = 0.10,
  LISTING_OFFER_COUNT = 5,
  LISTING_REFRESH_SIM = 300,
  INDEPENDENT_CARGO_LEVEL = 30,
  EMPLOYEE_UNLOCK_LEVEL_OFFSET = 0,
  -- Half of inventory BASE_TOW_SERVICE_COST ($250) when ending day away from yard.
  REMOTE_END_DAY_TOW_BASE = 250,
  REMOTE_END_DAY_TOW_FRACTION = 0.5,
  ACCIDENT_REBIND_M = 5,
  ACCIDENT_ROAD_OFFSET_M = 3,
  ACCIDENT_ARRIVE_M = 15,
  ACCIDENT_LIVE_DAMAGE = 1000,
}
C.INACTIVITY_FIRE_SIM = C.INACTIVITY_FIRE_DAYS * C.SIM_SECONDS_PER_GAME_DAY
C.REHIRE_COOLDOWN_SIM = C.REHIRE_COOLDOWN_DAYS * C.SIM_SECONDS_PER_GAME_DAY
-- Bag for helpers so this chunk stays under LuaJIT's 200-local limit.
local U = {}
local TRAILER_UNLOCK_FLAGS = {
  "smallTrailersDelivery",
  "logisticsTrailerMedium",
  "logisticsTrailerFlatbed",
  "logisticsTrailerFramelessDump",
  "largeTrailersDelivery",
  "logisticsTrailerDolly",
  "logisticsTrailerDryvan",
  "logisticsTrailerTanker",
  "logisticsTrailerContainer",
  "logisticsTrailerLog",
}
local MATERIALS_UNLOCK_FLAGS = {
  "logisticsFluidDelivery",
  "logisticsAggregateDelivery",
  "logisticsCementDelivery",
  "logisticsCashDelivery",
}
local MATERIAL_TYPE_UNLOCK_FLAGS = {
  fluid = "logisticsFluidDelivery",
  dryBulk = "logisticsAggregateDelivery",
  cement = "logisticsCementDelivery",
  cash = "logisticsCashDelivery",
}
local VEHICLE_UNLOCK_FLAGS = {
  "junkerVeh",
  "smallVeh",
  "fleetVeh",
  "largeVeh",
  "highEndVeh",
  "exoticVeh",
  "heavyVeh",
}
local EMPLOYMENT_PARCEL_EXCLUDED_TYPES = {
  food = true,
  takeout = true,
}
-- getBranchLevel looks up pathId, not attributeKey. "logistics-delivery" is missing;
-- "logistics" is the domain (4 levels, different XP), not the careerSkills skill.
local LOGISTICS_ATTRIBUTE_KEY = "logistics-delivery"
local LOGISTICS_SKILL_PATH_IDS = {"careerSkills-logistics"}
local RECOVERY_SKILL_ATTRIBUTE_KEY = "careerSkills-recovery"
-- Open-ended work has no finite assignment loop. End Day finishes active work;
-- unfinished materials contracts are held for later instead.
local OPEN_ENDED_JOB_KINDS = {
  repo = true,
  police = true,
  bus = true,
  paramedic = true,
}
-- Phone openings board size / refresh live on C.

local state = {
  version = C.SAVE_VERSION,
  employments = {},
  rehireBlockedUntil = {},
  activeMapId = nil,
  employerOrgId = nil,
  homeFacId = nil,
  hiredAt = nil,
  lastWorkAt = nil,
  hiredWorldMinute = nil,
  lastWorkWorldMinute = nil,
  pendingApplications = {},
  shift = nil,
  escrow = { money = 0, legs = {} },
  completedAssignments = 0,
  damageRecord = { strikes = 0 },
  lastShiftActionResult = nil,
  offeredFacIds = {},
  offeredListingsAt = nil,
  headhunter = { offered = {}, pending = nil },
}

local uiOpen = false
local shiftStartPresentationPending = false
local shiftStartPresentationReady = false
local dropOffOpen = false
local dropOffFacId, dropOffPsPath = nil, nil
local dropOffEscrowPending = false
local lastDropOffProgress = nil
local lastDropOffParkingLevels = nil
local holdDropOffForProgress = false
local afterOutboundDelivered, afterReturnDelivered, afterCompanyDropOff, trySetShiftRoute
local refreshDeliveryPois, routeToYard, routeToParkStall, companyVehiclesParked
local routeToReturnPickup, routeCurrentAssignment, routeToLocation
local assignmentStillInProgress, tryAutoAssignNextRun
local assignReturnLoad
local bindAssignedCargoToIssuedTruck
local maybeCompleteBundleShift
local offerLoopCompleteChoice, beginYardReturnForLoopChoice, playerNearHomeYard
local facilityOffersRepo
local isBundleShift, getShiftAssignmentsForUi
local getLoanerTruckSpots
local isEmployed, isOnShift, getOrg, getRepLevel, facilityMatchesEmployer
local canEmployAt
local getAssignableKinds
local translateUiText, getOrgDisplayName, notifyUi, firePhoneNotification, getUiState
local tryReturnDropOffBeforeShiftUi
local LOG_TAG = "employment"

U.shiftLog = function(headline, detail, level)
  level = level or "W"
  local msg = tostring(headline or "employment event")
  if detail and detail ~= "" then
    msg = msg .. " | " .. tostring(detail)
  end
  log(level, LOG_TAG, msg)
  print("[" .. LOG_TAG .. "] " .. msg)
end

U.publishShiftActionResult = function(result)
  state.lastShiftActionResult = result
  if guihooks and type(result) == "table" then
    guihooks.trigger("employmentShiftActionResult", result)
  end
  return result
end

U.failShift = function(reason, detail)
  reason = tostring(reason or "Shift start failed")
  U.shiftLog("startShift blocked", reason .. (detail and detail ~= "" and (" | " .. tostring(detail)) or ""))
  ui_message(reason, 8, "warning")
  -- Avoid `ok` key: engineLua callbacks can collapse { ok = false, ... } to bare false in JS.
  -- Keep diagnose detail for logs/UI consumers; never paste it into the player toast.
  return U.publishShiftActionResult({
    success = false,
    message = reason,
    reason = reason,
    detail = detail or "",
  })
end

U.okShift = function(extra)
  extra = type(extra) == "table" and extra or {}
  extra.success = true
  return U.publishShiftActionResult(extra)
end

U.summarizeKindMap = function(kinds)
  return U.dEmploymentDispatch().summarizeKindMap(U.dispatchContext(), kinds)
end

U.dParcel = function()
  return career_modules_delivery_parcelManager
end

U.dGeneral = function()
  return career_modules_delivery_general
end

U.dGenerator = function()
  return career_modules_delivery_generator
end

U.dMaterials = function()
  return career_modules_delivery_materialContractManager
end

U.dCargoScreen = function()
  return career_modules_delivery_cargoScreen
end

U.dVehOffers = function()
  return career_modules_delivery_vehicleOfferManager
end

U.dLoanerCaps = function()
  if not career_modules_delivery_loanerCapabilities and extensions and extensions.load then
    pcall(extensions.load, "career_modules_delivery_loanerCapabilities")
  end
  return career_modules_delivery_loanerCapabilities
end

U.dRepo = function()
  if not gameplay_repo and extensions and extensions.load then
    pcall(extensions.load, "gameplay_repo")
  end
  return gameplay_repo
end

U.roundMoney = function(value)
  return math.floor((tonumber(value) or 0) + 0.5)
end

U.nowSim = function()
  local g = U.dGeneral()
  if g and g.time then return g.time() end
  return 0
end

U.nowWorldMinutes = function()
  local weather = career_modules_dynamicWeather
  if weather and weather.getWorldMinutes then
    return weather.getWorldMinutes()
  end
  local ui = weather and weather.getUiState and weather.getUiState() or nil
  if not ui or ui.ready == false or ui.dayIndex == nil then return nil end
  return math.max(0, math.floor(tonumber(ui.dayIndex) or 0)) * C.WORLD_MINUTES_PER_DAY
    + math.max(0, math.min(1439, math.floor(tonumber(ui.minuteOfDay) or 0)))
end

U.inactivityFireWorldMinutes = function()
  return C.INACTIVITY_FIRE_DAYS * C.WORLD_MINUTES_PER_DAY
end

U.currentMapId = function()
  return (getCurrentLevelIdentifier and getCurrentLevelIdentifier()) or ""
end

U.simDaysRemaining = function(untilWorld)
  local now = U.nowWorldMinutes()
  if now == nil then return 0 end
  local left = (tonumber(untilWorld) or 0) - now
  if left <= 0 then return 0 end
  return math.ceil(left / C.WORLD_MINUTES_PER_DAY)
end

U.setRehireBlock = function(orgId)
  if not orgId then return end
  local now = U.nowWorldMinutes()
  if now == nil then return end
  orgId = tostring(orgId)
  state.rehireBlockedUntil[orgId] = now + C.REHIRE_COOLDOWN_DAYS * C.WORLD_MINUTES_PER_DAY
end

U.clearRehireBlock = function(orgId)
  if not orgId or not state.rehireBlockedUntil then return end
  state.rehireBlockedUntil[tostring(orgId)] = nil
end

U.getRehireBlockUntil = function(orgId)
  if not orgId then return nil end
  local now = U.nowWorldMinutes()
  if now == nil then return nil end
  local untilWorld = tonumber(state.rehireBlockedUntil[tostring(orgId)])
  if untilWorld and untilWorld > now then
    return untilWorld
  end
  return nil
end

U.canRehireOrg = function(orgId)
  return U.getRehireBlockUntil(orgId) == nil
end

U.ensureRehireSaveV3 = function()
  if state._rehireV3Done then return end
  state._rehireV3Done = true
  if (tonumber(state.version) or 1) < 3 then
    state.rehireBlockedUntil = {}
    state.version = C.SAVE_VERSION
  end
end

U.applyPendingLastWorkRefresh = function(worldNow)
  if not state.refreshLastWorkAt then return end
  worldNow = tonumber(worldNow) or U.nowWorldMinutes()
  if worldNow == nil then return end
  local simNow = U.nowSim()
  for orgId, untilVal in pairs(state.rehireBlockedUntil or {}) do
    local remainingSim = (tonumber(untilVal) or 0) - simNow
    if remainingSim > 0 then
      state.rehireBlockedUntil[orgId] = worldNow + remainingSim / C.SIM_SECONDS_PER_GAME_DAY * C.WORLD_MINUTES_PER_DAY
    else
      state.rehireBlockedUntil[orgId] = nil
    end
  end
  state.refreshLastWorkAt = nil
  if state.employerOrgId then
    state.lastWorkAt = simNow
    state.lastWorkWorldMinute = worldNow
  end
  for _, emp in pairs(state.employments or {}) do
    if emp and emp.employerOrgId then
      emp.lastWorkAt = simNow
      emp.lastWorkWorldMinute = worldNow
    end
  end
  U.flushEmploymentCache()
end

U.flushEmploymentCache = function()
  if not state.activeMapId or state.activeMapId == "" then
    state.activeMapId = U.currentMapId()
  end
  local mapId = state.activeMapId
  if not mapId or mapId == "" then return end
  local hasPending = state.pendingApplications and state.pendingApplications[1]
  if state.employerOrgId then
    state.employments[mapId] = {
      employerOrgId = state.employerOrgId,
      homeFacId = state.homeFacId,
      hiredAt = state.hiredAt,
      lastWorkAt = state.lastWorkAt or state.hiredAt,
      hiredWorldMinute = state.hiredWorldMinute,
      lastWorkWorldMinute = state.lastWorkWorldMinute or state.hiredWorldMinute,
      pendingApplications = state.pendingApplications or {},
      shift = state.shift,
      escrow = state.escrow or { money = 0, legs = {} },
      completedAssignments = state.completedAssignments or 0,
      damageRecord = state.damageRecord or { strikes = 0 },
    }
  elseif state.shift or hasPending then
    local pendingFacId = hasPending and state.pendingApplications[1].facId or nil
    state.employments[mapId] = {
      employerOrgId = nil,
      homeFacId = (state.shift and state.shift.originFacId) or state.homeFacId or pendingFacId,
      hiredAt = nil,
      lastWorkAt = state.lastWorkAt,
      hiredWorldMinute = nil,
      lastWorkWorldMinute = state.lastWorkWorldMinute,
      pendingApplications = state.pendingApplications or {},
      shift = state.shift,
      escrow = state.escrow or { money = 0, legs = {} },
      completedAssignments = state.completedAssignments or 0,
      damageRecord = state.damageRecord or { strikes = 0 },
    }
  else
    state.employments[mapId] = nil
  end
end

U.saveEmploymentProgress = function()
  U.flushEmploymentCache()
  if career_saveSystem and career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
end

U.clearEmploymentCache = function()
  state.employerOrgId = nil
  state.homeFacId = nil
  state.hiredAt = nil
  state.lastWorkAt = nil
  state.hiredWorldMinute = nil
  state.lastWorkWorldMinute = nil
  state.pendingApplications = {}
  state.shift = nil
  U.bindAssignedInFlight = false
  state.escrow = { money = 0, legs = {} }
  state.completedAssignments = 0
  state.damageRecord = { strikes = 0 }
end

U.migrateEmploymentSaveData = function(data)
  data = data or {}
  local version = tonumber(data.version) or 1
  if version < 2 then
    data.employments = data.employments or {}
    if data.employerOrgId and not next(data.employments) then
      local mapId = data.homeMapId or U.currentMapId()
      if mapId and mapId ~= "" then
        data.employments[mapId] = {
          employerOrgId = data.employerOrgId,
          homeFacId = data.homeFacId,
          hiredAt = data.hiredAt,
          lastWorkAt = data.lastWorkAt or data.hiredAt,
          pendingApplications = data.pendingApplications or {},
          shift = data.shift,
          escrow = data.escrow or { money = 0, legs = {} },
          completedAssignments = tonumber(data.completedAssignments) or 0,
          damageRecord = data.damageRecord or { strikes = 0 },
        }
      end
    end
    for _, emp in pairs(data.employments) do
      if type(emp) == "table" and emp.damageRecord
          and emp.damageRecord.strikes == nil
          and (emp.damageRecord.warnings or emp.damageRecord.completedRuns) then
        emp.damageRecord = { strikes = tonumber(emp.damageRecord.warnings) or 0 }
      end
    end
    version = 2
  end
  if version < 3 then
    data.rehireBlockedUntil = {}
    version = 3
  end
  if version < 4 then
    data.refreshLastWorkAt = true
    version = 4
  end
  if version < 5 then
    data.refreshLastWorkAt = true
    version = 5
  end
  if version < 6 then
    for _, emp in pairs(data.employments or {}) do
      if type(emp) == "table" and not emp.shift then
        emp.damageRecord = { strikes = 0 }
      end
    end
    version = 6
  end
  data.version = C.SAVE_VERSION
  return data
end

U.loadEmploymentCache = function(mapId, skipFlush)
  mapId = mapId or U.currentMapId()
  if state.activeMapId and state.activeMapId ~= mapId then
    if not skipFlush then
      U.flushEmploymentCache()
    end
    U.clearOfferedListings()
  end
  state.activeMapId = mapId
  if not mapId or mapId == "" then
    U.clearEmploymentCache()
    return
  end
  local emp = state.employments[mapId]
  if emp and emp.employerOrgId then
    state.employerOrgId = emp.employerOrgId
    state.homeFacId = emp.homeFacId
    state.hiredAt = emp.hiredAt
    state.lastWorkAt = emp.lastWorkAt or emp.hiredAt
    state.hiredWorldMinute = emp.hiredWorldMinute
    state.lastWorkWorldMinute = emp.lastWorkWorldMinute or emp.hiredWorldMinute
    state.pendingApplications = emp.pendingApplications or {}
    state.shift = emp.shift
    state.escrow = emp.escrow or { money = 0, legs = {} }
    state.completedAssignments = emp.completedAssignments or 0
    state.damageRecord = emp.damageRecord or { strikes = 0 }
  elseif emp and (emp.shift or (emp.pendingApplications and emp.pendingApplications[1])) then
    U.clearEmploymentCache()
    state.homeFacId = emp.homeFacId
    state.lastWorkAt = emp.lastWorkAt
    state.lastWorkWorldMinute = emp.lastWorkWorldMinute
    state.pendingApplications = emp.pendingApplications or {}
    state.shift = emp.shift
    state.escrow = emp.escrow or { money = 0, legs = {} }
    state.completedAssignments = emp.completedAssignments or 0
    state.damageRecord = emp.damageRecord or { strikes = 0 }
  else
    U.clearEmploymentCache()
  end
  if state.damageRecord.strikes == nil and (state.damageRecord.warnings or state.damageRecord.completedRuns) then
    state.damageRecord = { strikes = tonumber(state.damageRecord.warnings) or 0 }
  end
  if not state.shift then
    state.damageRecord = { strikes = 0 }
  end
end

U.touchLastWorkAt = function()
  if not isEmployed() then return end
  state.lastWorkAt = U.nowSim()
  local worldNow = U.nowWorldMinutes()
  if worldNow ~= nil then
    state.lastWorkWorldMinute = worldNow
  end
  U.flushEmploymentCache()
end

U.employmentShiftBlocksInactivity = function(mapId, emp)
  if emp and emp.shift then return true end
  if not mapId then return false end
  if mapId ~= (state.activeMapId or U.currentMapId()) then return false end
  return state.shift ~= nil
end

U.getBranchLevelSafe = function(id)
  if not id or not (career_branches and career_branches.getBranchLevel) then return nil end
  -- Assign first; never tonumber(getBranchLevel()) — extra returns become tonumber's base.
  local level = career_branches.getBranchLevel(id)
  if level == nil then return nil end
  return math.max(0, math.floor(tonumber(level) or 0))
end

local lastSyncedDeliveryLevel = nil

local function getDeliveryLevel()
  for _, id in ipairs(LOGISTICS_SKILL_PATH_IDS) do
    local level = U.getBranchLevelSafe(id)
    if level and level > 0 then return level end
  end
  if career_branches.getSortedBranches then
    for _, branch in ipairs(career_branches.getSortedBranches()) do
      if branch and not branch.missing and branch.isSkill and branch.attributeKey == LOGISTICS_ATTRIBUTE_KEY then
        local level = U.getBranchLevelSafe(branch.id or branch.pathId)
        if level and level > 0 then return level end
      end
    end
  end
  if career_modules_playerAttributes and career_modules_playerAttributes.getAttributeValue
      and career_branches and career_branches.calcBranchLevelFromValue then
    local attrValue = career_modules_playerAttributes.getAttributeValue(LOGISTICS_ATTRIBUTE_KEY)
    local value = tonumber(attrValue) or 0
    for _, skillPathId in ipairs(LOGISTICS_SKILL_PATH_IDS) do
      local branchLevel = career_branches.calcBranchLevelFromValue(value, skillPathId)
      local level = tonumber(branchLevel)
      if level and level > 0 then
        return math.max(0, math.floor(level))
      end
    end
  end
  return 0
end

U.syncUnlockFlagsForDeliveryLevel = function()
  local level = getDeliveryLevel()
  if lastSyncedDeliveryLevel == level then return level end
  lastSyncedDeliveryLevel = level
  if career_modules_unlockFlags and career_modules_unlockFlags.resetFlags then
    career_modules_unlockFlags.resetFlags()
  end
  return level
end

local function isApprenticeshipEnabled()
  local mode = career_modules_logisticsEmploymentMode
  if mode and mode.isApprenticeshipEnabled then
    return mode.isApprenticeshipEnabled()
  end
  return false
end

local function isEmploymentUnlocked()
  return isApprenticeshipEnabled()
end

local flagMinLevelByName = nil
U.getUnlockFlagMinLevels = function()
  if flagMinLevelByName then return flagMinLevelByName end
  flagMinLevelByName = {}
  local data = jsonReadFile("/gameplay/domains/careerSkills/skills/logistics/info.json")
  if type(data) == "table" then
    for levelIdx, levelDef in ipairs(data.levels or {}) do
      for _, flag in ipairs(levelDef.unlockFlags or {}) do
        if type(flag) == "string" and flagMinLevelByName[flag] == nil then
          flagMinLevelByName[flag] = levelIdx
        end
      end
    end
  end
  return flagMinLevelByName
end

U.usesTraineeUnlocks = function()
  return isApprenticeshipEnabled() and isEmployed()
end

U.traineeHasUnlockFlag = function(flag)
  if type(flag) ~= "string" or flag == "" then return false end
  local req = U.getUnlockFlagMinLevels()[flag]
  if req == nil then
    return career_modules_unlockFlags and career_modules_unlockFlags.getFlag and career_modules_unlockFlags.getFlag(flag) and true or false
  end
  return getDeliveryLevel() >= math.max(1, req - C.EMPLOYEE_UNLOCK_LEVEL_OFFSET)
end

U.getCurrentLevelLabel = function()
  local levelId = getCurrentLevelIdentifier and getCurrentLevelIdentifier()
    or (getCurrentLevel and getCurrentLevel())
  if not levelId or levelId == "" then return "this map" end
  if core_levels and core_levels.getLevelByName then
    local info = core_levels.getLevelByName(levelId)
    if info and info.title then
      return translateUiText(info.title, levelId)
    end
  end
  return tostring(levelId)
end

U.hasCompanyShift = function()
  return state.shift ~= nil
end

U.getCargoBoardBlockMessage = function(facId)
  if U.hasCompanyShift() then
    return "End your company shift before using the cargo board."
  end
  if isApprenticeshipEnabled() and getDeliveryLevel() < C.INDEPENDENT_CARGO_LEVEL then
    return "Reach Logistics level 30 for owner-operator cargo, or take company work from Employment."
  end
  return nil
end

U.shouldShowFreelanceInspectAt = function(facId)
  if U.hasCompanyShift() then return false end
  if U.isRoleplayFacility(facId) then return false end
  if isEmployed() and facilityMatchesEmployer(facId) then return false end
  if isApprenticeshipEnabled() and getDeliveryLevel() < C.INDEPENDENT_CARGO_LEVEL then
    return false
  end
  return true
end

U.allowsOwnerOpYardBoard = function(facId)
  if not facId or U.hasCompanyShift() then return false end
  if not isApprenticeshipEnabled() then return false end
  if getDeliveryLevel() < C.INDEPENDENT_CARGO_LEVEL then return false end
  local gen = U.dGenerator()
  local fac = gen and gen.getFacilityById and gen.getFacilityById(facId)
  return U.isOwnerOpYardFacility(fac)
end

U.getMapTravelBlockMessage = function()
  if not isOnShift() then return nil end
  return string.format("End your shift before leaving %s.", U.getCurrentLevelLabel())
end

U.hasUnlockFlag = function(flag)
  if U.usesTraineeUnlocks() then
    return U.traineeHasUnlockFlag(flag)
  end
  return career_modules_unlockFlags and career_modules_unlockFlags.getFlag and career_modules_unlockFlags.getFlag(flag) and true or false
end

U.hasAnyUnlockFlag = function(flags)
  for _, flag in ipairs(flags or {}) do
    if U.hasUnlockFlag(flag) then return true end
  end
  return false
end

U.dParcelMods = function()
  return career_modules_delivery_parcelMods
end

U.dSharedParcelMods = function()
  return require("gameplay/delivery/parcelMods")
end

U.maxUnlockedParcelSlots = function()
  if U.hasUnlockFlag("logisticsParcel128Slots") then return 128 end
  if U.hasUnlockFlag("logisticsParcel64Slots") then return 64 end
  if U.hasUnlockFlag("logisticsParcel32Slots") or U.hasUnlockFlag("largePackagesDelivery") then return 32 end
  return 16
end

U.cargoItemUnlocked = function(item)
  local slots = math.floor((tonumber(item and item.slots) or 0) + 0.5)
  if slots > U.maxUnlockedParcelSlots() then return false end
  local shared = U.dSharedParcelMods()
  local modifierKeys = shared.getModifierKeys(item)
  if not next(modifierKeys) then return true end
  if U.usesTraineeUnlocks() then
    local modifiers = gameplay_delivery_parcelMods and gameplay_delivery_parcelMods.getModifiers and gameplay_delivery_parcelMods.getModifiers()
    if type(modifiers) == "table" then
      local flags = {}
      for key in pairs(modifierKeys) do
        local unlockFlag = modifiers[key] and modifiers[key].unlockFlag
        if unlockFlag then flags[unlockFlag] = U.hasUnlockFlag(unlockFlag) end
      end
      return not shared.lockedBecauseOfMods(modifierKeys, flags, nil, modifiers)
    end
  end
  local mods = U.dParcelMods()
  if not (mods and mods.lockedBecauseOfMods) then return true end
  local locked = mods.lockedBecauseOfMods(modifierKeys)
  return not locked
end

-- Hiring must use the yard's configured boxes, rather than the generic parcel unlock.
-- Inspect templates so a temporarily empty cargo board does not hide an unlocked job.
U.facilityParcelWorkOptions = function(fac)
  local options = {}
  if not fac then return options end
  local templates = require("gameplay/delivery/templates")
  templates.loadParcelTemplates()
  local scanner = U.dFacilityScanner()
  for _, generator in ipairs(fac.logisticGenerators or {}) do
    if generator.type == "parcelProvider" then
      if generator.offerMode ~= "independent"
          and scanner.generatorProvidesParcels(generator, nil, EMPLOYMENT_PARCEL_EXCLUDED_TYPES) then
        local candidates = {}
        for _, logisticType in ipairs(generator.logisticTypes or {}) do
          if not EMPLOYMENT_PARCEL_EXCLUDED_TYPES[logisticType] then
            for _, template in ipairs(templates.getTemplatesByLogisticType(logisticType)) do
              table.insert(candidates, template)
            end
          end
        end
        for _, template in ipairs(candidates) do
          local slots = tonumber(template.minSlots)
          if slots and slots <= 128 and not template.materialType
              and (not generator.slotsMin or slots >= generator.slotsMin)
              and (not generator.slotsMax or (template.maxSlots or slots) <= generator.slotsMax)
              and not EMPLOYMENT_PARCEL_EXCLUDED_TYPES[template.logisticType]
              and (tonumber((template.modChance or {}).timed) or 0) < 1 then
            local item = { slots = slots, modifiers = {} }
            for key, chance in pairs(template.modChance or {}) do
              if chance >= 1 then table.insert(item.modifiers, { type = key }) end
            end
            table.insert(options, item)
          end
        end
      end
    end
  end
  return options
end

U.playerCanWorkParcelsAtFacility = function(fac)
  if not U.playerKindUnlocked("parcel") then return false end
  local caps = U.dLoanerCaps()
  if not (caps and caps.canIssueLoanersForFacility) then return false end
  for _, item in ipairs(U.facilityParcelWorkOptions(fac)) do
    if U.cargoItemUnlocked(item)
        and caps.canIssueLoanersForFacility(fac, "parcel", { targetLoad = item.slots }) then
      return true
    end
  end
  return false
end

U.minParcelLevelForFacility = function(fac)
  local levels = U.getUnlockFlagMinLevels()
  local modifiers = U.dSharedParcelMods().getModifiers()
  local best = nil
  for _, item in ipairs(U.facilityParcelWorkOptions(fac)) do
    local flag = item.slots > 64 and "logisticsParcel128Slots"
      or item.slots > 32 and "logisticsParcel64Slots"
      or item.slots > 16 and "logisticsParcel32Slots" or "smallPackagesDelivery"
    local req = levels[flag]
    if req then
      req = math.max(req, levels.smallPackagesDelivery or 1)
      for _, modifier in ipairs(item.modifiers) do
        local modFlag = modifiers[modifier.type] and modifiers[modifier.type].unlockFlag
        req = math.max(req, (modFlag and levels[modFlag]) or 1)
      end
      if not best or req < best then best = req end
    end
  end
  return best
end

U.trailerOfferUnlocked = function(offer)
  local tag = offer and offer.vehicle and offer.vehicle.unlockTag
  local mgr = U.dVehOffers()
  if not tag or not (mgr and mgr.isVehicleTagUnlocked) then return true end
  if U.usesTraineeUnlocks() and mgr.getVehicleTagUnlockFlag then
    local unlockFlag = mgr.getVehicleTagUnlockFlag(tag)
    if unlockFlag then
      return U.hasUnlockFlag(unlockFlag)
    end
  end
  return mgr.isVehicleTagUnlocked(tag) and true or false
end

U.vehicleOfferUnlocked = function(offer)
  return U.trailerOfferUnlocked(offer)
end

U.materialOfferUnlocked = function(offer)
  if not offer then return false end
  local bulk = U.resolveMaterialBulkType(offer.materialType) or offer.cargoType
  local flag = bulk and MATERIAL_TYPE_UNLOCK_FLAGS[bulk]
  if flag then
    return U.hasUnlockFlag(flag)
  end
  local gen = U.dGenerator()
  if not (gen and gen.getMaterialsTemplatesById) then return true end
  local material = gen.getMaterialsTemplatesById(offer.materialType)
  if not material or not material.type then return false end
  if U.usesTraineeUnlocks() then
    local shared = U.dSharedParcelMods()
    local modifiers = shared and shared.getModifiers and shared.getModifiers()
    local unlockFlag = modifiers and modifiers[material.type] and modifiers[material.type].unlockFlag
    if unlockFlag then
      return U.hasUnlockFlag(unlockFlag)
    end
  end
  local mods = U.dParcelMods()
  if not (mods and mods.lockedBecauseOfMods) then return true end
  local locked = mods.lockedBecauseOfMods({[material.type] = true})
  return not locked
end

U.dFacilityScanner = function()
  return require("gameplay/delivery/facilityScanner")
end

U.dEmploymentUi = function()
  return require("gameplay/delivery/employmentUi")
end

U.facilityOffersKind = function(fac, kind)
  return U.dFacilityScanner().facilityOffersKind(fac, kind, nil, "employment", EMPLOYMENT_PARCEL_EXCLUDED_TYPES)
end

U.vehicleFilterUnlockTag = function(filterId)
  if not filterId then return nil end
  local tpl = require("gameplay/delivery/templates")
  if not tpl then return nil end
  return tpl.getVehicleFilterUnlockTag(filterId)
end

-- Map a veh/trailer filter id to the careerSkills unlock flag (tags ≠ flags for some trailers).
U.filterUnlockFlag = function(filterId)
  local tag = U.vehicleFilterUnlockTag(filterId)
  if not tag then return nil end
  local mgr = U.dVehOffers()
  local flag = mgr and mgr.getVehicleTagUnlockFlag and mgr.getVehicleTagUnlockFlag(tag)
  return flag or tag
end

-- True when this yard generates at least one car-jockey tier the player has unlocked.
U.playerCanWorkJockeyAtFacility = function(fac)
  if not fac then return false end
  local sawTier = false
  for _, generator in ipairs(fac.logisticGenerators or {}) do
    if generator.type == "vehOfferProvider" and generator.filter and generator.offerMode ~= "independent" then
      for _,filterId in ipairs(type(generator.filter) == "table" and generator.filter or {generator.filter}) do
        local tag = U.vehicleFilterUnlockTag(filterId)
        local mgr = U.dVehOffers()
        if tag and mgr and mgr.getVehicleTagUnlockFlag and mgr.isVehicleTagUnlocked
            and not mgr.getVehicleTagUnlockFlag(tag) and mgr.isVehicleTagUnlocked(tag) then
          return true
        end
        local unlockFlag = U.filterUnlockFlag(filterId)
        if unlockFlag then
          sawTier = true
          if U.hasUnlockFlag(unlockFlag) then
            return true
          end
        end
      end
    end
  end
  if sawTier then return false end
  return U.hasAnyUnlockFlag(VEHICLE_UNLOCK_FLAGS)
end

-- True when this yard generates at least one trailer tier the player has unlocked.
U.playerCanWorkTrailerAtFacility = function(fac)
  if not fac then return false end
  local sawTiers = false
  for _, generator in ipairs(fac.logisticGenerators or {}) do
    if generator.type == "trailerOfferProvider" and generator.filter and generator.offerMode ~= "independent" then
      for _,filterId in ipairs(type(generator.filter) == "table" and generator.filter or {generator.filter}) do
        local unlockFlag = U.filterUnlockFlag(filterId)
        if unlockFlag then
          sawTiers = true
          if U.hasUnlockFlag(unlockFlag) then
            return true
          end
        end
      end
    end
  end
  if sawTiers then return false end
  return U.playerKindUnlocked("trailer")
end

U.playerKindUnlocked = function(kind)
  if kind == "parcel" then return U.hasUnlockFlag("smallPackagesDelivery") end
  if kind == "trailer" then return U.hasAnyUnlockFlag(TRAILER_UNLOCK_FLAGS) end
  if kind == "materials" then return U.hasAnyUnlockFlag(MATERIALS_UNLOCK_FLAGS) end
  if kind == "vehicle" then return U.hasAnyUnlockFlag(VEHICLE_UNLOCK_FLAGS) end
  return false
end

U.resolveMaterialBulkType = function(materialTypeOrBulk)
  if not materialTypeOrBulk then return nil end
  if MATERIAL_TYPE_UNLOCK_FLAGS[materialTypeOrBulk] then
    return materialTypeOrBulk
  end
  local gen = U.dGenerator()
  if gen and gen.loadMaterialTemplates then
    pcall(gen.loadMaterialTemplates)
  end
  local tpl = gen and gen.getMaterialsTemplatesById and gen.getMaterialsTemplatesById(materialTypeOrBulk)
  if tpl and tpl.type then return tpl.type end
  local ok, shared = pcall(require, "gameplay/delivery/templates")
  if ok and shared then
    return shared.resolveMaterialBulkType(materialTypeOrBulk)
  end
  return nil
end

U.facilityMaterialTypes = function(fac)
  return U.dFacilityScanner().facilityMaterialTypes(fac, U.resolveMaterialBulkType, MATERIAL_TYPE_UNLOCK_FLAGS, "employment")
end

U.facilitySupportsMaterialType = function(fac, cargoType)
  return U.dFacilityScanner().facilitySupportsMaterialType(fac, cargoType, U.resolveMaterialBulkType, MATERIAL_TYPE_UNLOCK_FLAGS)
end

U.playerCanWorkMaterialsAtFacility = function(fac)
  if not U.facilityOffersKind(fac, "materials") then return false end
  local types = U.facilityMaterialTypes(fac)
  if not next(types) then return false end
  for matType in pairs(types) do
    local flag = MATERIAL_TYPE_UNLOCK_FLAGS[matType]
    if flag and U.hasUnlockFlag(flag) then return true end
  end
  return false
end

U.canIssueEmploymentMaterials = function(fac, cargoType)
  local caps = U.dLoanerCaps()
  if not (fac and cargoType and caps and caps.canIssueLoanersForFacility) then return false end
  return caps.canIssueLoanersForFacility(fac, "materials", { cargoType = cargoType }) and true or false
end

U.getIssuedEmploymentMaterials = function(fac, cargoType, targetLoad)
  local caps = U.dLoanerCaps()
  if not (fac and cargoType and caps and caps.getIssuedLoanersForFacility) then
    return nil, nil, { cargoType = cargoType, targetLoad = targetLoad }
  end
  local strictOpts = { cargoType = cargoType, targetLoad = targetLoad }
  local truck, trailer = caps.getIssuedLoanersForFacility(fac, "materials", strictOpts)
  if truck then return truck, trailer, strictOpts end
  local softOpts = { cargoType = cargoType }
  truck, trailer = caps.getIssuedLoanersForFacility(fac, "materials", softOpts)
  return truck, trailer, truck and softOpts or strictOpts
end

U.facilityMaterialUnlockFlags = function(fac)
  local flags = {}
  for matType, flag in pairs(MATERIAL_TYPE_UNLOCK_FLAGS) do
    if U.facilitySupportsMaterialType(fac, matType) then
      flags[#flags + 1] = flag
    end
  end
  return flags
end

U.HEADHUNTER_MILESTONES = {
  { id = "fluids", level = 19, flag = "logisticsFluidDelivery", cargoType = "fluid", label = "fluid delivery" },
  { id = "aggregates", level = 16, flag = "logisticsAggregateDelivery", cargoType = "dryBulk", label = "aggregate delivery" },
  { id = "cement", level = 11, flag = "logisticsCementDelivery", cargoType = "cement", label = "cement delivery" },
}

U.facilityHasMilestoneCargo = function(fac, wantType)
  if not fac or not wantType then return false end
  if U.facilitySupportsMaterialType(fac, wantType) then return true end
  local mgr = U.dMaterials()
  if not mgr then return false end
  if mgr.getOffersForFacility then
    for _, offer in ipairs(mgr.getOffersForFacility(fac.id, "employment") or {}) do
      local raw = offer.materialType or (offer.material and offer.material.type)
      local bulk = U.resolveMaterialBulkType(raw) or raw
      if bulk == wantType then return true end
    end
  end
  return false
end

U.findHeadhunterListing = function(milestone)
  local gen = U.ensureDeliveryGenerator()
  if not (freeroam_organizations and freeroam_organizations.getOrganizations and gen) then
    return nil
  end
  local wantType = milestone and milestone.cargoType
  if not wantType then return nil end
  local caps = U.dLoanerCaps()
  if gen.loadMaterialTemplates then
    pcall(gen.loadMaterialTemplates)
  end
  local organizations = freeroam_organizations.getOrganizations()
  if type(organizations) ~= "table" then return nil end
  local typed = {}
  local scanned, supportHits, employHits = 0, 0, 0
  for orgId, org in pairs(organizations) do
    if orgId ~= state.employerOrgId and U.canRehireOrg(orgId) then
      local facilities = gen.getFacilitiesForOrganizationId(orgId) or {}
      for _, fac in ipairs(facilities) do
        scanned = scanned + 1
        if U.facilityHasMilestoneCargo(fac, wantType) then
          supportHits = supportHits + 1
          local canIssue = caps and caps.canIssueLoanersForFacility(fac, "materials", { cargoType = wantType })
          local canWork, profile = canEmployAt(orgId, fac.id, org)
          if canIssue and canWork and not U.isRoleplayProfile(profile) then
            employHits = employHits + 1
            local kinds = getAssignableKinds(fac.id)
            table.insert(typed, {
              orgId = orgId,
              orgName = getOrgDisplayName(org, orgId),
              facId = fac.id,
              facName = translateUiText(fac.name, fac.id),
              preview = U.facilityPreview(fac),
              workSummary = U.workSummaryForProfile(profile, kinds, fac),
              employerProfile = profile,
              matchedType = true,
            })
          end
        end
      end
    end
  end
  U.shiftLog("headhunter scan", string.format("%s scanned=%d support=%d employable=%d hits=%d",
    tostring(wantType), scanned, supportHits, employHits, #typed))
  if not typed[1] then return nil end
  table.sort(typed, function(a, b)
    return tostring(a.orgName) < tostring(b.orgName)
  end)
  return typed[1]
end

U.pendingHeadhunterMatchesMilestone = function(pending, milestone)
  if not (pending and milestone and milestone.cargoType) then return false end
  if pending.id ~= milestone.id then return false end
  local gen = U.dGenerator()
  local fac = gen and gen.getFacilityById and gen.getFacilityById(pending.facId)
  return fac and U.facilityHasMilestoneCargo(fac, milestone.cargoType) or false
end

U.maybeOfferHeadhunter = function()
  if not isEmploymentUnlocked() or not isEmployed() then return end
  if isOnShift() then return end
  state.headhunter = state.headhunter or { offered = {}, pending = nil }
  state.headhunter.offered = state.headhunter.offered or {}
  if (tonumber(state.headhunter.offerVersion) or 0) < 4 then
    state.headhunter.offered = {}
    state.headhunter.pending = nil
    state.headhunter.nextCheckAt = 0
    state.headhunter.offerVersion = 4
    notifyUi()
  end
  local now = U.nowSim()
  local level = getDeliveryLevel()
  local context = table.concat({tostring(U.currentMapId()), tostring(state.employerOrgId), tostring(level)}, "|")
  if U.headhunterCheckContext ~= context then
    U.headhunterCheckContext = context
    state.headhunter.nextCheckAt = 0
  end
  if (tonumber(state.headhunter.nextCheckAt) or 0) > now then return end
  state.headhunter.nextCheckAt = now + 30
  if state.headhunter.pending then
    local pending = state.headhunter.pending
    local milestone
    for _, m in ipairs(U.HEADHUNTER_MILESTONES) do
      if m.id == pending.id then milestone = m break end
    end
    if milestone and not U.pendingHeadhunterMatchesMilestone(pending, milestone) then
      U.shiftLog("headhunter", string.format("clearing mismatched pending %s at %s",
        tostring(pending.id), tostring(pending.facId)))
      state.headhunter.pending = nil
      notifyUi()
    else
      return
    end
  end
  for _, milestone in ipairs(U.HEADHUNTER_MILESTONES) do
    if level >= milestone.level and not state.headhunter.offered[milestone.id] then
      local listing = U.findHeadhunterListing(milestone)
      if listing then
        state.headhunter.pending = {
          id = milestone.id,
          level = milestone.level,
          label = milestone.label,
          orgId = listing.orgId,
          facId = listing.facId,
          orgName = listing.orgName,
          facName = listing.facName,
          preview = listing.preview,
          workSummary = listing.workSummary,
        }
        if ui_phone_layout and ui_phone_layout.ensureEmploymentAppPlaced then
          ui_phone_layout.ensureEmploymentAppPlaced()
        end
        firePhoneNotification(
          "employment.headhunter",
          "New career path",
          string.format("Logistics L%d unlocked %s. %s is hiring — open Employment to switch.",
            milestone.level, milestone.label, listing.facName or listing.orgName),
          "invite",
          nil,
          { ttl = 20 }
        )
        U.shiftLog("headhunter", string.format("offered %s -> %s (%s)",
          tostring(milestone.id), tostring(listing.orgId), tostring(listing.facId)))
        notifyUi()
        return
      end
      U.shiftLog("headhunter", string.format("no listing for milestone %s at L%d",
        tostring(milestone.id), level))
    end
  end
  state.headhunter.nextCheckAt = now + 300
end

M.debugHeadhunter = function()
  local level = getDeliveryLevel()
  local lines = {
    string.format("employed=%s employer=%s level=%d offerVersion=%s pending=%s",
      tostring(isEmployed()),
      tostring(state.employerOrgId),
      level,
      tostring(state.headhunter and state.headhunter.offerVersion),
      tostring(state.headhunter and state.headhunter.pending and state.headhunter.pending.facId)),
  }
  for _, milestone in ipairs(U.HEADHUNTER_MILESTONES) do
    local listing = U.findHeadhunterListing(milestone)
    table.insert(lines, string.format("%s L%d offered=%s listing=%s/%s",
      milestone.id,
      milestone.level,
      tostring(state.headhunter and state.headhunter.offered and state.headhunter.offered[milestone.id]),
      listing and listing.orgName or "nil",
      listing and listing.facName or "nil"))
  end
  local msg = table.concat(lines, " | ")
  log("W", "employment", "debugHeadhunter: " .. msg)
  return lines
end

U.isRoleplayProfile = function(profile)
  return profile == "police" or profile == "bus" or profile == "paramedic"
end

U.getFacilityEmployerProfile = function(facId)
  local fac = U.dGenerator() and U.dGenerator().getFacilityById and U.dGenerator().getFacilityById(facId)
  if not fac or not fac.associatedOrganization then return nil, nil, nil end
  local org = getOrg(fac.associatedOrganization)
  if not org and freeroam_organizations and freeroam_organizations.getOrganization then
    org = freeroam_organizations.getOrganization(fac.associatedOrganization)
  end
  return U.classifyEmployer(org, fac), org, fac
end

U.isRoleplayFacility = function(facId)
  local gen = U.dGenerator()
  local fac = gen and gen.getFacilityById and gen.getFacilityById(facId)
  if not fac or not fac.associatedOrganization then return false end
  local org = getOrg(fac.associatedOrganization)
  if not org and freeroam_organizations and freeroam_organizations.getOrganization then
    org = freeroam_organizations.getOrganization(fac.associatedOrganization)
  end
  return U.isRoleplayProfile(U.classifyRoleplayFacility(fac, org))
end

U.getActiveShiftOrgId = function()
  if state.shift and state.shift.shiftOrgId then
    return state.shift.shiftOrgId
  end
  return state.employerOrgId
end


U.ensureDeliveryGenerator = function()
  if not U.dGenerator() and extensions and extensions.load then
    pcall(extensions.load, "career_modules_delivery_generator")
  end
  return U.dGenerator()
end

U.orgHasFleet = function(org)
  return org and type(org.loanableVehicles) == "table" and org.loanableVehicles[1] ~= nil
end

U.classifyRoleplayOrg = function(org)
  return require('gameplay/delivery/facilityRole').organization(org)
end

U.classifyRoleplayFacility = function(fac, org)
  return require('gameplay/delivery/facilityRole').resolve(fac, org)
end

U.facilityHasLogisticsOffers = function(fac)
  return U.facilityOffersKind(fac, "parcel")
    or U.facilityOffersKind(fac, "trailer")
    or U.facilityOffersKind(fac, "materials")
end

U.isOmittedFromEmployment = function(fac)
  return fac and fac.omitEmployment == true
end

U.isVehicleDistributorFacility = function(fac)
  if not fac then return false end
  if fac.vehicleDistributor == false then return false end
  if U.isOmittedFromEmployment(fac) then return false end
  local org = getOrg(fac.associatedOrganization)
  if not org and freeroam_organizations and freeroam_organizations.getOrganization then
    org = freeroam_organizations.getOrganization(fac.associatedOrganization)
  end
  if U.classifyRoleplayFacility(fac, org) then return false end
  if fac.vehicleDistributor == true or fac.carHaulFacility == true then
    return true
  end
  if not U.facilityOffersKind(fac, "vehicle") then return false end
  if U.facilityOffersKind(fac, "parcel") then return false end
  if U.facilityOffersKind(fac, "trailer") then return false end
  if U.facilityOffersKind(fac, "materials") then return false end
  return true
end

local function facilityIssuesDistributorHaul(fac)
  if not U.isVehicleDistributorFacility(fac) then return false end
  local caps = U.dLoanerCaps()
  return caps and caps.canIssueLoanersForFacility(fac, "trailer", {}) or false
end

-- Owner-op / employment hubs: any logistics provider unless omitEmployment.
U.isOwnerOpYardFacility = function(fac)
  if not fac or U.isOmittedFromEmployment(fac) then return false end
  local org = getOrg(fac.associatedOrganization)
  if not org and freeroam_organizations and freeroam_organizations.getOrganization then
    org = freeroam_organizations.getOrganization(fac.associatedOrganization)
  end
  if U.classifyRoleplayFacility(fac, org) then return false end
  return U.facilityHasLogisticsOffers(fac) or U.isVehicleDistributorFacility(fac)
end

U.classifyEmployer = function(org, fac)
  if not org or not fac then return nil end
  local roleplay = U.classifyRoleplayFacility(fac, org)
  if roleplay then return roleplay end
  if U.isOmittedFromEmployment(fac) then return nil end

  -- Delivery yards often attach loaners via rlsLoaners.facilities.json on the facility,
  -- while the org table stays fleet-empty (dealerships). Count either source.
  local hasFleet = U.orgHasFleet(org)
    or (type(fac.loanableVehicles) == "table" and fac.loanableVehicles[1] ~= nil)
  local hasJockey = U.facilityOffersKind(fac, "vehicle")
  local hasMaterials = U.facilityOffersKind(fac, "materials")
  local hasTrailer = U.facilityOffersKind(fac, "trailer")
  local hasParcel = U.facilityOffersKind(fac, "parcel")
  local hasLogistics = hasParcel or hasTrailer or hasMaterials
  local hasRollbackRepo = facilityOffersRepo(fac.id)
  local isDistributor = U.isVehicleDistributorFacility(fac)

  -- New-vehicle distributors: jockeys + company fleet (truck/trailer multi-car) mix.
  if isDistributor then
    if hasJockey and hasFleet then return "jockey_mixed" end
    if hasJockey then return "jockey_only" end
    if hasFleet or hasLogistics then return "logistics" end
  end
  if hasJockey and hasRollbackRepo then
    return "jockey_repo_bundle"
  end
  if hasJockey and not hasFleet then
    return "jockey_only"
  end
  if hasJockey and hasFleet then
    return "jockey_mixed"
  end
  if hasLogistics then
    return "logistics"
  end
  return nil
end

U.makeRoleplayJob = function(profile)
  local labels = {
    police = {"Police patrol", "Clock in and take a company vehicle"},
    bus = {"Bus routes", "Clock in and take a company bus"},
    paramedic = {"Paramedic calls", "Clock in and take a company ambulance"},
  }
  local info = labels[profile] or labels.police
  return {
    kind = profile,
    label = info[1],
    subtext = info[2],
  }
end

local MATERIAL_WORK_LABELS = {
  fluid = "fluids",
  dryBulk = "aggregates",
  cement = "cement",
  cash = "cash",
}

U.materialWorkLabel = function(fac)
  if not fac then return nil end
  local bits, seen = {}, {}
  for matType, label in pairs(MATERIAL_WORK_LABELS) do
    if U.facilitySupportsMaterialType(fac, matType) then
      local flag = MATERIAL_TYPE_UNLOCK_FLAGS[matType]
      if not flag or U.hasUnlockFlag(flag) then
        if not seen[label] then
          seen[label] = true
          table.insert(bits, label)
        end
      end
    end
  end
  table.sort(bits)
  return #bits > 0 and table.concat(bits, ", ") or nil
end

U.trailerWorkLabel = function(fac)
  if not fac then return nil end
  local lookup = fac.logisticTypesProvidedLookup or {}
  local bits, seen = {}, {}
  for key, enabled in pairs(lookup) do
    if enabled and type(key) == "string" and key:find("^trailerDelivery", 1, true) then
      local label = "trailers"
      if key:find("Dryvan", 1, true) then label = "dry vans"
      elseif key:find("Container", 1, true) then label = "containers"
      elseif key:find("Flatbed", 1, true) then label = "flatbeds"
      elseif key:find("Residential", 1, true) then label = "household trailers"
      elseif key:find("Tanker", 1, true) then label = "tankers"
      elseif key:find("Log", 1, true) then label = "log trailers"
      end
      if not seen[label] then
        seen[label] = true
        table.insert(bits, label)
      end
    end
  end
  table.sort(bits)
  return #bits > 0 and table.concat(bits, ", ") or nil
end

U.logisticsWorkLabel = function(fac, kinds)
  kinds = kinds or {}
  local bits = {}
  if kinds.parcel then table.insert(bits, "parcels") end
  local trailerLabel = kinds.trailer and U.trailerWorkLabel(fac) or nil
  if trailerLabel then table.insert(bits, trailerLabel) end
  local materialLabel = kinds.materials and U.materialWorkLabel(fac) or nil
  if materialLabel then table.insert(bits, materialLabel) end
  return #bits > 0 and table.concat(bits, ", ") or "assigned loads"
end

U.minVehicleLevelForFacility = function(fac)
  if not fac then return U.minLevelForUnlockFlags(VEHICLE_UNLOCK_FLAGS) end
  local best = nil
  for _, generator in ipairs(fac.logisticGenerators or {}) do
    if generator.type == "vehOfferProvider" and generator.filter and generator.offerMode ~= "independent" then
      for _, filterId in ipairs(type(generator.filter) == "table" and generator.filter or {generator.filter}) do
        local unlockFlag = U.filterUnlockFlag(filterId)
        local req = unlockFlag and U.getUnlockFlagMinLevels()[unlockFlag]
        if type(req) == "number" and (not best or req < best) then
          best = req
        end
      end
    end
  end
  if best then return best end
  return U.minLevelForUnlockFlags(VEHICLE_UNLOCK_FLAGS)
end

U.minTrailerLevelForFacility = function(fac)
  if not fac then return U.minLevelForUnlockFlags(TRAILER_UNLOCK_FLAGS) end
  local best = nil
  for _, generator in ipairs(fac.logisticGenerators or {}) do
    if generator.type == "trailerOfferProvider" and generator.filter and generator.offerMode ~= "independent" then
      for _, filterId in ipairs(type(generator.filter) == "table" and generator.filter or {generator.filter}) do
        local unlockFlag = U.filterUnlockFlag(filterId)
        local req = unlockFlag and U.getUnlockFlagMinLevels()[unlockFlag]
        if type(req) == "number" and (not best or req < best) then
          best = req
        end
      end
    end
  end
  if best then return best end
  return U.minLevelForUnlockFlags(TRAILER_UNLOCK_FLAGS)
end

U.offeringsWorkSummary = function(offerings)
  return U.dEmploymentUi().offeringsWorkSummary(offerings)
end

-- Full yard menu for employment UI: every work type this facility supports, with unlock floors.
-- `available` mirrors getAssignableKinds (what hire-in would actually issue today).
U.buildFacilityOfferings = function(facId, profile, assignableKinds)
  local offerings = {}
  local gen = U.dGenerator()
  local fac = gen and gen.getFacilityById and gen.getFacilityById(facId)
  if not fac then return offerings end
  assignableKinds = assignableKinds or getAssignableKinds(facId)

  local function push(id, label, minLevel, available)
    table.insert(offerings, {
      id = id,
      label = label,
      minLevel = type(minLevel) == "number" and minLevel or nil,
      availableFromLevel = type(minLevel) == "number"
        and math.max(1, minLevel - C.EMPLOYEE_UNLOCK_LEVEL_OFFSET) or nil,
      available = available and true or false,
    })
  end

  if U.isRoleplayProfile(profile) then
    local caps = U.dLoanerCaps()
    local available = caps and caps.canIssueRoleplayVehicleForFacility(fac, {})
    push(profile, U.makeRoleplayJob(profile).label, nil, available)
    local _, fleet
    if caps and caps.getServiceFleetForFacility then _, fleet = caps.getServiceFleetForFacility(fac) end
    offerings[#offerings].unavailableReason = fleet and fleet.unavailableReason
    return offerings
  end

  local materialRows = {
    { id = "fluid", label = "Fluids", flag = "logisticsFluidDelivery" },
    { id = "dryBulk", label = "Aggregates", flag = "logisticsAggregateDelivery" },
    { id = "cement", label = "Cement", flag = "logisticsCementDelivery" },
    { id = "cash", label = "Cash", flag = "logisticsCashDelivery" },
  }
  for _, row in ipairs(materialRows) do
    if U.facilitySupportsMaterialType(fac, row.id) then
      local minLevel = U.getUnlockFlagMinLevels()[row.flag]
      local available = assignableKinds.materials == true and U.hasUnlockFlag(row.flag)
      push(row.id, row.label, minLevel, available)
    end
  end

  if U.facilityOffersKind(fac, "trailer") then
    local trailerMin = U.minTrailerLevelForFacility(fac)
    local trailerAvailable = assignableKinds.trailer == true and U.playerCanWorkTrailerAtFacility(fac)
    push("trailer", "Trailer delivery", trailerMin, trailerAvailable)
  end

  if U.facilityOffersKind(fac, "parcel") then
    push(
      "parcel",
      "Parcel runs",
      U.minParcelLevelForFacility(fac),
      assignableKinds.parcel == true
    )
  end

  if U.facilityOffersKind(fac, "vehicle") then
    local minVehicle = U.isVehicleDistributorFacility(fac)
      and (U.getUnlockFlagMinLevels().logisticsCarHauling or 14)
      or U.minVehicleLevelForFacility(fac)
    push(
      "hauling",
      "Car hauling",
      minVehicle,
      assignableKinds.vehicle == true
    )
  end

  return offerings
end

U.workSummaryForProfile = function(profile, kinds, fac)
  kinds = kinds or {}
  if profile == "police" then return "police patrol" end
  if profile == "bus" then return "bus routes" end
  if profile == "paramedic" then return "paramedic calls" end
  local facId = fac and fac.id
  if facId then
    return U.offeringsWorkSummary(U.buildFacilityOfferings(facId, profile, kinds))
  end
  if profile == "logistics" then
    return U.logisticsWorkLabel(fac, kinds)
  end
  if profile == "jockey_only" then
    if kinds.parcel or kinds.trailer or kinds.materials then
      return U.logisticsWorkLabel(fac, kinds)
    end
    if kinds.repo or kinds.vehicle then
      return "Car hauling"
    end
    return "assigned loads"
  end
  if profile == "jockey_repo_bundle" then
    return "Car hauling"
  end
  if profile == "jockey_mixed" then
    local bits = {}
    if kinds.parcel then table.insert(bits, "Parcel runs") end
    local trailerLabel = kinds.trailer and U.trailerWorkLabel(fac) or nil
    if trailerLabel then table.insert(bits, trailerLabel) end
    local materialLabel = kinds.materials and U.materialWorkLabel(fac) or nil
    if materialLabel then table.insert(bits, materialLabel) end
    if U.playerKindUnlocked("vehicle") and (kinds.vehicle or kinds.repo) then
      table.insert(bits, "Car hauling")
    end
    return #bits > 0 and table.concat(bits, ", ") or "assigned loads"
  end
  return U.logisticsWorkLabel(fac, kinds)
end

getAssignableKinds = function(facId)
  local kinds = {}
  local gen = U.dGenerator()
  local fac = gen and gen.getFacilityById and gen.getFacilityById(facId)
  if not fac then return kinds end
  local caps = U.dLoanerCaps()
  if facilityIssuesDistributorHaul(fac) then
    if U.facilityOffersKind(fac, "vehicle") and U.hasUnlockFlag("logisticsCarHauling")
        and U.playerCanWorkJockeyAtFacility(fac) then
      kinds.vehicle = true
    end
    return kinds
  end
  if U.facilityOffersKind(fac, "parcel") and U.playerCanWorkParcelsAtFacility(fac) then
    kinds.parcel = true
  end
  if U.facilityOffersKind(fac, "trailer") and U.playerCanWorkTrailerAtFacility(fac)
      and caps and caps.canIssueLoanersForFacility(fac, "trailer", {}) then
    kinds.trailer = true
  end
  if U.playerCanWorkMaterialsAtFacility(fac) and caps then
    local types = U.facilityMaterialTypes(fac)
    for matType in pairs(types) do
      local flag = MATERIAL_TYPE_UNLOCK_FLAGS[matType]
      if flag and U.hasUnlockFlag(flag)
          and caps.canIssueLoanersForFacility(fac, "materials", { cargoType = matType }) then
        kinds.materials = true
        break
      end
    end
  end
  if U.facilityOffersKind(fac, "vehicle") and U.playerCanWorkJockeyAtFacility(fac) then
    -- Employment converts car-jockey yards into car hauling: company rollback +
    -- pickup backhaul. Rollback comes from the yard fleet or the RLS employment pool.
    kinds.vehicle = true
    kinds.repo = true
  end
  return kinds
end

U.isParcelStringEmployer = function(facId)
  local kinds = getAssignableKinds(facId)
  if not kinds.parcel then return false end
  if kinds.trailer or kinds.materials or kinds.vehicle or kinds.repo then return false end
  return true
end


U.describeLoanerOffer = function(offer)
  return U.dEmploymentDispatch().describeLoanerOffer(U.dispatchContext(), offer)
end

U.diagnoseDispatch = function(facId, context)
  return U.dEmploymentDispatch().diagnoseDispatch(U.dispatchContext(), facId, context)
end

U.diagnoseNoJob = function(facId)
  return U.dEmploymentDispatch().diagnoseNoJob(U.dispatchContext(), facId)
end

U.diagnoseLoanerFailure = function(fac, job, opts)
  return U.dEmploymentDispatch().diagnoseLoanerFailure(U.dispatchContext(), fac, job, opts)
end

getOrg = function(orgId)
  if not orgId or not freeroam_organizations then return nil end
  -- Listings iterate getOrganizations(); apply must use the same table.
  -- getOrganization() re-runs reputation and can fail/log for some org files.
  local all = freeroam_organizations.getOrganizations and freeroam_organizations.getOrganizations()
  if type(all) == "table" and all[orgId] then
    return all[orgId]
  end
  if freeroam_organizations.getOrganization then
    local ok, org = pcall(freeroam_organizations.getOrganization, orgId)
    if ok and org then return org end
  end
  return nil
end

translateUiText = function(value, fallback)
  return U.dEmploymentUi().translateText(value, fallback)
end

getOrgDisplayName = function(org, orgId)
  return U.dEmploymentUi().orgDisplayName(org, orgId)
end

U.getBusinessDisplayName = function(facId, orgId)
  if facId then
    local gen = U.dGenerator()
    local fac = gen and gen.getFacilityById and gen.getFacilityById(facId)
    if fac and fac.name then
      return translateUiText(fac.name, facId)
    end
  end
  return getOrgDisplayName(getOrg(orgId), orgId)
end

getRepLevel = function(org)
  return tonumber(org and org.reputation and org.reputation.level) or 0
end

U.getOrgReputationLabel = function(org, level)
  level = tonumber(level)
  if level == nil then level = getRepLevel(org) end
  return U.dEmploymentUi().reputationLabel(org, level)
end

U.getCompanyShare = function()
  local orgId = U.getActiveShiftOrgId()
  local org = getOrg(orgId)
  local level = getRepLevel(org)
  if career_modules_reputation and career_modules_reputation.getCompanyShareValue then
    return career_modules_reputation.getCompanyShareValue(level)
  end
  return 0.5
end

notifyUi = function()
  if guihooks then
    guihooks.trigger("employmentUpdated")
  end
end

firePhoneNotification = function(channelKey, title, message, kind, extra, opts)
  if U.nextAssignmentTransition and (channelKey == "employment.shiftStarted" or channelKey == "employment.stringReady") then return end
  U.dEmploymentUi().firePhoneNotification(channelKey, title, message, kind, extra, opts)
end

U.maybeNotifyEmploymentUnlock = function()
  -- Employment is preinstalled from career start; no unlock notification.
end

U.getEmployerTasklistHeader = function()
  local facId = state.homeFacId or (state.shift and state.shift.originFacId)
  local fac = U.dGenerator() and U.dGenerator().getFacilityById and U.dGenerator().getFacilityById(facId)
  local org = getOrg(state.employerOrgId)
  return U.dEmploymentUi().employerTasklistHeader({
    facName = fac and type(fac.name) == "string" and fac.name ~= "" and fac.name or nil,
    orgName = org and org.name,
    orgId = state.employerOrgId,
  })
end

U.clearTaskGuidance = function()
  U.dEmploymentUi().clearTaskGuidance(guihooks)
end

U.purgeIndependentTasklist = function()
  local tl = career_modules_delivery_tasklist
  if tl and tl.clearAll then
    tl.clearAll()
  end
end

U.buildTaskGuidanceContext = function(shift)
  local bundle = shift and isBundleShift(shift)
  return {
    guihooks = guihooks,
    shift = shift,
    header = U.getEmployerTasklistHeader(),
    assignmentStillInProgress = assignmentStillInProgress(),
    purgeIndependent = U.purgeIndependentTasklist,
    isBundle = bundle and true or false,
    bundleItems = bundle and getShiftAssignmentsForUi(shift) or nil,
    getRepo = U.dRepo,
    getMaterialsActive = function()
      local mgr = U.dMaterials()
      return mgr and mgr.getActiveContract and mgr.getActiveContract()
    end,
    getVehicleTaskInfo = function()
      return career_modules_delivery_vehicleTasks
        and career_modules_delivery_vehicleTasks.getPrimaryActiveVehicleTaskInfo
        and career_modules_delivery_vehicleTasks.getPrimaryActiveVehicleTaskInfo()
    end,
    getBusGuidance = function()
      if gameplay_bus and gameplay_bus.getEmploymentTaskGuidance then
        return gameplay_bus.getEmploymentTaskGuidance()
      end
    end,
    getAmbulanceGuidance = function()
      if gameplay_ambulance and gameplay_ambulance.getEmploymentTaskGuidance then
        return gameplay_ambulance.getEmploymentTaskGuidance()
      end
    end,
    accidentTask = shift and U.accidentTaskGuidance and U.accidentTaskGuidance(shift) or nil,
    assignedReturnCargoInVehicle = shift and U.assignedReturnCargoInVehicle(shift) or false,
    clearReturnNeedsPickup = function()
      if shift then shift.returnNeedsPickup = nil end
    end,
    handoffPolice = function()
      if extensions and extensions.load and not career_modules_policeTasklist then
        pcall(extensions.load, "career_modules_policeTasklist")
      end
      if career_modules_policeTasklist and career_modules_policeTasklist.refresh then
        career_modules_policeTasklist.refresh()
      end
    end,
  }
end

local function refreshTaskGuidance(force)
  U.dEmploymentUi().refreshTaskGuidance(U.buildTaskGuidanceContext(state.shift), force)
end

U.makeAssignmentGuard = function()
  local shift, mapId = state.shift, U.currentMapId()
  return function()
    return shift ~= nil and state.shift == shift and U.currentMapId() == mapId
      and career_modules_delivery_employment == M
  end
end

U.refreshActiveTaskGuidance = function()
  local shift = state.shift
  if not shift or (not shift.awaitingPark and not shift.spawnBlocked and (shift.paused or shift.phase == "loopComplete")) then return end
  refreshTaskGuidance(true)
  if shift.jobKind == "materials" and not shift.awaitingPark and not shift.spawnBlocked then
    local mgr = U.dMaterials()
    local active = mgr and mgr.getActiveContract and mgr.getActiveContract()
    if active and active.status == "active" and mgr.refreshTaskGuidance then
      mgr.refreshTaskGuidance(true)
    end
  end
end

U.resetEscrow = function()
  state.escrow = { money = 0, legs = {} }
  local mapId = state.activeMapId
  if mapId and state.employments and state.employments[mapId] then
    state.employments[mapId].escrow = state.escrow
  end
end

U.escrowKeepSum = function()
  local sum = 0
  for _, leg in ipairs((state.escrow and state.escrow.legs) or {}) do
    sum = sum + (tonumber(leg.keep) or 0)
  end
  return U.roundMoney(sum)
end

U.reconcileEscrowMoney = function(reason)
  state.escrow = state.escrow or { money = 0, legs = {} }
  local fromLegs = U.escrowKeepSum()
  local fromMoney = U.roundMoney(state.escrow.money)
  if fromLegs ~= fromMoney then
    U.shiftLog("escrow reconcile", string.format("%s money=%d legsSum=%d → using legs",
      tostring(reason or "sync"), fromMoney, fromLegs))
    state.escrow.money = fromLegs
  end
  return fromLegs
end

U.recordEscrowLeg = function(label, gross, keep, share, kind)
  state.escrow = state.escrow or { money = 0, legs = {} }
  state.escrow.legs = state.escrow.legs or {}
  table.insert(state.escrow.legs, {
    label = label,
    gross = U.roundMoney(gross),
    keep = U.roundMoney(keep),
    companyShare = share,
    kind = kind,
    at = U.nowSim(),
  })
end

U.addEscrowKeep = function(label, gross, share, kind)
  share = tonumber(share) or U.getCompanyShare()
  gross = tonumber(gross) or 0
  local keep = U.roundMoney(gross * (1 - share))
  if keep == 0 and gross == 0 then return 0 end
  state.escrow = state.escrow or { money = 0, legs = {} }
  state.escrow.money = U.roundMoney((state.escrow.money or 0) + keep)
  U.recordEscrowLeg(label, gross, keep, share, kind)
  return keep
end

U.emptyShift = function(keepTransition)
  if not keepTransition and U.finishNextAssignmentTransition then U.finishNextAssignmentTransition() end
  local endedRoleplay = state.shift and (state.shift.jobKind == "bus" or state.shift.jobKind == "paramedic"
    or state.shift.jobKind == "police")
  U.cancelSpawnBlockedWatch()
  if U.deleteAccidentCargoBox then
    U.deleteAccidentCargoBox()
  end
  state.shift = nil
  U.bindAssignedInFlight = false
  U.pendingCargoTaskRefresh = nil
  dropOffEscrowPending = false
  U.resetDamageStrikes()
  U.clearTaskGuidance()
  U.dEmploymentUi().resetTasklistCache()
  U.purgeIndependentTasklist()
  if endedRoleplay and guihooks then
    guihooks.trigger("ClearTasklist")
  end
end

U.isDevToolsEnabled = function()
  local em = rawget(_G, "overhaul_extensionManager")
  return em and em.isDevKeyValid and em.isDevKeyValid() and true or false
end

isEmployed = function()
  return state.employerOrgId ~= nil
end

isOnShift = function()
  return state.shift ~= nil and not state.shift.paused
end

U.isOpenEndedJobKind = function(kind)
  return kind ~= nil and OPEN_ENDED_JOB_KINDS[kind] == true
end

U.uiSkillProgress = function(profile, fac, org)
  if not U.isRoleplayProfile(profile) then
    return getDeliveryLevel(), "Logistics"
  end
  local progress = require("gameplay/delivery/serviceFleet").playerUnlockProgress(fac, org)
  if progress then
    return progress.skillLevel, progress.skillLabel
  end
  if profile == "bus" then
    local level = (career_branches and career_branches.getBranchLevel and (
      career_branches.getBranchLevel("careerSkills-passenger") or career_branches.getBranchLevel("passenger"))) or 0
    return level, "Passenger Skill"
  end
  local level = (career_branches and career_branches.getBranchLevel and (
    career_branches.getBranchLevel("careerSkills-emergency") or career_branches.getBranchLevel("emergency"))) or 0
  return level, profile == "police" and "Police Skill" or "Paramedic Skill"
end

U.buildRoleplaySetupUi = function(profile, fac, facId)
  if not U.isRoleplayProfile(profile) then return nil end
  local vehicles, unavailableReason = {}, nil
  local caps = U.dLoanerCaps()
  if caps and caps.getRoleplayFleetForUi then
    vehicles, unavailableReason = caps.getRoleplayFleetForUi(fac)
  end
  return {
    facId = facId,
    kind = profile,
    vehicles = vehicles or {},
    unavailableReason = unavailableReason,
  }
end

isBundleShift = function(shift)
  return shift and shift.jobKind == "vehicle_repo_bundle"
end

U.isBundleHaulBackhaulPending = function(shift)
  shift = shift or state.shift
  if not isBundleShift(shift) then return false end
  local a = shift.assignments
  return a and a.vehicle and a.vehicle.complete and a.repo and not a.repo.complete and true or false
end

local DISTRIBUTOR_HAUL_COUNT = 2

local function isDistributorHaulShift(shift)
  return shift and shift.distributorHaul and true or false
end

U.accessPointProvidesLogisticType = function(ap, logisticType)
  return U.dFacilityScanner().accessPointProvidesLogisticType(ap, logisticType)
end

U.offerHaulLogisticType = function(offer)
  return (offer and offer.task and offer.task.lookupType)
    or (offer and offer.data and offer.data.lookupType)
    or "vehDeliveryNew"
end

U.distributorHaulStagingPads = function(fac, logisticType)
  local pads = {}
  if not fac then return pads end
  logisticType = logisticType or "vehDeliveryNew"
  for name, ap in pairs(fac.accessPointsByName or {}) do
    if U.accessPointProvidesLogisticType(ap, logisticType) then
      local path = ap.psPath
      if (not path or path == "") and ap.ps and ap.ps.getPath then
        path = ap.ps:getPath()
      end
      if path then
        table.insert(pads, { name = name, path = path })
      end
    end
  end
  table.sort(pads, function(a, b) return tostring(a.name) < tostring(b.name) end)
  return pads
end

U.stageDistributorHaulOffers = function(fac, offers)
  if not fac or not offers or not offers[1] then return end
  local pads = U.distributorHaulStagingPads(fac, U.offerHaulLogisticType(offers[1]))
  if not pads[1] then return end
  local padByPath = {}
  for _, pad in ipairs(pads) do
    padByPath[pad.path] = pad
  end
  local reserved = {}
  for _, offer in ipairs(offers) do
    local path = offer.spawnLocation and offer.spawnLocation.psPath
    if path and padByPath[path] and not reserved[path] then
      reserved[path] = offer.id
    end
  end
  local function applyPad(offer, path)
    local loc = { type = "facilityParkingspot", facId = fac.id, psPath = path }
    offer.origin = loc
    offer.spawnLocation = loc
    if offer.locations then
      offer.locations[1] = loc
    end
  end
  local nextIdx = 1
  local function nextFreePad()
    while pads[nextIdx] and reserved[pads[nextIdx].path] do
      nextIdx = nextIdx + 1
    end
    local pad = pads[nextIdx]
    if pad then
      nextIdx = nextIdx + 1
      return pad
    end
    return pads[1]
  end
  for _, offer in ipairs(offers) do
    local path = offer.spawnLocation and offer.spawnLocation.psPath
    if path and reserved[path] == offer.id then
      applyPad(offer, path)
    else
      local pad = nextFreePad()
      if pad then
        reserved[pad.path] = offer.id
        applyPad(offer, pad.path)
      end
    end
  end
end

local function shiftVehicleOfferIdSet(shift)
  local set = {}
  if not shift then return set end
  for _, id in ipairs(shift.assignedOfferIds or {}) do
    if id then set[id] = true end
  end
  if shift.assignedOfferId then set[shift.assignedOfferId] = true end
  local bundled = U.getShiftVehicleOfferId(shift)
  if bundled then set[bundled] = true end
  return set
end

local function distributorHaulRemaining(shift)
  if not isDistributorHaulShift(shift) then return 0 end
  local delivered = {}
  for _, id in ipairs(shift.deliveredOfferIds or {}) do
    delivered[id] = true
  end
  local n = 0
  for id in pairs(shiftVehicleOfferIdSet(shift)) do
    if not delivered[id] then n = n + 1 end
  end
  return n
end

facilityOffersRepo = function(facId)
  local fac = U.dGenerator() and U.dGenerator().getFacilityById and U.dGenerator().getFacilityById(facId)
  local caps = U.dLoanerCaps()
  if fac and fac.employmentRepo == false then return false end
  return fac and caps and caps.canIssueRepoForFacility and caps.canIssueRepoForFacility(fac, {}) or false
end

U.getShiftVehicleOfferId = function(shift)
  if not shift then return nil end
  if shift.assignments and shift.assignments.vehicle then
    if shift.assignments.vehicle.complete then
      return shift.assignedOfferId or (shift.assignments.repo and shift.assignments.repo.offerId)
    end
    return shift.assignments.vehicle.offerId
  end
  return shift.assignedOfferId
end

U.vehicleOfferTaskActive = function(offerId)
  if not offerId or not career_modules_delivery_vehicleTasks then return false end
  local tasks = career_modules_delivery_vehicleTasks.getVehicleTasks
    and career_modules_delivery_vehicleTasks.getVehicleTasks() or {}
  for _, taskData in ipairs(tasks) do
    if taskData.offer and taskData.offer.id == offerId then
      return true
    end
  end
  return false
end

getShiftAssignmentsForUi = function(shift)
  if not isBundleShift(shift) or not shift.assignments then return nil end
  local a = shift.assignments
  local items = {}
  if a.vehicle then
    table.insert(items, {
      id = "vehicle",
      label = a.vehicle.label or "Car hauling",
      subtext = a.vehicle.subtext or "",
      complete = a.vehicle.complete and true or false,
    })
  end
  if a.repo then
    local repoLabel = a.repo.label or "Pickup — haul a vehicle back to the yard"
    if a.vehicle and a.vehicle.complete and shift.returnIsBackhaul
        and a.repo.offerId == shift.assignedOfferId and U.assignedReturnCargoInVehicle(shift) then
      repoLabel = shift.returnDeliverLabel or "Deliver the assigned vehicle"
    end
    table.insert(items, {
      id = "repo",
      label = repoLabel,
      subtext = a.repo.subtext or "",
      complete = a.repo.complete and true or false,
    })
  end
  return #items > 0 and items or nil
end

maybeCompleteBundleShift = function(opts)
  local shift = state.shift
  if not isBundleShift(shift) then return end
  local a = shift.assignments
  if not a or not a.vehicle or not a.repo then return end
  if not a.vehicle.complete or not a.repo.complete then
    refreshTaskGuidance(true)
    notifyUi()
    return
  end
  opts = opts or {}
  -- Repo drop-off is the home yard; jockey finishing last can be elsewhere.
  if opts.atYard or playerNearHomeYard() then
    offerLoopCompleteChoice({
      label = "Assignments complete",
      subtext = "Take another job or end your day",
    })
    return
  end
  beginYardReturnForLoopChoice()
end

local function materialsAssignmentHasWork()
  local active = U.dMaterials() and U.dMaterials().getActiveContract and U.dMaterials().getActiveContract()
  if not active or active.status ~= "active" then return false end
  return (tonumber(active.remainingAmount) or 0) > 0
    or (tonumber(active.inTransitAmount) or 0) > 0
    or (tonumber(active.loadableAmount) or 0) > 0
end

assignmentStillInProgress = function()
  local shift = state.shift
  if not shift or shift.paused then return false end
  if isBundleShift(shift) then
    if shift.wrecked then return false end
    local a = shift.assignments
    if not a then return false end
    if not a.vehicle or not a.vehicle.complete then return true end
    if not a.repo or not a.repo.complete then
      return true
    end
    return false
  end
  if shift.jobKind == "police" or shift.jobKind == "bus" or shift.jobKind == "paramedic" then
    return false
  end
  if shift.jobKind == "materials" then
    return materialsAssignmentHasWork()
  end
  if shift.jobKind == "repo" then
    if shift.repoPendingStart then return true end
    local repo = U.dRepo()
    return repo and repo.isEmploymentRepoActive and repo.isEmploymentRepoActive() or false
  end
  if shift.wrecked or shift.phase == "loopComplete" then return false end
  return shift.phase == "outbound" or shift.phase == "return"
end

local function getEmployerOrgId()
  return state.employerOrgId
end

local function keepDeliveryModeActive()
  -- Held (paused) shifts must keep delivery mode so exitDeliveryMode does not
  -- abandon the assigned trailer/vehicle/parcels the player intends to resume.
  return state.shift ~= nil and (isOnShift() or state.shift.paused) and true or false
end

local function assignedIdSet()
  local set = {}
  local shift = state.shift
  if not shift then return set end
  for _, id in ipairs(shift.assignedCargoIds or {}) do
    set[id] = true
  end
  return set
end

local function cargoIsAssigned(cargo)
  if not cargo or not state.shift then return false end
  if state.shift.assignedContractId and cargo.data and cargo.data.materialContractId == state.shift.assignedContractId then
    return true
  end
  return assignedIdSet()[cargo.id] and true or false
end

facilityMatchesEmployer = function(facId)
  if not isEmployed() then return false end
  local fac = U.dGenerator() and U.dGenerator().getFacilityById and U.dGenerator().getFacilityById(facId)
  return fac and fac.associatedOrganization == state.employerOrgId
    and (fac.employmentCustomer ~= true or U.isRoleplayFacility(facId))
end

local function closeWorldPrompt()
  if gameplay_markerInteraction and gameplay_markerInteraction.closeViewDetailPrompt then
    gameplay_markerInteraction.closeViewDetailPrompt(true)
  end
end

local function pauseSim(paused)
  if simTimeAuthority and simTimeAuthority.pause then
    simTimeAuthority.pause(paused and true or false)
  end
end

local function changeToPlay()
  if guihooks then
    guihooks.trigger("ChangeState", { state = "play" })
  end
end

local function openShiftUi(facId)
  facId = facId or state.homeFacId
  local roleplay = facId and U.isRoleplayFacility(facId)
  if not roleplay then
    if not isEmploymentUnlocked() then
      ui_message("Company employment is not enabled for this career.", 6, "warning")
      return false
    end
    if not isEmployed() then return false end
    if facId and not facilityMatchesEmployer(facId) then
      facId = state.homeFacId
    end
  end
  if not facId then return false end
  if roleplay then
    U.roleplayPhoneFacId = facId
    U.roleplayPhonePosition = getPlayerVehicle(0) and getPlayerVehicle(0):getPosition()
    closeWorldPrompt()
    local function navigate()
      notifyUi()
      if gameplay_phone and gameplay_phone.openRoute then
        gameplay_phone.openRoute("phone-employment")
      elseif extensions and extensions.ui_router then
        extensions.ui_router.navigate("phone-employment")
      end
    end
    if core_jobsystem and core_jobsystem.create then
      core_jobsystem.create(function(job) job.sleep(0.2); navigate() end)
    else
      navigate()
    end
    return true
  end
  if tryReturnDropOffBeforeShiftUi and tryReturnDropOffBeforeShiftUi(facId) then
    return dropOffOpen and true or false
  end
  uiOpen = true
  closeWorldPrompt()
  pauseSim(true)
  if U.dGeneral() and U.dGeneral().refreshPoiCargoSnapshot then
    U.dGeneral().refreshPoiCargoSnapshot()
  end
  guihooks.trigger("ChangeState", { state = "career.employeeShift", params = { facilityId = facId } })
  return true
end

local function closeShiftUi()
  uiOpen = false
  shiftStartPresentationPending = false
  shiftStartPresentationReady = false
  pauseSim(false)
  changeToPlay()
  if gameplay_markerInteraction and gameplay_markerInteraction.setForceReevaluateOpenPrompt then
    gameplay_markerInteraction.setForceReevaluateOpenPrompt()
  end
end

local function onShiftRouteLeave()
  uiOpen = false
  shiftStartPresentationPending = false
  shiftStartPresentationReady = false
  pauseSim(false)
end

local function openDropOffUi(facId, psPath)
  dropOffOpen = true
  dropOffFacId, dropOffPsPath = facId, psPath
  lastDropOffProgress = nil
  lastDropOffParkingLevels = nil
  holdDropOffForProgress = false
  closeWorldPrompt()
  pauseSim(true)
  if U.dGeneral() and U.dGeneral().setDeliveryTimePaused then
    U.dGeneral().setDeliveryTimePaused(true)
  end
  guihooks.trigger("ChangeState", {
    state = "career.employeeDropOff",
    params = { facilityId = facId, parkingSpotPath = psPath },
  })
  return true
end

local function closeDropOffUi()
  if not dropOffOpen then return end
  local closedShift = state.shift
  dropOffOpen = false
  dropOffFacId, dropOffPsPath = nil, nil
  lastDropOffProgress = nil
  lastDropOffParkingLevels = nil
  holdDropOffForProgress = false
  if closedShift and isOnShift() and closedShift.phase == "loopComplete"
      and not closedShift.wrecked and not dropOffEscrowPending then
    if not uiOpen then openShiftUi(state.homeFacId or closedShift.originFacId) end
    return
  end
  pauseSim(false)
  if U.dGeneral() and U.dGeneral().setDeliveryTimePaused then
    U.dGeneral().setDeliveryTimePaused(false)
  end
  changeToPlay()
  if gameplay_markerInteraction and gameplay_markerInteraction.setForceReevaluateOpenPrompt then
    gameplay_markerInteraction.setForceReevaluateOpenPrompt(true)
  end
  if closedShift and core_jobsystem and core_jobsystem.create then
    core_jobsystem.create(function(job)
      job.sleep(0)
      local waited = 0
      while state.shift == closedShift and dropOffEscrowPending and waited < 10 do
        job.sleep(0.1)
        waited = waited + 0.1
      end
      if state.shift == closedShift and isOnShift()
          and closedShift.phase == "loopComplete" and not closedShift.wrecked
          and not uiOpen and not dropOffOpen then
        openShiftUi(state.homeFacId or closedShift.originFacId)
      end
    end)
  end
end

local function maybeKeepDropOffOpenForProgress()
  if dropOffOpen and (holdDropOffForProgress or lastDropOffProgress) then
    notifyUi()
    return true
  end
  return false
end

local function onDropOffRouteLeave()
  local completedShift = state.shift
  local openCompletedShift = completedShift and isOnShift()
    and completedShift.phase == "loopComplete" and not completedShift.wrecked
  dropOffOpen = false
  dropOffFacId, dropOffPsPath = nil, nil
  lastDropOffProgress = nil
  lastDropOffParkingLevels = nil
  holdDropOffForProgress = false
  if not uiOpen then pauseSim(false) end
  if U.dGeneral() and U.dGeneral().setDeliveryTimePaused then
    U.dGeneral().setDeliveryTimePaused(false)
  end
  if openCompletedShift then
    local function openAfterRouteLeave()
      if state.shift ~= completedShift or not isOnShift()
          or completedShift.phase ~= "loopComplete" or completedShift.wrecked
          or uiOpen or dropOffOpen then return end
      openShiftUi(state.homeFacId or completedShift.originFacId)
    end
    if core_jobsystem and core_jobsystem.create then
      core_jobsystem.create(function(job)
        job.sleep(0)
        openAfterRouteLeave()
      end)
    else
      openAfterRouteLeave()
    end
  end
end

U.issuedVehicleNeedsRepair = function()
  return U.dEmploymentEquipment().issuedVehicleNeedsRepair(U.equipmentContext())
end

U.collectCompanyInventoryIds = function()
  return U.dEmploymentEquipment().collectCompanyInventoryIds(U.equipmentContext())
end

local function deleteCargoOnCompanyVehicles()
  return U.dEmploymentEquipment().deleteCargoOnCompanyVehicles(U.equipmentContext())
end

local function deleteOrphanedVehicleCargo()
  return U.dEmploymentEquipment().deleteOrphanedVehicleCargo(U.equipmentContext())
end

local function returnIssuedVehicles()
  return U.dEmploymentEquipment().returnIssuedVehicles(U.equipmentContext())
end

-- Car jockeys drive the delivery car, not a company van. Other accepted
-- deliveries remain active when issuing the next company vehicle.
U.clearCompanyEquipmentThen = function(callback)
  return U.dEmploymentEquipment().clearCompanyEquipmentThen(U.equipmentContext(), callback)
end

U.handoffCompanyEquipmentThen = function(callback)
  return U.dEmploymentEquipment().handoffCompanyEquipmentThen(U.equipmentContext(), callback)
end

U.formatTodaysWagesMessage = function(total, wages, bonus, opts)
  wages = U.roundMoney(wages or total or 0)
  bonus = U.roundMoney(bonus or 0)
  total = U.roundMoney(total or (wages + bonus))
  if total <= 0 then
    if opts and opts.openEnded then
      return "Shift ended."
    end
    return "Shift ended. No wages held this shift."
  end
  if bonus > 0 then
    return string.format("Shift ended. Today's wages: $%d (includes $%d high-demand bonus).", total, bonus)
  end
  return string.format("Shift ended. Today's wages: $%d.", total)
end

U.dispatchSurgeLeaf = function(kind, cargoType)
  return U.dEmploymentDispatch().surgeLeaf(U.dispatchContext(), kind, cargoType)
end

U.isJobKindSurged = function(kind, cargoType)
  local heat = career_modules_activityHeat
  if not (heat and heat.getDemandFactor) then return false end
  local leaf = U.dispatchSurgeLeaf(kind, cargoType)
  if not leaf then return false end
  local factor = tonumber(heat.getDemandFactor(leaf)) or 1
  local threshold = tonumber(heat.HOT_THRESHOLD) or 1.10
  return factor >= threshold
end

U.maybeApplySurgeAssignmentBonus = function(shift)
  if not shift or not shift.surgeBonusEligible then return 0 end
  shift.surgeBonusEligible = nil
  local bonus = math.max(0, math.floor(tonumber(C.EMPLOYMENT_SURGE_BONUS_AMOUNT) or 0))
  if bonus <= 0 then return 0 end
  U.addEscrowKeep("High-demand assignment bonus", bonus, 0, "surgeBonus")
  ui_message(string.format("High-demand bonus: +$%d held with today's wages.", bonus), 6, "success")
  notifyUi()
  return bonus
end

local function escrowSurgeBonusTotal()
  local total = 0
  for _, leg in ipairs((state.escrow and state.escrow.legs) or {}) do
    if leg and leg.kind == "surgeBonus" then
      total = total + math.max(0, tonumber(leg.keep) or 0)
    end
  end
  return U.roundMoney(total)
end

local function payEscrow()
  local amount = U.reconcileEscrowMoney("payEscrow")
  local bonus = escrowSurgeBonusTotal()
  if amount > 0 then
    state.completedAssignments = (tonumber(state.completedAssignments) or 0) + 1
  end
  local total = amount
  if total > 0 and career_modules_playerAttributes and career_modules_playerAttributes.addAttributes then
    career_modules_playerAttributes.addAttributes({ money = total }, {
      tags = { "gameplay", "deliveryReward", "employment" },
      label = bonus > 0 and string.format("Today's wages + $%d high-demand bonus", bonus) or "Today's wages",
    })
  end
  U.resetEscrow()
  return total, math.max(0, amount - bonus), bonus
end

U.getDamageStrikeCount = function()
  state.damageRecord = state.damageRecord or { strikes = 0 }
  return math.max(0, math.floor(tonumber(state.damageRecord.strikes) or 0))
end

U.resetDamageStrikes = function()
  state.damageRecord = { strikes = 0 }
end

U.incrementDamageStrike = function()
  local strike = U.getDamageStrikeCount() + 1
  state.damageRecord = { strikes = strike }
  return strike
end

U.cancelEmploymentRepoJob = function()
  local repo = U.dRepo()
  if repo and repo.cancelEmploymentJob then
    repo.cancelEmploymentJob()
  end
end

local function terminateEmploymentForDamage()
  if state.shift then
    state.shift.pendingDamageTermination = true
    ui_message('Equipment damage deductions still apply. Finish or explicitly abandon the current assignment before employment ends.', 8, 'warning')
    return
  end
  local org = getOrg(state.employerOrgId)
  local orgName = getOrgDisplayName(org, state.employerOrgId)
  local shift = state.shift
  if shift and shift.jobKind == "materials" and U.dMaterials() and U.dMaterials().abandonContract then
    U.dMaterials().abandonContract(nil, { noFine = true, silent = true })
  end
  if shift and (shift.jobKind == "repo" or isBundleShift(shift)) then
    U.cancelEmploymentRepoJob()
  end
  if U.dGeneral() and U.dGeneral().isDeliveryModeActive and U.dGeneral().isDeliveryModeActive() then
    U.dGeneral().exitDeliveryMode()
  end
  state.ignoreCompanyDamageStrikes = true
  returnIssuedVehicles()
  U.emptyShift()
  U.resetEscrow()
  U.setRehireBlock(state.employerOrgId)
  U.clearEmploymentCache()
  U.flushEmploymentCache()
  U.resetDamageStrikes()
  firePhoneNotification(
    "employment.shiftEnded",
    "Terminated",
    string.format("%s let you go after repeated equipment damage. You cannot reapply for %d sim days.", orgName, C.REHIRE_COOLDOWN_DAYS),
    "error"
  )
  ui_message(string.format("%s terminated your employment after repeated equipment damage.", orgName), 8, "error")
  notifyUi()
end

U.fireEmploymentForInactivity = function(mapId, emp)
  if U.employmentShiftBlocksInactivity(mapId, emp) then return end
  local orgId = emp and emp.employerOrgId
  if not orgId then return end
  local org = getOrg(orgId)
  local orgName = getOrgDisplayName(org, orgId)
  local worked = (tonumber(emp.completedAssignments) or 0) > 0
  if worked then
    U.setRehireBlock(orgId)
  else
    U.clearRehireBlock(orgId)
  end
  state.employments[mapId] = nil
  if mapId == (state.activeMapId or U.currentMapId()) and state.employerOrgId == orgId then
    if state.shift and (state.shift.jobKind == "repo" or isBundleShift(state.shift)) then
      U.cancelEmploymentRepoJob()
    end
    if U.dGeneral() and U.dGeneral().isDeliveryModeActive and U.dGeneral().isDeliveryModeActive() then
      U.dGeneral().exitDeliveryMode()
    end
    returnIssuedVehicles()
    U.emptyShift()
    U.resetEscrow()
    U.clearEmploymentCache()
  end
  if worked then
    firePhoneNotification(
      "employment.shiftEnded",
      "Let go for inactivity",
      string.format("%s ended your employment — no company work in %d sim days. Reapply in %d sim days.",
        orgName, C.INACTIVITY_FIRE_DAYS, C.REHIRE_COOLDOWN_DAYS),
      "error"
    )
  else
    firePhoneNotification(
      "employment.shiftEnded",
      "Employment lapsed",
      string.format("%s dropped the hire — no shifts were started. You can apply again anytime.", orgName),
      "info"
    )
  end
  notifyUi()
end

U.checkEmploymentInactivity = function()
  local worldNow = U.nowWorldMinutes()
  if worldNow == nil then return end
  local now = U.nowSim()
  if now <= 0 then return end
  if (tonumber(state.nextEmploymentInactivityCheckAt) or 0) > now then return end
  state.nextEmploymentInactivityCheckAt = now + 1
  U.applyPendingLastWorkRefresh(worldNow)
  if state.shift then
    state.lastWorkAt = now
    state.lastWorkWorldMinute = worldNow
  end
  U.flushEmploymentCache()
  for mapId, emp in pairs(state.employments or {}) do
    if emp and emp.employerOrgId then
      if U.employmentShiftBlocksInactivity(mapId, emp) then
        emp.lastWorkAt = now
        emp.lastWorkWorldMinute = worldNow
        if mapId == (state.activeMapId or "") then
          state.lastWorkAt = now
          state.lastWorkWorldMinute = worldNow
        end
      else
        if not tonumber(emp.lastWorkWorldMinute) and not tonumber(emp.hiredWorldMinute) then
          emp.lastWorkWorldMinute = worldNow
          emp.hiredWorldMinute = worldNow
        end
        local lastWork = tonumber(emp.lastWorkWorldMinute or emp.hiredWorldMinute) or 0
        if lastWork > 0 and lastWork <= worldNow and (worldNow - lastWork) >= U.inactivityFireWorldMinutes() then
          U.fireEmploymentForInactivity(mapId, emp)
        end
      end
    end
  end
end

local function handleCompanyVehicleDamaged()
  if not state.shift then return end
  if U.isRoleplayProfile(state.shift.jobKind) then
    return
  end
  local strike = U.incrementDamageStrike()
  if strike <= C.DAMAGE_STRIKE_WARN_COUNT then
    if strike == 1 then
      U.recordEscrowLeg("Equipment damage warning", 0, 0, 0, "damageWarning")
      ui_message("Be careful with the equipment or we will have to dock you.", 8, "warning")
    else
      U.recordEscrowLeg("Final equipment damage warning", 0, 0, 0, "damageWarning")
      ui_message("Final warning: the next damaged return comes out of your held pay.", 8, "warning")
    end
  elseif strike <= (C.DAMAGE_STRIKE_WARN_COUNT + C.DAMAGE_STRIKE_DOCK_COUNT) then
    local dock = U.roundMoney(math.max(0, (state.escrow.money or 0) * C.DAMAGE_STRIKE_DOCK_PERCENT))
    if dock > 0 then
      state.escrow.money = math.max(0, U.roundMoney((state.escrow.money or 0) - dock))
      U.recordEscrowLeg("Equipment damage dock", dock, -dock, 0, "damageDock")
      U.reconcileEscrowMoney("damageDock")
    else
      U.recordEscrowLeg("Equipment damage dock (no held pay)", 0, 0, 0, "damageDock")
    end
    ui_message(
      string.format("Equipment damage: $%d withheld from held pay%s.", dock, strike >= (C.DAMAGE_STRIKE_WARN_COUNT + C.DAMAGE_STRIKE_DOCK_COUNT) and " — one more incident and you're fired" or ""),
      8,
      "warning"
    )
  else
    terminateEmploymentForDamage()
    return
  end
  notifyUi()
end

U.assessCompanyDamageBeforePayout = function()
  if not career_modules_insurance_insurance then return end
  for _, inventoryId in ipairs(U.collectCompanyInventoryIds()) do
    if career_modules_insurance_insurance.inventoryVehNeedsRepair(inventoryId) then
      handleCompanyVehicleDamaged()
      break
    end
  end
end

U.cargoMatchesEmployerOrg = function(cargo)
  if not cargo or not state.employerOrgId then return false end
  if cargo.organization and cargo.organization == state.employerOrgId then return true end
  for orgId, _ in pairs(cargo.loanerOrganisations or {}) do
    if orgId == state.employerOrgId then return true end
  end
  local facId = (cargo.origin and cargo.origin.facId) or (cargo.location and cargo.location.facId)
  return facId and facilityMatchesEmployer(facId) or false
end

U.offerMatchesEmployerOrg = function(offer)
  if not offer or not state.employerOrgId then return false end
  if offer.organization and offer.organization == state.employerOrgId then return true end
  local facId = offer.origin and offer.origin.facId
  return facId and facilityMatchesEmployer(facId) or false
end

U.dropOffAssignedToShift = function(dropOffData)
  local shift = state.shift
  if not shift then return false end
  if shift.jobKind == "materials" then return true end
  local offerIds = shiftVehicleOfferIdSet(shift)
  for _, cargo in ipairs((dropOffData and dropOffData.cargo) or {}) do
    if cargoIsAssigned(cargo) then return true end
  end
  if next(offerIds) then
    for _, offerData in ipairs((dropOffData and dropOffData.offers) or {}) do
      local offer = offerData.offer or offerData
      if offer and offer.id and offerIds[offer.id] then return true end
    end
  end
  return false
end

U.dropOffMatchesEmployerOrg = function(dropOffData)
  if not isOnShift() or not state.employerOrgId then return false end
  for _, cargo in ipairs((dropOffData and dropOffData.cargo) or {}) do
    if U.cargoMatchesEmployerOrg(cargo) then return true end
  end
  for _, offerData in ipairs((dropOffData and dropOffData.offers) or {}) do
    if U.offerMatchesEmployerOrg(offerData.offer or offerData) then return true end
  end
  return false
end

U.vanillaDeliveryDamageMoney = function(dropOffData)
  local total, label = 0, nil
  for _, offerData in ipairs((dropOffData and dropOffData.offers) or {}) do
    for _, bd in ipairs(offerData.breakdown or {}) do
      if bd and (bd.label == "Slight Damage" or bd.label == "Excessive Damage") then
        local money = tonumber(bd.rewards and bd.rewards.money) or 0
        if money < 0 then
          total = total + money
          if bd.label == "Excessive Damage" or not label then
            label = bd.label
          end
        end
      end
    end
  end
  return total, label or "Cargo damage"
end

local function consumeDropOffMoneyForEscrow(rewardSum, dropOffData)
  if type(rewardSum) ~= "table" or not state.shift then
    dropOffEscrowPending = false
    return rewardSum
  end
  local shift = state.shift
  local outboundDelivery = (shift.jobKind == "trailer" or shift.jobKind == "parcel")
    and shift.phase == "outbound"
  local assignedBelongs = U.dropOffAssignedToShift(dropOffData)
  local orgBelongs = U.dropOffMatchesEmployerOrg(dropOffData)
  if not assignedBelongs and not orgBelongs then
    dropOffEscrowPending = false
    notifyUi()
    return rewardSum
  end

  if shift.paused then
    shift.paused = false
    if U.dGeneral() and U.dGeneral().startDeliveryMode then
      U.dGeneral().startDeliveryMode()
    end
  end

  local share = U.getCompanyShare()
  local gross = tonumber(rewardSum.money) or 0
  local damageMoney, damageLabel = U.vanillaDeliveryDamageMoney(dropOffData)
  local deliveryGross = gross - damageMoney
  if deliveryGross ~= 0 then
    local keep = U.addEscrowKeep("Delivery", deliveryGross, share, "delivery")
    local total = U.reconcileEscrowMoney("afterDropOffAdd")
    if not shift.stringMode and keep > 0 and damageMoney >= 0 then
      ui_message(string.format("+$%d to today's held wages ($%d total).", keep, total), 5, "info")
    end
  end
  if damageMoney < 0 then
    local dockKeep = U.addEscrowKeep(damageLabel, damageMoney, share, "cargoDamage")
    local total = U.reconcileEscrowMoney("afterDropOffDamage")
    ui_message(string.format("%s: $%d withheld from held pay ($%d remaining).", damageLabel, math.abs(dockKeep), total), 8, "warning")
  end
  rewardSum.money = 0
  if assignedBelongs then
    U.maybeApplySurgeAssignmentBonus(shift)
    if isBundleShift(shift) then
      if shift.assignments and shift.assignments.vehicle and not shift.assignments.vehicle.complete then
        shift.assignments.vehicle.complete = true
        ui_message("Car hauling assignment complete.", 6, "success")
        if shift.assignments.repo and not shift.assignments.repo.complete then
          U.beginBundleRepoLeg()
        else
          maybeCompleteBundleShift()
        end
      elseif shift.assignments and shift.assignments.repo and not shift.assignments.repo.complete then
        shift.assignments.repo.complete = true
        ui_message("Car hauling complete.", 6, "success")
        maybeCompleteBundleShift({ atYard = true })
      end
    elseif shift.jobKind ~= "materials" then
      if isDistributorHaulShift(shift) and shift.phase == "outbound" then
        shift.deliveredOfferIds = shift.deliveredOfferIds or {}
        local known = {}
        for _, id in ipairs(shift.deliveredOfferIds) do known[id] = true end
        for _, offerData in ipairs((dropOffData and dropOffData.offers) or {}) do
          local offer = offerData.offer or offerData
          if offer and offer.id and shiftVehicleOfferIdSet(shift)[offer.id] and not known[offer.id] then
            table.insert(shift.deliveredOfferIds, offer.id)
            known[offer.id] = true
          end
        end
        local remaining = distributorHaulRemaining(shift)
        if remaining > 0 then
          ui_message(string.format("%d vehicle%s left on this haul.", remaining, remaining == 1 and "" or "s"), 6, "info")
          routeCurrentAssignment()
          refreshTaskGuidance(true)
        else
          afterOutboundDelivered()
        end
      elseif shift.phase == "outbound" then
        U.pruneDeliveredStringCargo(shift, dropOffData)
        afterOutboundDelivered()
      elseif shift.phase == "return" then
        afterReturnDelivered()
      end
    end
  end
  dropOffEscrowPending = false
  U.reconcileEscrowMoney("afterDropOff")
  U.flushEmploymentCache()
  notifyUi()
  if outboundDelivery and state.shift == shift
      and (shift.phase == "return" or shift.phase == "loopComplete") and dropOffOpen then
    closeDropOffUi()
  end
  return rewardSum
end

U.cargoDestinationMatchesSpot = function(cargo, facId, psPath)
  if not cargo or not facId or not psPath then return false end
  local dest = cargo.destination
  if not dest then return false end
  if dest.type == "facilityParkingspot" then
    return dest.facId == facId and dest.psPath == psPath
  end
  if dest.type == "multi" then
    for _, d in ipairs(dest.destinations or {}) do
      if d and d.facId == facId and d.psPath == psPath then return true end
    end
  end
  return false
end

local function canMoveCargoOntoLocation(cargoId, targetLocation)
  if type(targetLocation) ~= "table" then return true end
  local parcelMgr = U.dParcel()
  local cargo = parcelMgr and parcelMgr.getCargoById and parcelMgr.getCargoById(cargoId)
  if targetLocation.type == "facilityParkingspot" then
    if not U.hasCompanyShift() then return true end
    return false
  end
  if not targetLocation.vehId then return true end
  if not career_modules_inventory then return true end
  local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(targetLocation.vehId)
  local vehInfo = inventoryId and career_modules_inventory.getVehicles()[inventoryId]
  if not (vehInfo and vehInfo.loanType == "company") then return true end
  if not isOnShift() then return false end
  return cargoIsAssigned(cargo)
end

local function gatherAssignedDropOffs(facId, psPath)
  local confirmedCargoIds, confirmedOfferIds = {}, {}
  local shift = state.shift
  if shift and shift.jobKind == "parcel"
      and ((shift.phase == "outbound" and shift.needsRemotePickup)
        or (shift.phase == "return" and shift.returnNeedsPickup)
        or shift.dropOffDepartureRequired) then
    return confirmedCargoIds, confirmedOfferIds
  end
  local parcelMgr = U.dParcel()
  if parcelMgr and parcelMgr.getAllCargoInVehicles then
    for _, cargo in ipairs(parcelMgr.getAllCargoInVehicles(true) or {}) do
      if ((cargo.location and cargo.location.type == "vehicle")
          or (cargo._transientMove and cargo._transientMove.targetLocation
            and cargo._transientMove.targetLocation.type == "vehicle"))
          and cargoIsAssigned(cargo) and U.cargoDestinationMatchesSpot(cargo, facId, psPath) then
        table.insert(confirmedCargoIds, { id = cargo.id, ids = { cargo.id }, amount = cargo.slots })
      end
    end
  end
  if state.shift and career_modules_delivery_vehicleTasks then
    local tasks = career_modules_delivery_vehicleTasks.getVehicleTasks and career_modules_delivery_vehicleTasks.getVehicleTasks() or {}
    local assigned = shiftVehicleOfferIdSet(state.shift)
    for _, taskData in ipairs(tasks) do
      local offer = taskData.offer
      local activeTask = taskData.tasks and taskData.tasks[taskData.activeTaskIndex]
      local destination = activeTask and activeTask.destination
        or (offer and (offer.destination or (offer.task and offer.task.destination)))
      local missingVehicle = taskData.logisticsPending
        or not (taskData.vehId and getObjectByID(taskData.vehId))
      local readyToDropOff = activeTask and (activeTask.type == "confirmDropOff"
        or (missingVehicle and (tonumber(taskData.activeTaskIndex) or 0) > 1
          and activeTask.type == "bringToDestination"))
      if offer and offer.id and assigned[offer.id] and readyToDropOff then
        if destination and destination.psPath == psPath
            and (not destination.facId or destination.facId == facId) then
          table.insert(confirmedOfferIds, offer.id)
        end
      end
    end
  end
  return confirmedCargoIds, confirmedOfferIds
end

local function hasAssignedDropOffHere(facId, psPath)
  local cargoIds, offerIds = gatherAssignedDropOffs(facId, psPath)
  return next(cargoIds) ~= nil or next(offerIds) ~= nil
end

U.getDropOffParkingLevels = function(facId, psPath)
  if not facId or not psPath then return nil end
  local gen = U.dGenerator()
  local precision = career_modules_delivery_precisionParking
  local spot = gen and gen.getParkingSpotByPath and gen.getParkingSpotByPath(psPath)
  if not (spot and precision and precision.calculateVehiclePrecisionScore) then return nil end

  local cargoIds, offerIds = gatherAssignedDropOffs(facId, psPath)
  local levels, seen = {}, {}
  local function addVehicle(vehId)
    if not (vehId and getObjectByID(vehId)) then return end
    local score = precision.calculateVehiclePrecisionScore(vehId, spot)
    local level = score and score.precisionLevel
    if level and not seen[level] then
      levels[#levels + 1] = level
      seen[level] = true
    end
  end

  if #offerIds > 0 then
    local assigned = {}
    for _, id in ipairs(offerIds) do assigned[id] = true end
    local tasks = career_modules_delivery_vehicleTasks.getVehicleTasks() or {}
    for _, task in ipairs(tasks) do
      local activeTask = task.tasks and task.tasks[task.activeTaskIndex]
      local destination = activeTask and activeTask.destination
      if task.offer and assigned[task.offer.id] and destination
          and destination.psPath == psPath then
        addVehicle(task.vehId)
      end
    end
  end

  if #cargoIds > 0 then
    local parcelMgr = U.dParcel()
    for _, elem in ipairs(cargoIds) do
      local cargo = parcelMgr and parcelMgr.getCargoById and parcelMgr.getCargoById(elem.id)
      if cargo and cargo.destination and cargo.destination.psPath == psPath then
        addVehicle(be:getPlayerVehicleID(0))
        break
      end
    end
  end

  return #levels > 0 and levels or nil
end

local function hasOutstandingReturnWork(shift)
  if not shift or shift.phase ~= "return" then return false end
  if shift.returnNeedsPickup then return true end
  if shift.assignedOfferId then return true end
  local parcelMgr = U.dParcel()
  for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
    local cargo = parcelMgr and parcelMgr.getCargoById and parcelMgr.getCargoById(cargoId)
    if cargo then return true end
  end
  return false
end

-- true = handled (drop-off opened or routed); false = open shift UI as normal
tryReturnDropOffBeforeShiftUi = function(facId)
  local shift = state.shift
  if not shift or shift.paused then
    return false
  end
  if shift.jobKind == "parcel" and shift.phase == "outbound" then
    local destFac = shift.destFacId
    local destPs = shift.destPsPath
    if facId == destFac and destPs and hasAssignedDropOffHere(destFac, destPs) then
      openDropOffUi(destFac, destPs)
      return true
    end
    return false
  end
  if shift.phase ~= "return" or not shift.returnIsBackhaul then return false end
  if not (U.assignedReturnCargoInVehicle(shift) or hasOutstandingReturnWork(shift)) then
    return false
  end
  local destFac = shift.destFacId
  local destPs = shift.destPsPath
  if not destFac or not destPs then return false end
  if hasAssignedDropOffHere(destFac, destPs) then
    openDropOffUi(destFac, destPs)
    return true
  end
  return false
end

local function shouldOpenEmployeeDropOff(facId, psPath)
  if not isOnShift() then return false end
  local shift = state.shift
  if shift.jobKind == "materials" then
    local active = U.dMaterials() and U.dMaterials().getActiveContract and U.dMaterials().getActiveContract()
    if active and active.status == "active" then
      return false
    end
  end
  return hasAssignedDropOffHere(facId, psPath)
end

afterOutboundDelivered = function()
  local shift = state.shift
  if not shift or shift.phase ~= "outbound" then return end
  if shift.jobKind == "materials" then
    if materialsAssignmentHasWork() then
      shift.phase = "outbound"
      refreshTaskGuidance(true)
      notifyUi()
      return
    end
    beginYardReturnForLoopChoice()
    return
  end
  if U.isOpenEndedJobKind(shift.jobKind) then
    -- Repo / roleplay finish at the yard (or open-ended site); prompt, do not auto-dispatch.
    offerLoopCompleteChoice({
      label = "Assignment complete",
      subtext = "Take another job or end your day",
    })
    return
  end
  if shift.jobKind == "vehicle" then
    if isDistributorHaulShift(shift) then
      shift.phase = "return"
      shift.returnIsBackhaul = nil
      shift.returnNeedsPickup = nil
      shift.assignedOfferId = nil
      shift.assignedOfferIds = nil
      shift.awaitingLoopChoice = true
      shift.returnLabel = "Return the company vehicle to the office"
      shift.returnDeliverLabel = nil
      shift.returnSubtext = "No return freight — head back to the yard"
      shift.destFacId = state.homeFacId
      shift.destLocation = nil
      shift.destPsPath = nil
      routeToYard()
      refreshTaskGuidance(true)
      notifyUi()
      if dropOffOpen and not maybeKeepDropOffOpenForProgress() then
        closeDropOffUi()
      end
      return
    end
    -- Drive-off vehicle work gets a return vehicle when the destination has one.
    shift.phase = "return"
    assignReturnLoad(shift.destFacId)
    trySetShiftRoute()
    refreshTaskGuidance(true)
    notifyUi()
    if dropOffOpen and not maybeKeepDropOffOpenForProgress() then
      closeDropOffUi()
    end
    return
  end
  if shift.stringMode and shift.stops then
    local hadRemainingHere = U.stringCurrentStopHasRemaining(shift)
    if hadRemainingHere then
      U.applyParcelStringStop(shift, shift.stopIndex or 1)
      refreshTaskGuidance(true)
      notifyUi()
      refreshDeliveryPois()
      return
    end
    shift.stopsCompleted = (tonumber(shift.stopsCompleted) or 0) + 1
    if U.advanceParcelStringStop(shift) then
      routeCurrentAssignment()
      refreshTaskGuidance(true)
      notifyUi()
      refreshDeliveryPois()
      if dropOffOpen and not maybeKeepDropOffOpenForProgress() then
        closeDropOffUi()
      end
      return
    end
    if U.planParcelStringFromTruck(shift, shift.destLocation or shift.destFacId) then
      routeCurrentAssignment()
      refreshTaskGuidance(true)
      notifyUi()
      refreshDeliveryPois()
      if dropOffOpen and not maybeKeepDropOffOpenForProgress() then
        closeDropOffUi()
      end
      return
    end
    if facilityMatchesEmployer(shift.destFacId) or facilityMatchesEmployer(dropOffFacId) or playerNearHomeYard() then
      offerLoopCompleteChoice({
        label = "Loop complete",
        subtext = "Take another job or end your day",
      })
      return
    end
    shift.phase = "return"
    shift.returnIsBackhaul = nil
    shift.returnNeedsPickup = nil
    shift.assignedCargoIds = {}
    shift.destFacId = state.homeFacId
    shift.destLocation = nil
    shift.destPsPath = nil
    shift.returnLabel = "Return to the company yard"
    shift.returnSubtext = "Empty return — take another string or end your day"
    trySetShiftRoute()
    refreshTaskGuidance(true)
    notifyUi()
    refreshDeliveryPois()
    if dropOffOpen and not maybeKeepDropOffOpenForProgress() then
      closeDropOffUi()
    end
    return
  end
  -- Parcel / trailer: enter return (backhaul) automatically — no player choice.
  shift.phase = "return"
  shift.returnLabel = shift.returnLabel or "Pick up the return load, then drive to the yard"
  assignReturnLoad(shift.destFacId)
  trySetShiftRoute()
  refreshTaskGuidance(true)
  notifyUi()
  if dropOffOpen and not maybeKeepDropOffOpenForProgress() then
    closeDropOffUi()
  end
end

afterReturnDelivered = function()
  local shift = state.shift
  if not shift then return end
  if shift.phase == "loopComplete" then return end
  if shift.phase ~= "return" then return end
  shift.awaitingLoopChoice = nil
  -- Back at yard (return drop-off / empty yard arrival): prompt, never auto-assign.
  offerLoopCompleteChoice({
    label = "Loop complete",
    subtext = "Take another job or end your day",
  })
end

afterCompanyDropOff = function()
  if not isOnShift() then return end
  local shift = state.shift
  if shift.phase == "loopComplete" and not shift.wrecked then
    if not dropOffOpen and not uiOpen then
      openShiftUi(state.homeFacId or shift.originFacId)
    else
      notifyUi()
    end
    return
  end
  local mgr = U.dMaterials()
  local active = mgr and mgr.getActiveContract and mgr.getActiveContract()
  if shift.jobKind == "materials" and materialsAssignmentHasWork() then
    if mgr.refreshTaskGuidance then mgr.refreshTaskGuidance(true) end
    local remaining = math.max(0, tonumber(active.remainingAmount) or 0)
    local delivered = math.max(0, tonumber(active.deliveredAmount) or 0)
    local units = active.units or "L"
    local cs = U.dCargoScreen()
    if (active.inTransitAmount or 0) > 0 then
      if cs and cs.setMaterialContractDestinationRoute then
        cs.setMaterialContractDestinationRoute(false)
      end
    elseif (active.loadableAmount or 0) > 0 then
      if cs and cs.setMaterialContractPickupRoute then
        cs.setMaterialContractPickupRoute(false)
      else
        routeToYard()
      end
    else
      routeToYard()
    end
    if U.dGeneral() and U.dGeneral().requestUpdateContainerWeights then
      U.dGeneral().requestUpdateContainerWeights()
      if U.dGeneral().updateContainerWeights then
        U.dGeneral().updateContainerWeights()
      end
    end
    ui_message(string.format("Delivered %d %s · %d %s remaining. Return to the yard.", math.floor(delivered + 0.5), units, math.floor(remaining + 0.5), units), 7, "info")
    refreshDeliveryPois()
    notifyUi()
    return
  end
  if shift.jobKind == "materials" and shift.phase == "outbound" then
    afterOutboundDelivered()
    return
  end
  -- Prefer shift-owned nav (return pickup / loopComplete yard). When that
  -- declines (outbound or intermediate backhaul), route the assignment dest —
  -- never force the inspect pad and clobber a loaded delivery pin.
  -- Defer one tick: finishing the outbound trailer task calls navigateToActiveTasks
  -- with no targets and clears the path we just set.
  local function applyPostDropOffRoute()
    if not isOnShift() then return end
    if not trySetShiftRoute() then
      routeCurrentAssignment()
    end
    refreshTaskGuidance(true)
    notifyUi()
  end
  if core_jobsystem and core_jobsystem.create then
    core_jobsystem.create(function(job)
      job.sleep(0)
      applyPostDropOffRoute()
    end)
  else
    applyPostDropOffRoute()
  end
end

trySetShiftRoute = function()
  if not isOnShift() then return false end
  local shift = state.shift
  if shift.awaitingPark then
    return routeToParkStall()
  end
  if shift.jobKind == "materials" then
    local active = U.dMaterials() and U.dMaterials().getActiveContract and U.dMaterials().getActiveContract()
    if active and active.status == "active" then
      return false
    end
  end
  if shift.phase == "return" then
    -- Still need to collect return freight at another yard — pin that pickup, not the office.
    if shift.returnNeedsPickup and not U.assignedReturnCargoInVehicle(shift) then
      return routeToReturnPickup()
    end
    if U.assignedReturnCargoInVehicle(shift) then
      shift.returnNeedsPickup = nil
    end
    -- Backhaul drop-off pad (including home-yard trailer/parcel dest) — never the inspect stall.
    if shift.returnIsBackhaul then
      local loc = shift.destLocation
      if not loc and shift.destFacId then
        loc = { type = "facilityParkingspot", facId = shift.destFacId, psPath = shift.destPsPath }
      end
      if loc and routeToLocation(loc) then
        refreshDeliveryPois()
        return true
      end
    end
    -- Empty yard return / no dest pad.
    return routeToYard()
  end
  if shift.phase == "loopComplete" or shift.wrecked then
    return routeToYard()
  end
  if shift.jobKind == "parcel" and shift.phase == "outbound" then
    local loc = shift.destLocation
    if not loc and shift.destFacId then
      loc = { type = "facilityParkingspot", facId = shift.destFacId, psPath = shift.destPsPath }
    end
    if loc and routeToLocation(loc) then
      refreshDeliveryPois()
      return true
    end
  end
  return false
end

local function confirmEmployeeDropOff(facId, psPath)
  if not isOnShift() then return false end
  if dropOffEscrowPending then
    ui_message("Still confirming the last drop-off — wait a moment.", 5, "info")
    return false
  end
  local cargoIds, offerIds = gatherAssignedDropOffs(facId, psPath)
  if next(cargoIds) or next(offerIds) then
    local progress = career_modules_delivery_progress
    if not (progress and progress.confirmDropOffData) then return false end
    lastDropOffParkingLevels = U.getDropOffParkingLevels(facId, psPath)
    dropOffEscrowPending = true
    holdDropOffForProgress = dropOffOpen
    local shift = state.shift
    local atDropOff = U.playerNearLocation({ type = "facilityParkingspot", facId = facId, psPath = psPath }, 8)
    local result = progress.confirmDropOffData({
      confirmedCargoIds = cargoIds,
      confirmedOfferIds = offerIds,
    }, facId, psPath, function(cargo)
      local recoverable = cargo.logisticsPending
        or (cargo.location and cargo._transientMove and cargo._transientMove.targetLocation
          and cargo._transientMove.targetLocation.type == "vehicle")
      return atDropOff and state.shift == shift and recoverable
        and cargoIsAssigned(cargo) and U.cargoDestinationMatchesSpot(cargo, facId, psPath)
    end, atDropOff and { facId = facId, psPath = psPath } or nil)
    if result == false then
      dropOffEscrowPending = false
      holdDropOffForProgress = false
      notifyUi()
      return false
    end
    notifyUi()
    return true
  end
  local shift = state.shift
  if not shift then return false end
  if shift.phase == "loopComplete" or shift.awaitingLoopChoice then
    afterReturnDelivered()
    return true
  end
  if shift.phase == "return" and facilityMatchesEmployer(facId) and not hasOutstandingReturnWork(shift) then
    afterReturnDelivered()
    return true
  end
  return false
end

local function tryAutoDropOffAssigned(facId, psPath)
  return false
end

local function cargoHasTimedModifier(item)
  if not item then return false end
  if not (item.modifiers and item.modifiers[1]) then
    local gen = U.dGenerator()
    if gen and gen.finalizeParcelItemDistanceAndRewards then
      local savedRewards = item.rewards
      item.rewards = nil
      gen.finalizeParcelItemDistanceAndRewards(item)
      if not item.rewards and savedRewards then
        item.rewards = savedRewards
      end
    end
  end
  return U.dSharedParcelMods().hasModifier(item, "timed")
end
U.cargoHasTimedModifier = cargoHasTimedModifier

U.purgeTimedParcelsFromShift = function(shift)
  if not shift then return end
  local parcelMgr = U.dParcel()
  local keep, keepSet = {}, {}
  for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
    local cargo = parcelMgr and parcelMgr.getCargoById and parcelMgr.getCargoById(cargoId)
    if cargo and not cargoHasTimedModifier(cargo) then
      table.insert(keep, cargoId)
      keepSet[cargoId] = true
    elseif cargo and cargo.location and cargo.location.type == "vehicle" and shift.originLocation and parcelMgr.changeCargoLocation then
      parcelMgr.changeCargoLocation(cargoId, shift.originLocation)
    end
  end
  shift.assignedCargoIds = keep
  if shift.stringCargoIds then
    local sc = {}
    for _, cargoId in ipairs(shift.stringCargoIds) do
      if keepSet[cargoId] then table.insert(sc, cargoId) end
    end
    shift.stringCargoIds = sc
  end
  shift.stops = {}
  shift.stopIndex = 1
  shift.stopsCompleted = 0
  shift.stringStopTotal = nil
  shift.stringRouteLocked = nil
end

U.rebuildStringFromFinalTruckLoad = function(shift)
  if not (shift and shift.stringMode) then return false end
  U.purgeTimedParcelsFromShift(shift)
  return U.planParcelStringFromTruck(shift, shift.originLocation or shift.originFacId)
end

local function countAssignedParcelsOnTruck(shift)
  local parcelMgr = U.dParcel()
  if not (shift and parcelMgr and parcelMgr.getCargoById) then return 0 end
  local n = 0
  for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
    local cargo = parcelMgr.getCargoById(cargoId)
    if cargo and cargo.location and cargo.location.type == "vehicle" and not cargoHasTimedModifier(cargo) then
      n = n + 1
    end
  end
  return n
end

local function collectParcelGroups(facId, towardHomeOnly)
  return U.dEmploymentDispatch().collectParcelGroups(U.dispatchContext(), facId, towardHomeOnly)
end

U.forceTriggerParcelGeneratorsAtFacility = function(facId)
  local gen = U.dGenerator()
  local fac = gen and gen.getFacilityById and gen.getFacilityById(facId)
  if not (gen and fac and gen.triggerGenerator) then return end
  for _, generator in ipairs(fac.logisticGenerators or {}) do
    if generator.type == "parcelProvider" or generator.type == "parcelReceiver" then
      gen.triggerGenerator(fac, generator)
    end
  end
end

U.ensureParcelGroupsAtFacility = function(facId)
  local groups = collectParcelGroups(facId, false)
  if groups[1] then return groups end
  for _ = 1, 6 do
    U.forceTriggerParcelGeneratorsAtFacility(facId)
    groups = collectParcelGroups(facId, false)
    if groups[1] then return groups end
  end
  return groups
end

local function pickReturnParcelGroup(fromFacId)
  return U.dEmploymentDispatch().pickReturnParcelGroup(U.dispatchContext(), fromFacId)
end

local function pickReturnTrailerOffer(fromFacId)
  return U.dEmploymentDispatch().pickReturnTrailerOffer(U.dispatchContext(), fromFacId)
end

U.pickReturnVehicleOffer = function(fromFacId, excludedOfferIds)
  return U.dEmploymentDispatch().pickReturnVehicleOffer(U.dispatchContext(), fromFacId, excludedOfferIds)
end

U.pickHaulBackhaulVehicleOffer = function(fromFacId, excludedOfferIds)
  return U.dEmploymentDispatch().pickHaulBackhaulVehicleOffer(U.dispatchContext(), fromFacId, excludedOfferIds)
end

U.assignVehicleBackhaulOffer = function(vehicleOffer, fromFacId)
  local shift = state.shift
  if not (shift and vehicleOffer) then return false end
  local dest = vehicleOffer.destination or (vehicleOffer.locations and vehicleOffer.locations[2])
  local pickupFacId = (vehicleOffer.origin and vehicleOffer.origin.facId)
    or (vehicleOffer.locations and vehicleOffer.locations[1] and vehicleOffer.locations[1].facId)
    or fromFacId
  shift.assignedOfferId = vehicleOffer.id
  shift.assignedOfferIds = nil
  shift.returnIsBackhaul = true
  shift.destFacId = dest and dest.facId
  shift.destPsPath = dest and dest.psPath
  shift.destLocation = dest
  shift.originLocation = vehicleOffer.spawnLocation
    or vehicleOffer.origin
    or (vehicleOffer.locations and vehicleOffer.locations[1])
    or { type = "facilityParkingspot", facId = pickupFacId }
  shift.returnPickupFacId = pickupFacId
  shift.returnNeedsPickup = true
  shift.returnLabel = string.format("Pick up return vehicle at %s", U.describeFacilityName(pickupFacId))
  shift.returnDeliverLabel = string.format("Deliver return vehicle to %s", U.describeFacilityName(dest and dest.facId))
  shift.returnSubtext = vehicleOffer.name or "Return vehicle"
  local now = (U.dGeneral() and U.dGeneral().time and U.dGeneral().time()) or 0
  vehicleOffer.offerExpiresAt = math.max(tonumber(vehicleOffer.offerExpiresAt) or 0, now + 3600)
  if pickupFacId ~= fromFacId then
    routeToReturnPickup()
  end
  if U.trySpawnAssignedReturnVehicle then U.trySpawnAssignedReturnVehicle() end
  return true
end

assignReturnLoad = function(fromFacId, opts)
  local shift = state.shift
  if not shift or shift.jobKind == "materials" or shift.wrecked then return false end
  opts = type(opts) == "table" and opts or {}
  fromFacId = fromFacId or shift.destFacId or state.homeFacId
  if shift.jobKind == "vehicle" and not opts.retryVehicle then
    shift.returnVehicleAttemptedOfferIds = {}
    shift.returnVehicleOffersRescanned = nil
  end
  shift.returnIsBackhaul = nil
  shift.assignedOfferId = nil
  shift.assignedCargoIds = {}
  shift.returnNeedsPickup = nil
  shift.returnPickupFacId = nil
  shift.returnDeliverLabel = nil
  shift._returnTrailerSpawning = nil
  shift._returnTrailerSpawned = nil
  shift._returnVehicleSpawning = nil
  shift._returnVehicleSpawned = nil

  local function assignEmptyYardReturn()
    shift.returnIsBackhaul = nil
    shift.awaitingLoopChoice = true
    shift.returnLabel = "Return the company vehicle to the office"
    shift.returnDeliverLabel = nil
    shift.returnSubtext = "No matching return freight — head back to the yard"
    shift.destFacId = state.homeFacId
    shift.destLocation = nil
    shift.destPsPath = nil
    shift.assignedOfferId = nil
    shift.returnNeedsPickup = nil
    shift.returnPickupFacId = nil
    shift._returnTrailerSpawning = nil
    shift._returnTrailerSpawned = nil
    routeToYard()
    return false
  end

  local function assignParcelBackhaul(parcelGroup)
    local now = (U.dGeneral() and U.dGeneral().time and U.dGeneral().time()) or 0
    for _, item in ipairs(parcelGroup.items) do
      item.offerExpiresAt = math.max(tonumber(item.offerExpiresAt) or 0, now + 3600)
      table.insert(shift.assignedCargoIds, item.id)
    end
    shift.returnIsBackhaul = true
    shift.dropOffDepartureRequired = true
    shift.destFacId = parcelGroup.destination and parcelGroup.destination.facId
    shift.destPsPath = parcelGroup.destination and parcelGroup.destination.psPath
    shift.destLocation = parcelGroup.destination
    local pickupFacId = parcelGroup.facId
      or (parcelGroup.items[1] and parcelGroup.items[1].origin and parcelGroup.items[1].origin.facId)
      or fromFacId
    shift.originLocation = parcelGroup.items[1] and parcelGroup.items[1].origin
      or { type = "facilityParkingspot", facId = pickupFacId }
    local pickLabel, deliverLabel, subtext = U.formatReturnParcelGuidance(
      pickupFacId, parcelGroup.destination, #shift.assignedCargoIds, fromFacId)
    shift.returnLabel = pickLabel
    shift.returnDeliverLabel = deliverLabel
    shift.returnSubtext = subtext
    shift.returnPickupFacId = pickupFacId
    if pickupFacId == fromFacId then
      bindAssignedCargoToIssuedTruck()
    else
      shift.returnNeedsPickup = true
      U.stageAssignedReturnPickup()
      routeToReturnPickup()
    end
    return true
  end

  local function assignTrailerBackhaul(trailerOffer)
    local dest = trailerOffer.destination or (trailerOffer.locations and trailerOffer.locations[2])
    shift.assignedOfferId = trailerOffer.id
    shift.returnIsBackhaul = true
    shift.destFacId = dest and dest.facId
    shift.destPsPath = dest and dest.psPath
    shift.destLocation = dest
    local pickupFacId = (trailerOffer.origin and trailerOffer.origin.facId)
      or (trailerOffer.locations and trailerOffer.locations[1] and trailerOffer.locations[1].facId)
      or fromFacId
    -- Pin the spawn pad, not the yard inspect spot.
    shift.originLocation = trailerOffer.spawnLocation
      or trailerOffer.origin
      or (trailerOffer.locations and trailerOffer.locations[1])
      or { type = "facilityParkingspot", facId = pickupFacId }
    shift.returnPickupFacId = pickupFacId
    local pickupName = U.describeFacilityName(pickupFacId)
    local destName = U.describeFacilityName(dest and dest.facId)
    local toOffice = state.homeFacId and dest and dest.facId == state.homeFacId
    shift.returnLabel = string.format("Pick up return trailer at %s", pickupName)
    shift.returnDeliverLabel = string.format("Deliver return trailer to %s", destName)
    shift.returnSubtext = toOffice
      and ((trailerOffer.name or "Return trailer") .. " · back to the office")
      or (trailerOffer.name or "Return trailer")
    -- Keep the board offer alive for the drive to the pickup yard.
    local now = (U.dGeneral() and U.dGeneral().time and U.dGeneral().time()) or 0
    trailerOffer.offerExpiresAt = math.max(tonumber(trailerOffer.offerExpiresAt) or 0, now + 3600)
    trailerOffer._employmentReturnTrailer = true
    shift.returnNeedsPickup = true

    if pickupFacId ~= fromFacId then
      -- Spawn only once the player is near the yard — remote spawn often fails/vanishes.
      shift.returnNeedsPickup = true
      shift._returnTrailerSpawning = nil
      shift._returnTrailerSpawned = nil
      routeToReturnPickup()
      refreshTaskGuidance(true)
      notifyUi()
      return true
    end

    U.trySpawnAssignedReturnTrailer()
    return true
  end

  local function assignVehicleBackhaul(vehicleOffer)
    return U.assignVehicleBackhaulOffer(vehicleOffer, fromFacId)
  end

  if shift.jobKind == "trailer" then
    local trailerOffer = pickReturnTrailerOffer(fromFacId)
    if trailerOffer then
      return assignTrailerBackhaul(trailerOffer)
    end
    return assignEmptyYardReturn()
  end

  if shift.jobKind == "parcel" then
    local parcelGroup = pickReturnParcelGroup(fromFacId)
    if parcelGroup then
      return assignParcelBackhaul(parcelGroup)
    end
    return assignEmptyYardReturn()
  end

  if shift.jobKind == "vehicle" then
    if not shift.returnVehicleOffersRescanned then
      local gen = U.dGenerator()
      if gen and gen.triggerAllGenerators then gen.triggerAllGenerators() end
      shift.returnVehicleOffersRescanned = true
    end
    local vehicleOffer = U.pickReturnVehicleOffer(fromFacId, shift.returnVehicleAttemptedOfferIds)
    if vehicleOffer then
      return assignVehicleBackhaul(vehicleOffer)
    end
    shift.awaitingLoopChoice = true
    shift.returnLabel = "Return to the company yard"
    shift.returnSubtext = "No more deliveries available. Please check back later for more assignments"
    shift.destFacId = state.homeFacId
    shift.destLocation = nil
    shift.destPsPath = nil
    shift.returnVehicleAttemptedOfferIds = nil
    shift.returnVehicleOffersRescanned = nil
    ui_message(shift.returnSubtext, 8, "info")
    routeToYard()
    refreshTaskGuidance(true)
    notifyUi()
    return false
  end

  return assignEmptyYardReturn()
end

local function pickTrailerOffer(facId)
  return U.dEmploymentDispatch().pickTrailerOffer(U.dispatchContext(), facId)
end

-- Home yard can't ship: find real cargo/offers at N destined for this yard.
-- Company truck is still issued at homeFacId (caller); only the load origin moves.

U.listVehOfferPartnerFacilities = function(excludeFacId)
  local gen = U.dGenerator()
  if not (gen and gen.getFacilities) then return {} end
  local out = {}
  for _, fac in ipairs(gen.getFacilities() or {}) do
    if fac and fac.id and fac.id ~= excludeFacId and U.facilityOffersKind(fac, "vehicle") then
      table.insert(out, fac)
    end
  end
  return out
end

-- Flatbed haul: always deliver to the company yard.
-- Prefer pickup at a facility that has a vehicle offer headed home; otherwise
-- classic street-spawn repo (no pickupFacId).
U.pickEmploymentHaulRoute = function(opts)
  opts = type(opts) == "table" and opts or {}
  local homeFacId = opts.homeFacId
  local nearFacId = opts.nearFacId
  local gen = U.dGenerator()
  local mgr = U.dVehOffers()
  local homeFac = gen and gen.getFacilityById and gen.getFacilityById(homeFacId) or nil

  local function facLabel(facId, fac)
    if fac and fac.name then
      return translateUiText(fac.name, facId or fac.id)
    end
    return U.describeFacilityName(facId)
  end

  local function offerDestFacId(offer)
    return offer.destination and offer.destination.facId
      or (offer.locations and offer.locations[2] and offer.locations[2].facId)
  end

  local function offerReady(offer)
    if not (offer and offer.data and offer.data.type == "vehicle" and U.vehicleOfferUnlocked(offer)) then
      return false
    end
    if offerDestFacId(offer) ~= homeFacId then
      return false
    end
    if mgr and mgr.ensureOfferSpawnReady then
      return mgr.ensureOfferSpawnReady(offer, "pickEmploymentHaulRoute") and true or false
    end
    if mgr and mgr.isOfferSpawnReady then
      return mgr.isOfferSpawnReady(offer) and true or false
    end
    return true
  end

  local function facilityHasInboundToHome(facId)
    if not (mgr and mgr.getAllOfferAtFacilityUnexpired and facId) then return false end
    for _, offer in ipairs(mgr.getAllOfferAtFacilityUnexpired(facId) or {}) do
      if offerReady(offer) then
        return true
      end
    end
    return false
  end

  local inboundFacs = {}
  for _, fac in ipairs(U.listVehOfferPartnerFacilities(homeFacId)) do
    if facilityHasInboundToHome(fac.id) then
      table.insert(inboundFacs, fac)
    end
  end

  local pickupFac = nil
  if nearFacId then
    for _, fac in ipairs(inboundFacs) do
      if fac.id == nearFacId then
        pickupFac = fac
        break
      end
    end
  end
  if not pickupFac and nearFacId and gen and gen.getDistanceBetweenFacilities and #inboundFacs > 0 then
    local best, bestDist
    for _, fac in ipairs(inboundFacs) do
      local dist = U.facDistanceBetween(nearFacId, fac.id)
      if not best or dist < bestDist then
        best, bestDist = fac, dist
      end
    end
    pickupFac = best
  end
  if not pickupFac and #inboundFacs > 0 then
    local orgId = state.employerOrgId or (homeFac and homeFac.associatedOrganization)
    for _, fac in ipairs(inboundFacs) do
      if orgId and fac.associatedOrganization == orgId then
        pickupFac = fac
        break
      end
    end
    pickupFac = pickupFac or inboundFacs[1]
  end

  return {
    pickupFacId = pickupFac and pickupFac.id or nil,
    pickupLabel = pickupFac and facLabel(pickupFac.id, pickupFac) or nil,
    deliveryFacId = homeFacId,
    deliveryLabel = facLabel(homeFacId, homeFac),
    mode = pickupFac and "facilityBackhaul" or "repo",
  }
end

local function playerInIssuedCompanyTruck()
  return U.dEmploymentEquipment().playerInIssuedCompanyTruck(U.equipmentContext())
end

local function getEmployerFacility()
  local facId = state.homeFacId or (state.shift and state.shift.originFacId)
  if not facId then return nil end
  local gen = U.dGenerator()
  if gen and gen.getFacilityById then
    local fac = gen.getFacilityById(facId)
    if fac then return fac end
  end
  if freeroam_facilities and freeroam_facilities.getFacility then
    return freeroam_facilities.getFacility("deliveryProvider", facId)
  end
  return nil
end

local function getEmployerDeliveryContext()
  local facId = state.homeFacId or (state.shift and state.shift.originFacId)
  if not facId then return nil end
  local fac = getEmployerFacility()
  local label = fac and translateUiText(fac.name, fac.id) or getOrgDisplayName(getOrg(state.employerOrgId), state.employerOrgId)
  return {
    facId = facId,
    label = label,
    fac = fac,
  }
end

local function handleEmploymentRepoComplete(gross, meta)
  local shift = state.shift
  if not shift then return end
  gross = tonumber(gross) or 0
  if isBundleShift(shift) then
    if shift.assignments and shift.assignments.repo then
      shift.assignments.repo.repoPendingStart = false
    end
    if gross > 0 then
      local keep = U.addEscrowKeep("Flatbed haul", gross, U.getCompanyShare())
      ui_message(string.format("Company is holding $%d until you end your shift.", keep), 6, "info")
    end
    U.maybeApplySurgeAssignmentBonus(shift)
    if shift.assignments and shift.assignments.repo then
      shift.assignments.repo.complete = true
    end
    ui_message("Car hauling complete.", 6, "success")
    -- Mark complete before XP so attribute errors cannot leave the leg unfinished.
    local skillXp = meta and tonumber(meta.skillXp) or 0
    if skillXp > 0 and career_modules_playerAttributes and career_modules_playerAttributes.addAttributes then
      local xpOk, xpErr = pcall(career_modules_playerAttributes.addAttributes, {
        [RECOVERY_SKILL_ATTRIBUTE_KEY] = skillXp,
      }, { tags = { "gameplay", "repo", "recovery", "employment" } })
      if not xpOk then
        log("W", "employment", "Repo skill XP grant failed: " .. tostring(xpErr))
      end
    end
    maybeCompleteBundleShift({ atYard = true })
    notifyUi()
    return
  end
  if shift.jobKind ~= "repo" then return end
  shift.repoPendingStart = nil
  if gross > 0 then
    local keep = U.addEscrowKeep("Flatbed haul", gross, U.getCompanyShare())
    ui_message(string.format("Company is holding $%d until you end your shift.", keep), 6, "info")
  end
  U.maybeApplySurgeAssignmentBonus(shift)
  local skillXp = meta and tonumber(meta.skillXp) or 0
  if skillXp > 0 and career_modules_playerAttributes and career_modules_playerAttributes.addAttributes then
    local xpOk, xpErr = pcall(career_modules_playerAttributes.addAttributes, {
      [RECOVERY_SKILL_ATTRIBUTE_KEY] = skillXp,
    }, { tags = { "gameplay", "repo", "recovery", "employment" } })
    if not xpOk then
      log("W", "employment", "Repo skill XP grant failed: " .. tostring(xpErr))
    end
  end
  if meta and meta.vehicleLabel then
    shift.outboundLabel = "Haul the " .. meta.vehicleLabel .. " back to the yard"
    shift.outboundSubtext = "Company rollback"
  end
  ui_message("Car hauling complete.", 6, "success")
  afterOutboundDelivered()
end

local function tryStartEmploymentRepo()
  local shift = state.shift
  if not shift or not isOnShift() then return false end
  if isBundleShift(shift) then return false end
  if shift.jobKind ~= "repo" then
    return false
  end
  local repo = U.dRepo()
  if repo and repo.isEmploymentRepoActive and repo.isEmploymentRepoActive() then
    shift.repoPendingStart = false
    return true
  end
  if not shift.repoPendingStart then
    return false
  end
  if not playerInIssuedCompanyTruck() then
    return false
  end
  if not repo or not repo.startEmploymentJob then
    U.handleAssignmentStartFailure("Company pickup service is unavailable.")
    return false
  end
  local delivery = getEmployerDeliveryContext()
  local nearFacId = shift.destFacId
  local homeFacId = (delivery and delivery.facId) or state.homeFacId or shift.originFacId
  local route = U.pickEmploymentHaulRoute({
    homeFacId = homeFacId,
    nearFacId = nearFacId,
  })
  local deliveryFacId = route.deliveryFacId or homeFacId
  local deliveryLabel = route.deliveryLabel
    or (delivery and delivery.label)
    or getOrgDisplayName(getOrg(state.employerOrgId), state.employerOrgId)
  if route.pickupLabel then
    shift.outboundLabel = string.format("Pickup at %s — haul back to the yard", route.pickupLabel)
    shift.outboundSubtext = "Company rollback"
  else
    shift.outboundLabel = "Pickup — haul a vehicle back to the yard"
    shift.outboundSubtext = "Company rollback"
  end
  local isCurrent = U.makeAssignmentGuard()
  local started = repo.startEmploymentJob(handleEmploymentRepoComplete, function(reason, generationFailed)
    if not isCurrent() then return end
    if generationFailed then
      U.handleAssignmentStartFailure(reason or "Company pickup could not be created.")
      return
    end
    shift.repoPendingStart = true
    if reason and reason ~= "" then
      ui_message(tostring(reason), 6, "warning")
    end
    refreshTaskGuidance(true)
    notifyUi()
  end, {
    homeFacId = deliveryFacId,
    deliveryLabel = deliveryLabel,
    pickupFacId = route.pickupFacId,
    pickupLabel = route.pickupLabel,
  })
  if started then
    shift.repoPendingStart = false
    refreshTaskGuidance(true)
  end
  return started
end

U.rearmMissingEmploymentRepo = function()
  local shift = state.shift
  if not shift or not isOnShift() then return false end
  if isBundleShift(shift) then
    if not U.isBundleHaulBackhaulPending(shift) then return false end
    if shift.returnNeedsPickup and shift.assignedOfferId then
      return U.trySpawnAssignedReturnVehicle() and true or false
    end
    if shift.returnIsBackhaul and shift.assignedOfferId then
      return false
    end
    U.beginBundleRepoLeg()
    return true
  end
  if shift.jobKind ~= "repo" or shift.phase ~= "outbound" or shift.repoPendingStart then
    return false
  end
  local repo = U.dRepo()
  if not repo
      or (repo.isEmploymentRepoActive and repo.isEmploymentRepoActive())
      or (repo.isEmploymentRepoCompleting and repo.isEmploymentRepoCompleting()) then
    return false
  end
  shift.repoPendingStart = true
  refreshTaskGuidance(true)
  notifyUi()
  return true
end

local function markIssued(offer)
  return U.dEmploymentEquipment().markIssued(U.equipmentContext(), offer)
end

local function captureIssuedInventoryIds()
  return U.dEmploymentEquipment().captureIssuedInventoryIds(U.equipmentContext())
end

U.shiftLoanerKind = function(shift)
  return U.dEmploymentEquipment().shiftLoanerKind(U.equipmentContext(), shift)
end

U.bundleNeedsRepoTruckSpawn = function(shift)
  return U.dEmploymentEquipment().bundleNeedsRepoTruckSpawn(U.equipmentContext(), shift)
end

U.issueBundleRepoTruck = function(fac, onReady)
  return U.dEmploymentEquipment().issueBundleRepoTruck(U.equipmentContext(), fac, onReady)
end

routeToLocation = function(location)
  if not location then return false end
  local gen = U.dGenerator()
  local toPos = location.type == "coordinates" and location.pos
    or (gen and gen.getLocationCoordinates and gen.getLocationCoordinates(location))
  if not toPos and location.type == "facilityParkingspot" and location.psPath and gen and gen.getParkingSpotByPath then
    local spot = gen.getParkingSpotByPath(location.psPath)
    toPos = spot and spot.pos
  end
  if not toPos and location.facId and gen and gen.getFacilityById then
    local fac = gen.getFacilityById(location.facId)
    local spot = fac and ((fac.trailerSpots and fac.trailerSpots[1])
      or (fac.pickUpSpots and fac.pickUpSpots[1])
      or (fac.inspectSpots and fac.inspectSpots[1])
      or (fac.dropOffSpots and fac.dropOffSpots[1]))
    if spot then
      toPos = spot.pos
      if not location.psPath then
        location.psPath = (spot.getPath and spot:getPath()) or spot.psPath
      end
    end
  end
  if not toPos then return false end
  if freeroam_bigMapMode and freeroam_bigMapMode.setNavFocus then
    freeroam_bigMapMode.setNavFocus(toPos)
  end
  if core_groundMarkers and core_groundMarkers.setPath then
    core_groundMarkers.setPath({toPos}, {clearPathOnReachingTarget = false})
  end
  return true
end

local function getYardLocation()
  local shift = state.shift
  local facId = state.homeFacId or (shift and shift.originFacId)
  local gen = U.dGenerator()
  local fac = gen and gen.getFacilityById and gen.getFacilityById(facId)
  if not fac then return shift and shift.originLocation or nil end
  local spot = (fac.inspectSpots and fac.inspectSpots[1])
    or (fac.pickUpSpots and fac.pickUpSpots[1])
    or (fac.dropOffSpots and fac.dropOffSpots[1])
  if not spot then return shift and shift.originLocation or nil end
  local path = (spot.getPath and spot:getPath()) or spot.psPath
  if not path then return shift and shift.originLocation or nil end
  return { type = "facilityParkingspot", facId = facId, psPath = path }
end

refreshDeliveryPois = function()
  if gameplay_rawPois and gameplay_rawPois.clear then gameplay_rawPois.clear() end
  if U.dGeneral() and U.dGeneral().requestDeliveryPoiRefresh then
    U.dGeneral().requestDeliveryPoiRefresh(true)
  end
end

routeToYard = function()
  -- Do not call freeroam_bigMapMode.resetRoute here — that wiped the path we just set
  -- and left world pins on leftover cargo destinations instead of the company yard.
  if not routeToLocation(getYardLocation()) then return false end
  refreshDeliveryPois()
  return true
end

local HOME_YARD_NEAR_DIST = 70

playerNearHomeYard = function(maxDist)
  maxDist = tonumber(maxDist) or HOME_YARD_NEAR_DIST
  if not be or not be.getPlayerVehicle then return false end
  local veh = be:getPlayerVehicle(0)
  if not veh or not veh.getPosition then return false end
  local yard = getYardLocation()
  if not yard or not yard.psPath then return false end
  local gen = U.dGenerator()
  local spot = gen and gen.getParkingSpotByPath and gen.getParkingSpotByPath(yard.psPath)
  if not spot or not spot.pos then return false end
  return (veh:getPosition() - spot.pos):length() <= maxDist
end

U.companyVehiclesAwayFromYard = function(maxDist)
  maxDist = tonumber(maxDist) or HOME_YARD_NEAR_DIST
  local inventory = career_modules_inventory
  if not (inventory and inventory.getVehicleIdFromInventoryId) then return false end
  local yard = getYardLocation()
  local gen = U.dGenerator()
  local spot = yard and yard.psPath and gen and gen.getParkingSpotByPath and gen.getParkingSpotByPath(yard.psPath)
  if not (spot and spot.pos) then return false end
  for _, inventoryId in ipairs(U.collectCompanyInventoryIds()) do
    local vehId = inventory.getVehicleIdFromInventoryId(inventoryId)
    local veh = vehId and vehId >= 0 and getObjectByID(vehId)
    if veh and (veh:getPosition() - spot.pos):length() > maxDist then return true end
  end
  return false
end

local YARD_AUTO_OPEN_DIST = 10
local YARD_SETTLE_SPEED = 0.35
local YARD_SETTLE_TIME = 1.0
local yardArriveSettleTimer = 0
local taskGuidanceRefreshTimer = 0.25

local function playerNearLocation(loc, maxDist)
  maxDist = tonumber(maxDist) or 150
  if not loc then return false end
  if not be or not be.getPlayerVehicle then return false end
  local veh = be:getPlayerVehicle(0)
  if not veh or not veh.getPosition then return false end
  local gen = U.dGenerator()
  local pos = gen and gen.getLocationCoordinates and gen.getLocationCoordinates(loc)
  if not pos and loc.psPath and gen and gen.getParkingSpotByPath then
    local spot = gen.getParkingSpotByPath(loc.psPath)
    pos = spot and spot.pos
  end
  if not pos then return false end
  return (veh:getPosition() - pos):length() <= maxDist
end
U.playerNearLocation = playerNearLocation

local function playerAtHomeYardStall()
  if playerNearHomeYard(YARD_AUTO_OPEN_DIST) then return true end
  local facId = state.homeFacId or (state.shift and state.shift.originFacId)
  local gen = U.dGenerator()
  local fac = facId and gen and gen.getFacilityById and gen.getFacilityById(facId)
  if not fac then return false end
  local function anySpot(spots)
    for _, spot in ipairs(spots or {}) do
      local path = (spot.getPath and spot:getPath()) or spot.psPath
      if path and playerNearLocation({ type = "facilityParkingspot", facId = facId, psPath = path }, 8) then
        return true
      end
    end
    return false
  end
  return anySpot(fac.inspectSpots) or anySpot(fac.pickUpSpots)
    or anySpot(fac.dropOffSpots) or anySpot(fac.loanerNonTrailerSpots)
end

local function playerReadyAtYardInspect(dtSim)
  if not playerAtHomeYardStall() then
    yardArriveSettleTimer = 0
    return false
  end
  if not be or not be.getPlayerVehicle then
    yardArriveSettleTimer = 0
    return false
  end
  local veh = be:getPlayerVehicle(0)
  if not (veh and veh.getVelocity) then
    yardArriveSettleTimer = 0
    return false
  end
  if veh:getVelocity():length() > YARD_SETTLE_SPEED then
    yardArriveSettleTimer = 0
    return false
  end
  yardArriveSettleTimer = yardArriveSettleTimer + (tonumber(dtSim) or 0)
  return yardArriveSettleTimer >= YARD_SETTLE_TIME
end

local function playerAtAssignedDropOffSpot(facId, psPath)
  if not facId or not psPath then return false end
  if not shouldOpenEmployeeDropOff(facId, psPath) then return false end
  if playerNearLocation({ type = "facilityParkingspot", facId = facId, psPath = psPath }, 8) then
    return true
  end
  local shift = state.shift
  if not (shift and shift.jobKind == "trailer") then return false end
  local gen = U.dGenerator()
  local spot = gen and gen.getParkingSpotByPath and gen.getParkingSpotByPath(psPath)
  local tasks = career_modules_delivery_vehicleTasks
  if not (spot and spot.containsPoint and tasks and tasks.getVehicleTasks
      and overhaul_playerVehicles and overhaul_playerVehicles.isPlayerVehicle) then
    return false
  end
  local assigned = shiftVehicleOfferIdSet(shift)
  for _, taskData in ipairs(tasks.getVehicleTasks() or {}) do
    local activeTask = taskData.tasks and taskData.tasks[taskData.activeTaskIndex]
    local destination = activeTask and activeTask.destination
    if taskData.offer and assigned[taskData.offer.id]
        and activeTask and activeTask.type == "confirmDropOff" and destination
        and destination.psPath == psPath
        and (not destination.facId or destination.facId == facId)
        and overhaul_playerVehicles.isPlayerVehicle(taskData.vehId) then
      local trailer = getObjectByID(taskData.vehId)
      if trailer and spot:containsPoint(trailer:getPosition()) then return true end
    end
  end
  return false
end



U.willAutoOpenDropOffAt = function(facId, psPath)
  if not isOnShift() or uiOpen or dropOffOpen or dropOffEscrowPending then return false end
  if not facId or not psPath then return false end
  if gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking() then return false end
  return playerAtAssignedDropOffSpot(facId, psPath)
end

U.tryOpenNearbyAssignedDropOff = function(dtSim)
  local shift = state.shift
  if uiOpen or dropOffOpen or dropOffEscrowPending
      or not shift
      or (gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking()) then
    state.dropOffProximityTimer = 0
    return false
  end
  local veh = be and be.getPlayerVehicle and be:getPlayerVehicle(0)
  if not (veh and veh.getVelocity) or veh:getVelocity():length() > YARD_SETTLE_SPEED then
    state.dropOffProximityTimer = 0
    return false
  end
  state.dropOffProximityTimer = (state.dropOffProximityTimer or 0) + (tonumber(dtSim) or 0)
  if state.dropOffProximityTimer < YARD_SETTLE_TIME then return false end
  local function trySpot(facId, psPath)
    if not playerAtAssignedDropOffSpot(facId, psPath) then return false end
    state.dropOffProximityTimer = 0
    return openDropOffUi(facId, psPath)
  end
  if trySpot(shift.destFacId, shift.destPsPath) then return true end
  local stop = shift.stops and shift.stops[shift.stopIndex or 1]
  if stop and (stop.destFacId ~= shift.destFacId or stop.destPsPath ~= shift.destPsPath) then
    if trySpot(stop.destFacId, stop.destPsPath) then return true end
  end
  state.dropOffProximityTimer = YARD_SETTLE_TIME - 0.25
  return false
end

U.isEmployeeDropOffBlocked = function()
  local shift = state.shift
  if not (shift and shift.jobKind == "parcel") then return false end
  if shift.dropOffDepartureRequired then return true end
  if shift.phase == "outbound" then return shift.needsRemotePickup == true end
  if shift.phase == "return" then return shift.returnNeedsPickup == true end
  return false
end

U.finishUnavailableReturnTrailer = function(shift, reason)
  if not shift or state.shift ~= shift then return end
  U.shiftLog("return trailer unavailable", tostring(reason or "unknown"))
  U.cancelSpawnBlockedWatch()
  shift._returnTrailerSpawning = nil
  shift._returnTrailerSpawned = nil
  shift.returnIsBackhaul = nil
  shift.assignedOfferId = nil
  shift.returnNeedsPickup = nil
  shift.returnPickupFacId = nil
  shift.awaitingLoopChoice = true
  shift.returnLabel = "Return the company vehicle to the office"
  shift.returnSubtext = "No returns available. Head back to the yard"
  shift.destFacId = state.homeFacId
  shift.destLocation = nil
  shift.destPsPath = nil
  ui_message(shift.returnSubtext, 7, "info")
  routeToYard()
  refreshTaskGuidance(true)
  notifyUi()
end

local function trySpawnAssignedReturnTrailer()
  local shift = state.shift
  if not shift or shift.jobKind ~= "trailer" or shift.phase ~= "return" then return false end
  if shift.spawnBlocked then return false end
  if not shift.returnNeedsPickup or not shift.assignedOfferId then return false end
  if shift._returnTrailerSpawning or shift._returnTrailerSpawned then return false end
  if U.assignedReturnCargoInVehicle(shift) then
    shift.returnNeedsPickup = nil
    shift._returnTrailerSpawned = true
    return false
  end

  local mgr = U.dVehOffers()
  local offer = mgr and mgr.getOfferById and mgr.getOfferById(shift.assignedOfferId)
  if not offer then
    U.shiftLog("return trailer unavailable", "missingOffer")
    ui_message("No returns available. Head back to the yard", 7, "info")
    shift.returnIsBackhaul = nil
    shift.assignedOfferId = nil
    shift.returnNeedsPickup = nil
    shift.returnPickupFacId = nil
    shift.awaitingLoopChoice = true
    shift.returnLabel = "Return the company vehicle to the office"
    shift.returnSubtext = "No returns available. Head back to the yard"
    shift.destFacId = state.homeFacId
    shift.destLocation = nil
    shift.destPsPath = nil
    routeToYard()
    refreshTaskGuidance(true)
    notifyUi()
    return false
  end
  if offer.spawned then
    shift._returnTrailerSpawned = true
    local tasks = career_modules_delivery_vehicleTasks
    if tasks and tasks.navigateToNextTask then
      tasks.navigateToNextTask()
    end
    return true
  end

  local spawnLoc = offer.spawnLocation or offer.origin or shift.originLocation
  if not playerNearLocation(spawnLoc, 150) then return false end

  shift._returnTrailerSpawning = true
  offer._employmentReturnTrailer = true
  mgr.spawnAssignedOffer(offer.id, false, function(success, reason)
    shift._returnTrailerSpawning = nil
    if not state.shift or state.shift ~= shift then return end
    if success == false then
      if reason == "occupied" then
        U.enterSpawnBlockedState({needAssignedOffers = true})
        return
      end
      U.finishUnavailableReturnTrailer(shift, reason)
      return
    end
    shift._returnTrailerSpawned = true
    local tasks = career_modules_delivery_vehicleTasks
    if tasks and tasks.navigateToNextTask then
      tasks.navigateToNextTask()
    else
      routeToReturnPickup()
    end
    refreshTaskGuidance(true)
    notifyUi()
  end)
  return true
end

U.trySpawnAssignedReturnTrailer = trySpawnAssignedReturnTrailer

U.trySpawnAssignedReturnVehicle = function()
  local shift = state.shift
  if not shift then return false end
  if shift.spawnBlocked then return false end
  local vehicleReturn = shift.jobKind == "vehicle" and shift.phase == "return"
  local bundleReturn = U.isBundleHaulBackhaulPending(shift)
  if not vehicleReturn and not bundleReturn then return false end
  if not shift.returnNeedsPickup or not shift.assignedOfferId then return false end
  if shift._returnVehicleSpawning or shift._returnVehicleSpawned then return false end
  if U.assignedReturnCargoInVehicle(shift) then
    shift.returnNeedsPickup = nil
    shift._returnVehicleSpawned = true
    return false
  end

  local mgr = U.dVehOffers()
  local offer = mgr and mgr.getOfferById and mgr.getOfferById(shift.assignedOfferId)
  if not offer then
    shift.returnVehicleAttemptedOfferIds = shift.returnVehicleAttemptedOfferIds or {}
    shift.returnVehicleAttemptedOfferIds[shift.assignedOfferId] = true
    return assignReturnLoad(shift.returnPickupFacId, { retryVehicle = true })
  end
  local spawnLoc = offer.spawnLocation or offer.origin or shift.originLocation
  if not playerNearLocation(spawnLoc, 150) then return false end
  if not (mgr and mgr.spawnAssignedOffer) then return false end

  shift._returnVehicleSpawning = true
  local assignment = shift
  local offerId = offer.id
  local pickupFacId = shift.returnPickupFacId
  mgr.spawnAssignedOffer(offerId, false, function(success, reason)
    if state.shift ~= assignment then return end
    assignment._returnVehicleSpawning = nil
    if success == false then
      if reason == "occupied" then
        U.enterSpawnBlockedState({needAssignedOffers = true})
        return
      end
      assignment.returnVehicleAttemptedOfferIds = assignment.returnVehicleAttemptedOfferIds or {}
      assignment.returnVehicleAttemptedOfferIds[offerId] = true
      ui_message("Assigned vehicle unavailable. Dispatch is checking the next nearest delivery.", 6, "info")
      assignReturnLoad(pickupFacId, { retryVehicle = true })
      return
    end
    assignment._returnVehicleSpawned = true
    if assignment.spawnBlocked and not U.spawnBlockedNeedsCompanyLoaner(assignment)
        and not U.spawnBlockedNeedsAssignedOffers(assignment) then
      U.clearSpawnBlockedState(true)
    end
    routeCurrentAssignment()
    refreshTaskGuidance(true)
    notifyUi()
  end)
  return true
end

offerLoopCompleteChoice = function(opts)
  opts = opts or {}
  local shift = state.shift
  if not shift then return end
  shift.phase = "loopComplete"
  shift.awaitingLoopChoice = nil
  shift.returnLabel = opts.label or "Assignment complete"
  shift.returnSubtext = opts.subtext or "Take another job or end your day"
  refreshTaskGuidance(true)
  notifyUi()
  ui_message(shift.returnSubtext, 7, "info")
  U.saveEmploymentProgress()
  if dropOffOpen or dropOffEscrowPending then
    return
  end
  if not uiOpen then
    openShiftUi(state.homeFacId or shift.originFacId)
  end
end

beginYardReturnForLoopChoice = function()
  local shift = state.shift
  if not shift then return end
  shift.phase = "return"
  shift.returnIsBackhaul = false
  shift.returnNeedsPickup = nil
  shift.awaitingLoopChoice = true
  shift.returnLabel = "Return to the company yard"
  shift.returnSubtext = "Then choose your next job or end the day"
  routeToYard()
  refreshTaskGuidance(true)
  notifyUi()
  ui_message("Assignments complete — head back to the yard.", 7, "info")
end

routeToReturnPickup = function()
  local shift = state.shift
  if not shift then return false end
  local loc = shift.originLocation
  if shift.assignedOfferId then
    local mgr = U.dVehOffers()
    local offer = mgr and mgr.getOfferById and mgr.getOfferById(shift.assignedOfferId)
    if offer and (offer.spawnLocation or offer.origin) then
      loc = offer.spawnLocation or offer.origin
      shift.originLocation = loc
      local veh = offer.vehicle and offer.vehicle.vehId and getObjectByID(offer.vehicle.vehId)
      if veh then loc = {type = "coordinates", pos = veh:getPosition()} end
    end
  end
  if not loc and shift.returnPickupFacId then
    local gen = U.dGenerator()
    local fac = gen and gen.getFacilityById and gen.getFacilityById(shift.returnPickupFacId)
    local spot = fac and ((fac.trailerSpots and fac.trailerSpots[1])
      or (fac.pickUpSpots and fac.pickUpSpots[1])
      or (fac.inspectSpots and fac.inspectSpots[1])
      or (fac.dropOffSpots and fac.dropOffSpots[1]))
    local path = spot and ((spot.getPath and spot:getPath()) or spot.psPath)
    if path then
      loc = { type = "facilityParkingspot", facId = shift.returnPickupFacId, psPath = path }
    else
      loc = { type = "facilityParkingspot", facId = shift.returnPickupFacId }
    end
  end
  if not loc or not routeToLocation(loc) then return false end
  refreshDeliveryPois()
  return true
end


U.inventoryEntriesForIds = function(ids)
  return U.dEmploymentEquipment().inventoryEntriesForIds(U.equipmentContext(), ids)
end

U.isCompanyTrailer = function(vehInfo, vehId)
  return U.dEmploymentEquipment().isCompanyTrailer(U.equipmentContext(), vehInfo, vehId)
end

U.inventoryVehAsLoanerOffer = function(vehInfo)
  return U.dEmploymentEquipment().inventoryVehAsLoanerOffer(U.equipmentContext(), vehInfo)
end

U.companyInventoryHasTrailer = function()
  return U.dEmploymentEquipment().companyInventoryHasTrailer(U.equipmentContext())
end

U.companyInventoryHasTowTractor = function(couplerClass)
  return U.dEmploymentEquipment().companyInventoryHasTowTractor(U.equipmentContext(), couplerClass)
end

U.companyInventoryHasRepoTruck = function(requireTSeriesRollback)
  return U.dEmploymentEquipment().companyInventoryHasRepoTruck(U.equipmentContext(), requireTSeriesRollback)
end

U.canReuseIssuedEquipmentForJob = function(jobKind, couplerClass, jobOpts)
  return U.dEmploymentEquipment().canReuseIssuedEquipmentForJob(U.equipmentContext(), jobKind, couplerClass, jobOpts)
end

U.routeToCompanyTruck = function()
  return U.dEmploymentEquipment().routeToCompanyTruck(U.equipmentContext())
end

U.vehicleOfferFitsIssuedRollback = function(offer)
  if not offer then return false end
  local dispatch = U.dEmploymentDispatch()
  local caps = U.dLoanerCaps()
  local fac = getEmployerFacility()
  local useRollback, requireTSeries = dispatch.vehicleOfferRollbackPolicy(U.dispatchContext(), offer, fac, caps)
  if not useRollback then return false end
  if requireTSeries then
    return U.companyInventoryHasRepoTruck(true)
  end
  return true
end

U.beginCompanyVehiclePickupRoute = function()
  if U.nextAssignmentTransition then
    U.nextAssignmentTransition.equipmentShift = state.shift
    return true
  end
  return U.dEmploymentEquipment().beginCompanyVehiclePickupRoute(U.equipmentContext())
end

U.beginBundleRepoLeg = function()
  local shift = state.shift
  if not isBundleShift(shift) then return end
  local a = shift.assignments
  if not a or not a.repo or a.repo.complete then
    maybeCompleteBundleShift()
    return
  end
  U.cancelEmploymentRepoJob()
  a.repo.repoPendingStart = nil
  if shift.returnIsBackhaul and shift.assignedOfferId then
    if dropOffOpen and not maybeKeepDropOffOpenForProgress() then
      closeDropOffUi()
    end
    if playerInIssuedCompanyTruck() then
      U.trySpawnAssignedReturnVehicle()
      ui_message("Flatbed assignment ready — follow the route to the pickup.", 7, "info")
    else
      U.routeToCompanyTruck()
      ui_message("Get in the company flatbed to start your car haul assignment.", 7, "info")
    end
    refreshTaskGuidance(true)
    notifyUi()
    return
  end

  if not shift.returnVehicleOffersRescanned then
    local gen = U.dGenerator()
    if gen and gen.triggerAllGenerators then gen.triggerAllGenerators() end
    shift.returnVehicleOffersRescanned = true
  end

  local excluded = {}
  for id in pairs(U.deliveredEmploymentOfferIds(shift)) do
    excluded[id] = true
  end
  shift.returnVehicleAttemptedOfferIds = shift.returnVehicleAttemptedOfferIds or {}
  for id, flagged in pairs(shift.returnVehicleAttemptedOfferIds) do
    if flagged then excluded[id] = true end
  end

  local fromFacId = shift.destFacId or state.homeFacId
  local offer = U.pickHaulBackhaulVehicleOffer(fromFacId, excluded)
  while offer and not U.vehicleOfferFitsIssuedRollback(offer) do
    excluded[offer.id] = true
    shift.returnVehicleAttemptedOfferIds[offer.id] = true
    offer = U.pickHaulBackhaulVehicleOffer(fromFacId, excluded)
  end

  if not offer then
    a.repo.complete = true
    a.repo.offerId = nil
    a.repo.label = "Return to the company yard"
    a.repo.subtext = "No inbound vehicle available"
    ui_message("No inbound vehicle for the yard. Head back to return the company truck.", 7, "info")
    maybeCompleteBundleShift()
    return
  end

  if dropOffOpen then
    closeDropOffUi()
  end
  U.assignVehicleBackhaulOffer(offer, fromFacId)
  a.repo.offerId = offer.id
  a.repo.complete = false
  local pickupName = U.describeFacilityName(shift.returnPickupFacId)
  a.repo.label = string.format("Pickup at %s — haul back to the yard", pickupName)
  a.repo.subtext = offer.name or "Company rollback"
  if playerInIssuedCompanyTruck() then
    ui_message("Flatbed assignment ready — follow the route to the pickup.", 7, "info")
  else
    U.routeToCompanyTruck()
    ui_message("Get in the company flatbed to start your car haul assignment.", 7, "info")
  end
  local function pinFlatbedRoute()
    if not isOnShift() or not M.isBundleFlatbedPending() then return end
    M.reassertBundleFlatbedRoute()
    refreshTaskGuidance(true)
  end
  if core_jobsystem and core_jobsystem.create then
    core_jobsystem.create(function(job)
      job.sleep(0)
      pinFlatbedRoute()
    end)
  else
    pinFlatbedRoute()
  end
  refreshTaskGuidance(true)
  notifyUi()
end


companyVehiclesParked = function()
  return U.dEmploymentEquipment().companyVehiclesParked(U.equipmentContext())
end

getLoanerTruckSpots = function()
  return U.dEmploymentEquipment().getLoanerTruckSpots(U.equipmentContext())
end


routeToParkStall = function()
  return U.dEmploymentEquipment().routeToParkStall(U.equipmentContext())
end


routeCurrentAssignment = function()
  local shift = state.shift
  if not shift then return end
  if shift.parcelLoadPending then
    U.routeToCompanyTruck()
    return
  end
  if shift.awaitingCompanyVehicleEntry then
    if playerInIssuedCompanyTruck() then
      shift.awaitingCompanyVehicleEntry = nil
    else
      U.routeToCompanyTruck()
      return
    end
  end
  if U.routeAccidentRecovery and U.routeAccidentRecovery() then
    return
  end
  local cs = U.dCargoScreen()
  if shift.jobKind == "materials" then
    local active = U.dMaterials() and U.dMaterials().getActiveContract and U.dMaterials().getActiveContract()
    if active and (tonumber(active.inTransitAmount) or 0) > 0 and cs and cs.setMaterialContractDestinationRoute then
      if cs.setMaterialContractDestinationRoute(false) then
        refreshDeliveryPois()
        return
      end
    end
    if cs and cs.setMaterialContractPickupRoute and cs.setMaterialContractPickupRoute(false) then
      refreshDeliveryPois()
      return
    end
    if routeToLocation(shift.originLocation) then
      refreshDeliveryPois()
    end
    return
  end
  if shift.jobKind == "trailer" then
    if shift.phase == "return" and shift.returnNeedsPickup and not U.assignedReturnCargoInVehicle(shift) then
      if not routeToReturnPickup() and shift.returnPickupFacId then
        routeToLocation({ type = "facilityParkingspot", facId = shift.returnPickupFacId })
      end
      refreshDeliveryPois()
      return
    end
    local tasks = career_modules_delivery_vehicleTasks
    if tasks and tasks.navigateToNextTask then
      tasks.navigateToNextTask()
    elseif cs and cs.setBestRoute then
      cs.setBestRoute(true)
    end
    refreshDeliveryPois()
    return
  end
  if isBundleShift(shift) then
    local a = shift.assignments
    if a and a.vehicle and not a.vehicle.complete then
      local tasks = career_modules_delivery_vehicleTasks
      local routed = tasks and tasks.navigateToNextTask and tasks.navigateToNextTask()
      if not routed then
        if shift.destLocation then
          routeToLocation(shift.destLocation)
        elseif shift.destFacId then
          routeToLocation({ type = "facilityParkingspot", facId = shift.destFacId, psPath = shift.destPsPath })
        elseif cs and cs.setBestRoute then
          cs.setBestRoute(true)
        end
      end
    elseif a and not a.repo.complete then
      if not playerInIssuedCompanyTruck() then
        U.routeToCompanyTruck()
      elseif shift.returnNeedsPickup and not U.assignedReturnCargoInVehicle(shift) then
        U.trySpawnAssignedReturnVehicle()
        if not routeToReturnPickup() and shift.returnPickupFacId then
          routeToLocation({ type = "facilityParkingspot", facId = shift.returnPickupFacId })
        end
      else
        local tasks = career_modules_delivery_vehicleTasks
        local routed = tasks and tasks.navigateToNextTask and tasks.navigateToNextTask()
        if not routed then
          if shift.destLocation then
            routeToLocation(shift.destLocation)
          elseif shift.destFacId then
            routeToLocation({ type = "facilityParkingspot", facId = shift.destFacId, psPath = shift.destPsPath })
          elseif cs and cs.setBestRoute then
            cs.setBestRoute(true)
          end
        end
      end
    end
    refreshDeliveryPois()
    return
  end
  if shift.jobKind == "vehicle" then
    if isDistributorHaulShift(shift) and (shift.phase == "return" or shift.awaitingLoopChoice) then
      routeToYard()
      refreshDeliveryPois()
      return
    end
    local tasks = career_modules_delivery_vehicleTasks
    local routed = tasks and tasks.navigateToNextTask and tasks.navigateToNextTask()
    if isDistributorHaulShift(shift) then
      refreshDeliveryPois()
      return
    end
    if not routed then
      if shift.destLocation then
        routeToLocation(shift.destLocation)
      elseif shift.destFacId then
        routeToLocation({ type = "facilityParkingspot", facId = shift.destFacId, psPath = shift.destPsPath })
      elseif cs and cs.setBestRoute then
        cs.setBestRoute(true)
      end
    end
    refreshDeliveryPois()
    return
  end
  if shift.jobKind == "repo" then
    tryStartEmploymentRepo()
    refreshDeliveryPois()
    return
  end
  if shift.jobKind == "parcel" and shift.needsRemotePickup then
    if U.assignedReturnCargoInVehicle(shift) then
      shift.needsRemotePickup = nil
    else
      if shift.originLocation and routeToLocation(shift.originLocation) then
        refreshDeliveryPois()
        return
      end
      if shift.pickupFacId then
        routeToLocation({ type = "facilityParkingspot", facId = shift.pickupFacId })
        refreshDeliveryPois()
        return
      end
    end
  end
  -- Parcel strings follow the locked stop order (nearest-neighbor, planned once at load).
  -- Do not use setBestRoute here — that pins nearest cargo dest and desyncs the tasklist.
  if shift.stringMode and shift.stops and shift.phase == "outbound" then
    if shift.destLocation and routeToLocation(shift.destLocation) then
      refreshDeliveryPois()
      return
    end
    if shift.destFacId then
      routeToLocation({ type = "facilityParkingspot", facId = shift.destFacId, psPath = shift.destPsPath })
      refreshDeliveryPois()
      return
    end
  end
  -- Parcel (and similar): prefer cargo-screen best route, then hard dest fallback.
  -- Do not treat a no-op setBestRoute as success — that left players at the yard inspect spot.
  if cs and cs.setBestRoute and cs.setBestRoute(true) then
    refreshDeliveryPois()
    return
  end
  if shift.destLocation and routeToLocation(shift.destLocation) then
    refreshDeliveryPois()
    return
  end
  if shift.destFacId then
    routeToLocation({ type = "facilityParkingspot", facId = shift.destFacId, psPath = shift.destPsPath })
  end
  refreshDeliveryPois()
end

local function spawnAssignedVehicleOffers(onDone)
  return U.dEmploymentEquipment().spawnAssignedVehicleOffers(U.equipmentContext(), onDone)
end

U.cancelSpawnBlockedWatch = function()
  return U.dEmploymentEquipment().cancelSpawnBlockedWatch(U.equipmentContext())
end

U.extendAssignedOfferExpiryWhileBlocked = function(shift)
  return U.dEmploymentEquipment().extendAssignedOfferExpiryWhileBlocked(U.equipmentContext(), shift)
end

U.collectSpawnBlockedSpots = function(shift, needs)
  return U.dEmploymentEquipment().collectSpawnBlockedSpots(U.equipmentContext(), shift, needs)
end

U.inspectSpawnBlockedOccupancy = function(blocked)
  return U.dEmploymentEquipment().inspectSpawnBlockedOccupancy(U.equipmentContext(), blocked)
end

U.routeToSpawnBlockedArea = function(spots)
  return U.dEmploymentEquipment().routeToSpawnBlockedArea(U.equipmentContext(), spots)
end

U.clearSpawnBlockedState = function(success)
  return U.dEmploymentEquipment().clearSpawnBlockedState(U.equipmentContext(), success)
end

U.enterSpawnBlockedState = function(opts)
  return U.dEmploymentEquipment().enterSpawnBlockedState(U.equipmentContext(), opts)
end

U.spawnBlockedNeedsCompanyLoaner = function(shift)
  return U.dEmploymentEquipment().spawnBlockedNeedsCompanyLoaner(U.equipmentContext(), shift)
end

U.spawnBlockedNeedsAssignedOffers = function(shift)
  return U.dEmploymentEquipment().spawnBlockedNeedsAssignedOffers(U.equipmentContext(), shift)
end

U.jobFromShiftForActivation = function(shift)
  return U.dEmploymentEquipment().jobFromShiftForActivation(U.equipmentContext(), shift)
end

U.attemptSpawnBlockedRetry = function()
  return U.dEmploymentEquipment().attemptSpawnBlockedRetry(U.equipmentContext())
end

U.tickSpawnBlockedWatch = function(dtSim)
  return U.dEmploymentEquipment().tickSpawnBlockedWatch(U.equipmentContext(), dtSim)
end

U.drawSpawnBlockedArea = function(blocked)
  return U.dEmploymentEquipment().drawSpawnBlockedArea(U.equipmentContext(), blocked)
end

M.getBlockedSpawnStatus = function()
  return U.dEmploymentEquipment().getBlockedSpawnStatus(U.equipmentContext())
end

M.spawnBlockedEquipment = function()
  local status = M.getBlockedSpawnStatus()
  local blocked = state.shift and state.shift.spawnBlocked
  if not status or not status.nearby or blocked.retryInFlight then return false end
  local clear = U.inspectSpawnBlockedOccupancy(blocked)
  blocked.ready = clear
  if not clear then
    ui_message("The spawn area is still blocked. Clear the highlighted stalls first.", 6, "warning")
    notifyUi()
    return false
  end
  closeWorldPrompt()
  closeShiftUi()
  if blocked.retryKind == "accidentReplacement" then
    U.clearSpawnBlockedState(true)
    return U.claimAccidentReplacement and U.claimAccidentReplacement() or false
  end
  U.attemptSpawnBlockedRetry()
  return true
end

U.handleMissingCompanySpawn = function(reason, opts)
  opts = opts or {}
  local batch = career_modules_loanerVehicles and career_modules_loanerVehicles.consumeLastSpawnBatchResult
    and career_modules_loanerVehicles.consumeLastSpawnBatchResult()
  if batch and batch.occupiedBlocked and state.shift then
    U.enterSpawnBlockedState({
      needCompanyLoaner = true,
      needAssignedOffers = opts.needAssignedOffers and true or false,
    })
    notifyUi()
    closeShiftUi()
    return true
  end
  U.handleAssignmentStartFailure(reason)
  return false
end

U.handleAssignmentStartFailure = function(reason, failedShift)
  failedShift = failedShift or state.shift
  U.cancelSpawnBlockedWatch()
  U.shiftLog("assignment start failed", reason)
  if U.dGeneral() and U.dGeneral().isDeliveryModeActive and U.dGeneral().isDeliveryModeActive() then
    if U.dGeneral().exitDeliveryMode then U.dGeneral().exitDeliveryMode() end
  end
  U.emptyShift(true)
  closeShiftUi()
  if U.retryFailedAssignment(failedShift) then return true end
  U.finishNextAssignmentTransition()
  ui_message((reason or "Could not start the assignment.") .. " Clock in again to try another job.", 8, "warning")
  notifyUi()
  return false
end

local function markShiftStartPresentationReady()
  if not shiftStartPresentationPending or not uiOpen then return false end
  shiftStartPresentationPending = false
  shiftStartPresentationReady = true
  return true
end

local function handleVehicleSpawnResult(success, failReason)
  local shift = state.shift
  if shift and shift.spawnBlocked then
    shift.spawnBlocked.retryInFlight = nil
  end
  if success == false then
    if failReason == "occupied" and shift then
      U.enterSpawnBlockedState({
        needCompanyLoaner = U.spawnBlockedNeedsCompanyLoaner(shift),
        needAssignedOffers = true,
      })
      return
    end
    if shift and shift.jobKind == "trailer" and shift.phase == "return" and shift.returnIsBackhaul then
      U.finishUnavailableReturnTrailer(shift, failReason)
      return
    end
    if shift and shift.jobKind == "vehicle" and shift.phase == "return" and shift.returnIsBackhaul then
      shift.returnIsBackhaul = nil
      shift.assignedOfferId = nil
      shift.returnNeedsPickup = nil
      shift.returnPickupFacId = nil
      shift.awaitingLoopChoice = true
      shift.returnLabel = "Return to the company yard"
      shift.returnSubtext = "No return vehicle available — head back to the yard"
      shift.destFacId = state.homeFacId
      shift.destLocation = nil
      shift.destPsPath = nil
      ui_message(shift.returnSubtext, 7, "info")
      routeToYard()
      refreshTaskGuidance(true)
      notifyUi()
      return
    end
    U.handleAssignmentStartFailure("Could not spawn the assigned vehicle.")
    return
  end
  if shift and shift.spawnBlocked then
    if U.spawnBlockedNeedsCompanyLoaner(shift) or U.spawnBlockedNeedsAssignedOffers(shift) then
      return
    end
    U.clearSpawnBlockedState(true)
  end
  if markShiftStartPresentationReady() then notifyUi() end
  -- Defer one tick so addVehicleTask has registered before we navigate.
  local isCurrent = U.makeAssignmentGuard()
  local function apply()
    if not isCurrent() or not isOnShift() then return end
    routeCurrentAssignment()
    U.refreshActiveTaskGuidance()
    U.markNextAssignmentReady(shift)
  end
  if core_jobsystem and core_jobsystem.create then
    core_jobsystem.create(function(job)
      job.sleep(0)
      apply()
    end)
  else
    apply()
  end
end

local function activateAssignedWork(job)
  local shift = state.shift
  if not shift then return end
  local isCurrent = U.makeAssignmentGuard()
  local function onSpawned(success, failReason)
    if isCurrent() then handleVehicleSpawnResult(success, failReason) end
  end
  job = job or {}
  if shift.jobKind == "parcel" then
    local parcelMgr = U.dParcel()
    local hasCargo = false
    for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
      if parcelMgr and parcelMgr.getCargoById(cargoId) then
        hasCargo = true
        break
      end
    end
    if not hasCargo then
      U.handleAssignmentStartFailure("The assigned parcels are no longer available.")
      return
    end
    if shift.needsRemotePickup then
      U.stageAssignedReturnPickup()
      if shift.originLocation and routeToLocation(shift.originLocation) then
        refreshDeliveryPois()
      else
        routeCurrentAssignment()
      end
      refreshTaskGuidance(true)
      U.markNextAssignmentReady(shift)
      return
    end
    bindAssignedCargoToIssuedTruck()
    return
  end
  if shift.jobKind == "materials" then
    local mgr = U.dMaterials()
    if not (shift.assignedContractId and mgr and mgr.acceptAssignedOffer
        and mgr.acceptAssignedOffer(shift.assignedContractId)) then
      U.handleAssignmentStartFailure("The assigned material contract is no longer available.")
      return
    end
    routeCurrentAssignment()
    U.markNextAssignmentReady(shift)
    return
  end
  if U.dEmploymentEquipment().spawnAssignedWork(U.equipmentContext(), onSpawned) then return end
  if shift.jobKind == "repo" then
    shift.repoPendingStart = true
    tryStartEmploymentRepo()
    refreshTaskGuidance(true)
    return
  end
  if shift.jobKind == "trailer" or shift.jobKind == "vehicle" or isBundleShift(shift) then
    U.handleAssignmentStartFailure("The assigned vehicle offer is no longer available.")
    return
  end
  routeCurrentAssignment()
end

U.activateAssignedWork = activateAssignedWork

U.activateBundleShiftWork = function(job)
  local isCurrent = U.makeAssignmentGuard()
  if U.dGeneral() and U.dGeneral().startDeliveryMode then
    U.dGeneral().startDeliveryMode()
  end
  -- Car jockey spawnOffer uses stepHandler. Repo truck spawnAllOffers finishes by
  -- calling us from its completion step; starting a nested sequence there skips
  -- the first spawn step. Defer one tick (same pattern as loanerVehicles).
  local function run()
    if not isCurrent() or not isBundleShift(state.shift) then return end
    activateAssignedWork(job)
    refreshTaskGuidance(true)
    notifyUi()
  end
  if core_jobsystem and core_jobsystem.create then
    U.shiftLog("activateBundleShiftWork", "deferring car jockey spawn one tick")
    core_jobsystem.create(function(jobsys)
      jobsys.sleep(0)
      run()
    end)
  else
    run()
  end
end

U.finalizeAssignedParcelRewards = function(cargoIds)
  local gen = U.dGenerator()
  local parcelMgr = U.dParcel()
  if not (gen and gen.finalizeParcelItemDistanceAndRewards and parcelMgr and parcelMgr.getCargoById) then
    return
  end
  for _, cargoId in ipairs(cargoIds or {}) do
    local cargo = parcelMgr.getCargoById(cargoId)
    if cargo then
      gen.finalizeParcelItemDistanceAndRewards(cargo)
    end
  end
end

U.describeFacilityName = function(facId)
  if not facId then return "the yard" end
  local gen = U.dGenerator()
  local fac = gen and gen.getFacilityById and gen.getFacilityById(facId)
  if fac and fac.name then
    return translateUiText(fac.name, facId)
  end
  return tostring(facId)
end

-- Clear return-leg copy. If pickup isn't where you just dropped off, say so explicitly.
U.formatReturnParcelGuidance = function(pickupFacId, dest, cargoCount, dropOffFacId)
  local pickupName = U.describeFacilityName(pickupFacId)
  local destFacId = dest and dest.facId
  local destName = U.describeFacilityName(destFacId)
  local toOffice = state.homeFacId and destFacId == state.homeFacId
  local count = tonumber(cargoCount) or 0
  local remotePickup = dropOffFacId and pickupFacId and dropOffFacId ~= pickupFacId
  local countBit = count > 0 and string.format("%d parcel%s", count, count == 1 and "" or "s") or "Return load"
  local pickLabel, deliverLabel, subtext
  if remotePickup then
    pickLabel = string.format("Pick up return load at %s", pickupName)
    subtext = toOffice
      and string.format("%s · deliver to the office", countBit)
      or string.format("%s · deliver to %s", countBit, destName)
  else
    pickLabel = string.format("Pick up return load at %s", pickupName)
    subtext = toOffice and string.format("%s · back to the office", countBit) or countBit
  end
  deliverLabel = string.format("Deliver return to %s", destName)
  return pickLabel, deliverLabel, subtext
end

U.assignedReturnCargoInVehicle = function(shift)
  if not shift then return false end
  if shift.assignedCargoIds and shift.assignedCargoIds[1] then
    local parcelMgr = U.dParcel()
    if parcelMgr and parcelMgr.getCargoById then
      for _, cargoId in ipairs(shift.assignedCargoIds) do
        local cargo = parcelMgr.getCargoById(cargoId)
        if cargo and cargo.location and cargo.location.type == "vehicle" then
          return true
        end
      end
    end
  end
  -- Trailer backhaul: coupled / en-route counts as acquired.
  if shift.assignedOfferId and career_modules_delivery_vehicleTasks then
    local tasks = career_modules_delivery_vehicleTasks.getVehicleTasks
      and career_modules_delivery_vehicleTasks.getVehicleTasks() or {}
    for _, td in ipairs(tasks) do
      if not td.remove and td.offer and td.offer.id == shift.assignedOfferId then
        local step = td.tasks and td.tasks[td.activeTaskIndex]
        if step and (step.type == "bringToDestination" or step.type == "confirmDropOff") then
          return true
        end
      end
    end
  end
  return false
end

U.isInspectProviderSpot = function(facId, psPath)
  if not facId or not psPath then return false end
  local gen = U.dGenerator()
  local fac = gen and gen.getFacilityById and gen.getFacilityById(facId)
  if not fac then return false end
  for _, ap in pairs(fac.accessPointsByName or {}) do
    if ap.isInspectSpot then
      local path = ap.psPath
      if not path and ap.ps and ap.ps.getPath then
        path = ap.ps:getPath()
      end
      if path == psPath and ap.logisticTypesProvidedLookup and next(ap.logisticTypesProvidedLookup) then
        return true
      end
    end
  end
  return false
end

U.cargoAtInspectProviderSpot = function(cargo)
  local loc = cargo and cargo.location
  if not loc or loc.type ~= "facilityParkingspot" then return false end
  return U.isInspectProviderSpot(loc.facId, loc.psPath)
end

U.clearOfferedListings = function()
  state.offeredFacIds = {}
  state.offeredListingsAt = nil
end

U.shuffleInPlace = function(t)
  for i = #t, 2, -1 do
    local j = math.random(i)
    t[i], t[j] = t[j], t[i]
  end
  return t
end

-- Keep still-valid cached yards, then fill remaining slots from a shuffled pool.
U.listingOfferKey = function(listing)
  if not listing then return nil end
  return listing.facId or listing.orgId
end

U.selectOfferedListings = function(allListings, count, preferIds, forceRefresh)
  count = count or C.LISTING_OFFER_COUNT
  if type(allListings) ~= "table" or #allListings == 0 then
    return {}
  end
  if #allListings <= count then
    return allListings
  end
  local byKey = {}
  for _, listing in ipairs(allListings) do
    local key = U.listingOfferKey(listing)
    if key then
      byKey[key] = listing
    end
  end
  local chosen, used = {}, {}
  if not forceRefresh and type(preferIds) == "table" then
    for _, id in ipairs(preferIds) do
      local listing = byKey[id]
      local key = U.listingOfferKey(listing)
      if listing and key and not used[key] and #chosen < count then
        table.insert(chosen, listing)
        used[key] = true
      end
    end
  end
  local pool = {}
  for _, listing in ipairs(allListings) do
    local key = U.listingOfferKey(listing)
    if key and not used[key] then
      table.insert(pool, listing)
    end
  end
  U.shuffleInPlace(pool)
  for _, listing in ipairs(pool) do
    if #chosen >= count then break end
    local key = U.listingOfferKey(listing)
    table.insert(chosen, listing)
    if key then used[key] = true end
  end
  table.sort(chosen, function(a, b)
    if tostring(a.orgName) == tostring(b.orgName) then
      return tostring(a.facName) < tostring(b.facName)
    end
    return tostring(a.orgName) < tostring(b.orgName)
  end)
  return chosen
end

U.bindAssignedInFlight = false

U.PARCEL_LOAD_CLEARANCE_RATIO = 0.60
U.PARCEL_LOAD_CLEARANCE_MAX_TRIMS = 12

U.measureVehicleGroundClearance = function(vehId)
  vehId = tonumber(vehId) or vehId
  if not vehId then return nil end
  local veh = scenetree.findObjectById(vehId)
  if not veh or not veh.getPosition then return nil end
  local pos = veh:getPosition()
  if not pos then return nil end
  local origin = vec3(pos.x, pos.y, pos.z + 2)
  local hit = castRayStatic(origin, vec3(0, 0, -1), 8)
  if not hit or hit >= 8 then return nil end
  local groundZ = origin.z - hit
  return pos.z - groundZ
end

U.countAssignedParcelsOnVehicle = function(shift, vehId)
  vehId = tonumber(vehId) or vehId
  local parcelMgr = U.dParcel()
  if not (shift and vehId and parcelMgr and parcelMgr.getCargoById) then return 0 end
  local n = 0
  for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
    local cargo = parcelMgr.getCargoById(cargoId)
    local loc = cargo and cargo.location
    if loc and loc.type == "vehicle" and tonumber(loc.vehId) == vehId then
      n = n + 1
    end
  end
  return n
end

U.unloadHeaviestAssignedParcelFromTruck = function(shift, vehId)
  vehId = tonumber(vehId) or vehId
  local parcelMgr = U.dParcel()
  if not (shift and vehId and parcelMgr and parcelMgr.getCargoById and parcelMgr.changeCargoLocation) then
    return false
  end
  if U.countAssignedParcelsOnVehicle(shift, vehId) <= 1 then
    return false
  end
  local bestId, bestWeight = nil, nil
  for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
    local cargo = parcelMgr.getCargoById(cargoId)
    local loc = cargo and cargo.location
    if loc and loc.type == "vehicle" and tonumber(loc.vehId) == vehId then
      local w = tonumber(cargo.weight) or 0
      if not bestWeight or w > bestWeight then
        bestWeight = w
        bestId = cargoId
      end
    end
  end
  if not bestId then return false end
  local cargo = parcelMgr.getCargoById(bestId)
  local returnLoc = shift.originLocation or (cargo and cargo.origin)
  if not returnLoc then return false end
  parcelMgr.changeCargoLocation(bestId, returnLoc)
  local keep = {}
  for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
    if cargoId ~= bestId then
      keep[#keep + 1] = cargoId
    end
  end
  shift.assignedCargoIds = keep
  if shift.stringCargoIds then
    local membership = {}
    for _, cargoId in ipairs(shift.stringCargoIds) do
      if cargoId ~= bestId then
        membership[#membership + 1] = cargoId
      end
    end
    shift.stringCargoIds = membership
  end
  return true, bestId, bestWeight
end

U.applyContainerWeightsWithOverlay = function(onSettled)
  local g = U.dGeneral()
  if not (g and g.requestUpdateContainerWeights and g.updateContainerWeights) then
    if onSettled then onSettled() end
    return
  end
  g.requestUpdateContainerWeights()
  g.updateContainerWeights(function(data)
    local maxDelay = 0
    for _, delay in pairs(data or {}) do
      maxDelay = math.max(maxDelay, tonumber(delay) or 0)
    end
    local function unfreeze()
      for id, _ in pairs(data or {}) do
        local veh = scenetree.findObjectById(id)
        if veh then
          pcall(core_vehicleBridge.executeAction, veh, "setFreeze", false)
        end
      end
    end
    if core_jobsystem and core_jobsystem.create then
      core_jobsystem.create(function(job)
        if maxDelay > 0 then
          job.sleep(math.max(maxDelay, 1) + 0.5)
        end
        unfreeze()
        job.sleep(0.6)
        if onSettled then onSettled() end
      end)
    else
      unfreeze()
      if onSettled then onSettled() end
    end
  end)
end

U.beginParcelClearanceTrimAfterLoad = function(shift, vehId, emptyClearance, onDone)
  vehId = tonumber(vehId) or vehId
  onDone = onDone or function() end
  if not shift or not vehId then
    onDone(0)
    return
  end
  shift._clearanceTrimToken = (shift._clearanceTrimToken or 0) + 1
  local token = shift._clearanceTrimToken
  local trimmed = 0
  local minRatio = tonumber(U.PARCEL_LOAD_CLEARANCE_RATIO) or 0.60
  local maxTrims = math.floor(tonumber(U.PARCEL_LOAD_CLEARANCE_MAX_TRIMS) or 12)
  local overlayShown = false

  local function intact()
    return state.shift == shift and shift._clearanceTrimToken == token
  end

  local function showOverlay()
    if overlayShown or not guihooks or U.nextAssignmentTransition then return end
    overlayShown = true
    guihooks.trigger("rlsCareerLoadingOverlay", {
      visible = true,
      message = "Loading cargo",
    })
  end

  local function hideOverlay()
    if not overlayShown or not guihooks then return end
    overlayShown = false
    guihooks.trigger("rlsCareerLoadingOverlay", { visible = false })
  end

  local function finish()
    hideOverlay()
    if not intact() then return end
    onDone(trimmed)
  end

  local function checkAndTrim()
    if not intact() then
      hideOverlay()
      return
    end
    local emptyC = tonumber(emptyClearance)
    local loadedC = U.measureVehicleGroundClearance(vehId)
    if not emptyC or emptyC < 0.08 or not loadedC then
      finish()
      return
    end
    local ratio = loadedC / emptyC
    if ratio >= minRatio or trimmed >= maxTrims then
      U.shiftLog("parcel clearance", string.format(
        "accept ratio=%.3f empty=%.3f loaded=%.3f trimmed=%d",
        ratio, emptyC, loadedC, trimmed))
      finish()
      return
    end
    local removed = U.unloadHeaviestAssignedParcelFromTruck(shift, vehId)
    if not removed then
      U.shiftLog("parcel clearance", string.format(
        "cannot trim further ratio=%.3f empty=%.3f loaded=%.3f",
        ratio, emptyC, loadedC))
      finish()
      return
    end
    trimmed = trimmed + 1
    U.shiftLog("parcel clearance", string.format(
      "trim #%d ratio=%.3f -> reweigh", trimmed, ratio))
    U.applyContainerWeightsWithOverlay(checkAndTrim)
  end

  showOverlay()
  U.applyContainerWeightsWithOverlay(checkAndTrim)
end

U.buildCompanyParcelLoadSlots = function(containers)
  local slots = {}
  for _, con in ipairs(containers or {}) do
    if con.cargoTypesLookup and con.cargoTypesLookup.parcel and (con.freeCargoSlots or 0) > 0 then
      local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(con.vehId)
      local vehInfo = inventoryId and career_modules_inventory.getVehicles()[inventoryId]
      if vehInfo and vehInfo.loanType == "company" then
        local usedWeight = 0
        for _, cargo in ipairs(con.rawCargo or {}) do
          usedWeight = usedWeight + (tonumber(cargo.weight) or 0)
        end
        for _, cargo in ipairs(con.transientCargo or {}) do
          usedWeight = usedWeight + (tonumber(cargo.weight) or 0)
        end
        slots[#slots + 1] = {
          location = { type = "vehicle", vehId = con.vehId, containerId = con.containerId },
          free = tonumber(con.freeCargoSlots) or 0,
          usedWeight = usedWeight,
          vehId = con.vehId,
        }
      end
    end
  end
  return slots
end

U.takeParcelLoadLocation = function(slots, cargo)
  if not (slots and slots[1] and cargo) then return nil end
  local need = math.max(0, tonumber(cargo.slots) or 0)
  local bestFit, bestFitWeight, bestFitFree
  local bestAny, bestAnyWeight, bestAnyFree
  for i = 1, #slots do
    local slot = slots[i]
    local w = slot.usedWeight or 0
    local free = slot.free or 0
    if not bestAny or w < bestAnyWeight or (w == bestAnyWeight and free > bestAnyFree) then
      bestAny, bestAnyWeight, bestAnyFree = slot, w, free
    end
    if free >= need then
      if not bestFit or w < bestFitWeight or (w == bestFitWeight and free > bestFitFree) then
        bestFit, bestFitWeight, bestFitFree = slot, w, free
      end
    end
  end
  local slot = bestFit or bestAny
  if not slot then return nil end
  slot.free = (slot.free or 0) - need
  slot.usedWeight = (slot.usedWeight or 0) + (tonumber(cargo.weight) or 0)
  return {
    type = "vehicle",
    vehId = slot.location.vehId,
    containerId = slot.location.containerId,
  }
end

bindAssignedCargoToIssuedTruck = function()
  local shift = state.shift
  if not shift or shift.jobKind ~= "parcel" then return end
  if shift.phase ~= "outbound" and shift.phase ~= "return" then return end
  if shift.accident and shift.accident.needReload then
    routeCurrentAssignment()
    return
  end
  if U.bindAssignedInFlight then return end
  U.finalizeAssignedParcelRewards(shift.assignedCargoIds)
  U.purgeTimedParcelsFromShift(shift)
  local parcelMgr = U.dParcel()
  local g = U.dGeneral()
  if not (parcelMgr and g and g.getNearbyVehicleCargoContainers) then
    routeCurrentAssignment()
    return
  end
  local hasCargo = false
  for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
    if parcelMgr.getCargoById(cargoId) then hasCargo = true; break end
  end
  if not hasCargo then
    shift.parcelLoadPending = nil
    shift.parcelLoadRetryAt = nil
    U.handleAssignmentStartFailure("The assigned parcels are no longer available.")
    return
  end
  U.bindAssignedToken = (U.bindAssignedToken or 0) + 1
  local bindToken = U.bindAssignedToken
  U.bindAssignedInFlight = true
  shift.parcelLoadPending = true
  local vehicleIds = {}
  for _, inventoryId in ipairs(shift.issuedInventoryIds or {}) do
    local vehId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
    if vehId then vehicleIds[vehId] = true end
  end
  g.getNearbyVehicleCargoContainers(function(containers)
    if not state.shift or state.shift ~= shift or U.bindAssignedToken ~= bindToken then return end
    U.bindAssignedInFlight = false
    if shift.phase ~= "outbound" and shift.phase ~= "return" then return end
    local slots = U.buildCompanyParcelLoadSlots(containers)
    if not slots[1] then
      local inTruck = playerInIssuedCompanyTruck()
      local sawFullBay = false
      for _, con in ipairs(containers or {}) do
        if con.cargoTypesLookup and con.cargoTypesLookup.parcel and (con.freeCargoSlots or 0) <= 0 then
          local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(con.vehId)
          local vehInfo = inventoryId and career_modules_inventory.getVehicles()[inventoryId]
          if vehInfo and vehInfo.loanType == "company" then
            sawFullBay = true
            break
          end
        end
      end
      if sawFullBay and not shift._clearedStaleTruckCargo then
        shift._clearedStaleTruckCargo = true
        deleteCargoOnCompanyVehicles()
        shift.parcelLoadRetryAt = U.nowSim() + 0.5
        return
      end
      shift.parcelLoadAttempts = (shift.parcelLoadAttempts or 0) + 1
      if U.nextAssignmentTransition then
        if shift.parcelLoadAttempts >= 10 then
          U.handleAssignmentStartFailure("The company truck's cargo containers are unavailable.")
        else
          shift.parcelLoadRetryAt = U.nowSim() + 1
        end
        return
      end
      if inTruck then
        shift.parcelLoadRetryAt = U.nowSim() + 1
        if shift.parcelLoadAttempts == 1 then
          ui_message("Stay in the company van. Cargo loads when the bay is ready.", 6, "info")
        elseif shift.parcelLoadAttempts == 8 and not shift._autoLoadGetInPrompted then
          shift._autoLoadGetInPrompted = true
          ui_message("The van's cargo bay isn't responding. Step out and get back in.", 7, "warning")
        end
        return
      end
      if shift.parcelLoadAttempts >= 10 then
        shift.parcelLoadPending = nil
        shift.parcelLoadRetryAt = nil
        shift.parcelLoadAttempts = nil
        U.handleAssignmentStartFailure("The company truck's cargo containers are unavailable. Please try another assignment.")
        return
      end
      shift.parcelLoadRetryAt = U.nowSim() + 1
      if U.routeToCompanyTruck and U.routeToCompanyTruck() then
        if not shift._autoLoadGetInPrompted then
          shift._autoLoadGetInPrompted = true
          ui_message("Get in the company van. Cargo loads after you're in it.", 6, "info")
        end
        return
      end
      routeCurrentAssignment()
      return
    end
      shift.parcelLoadPending = nil
      shift.parcelLoadRetryAt = nil
      shift.parcelLoadAttempts = nil
      local loadVehId = slots[1].vehId
      local emptyClearance = U.measureVehicleGroundClearance(loadVehId)
      local autoLoaded = false
      local stagedManual = false
      local loadOrder = {}
      for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
        loadOrder[#loadOrder + 1] = cargoId
      end
      table.sort(loadOrder, function(a, b)
        local ca = parcelMgr.getCargoById(a)
        local cb = parcelMgr.getCargoById(b)
        return (tonumber(ca and ca.weight) or 0) > (tonumber(cb and cb.weight) or 0)
      end)
      for _, cargoId in ipairs(loadOrder) do
        local cargo = parcelMgr.getCargoById(cargoId)
        if cargo and cargoHasTimedModifier(cargo) then
        elseif cargo and cargo.location and cargo.location.type == "accident" then
        elseif cargo and cargo.logisticsPending and cargo.location and cargo.location.type == "vehicle" then
          local dest = U.takeParcelLoadLocation(slots, cargo)
          if dest then
            parcelMgr.changeCargoLocation(cargoId, dest)
            autoLoaded = true
          else
            stagedManual = true
          end
        elseif cargo and cargo.location and cargo.location.type == "vehicle" then
        elseif cargo and U.cargoAtInspectProviderSpot(cargo) then
          local dest = U.takeParcelLoadLocation(slots, cargo)
          if dest then
            if cargo._transientMove and parcelMgr.clearTransientMoveForCargo then
              parcelMgr.clearTransientMoveForCargo(cargoId)
            end
            parcelMgr.changeCargoLocation(cargoId, dest)
            autoLoaded = true
          else
            stagedManual = true
          end
        elseif cargo then
          local dest = U.takeParcelLoadLocation(slots, cargo)
          if dest and not cargo._transientMove then
            parcelMgr.addTransientMoveCargo(cargoId, dest)
            stagedManual = true
          elseif not dest then
            stagedManual = true
          end
        end
      end
      local onTruck = countAssignedParcelsOnTruck(shift)
      if autoLoaded or (shift.stringMode and onTruck > 0) then
        local completedRemotePickup = shift.returnNeedsPickup or shift.needsRemotePickup
        shift.returnNeedsPickup = nil
        shift.needsRemotePickup = nil
        if completedRemotePickup then shift.dropOffDepartureRequired = nil end
        shift._autoLoadGetInPrompted = nil

        local function finishAutoLoad(trimmedCount)
          if not state.shift or state.shift ~= shift then return end
          if shift.stringMode then
            U.rebuildStringFromFinalTruckLoad(shift)
          end
          routeCurrentAssignment()
          refreshDeliveryPois()
          local n = countAssignedParcelsOnTruck(shift)
          local deliveryLabel = shift.phase == "return" and shift.returnDeliverLabel or shift.outboundLabel
          if autoLoaded and not stagedManual then
            local msg = string.format(
              "%d parcel%s loaded — %s",
              n,
              n == 1 and "" or "s",
              deliveryLabel or "deliver to the assigned destination")
            if (tonumber(trimmedCount) or 0) > 0 then
              msg = string.format(
                "%d parcel%s loaded (trimmed %d for weight) — %s",
                n,
                n == 1 and "" or "s",
                trimmedCount,
                deliveryLabel or "deliver to the assigned destination")
            end
            U.assignmentMessage(msg, 7, "info")
            if shift.stringMode and shift.outboundLabel then
              firePhoneNotification("employment.stringReady", "Route ready", shift.outboundLabel, "success")
            end
          elseif autoLoaded and stagedManual then
            U.assignmentMessage("Some assigned parcels are at another dock — pick those up next.", 6, "info")
          end
          refreshTaskGuidance(true)
          notifyUi()
          U.markNextAssignmentReady(shift)
        end

        if autoLoaded then
          local cs = U.dCargoScreen()
          if cs and cs.onCargoPickedUp then
            cs.onCargoPickedUp()
          end
          U.beginParcelClearanceTrimAfterLoad(shift, loadVehId, emptyClearance, finishAutoLoad)
        else
          finishAutoLoad(0)
        end
        return
      end
      routeCurrentAssignment()
      return
  end, vehicleIds)
end

local function tryAutoLoadAssignedParcelsAtSpot(facId, psPath)
  if not isOnShift() then return false end
  local shift = state.shift
  if not shift or shift.jobKind ~= "parcel" then return false end
  if shift.phase ~= "outbound" and shift.phase ~= "return" then return false end
  if shift.accident and shift.accident.needReload then return false end
  if U.bindAssignedInFlight then return false end
  local remotePickup = (shift.phase == "return" and shift.returnNeedsPickup)
    or (shift.phase == "outbound" and shift.needsRemotePickup)
  if not remotePickup and not U.isInspectProviderSpot(facId, psPath) then return false end
  if U.assignedReturnCargoInVehicle(shift) and not shift.returnNeedsPickup and not shift.needsRemotePickup then
    return false
  end
  local parcelMgr = U.dParcel()
  if not parcelMgr then return false end
  local expected = shift.originLocation
  if remotePickup and expected and expected.facId == facId
      and (not expected.psPath or expected.psPath == psPath)
      and not U.assignedParcelFreightAlive(shift) then
    ui_message("The assigned return parcels are gone — finding another return load.", 6, "info")
    assignReturnLoad(facId)
    refreshTaskGuidance(true)
    return true
  end
  local anyHere = false
  for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
    local cargo = parcelMgr.getCargoById and parcelMgr.getCargoById(cargoId)
    local loc = cargo and cargo.location
    if loc and loc.type == "facilityParkingspot" and loc.facId == facId and loc.psPath == psPath then
      anyHere = true
      break
    end
  end
  if not anyHere then
    if remotePickup then
      U.stageAssignedReturnPickup()
    end
    return false
  end
  bindAssignedCargoToIssuedTruck()
  return true
end

U.stageAssignedReturnPickup = function()
  local shift = state.shift
  if not shift or shift.jobKind ~= "parcel" then return false end
  if not (shift.returnNeedsPickup or shift.needsRemotePickup) then return false end
  local parcelMgr = U.dParcel()
  local g = U.dGeneral()
  if not (parcelMgr and g and g.getNearbyVehicleCargoContainers) then return false end
  if not playerNearLocation(shift.originLocation, 12) then
    if parcelMgr.clearTransientMoveForCargo then
      for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
        local cargo = parcelMgr.getCargoById and parcelMgr.getCargoById(cargoId)
        if cargo and cargo._transientMove then parcelMgr.clearTransientMoveForCargo(cargoId) end
      end
    end
    return false
  end
  g.getNearbyVehicleCargoContainers(function(containers)
    if not state.shift or state.shift ~= shift then return end
    local slots = U.buildCompanyParcelLoadSlots(containers)
    if not slots[1] then return end
    local staged = false
    for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
      local cargo = parcelMgr.getCargoById and parcelMgr.getCargoById(cargoId)
      if cargo and cargo.location and cargo.location.type == "facilityParkingspot" then
        if not cargo._transientMove then
          local dest = U.takeParcelLoadLocation(slots, cargo)
          if dest then
            parcelMgr.addTransientMoveCargo(cargoId, dest)
            staged = true
          end
        end
      end
    end
    if staged then
      refreshDeliveryPois()
      notifyUi()
    end
  end)
  return true
end

U.hasAssignedReturnCargoAtSpot = function(facId, psPath)
  if not isOnShift() then return false end
  local shift = state.shift
  if not shift or shift.jobKind ~= "parcel" then return false end
  if not (shift.returnNeedsPickup or shift.needsRemotePickup) then return false end
  local parcelMgr = U.dParcel()
  if not parcelMgr then return false end
  for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
    local cargo = parcelMgr.getCargoById and parcelMgr.getCargoById(cargoId)
    local loc = cargo and cargo.location
    if loc and loc.type == "facilityParkingspot" and loc.facId == facId and loc.psPath == psPath then
      return true
    end
  end
  return false
end

local function describeDest(dest)
  if not dest then return "the destination" end
  local raw
  if U.dParcel() and U.dParcel().getLocationLabelShort then
    raw = U.dParcel().getLocationLabelShort(dest)
  end
  return translateUiText(raw or dest.facId, dest.facId or "the destination")
end

local function makeShiftState(facId, job, issuedInventoryIds)
  local fac = U.dGenerator() and U.dGenerator().getFacilityById and U.dGenerator().getFacilityById(facId)
  local shiftOrgId = fac and fac.associatedOrganization or state.employerOrgId
  if job.kind == "police" or job.kind == "bus" or job.kind == "paramedic" then
    return {
      phase = "active",
      jobKind = job.kind,
      spawnFallbackAttempted = job.spawnFallbackAttempted,
      shiftOrgId = shiftOrgId,
      issuedInventoryIds = issuedInventoryIds or {},
      originFacId = facId,
      loopComplete = false,
      wrecked = false,
      outboundLabel = job.label,
      outboundSubtext = job.subtext,
    }
  end
  if job.kind == "vehicle_repo_bundle" then
    return {
      phase = "active",
      jobKind = job.kind,
      spawnFallbackAttempted = job.spawnFallbackAttempted,
      issuedInventoryIds = issuedInventoryIds or {},
      assignedOfferId = job.offerId,
      destFacId = job.destFacId,
      destPsPath = job.destPsPath,
      originFacId = facId,
      originLocation = job.originLocation,
      destLocation = job.destLocation,
      requireTSeriesRollback = job.requireTSeriesRollback and true or nil,
      loopComplete = false,
      wrecked = false,
      outboundLabel = job.label,
      outboundSubtext = job.subtext,
      surgeBonusEligible = U.isJobKindSurged(job.kind, job.cargoType) and true or nil,
      assignments = {
        vehicle = {
          complete = false,
          offerId = job.offerId,
          label = job.vehicleLabel,
          subtext = job.vehicleSubtext,
        },
        repo = {
          complete = false,
          repoPendingStart = false,
          label = job.repoLabel,
          subtext = job.repoSubtext,
        },
      },
    }
  end
  local shift = {
    phase = "outbound",
    jobKind = job.kind,
    spawnFallbackAttempted = job.spawnFallbackAttempted,
    issuedInventoryIds = issuedInventoryIds or {},
    assignedCargoIds = job.cargoIds or {},
    assignedOfferId = job.offerId,
    assignedContractId = job.contractId,
    cargoType = job.cargoType,
    targetLoad = job.kind == "parcel" and job.cargoIds and #job.cargoIds or job.standardLoad,
    materialName = job.materialName,
    destFacId = job.destFacId,
    destPsPath = job.destPsPath,
    originFacId = facId,
    originLocation = job.originLocation,
    destLocation = job.destLocation,
    needsRemotePickup = job.needsRemotePickup and true or false,
    dropOffDepartureRequired = job.kind == "parcel" and true or nil,
    pickupFacId = job.pickupFacId,
    distributorHaul = job.distributorHaul and true or nil,
    couplerClass = job.couplerClass,
    assignedOfferIds = job.offerIds and deepcopy(job.offerIds) or nil,
    deliveredOfferIds = job.distributorHaul and {} or nil,
    stringMode = job.stringMode and true or nil,
    stops = job.stops,
    stopIndex = job.stringMode and (job.stopIndex or 1) or nil,
    stringCargoIds = job.stringMode and (job.cargoIds and deepcopy(job.cargoIds) or nil) or nil,
    stringStopTotal = nil,
    stopsCompleted = job.stringMode and 0 or nil,
    loopComplete = false,
    wrecked = false,
    outboundLabel = job.label,
    outboundSubtext = job.subtext,
    returnLabel = "Return to the company yard",
    returnSubtext = "Clock out after you arrive, or take another run",
  }
  if shift.stringMode and shift.stops and U.applyParcelStringStop then
    U.applyParcelStringStop(shift, shift.stopIndex or 1)
  end
  if job.kind ~= "police" and job.kind ~= "bus" and job.kind ~= "paramedic" then
    shift.surgeBonusEligible = U.isJobKindSurged(job.kind, job.cargoType) and true or nil
  end
  return shift
end

local function suppressConflictingRoleplay(jobKind)
  jobKind = jobKind or (state.shift and state.shift.jobKind)
  if jobKind == "police" or jobKind == "bus" or jobKind == "paramedic" then return end
  if gameplay_bus and gameplay_bus.cancelActiveRoute then
    gameplay_bus.cancelActiveRoute("company logistics shift")
  end
  if gameplay_ambulance and gameplay_ambulance.cancelActiveCall then
    gameplay_ambulance.cancelActiveCall("company logistics shift")
  end
end

local function beginAssignment(facId, job)
  U.touchLastWorkAt()
  state.ignoreCompanyDamageStrikes = nil
  job = job or {}
  local gen = U.dGenerator()
  if not (gen and gen.getFacilityById) then
    return false, "delivery generator not loaded"
  end
  local fac = gen.getFacilityById(facId)
  if not fac then
    return false, "facility not found: " .. tostring(facId)
  end
  local caps = U.dLoanerCaps()
  if job.kind == "police" or job.kind == "bus" or job.kind == "paramedic" then
    state.shift = makeShiftState(facId, job, {})
    state.shift.issuedInventoryIds = captureIssuedInventoryIds()
    state.shift.roleplayVehicleSelection = job.vehicleSelection
    if job.personalVehicleId then
      state.shift.personalVehicleId = job.personalVehicleId
      state.shift.issuedInventoryIds = {}
      refreshTaskGuidance(true)
      notifyUi()
      U.markNextAssignmentReady(state.shift)
      return true
    end
    local isCurrent = U.makeAssignmentGuard()
    U.shiftLog("beginAssignment", string.format("jobKind=%s", tostring(job.kind)))
    local truck = caps and caps.getIssuedRoleplayVehicleForFacility and caps.getIssuedRoleplayVehicleForFacility(fac, {selection = job.vehicleSelection}) or nil
    if not truck and not (state.shift.issuedInventoryIds and state.shift.issuedInventoryIds[1]) then
      state.shift = nil
      U.assignmentMessage("No company vehicle is available for this shift.", 6, "warning")
      return false, "no roleplay vehicle"
    end
    local function afterSpawn()
      if not isCurrent() then return end
      state.shift.issuedInventoryIds = captureIssuedInventoryIds()
      if not state.shift.issuedInventoryIds[1] then
        U.handleMissingCompanySpawn("Company vehicle did not spawn at the yard.")
        return
      end
      refreshTaskGuidance(true)
      firePhoneNotification("employment.shiftStarted", "Shift started", job.label or "On company time", "success")
      markShiftStartPresentationReady()
      notifyUi()
      U.beginCompanyVehiclePickupRoute()
      U.markNextAssignmentReady(state.shift)
    end
    if state.shift.issuedInventoryIds and state.shift.issuedInventoryIds[1] then
      afterSpawn()
      return true
    end
    markIssued(truck)
    U.dEmploymentEquipment().spawnCompanyOffers(U.equipmentContext(), afterSpawn)
    return true
  end

  -- Logistics owns the player for this shift — kill freestanding bus/paramedic routes.
  suppressConflictingRoleplay(job.kind)
  if job.kind == "vehicle_repo_bundle" then
    state.shift = makeShiftState(facId, job, {})
    local isCurrent = U.makeAssignmentGuard()
    U.shiftLog("beginAssignment", string.format("jobKind=vehicle_repo_bundle offer=%s", tostring(job.offerId)))

    local function afterSpawn()
      if not isCurrent() then return end
      state.shift.issuedInventoryIds = captureIssuedInventoryIds()
      if U.bundleNeedsRepoTruckSpawn(state.shift) then
        U.handleMissingCompanySpawn("Company rollback did not spawn at the yard.", {needAssignedOffers = true})
        return
      end
      U.activateBundleShiftWork(job)
      firePhoneNotification("employment.shiftStarted", "Shift started", job.label or "Car hauling.", "success")
      U.beginCompanyVehiclePickupRoute()
    end

    local function issueOrReuse()
      if not isCurrent() then return end
      if not U.bundleNeedsRepoTruckSpawn(state.shift) then
        afterSpawn()
        return
      end
      local ok, detail = U.issueBundleRepoTruck(fac, afterSpawn)
      if not ok then
        U.shiftLog("beginAssignment blocked", string.format("jobKind=vehicle_repo_bundle; %s", detail or "no truck"))
        U.handleAssignmentStartFailure("No company truck is available for this assignment.")
      end
    end

    if U.bundleNeedsRepoTruckSpawn(state.shift) and captureIssuedInventoryIds()[1] then
      U.handoffCompanyEquipmentThen(issueOrReuse)
      return true
    end
    if not U.bundleNeedsRepoTruckSpawn(state.shift) then
      afterSpawn()
      return true
    end
    local ok, detail = U.issueBundleRepoTruck(fac, afterSpawn)
    if not ok then
      state.shift = nil
      U.assignmentMessage("No company truck is available for this assignment.", 6, "warning")
      U.shiftLog("beginAssignment blocked", string.format("jobKind=vehicle_repo_bundle; %s", detail or "no truck"))
      return false, detail
    end
    return true
  end
  if job.kind == "vehicle" and job.distributorHaul then
    local truck, trailer
    if caps then
      truck, trailer = caps.getIssuedLoanersForFacility(fac, "trailer", {})
    end
    if not truck or not trailer then
      local detail = U.diagnoseLoanerFailure(fac, { kind = "trailer" }, {})
      U.assignmentMessage("No company truck and trailer are available for this haul.", 6, "warning")
      U.shiftLog("beginAssignment blocked", string.format("jobKind=vehicle distributorHaul; %s", detail))
      return false, detail
    end
    job.couplerClass = caps.getOfferCouplerClass(trailer)
    state.shift = makeShiftState(facId, job, captureIssuedInventoryIds())
    local isCurrent = U.makeAssignmentGuard()
    U.shiftLog("beginAssignment", string.format("jobKind=vehicle distributorHaul offers=%s truck=%s trailer=%s",
      dumps(job.offerIds or { job.offerId }), U.describeLoanerOffer(truck), U.describeLoanerOffer(trailer)))
    local function afterHaulerSpawn()
      if not isCurrent() then
        U.shiftLog("beginAssignment vehicle haul", "shift cleared before equipment handoff finished")
        return
      end
      state.shift.issuedInventoryIds = captureIssuedInventoryIds()
      if not U.companyInventoryHasTowTractor(state.shift.couplerClass) or not U.companyInventoryHasTrailer() then
        U.shiftLog("afterSpawn blocked", "distributor haul missing truck or trailer after company spawn")
        U.handleMissingCompanySpawn("Company truck and trailer did not spawn at the yard.", {needAssignedOffers = true})
        return
      end
      if U.dGeneral() and U.dGeneral().startDeliveryMode then
        U.dGeneral().startDeliveryMode()
      end
      activateAssignedWork(job)
      refreshTaskGuidance(true)
      firePhoneNotification("employment.shiftStarted", "Shift started", job.label or "Haul the assigned vehicles.", "success")
      notifyUi()
      U.beginCompanyVehiclePickupRoute()
    end
    if U.canReuseIssuedEquipmentForJob("trailer", job.couplerClass) and U.companyInventoryHasTrailer() then
      afterHaulerSpawn()
      return true
    end
    markIssued(truck)
    markIssued(trailer)
    U.dEmploymentEquipment().spawnCompanyOffers(U.equipmentContext(), afterHaulerSpawn)
    return true
  end
  if job.kind == "vehicle" then
    state.shift = makeShiftState(facId, job, {})
    local isCurrent = U.makeAssignmentGuard()
    U.shiftLog("beginAssignment", string.format("jobKind=vehicle offer=%s", tostring(job.offerId)))
    local function afterEquipmentCleared(returned)
      if not isCurrent() then
        U.shiftLog("beginAssignment vehicle", "shift cleared before equipment handoff finished")
        return
      end
      if returned == false then U.emptyShift(); notifyUi(); return end
      if U.dGeneral() and U.dGeneral().startDeliveryMode then
        U.dGeneral().startDeliveryMode()
      end
      activateAssignedWork(job)
      refreshTaskGuidance(true)
      firePhoneNotification("employment.shiftStarted", "Shift started", job.label or "Deliver the assigned vehicle.", "success")
      notifyUi()
      U.shiftLog("beginAssignment", string.format("vehicle offer=%s activated after equipment clear", tostring(job.offerId)))
    end
    U.handoffCompanyEquipmentThen(afterEquipmentCleared)
    return true
  end
  local targetLoad = job.standardLoad
  if job.kind == "parcel" and job.cargoIds then
    targetLoad = #job.cargoIds
  end
  local loanerOpts = {
    cargoType = job.cargoType,
    targetLoad = targetLoad,
  }
  if job.kind == "trailer" then
    loanerOpts.couplerClass = job.couplerClass
    if not loanerOpts.couplerClass and job.offerId then
      local mgr = U.dVehOffers()
      local offer = mgr and mgr.getOfferById and mgr.getOfferById(job.offerId)
      if offer and caps and caps.getOfferCouplerClass then
        loanerOpts.couplerClass = caps.getOfferCouplerClass(offer)
      end
    end
  end
  local truck, trailer
  if job.kind == "materials" then
    truck, trailer, loanerOpts = U.getIssuedEmploymentMaterials(fac, job.cargoType, targetLoad)
    if truck and not loanerOpts.targetLoad and targetLoad then
      U.shiftLog("beginAssignment", string.format("materials soft loaner match without targetLoad=%s", tostring(targetLoad)))
    end
  else
    truck, trailer = caps and caps.getIssuedLoanersForFacility(fac, job.kind, loanerOpts) or nil, nil
  end
  if not truck then
    local detail = U.diagnoseLoanerFailure(fac, job, loanerOpts)
    U.assignmentMessage("No company truck is available for this assignment.", 6, "warning")
    U.shiftLog("beginAssignment blocked", string.format("jobKind=%s; %s", tostring(job.kind), detail))
    return false, detail
  end

  state.shift = makeShiftState(facId, job, captureIssuedInventoryIds())
  local isCurrent = U.makeAssignmentGuard()
  if job.kind == "trailer" then
    state.shift.couplerClass = loanerOpts.couplerClass
  end
  U.shiftLog("beginAssignment", string.format("jobKind=%s coupler=%s truck=%s trailer=%s",
    tostring(job.kind), tostring(loanerOpts.couplerClass), U.describeLoanerOffer(truck), U.describeLoanerOffer(trailer)))

  local function afterSpawn()
    if not isCurrent() then
      U.shiftLog("afterSpawn skipped", "shift state cleared before spawn callback")
      return
    end
    state.shift.issuedInventoryIds = captureIssuedInventoryIds()
    if job.kind == "trailer" and not U.companyInventoryHasTowTractor(state.shift.couplerClass) then
      U.shiftLog("afterSpawn blocked", "trailer job missing tow vehicle after company spawn")
      U.handleMissingCompanySpawn("Company tow vehicle did not spawn at the yard.", {needAssignedOffers = true})
      return
    end
    if (job.kind == "parcel" or job.kind == "materials" or job.kind == "repo")
        and not (state.shift.issuedInventoryIds and state.shift.issuedInventoryIds[1]) then
      U.shiftLog("afterSpawn blocked", string.format("%s job missing company vehicle after spawn", tostring(job.kind)))
      U.handleMissingCompanySpawn("Company vehicle did not spawn at the yard.")
      return
    end
    if U.dGeneral() and U.dGeneral().startDeliveryMode then
      U.dGeneral().startDeliveryMode()
    end
    if U.nextAssignmentTransition and job.kind == "parcel" then
      U.nextAssignmentTransition.deferredWork = job
    elseif job.kind == "trailer" and core_jobsystem and core_jobsystem.create then
      core_jobsystem.create(function(spawnJob)
        spawnJob.sleep(0)
        if isCurrent() then activateAssignedWork(job) end
      end)
    else
      activateAssignedWork(job)
    end
    if not isCurrent() then return end
    if state.shift and state.shift.spawnBlocked then
      refreshTaskGuidance(true)
      notifyUi()
      closeShiftUi()
      return
    end
    refreshTaskGuidance(true)
    firePhoneNotification("employment.shiftStarted", "Shift started", job.label or "Deliver the assigned load.", "success")
    if job.kind == "parcel" or job.kind == "materials" or job.kind == "repo" then
      markShiftStartPresentationReady()
    end
    notifyUi()
    U.beginCompanyVehiclePickupRoute()
    U.shiftLog("afterSpawn complete", string.format("jobKind=%s issued=%d",
      tostring(job.kind), #(state.shift.issuedInventoryIds or {})))
  end

  if U.canReuseIssuedEquipmentForJob(job.kind, loanerOpts.couplerClass, loanerOpts) then
    U.shiftLog("beginAssignment", "reusing existing issued company inventory")
    afterSpawn()
    return true
  end

  local function issueEquipment(returned)
    if not isCurrent() then return end
    if returned == false then U.emptyShift(); notifyUi(); return end
    markIssued(truck)
    if trailer and job.kind ~= "trailer" then
      markIssued(trailer)
    end

    if career_modules_loanerVehicles and career_modules_loanerVehicles.spawnAllOffers then
      if not truck.id then
        U.shiftLog("beginAssignment blocked", "loaner offer missing id after markIssued")
        U.handleAssignmentStartFailure("No company truck is available for this assignment.")
        return
      end
      U.shiftLog("beginAssignment", "spawning company loaner offers")
      U.dEmploymentEquipment().spawnCompanyOffers(U.equipmentContext(), afterSpawn)
    else
      U.shiftLog("beginAssignment", "loanerVehicles.spawnAllOffers missing; activating immediately")
      afterSpawn()
    end
  end

  if U.collectCompanyInventoryIds()[1] then
    U.shiftLog("beginAssignment", "returning incompatible company equipment")
    if playerInIssuedCompanyTruck() then
      U.assignmentMessage("Step out of the company van. This job uses a different vehicle.", 7, "info")
    end
    U.handoffCompanyEquipmentThen(issueEquipment)
  else
    issueEquipment()
  end
  return true
end

U.assignmentMessage = function(...)
  if not U.nextAssignmentTransition then ui_message(...) end
end

U.NEXT_ASSIGNMENT_LOADING_TAG = "rlsEmploymentNextAssignment"
U.NEXT_ASSIGNMENT_LOADING_FALLBACK_S = 4
U.NEXT_ASSIGNMENT_TIMEOUT_S = 15
U.NEXT_ASSIGNMENT_RETRY_S = 1
U.NEXT_ASSIGNMENT_SETTLE_S = 0.5
U.NEXT_ASSIGNMENT_CARGO_QUERY_TIMEOUT_S = 3
U.NEXT_ASSIGNMENT_STEP_LABELS = {
  screen = "showing the loading screen",
  returnEquipment = "returning the previous vehicle",
  spawn = "spawning the company vehicle",
  enter = "entering the company vehicle",
  load = "loading cargo",
  prepare = "preparing the job",
  settle = "settling the vehicle",
}

U.setNextAssignmentStep = function(transition, step)
  if transition.step == step then return end
  U.shiftLog("next assignment", string.format("%s -> %s at %.1fs",
    tostring(transition.step or "start"), step, tonumber(transition.elapsed) or 0))
  transition.step = step
  transition.stepWait = 0
  transition.nextRetryAt = 0
end

U.resetNextAssignmentAttempt = function(transition)
  transition.elapsed = 0
  transition.stepWait = 0
  transition.readyShift = nil
  transition.equipmentShift = nil
  transition.deferredWork = nil
  transition.enterAttempts = 0
  transition.settled = 0
  transition.cargoWait = 0
end

U.enterCareerLoadingScreen = function(tag, onShown)
  if core_gamestate and core_gamestate.requestEnterLoadingScreen then
    core_gamestate.requestEnterLoadingScreen(tag, onShown)
  elseif onShown then
    onShown()
  end
end

U.exitCareerLoadingScreen = function(tag)
  if not (core_gamestate and core_gamestate.requestExitLoadingScreen) then return end
  if core_gamestate.getLoadingStatus and not core_gamestate.getLoadingStatus(tag) then return end
  core_gamestate.requestExitLoadingScreen(tag)
end

U.finishNextAssignmentTransition = function()
  if not U.nextAssignmentTransition then return end
  U.nextAssignmentTransition = nil
  if core_input_actionFilter then
    core_input_actionFilter.addAction(0, "employmentNextAssignment", false)
  end
  U.exitCareerLoadingScreen(U.NEXT_ASSIGNMENT_LOADING_TAG)
end

U.markNextAssignmentReady = function(shift)
  if U.nextAssignmentTransition and shift and state.shift == shift then
    U.nextAssignmentTransition.readyShift = shift
  end
end

U.beginNextAssignment = function(facId, job)
  if U.nextAssignmentTransition then return true end
  local transition = {elapsed = 0, employerOrgId = state.employerOrgId}
  U.nextAssignmentTransition = transition
  U.setNextAssignmentStep(transition, "screen")
  if core_input_actionFilter then
    core_input_actionFilter.setGroup("employmentNextAssignment", {
      "throttle", "brake", "clutch", "steering", "parkingbrake", "toggleParkingbrake",
      "walkingMode", "switch_next_vehicle", "switch_previous_vehicle", "reset_physics",
    })
    core_input_actionFilter.addAction(0, "employmentNextAssignment", true)
  end
  closeShiftUi()
  closeDropOffUi()
  local previousShift = state.shift
  local started = false
  local function begin()
    if started then return end
    started = true
    if U.nextAssignmentTransition ~= transition then return end
    if state.shift ~= previousShift or state.employerOrgId ~= transition.employerOrgId then
      U.finishNextAssignmentTransition()
      return
    end
    U.setNextAssignmentStep(transition, "spawn")
    local ok, err = pcall(U.beginAssignmentWithGuidance, facId, job)
    if not ok then
      U.shiftLog("next assignment failed", tostring(err))
      U.emptyShift()
      ui_message("Could not prepare another assignment. Clock in again to try another job.", 8, "warning")
    end
  end
  U.enterCareerLoadingScreen(U.NEXT_ASSIGNMENT_LOADING_TAG, begin)
  if core_jobsystem and core_jobsystem.create then
    core_jobsystem.create(function(jobSystem)
      jobSystem.sleep(U.NEXT_ASSIGNMENT_LOADING_FALLBACK_S)
      begin()
    end)
  else
    begin()
  end
  return true
end

U.beginAssignmentWithGuidance = function(facId, job)
  if U.nextAssignmentTransition then
    U.resetNextAssignmentAttempt(U.nextAssignmentTransition)
  end
  local ok, err = beginAssignment(facId, job)
  if not ok then
    local retrying = U.handleAssignmentStartFailure("Could not issue the company assignment.", {
      jobKind = job.kind,
      originFacId = facId,
      spawnFallbackAttempted = job.spawnFallbackAttempted,
    })
    return retrying, err
  end
  if ok then U.refreshActiveTaskGuidance() end
  return ok, err
end

local startNextRun
local resumeShift

-- Even mix across every kind this yard can actually offer right now.


local function chooseWeightedJobOption(options)
  return U.dEmploymentDispatch().chooseWeightedJobOption(U.dispatchContext(), options)
end


U.dEmploymentParcelStrings = function()
  return require("gameplay/delivery/employmentParcelStrings")
end

U.parcelStringContext = function()
  return {
    services = {
      generator = U.dGenerator,
      loanerCaps = U.dLoanerCaps,
      parcels = U.dParcel,
    },
    prepare = {
      parcelGroups = U.ensureParcelGroupsAtFacility,
      cargoHasTimedModifier = cargoHasTimedModifier,
      deliveryLevel = getDeliveryLevel,
    },
    labels = {
      facility = U.describeFacilityName,
      destination = describeDest,
    },
  }
end


U.resolveFacilityLocation = function(facOrLoc, preferredPsPath)
  return U.dEmploymentParcelStrings().resolveFacilityLocation(U.parcelStringContext(), facOrLoc, preferredPsPath)
end

U.facDistanceBetween = function(fromFacOrLoc, toFacOrLoc)
  return U.dEmploymentParcelStrings().facDistanceBetween(U.parcelStringContext(), fromFacOrLoc, toFacOrLoc)
end


U.applyParcelStringStop = function(shift, stopIndex)
  return U.dEmploymentParcelStrings().applyStop(U.parcelStringContext(), shift, stopIndex)
end

U.pruneDeliveredStringCargo = function(shift, dropOffData)
  return U.dEmploymentParcelStrings().pruneDelivered(U.parcelStringContext(), shift, dropOffData)
end

U.planParcelStringFromTruck = function(shift, fromLoc)
  return U.dEmploymentParcelStrings().planFromTruck(U.parcelStringContext(), shift, fromLoc)
end

U.advanceParcelStringStop = function(shift)
  return U.dEmploymentParcelStrings().advanceStop(U.parcelStringContext(), shift)
end


U.stringCurrentStopHasRemaining = function(shift)
  return U.dEmploymentParcelStrings().currentStopHasRemaining(shift)
end


U.buildParcelStringJob = function(facId)
  return U.dEmploymentParcelStrings().buildJob(U.parcelStringContext(), facId)
end

-- All issuable jobs at this yard right now (same pool chooseJob weights from).
local function buildJobOptions(facId)
  return U.dEmploymentDispatch().buildJobOptions(U.dispatchContext(), facId)
end

local function chooseJob(facId)
  return U.dEmploymentDispatch().chooseJob(U.dispatchContext(), facId)
end

U.retryFailedAssignment = function(failedShift)
  if not failedShift or failedShift.spawnFallbackAttempted then return false end
  local facId = state.homeFacId or failedShift.originFacId
  if not facId or not state.employerOrgId then return false end
  local options = buildJobOptions(facId) or {}
  local alternatives = {}
  local carJockeyKinds = {vehicle = true, repo = true, vehicle_repo_bundle = true}
  for _, option in ipairs(options) do
    if option.kind ~= failedShift.jobKind
        and not (carJockeyKinds[failedShift.jobKind] and carJockeyKinds[option.kind]) then
      alternatives[#alternatives + 1] = option
    end
  end
  if not alternatives[1] then return false end
  local job = chooseWeightedJobOption(alternatives)
  job.spawnFallbackAttempted = true
  local employerOrgId = state.employerOrgId
  local transition = U.nextAssignmentTransition
  local function retry()
    if transition and U.nextAssignmentTransition ~= transition then return end
    if state.shift or state.employerOrgId ~= employerOrgId then return end
    U.assignmentMessage("Assignment unavailable. Dispatch is trying a different job type.", 8, "info")
    local ok = U.beginAssignmentWithGuidance(facId, job)
    if ok then
      U.saveEmploymentProgress()
    end
  end
  -- Finish the failed spawn sequence before starting replacement equipment.
  if core_jobsystem and core_jobsystem.create then
    core_jobsystem.create(function(spawnJob)
      spawnJob.sleep(0)
      retry()
    end)
  else
    retry()
  end
  return true
end

U.resolveSelectedJob = function(facId, selection)
  return U.dEmploymentDispatch().resolveSelectedJob(U.dispatchContext(), facId, selection)
end

local function getDevJobOptions(facId)
  return U.dEmploymentDispatch().getDevJobOptions(U.dispatchContext(), facId)
end

-- Listings / apply gate: only if this yard has work the player can actually be issued for.
canEmployAt = function(orgId, facId, previewOrg)
  local org = previewOrg or getOrg(orgId)
  if not org and freeroam_organizations and freeroam_organizations.getOrganization then
    org = freeroam_organizations.getOrganization(orgId)
  end
  local fac = U.dGenerator() and U.dGenerator().getFacilityById and U.dGenerator().getFacilityById(facId)
  if not org or not fac or fac.associatedOrganization ~= orgId then
    return false, nil
  end
  if U.isOmittedFromEmployment(fac) then
    return false, nil
  end
  local profile = U.classifyEmployer(org, fac)
  if not profile then return false, nil end
  if profile == "police" or profile == "bus" or profile == "paramedic" then
    local caps = U.dLoanerCaps()
    local offers = caps and caps.getServiceFleetForFacility and caps.getServiceFleetForFacility(fac)
    return offers ~= nil and offers[1] ~= nil, profile
  end
  -- Parcels / trailers / materials / jockey / repo — all require unlocked equipment + skill flags.
  return next(getAssignableKinds(facId)) ~= nil, profile
end

U.minLevelForUnlockFlags = function(flags)
  local mins = U.getUnlockFlagMinLevels()
  local best = nil
  for _, flag in ipairs(flags or {}) do
    local req = mins[flag]
    if type(req) == "number" and (not best or req < best) then
      best = req
    end
  end
  return best
end

U.getListingSkillGate = function(facId, profile)
  local level = getDeliveryLevel()
  local fac = U.dGenerator() and U.dGenerator().getFacilityById and U.dGenerator().getFacilityById(facId)
  if not fac then
    return {
      skillLocked = true,
      requiredLevel = nil,
      skillMessage = "This yard is not available right now.",
    }
  end
  if profile == "police" or profile == "bus" or profile == "paramedic" then
    return { skillLocked = false, requiredLevel = nil, skillMessage = nil }
  end

  local kindLevels = {}
  if U.facilityOffersKind(fac, "parcel") then
    table.insert(kindLevels, { kind = "Parcel runs", level = U.minParcelLevelForFacility(fac) })
  end
  if U.facilityOffersKind(fac, "trailer") then
    table.insert(kindLevels, {
      kind = "Trailer delivery",
      level = U.minTrailerLevelForFacility(fac),
    })
  end
  if U.facilityOffersKind(fac, "materials") then
    local matFlags = U.facilityMaterialUnlockFlags(fac)
    table.insert(kindLevels, {
      kind = "materials",
      level = U.minLevelForUnlockFlags(#matFlags > 0 and matFlags or MATERIALS_UNLOCK_FLAGS),
    })
  end
  if U.facilityOffersKind(fac, "vehicle") then
    table.insert(kindLevels, {
      kind = "Car hauling",
      level = U.minVehicleLevelForFacility(fac),
    })
  end

  local bestReq, bestKind = nil, nil
  for _, entry in ipairs(kindLevels) do
    local req = entry.level
    if req and (not bestReq or req < bestReq) then
      bestReq, bestKind = req, entry.kind
    end
  end

  if not bestReq then
    return {
      skillLocked = true,
      requiredLevel = nil,
      skillMessage = "No company work types are available at this yard yet.",
    }
  end
  if level >= bestReq then
    return { skillLocked = false, requiredLevel = bestReq, skillMessage = nil }
  end
  return {
    skillLocked = true,
    requiredLevel = bestReq,
    skillMessage = string.format(
      "Reach Logistics level %d for %s at this yard (you are L%d).",
      bestReq, bestKind or "this work", level
    ),
  }
end

local function startShift(facId)
  if gameplay_vehicleTransfer and gameplay_vehicleTransfer.isOnShift and gameplay_vehicleTransfer.isOnShift() then
    return U.failShift("End your CarGo day before starting a company shift.")
  end
  U.shiftLog("startShift requested", string.format("facId=%s", tostring(facId)))
  local roleplay = U.isRoleplayFacility(facId)
  if not roleplay and not isEmploymentUnlocked() then
    return U.failShift("Company employment is not enabled for this career.")
  end
  if not roleplay and not facilityMatchesEmployer(facId) then
    return U.failShift("You are not employed at this company.", U.diagnoseDispatch(facId, "employerMismatch"))
  end
  if state.shift and state.shift.paused then
    local canResume = (not roleplay and facilityMatchesEmployer(facId))
      or (roleplay and state.shift.originFacId == facId)
      or (roleplay and state.shift.shiftOrgId and facId
          and (function()
            local fac = U.dGenerator() and U.dGenerator().getFacilityById and U.dGenerator().getFacilityById(facId)
            return fac and fac.associatedOrganization == state.shift.shiftOrgId
          end)())
    if canResume then
      local ok = resumeShift(facId)
      if ok then
        U.shiftLog("startShift", "resumed held assignment")
        return U.okShift()
      end
      return U.failShift("Could not continue the held assignment.", U.diagnoseDispatch(facId, "resumeShift"))
    end
    return U.failShift("End your current company shift before starting another.",
      string.format("pausedKind=%s", tostring(state.shift.jobKind)))
  end
  if state.shift then
    if isOnShift() and state.shift.phase == "loopComplete" and not roleplay then
      return startNextRun(facId)
    end
    return U.failShift("End your current company shift before starting another.",
      string.format("phase=%s kind=%s", tostring(state.shift.phase), tostring(state.shift.jobKind)))
  end
  if not roleplay then
    local gate = U.getListingSkillGate(facId)
    if gate.skillLocked then return U.failShift(gate.skillMessage) end
  end
  local job, chooseErr = chooseJob(facId)
  if not job then
    return U.failShift("No company assignments are ready.", chooseErr or U.diagnoseNoJob(facId))
  end
  shiftStartPresentationPending = uiOpen and true or false
  shiftStartPresentationReady = false
  U.shiftLog("startShift dispatch", string.format("jobKind=%s label=%s", tostring(job.kind), tostring(job.label)))
  local ok, assignErr = U.beginAssignmentWithGuidance(facId, job)
  if not ok then
    shiftStartPresentationPending = false
    return U.failShift("Could not issue the company truck.", assignErr or U.diagnoseLoanerFailure(
      U.dGenerator() and U.dGenerator().getFacilityById and U.dGenerator().getFacilityById(facId),
      job,
      { cargoType = job.cargoType, targetLoad = job.standardLoad or job.targetLoad }))
  end
  U.shiftLog("startShift", "assignment begun; waiting for loaner spawn callback if needed")
  return U.okShift({ jobKind = job.kind, label = job.label })
end

local function startShiftGate(facId)
  if gameplay_vehicleTransfer and gameplay_vehicleTransfer.isOnShift and gameplay_vehicleTransfer.isOnShift() then
    return false, U.failShift("End your CarGo day before starting a company shift.")
  end
  local roleplay = U.isRoleplayFacility(facId)
  if not roleplay and not isEmploymentUnlocked() then
    return false, U.failShift("Company employment is not enabled for this career.")
  end
  if not roleplay and not facilityMatchesEmployer(facId) then
    return false, U.failShift("You are not employed at this company.", U.diagnoseDispatch(facId, "employerMismatch"))
  end
  if state.shift and state.shift.paused then
    return false, U.failShift("End or continue the held assignment before selecting a new job.")
  end
  if state.shift then
    if isOnShift() and state.shift.phase == "loopComplete" and not roleplay then
      return "nextRun"
    end
    return false, U.failShift("End your current company shift before starting another.",
      string.format("phase=%s kind=%s", tostring(state.shift.phase), tostring(state.shift.jobKind)))
  end
  return "start"
end

local function startShiftWithJob(facId, selection)
  if U.nextAssignmentTransition then return U.okShift({preparing = true}) end
  if not U.isDevToolsEnabled() then
    return U.failShift("Dev key required.")
  end
  U.shiftLog("startShiftWithJob requested", string.format("facId=%s selection=%s", tostring(facId), dumps(selection)))
  local gate, fail = startShiftGate(facId)
  if not gate then
    return fail
  end
  local job, chooseErr = U.resolveSelectedJob(facId, selection)
  if not job then
    local readyMsg = chooseErr
    if type(readyMsg) == "string" and #readyMsg < 160 and not readyMsg:find("ctx=", 1, true) then
      return U.failShift(readyMsg, U.diagnoseNoJob(facId))
    end
    return U.failShift("Selected job is no longer available.", chooseErr or U.diagnoseNoJob(facId))
  end
  if gate == "nextRun" then
    if not isOnShift() or state.shift.phase ~= "loopComplete" or assignmentStillInProgress() then
      return U.failShift("Finish the current assignment loop first.", U.diagnoseDispatch(facId, "nextRunGate"))
    end
    if not playerNearHomeYard() then
      routeToYard()
      return U.failShift("Return to the company yard before taking another job.", U.diagnoseDispatch(facId, "nextRunAwayFromYard"))
    end
    if dropOffEscrowPending then
      return U.failShift("Still confirming drop-off pay — wait a moment.", U.diagnoseDispatch(facId, "escrow"))
    end
    local previousKind = state.shift and state.shift.jobKind
    if previousKind and not U.isOpenEndedJobKind(previousKind) then
      local paid, wages, bonus = payEscrow()
      if paid > 0 then
        ui_message(U.formatTodaysWagesMessage(paid, wages, bonus), 6, "success")
      end
    end
    local ok, assignErr = U.beginNextAssignment(facId, job)
    if not ok then
      if state.shift and state.shift.phase ~= "loopComplete" then
        state.shift.phase = "loopComplete"
      end
      return U.failShift("Could not issue the company truck.", assignErr or U.diagnoseLoanerFailure(
        U.dGenerator() and U.dGenerator().getFacilityById and U.dGenerator().getFacilityById(facId),
        job,
        { cargoType = job.cargoType, targetLoad = job.standardLoad or job.targetLoad }))
    end
    U.shiftLog("startShiftWithJob nextRun", string.format("from=%s to=%s label=%s",
      tostring(previousKind), tostring(job.kind), tostring(job.label)))
    closeShiftUi()
    closeDropOffUi()
    U.saveEmploymentProgress()
    return U.okShift({ jobKind = job.kind, label = job.label })
  end
  U.shiftLog("startShiftWithJob dispatch", string.format("jobKind=%s label=%s", tostring(job.kind), tostring(job.label)))
  local ok, assignErr = U.beginAssignmentWithGuidance(facId, job)
  if not ok then
    return U.failShift("Could not issue the company truck.", assignErr or U.diagnoseLoanerFailure(
      U.dGenerator() and U.dGenerator().getFacilityById and U.dGenerator().getFacilityById(facId),
      job,
      { cargoType = job.cargoType, targetLoad = job.standardLoad or job.targetLoad }))
  end
  return U.okShift({ jobKind = job.kind, label = job.label })
end

startNextRun = function(facId)
  if U.nextAssignmentTransition then return U.okShift({preparing = true}) end
  if state.shift and state.shift.endAfterAssignment then return false end
  if not isOnShift() or state.shift.phase ~= "loopComplete" or assignmentStillInProgress() then
    return U.failShift("Finish the current assignment loop first.", U.diagnoseDispatch(facId, "nextRunGate"))
  end
  if not playerNearHomeYard() then
    routeToYard()
    return U.failShift("Return to the company yard before taking another job.", U.diagnoseDispatch(facId, "nextRunAwayFromYard"))
  end
  if tryAutoAssignNextRun() then
    closeShiftUi()
    closeDropOffUi()
    return U.okShift({
      jobKind = state.shift and state.shift.jobKind,
      label = state.shift and state.shift.outboundLabel,
    })
  end
  return U.failShift("No further assignments are ready.", U.diagnoseNoJob(facId or state.homeFacId))
end

tryAutoAssignNextRun = function()
  if U.nextAssignmentTransition then return true end
  if state.shift and state.shift.endAfterAssignment then return false end
  if not isOnShift() then return false end
  if dropOffEscrowPending then
    U.shiftLog("tryAutoAssignNextRun", "blocked: drop-off escrow still pending")
    return false
  end
  local shift = state.shift
  if not shift or shift.paused then return false end
  if shift.phase ~= "loopComplete" then return false end
  if assignmentStillInProgress() then return false end
  local facId = state.homeFacId or shift.originFacId
  local previousKind = shift.jobKind
  local job, chooseErr = chooseJob(facId)
  if not job then
    U.shiftLog("tryAutoAssignNextRun", chooseErr or "no job available")
    return false
  end
  -- Finite loops cash out between runs. Open-ended shifts hold pay until End day.
  if not U.isOpenEndedJobKind(previousKind) then
    local paid, wages, bonus = payEscrow()
    if paid > 0 then
      ui_message(U.formatTodaysWagesMessage(paid, wages, bonus), 6, "success")
    end
  end
  -- Damaged / wrong-kind company equipment is returned and replaced inside beginAssignment.
  local ok, assignErr = U.beginNextAssignment(facId, job)
  if not ok then
    U.shiftLog("tryAutoAssignNextRun", assignErr or "beginAssignment failed")
    if state.shift and state.shift.phase ~= "loopComplete" then
      state.shift.phase = "loopComplete"
    end
    return false
  end
  U.shiftLog("tryAutoAssignNextRun", string.format("jobKind=%s label=%s", tostring(job.kind), tostring(job.label)))
  U.saveEmploymentProgress()
  return true
end

local function callShiftAction(actionName, fn, facId)
  local ok, result = pcall(fn, facId)
  if not ok then
    return U.failShift("Shift action crashed: " .. tostring(actionName), tostring(result))
  end
  if type(result) ~= "table" then
    return U.failShift("Shift action returned unexpected value: " .. tostring(actionName), tostring(result))
  end
  return result
end

local function issuedVehiclesStillPresent()
  if not career_modules_inventory then return false end
  for _, inventoryId in ipairs(U.collectCompanyInventoryIds()) do
    if career_modules_inventory.getVehicles()[inventoryId] then
      return true
    end
  end
  return false
end

local function exitDeliveryModeIfActive()
  if U.dGeneral() and U.dGeneral().isDeliveryModeActive and U.dGeneral().isDeliveryModeActive() and U.dGeneral().exitDeliveryMode then
    U.dGeneral().exitDeliveryMode()
  end
end

local function pauseShift()
  return U.dEmploymentShiftRecovery().pauseShift(U.shiftRecoveryContext())
end

local function finishShift()
  if dropOffEscrowPending then
    ui_message("Still confirming drop-off pay — wait a moment before ending the day.", 6, "warning")
    return false
  end
  if state.shift and (state.shift.jobKind == "repo" or isBundleShift(state.shift)) then
    U.cancelEmploymentRepoJob()
  end
  U.reconcileEscrowMoney("finishShift")
  local endingPassengerShift = state.shift and (state.shift.jobKind == "paramedic" or state.shift.jobKind == "bus")
  local openEndedShift = state.shift and U.isOpenEndedJobKind(state.shift.jobKind)
  if endingPassengerShift then state.shift.awaitingCompanyVehicleEntry = nil end
  if state.shift and state.shift.jobKind == "paramedic" and gameplay_ambulance and gameplay_ambulance.requestEndDay then
    gameplay_ambulance.requestEndDay()
  end
  state.ignoreCompanyDamageStrikes = true
  U.assessCompanyDamageBeforePayout()
  local terminateAfterSettlement = state.shift and state.shift.pendingDamageTermination
  U.touchLastWorkAt()
  U.flushEmploymentCache()
  local total, wages, bonus = payEscrow()
  deleteCargoOnCompanyVehicles()
  deleteOrphanedVehicleCargo()
  returnIssuedVehicles()
  U.emptyShift()
  if terminateAfterSettlement then terminateEmploymentForDamage() end
  exitDeliveryModeIfActive()
  U.purgeIndependentTasklist()
  if career_modules_delivery_tasklist and career_modules_delivery_tasklist.sendCargoToTasklist then
    career_modules_delivery_tasklist.sendCargoToTasklist()
  end
  if endingPassengerShift then
    if freeroam_bigMapMode and freeroam_bigMapMode.setNavFocus then freeroam_bigMapMode.setNavFocus(nil) end
    if freeroam_bigMapMode and freeroam_bigMapMode.resetRoute then freeroam_bigMapMode.resetRoute() end
    if core_groundMarkers and core_groundMarkers.setPath then core_groundMarkers.setPath(nil) end
  end
  local wagesMsg = U.formatTodaysWagesMessage(total, wages, bonus, { openEnded = openEndedShift })
  firePhoneNotification("employment.shiftEnded", "Shift ended", wagesMsg, "success")
  ui_message(wagesMsg, 7, "success")
  notifyUi()
  closeShiftUi()
  closeDropOffUi()
  U.saveEmploymentProgress()
  return true
end

U.discardUncollectedParcelPickup = function(shift)
  local parcelMgr = U.dParcel()
  if parcelMgr then
    for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
      if parcelMgr.clearTransientMoveForCargo then
        parcelMgr.clearTransientMoveForCargo(cargoId)
      end
      if parcelMgr.getCargoById and parcelMgr.getCargoById(cargoId)
          and parcelMgr.changeCargoLocation then
        parcelMgr.changeCargoLocation(cargoId, { type = "deleted" })
      end
    end
  end
  shift.assignedCargoIds = {}
  shift.needsRemotePickup = nil
  shift.returnNeedsPickup = nil
  shift.returnPickupFacId = nil
  shift.returnIsBackhaul = nil
end

-- Empty yard return / wrecked / loop complete — no freight left to move.
local function onlyCompanyYardReturnLeft(shift)
  if not shift then return false end
  if shift.wrecked or shift.phase == "loopComplete" then return true end
  if shift.awaitingLoopChoice then return true end
  if shift.phase == "return" and not hasOutstandingReturnWork(shift) then return true end
  -- Player already returned the company loaner(s); nothing left but payout.
  if not issuedVehiclesStillPresent() then
    if shift.phase == "outbound" or shift.phase == "return" then
      local parcelMgr = U.dParcel()
      for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
        local cargo = parcelMgr and parcelMgr.getCargoById and parcelMgr.getCargoById(cargoId)
        if cargo then return false end
      end
      if shift.assignedOfferId then return false end
      if isDistributorHaulShift(shift) and distributorHaulRemaining(shift) > 0 then return false end
      if shift.jobKind == "materials" and materialsAssignmentHasWork() then return false end
      return true
    end
  end
  return false
end

U.playerAtEmployerYard = function(facId)
  if facId and facilityMatchesEmployer(facId) then return true end
  if playerNearHomeYard and playerNearHomeYard() then return true end
  return false
end

U.chargeRemoteEndDayRecoveryFee = function()
  local base = C.REMOTE_END_DAY_TOW_BASE * C.REMOTE_END_DAY_TOW_FRACTION
  if career_economyAdjuster and career_economyAdjuster.getSectionMultiplier then
    base = base * (tonumber(career_economyAdjuster.getSectionMultiplier("delivery")) or 1)
  end
  local fee = math.max(0, math.floor(base + 0.5))
  if fee <= 0 then return 0 end
  if career_modules_playerAttributes and career_modules_playerAttributes.addAttributes then
    career_modules_playerAttributes.addAttributes({ money = -fee }, {
      tags = { "gameplay", "employment", "tow", "fine" },
      label = "Remote company vehicle recovery",
    })
  end
  return fee
end

U.finalAssignmentInProgress = function()
  local shift = state.shift
  if not shift then return false end
  if shift.spawnBlocked then return true end
  if shift.jobKind == "bus" then
    return gameplay_bus and gameplay_bus.isBusRouteActive and gameplay_bus.isBusRouteActive() or false
  end
  if shift.jobKind == "paramedic" then
    if shift.endAfterAssignment and gameplay_ambulance and gameplay_ambulance.hasPatientOnboard then
      return gameplay_ambulance.hasPatientOnboard()
    end
    return gameplay_ambulance and gameplay_ambulance.isAmbulanceJobActive and gameplay_ambulance.isAmbulanceJobActive() or false
  end
  if shift.jobKind == "police" then
    for _, vehicle in pairs(gameplay_traffic and gameplay_traffic.getTrafficData and gameplay_traffic.getTrafficData() or {}) do
      if vehicle.pursuit and (tonumber(vehicle.pursuit.mode) or 0) > 0 then return true end
    end
    return false
  end
  return assignmentStillInProgress() and not onlyCompanyYardReturnLeft(shift)
end

U.yardDropOffPendingForEndDay = function(shift)
  if not shift or shift.wrecked then return false end
  return not U.finalAssignmentInProgress() and U.companyVehiclesAwayFromYard()
end

M.isEndingDay = function()
  return state.shift and state.shift.endAfterAssignment == true or false
end

local function endDay(facId)
  if not isOnShift() then return false end
  if dropOffEscrowPending then
    ui_message("Still confirming drop-off pay — wait a moment before ending the day.", 6, "warning")
    notifyUi()
    return false
  end
  local shift = state.shift
  if shift and shift.jobKind == "materials" and U.finalAssignmentInProgress() then
    shift.endAfterAssignment = nil
    local held = pauseShift()
    if held then U.saveEmploymentProgress() end
    return held
  end
  if shift and shift.jobKind == "materials" and U.yardDropOffPendingForEndDay(shift) then
    routeToYard()
    ui_message("Drop the company truck off at the yard to collect pay and end the day.", 8, "info")
    notifyUi()
    return false
  end
  if shift and shift.jobKind == "paramedic" and not shift.spawnBlocked
      and gameplay_ambulance and gameplay_ambulance.requestEndDay then
    shift.endAfterAssignment = true
    gameplay_ambulance.requestEndDay()
    if not U.finalAssignmentInProgress() then return finishShift() end
    ui_message("Deliver your patient to the hospital to collect pay and end the day.", 8, "info")
    notifyUi()
    return true
  end
  if shift and shift.jobKind == "bus" and not shift.spawnBlocked and gameplay_bus and gameplay_bus.requestEndShift then
    shift.endAfterAssignment = true
    gameplay_bus.requestEndShift(false)
    if not U.finalAssignmentInProgress() then return finishShift() end
    notifyUi()
    return true
  end
  local uncollectedParcelPickup = shift and shift.jobKind == "parcel"
    and ((shift.phase == "outbound" and shift.needsRemotePickup)
      or (shift.phase == "return" and shift.returnNeedsPickup))
  if uncollectedParcelPickup
      and not U.assignedReturnCargoInVehicle(shift) then
    U.discardUncollectedParcelPickup(shift)
    return finishShift()
  end
  if shift and shift.endAfterAssignment then return true end
  if U.finalAssignmentInProgress() then
    shift.endAfterAssignment = true
    ui_message("Final assignment. Finish your current work to collect pay and end the day.", 8, "info")
    notifyUi()
    closeShiftUi()
    return true
  end
  if shift then
    shift.awaitingPark = nil
    shift.parkedNotified = nil
    shift.pendingClockOut = nil
  end
  -- Open-ended work (repo, etc.): always pay out and return the loaner.
  if shift and U.isOpenEndedJobKind(shift.jobKind) then
    return finishShift()
  end
  -- Yard-return-only / wrecked / vehicle already returned: finish from anywhere.
  if onlyCompanyYardReturnLeft(shift) then
    if not U.playerAtEmployerYard(facId) then
      local fee = U.chargeRemoteEndDayRecoveryFee()
      if fee > 0 then
        ui_message(string.format("Away-from-yard recovery: $%d (half tow rate).", fee), 6, "info")
      end
    end
    return finishShift()
  end
  return finishShift()
end

-- The confirmation belongs to a specific active route. A delayed UI reply must
-- never transfer passengers or settle a different shift that started meanwhile.
U.endBusShiftNow = function(expectedRouteId)
  local shift = state.shift
  if not isOnShift() or not shift or shift.jobKind ~= "bus" or shift.spawnBlocked or dropOffEscrowPending then return false end
  if not gameplay_bus or not gameplay_bus.getShiftState or not gameplay_bus.requestEndShift then return false end
  local bus = gameplay_bus.getShiftState()
  if not bus.active or not expectedRouteId or bus.routeId ~= expectedRouteId then return false end
  shift.endAfterAssignment = true
  if not gameplay_bus.requestEndShift(true) or U.finalAssignmentInProgress() then return false end
  return finishShift()
end

local function completePendingClockOut()
  local shift = state.shift
  if not shift or not shift.awaitingPark then return false end
  local mode = shift.pendingClockOut
  if not mode then
    if U.isOpenEndedJobKind(shift.jobKind) then
      mode = "finish"
    elseif onlyCompanyYardReturnLeft(shift) then
      mode = "finish"
    else
      mode = assignmentStillInProgress() and "pause" or "finish"
    end
  end
  shift.awaitingPark = nil
  shift.pendingClockOut = nil
  shift.parkedNotified = nil
  if mode == "pause" then
    return pauseShift()
  end
  return finishShift()
end

U.resetOfferSpawnFlags = function(offer)
  if not offer then return end
  if offer.vehicle and offer.vehicle.inventoryId then
    offer.spawned = true
    offer._spawning = nil
    return
  end
  if offer.vehicle and offer.vehicle.vehId and getObjectByID(offer.vehicle.vehId) then
    offer.spawned = true
    offer._spawning = nil
    return
  end
  offer.spawned = nil
  offer._spawning = nil
end

U.extendOfferExpiry = function(offer, seconds)
  if not offer then return end
  local now = (U.dGeneral() and U.dGeneral().time and U.dGeneral().time()) or 0
  offer.offerExpiresAt = math.max(tonumber(offer.offerExpiresAt) or 0, now + (tonumber(seconds) or 3600))
end

U.assignedParcelFreightAlive = function(shift)
  if not shift or not shift.assignedCargoIds or not shift.assignedCargoIds[1] then return false end
  local parcelMgr = U.dParcel()
  if not (parcelMgr and parcelMgr.getCargoById) then return false end
  for _, cargoId in ipairs(shift.assignedCargoIds) do
    if parcelMgr.getCargoById(cargoId) then return true end
  end
  return false
end

U.hasMissingSavedVehicles = function(shift)
  return U.dEmploymentShiftRecovery().hasMissingSavedVehicles(U.shiftRecoveryContext(), shift)
end

resumeShift = function(facId)
  return U.dEmploymentShiftRecovery().resumeShift(U.shiftRecoveryContext(), facId)
end

local function acceptReturn(facId)
  local shift = state.shift
  if not shift or shift.wrecked or shift.jobKind == "materials" then return false end
  if shift.phase ~= "return" then return false end
  if isDistributorHaulShift(shift) then
    shift.returnIsBackhaul = nil
    shift.returnNeedsPickup = nil
    shift.assignedOfferId = nil
    shift.assignedOfferIds = nil
    shift.returnLabel = "Return the company vehicle to the office"
    shift.returnSubtext = "No return freight — head back to the yard"
    shift.destFacId = state.homeFacId
    shift.destLocation = nil
    shift.destPsPath = nil
    routeToYard()
    refreshTaskGuidance(true)
    notifyUi()
    closeDropOffUi()
    return true
  end
  if shift.assignedOfferId or (shift.assignedCargoIds and shift.assignedCargoIds[1]) then
    if shift.assignedOfferId and U.dVehOffers() and U.dVehOffers().spawnAssignedOffer then
      U.dVehOffers().spawnAssignedOffer(shift.assignedOfferId, false, handleVehicleSpawnResult)
    else
      bindAssignedCargoToIssuedTruck()
    end
    refreshTaskGuidance(true)
    notifyUi()
    closeDropOffUi()
    return true
  end
  if assignReturnLoad(facId or shift.destFacId) then
    refreshTaskGuidance(true)
    notifyUi()
    closeDropOffUi()
    return true
  end
  shift.returnLabel = "Return the company vehicle to the yard"
  shift.destFacId = state.homeFacId
  routeToYard()
  refreshTaskGuidance(true)
  notifyUi()
  closeDropOffUi()
  return true
end

local function quitJob(opts)
  if not isEmployed() then return false end
  opts = type(opts) == "table" and opts or {}
  local silent = opts.silent == true
  local shift = state.shift
  if shift and shift.jobKind == "materials" and U.dMaterials() and U.dMaterials().abandonContract then
    U.dMaterials().abandonContract(nil, { noFine = true, silent = true })
  end
  if shift and (shift.jobKind == "repo" or isBundleShift(shift)) then
    U.cancelEmploymentRepoJob()
  end
  if U.dGeneral() and U.dGeneral().isDeliveryModeActive and U.dGeneral().isDeliveryModeActive() then
    U.dGeneral().exitDeliveryMode(true, true)
  end
  state.ignoreCompanyDamageStrikes = true
  U.assessCompanyDamageBeforePayout()
  returnIssuedVehicles()
  U.emptyShift()
  U.resetEscrow()
  U.clearEmploymentCache()
  U.flushEmploymentCache()
  if not silent then
    firePhoneNotification("employment.shiftEnded", "Left the company", "You are no longer employed at this yard.", "error")
    ui_message("You quit the job.", 6, "warning")
  end
  U.clearOfferedListings()
  notifyUi()
  refreshDeliveryPois()
  return true
end

local function returnAllCompanyVehicles()
  if not (career_modules_loanerVehicles and career_modules_loanerVehicles.returnVehicle and career_modules_inventory) then
    return 0
  end
  return career_modules_loanerVehicles.returnAllCompanyVehicles()
end

U.discardEmploymentCargoForReset = function()
  local parcelMgr = U.dParcel()
  if not (parcelMgr and parcelMgr.getAllCargoCustomFilter and parcelMgr.changeCargoLocation) then return end
  local assigned, companyVehicles = {}, {}
  for _, cargoId in ipairs(state.shift and state.shift.assignedCargoIds or {}) do
    assigned[cargoId] = true
  end
  for inventoryId, vehInfo in pairs(career_modules_inventory and career_modules_inventory.getVehicles() or {}) do
    if vehInfo and vehInfo.loanType == "company" then companyVehicles[inventoryId] = true end
  end
  local cargoToDiscard = parcelMgr.getAllCargoCustomFilter(function(cargo)
    if assigned[cargo.id] then return true end
    local binding = cargo.logisticsBinding
    if binding and companyVehicles[binding.inventoryId] then return true end
    local vehId = cargo.location and cargo.location.vehId
    local inventoryId = vehId and career_modules_inventory
      and career_modules_inventory.getInventoryIdFromVehicleId(vehId)
    return inventoryId and companyVehicles[inventoryId] or false
  end) or {}
  for _, cargo in ipairs(cargoToDiscard) do
    if cargo._transientMove and parcelMgr.clearTransientMoveForCargo then
      parcelMgr.clearTransientMoveForCargo(cargo.id)
    end
    parcelMgr.changeCargoLocation(cargo.id, { type = "deleted" })
  end
end

U.employmentCompanyVehicleIds = function()
  local companyVehicles = {}
  for inventoryId, vehInfo in pairs(career_modules_inventory and career_modules_inventory.getVehicles() or {}) do
    if vehInfo and vehInfo.loanType == "company" then companyVehicles[inventoryId] = true end
  end
  return companyVehicles
end

U.employmentAssignmentCargoFilter = function(cargo)
  if not cargo or not state.shift then return false end
  local shift = state.shift
  for _, cargoId in ipairs(shift.assignedCargoIds or {}) do
    if cargo.id == cargoId then return true end
  end
  if cargo.employmentAssigned then return true end
  if shift.assignedContractId and cargo.data and cargo.data.materialContractId == shift.assignedContractId then
    return true
  end
  local companyVehicles = U.employmentCompanyVehicleIds()
  local binding = cargo.logisticsBinding
  if binding and companyVehicles[binding.inventoryId] then return true end
  local vehId = cargo.location and cargo.location.vehId
  local inventoryId = vehId and career_modules_inventory
    and career_modules_inventory.getInventoryIdFromVehicleId(vehId)
  return inventoryId and companyVehicles[inventoryId] or false
end

U.canAbandonEmploymentAssignment = function()
  if dropOffEscrowPending then return false end
  if not isOnShift() then return false end
  local shift = state.shift
  if not shift or shift.paused then return false end
  if shift.jobKind == "police" or shift.jobKind == "bus" or shift.jobKind == "paramedic" then return false end
  if shift.spawnBlocked then return true end
  if assignmentStillInProgress() then return true end
  if shift.endAfterAssignment and U.finalAssignmentInProgress() then return true end
  return false
end

U.deliveredEmploymentOfferIds = function(shift)
  local delivered = {}
  for _, id in ipairs(shift.deliveredOfferIds or {}) do
    delivered[id] = true
  end
  if isBundleShift(shift) and shift.assignments and shift.assignments.vehicle
      and shift.assignments.vehicle.complete and shift.assignments.vehicle.offerId then
    delivered[shift.assignments.vehicle.offerId] = true
  end
  return delivered
end

U.quoteEmploymentVehicleTaskPenalty = function(shift)
  local vt = career_modules_delivery_vehicleTasks
  if not (vt and vt.getVehicleTasks and vt.getFineForAbandon) then return 0 end
  local offerSet = shiftVehicleOfferIdSet(shift)
  local delivered = U.deliveredEmploymentOfferIds(shift)
  local money = 0
  for _, taskData in ipairs(vt.getVehicleTasks() or {}) do
    local oid = taskData.offer and taskData.offer.id
    if oid and offerSet[oid] and not delivered[oid] and not taskData.remove then
      money = money - (vt.getFineForAbandon(taskData).money or 0)
    end
  end
  return math.max(0, money)
end

U.abandonAssignmentQuote = function()
  if not U.canAbandonEmploymentAssignment() then return 0 end
  local shift = state.shift
  local total = 0
  if shift.jobKind == "materials" then
    local mgr = U.dMaterials()
    local contractId = shift.assignedContractId
    if mgr and mgr.getContractById and contractId then
      local contract = mgr.getContractById(contractId)
      total = total + (contract and contract.abandonmentFine or 0)
    end
  else
    local general = U.dGeneral()
    if general and general.getDeliveryModePenalty then
      local penalty = general.getDeliveryModePenalty(nil, false, U.employmentAssignmentCargoFilter)
      total = total + math.max(0, -(penalty.money or 0))
    end
    total = total + U.quoteEmploymentVehicleTaskPenalty(shift)
  end
  return math.max(0, math.floor(total + 0.5))
end

U.clearEmploymentAssignmentFields = function(shift)
  shift.endAfterAssignment = nil
  shift.spawnBlocked = nil
  shift.assignedCargoIds = {}
  shift.assignedOfferId = nil
  shift.assignedOfferIds = nil
  shift.assignedContractId = nil
  shift.assignments = nil
  shift.repoPendingStart = nil
  shift.needsRemotePickup = nil
  shift.returnNeedsPickup = nil
  shift.returnIsBackhaul = nil
  shift.returnPickupFacId = nil
  shift.returnDeliverLabel = nil
  shift.wrecked = nil
  shift.stringMode = nil
  shift.stops = nil
  shift.stopIndex = nil
  shift.stringCargoIds = nil
  shift.stringStopTotal = nil
  shift.stopsCompleted = nil
  shift.freight = nil
  shift.plannerFreight = nil
  shift.deliveredOfferIds = nil
  shift.distributorHaul = nil
  shift.awaitingPark = nil
  shift.destFacId = nil
  shift.destPsPath = nil
  shift.destLocation = nil
  shift.outboundLabel = nil
  shift.outboundSubtext = nil
  shift.dropOffDepartureRequired = nil
  shift.parcelLoadPending = nil
  shift.parcelLoadRetryAt = nil
  shift.stringRouteLocked = nil
  shift._returnTrailerSpawning = nil
  shift._returnTrailerSpawned = nil
  shift._returnVehicleSpawning = nil
  shift._returnVehicleSpawned = nil
end

U.settleAbandonedAssignmentState = function(shift)
  if issuedVehiclesStillPresent() and not playerNearHomeYard() then
    beginYardReturnForLoopChoice()
    shift.returnLabel = "Return to the company yard"
    shift.returnSubtext = "Assignment abandoned — return to the yard for your next job or to end the day"
    shift.outboundLabel = "Assignment abandoned"
    shift.outboundSubtext = shift.returnSubtext
  else
    offerLoopCompleteChoice({
      label = "Assignment abandoned",
      subtext = "Choose your next job or end your day. Delivery penalties were applied.",
    })
  end
end

U.giveBackEmploymentVehicleTasks = function(shift)
  local vt = career_modules_delivery_vehicleTasks
  if not vt then return end
  local offerSet = shiftVehicleOfferIdSet(shift)
  local delivered = U.deliveredEmploymentOfferIds(shift)
  for _, taskData in ipairs(vt.getVehicleTasks and vt.getVehicleTasks() or {}) do
    local oid = taskData.offer and taskData.offer.id
    if oid and offerSet[oid] and not delivered[oid] and not taskData.remove then
      taskData.giveBack = true
    end
  end
end

U.employmentPenaltyHasCharge = function(penalty)
  if type(penalty) ~= "table" then return false end
  for _, amount in pairs(penalty) do
    if amount ~= 0 then return true end
  end
  return false
end

U.applyEmploymentCargoPenalty = function(penalty)
  if not U.employmentPenaltyHasCharge(penalty) then return end
  if career_modules_playerAttributes and career_modules_playerAttributes.addAttributes then
    career_modules_playerAttributes.addAttributes(penalty, {
      tags = { "gameplay", "delivery", "fine", "employment" },
      label = "Company assignment abandonment",
    })
  end
end

U.abandonEmploymentAssignment = function()
  if not U.canAbandonEmploymentAssignment() then
    return U.failShift("Nothing to abandon on this assignment.")
  end
  local shift = state.shift
  local quotedFine = U.abandonAssignmentQuote()
  U.cancelSpawnBlockedWatch()
  if shift.jobKind == "materials" then
    local mgr = U.dMaterials()
    if mgr and mgr.abandonContract then
      mgr.abandonContract(shift.assignedContractId)
    end
  else
    local general = U.dGeneral()
    local parcelMgr = U.dParcel()
    local penalty = general and general.getDeliveryModePenalty
      and general.getDeliveryModePenalty(nil, false, U.employmentAssignmentCargoFilter) or {}
    if parcelMgr and parcelMgr.getAllCargoCustomFilter and parcelMgr.changeCargoLocation then
      for _, cargo in ipairs(parcelMgr.getAllCargoCustomFilter(U.employmentAssignmentCargoFilter) or {}) do
        if cargo._transientMove and parcelMgr.clearTransientMoveForCargo then
          parcelMgr.clearTransientMoveForCargo(cargo.id)
        end
        parcelMgr.changeCargoLocation(cargo.id, { type = "deleted" })
      end
    end
    U.applyEmploymentCargoPenalty(penalty)
    if general and general.requestUpdateContainerWeights then
      general.requestUpdateContainerWeights()
    end
    U.giveBackEmploymentVehicleTasks(shift)
  end
  U.cancelEmploymentRepoJob()
  U.discardEmploymentCargoForReset()
  if U.dMaterials() and U.dMaterials().clearTaskGuidance then
    U.dMaterials().clearTaskGuidance()
  end
  if U.dGeneral() and U.dGeneral().isDeliveryModeActive and U.dGeneral().isDeliveryModeActive() then
    if U.dGeneral().checkExitDeliveryMode then
      U.dGeneral().checkExitDeliveryMode()
    end
  end
  U.clearEmploymentAssignmentFields(shift)
  local atYard = playerNearHomeYard()
  U.settleAbandonedAssignmentState(shift)
  closeWorldPrompt()
  if dropOffOpen then
    closeDropOffUi()
  end
  refreshDeliveryPois()
  state.dropOffProximityTimer = 0
  if atYard then
    if core_groundMarkers and core_groundMarkers.setPath then
      core_groundMarkers.setPath(nil)
    end
    if freeroam_bigMapMode and freeroam_bigMapMode.resetRoute then
      freeroam_bigMapMode.resetRoute()
    end
  end
  if gameplay_markerInteraction and gameplay_markerInteraction.setForceReevaluateOpenPrompt then
    gameplay_markerInteraction.setForceReevaluateOpenPrompt(true)
  end
  if career_modules_delivery_tasklist and career_modules_delivery_tasklist.sendCargoToTasklist then
    career_modules_delivery_tasklist.sendCargoToTasklist()
  end
  refreshTaskGuidance(true)
  U.saveEmploymentProgress()
  notifyUi()
  local msg = quotedFine > 0
    and string.format("Assignment abandoned. Penalty: $%d", quotedFine)
    or "Assignment abandoned."
  ui_message(msg, 8, quotedFine > 0 and "warning" or "info")
  return U.okShift({ abandonFine = quotedFine })
end

local function clearShiftKeepEmployment(opts)
  opts = opts or {}
  U.cancelSpawnBlockedWatch()
  if U.dMaterials() and U.dMaterials().abandonContract then
    U.dMaterials().abandonContract(nil, { noFine = true, silent = true })
  end
  if U.dMaterials() and U.dMaterials().clearTaskGuidance then
    U.dMaterials().clearTaskGuidance()
  end
  U.cancelEmploymentRepoJob()
  U.discardEmploymentCargoForReset()
  local vt = career_modules_delivery_vehicleTasks
  if vt and vt.abandonAllVehicleTasks then
    vt.abandonAllVehicleTasks()
  end
  if U.dGeneral() and U.dGeneral().isDeliveryModeActive and U.dGeneral().isDeliveryModeActive() then
    U.dGeneral().exitDeliveryMode()
  end
  local removed = returnAllCompanyVehicles()
  U.emptyShift()
  if opts.keepEscrow ~= true then
    U.resetEscrow()
  end
  if core_groundMarkers and core_groundMarkers.setPath then
    core_groundMarkers.setPath(nil)
  end
  if freeroam_bigMapMode and freeroam_bigMapMode.resetRoute then
    freeroam_bigMapMode.resetRoute()
  end
  U.flushEmploymentCache()
  return removed
end

-- Wipe a stuck pre-fix shift: trucks, assignment, escrow, tasklist. Keep the job.
local function resetShiftAndEquipment()
  if not U.isDevToolsEnabled() then
    log("W", "employment", "resetShiftAndEquipment blocked: no valid dev key")
    return false
  end
  local removed = clearShiftKeepEmployment()
  if career_saveSystem and career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end
  firePhoneNotification("employment.shiftEnded", "Shift reset", "Company trucks returned. Clock in for a clean assignment.", "info")
  ui_message(string.format("Company shift reset (%d truck%s returned). You are still employed.", removed, removed == 1 and "" or "s"), 7, "info")
  notifyUi()
  closeShiftUi()
  closeDropOffUi()
  return true
end

local function rollJobListings()
  if not U.isDevToolsEnabled() then
    log("W", "employment", "rollJobListings blocked: no valid dev key")
    return { ok = false, message = "Dev key required." }
  end
  U.clearOfferedListings()
  local ui = getUiState()
  ui.rollOk = true
  return ui
end

U.softClearStickyShift = function(reason)
  if not state.shift then return false end
  U.shiftLog("softClearStickyShift", tostring(reason or "irrecoverable"))
  local removed = clearShiftKeepEmployment()
  firePhoneNotification(
    "employment.shiftEnded",
    "Shift cleared",
    "Company equipment returned. You are still employed — clock in for a new assignment.",
    "info")
  ui_message(
    string.format(
      "Could not recover that shift (%d truck%s returned). You are still employed.",
      removed,
      removed == 1 and "" or "s"),
    8,
    "warning")
  notifyUi()
  closeShiftUi()
  closeDropOffUi()
  return true
end



U.abortInterruptedShiftOnLoad = function()
  return U.dEmploymentShiftRecovery().abortInterruptedShiftOnLoad(U.shiftRecoveryContext())
end

U.isAssignedFreight = function(shift, item, kind)
  return U.dEmploymentShiftRecovery().isAssignedFreight(U.shiftRecoveryContext(), shift, item, kind)
end
U.captureFreight = function(shift, api)
  return U.dEmploymentShiftRecovery().captureFreight(U.shiftRecoveryContext(), shift, api)
end
U.restoreFreight = function(shift, api)
  return U.dEmploymentShiftRecovery().restoreFreight(U.shiftRecoveryContext(), shift, api)
end

U.reconcileLoadedShift = function()
  return U.dEmploymentShiftRecovery().reconcileLoadedShift(U.shiftRecoveryContext())
end

local function applyForJob(orgIdOrListing, facId, endCurrentEmployment)
  local orgId, resolvedFacId = orgIdOrListing, facId
  if type(orgIdOrListing) == "table" then
    orgId = orgIdOrListing.orgId
    resolvedFacId = orgIdOrListing.facId
  end
  orgId = orgId ~= nil and tostring(orgId) or nil
  resolvedFacId = resolvedFacId ~= nil and tostring(resolvedFacId) or nil
  facId = resolvedFacId

  local function fail(reason)
    reason = tostring(reason or "Application failed.")
    U.shiftLog("applyForJob fail", string.format("orgId=%s facId=%s :: %s", tostring(orgId), tostring(facId), reason))
    ui_message(reason, 8, "warning")
    firePhoneNotification("employment.applyFailed", "Application failed", reason, "warning")
    notifyUi()
    return { ok = false, reason = reason, orgId = orgId, facId = facId }
  end

  U.shiftLog("applyForJob", string.format("orgId=%s facId=%s", tostring(orgId), tostring(facId)))
  if career_modules_delivery_broker and career_modules_delivery_broker.hasObligations() then
    return fail('Finish or cancel Broker work and return rentals before applying for employment.')
  end
  U.ensureRehireSaveV3()
  U.syncUnlockFlagsForDeliveryLevel()

  if not isEmploymentUnlocked() then
    return fail("Company employment is not enabled for this career.")
  end

  local org = getOrg(orgId)
  if not org then
    return fail(string.format("Company id '%s' is not loaded.", tostring(orgId)))
  end
  local fac = U.dGenerator() and U.dGenerator().getFacilityById and U.dGenerator().getFacilityById(facId)
  local profile = fac and U.classifyEmployer(org, fac) or nil
  if not profile and U.dGenerator() and U.dGenerator().getFacilitiesForOrganizationId then
    for _, candidate in ipairs(U.dGenerator().getFacilitiesForOrganizationId(orgId) or {}) do
      profile = U.classifyEmployer(org, candidate)
      if profile then
        facId = candidate.id
        fac = candidate
        break
      end
    end
  end
  if U.isRoleplayProfile(profile) then
    return fail("No application needed — clock in at the station when you're ready.")
  end
  if isOnShift() or (state.shift and state.shift.paused) then
    return fail("Finish your current shift before applying for another job.")
  end
  if isEmployed() and state.employerOrgId == orgId and state.homeFacId == facId then
    return fail("You already work at this yard.")
  end
  if isEmployed() and endCurrentEmployment ~= true then
    return fail("Confirm ending your current employment before applying elsewhere.")
  end
  if not U.canRehireOrg(orgId) then
    local days = U.simDaysRemaining(U.getRehireBlockUntil(orgId))
    return fail(string.format("You cannot reapply to this company for %d more sim day%s.", days, days == 1 and "" or "s"))
  end
  if state.pendingApplications[1] then
    return fail("You already have an application pending.")
  end
  if not fac or fac.associatedOrganization ~= orgId then
    local facilities = U.dGenerator() and U.dGenerator().getFacilitiesForOrganizationId and U.dGenerator().getFacilitiesForOrganizationId(orgId) or {}
    facId = nil
    fac = nil
    for _, candidate in ipairs(facilities) do
      if canEmployAt(orgId, candidate.id, org) then
        facId = candidate.id
        fac = candidate
        break
      end
    end
  end
  local canWork, workProfile = canEmployAt(orgId, facId, org)
  if not facId or not canWork then
    local gate = facId and U.getListingSkillGate(facId, workProfile or profile) or nil
    if gate and gate.skillMessage then
      return fail(gate.skillMessage)
    end
    local kinds = facId and getAssignableKinds(facId) or {}
    local kindBits = {}
    for k, v in pairs(kinds) do
      if v then table.insert(kindBits, k) end
    end
    return fail(string.format(
      "Yard '%s' has no issuable work yet (profile=%s kinds=%s). Fac assoc=%s.",
      tostring(facId),
      tostring(workProfile or profile),
      (#kindBits > 0 and table.concat(kindBits, ",") or "none"),
      tostring(fac and fac.associatedOrganization)
    ))
  end
  do
    local gate = U.getListingSkillGate(facId, workProfile or profile)
    if gate and gate.skillLocked and gate.skillMessage then
      return fail(gate.skillMessage)
    end
  end
  if isEmployed() then
    quitJob({ silent = true })
  end
  if not state.activeMapId or state.activeMapId == "" then
    state.activeMapId = U.currentMapId()
  end
  table.insert(state.pendingApplications, {
    orgId = orgId,
    facId = facId,
    appliedAt = U.nowSim(),
    hireAt = U.nowSim() + (U.isDevToolsEnabled() and C.HIRE_DELAY_SIM or C.HIRE_DELAY_SIM_RELEASE),
  })
  U.flushEmploymentCache()
  local businessName = U.getBusinessDisplayName(facId, orgId)
  ui_message(string.format("Application sent to %s. You'll get a notification if you're hired.", businessName), 7, "info")
  U.shiftLog("applyForJob ok", string.format("%s pending fac=%s", businessName, tostring(facId)))
  notifyUi()
  return { ok = true, orgId = orgId, facId = facId, name = businessName }
end

local function completeHire(application)
  local broker = career_modules_delivery_broker
  if broker and broker.hasObligations() then
    state.pendingApplications = {}
    ui_message('Finish or cancel Broker work and return rentals before accepting employment.', 8, 'warning')
    notifyUi()
    return false
  end
  state.employerOrgId = application.orgId
  state.homeFacId = application.facId
  state.hiredAt = U.nowSim()
  state.lastWorkAt = state.hiredAt
  state.hiredWorldMinute = U.nowWorldMinutes()
  state.lastWorkWorldMinute = state.hiredWorldMinute
  state.pendingApplications = {}
  state.ignoreCompanyDamageStrikes = nil
  U.resetEscrow()
  U.resetDamageStrikes()
  U.flushEmploymentCache()
  U.clearOfferedListings()
  local businessName = U.getBusinessDisplayName(application.facId, application.orgId)
  local title = application.headhunter and "Headhunter placement" or "You're hired"
  local message = application.headhunter
    and string.format("You're now at %s — report to the yard for %s work.", businessName, application.milestoneLabel or "company")
    or string.format("You've been hired at %s. Report to the office for your first assignment.", businessName)
  firePhoneNotification(
    application.headhunter and "employment.headhunter" or "employment.hired",
    title,
    message,
    "success"
  )
  notifyUi()
  if application.headhunter then
    routeToYard()
  else
    refreshDeliveryPois()
  end
end

local function acceptHeadhunterOffer()
  local broker = career_modules_delivery_broker
  if broker and broker.hasObligations() then
    ui_message('Finish or cancel Broker work and return rentals before accepting employment.', 8, 'warning')
    return false
  end
  local offer = state.headhunter and state.headhunter.pending
  if not offer then return false end
  if not isEmploymentUnlocked() then return false end
  if isOnShift() or (state.shift and state.shift.paused) then
    ui_message("End your shift before switching employers.", 6, "warning")
    return false
  end
  local orgId, facId = offer.orgId, offer.facId
  local milestoneLabel = offer.label
  local milestoneId = offer.id
  state.headhunter.pending = nil
  if milestoneId then
    state.headhunter.offered = state.headhunter.offered or {}
    state.headhunter.offered[milestoneId] = true
  end
  quitJob({ silent = true })
  completeHire({
    orgId = orgId,
    facId = facId,
    headhunter = true,
    milestoneLabel = milestoneLabel,
  })
  ui_message(string.format("Switched employers for %s work.", milestoneLabel or "company"), 7, "success")
  return true
end

local function dismissHeadhunterOffer()
  if not (state.headhunter and state.headhunter.pending) then return false end
  local pending = state.headhunter.pending
  local milestone
  for _, m in ipairs(U.HEADHUNTER_MILESTONES) do
    if m.id == pending.id then milestone = m break end
  end
  state.headhunter.pending = nil
  -- Only consume the milestone when the yard actually offered that logistic.
  if milestone and U.pendingHeadhunterMatchesMilestone(pending, milestone) then
    state.headhunter.offered = state.headhunter.offered or {}
    state.headhunter.offered[pending.id] = true
  end
  notifyUi()
  return true
end

U.facilityPreview = function(fac)
  if type(fac) == "table" and fac.preview then return fac.preview end
  local facId = type(fac) == "table" and fac.id or fac
  local g = career_modules_delivery_generator
  local f = facId and g and g.getFacilityById and g.getFacilityById(facId)
  return f and f.preview or nil
end

U.buildEmploymentListing = function(orgId, org, fac, profile, canWork)
  local kinds = getAssignableKinds(fac.id)
  local gate = U.getListingSkillGate(fac.id, profile)
  local skillLocked = (not canWork) or (gate and gate.skillLocked) or false
  local offerings = U.buildFacilityOfferings(fac.id, profile, kinds)
  return U.dEmploymentUi().formatListing({
    orgId = orgId,
    orgName = getOrgDisplayName(org, orgId),
    facId = fac.id,
    facName = translateUiText(fac.name, fac.id),
    offerings = offerings,
    employerProfile = profile,
    rehireBlocked = not U.canRehireOrg(orgId),
    rehireDaysRemaining = U.simDaysRemaining(U.getRehireBlockUntil(orgId)),
    skillLocked = skillLocked,
    preview = U.facilityPreview(fac),
    requiredLevel = gate and gate.requiredLevel or nil,
    skillMessage = gate and gate.skillMessage or nil,
  })
end

local function getListings()
  U.syncUnlockFlagsForDeliveryLevel()
  local listings = {}
  if not isEmploymentUnlocked() then
    return listings
  end
  local gen = U.ensureDeliveryGenerator()
  U.dLoanerCaps()
  if not (freeroam_organizations and freeroam_organizations.getOrganizations and gen) then
    return listings
  end
  local general = U.dGeneral()
  if general and general.ensureSetupForCurrentMap then
    general.ensureSetupForCurrentMap()
  end
  if gen.getSetupLevelIdentifier and gen.getSetupLevelIdentifier() ~= U.currentMapId() then
    return listings
  end
  local organizations = freeroam_organizations.getOrganizations()
  if type(organizations) ~= "table" then
    return listings
  end
  for orgId, org in pairs(organizations) do
    local facilities = gen.getFacilitiesForOrganizationId(orgId) or {}
    for _, fac in ipairs(facilities) do
      local canWork, profile = canEmployAt(orgId, fac.id, org)
      if profile and not U.isRoleplayProfile(profile) then
        table.insert(listings, U.buildEmploymentListing(orgId, org, fac, profile, canWork))
      end
    end
  end
  table.sort(listings, function(a, b)
    if (not a.skillLocked) ~= (not b.skillLocked) then
      return not a.skillLocked
    end
    return tostring(a.facName) < tostring(b.facName)
  end)

  local now = U.nowSim()
  local forceRefresh = false
  if not state.offeredFacIds or not state.offeredFacIds[1] then
    forceRefresh = true
  elseif state.offeredListingsAt and (now - (tonumber(state.offeredListingsAt) or 0)) >= C.LISTING_REFRESH_SIM then
    forceRefresh = true
  end
  local shown = U.selectOfferedListings(listings, C.LISTING_OFFER_COUNT, state.offeredFacIds, forceRefresh)
  state.offeredFacIds = {}
  for _, listing in ipairs(shown) do
    table.insert(state.offeredFacIds, listing.facId or listing.orgId)
  end
  if forceRefresh or not state.offeredListingsAt then
    state.offeredListingsAt = now
  end
  return shown
end

local function formatAssignment(facId)
  local shift = state.shift
  if not shift then return nil end
  local atYard = false
  if facId then
    local fac = U.dGenerator() and U.dGenerator().getFacilityById and U.dGenerator().getFacilityById(facId)
    atYard = facilityMatchesEmployer(facId)
      or (shift.originFacId and shift.originFacId == facId)
      or (shift.shiftOrgId and fac and fac.associatedOrganization == shift.shiftOrgId)
      or false
  end
  local held = shift.paused and true or false
  local spawnBlocked = shift.spawnBlocked and true or false
  local inProgress = assignmentStillInProgress()
  local openEnded = U.isOpenEndedJobKind(shift.jobKind)
  local loopComplete = shift.phase == "loopComplete" and not inProgress
  local busState = shift.jobKind == "bus" and gameplay_bus and gameplay_bus.getShiftState and gameplay_bus.getShiftState() or nil
  local useParamedicGuidance = shift.jobKind == "paramedic" and gameplay_ambulance and gameplay_ambulance.getEmploymentTaskGuidance and true or false
  local paramedicGuidance = useParamedicGuidance and gameplay_ambulance.getEmploymentTaskGuidance() or nil
  local busGuidance
  if busState and not busState.paused and not shift.endAfterAssignment then
    busGuidance = gameplay_bus.getEmploymentTaskGuidance and gameplay_bus.getEmploymentTaskGuidance()
  end
  local canAbandon = U.canAbandonEmploymentAssignment()
  local yardDropOffPending = shift.jobKind == "materials" and U.yardDropOffPendingForEndDay(shift)
  return U.dEmploymentUi().formatAssignment({
    phase = shift.phase,
    jobKind = shift.jobKind,
    cargoType = shift.cargoType,
    outboundLabel = shift.outboundLabel,
    outboundSubtext = shift.outboundSubtext,
    returnLabel = shift.returnLabel,
    returnSubtext = shift.returnSubtext,
    returnDeliverLabel = shift.returnDeliverLabel,
    returnIsBackhaul = shift.returnIsBackhaul,
    assignedReturnCargoInVehicle = U.assignedReturnCargoInVehicle(shift),
    wrecked = shift.wrecked,
    endAfterAssignment = shift.endAfterAssignment,
    awaitingPark = shift.awaitingPark,
    stringMode = shift.stringMode,
    stopIndex = shift.stopIndex,
    stopCount = shift.stops and #shift.stops or nil,
    stringStopTotal = shift.stringStopTotal,
    hasStops = shift.stops and true or false,
    spawnBlocked = spawnBlocked,
    spawnBlockedReady = shift.spawnBlocked and shift.spawnBlocked.ready,
    held = held,
    atYard = atYard,
    inProgress = inProgress,
    openEnded = openEnded,
    loopComplete = loopComplete,
    isBundle = isBundleShift(shift),
    isDistributorHaul = isDistributorHaulShift(shift),
    distributorRemaining = distributorHaulRemaining(shift),
    dropOffEscrowPending = dropOffEscrowPending,
    vehiclesParked = companyVehiclesParked(),
    busState = busState,
    useParamedicGuidance = useParamedicGuidance,
    paramedicGuidance = paramedicGuidance,
    busGuidance = busGuidance,
    accident = U.accidentUi and U.accidentUi(shift) or nil,
    canReportAccident = U.canReportAccident and U.canReportAccident() or false,
    canEndBusShiftNow = busState and busState.active and busState.routeId ~= nil and not held and not spawnBlocked and not dropOffEscrowPending or false,
    holdsOnEndDay = shift.jobKind == "materials" and inProgress and not onlyCompanyYardReturnLeft(shift) and true or false,
    canSpawnBlockedEquipment = spawnBlocked and state.shift.spawnBlocked.ready == true and not state.shift.spawnBlocked.retryInFlight,
    yardDropOffPending = yardDropOffPending,
    canEndDay = (not held) and isOnShift() and not dropOffEscrowPending and not yardDropOffPending,
    canAbandonAssignment = canAbandon,
    abandonFine = canAbandon and U.abandonAssignmentQuote() or 0,
    canNextRun = (not shift.endAfterAssignment) and (not held) and (not spawnBlocked) and loopComplete
      and (atYard or U.playerAtEmployerYard(facId)) and not dropOffEscrowPending,
    canContinue = held and atYard,
    shiftAssignments = getShiftAssignmentsForUi(shift),
  })
end

local function getAssignedVehiclesForUi(shift)
  if not shift or not career_modules_inventory then return {} end
  local ids, seen = {}, {}
  local function addId(inventoryId, role)
    if inventoryId == nil then return end
    local key = tostring(inventoryId)
    if seen[key] then return end
    seen[key] = true
    ids[#ids + 1] = { id = inventoryId, role = role }
  end
  for _, inventoryId in ipairs(shift.issuedInventoryIds or {}) do
    addId(inventoryId, "Company vehicle")
  end
  local offerManager = U.dVehOffers()
  for offerId in pairs(shiftVehicleOfferIdSet(shift)) do
    local offer = offerManager and offerManager.getOfferById and offerManager.getOfferById(offerId)
    addId(offer and offer.vehicle and offer.vehicle.inventoryId, "Assigned vehicle")
  end
  return U.dEmploymentUi().formatAssignedVehicles(ids, career_modules_inventory)
end

getUiState = function(facId)
  facId = facId or (state.shift and state.shift.originFacId) or U.roleplayPhoneFacId
  U.ensureRehireSaveV3()
  U.syncUnlockFlagsForDeliveryLevel()
  local listings = {}
  local ok, result = pcall(getListings)
  if ok and type(result) == "table" then
    listings = result
  else
    log("E", "employment", "getListings failed: " .. tostring(result))
  end
  local org = getOrg(state.employerOrgId)
  local pending = state.pendingApplications[1]
  local unlocked = isEmploymentUnlocked()
  local viewProfile, viewOrg, viewFac = U.getFacilityEmployerProfile(facId)
  local displayOrgId = state.employerOrgId
  local displayOrg = org
  if state.shift and state.shift.shiftOrgId then
    displayOrgId = state.shift.shiftOrgId
    displayOrg = getOrg(displayOrgId) or displayOrg
  elseif U.isRoleplayProfile(viewProfile) and viewFac then
    displayOrgId = viewFac.associatedOrganization
    displayOrg = viewOrg or displayOrg
  end
  local displayFacId = state.homeFacId
  if state.shift and state.shift.originFacId then
    displayFacId = state.shift.originFacId
  elseif U.isRoleplayProfile(viewProfile) and viewFac then
    displayFacId = viewFac.id
  end
  local businessName = U.getBusinessDisplayName(displayFacId, displayOrgId)
  local employerRepLevel = displayOrgId and getRepLevel(displayOrg) or nil
  local employerRepLabel = displayOrgId and U.getOrgReputationLabel(displayOrg, employerRepLevel) or nil
  local skillLevel, skillLabel = U.uiSkillProgress(viewProfile, viewFac, viewOrg)
  local companyShare = 0.5
  if employerRepLevel ~= nil and career_modules_reputation and career_modules_reputation.getCompanyShareValue then
    companyShare = tonumber(career_modules_reputation.getCompanyShareValue(employerRepLevel)) or companyShare
  end
  local commissionPercent = U.dEmploymentUi().commissionPercent(companyShare)
  local employerOfferings = {}
  local companyVehicles = {}
  local offeringFacId = displayFacId or facId
  if offeringFacId then
    local offeringProfile, offeringOrg, offeringFac = U.getFacilityEmployerProfile(offeringFacId)
    local assignableKinds = getAssignableKinds(offeringFacId)
    employerOfferings = U.buildFacilityOfferings(offeringFacId, offeringProfile, assignableKinds)
    local caps = U.dLoanerCaps()
    if caps and caps.getCompanyFleetForUi then
      local fleetMaterialTypes = {}
      if assignableKinds.materials then
        for cargoType in pairs(U.facilityMaterialTypes(offeringFac)) do
          local flag = MATERIAL_TYPE_UNLOCK_FLAGS[cargoType]
          if flag and U.hasUnlockFlag(flag) then fleetMaterialTypes[cargoType] = true end
        end
      end
      companyVehicles = caps.getCompanyFleetForUi(offeringFac, {
        parcel = assignableKinds.parcel,
        trailer = assignableKinds.trailer,
        repo = assignableKinds.repo,
        vehicle = assignableKinds.vehicle,
        distributorHaul = facilityIssuesDistributorHaul(offeringFac),
        materialTypes = fleetMaterialTypes,
      })
    end
  end
  local roleplaySetup = (not state.shift) and U.buildRoleplaySetupUi(viewProfile, viewFac, facId) or nil
  return U.dEmploymentUi().formatUiState({
    employed = isEmployed() and true or false,
    onShift = isOnShift() and true or false,
    roleplayFacility = U.isRoleplayProfile(viewProfile) and true or false,
    roleplaySetup = roleplaySetup,
    canClockInHere = (function()
      if U.isRoleplayProfile(viewProfile) then
        if M.blocksRoleplay and M.blocksRoleplay() then return false end
        return true
      end
      return facilityMatchesEmployer(facId) and true or false
    end)(),
    employerOrgId = displayOrgId,
    employerName = businessName,
    employerPreview = (function()
      local g = career_modules_delivery_generator
      local f = displayFacId and g and g.getFacilityById and g.getFacilityById(displayFacId)
      return f and f.preview or nil
    end)(),
    employerRepLevel = employerRepLevel,
    employerRepLabel = employerRepLabel,
    commissionPercent = commissionPercent,
    employerOfferings = employerOfferings,
    companyVehicles = companyVehicles,
    assignedVehicles = getAssignedVehiclesForUi(state.shift),
    shiftStartPending = shiftStartPresentationPending and true or false,
    shiftStartReady = shiftStartPresentationReady and true or false,
    logisticsEmployerOrgId = state.employerOrgId,
    logisticsEmployerName = U.getBusinessDisplayName(state.homeFacId, state.employerOrgId),
    homeFacId = state.homeFacId,
    pending = pending and {
      orgId = pending.orgId,
      orgName = U.getBusinessDisplayName(pending.facId, pending.orgId),
      facId = pending.facId,
      facName = U.getBusinessDisplayName(pending.facId, pending.orgId),
    } or nil,
    assignment = formatAssignment(facId),
    canReportAccident = U.canReportAccident and U.canReportAccident() or false,
    escrowMoney = U.reconcileEscrowMoney("getUiState"),
    escrowLegs = state.escrow.legs or {},
    surgeBonusHeld = escrowSurgeBonusTotal(),
    damageStrikeCount = U.getDamageStrikeCount(),
    showDamageNotice = U.getDamageStrikeCount() > 0,
    damageStatus = U.dEmploymentUi().formatDamageStatus(
      U.getDamageStrikeCount(),
      C.DAMAGE_STRIKE_WARN_COUNT,
      C.DAMAGE_STRIKE_DOCK_COUNT,
      C.DAMAGE_STRIKE_DOCK_PERCENT
    ),
    listings = listings,
    atEmployerYard = facId and facilityMatchesEmployer(facId) or false,
    deliveryLevel = getDeliveryLevel(),
    skillLevel = tonumber(skillLevel) or 0,
    skillLabel = skillLabel,
    unlocked = unlocked,
    apprenticeship = isApprenticeshipEnabled(),
    independentCargoLevel = C.INDEPENDENT_CARGO_LEVEL,
    devTools = U.isDevToolsEnabled(),
    headhunterOffer = state.headhunter and state.headhunter.pending or nil,
  })
end

local function getDropOffUiState()
  local shift = state.shift
  if not dropOffEscrowPending and shift and dropOffFacId and facilityMatchesEmployer(dropOffFacId) then
    if not U.isBundleHaulBackhaulPending(shift)
        and (shift.awaitingLoopChoice
          or (shift.phase == "return" and not hasOutstandingReturnWork(shift))) then
      afterReturnDelivered()
      shift = state.shift
    end
  end
  local ui = getUiState(dropOffFacId)
  ui.facilityId = dropOffFacId
  ui.parkingSpotPath = dropOffPsPath
  ui.canConfirm = (not dropOffEscrowPending) and hasAssignedDropOffHere(dropOffFacId, dropOffPsPath)
  if ui.canConfirm then
    lastDropOffParkingLevels = U.getDropOffParkingLevels(dropOffFacId, dropOffPsPath)
  end
  ui.parkingLevels = lastDropOffParkingLevels
  ui.progressRewards = nil
  ui.repDelta = lastDropOffProgress
  return ui
end

U.nextAssignmentVehicle = function(shift)
  if shift.jobKind == "vehicle" and not shift.distributorHaul then
    local mgr = U.dVehOffers()
    local offer = mgr and mgr.getOfferById and mgr.getOfferById(shift.assignedOfferId)
    local vehId = offer and offer.spawned and offer.vehicle and offer.vehicle.vehId
    return vehId and getObjectByID(vehId) and vehId or nil
  end
  for _, id in ipairs(shift.personalVehicleId and {shift.personalVehicleId} or shift.issuedInventoryIds or {}) do
    local candidateId = career_modules_inventory.getVehicleIdFromInventoryId(id)
    local info = career_modules_inventory.getVehicles()[id]
    if candidateId and getObjectByID(candidateId) and not U.isCompanyTrailer(info, candidateId) then
      return candidateId, id
    end
  end
end

U.requestNextAssignmentEntry = function(transition, vehId, inventoryId)
  transition.enterAttempts = (transition.enterAttempts or 0) + 1
  U.shiftLog("next assignment", string.format("enter vehicle %s attempt %d", tostring(vehId), transition.enterAttempts))
  if transition.enterAttempts == 1 and inventoryId and career_modules_inventory.enterVehicle then
    career_modules_inventory.enterVehicle(inventoryId)
    return
  end
  if gameplay_walk and gameplay_walk.setWalkingMode then
    gameplay_walk.setWalkingMode(false, nil, nil, true)
  end
  be:enterVehicle(0, getObjectByID(vehId))
end

U.stepRetryDue = function(transition, dt)
  transition.stepWait = (transition.stepWait or 0) + dt
  if transition.stepWait < (transition.nextRetryAt or 0) then return false end
  transition.nextRetryAt = transition.stepWait + U.NEXT_ASSIGNMENT_RETRY_S
  return true
end

U.tickNextAssignmentTransition = function(dtReal, dtSim)
  local transition = U.nextAssignmentTransition
  if not transition then return end
  if state.employerOrgId ~= transition.employerOrgId then
    U.finishNextAssignmentTransition()
    return
  end
  local dt = tonumber(dtReal) or 0
  transition.elapsed = transition.elapsed + dt
  local shift = state.shift
  if transition.elapsed >= U.NEXT_ASSIGNMENT_TIMEOUT_S then
    local label = U.NEXT_ASSIGNMENT_STEP_LABELS[transition.step] or "preparing the job"
    U.shiftLog("next assignment", string.format("timed out while %s", label))
    U.handleAssignmentStartFailure("Assignment preparation timed out while " .. label .. ".", {spawnFallbackAttempted = true})
    return
  end
  local function step(name)
    U.setNextAssignmentStep(transition, name)
  end
  if transition.step == "screen" or not shift then return end
  if state.companyEquipmentHandoff then
    step("returnEquipment")
    return
  end
  if shift.spawnBlocked then
    U.handleAssignmentStartFailure("The company vehicle parking area is blocked.")
    return
  end
  if transition.equipmentShift ~= shift and transition.readyShift ~= shift then
    step("spawn")
    return
  end
  local vehId, inventoryId = U.nextAssignmentVehicle(shift)
  if not vehId then
    step("spawn")
    return
  end
  if be:getPlayerVehicleID(0) ~= vehId then
    step("enter")
    transition.settled = 0
    if U.stepRetryDue(transition, dt) then
      U.requestNextAssignmentEntry(transition, vehId, inventoryId)
    end
    return
  end
  shift.awaitingCompanyVehicleEntry = nil
  if transition.deferredWork then
    local job = transition.deferredWork
    transition.deferredWork = nil
    step("load")
    activateAssignedWork(job)
    return
  end
  if shift.jobKind == "repo" then
    local repo = U.dRepo()
    if not (repo and repo.isEmploymentPickupReady and repo.isEmploymentPickupReady()) then
      step("prepare")
      return
    end
    U.markNextAssignmentReady(shift)
  end
  if U.bindAssignedInFlight or shift.parcelLoadPending then
    step("load")
    transition.cargoWait = (transition.cargoWait or 0) + dt
    local limit = U.bindAssignedInFlight and U.NEXT_ASSIGNMENT_CARGO_QUERY_TIMEOUT_S or U.NEXT_ASSIGNMENT_RETRY_S
    if transition.cargoWait >= limit then
      transition.cargoWait = 0
      if U.bindAssignedInFlight then
        U.shiftLog("next assignment", "cargo container query timed out; retrying")
        U.bindAssignedInFlight = false
      end
      shift.parcelLoadRetryAt = nil
      bindAssignedCargoToIssuedTruck()
    end
    return
  end
  transition.cargoWait = 0
  if transition.readyShift ~= shift then
    step(shift.jobKind == "parcel" and "load" or "prepare")
    return
  end
  step("settle")
  transition.settled = (transition.settled or 0) + dt
  if transition.settled < U.NEXT_ASSIGNMENT_SETTLE_S then return end
  routeCurrentAssignment()
  U.refreshActiveTaskGuidance()
  if state.shift ~= shift or U.nextAssignmentTransition ~= transition then return end
  U.saveEmploymentProgress()
  U.finishNextAssignmentTransition()
  ui_message(shift.outboundLabel or "Next assignment ready.", 6, "info")
end

local function onUpdate(dtReal, dtSim)
  if not (career_career and career_career.isActive and career_career.isActive()) then
    U.finishNextAssignmentTransition()
    return
  end
  U.tickNextAssignmentTransition(dtReal, dtSim)
  if state.restoringFreight then return end
  U.maybeNotifyEmploymentUnlock()
  U.checkEmploymentInactivity()
  local pending = state.pendingApplications[1]
  if pending and U.nowSim() >= (pending.hireAt or 0) then
    completeHire(pending)
  end
  U.maybeOfferHeadhunter()
  if state.offeredListingsAt
      and (U.nowSim() - (tonumber(state.offeredListingsAt) or 0)) >= C.LISTING_REFRESH_SIM then
    U.clearOfferedListings()
    notifyUi()
  end
  if not state.shift or not isOnShift() then
    state.dropOffProximityTimer = 0
  end
  if state.shift then
    if isOnShift() then
      local shift = state.shift
      if shift.jobKind == "parcel" and shift.dropOffDepartureRequired then
        local destination = shift.destLocation
          or (shift.destFacId and { type = "facilityParkingspot", facId = shift.destFacId, psPath = shift.destPsPath })
        local origin = shift.originLocation
        local remoteOrigin = origin and (
          (origin.facId and shift.destFacId and origin.facId ~= shift.destFacId)
          or (origin.psPath and shift.destPsPath and origin.psPath ~= shift.destPsPath))
        if (remoteOrigin and U.assignedReturnCargoInVehicle(shift))
            or (destination and not playerNearLocation(destination, 12)) then
          shift.dropOffDepartureRequired = nil
        end
      end
      if shift.parcelLoadPending and shift.parcelLoadRetryAt and U.nowSim() >= shift.parcelLoadRetryAt then
        shift.parcelLoadRetryAt = nil
        bindAssignedCargoToIssuedTruck()
        if state.shift ~= shift then return end
      end
      if shift.endAfterAssignment and not dropOffEscrowPending and not U.finalAssignmentInProgress() then
        if finishShift() then return end
      end
      if shift.spawnBlocked then
        U.tickSpawnBlockedWatch(dtSim)
      end
      if shift.jobKind == "materials" then
        if materialsAssignmentHasWork() then
          if shift.phase == "loopComplete" and not shift.wrecked then
            shift.phase = "outbound"
            refreshTaskGuidance(true)
            notifyUi()
          end
        elseif shift.phase == "outbound" then
          afterOutboundDelivered()
        end
      end
      if U.tickAccidentRecovery then
        U.tickAccidentRecovery(dtSim)
      end
      if not U.nextAssignmentTransition and U.tryOpenNearbyAssignedDropOff(dtSim) then return end
      if shift.awaitingPark and companyVehiclesParked() then
        completePendingClockOut()
      end
      if not U.nextAssignmentTransition and shift.awaitingLoopChoice and playerReadyAtYardInspect(dtSim) then
        yardArriveSettleTimer = 0
        offerLoopCompleteChoice({
          label = "Assignments complete",
          subtext = "Take another job or end your day",
        })
      elseif not U.nextAssignmentTransition and shift.phase == "return"
          and not hasOutstandingReturnWork(shift)
          and playerReadyAtYardInspect(dtSim)
          and not uiOpen
          and not dropOffOpen then
        yardArriveSettleTimer = 0
        afterReturnDelivered()
      elseif not U.nextAssignmentTransition and shift.phase == "loopComplete"
          and not shift.wrecked
          and playerReadyAtYardInspect(dtSim)
          and not uiOpen
          and not dropOffOpen then
        yardArriveSettleTimer = 0
        openShiftUi(state.homeFacId or shift.originFacId)
      end
      if shift.jobKind == "trailer" and shift.phase == "return" and shift.returnNeedsPickup then
        trySpawnAssignedReturnTrailer()
      end
      if (shift.jobKind == "vehicle" and shift.phase == "return" and shift.returnNeedsPickup)
          or U.isBundleHaulBackhaulPending(shift) then
        U.trySpawnAssignedReturnVehicle()
      end
      U.rearmMissingEmploymentRepo()
      if shift.jobKind == "repo" and shift.repoPendingStart then
        tryStartEmploymentRepo()
      end
    end
    taskGuidanceRefreshTimer = taskGuidanceRefreshTimer + (tonumber(dtSim) or 0)
    if taskGuidanceRefreshTimer >= 0.25 then
      taskGuidanceRefreshTimer = 0
      refreshTaskGuidance(false)
    end
  end
end

local function loadState()
  U.loadedShiftReconciled = nil
  U.headhunterCheckContext = nil
  local _, currentSavePath = career_saveSystem.getCurrentProfile()
  if not currentSavePath then return end
  local data = U.migrateEmploymentSaveData(jsonReadFile(currentSavePath .. saveFile) or {})
  state.version = C.SAVE_VERSION
  state.employments = data.employments or {}
  state.rehireBlockedUntil = data.rehireBlockedUntil or {}
  state.activeMapId = data.activeMapId
  state.offeredFacIds = data.offeredFacIds or data.offeredOrgIds or {}
  state.offeredListingsAt = data.offeredListingsAt
  state.headhunter = data.headhunter or { offered = {}, pending = nil }
  state.headhunter.offered = state.headhunter.offered or {}
  state.refreshLastWorkAt = data.refreshLastWorkAt and true or nil
  U.loadEmploymentCache(U.currentMapId(), true)
  state.restoringFreight=state.shift and (state.shift.freight or state.shift.plannerFreight) and true or nil
  if data.pendingApplications and data.pendingApplications[1] and not state.employerOrgId then
    state.pendingApplications = data.pendingApplications
  end
end

U.employmentsForSave = function(employments)
  local saved = {}
  for mapId, employment in pairs(employments or {}) do
    local entry = {}
    for key, value in pairs(employment) do entry[key] = value end
    if employment.shift and employment.shift.spawnBlocked then
      entry.shift = {}
      for key, value in pairs(employment.shift) do entry.shift[key] = value end
      local blocked = employment.shift.spawnBlocked
      entry.shift.spawnBlocked = {
        token = blocked.token,
        needCompanyLoaner = blocked.needCompanyLoaner == true,
        needAssignedOffers = blocked.needAssignedOffers == true,
        retryKind = blocked.retryKind,
        ready = false,
        accum = 0,
      }
    end
    saved[mapId] = entry
  end
  return saved
end

local function saveState(currentSavePath)
  if not currentSavePath then
    local _, p = career_saveSystem.getCurrentProfile()
    currentSavePath = p
    if not currentSavePath then return end
  end
  if state.shift then
    -- Keep a pending restored snapshot intact if save is called before world-ready.
    state.shift.freight = state.restoringFreight and (state.shift.freight or state.shift.plannerFreight) or U.captureFreight(state.shift, {
      parcels=career_modules_delivery_parcelManager, vehicles=career_modules_delivery_vehicleOfferManager,
    })
  end
  U.flushEmploymentCache()
  local dirPath = currentSavePath .. saveDir
  if not FS:directoryExists(dirPath) then FS:directoryCreate(dirPath) end
  career_saveSystem.jsonWriteFileSafe(currentSavePath .. saveFile, {
    version = C.SAVE_VERSION,
    employments = U.employmentsForSave(state.employments),
    rehireBlockedUntil = state.rehireBlockedUntil,
    activeMapId = state.activeMapId,
    offeredFacIds = state.offeredFacIds,
    offeredListingsAt = state.offeredListingsAt,
    headhunter = state.headhunter or { offered = {}, pending = nil },
    refreshLastWorkAt = state.refreshLastWorkAt or nil,
  }, true)
end

local function onCareerActivated()
  U.finishNextAssignmentTransition()
  U.roleplayPhoneFacId, U.roleplayPhonePosition = nil, nil
  if career_modules_logisticsEmploymentMode and career_modules_logisticsEmploymentMode.onCareerActivated then
    career_modules_logisticsEmploymentMode.onCareerActivated()
  end
  loadState()
  -- Locked freelance only: silently drop any hire leftover from before the gate was wired.
  -- Unset legacy saves stay freelance with no employment state to clear.
  if not isEmploymentUnlocked() then
    if isEmployed() then
      quitJob({ silent = true })
    end
    state.pendingApplications = {}
  end
  if state.employerOrgId == "vehicle_transfer" or state.homeFacId == "vehicle_transfer" then
    quitJob({ silent = true })
  end
  if state.pendingApplications then
    local kept = {}
    for _, app in ipairs(state.pendingApplications) do
      if app and app.orgId ~= "vehicle_transfer" and app.facId ~= "vehicle_transfer" then
        table.insert(kept, app)
      end
    end
    state.pendingApplications = kept
  end
  if state.offeredFacIds then
    local keptOffers = {}
    for _, id in ipairs(state.offeredFacIds) do
      if id ~= "vehicle_transfer" then
        table.insert(keptOffers, id)
      end
    end
    state.offeredFacIds = keptOffers
  end
  if career_modules_loanerVehicles and career_modules_inventory then
    for _, vehInfo in pairs(career_modules_inventory.getVehicles() or {}) do
      if vehInfo.loanType == "work" and vehInfo.owningOrganization then
        local organization = getOrg(vehInfo.owningOrganization)
        if career_modules_loanerVehicles.usesIndependentHourlyRental and career_modules_loanerVehicles.usesIndependentHourlyRental(organization) then
          vehInfo.loanType = "rental"
          vehInfo.rentalHourlyRate = vehInfo.rentalHourlyRate or (career_modules_loanerVehicles.getHourlyRateForOffer and career_modules_loanerVehicles.getHourlyRateForOffer(vehInfo)) or 30
          if career_modules_loanerVehicles.initRentalBilling then
            career_modules_loanerVehicles.initRentalBilling(vehInfo)
          else
            vehInfo.rentalSimAccrued = vehInfo.rentalSimAccrued or 0
            vehInfo.rentalBilledSimSeconds = vehInfo.rentalBilledSimSeconds or 0
          end
        end
      end
    end
  end
  if isOnShift() or (state.shift and state.shift.paused) then
    U.clearTaskGuidance()
    if U.dMaterials() and U.dMaterials().clearTaskGuidance then
      U.dMaterials().clearTaskGuidance()
    end
  else
    U.clearTaskGuidance()
    if U.dMaterials() and U.dMaterials().clearTaskGuidance then
      U.dMaterials().clearTaskGuidance()
    end
    returnAllCompanyVehicles()
  end
  U.maybeNotifyEmploymentUnlock()
  if extensions and extensions.load then
    pcall(extensions.load, "ui_phone_layout")
  end
  if ui_phone_layout and ui_phone_layout.ensureEmploymentAppPlaced then
    ui_phone_layout.ensureEmploymentAppPlaced()
  end
end

local function onExtensionLoaded()
  -- Reputation / orgs are not safe here during toggleCareerModules.
end

U.dEmploymentShiftRecovery = function()
  return require("gameplay/delivery/employmentShiftRecovery")
end

U.shiftRecoveryContext = function()
  return {
    getState = function() return state end,
    services = {
      vehicleOffers = U.dVehOffers,
      materials = U.dMaterials,
      generator = U.dGenerator,
      loanerCaps = U.dLoanerCaps,
      general = U.dGeneral,
      parcels = U.dParcel,
      inventory = function() return career_modules_inventory end,
      loaners = function() return career_modules_loanerVehicles end,
      vehicleTasks = function() return career_modules_delivery_vehicleTasks end,
      parcelManager = function() return career_modules_delivery_parcelManager end,
      vehicleOfferManager = function() return career_modules_delivery_vehicleOfferManager end,
      deliveryGenerator = function() return career_modules_delivery_generator end,
    },
    callbacks = {
      assignReturnLoad = assignReturnLoad,
      assignedParcelFreightAlive = U.assignedParcelFreightAlive,
      assignedReturnCargoInVehicle = U.assignedReturnCargoInVehicle,
      beginBundleRepoLeg = U.beginBundleRepoLeg,
      bindAssignedCargoToIssuedTruck = bindAssignedCargoToIssuedTruck,
      cancelEmploymentRepoJob = U.cancelEmploymentRepoJob,
      cancelSpawnBlockedWatch = U.cancelSpawnBlockedWatch,
      captureIssuedInventoryIds = captureIssuedInventoryIds,
      closeDropOffUi = closeDropOffUi,
      closeShiftUi = closeShiftUi,
      collectCompanyInventoryIds = U.collectCompanyInventoryIds,
      companyInventoryHasTowTractor = U.companyInventoryHasTowTractor,
      companyInventoryHasTrailer = U.companyInventoryHasTrailer,
      describeFacilityName = U.describeFacilityName,
      emptyShift = U.emptyShift,
      exitDeliveryModeIfActive = exitDeliveryModeIfActive,
      extendOfferExpiry = U.extendOfferExpiry,
      facilityMatchesEmployer = facilityMatchesEmployer,
      firePhoneNotification = firePhoneNotification,
      flushEmploymentCache = U.flushEmploymentCache,
      formatTodaysWagesMessage = U.formatTodaysWagesMessage,
      getIssuedEmploymentMaterials = U.getIssuedEmploymentMaterials,
      getShiftVehicleOfferId = U.getShiftVehicleOfferId,
      handleMissingCompanySpawn = U.handleMissingCompanySpawn,
      handleVehicleSpawnResult = handleVehicleSpawnResult,
      isBundleHaulBackhaulPending = U.isBundleHaulBackhaulPending,
      isBundleShift = isBundleShift,
      isDistributorHaulShift = isDistributorHaulShift,
      isOnShift = isOnShift,
      isOpenEndedJobKind = U.isOpenEndedJobKind,
      issuedVehiclesStillPresent = issuedVehiclesStillPresent,
      markIssued = markIssued,
      maybeCompleteBundleShift = maybeCompleteBundleShift,
      notifyUi = notifyUi,
      payEscrow = payEscrow,
      pickTrailerOffer = pickTrailerOffer,
      reconcileEscrowMoney = U.reconcileEscrowMoney,
      refreshTaskGuidance = refreshTaskGuidance,
      resetOfferSpawnFlags = U.resetOfferSpawnFlags,
      returnAllCompanyVehicles = returnAllCompanyVehicles,
      routeCurrentAssignment = routeCurrentAssignment,
      routeToReturnPickup = routeToReturnPickup,
      routeToYard = routeToYard,
      shiftLoanerKind = U.shiftLoanerKind,
      shiftLog = U.shiftLog,
      shiftVehicleOfferIdSet = shiftVehicleOfferIdSet,
      spawnAssignedVehicleOffers = spawnAssignedVehicleOffers,
      spawnBlockedNeedsAssignedOffers = U.spawnBlockedNeedsAssignedOffers,
      spawnBlockedNeedsCompanyLoaner = U.spawnBlockedNeedsCompanyLoaner,
      stageAssignedReturnPickup = U.stageAssignedReturnPickup,
      touchLastWorkAt = U.touchLastWorkAt,
      trySetShiftRoute = trySetShiftRoute,
      trySpawnAssignedReturnTrailer = trySpawnAssignedReturnTrailer,
      trySpawnAssignedReturnVehicle = U.trySpawnAssignedReturnVehicle,
      tryStartEmploymentRepo = tryStartEmploymentRepo,
      vehicleOfferTaskActive = U.vehicleOfferTaskActive,
    },
  }
end

U.dEmploymentEquipment = function()
  return require("gameplay/delivery/employmentEquipment")
end

U.equipmentContext = function()
  return {
    getState = function() return state end,
    services = {
      loanerCaps = U.dLoanerCaps,
      parcels = U.dParcel,
      general = U.dGeneral,
      generator = U.dGenerator,
      vehicleOffers = U.dVehOffers,
      inventory = function() return career_modules_inventory end,
      loaners = function() return career_modules_loanerVehicles end,
      insurance = function() return career_modules_insurance_insurance end,
    },
    callbacks = {
      activateAssignedWork = U.activateAssignedWork,
      diagnoseLoanerFailure = U.diagnoseLoanerFailure,
      getActiveShiftOrgId = U.getActiveShiftOrgId,
      getEmployerFacility = getEmployerFacility,
      getIssuedEmploymentMaterials = U.getIssuedEmploymentMaterials,
      handleAssignmentStartFailure = U.handleAssignmentStartFailure,
      isBundleHaulBackhaulPending = U.isBundleHaulBackhaulPending,
      isBundleShift = isBundleShift,
      isDistributorHaulShift = isDistributorHaulShift,
      isOnShift = isOnShift,
      isRoleplayProfile = U.isRoleplayProfile,
      makeAssignmentGuard = U.makeAssignmentGuard,
      notifyUi = notifyUi,
      purgeIndependentTasklist = U.purgeIndependentTasklist,
      refreshActiveTaskGuidance = U.refreshActiveTaskGuidance,
      refreshDeliveryPois = refreshDeliveryPois,
      refreshTaskGuidance = refreshTaskGuidance,
      routeCurrentAssignment = routeCurrentAssignment,
      routeToYard = routeToYard,
      shiftLog = U.shiftLog,
      stageDistributorHaulOffers = U.stageDistributorHaulOffers,
      trySpawnAssignedReturnVehicle = U.trySpawnAssignedReturnVehicle,
    },
  }
end

U.dEmploymentDispatch = function()
  return require("gameplay/delivery/employmentDispatch")
end

U.dispatchContext = function()
  return {
    employment = {
      employerOrgId = state.employerOrgId,
      homeFacId = state.homeFacId,
      shift = state.shift and {phase = state.shift.phase, jobKind = state.shift.jobKind, paused = state.shift.paused},
    },
    excludedParcelTypes = EMPLOYMENT_PARCEL_EXCLUDED_TYPES,
    distributorCount = DISTRIBUTOR_HAUL_COUNT,
    nowSim = U.nowSim,
    log = U.shiftLog,
    services = {
      generator = U.dGenerator,
      loanerCaps = U.dLoanerCaps,
      materials = U.dMaterials,
      parcels = U.dParcel,
      vehicleOffers = U.dVehOffers,
    },
    policy = {
      cargoItemUnlocked = U.cargoItemUnlocked,
      trailerOfferUnlocked = U.trailerOfferUnlocked,
      vehicleOfferUnlocked = U.vehicleOfferUnlocked,
      materialOfferUnlocked = U.materialOfferUnlocked,
      canIssueMaterials = U.canIssueEmploymentMaterials,
      facilityOffersKind = U.facilityOffersKind,
      facilityProfile = U.getFacilityEmployerProfile,
      isRoleplayProfile = U.isRoleplayProfile,
      makeRoleplayJob = U.makeRoleplayJob,
      isParcelStringEmployer = U.isParcelStringEmployer,
      isDevToolsEnabled = U.isDevToolsEnabled,
      assignableKinds = getAssignableKinds,
      distributorHaul = facilityIssuesDistributorHaul,
      getOrg = getOrg,
      repLevel = getRepLevel,
      isEmployed = isEmployed,
      isOnShift = isOnShift,
      facilityMatchesEmployer = facilityMatchesEmployer,
    },
    prepare = {
      parcelGroups = U.ensureParcelGroupsAtFacility,
      stageDistributor = U.stageDistributorHaulOffers,
      cargoHasTimedModifier = cargoHasTimedModifier,
    },
    planning = {
      parcelString = U.buildParcelStringJob,
      distance = U.facDistanceBetween,
      trimParcelItems = function(facId, items)
        local gen = U.dGenerator()
        local fac = facId and gen and gen.getFacilityById and gen.getFacilityById(facId)
        return U.dEmploymentParcelStrings().trimItems(U.parcelStringContext(), fac, items)
      end,
    },
    labels = {
      facility = U.describeFacilityName,
      destination = describeDest,
      translate = translateUiText,
      organization = getOrgDisplayName,
    },
  }
end

M.isEmployed = isEmployed
M.isOnShift = isOnShift
M.hasCompanyShift = U.hasCompanyShift
M.isJockeyShift = function()
  local shift = state.shift
  if not shift or not isOnShift() then return false end
  if isDistributorHaulShift(shift) then return true end
  if shift.jobKind == "vehicle" then return true end
  if isBundleShift(shift) then
    local a = shift.assignments
    if a and a.vehicle and not a.vehicle.complete then return true end
    if U.isBundleHaulBackhaulPending(shift) and shift.returnIsBackhaul then return true end
    return false
  end
  return false
end

M.isBundleFlatbedPending = function()
  local shift = state.shift
  if not shift or not isOnShift() or not U.isBundleHaulBackhaulPending(shift) then return false end
  if shift.returnIsBackhaul and shift.assignedOfferId and playerInIssuedCompanyTruck() then
    return false
  end
  return true
end

M.reassertBundleFlatbedRoute = function()
  if not M.isBundleFlatbedPending() then return false end
  if not playerInIssuedCompanyTruck() then
    return U.routeToCompanyTruck() and true or false
  end
  local shift = state.shift
  if shift.returnNeedsPickup then
    return routeToReturnPickup() and true or false
  end
  return false
end
M.getShiftDestLocation = function()
  local shift = state.shift
  if not shift then return nil end
  if shift.destLocation and (shift.destLocation.psPath or shift.destLocation.facId) then
    return shift.destLocation
  end
  if shift.destFacId then
    return { type = "facilityParkingspot", facId = shift.destFacId, psPath = shift.destPsPath }
  end
  return nil
end
M.onVehicleTaskStepChanged = function()
  if not isOnShift() then return end
  if M.reassertBundleFlatbedRoute() then
    refreshTaskGuidance(true)
    return
  end
  routeCurrentAssignment()
  refreshTaskGuidance(true)
end
M.getGuidedDeliveryFacilityId = function()
  if not isOnShift() then return nil end
  local shift = state.shift
  if not shift or shift.jobKind ~= "parcel" then return nil end
  if shift.awaitingPark or shift.phase == "loopComplete" or shift.wrecked then
    return state.homeFacId or shift.originFacId
  end
  if (shift.needsRemotePickup or shift.returnNeedsPickup)
      and not U.assignedReturnCargoInVehicle(shift) then
    return shift.returnPickupFacId or shift.pickupFacId or shift.originFacId
  end
  if shift.stringMode and shift.phase == "outbound" then
    local stop = shift.stops and shift.stops[shift.stopIndex or 1]
    return (stop and stop.destFacId) or shift.destFacId
  end
  return shift.destFacId
end
M.shouldShowDeliveryFacilityWorldPin = function(facId)
  if not facId then return true end
  local guided = M.getGuidedDeliveryFacilityId()
  if not guided then return true end
  return facId == guided
end
M.shouldShowParcelDropOffPin = function(cargo)
  if not isOnShift() then return true end
  local shift = state.shift
  if not shift or shift.jobKind ~= "parcel" then return true end
  if not cargoIsAssigned(cargo) then return false end
  if shift.phase == "outbound" then
    local stop = shift.stops and shift.stops[shift.stopIndex or 1]
    if stop then
      return U.dEmploymentParcelStrings().cargoMatchesStop(cargo, stop)
    end
    local dest = cargo.destination
    if shift.destFacId and dest and dest.facId == shift.destFacId then
      if not shift.destPsPath or not dest.psPath or dest.psPath == shift.destPsPath then
        return true
      end
    end
    return false
  end
  return true
end
M.ownsHudTasklist = function()
  return isOnShift()
end
M.refreshHudTasklist = function(force)
  refreshTaskGuidance(force and true or false)
end
M.isEmployedAtRepoCompany = function()
  if not isEmployed() then return false end
  local fac = U.dGenerator() and U.dGenerator().getFacilityById and U.dGenerator().getFacilityById(state.homeFacId)
  local caps = U.dLoanerCaps()
  return fac and caps and caps.canIssueLoanersForFacility(fac, "repo", {}) or false
end
M.isAssignmentPaused = function()
  return state.shift and state.shift.paused and true or false
end
M.isAwaitingPark = function()
  return state.shift and state.shift.awaitingPark and true or false
end
M.shouldAbortInterruptedShiftOnLoad = function()
  local shift = state.shift
  return shift ~= nil and not shift.sessionVehicles and not (shift.freight or shift.plannerFreight) and not state.restoringFreight
end
M.shouldPersistVehicle = function(inventoryId)
  local shift = state.shift
  if not shift then return false end
  inventoryId = tonumber(inventoryId)
  for _, id in ipairs(shift.issuedInventoryIds or {}) do
    if tonumber(id) == inventoryId then return true end
  end
  local inventory = career_modules_inventory
  local info = inventory and inventory.getVehicle(inventoryId)
  if info and info.loanType == "company" and info.owningOrganization == U.getActiveShiftOrgId() then return true end
  if not info or info.loanType ~= "delivery" then return false end
  local snapshot = shift.freight or shift.plannerFreight
  if snapshot then
    for _, offer in ipairs(snapshot.offers or {}) do
      if offer.vehicle and tonumber(offer.vehicle.inventoryId) == inventoryId then return true end
    end
  end
  local mgr = U.dVehOffers()
  for _, id in ipairs(shift.assignedOfferIds or {shift.assignedOfferId}) do
    local offer = mgr and mgr.getOfferById(id)
    if offer and offer.vehicle and tonumber(offer.vehicle.inventoryId) == inventoryId then return true end
  end
  return false
end
M.getEmployerOrgId = getEmployerOrgId
M.getEmployerQuickTravelTarget = function()
  if not isEmployed() then return nil end
  local yard = getYardLocation()
  local gen = U.dGenerator()
  local spot = yard and yard.psPath and gen and gen.getParkingSpotByPath and gen.getParkingSpotByPath(yard.psPath)
  if not (spot and spot.pos) then return nil end
  local context = getEmployerDeliveryContext()
  return {pos = spot.pos, rot = spot.rot, label = context and context.label or "Your employer"}
end
M.getTasklistHeaderLabel = U.getEmployerTasklistHeader
M.keepDeliveryModeActive = keepDeliveryModeActive
M.applyForJob = applyForJob
M.acceptHeadhunterOffer = acceptHeadhunterOffer
M.dismissHeadhunterOffer = dismissHeadhunterOffer
-- Phone app: drop ground markers at the employer's yard so the player can go clock in.
local function navigateToYard(facId)
  facId = facId or state.homeFacId
  local gen = career_modules_delivery_generator
  local fac = facId and gen and gen.getFacilityById and gen.getFacilityById(facId)
  if not fac then return false, "No company yard to route to." end
  local pos = fac.inspectSpots and fac.inspectSpots[1] and fac.inspectSpots[1].pos
  if not pos and fac.pos then pos = vec3(fac.pos) end
  if not pos then return false, "The yard location is unavailable." end
  local general = career_modules_delivery_general
  if general and general.setDeliveryNavFocus then pcall(general.setDeliveryNavFocus, pos) end
  if core_groundMarkers and core_groundMarkers.setPath then
    core_groundMarkers.setPath({pos}, {clearPathOnReachingTarget = false})
  end
  return true, "Route to the company yard set."
end

M.quitJob = quitJob
M.navigateToYard = navigateToYard
M.onLogisticsAbandoned = function()
  if not state.shift then return end
  local terminateAfter = state.shift.pendingDamageTermination
  U.cancelEmploymentRepoJob()
  state.ignoreCompanyDamageStrikes = true
  returnIssuedVehicles()
  U.emptyShift()
  U.resetEscrow()
  if terminateAfter then terminateEmploymentForDamage() else U.flushEmploymentCache() end
  notifyUi()
end
M.resetShiftAndEquipment = resetShiftAndEquipment
M.rollJobListings = rollJobListings
M.getDevJobOptions = getDevJobOptions
M.startShiftWithJob = function(facId, selection)
  return callShiftAction("startShiftWithJob", function(id)
    return startShiftWithJob(id, selection)
  end, facId)
end
M.startShift = function(facId)
  return callShiftAction("startShift", startShift, facId)
end
M.startRoleplayShift = function(facId, selection)
  return callShiftAction("startRoleplayShift", function(id)
    local profile, _, fac = U.getFacilityEmployerProfile(id)
    if not U.isRoleplayProfile(profile) or id ~= U.roleplayPhoneFacId then
      return U.failShift("Visit the service facility to start your day.")
    end
    local player = getPlayerVehicle(0)
    if not player or not U.roleplayPhonePosition or player:getPosition():distance(U.roleplayPhonePosition) > 30 then
      return U.failShift("Return to the service facility to start your day.")
    end
    local gate, fail = startShiftGate(id)
    if not gate then return fail end
    if type(selection) ~= "table" then return U.failShift("Choose a vehicle first.") end
    local job = U.makeRoleplayJob(profile)
    if selection.personal then
      local inv = career_modules_inventory
      local vehId = be:getPlayerVehicleID(0)
      local inventoryId = inv and inv.getInventoryIdFromVehicleId(vehId)
      local info = inventoryId and inv.getVehicles()[inventoryId]
      if not info or info.owned == false or info.loanType or info.owningOrganization then
        return U.failShift("Enter your own service vehicle first.")
      end
      local valid = false
      if profile == "bus" then
        valid = gameplay_bus and gameplay_bus.canUsePersonalVehicle and gameplay_bus.canUsePersonalVehicle(vehId)
      elseif profile == "paramedic" then
        valid = gameplay_ambulance and gameplay_ambulance.canUsePersonalVehicle and gameplay_ambulance.canUsePersonalVehicle(vehId)
      else
        valid = inv.getVehicleRole and inv.getVehicleRole(inventoryId) == "police"
      end
      if not valid then return U.failShift("This vehicle or your skill level is not eligible for this service.") end
      job.personalVehicleId = inventoryId
    else
      local caps = U.dLoanerCaps()
      if not caps or not caps.getIssuedRoleplayVehicleForFacility(fac, {selection = selection}) then
        return U.failShift("This company vehicle is no longer available.")
      end
      job.vehicleSelection = {model = selection.model, config = selection.config}
    end
    local ok, err = U.beginAssignmentWithGuidance(id, job)
    if not ok then return U.failShift("Could not start the shift.", err) end
    U.saveEmploymentProgress()
    ui_message("On duty. Use End Day in Phone > Employment when you are finished.", 8, "info")
    return U.okShift()
  end, facId)
end
M.closeRoleplaySetup = function()
  U.roleplayPhoneFacId, U.roleplayPhonePosition = nil, nil
  notifyUi()
end
M.startNextRun = function(facId)
  return callShiftAction("startNextRun", startNextRun, facId)
end
M.getLastShiftActionResult = function()
  return state.lastShiftActionResult or {
    success = false,
    message = "No shift action has been recorded yet.",
    detail = "",
  }
end
M.getShiftStartDiagnostics = function(facId)
  return {
    facId = facId,
    detail = U.diagnoseDispatch(facId, "manual"),
    kinds = U.summarizeKindMap(getAssignableKinds(facId)),
  }
end
M.acceptReturn = acceptReturn
M.endDay = endDay
M.endBusShiftNow = U.endBusShiftNow
M.abandonAssignmentQuote = U.abandonAssignmentQuote
M.abandonAssignment = function(facId)
  return callShiftAction("abandonAssignment", U.abandonEmploymentAssignment, facId)
end
M.openShiftUi = openShiftUi
M.closeShiftUi = closeShiftUi
M.canOpenFacilityShiftUi = function(facId)
  if not facId then return false end
  if U.isRoleplayFacility(facId) then return true end
  return isEmployed() and facilityMatchesEmployer(facId) or false
end
M.tryOpenFacilityShiftUi = function(facId)
  if not M.canOpenFacilityShiftUi(facId) then return false end
  return openShiftUi(facId)
end
M.isRoleplayFacility = function(facId)
  return U.isRoleplayFacility(facId)
end
M.onShiftRouteLeave = onShiftRouteLeave
M.openDropOffUi = openDropOffUi
M.closeDropOffUi = closeDropOffUi
M.onDropOffRouteLeave = onDropOffRouteLeave
M.willAutoOpenDropOffAt = U.willAutoOpenDropOffAt
M.shouldOpenEmployeeDropOff = shouldOpenEmployeeDropOff
M.isEmployeeDropOffBlocked = U.isEmployeeDropOffBlocked
M.confirmEmployeeDropOff = confirmEmployeeDropOff
M.tryAutoDropOffAssigned = tryAutoDropOffAssigned
M.consumeDropOffMoneyForEscrow = consumeDropOffMoneyForEscrow
M.recordDropOffRewardProgress = function(repDelta)
  lastDropOffProgress = (type(repDelta) == "table" and repDelta.gain ~= nil) and repDelta or nil
  holdDropOffForProgress = lastDropOffProgress ~= nil
  if dropOffOpen then notifyUi() end
end
M.onRepoDeliveryComplete = handleEmploymentRepoComplete
M.afterCompanyDropOff = afterCompanyDropOff
M.trySetShiftRoute = trySetShiftRoute
M.tryAutoLoadAssignedParcelsAtSpot = tryAutoLoadAssignedParcelsAtSpot
M.hasAssignedReturnCargoAtSpot = U.hasAssignedReturnCargoAtSpot
M.stageAssignedReturnPickup = U.stageAssignedReturnPickup
M.clearAwaitingParkIfWorking = function()
  local shift = state.shift
  if shift and shift.awaitingPark and assignmentStillInProgress() then
    shift.awaitingPark = nil
    shift.parkedNotified = nil
    shift.pendingClockOut = nil
    refreshTaskGuidance(true)
  end
end
M.isEmployeeDropOffOpen = function()
  return dropOffOpen and true or false
end
M.canMoveCargoOntoLocation = canMoveCargoOntoLocation
M.getIssuedTruckForJob = function(facility, jobKind, cargoType, targetLoad)
  local caps = career_modules_delivery_loanerCapabilities
  return caps and caps.getIssuedTruckForJob(facility, jobKind, cargoType, targetLoad) or nil, nil
end
M.getUiState = getUiState
M.canReportAccident = function()
  return U.canReportAccident and U.canReportAccident() or false
end
M.reportAccident = function(preferredVehId)
  return U.reportAccident and U.reportAccident(preferredVehId) or false
end
M.claimAccidentReplacement = function()
  return U.claimAccidentReplacement and U.claimAccidentReplacement() or false
end
M.getDropOffUiState = getDropOffUiState
M.getListings = getListings
M.isEmploymentUnlocked = isEmploymentUnlocked
M.getDeliveryLevel = getDeliveryLevel
M.isApprenticeshipEnabled = isApprenticeshipEnabled
M.isOmittedFromEmployment = U.isOmittedFromEmployment
M.isVehicleDistributorFacility = U.isVehicleDistributorFacility
M.isOwnerOpYardFacility = U.isOwnerOpYardFacility
M.classifyRoleplayOrg = U.classifyRoleplayOrg
M.allowsOwnerOpYardBoard = U.allowsOwnerOpYardBoard
M.isLegacyFreelanceLogistics = function()
  local mode = career_modules_logisticsEmploymentMode
  if mode and mode.isLegacyFreelance then
    return mode.isLegacyFreelance()
  end
  if mode and mode.hasChosen and not mode.hasChosen() then
    return true
  end
  return false
end
M.hasEmploymentModeChoice = function()
  local mode = career_modules_logisticsEmploymentMode
  return mode and mode.hasChosen and mode.hasChosen() or false
end
M.canUseCargoBoard = function(facId)
  if U.getCargoBoardBlockMessage(facId) then return false end
  return true
end
M.getCargoBoardBlockMessage = U.getCargoBoardBlockMessage
M.shouldShowFreelanceInspectAt = U.shouldShowFreelanceInspectAt
M.facilityMatchesEmployer = function(facId)
  return facilityMatchesEmployer(facId)
end
M.getMapTravelBlockMessage = U.getMapTravelBlockMessage
M.canLoanIndependently = function()
  return true
end
M.usesEmploymentPayForOrg = function(orgId)
  return isOnShift() and orgId ~= nil and orgId == state.employerOrgId
end
M.isRoleplayShift = function()
  if not isOnShift() or not state.shift then return false end
  local kind = state.shift.jobKind
  return kind == "police" or kind == "bus" or kind == "paramedic"
end
M.blocksRoleplay = function()
  return isOnShift() and state.shift ~= nil and not M.isRoleplayShift()
end
M.shouldEscrowRoleplayPay = function()
  return M.isRoleplayShift()
end
M.depositRoleplayEscrow = function(label, gross)
  if not M.shouldEscrowRoleplayPay() then return nil end
  local keep = U.addEscrowKeep(label or "Shift pay", gross, U.getCompanyShare(), "roleplay")
  U.flushEmploymentCache()
  notifyUi()
  return keep
end
M.applyEmploymentPayToBreakdown = function(originalRewards, breakdown, adjustedRewards)
  if not isOnShift() or not state.employerOrgId or type(breakdown) ~= "table" or type(adjustedRewards) ~= "table" then
    return originalRewards, breakdown, adjustedRewards
  end
  local filtered, changed = {}, false
  for _, bd in ipairs(breakdown) do
    local stripLoanerMoney = false
    if bd and bd.simpleBreakdownType == "loaner" then
      for key, _ in pairs(bd.rewards or {}) do
        local orgId = type(key) == "string" and key:match("^(.*)Reputation$")
        if orgId and orgId == state.employerOrgId then
          stripLoanerMoney = true
          break
        end
      end
    end
    if stripLoanerMoney then
      local cutMoney = tonumber(bd.rewards and bd.rewards.money) or 0
      if cutMoney ~= 0 then
        adjustedRewards.money = (tonumber(adjustedRewards.money) or 0) - cutMoney
        changed = true
      end
      local repOnly = { label = bd.label, rewards = {}, simpleBreakdownType = "loaner" }
      for key, amount in pairs(bd.rewards or {}) do
        if key ~= "money" then repOnly.rewards[key] = amount end
      end
      if next(repOnly.rewards) then
        table.insert(filtered, repOnly)
      end
    else
      table.insert(filtered, bd)
    end
  end
  if changed then
    return originalRewards, filtered, adjustedRewards
  end
  return originalRewards, breakdown, adjustedRewards
end

U.dEmploymentAccidentRecovery = function()
  return require("gameplay/delivery/employmentAccidentRecovery")
end

U.accidentRecoveryContext = function()
  return {
    getState = function() return state end,
    constants = C,
    services = {
      ui = U.dEmploymentUi,
      parcels = U.dParcel,
      general = U.dGeneral,
      cargoScreen = U.dCargoScreen,
      generator = U.dGenerator,
      loanerCaps = U.dLoanerCaps,
      inventory = function() return career_modules_inventory end,
      loaners = function() return career_modules_loanerVehicles end,
      insurance = function() return career_modules_insurance_insurance end,
    },
    callbacks = {
      buildCompanyParcelLoadSlots = U.buildCompanyParcelLoadSlots,
      captureIssuedInventoryIds = captureIssuedInventoryIds,
      collectCompanyInventoryIds = U.collectCompanyInventoryIds,
      detachVehicleTrailers = U.detachVehicleTrailers,
      enterCompanyTractor = U.enterCompanyTractor,
      enterSpawnBlockedState = U.enterSpawnBlockedState,
      getIssuedEmploymentMaterials = U.getIssuedEmploymentMaterials,
      handleCompanyVehicleDamaged = handleCompanyVehicleDamaged,
      inventoryVehAsLoanerOffer = U.inventoryVehAsLoanerOffer,
      isCompanyTrailer = U.isCompanyTrailer,
      isEmployed = isEmployed,
      isOnShift = isOnShift,
      isRoleplayProfile = U.isRoleplayProfile,
      markIssued = markIssued,
      notifyUi = notifyUi,
      playerNearHomeYard = playerNearHomeYard,
      refreshDeliveryPois = refreshDeliveryPois,
      refreshTaskGuidance = refreshTaskGuidance,
      routeCurrentAssignment = routeCurrentAssignment,
      routeToYard = routeToYard,
      saveEmploymentProgress = U.saveEmploymentProgress,
      shiftLoanerKind = U.shiftLoanerKind,
      stepOutIfInInventoryIds = U.stepOutIfInInventoryIds,
      takeParcelLoadLocation = U.takeParcelLoadLocation,
    },
  }
end

U.accidentTaskGuidance = function(shift)
  return U.dEmploymentAccidentRecovery().accidentTaskGuidance(U.accidentRecoveryContext(), shift)
end

U.accidentUi = function(shift)
  return U.dEmploymentAccidentRecovery().accidentUi(U.accidentRecoveryContext(), shift)
end

U.inventorySpawnedVehId = function(inventoryId)
  return U.dEmploymentAccidentRecovery().inventorySpawnedVehId(U.accidentRecoveryContext(), inventoryId)
end

U.vehIsFlipped = function(vehId)
  return U.dEmploymentAccidentRecovery().vehIsFlipped(U.accidentRecoveryContext(), vehId)
end

U.spawnedVehLiveDamage = function(vehId)
  return U.dEmploymentAccidentRecovery().spawnedVehLiveDamage(U.accidentRecoveryContext(), vehId)
end

U.companyInventoryIsWrecked = function(inventoryId)
  return U.dEmploymentAccidentRecovery().companyInventoryIsWrecked(U.accidentRecoveryContext(), inventoryId)
end

U.canReportAccident = function()
  return U.dEmploymentAccidentRecovery().canReportAccident(U.accidentRecoveryContext())
end

U.routeToWorldPos = function(pos)
  return U.dEmploymentAccidentRecovery().routeToWorldPos(U.accidentRecoveryContext(), pos)
end

U.routeAccidentRecovery = function()
  return U.dEmploymentAccidentRecovery().routeAccidentRecovery(U.accidentRecoveryContext())
end

U.accidentVehIdMatches = function(vehId, idSet)
  return U.dEmploymentAccidentRecovery().accidentVehIdMatches(U.accidentRecoveryContext(), vehId, idSet)
end

U.markAccidentVehId = function(idSet, vehId)
  return U.dEmploymentAccidentRecovery().markAccidentVehId(U.accidentRecoveryContext(), idSet, vehId)
end

U.groundAccidentPos = function(pos)
  return U.dEmploymentAccidentRecovery().groundAccidentPos(U.accidentRecoveryContext(), pos)
end

U.accidentBoxPosFromScene = function(origin)
  return U.dEmploymentAccidentRecovery().accidentBoxPosFromScene(U.accidentRecoveryContext(), origin)
end

U.deleteNamedStatic = function(name)
  return U.dEmploymentAccidentRecovery().deleteNamedStatic(U.accidentRecoveryContext(), name)
end

U.deleteAccidentCargoBox = function()
  return U.dEmploymentAccidentRecovery().deleteAccidentCargoBox(U.accidentRecoveryContext())
end

U.spawnAccidentStatic = function(name, shapeName, pos, scale, color)
  return U.dEmploymentAccidentRecovery().spawnAccidentStatic(U.accidentRecoveryContext(), name, shapeName, pos, scale, color)
end

U.spawnAccidentCargoBox = function(pos)
  return U.dEmploymentAccidentRecovery().spawnAccidentCargoBox(U.accidentRecoveryContext(), pos)
end

U.restoreAccidentCargoBox = function()
  return U.dEmploymentAccidentRecovery().restoreAccidentCargoBox(U.accidentRecoveryContext())
end

U.setCargoLocation = function(cargoId, location)
  return U.dEmploymentAccidentRecovery().setCargoLocation(U.accidentRecoveryContext(), cargoId, location)
end

U.cargoTiedToWreckedVeh = function(cargo, wreckedVehIds, wreckedInvIds)
  return U.dEmploymentAccidentRecovery().cargoTiedToWreckedVeh(U.accidentRecoveryContext(), cargo, wreckedVehIds, wreckedInvIds)
end

U.relocateCargoOffWrecked = function(wreckedVehIds, wreckedInvIds)
  return U.dEmploymentAccidentRecovery().relocateCargoOffWrecked(U.accidentRecoveryContext(), wreckedVehIds, wreckedInvIds)
end

U.tryRebindAccidentCargo = function()
  return U.dEmploymentAccidentRecovery().tryRebindAccidentCargo(U.accidentRecoveryContext())
end

U.tickAccidentRecovery = function(dtSim)
  return U.dEmploymentAccidentRecovery().tickAccidentRecovery(U.accidentRecoveryContext(), dtSim)
end

U.accidentEntryForInventory = function(inventoryId)
  return U.dEmploymentAccidentRecovery().accidentEntryForInventory(U.accidentRecoveryContext(), inventoryId)
end

U.collectAccidentWreckage = function(preferredVehId)
  return U.dEmploymentAccidentRecovery().collectAccidentWreckage(U.accidentRecoveryContext(), preferredVehId)
end

U.fallbackAccidentOffer = function(entry, shift)
  return U.dEmploymentAccidentRecovery().fallbackAccidentOffer(U.accidentRecoveryContext(), entry, shift)
end

U.stepOutIfInInventoryIds = function(idSet)
  if not (career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId) then return end
  local vehId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0)
  if not vehId or vehId < 0 then return end
  local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
  if not (inventoryId and idSet[inventoryId]) then return end
  if spawn then spawn.preventPlayerSpawning = nil end
  if gameplay_walk and gameplay_walk.setWalkingMode then
    gameplay_walk.setWalkingMode(true, nil, nil, true)
  end
end

U.detachVehicleTrailers = function(vehId)
  local veh = vehId and scenetree.findObjectById and scenetree.findObjectById(vehId)
  if veh and veh.queueLuaCommand then
    veh:queueLuaCommand("if beamstate and beamstate.detachAll then beamstate.detachAll() end")
  end
end


U.enterCompanyTractor = function(opts)
  opts = type(opts) == "table" and opts or {}
  if not (career_modules_inventory and career_modules_inventory.getVehicleIdFromInventoryId) then return false end
  local skipInv = {}
  if opts.skipInventoryId then
    skipInv[opts.skipInventoryId] = true
    skipInv[tonumber(opts.skipInventoryId) or opts.skipInventoryId] = true
  end
  local function tryEnter()
    for _, inventoryId in ipairs(U.collectCompanyInventoryIds()) do
      local invN = tonumber(inventoryId) or inventoryId
      if skipInv[inventoryId] or skipInv[invN] then goto continueTractor end
      local vehId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
      local vehInfo = career_modules_inventory.getVehicles()[inventoryId]
      if vehId and not U.isCompanyTrailer(vehInfo, vehId) then
        if spawn then spawn.preventPlayerSpawning = nil end
        if career_modules_inventory.enterVehicle then
          career_modules_inventory.enterVehicle(inventoryId)
        else
          local obj = getObjectByID(vehId)
          if obj and be and be.enterVehicle then
            if gameplay_walk and gameplay_walk.setWalkingMode then
              gameplay_walk.setWalkingMode(false, nil, nil, true)
            end
            be:enterVehicle(0, obj)
          end
        end
        return true
      end
      ::continueTractor::
    end
    return false
  end
  if tryEnter() then return true end
  if core_jobsystem and core_jobsystem.create then
    core_jobsystem.create(function(job)
      for _ = 1, 32 do
        job.sleep(0.25)
        if tryEnter() then return end
      end
    end)
  end
  return false
end

U.enterAccidentReplacementTractor = function()
  return U.dEmploymentAccidentRecovery().enterAccidentReplacementTractor(U.accidentRecoveryContext())
end

U.getMissingAccidentReplacementOffers = function(shift)
  return U.dEmploymentAccidentRecovery().getMissingAccidentReplacementOffers(U.accidentRecoveryContext(), shift)
end

U.finishAccidentSpawn = function(replacedTractor)
  return U.dEmploymentAccidentRecovery().finishAccidentSpawn(U.accidentRecoveryContext(), replacedTractor)
end

U.claimAccidentReplacement = function()
  return U.dEmploymentAccidentRecovery().claimAccidentReplacement(U.accidentRecoveryContext())
end

U.reportAccident = function(preferredVehId)
  return U.dEmploymentAccidentRecovery().reportAccident(U.accidentRecoveryContext(), preferredVehId)
end

M.onIssuedVehicleReturnedDamaged = function(inventoryId, amount)
  if state.ignoreCompanyDamageStrikes or state.accidentReportInProgress then return end
  if not isEmployed() then return end
  if not (career_modules_inventory and career_modules_inventory.getVehicles) then return end
  local vehInfo = career_modules_inventory.getVehicles()[inventoryId]
  if not (vehInfo and vehInfo.loanType == "company" and vehInfo.owningOrganization == state.employerOrgId) then
    return
  end
  handleCompanyVehicleDamaged()
end

-- Return Loaner during a shift: clear issued tracking and unlock End day payout
-- when only yard-return / wreck recovery remains.
M.onIssuedVehicleReturned = function(inventoryId)
  if state.ignoreCompanyDamageStrikes or state.companyEquipmentHandoff or state.restoringFreight then return end
  local shift = state.shift
  if not shift then return end
  if not (isOnShift() or shift.paused) then return end
  if shift.issuedInventoryIds then
    local keep = {}
    for _, id in ipairs(shift.issuedInventoryIds) do
      if id ~= inventoryId then table.insert(keep, id) end
    end
    shift.issuedInventoryIds = keep
  end
  if state.accidentReportInProgress then
    notifyUi()
    return
  end
  if issuedVehiclesStillPresent() then
    notifyUi()
    return
  end
  -- No company vehicles left in inventory: treat as recovered / returned.
  shift.assignedCargoIds = {}
  shift.assignedOfferId = nil
  shift.assignedOfferIds = nil
  shift.stops = nil
  shift.stringMode = nil
  shift.returnNeedsPickup = nil
  shift.needsRemotePickup = nil
  shift.awaitingPark = nil
  shift.pendingClockOut = nil
  shift.phase = "loopComplete"
  shift.returnLabel = "Company vehicle returned"
  shift.returnSubtext = "End day anytime to collect held pay"
  if shift.paused then
    shift.paused = false
  end
  refreshTaskGuidance(true)
  notifyUi()
  ui_message("Company vehicle returned. End day to collect held pay.", 7, "info")
end

M.onUpdate = onUpdate
M.onClientEndMission = function() U.finishNextAssignmentTransition() end
M.onExtensionUnloaded = function() U.finishNextAssignmentTransition() end
M.onVehicleSwitched = function()
  local shift = state.shift
  if not shift or not shift.awaitingCompanyVehicleEntry then return end
  if not playerInIssuedCompanyTruck() then
    U.routeToCompanyTruck()
    return
  end
  shift.awaitingCompanyVehicleEntry = nil
  if shift.jobKind ~= "police" and shift.jobKind ~= "bus" and shift.jobKind ~= "paramedic" then
    routeCurrentAssignment()
  end
  refreshTaskGuidance(true)
end
M.onUiReady = function(uiType)
  if uiType == "vue" then U.refreshActiveTaskGuidance() end
end
M.onDeliveryCargoLoadingStarted = function(token)
  if not state.shift then return end
  U.pendingCargoTaskRefresh = {token = token, isCurrent = U.makeAssignmentGuard()}
end
M.onDeliveryCargoLoadingFinished = function(token)
  local pending = U.pendingCargoTaskRefresh
  if not pending or pending.token ~= token then return end
  U.pendingCargoTaskRefresh = nil
  if pending.isCurrent() then U.refreshActiveTaskGuidance() end
end
M.onCareerActivated = onCareerActivated
M.onWorldReadyState = function(worldReadyState)
  if worldReadyState == 2 and not U.loadedShiftReconciled then
    U.loadedShiftReconciled = true
    core_jobsystem.create(function(job)
      job.sleep(0)
      if career_modules_delivery_employment ~= M then return end
      local inventory = career_modules_inventory
      for attempt = 1, 300 do
        if not (inventory and inventory.isVehicleRestorePending and inventory.isVehicleRestorePending()) then break end
        job.sleep(0.1)
        if career_modules_delivery_employment ~= M then return end
        if attempt == 300 then
          ui_message("Assignment recovery is waiting for vehicle restoration. Reload the save to retry.", 10, "warning")
          return
        end
      end
      U.loadEmploymentCache(U.currentMapId())
      U.reconcileLoadedShift()
      state.restoringFreight=nil
      U.restoreAccidentCargoBox()
      if isOnShift() or (state.shift and state.shift.paused) then
        refreshTaskGuidance(true)
      else
        U.clearTaskGuidance()
      end
      notifyUi()
    end)
  end
end
M.onExtensionLoaded = onExtensionLoaded
-- Reloading a career on the current map does not emit a new world-ready event.
-- The existing reconciliation guard keeps activation and map loading idempotent.
M.onCareerActivationReady = function()
  M.onWorldReadyState(2)
end
M.onSaveCurrentProfile = saveState

M.isAssignedCargo = function(item) return U.isAssignedFreight(state.shift,item,"parcel") end
M.isAssignedVehicleOffer = function(item) return U.isAssignedFreight(state.shift,item,"vehicle") end
return M
