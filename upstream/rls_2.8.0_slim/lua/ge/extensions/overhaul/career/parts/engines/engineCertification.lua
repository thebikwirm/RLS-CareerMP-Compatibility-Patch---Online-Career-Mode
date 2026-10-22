-- Engine certification: recipe ratings, torque limits and compatible hardware.
-- Map: State; Save data; Torque curves; Authored data scan; Boost estimate; Jobs; Lifecycle and public API.

local M = {}

local jbeamIO = require("jbeam/io")
-- Config -------------------------------------------------------------------------------------------

local SAVE_VERSION = 2
local SAVE_PATH = "/career/rls_career/engineCertifications.json"
local CERTIFICATION_SECONDS = 60
local CERTIFICATION_FEE_RATE = 0.10
local HORSEPOWER_TORQUE_RPM_DIVISOR = 7127
local RPM_PER_RAD_PER_SECOND = 9.549296596
local ATMOSPHERE_PSI = 14.7
local BOOST_TORQUE_GAIN = 0.55
local MAXIMUM_ESTIMATED_BOOST_PSI = 50
local FORCED_INDUCTION_KEYS = {"maxWastegatePressure", "wastegatePressure", "wastegateLimit", "wastegateStart", "maxBoost"}

-- State -------------------------------------------------------------------------------------------

-- Saved with the career: pending and running stress tests, keyed by package id.
local jobs = {}
local activeSeconds = 0
local initialized = false
local orphanCheckPending = false

-- Save data -----------------------------------------------------------------------------------------

local function saveData(savePath)
  if not savePath then return end
  overhaul_career_saveSystem.jsonWriteFileSafe(savePath .. SAVE_PATH, {version = SAVE_VERSION, activeSeconds = activeSeconds, jobs = jobs}, true)
end

-- Jobs that were already completed stay out of the list; unfinished ones restart as pending.
local function loadData()
  jobs = {}
  orphanCheckPending = true
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  local data = savePath and jsonReadFile(savePath .. SAVE_PATH) or nil
  activeSeconds = math.max(0, tonumber(data and data.activeSeconds) or 0)
  for id, source in pairs(data and data.jobs or {}) do
    local job = deepcopy(source)
    if not job.completed then
      if not job.readyAtActive then
        job.readyAtActive = activeSeconds + CERTIFICATION_SECONDS
      end
      job.status = "pending"
      jobs[tostring(id)] = job
    end
  end
end

-- Torque curves -------------------------------------------------------------------------------------

-- Torque curve from a CSV file reference such as include("/vehicles/x/torque.csv"), or the table as given.
local function readCurveFile(curve)
  if type(curve) ~= "string" then return curve end
  local includePath = curve:match("include%s*%(%s*['\"]([^'\"]+)['\"]%s*%)")
  if not includePath then return nil end
  if includePath:sub(1, 1) ~= "/" then includePath = "/" .. includePath end
  local csv = readFile(includePath)
  if type(csv) ~= "string" or csv == "" then return nil end
  local result = {}
  for line in csv:gmatch("[^\r\n]+") do
    local first, second = line:match("^%s*([^,]+)%s*,%s*([^,]+)")
    if first and second then
      first = first:gsub('[%s\"]', '')
      second = second:gsub('[%s\"]', '')
      local rpm = tonumber(first)
      local torque = tonumber(second)
      if rpm and torque then result[#result + 1] = {rpm = rpm, torque = torque} end
    end
  end
  return result
end

-- Accepts {rpm, amount} rows, {rpm = ..., torque = ...} rows, or an rpm-keyed table.
local function normalizedCurve(curve)
  curve = readCurveFile(curve)
  if type(curve) ~= "table" then return nil end
  local result = {}
  for key, value in pairs(curve) do
    local rpm, amount
    if type(value) == "table" then
      rpm, amount = tonumber(value.rpm or value[1]), tonumber(value.torque or value[2])
    else
      rpm, amount = tonumber(key), tonumber(value)
    end
    if rpm and amount then result[#result + 1] = {rpm = rpm, amount = amount} end
  end
  table.sort(result, function(a, b) return a.rpm < b.rpm end)
  return #result > 0 and result or nil
end

-- Keeps the longest (then highest-torque) raw torque curve seen so far as the engine's base curve.
local function readBaseCurve(engine, curve)
  curve = readCurveFile(curve)
  if type(curve) ~= "table" then return end
  local samples, peakTorque, peakHp = {}, 0, 0
  for key, value in pairs(curve) do
    local rpm, torque
    if type(value) == "table" then
      rpm, torque = tonumber(value.rpm or value[1]), tonumber(value.torque or value[2])
    else
      rpm, torque = tonumber(key), tonumber(value)
    end
    if rpm and torque and rpm >= 0 then
      local hp = torque * rpm / HORSEPOWER_TORQUE_RPM_DIVISOR
      samples[#samples + 1] = {rpm = rpm, torque = torque, horsepower = hp}
      peakTorque, peakHp = math.max(peakTorque, torque), math.max(peakHp, hp)
    end
  end
  if #samples > #engine.bestSamples or peakTorque > engine.bestPeakTorque then
    table.sort(samples, function(a, b) return a.rpm < b.rpm end)
    engine.bestSamples, engine.bestPeakTorque, engine.bestPeakHp = samples, peakTorque, peakHp
  end
end

local function curveValue(curve, rpm)
  if rpm <= curve[1].rpm then return curve[1].amount end
  for index = 2, #curve do
    local right, left = curve[index], curve[index - 1]
    if rpm <= right.rpm then
      local range = right.rpm - left.rpm
      local blend = range > 0 and (rpm - left.rpm) / range or 0
      return left.amount + (right.amount - left.amount) * blend
    end
  end
  return curve[#curve].amount
end

-- Applies the authored torque modifiers to the base curve and recomputes its peaks.
local function applyTorqueModifiers(engine)
  if #engine.bestSamples == 0 or (#engine.additiveTorqueCurves == 0 and #engine.multiplierTorqueCurves == 0) then return end
  engine.bestPeakTorque, engine.bestPeakHp = 0, 0
  for _, sample in ipairs(engine.bestSamples) do
    local torque = sample.torque
    for _, curve in ipairs(engine.multiplierTorqueCurves) do torque = torque * curveValue(curve, sample.rpm) end
    for _, curve in ipairs(engine.additiveTorqueCurves) do torque = torque + curveValue(curve, sample.rpm) end
    sample.torque = torque
    sample.horsepower = torque * sample.rpm / HORSEPOWER_TORQUE_RPM_DIVISOR
    engine.bestPeakTorque = math.max(engine.bestPeakTorque, sample.torque)
    engine.bestPeakHp = math.max(engine.bestPeakHp, sample.horsepower)
  end
end

-- Authored data scan ----------------------------------------------------------------------------------

local function newEngineScan()
  return {
    rating = nil, legacyRating = nil, declaredMaxRpm = nil, limiterRpm = nil,
    bestSamples = {}, bestPeakTorque = 0, bestPeakHp = 0,
    forcedInduction = {}, additiveTorqueCurves = {}, multiplierTorqueCurves = {},
    seen = {}
  }
end

-- Walks authored tables for ratings, rev limits and torque curves. Forced-induction blocks are kept aside: their own numbers must not overwrite the engine's ratings.
local function scanAuthoredTable(engine, value, insideForcedInduction)
  if type(value) ~= "table" or engine.seen[value] then return end
  engine.seen[value] = true
  for key, child in pairs(value) do
    local lower = string.lower(tostring(key))
    if not insideForcedInduction and lower == "maxtorquerating" and tonumber(child) then
      engine.rating = engine.rating and math.min(engine.rating, tonumber(child)) or tonumber(child)
    elseif not insideForcedInduction and lower == "maxovertorquedamage" and tonumber(child) then
      engine.legacyRating = engine.legacyRating and math.min(engine.legacyRating, tonumber(child)) or tonumber(child)
    elseif not insideForcedInduction and lower == "maxrpm" then engine.declaredMaxRpm = tonumber(child) or engine.declaredMaxRpm
    elseif not insideForcedInduction and (lower == "revlimiterrpm" or lower == "limiterrpm") then engine.limiterRpm = tonumber(child) or engine.limiterRpm
    elseif not insideForcedInduction and lower == "maxav" and not engine.limiterRpm then
      engine.limiterRpm = tonumber(child) and tonumber(child) * RPM_PER_RAD_PER_SECOND or nil
    elseif not insideForcedInduction and lower == "torque" then readBaseCurve(engine, child)
    elseif not insideForcedInduction and lower == "torquemodmult" then
      local curve = normalizedCurve(child)
      if curve then engine.multiplierTorqueCurves[#engine.multiplierTorqueCurves + 1] = curve end
    elseif not insideForcedInduction and string.find(lower, "torquemod", 1, true) == 1 then
      local curve = normalizedCurve(child)
      if curve then engine.additiveTorqueCurves[#engine.additiveTorqueCurves + 1] = curve end
    elseif (lower == "supercharger" or lower == "turbocharger") and type(child) == "table" then
      engine.forcedInduction[#engine.forcedInduction + 1] = child
    end
    if type(child) == "table" then
      scanAuthoredTable(engine, child, insideForcedInduction or lower == "supercharger" or lower == "turbocharger")
    end
  end
end

-- Only these authored sections affect the static engine stress result. Traversing beams, nodes, meshes, sounds and slot metadata made cold catalog generation needlessly expensive on large modded vehicles.
local function scanPart(engine, data)
  scanAuthoredTable(engine, data.powertrain)
  scanAuthoredTable(engine, data.mainEngine)
  scanAuthoredTable(engine, data.vehicleController)
  if type(data.supercharger) == "table" then
    engine.forcedInduction[#engine.forcedInduction + 1] = data.supercharger
  end
  if type(data.turbocharger) == "table" then
    engine.forcedInduction[#engine.forcedInduction + 1] = data.turbocharger
  end
end

local function visitRecipeParts(engine, node, ioCtx)
  if not node then return end
  local data = node.name and jbeamIO.getPart(ioCtx, node.name)
  if data then scanPart(engine, data) end
  for _, child in pairs(node.children or {}) do visitRecipeParts(engine, child, ioCtx) end
end

-- Boost estimate -------------------------------------------------------------------------------------

-- A boost value authored as a number, or as a tuning variable with an optional offset such as "$boost + 2".
local function resolveAuthoredNumber(recipe, value)
  local numeric = tonumber(value)
  if numeric then return numeric end
  if type(value) ~= "string" then return nil end
  local variableName = value:match("(%$[%w_]+)")
  local base = variableName and tonumber(recipe.tuning and recipe.tuning[variableName])
  if not base then return nil end
  local offset = tonumber(value:match("([%+%-]%s*[%d%.]+)")) or 0
  return base + offset
end

local function devicePressure(recipe, device, peakTorqueRpm)
  local pressure
  for _, key in ipairs(FORCED_INDUCTION_KEYS) do
    pressure = resolveAuthoredNumber(recipe, device[key])
    if pressure then break end
  end
  if not pressure and tonumber(device.pressurePSIPer1kRPM) then
    pressure = tonumber(device.pressurePSIPer1kRPM) * math.max(0, peakTorqueRpm)
      * math.max(0.1, tonumber(device.gearRatio) or 1) / 1000
  end
  return tonumber(pressure) or 0
end

-- The highest boost any authored device reaches, capped. Used for a risk estimate, not a dyno run.
local function estimateBoostPsi(engine, recipe, peakTorqueRpm)
  local estimatedBoostPsi = 0
  for _, device in ipairs(engine.forcedInduction) do
    estimatedBoostPsi = math.max(estimatedBoostPsi, devicePressure(recipe, device, peakTorqueRpm))
  end
  return math.min(MAXIMUM_ESTIMATED_BOOST_PSI, estimatedBoostPsi)
end

-- Reads the authored engine into `engine`: ratings, rev limits, torque curves and forced induction.
local function collectEngineData(recipe, ioCtx)
  local engine = newEngineScan()
  visitRecipeParts(engine, recipe.tree, ioCtx)
  applyTorqueModifiers(engine)
  return engine
end

local function peakTorqueRpmOf(samples, peakTorque)
  local peakTorqueRpm = 0
  for _, sample in ipairs(samples) do
    if sample.torque >= peakTorque then peakTorqueRpm = sample.rpm end
  end
  return peakTorqueRpm
end

-- Reads the exact authored recipe. Values are canonical BeamNG units: Nm and mechanical horsepower. UI code performs the player's preferred conversion.
local function analyzeRecipe(recipe, existingIoCtx)
  if type(recipe) ~= "table" or not recipe.vehicleModel or not recipe.tree then
    return nil, "Recipe metadata is incomplete."
  end
  local vehicleDir = string.format("/vehicles/%s/", recipe.vehicleModel)
  if not FS:directoryExists(vehicleDir) then return nil, "The source vehicle model is unavailable." end
  local ioCtx = existingIoCtx or jbeamIO.startLoading({vehicleDir, "/vehicles/common/"})
  if not ioCtx then return nil, "The engine JBeam could not be loaded." end

  local engine = collectEngineData(recipe, ioCtx)
  local usedLegacy = not engine.rating and engine.legacyRating ~= nil
  local rating = engine.rating or engine.legacyRating
  if not rating or rating <= 0 then return nil, "This engine has no declared torque rating and is not certifiable." end
  if #engine.bestSamples == 0 or engine.bestPeakTorque <= 0 then return nil, "This engine has no readable torque curve and is not certifiable." end
  local limiterRpm = engine.limiterRpm or engine.declaredMaxRpm or engine.bestSamples[#engine.bestSamples].rpm

  -- A full dyno spawn would be expensive and brittle for retail stock. Estimate the added cylinder pressure from authored boost hardware instead. This is intentionally conservative and bounded; it is used for a risk warning, not as a replacement for BeamNG's runtime powertrain simulation.
  local estimatedBoostPsi = estimateBoostPsi(engine, recipe, peakTorqueRpmOf(engine.bestSamples, engine.bestPeakTorque))
  local boostMultiplier = 1 + estimatedBoostPsi / ATMOSPHERE_PSI * BOOST_TORQUE_GAIN
  local peakTorque = engine.bestPeakTorque * boostMultiplier
  local peakHp = engine.bestPeakHp * boostMultiplier

  local failed = peakTorque > rating + 0.001
  if engine.declaredMaxRpm and limiterRpm and limiterRpm > engine.declaredMaxRpm + 1 then failed = true end
  local scale = rating / peakTorque

  return {
    result = failed and "failed" or "passed",
    peakHorsepower = peakHp,
    peakTorque = peakTorque,
    rating = rating,
    torqueUtilization = peakTorque / rating,
    estimatedSafePower = peakHp * scale,
    estimatedBoostPsi = estimatedBoostPsi,
    limiterRpm = limiterRpm,
    declaredMaxRpm = engine.declaredMaxRpm,
    usedLegacyRating = usedLegacy,
    samples = engine.bestSamples
  }
end

-- Jobs ----------------------------------------------------------------------------------------------

local function completeJob(packageId, job)
  if job.completed then return end
  job.completed = true
  job.status = job.analysis.result
  job.completedAtActive = activeSeconds
  local certification = deepcopy(job.analysis)
  certification.status = job.status
  certification.recipeSignature = job.recipeSignature
  certification.completedAtActive = job.completedAtActive
  certification.fee = job.fee
  certification.shopId = job.shopId
  overhaul_career_parts_engines_enginePackages.setEngineShopCertification(packageId, certification)
  jobs[tostring(packageId)] = nil
  guihooks.trigger("toastrMsg", {
    type = job.status == "passed" and "success" or "warning",
    title = "Engine stress test complete",
    msg = job.status == "passed" and (job.packageName .. " passed its stress test.")
      or (job.packageName .. " exceeded its declared stress limit.")
  })
end

-- A pending certification on a package with no running job was left by an interrupted save; clear it.
local function clearOrphanPendingCertifications()
  orphanCheckPending = false
  local packagesModule = overhaul_career_parts_engines_enginePackages
  if not packagesModule or not packagesModule.listPackages then return end
  for _, package in ipairs(packagesModule.listPackages({ownerType = "personal"}) or {}) do
    local certification = package.engineShopCertification
    if type(certification) == "table" and certification.status == "pending" and not jobs[tostring(package.id)] then
      package.engineShopCertification = nil
      log("W", "engineCertification", "Cleared pending stress test with no job for package " .. tostring(package.id))
    end
  end
end

local function processJobs()
  if orphanCheckPending then clearOrphanPendingCertifications() end
  for packageId, job in pairs(jobs) do
    if not overhaul_career_parts_engines_enginePackages.getPackage(packageId) then
      jobs[packageId] = nil
    elseif not job.completed and activeSeconds >= (tonumber(job.readyAtActive) or math.huge) then
      completeJob(packageId, job)
    end
  end
end

-- Why a package cannot start a stress test, or nil when it can.
local function certificationBlocker(package, recipe)
  local prior = package.engineShopCertification
  if prior and prior.recipeSignature == recipe.signature and (prior.status == "passed" or prior.status == "failed") then
    return prior.status == "passed"
      and "This exact configuration already passed its stress test."
      or "This exact configuration already failed its stress test. Change the package before testing it again."
  end
end

local function startPersonalCertification(packageId, shopId)
  processJobs()
  packageId = tostring(packageId or "")
  local package = overhaul_career_parts_engines_enginePackages.getPackage(packageId)
  if not package or package.ownerType == "business" then return {success = false, message = "Choose a personal Engine Package."} end
  if overhaul_career_parts_engines_enginePackages.getPackageStatus(package) ~= "stored" then
    return {success = false, message = "Certification requires a stored Engine Package."}
  end
  local existing = jobs[packageId]
  if existing and not existing.completed then return {success = false, message = "This package is already being certified."} end
  local freshValue, recipe = overhaul_career_parts_engines_enginePackages.getFreshPackageValue(package)
  if not freshValue then return {success = false, message = recipe or "Package value could not be calculated."} end
  local blocker = certificationBlocker(package, recipe)
  if blocker then return {success = false, message = blocker} end
  local analysis, err = analyzeRecipe(recipe)
  if not analysis then return {success = false, message = err} end
  local fee = math.max(1, math.floor(freshValue * CERTIFICATION_FEE_RATE + 0.5))
  if not overhaul_career_economy_payment.pay({money = {amount = fee, canBeNegative = false}}, require("overhaul/lib/finance/metadata").tag({
    label = "Engine stress test", tags = {"engineCertification", "maintenance"}
  }, "service", {vehicleRelated = false, locationId = shopId})) then return {success = false, message = "You cannot afford the stress-test fee."} end
  jobs[packageId] = {
    packageId = packageId, packageName = package.name, shopId = tostring(shopId or ""),
    recipeSignature = recipe.signature, fee = fee, submittedAtActive = activeSeconds, readyAtActive = activeSeconds + CERTIFICATION_SECONDS,
    status = "pending", completed = false, analysis = analysis
  }
  overhaul_career_parts_engines_enginePackages.setEngineShopCertification(packageId, {
    status = "pending", recipeSignature = recipe.signature, submittedAtActive = activeSeconds,
    readyAtActive = activeSeconds + CERTIFICATION_SECONDS, fee = fee, shopId = tostring(shopId or "")
  })
  return {success = true, message = string.format("Stress test started for $%d. It will finish after 60 seconds.", fee)}
end

local function getPersonalJobs()
  processJobs()
  local result = {}
  for _, job in pairs(jobs) do
    local copy = deepcopy(job)
    copy.remainingSeconds = copy.completed and 0 or math.max(0, (copy.readyAtActive or activeSeconds) - activeSeconds)
    result[#result + 1] = copy
  end
  table.sort(result, function(a, b) return tostring(a.packageId) < tostring(b.packageId) end)
  return result
end

local function packageGuard(package)
  local job = package and jobs[tostring(package.id)]
  if job and not job.completed then return false, "This Engine Package is locked during certification." end
  return true
end

-- Update -------------------------------------------------------------------------------------------

local function onUpdate(dtReal)
  if not (overhaul_career_career and overhaul_career_career.isActive()) then return end
  if simTimeAuthority.getPause() then return end
  activeSeconds = activeSeconds + math.max(0, tonumber(dtReal) or 0)
  processJobs()
end

-- Lifecycle ------------------------------------------------------------------------

local function initialize()
  if initialized then return end
  initialized = true
  loadData()
  overhaul_career_parts_engines_enginePackages.registerPackageReferenceGuard(packageGuard)
end

-- Public API ---------------------------------------------------------------------------------------

M.analyzeRecipe = analyzeRecipe
M.startPersonalCertification = startPersonalCertification
M.getPersonalJobs = getPersonalJobs
M.processJobs = processJobs

-- Hooks --------------------------------------------------------------------------------------------

M.onUpdate = onUpdate
M.onCareerActivated = initialize
M.onOverhaulModulesActivated = initialize
M.onOverhaulSaveCurrentProfile = function(path)
  initialize()
  saveData(path)
end

return M
