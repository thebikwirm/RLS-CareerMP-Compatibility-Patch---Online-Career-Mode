local M = {}

M.dependencies = {
  "career_career", "career_saveSystem", "career_modules_payment",
  "career_modules_enginePackages"
}

local jbeamIO = require("jbeam/io")
local SAVE_VERSION = 2
local SAVE_PATH = "/career/rls_career/engineCertifications.json"
local jobs = {}
local activeSeconds = 0
local initialized = false

local function saveData(savePath)
  if not savePath then local _, path = career_saveSystem.getCurrentProfile(); savePath = path end
  if savePath then
    jsonWriteFile(savePath .. SAVE_PATH, {version = SAVE_VERSION, activeSeconds = activeSeconds, jobs = jobs}, true)
  end
end

local function loadData()
  jobs = {}
  local _, savePath = career_saveSystem.getCurrentProfile()
  local data = savePath and jsonReadFile(savePath .. SAVE_PATH) or nil
  activeSeconds = math.max(0, tonumber(data and data.activeSeconds) or 0)
  for id, source in pairs(data and data.jobs or {}) do
    local job = deepcopy(source)
    if not job.completed then
      if not job.readyAtActive then
        job.readyAtActive = activeSeconds + 60
      end
      job.status = "pending"
      jobs[tostring(id)] = job
    end
  end
end

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

-- Reads the exact authored recipe. Values are canonical BeamNG units: Nm and
-- mechanical horsepower. UI code performs the player's preferred conversion.
local function analyzeRecipe(recipe, existingIoCtx)
  if type(recipe) ~= "table" or not recipe.vehicleModel or not recipe.tree then
    return nil, "Recipe metadata is incomplete."
  end
  local vehicleDir = string.format("/vehicles/%s/", recipe.vehicleModel)
  if not FS:directoryExists(vehicleDir) then return nil, "The source vehicle model is unavailable." end
  local ioCtx = existingIoCtx or jbeamIO.startLoading({vehicleDir, "/vehicles/common/"})
  if not ioCtx then return nil, "The engine JBeam could not be loaded." end

  local rating, legacyRating, declaredMaxRpm, limiterRpm
  local bestSamples, bestPeakTorque, bestPeakHp = {}, 0, 0
  local forcedInduction = {}
  local additiveTorqueCurves, multiplierTorqueCurves = {}, {}
  local seen = {}

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

  local function readCurve(curve)
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
        local hp = torque * rpm / 7127
        samples[#samples + 1] = {rpm = rpm, torque = torque, horsepower = hp}
        peakTorque, peakHp = math.max(peakTorque, torque), math.max(peakHp, hp)
      end
    end
    if #samples > #bestSamples or peakTorque > bestPeakTorque then
      table.sort(samples, function(a, b) return a.rpm < b.rpm end)
      bestSamples, bestPeakTorque, bestPeakHp = samples, peakTorque, peakHp
    end
  end

  local function scan(value, insideForcedInduction)
    if type(value) ~= "table" or seen[value] then return end
    seen[value] = true
    for key, child in pairs(value) do
      local lower = string.lower(tostring(key))
      if not insideForcedInduction and lower == "maxtorquerating" and tonumber(child) then
        rating = rating and math.min(rating, tonumber(child)) or tonumber(child)
      elseif not insideForcedInduction and lower == "maxovertorquedamage" and tonumber(child) then
        legacyRating = legacyRating and math.min(legacyRating, tonumber(child)) or tonumber(child)
      elseif not insideForcedInduction and lower == "maxrpm" then declaredMaxRpm = tonumber(child) or declaredMaxRpm
      elseif not insideForcedInduction and (lower == "revlimiterrpm" or lower == "limiterrpm") then limiterRpm = tonumber(child) or limiterRpm
      elseif not insideForcedInduction and lower == "maxav" and not limiterRpm then
        limiterRpm = tonumber(child) and tonumber(child) * 9.549296596 or nil
      elseif not insideForcedInduction and lower == "torque" then readCurve(child)
      elseif not insideForcedInduction and lower == "torquemodmult" then
        local curve = normalizedCurve(child)
        if curve then multiplierTorqueCurves[#multiplierTorqueCurves + 1] = curve end
      elseif not insideForcedInduction and string.find(lower, "torquemod", 1, true) == 1 then
        local curve = normalizedCurve(child)
        if curve then additiveTorqueCurves[#additiveTorqueCurves + 1] = curve end
      elseif (lower == "supercharger" or lower == "turbocharger") and type(child) == "table" then
        forcedInduction[#forcedInduction + 1] = child
      end
      if type(child) == "table" then
        scan(child, insideForcedInduction or lower == "supercharger" or lower == "turbocharger")
      end
    end
  end

  local function visit(node)
    if not node then return end
    local data = node.name and jbeamIO.getPart(ioCtx, node.name)
    if data then
      -- Only these authored sections affect the static engine stress result.
      -- Traversing beams, nodes, meshes, sounds, and slot metadata made cold
      -- catalog generation needlessly expensive on large modded vehicles.
      scan(data.powertrain)
      scan(data.mainEngine)
      scan(data.vehicleController)
      if type(data.supercharger) == "table" then
        forcedInduction[#forcedInduction + 1] = data.supercharger
      end
      if type(data.turbocharger) == "table" then
        forcedInduction[#forcedInduction + 1] = data.turbocharger
      end
    end
    for _, child in pairs(node.children or {}) do visit(child) end
  end
  visit(recipe.tree)

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
  if #bestSamples > 0 and (#additiveTorqueCurves > 0 or #multiplierTorqueCurves > 0) then
    bestPeakTorque, bestPeakHp = 0, 0
    for _, sample in ipairs(bestSamples) do
      local torque = sample.torque
      for _, curve in ipairs(multiplierTorqueCurves) do torque = torque * curveValue(curve, sample.rpm) end
      for _, curve in ipairs(additiveTorqueCurves) do torque = torque + curveValue(curve, sample.rpm) end
      sample.torque = torque
      sample.horsepower = torque * sample.rpm / 7127
      bestPeakTorque = math.max(bestPeakTorque, sample.torque)
      bestPeakHp = math.max(bestPeakHp, sample.horsepower)
    end
  end

  local usedLegacy = not rating and legacyRating ~= nil
  rating = rating or legacyRating
  if not rating or rating <= 0 then return nil, "This engine has no declared torque rating and is not certifiable." end
  if #bestSamples == 0 or bestPeakTorque <= 0 then return nil, "This engine has no readable torque curve and is not certifiable." end
  limiterRpm = limiterRpm or declaredMaxRpm or bestSamples[#bestSamples].rpm

  -- A full dyno spawn would be expensive and brittle for retail stock. Estimate
  -- the added cylinder pressure from authored boost hardware instead. This is
  -- intentionally conservative and bounded; it is used for a risk warning,
  -- not as a replacement for BeamNG's runtime powertrain simulation.
  local peakTorqueRpm = 0
  for _, sample in ipairs(bestSamples) do
    if sample.torque >= bestPeakTorque then peakTorqueRpm = sample.rpm end
  end
  local function resolveAuthoredNumber(value)
    local numeric = tonumber(value)
    if numeric then return numeric end
    if type(value) ~= "string" then return nil end
    local variableName = value:match("(%$[%w_]+)")
    local base = variableName and tonumber(recipe.tuning and recipe.tuning[variableName])
    if not base then return nil end
    local offset = tonumber(value:match("([%+%-]%s*[%d%.]+)")) or 0
    return base + offset
  end
  local estimatedBoostPsi = 0
  for _, device in ipairs(forcedInduction) do
    local pressure
    for _, key in ipairs({"maxWastegatePressure", "wastegatePressure", "wastegateLimit", "wastegateStart", "maxBoost"}) do
      pressure = resolveAuthoredNumber(device[key])
      if pressure then break end
    end
    if not pressure and tonumber(device.pressurePSIPer1kRPM) then
      pressure = tonumber(device.pressurePSIPer1kRPM) * math.max(0, peakTorqueRpm)
        * math.max(0.1, tonumber(device.gearRatio) or 1) / 1000
    end
    estimatedBoostPsi = math.max(estimatedBoostPsi, tonumber(pressure) or 0)
  end
  estimatedBoostPsi = math.min(50, estimatedBoostPsi)
  local boostMultiplier = 1 + estimatedBoostPsi / 14.7 * 0.55
  bestPeakTorque = bestPeakTorque * boostMultiplier
  bestPeakHp = bestPeakHp * boostMultiplier

  local failed = bestPeakTorque > rating + 0.001
  if declaredMaxRpm and limiterRpm and limiterRpm > declaredMaxRpm + 1 then failed = true end
  local scale = rating / bestPeakTorque
  local estimatedSafePower = bestPeakHp * scale

  return {
    result = failed and "failed" or "passed",
    peakHorsepower = bestPeakHp,
    peakTorque = bestPeakTorque,
    rating = rating,
    torqueUtilization = bestPeakTorque / rating,
    estimatedSafePower = estimatedSafePower,
    estimatedBoostPsi = estimatedBoostPsi,
    limiterRpm = limiterRpm,
    declaredMaxRpm = declaredMaxRpm,
    usedLegacyRating = usedLegacy,
    samples = bestSamples
  }
end

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
  career_modules_enginePackages.setEngineShopCertification(packageId, certification)
  jobs[tostring(packageId)] = nil
  saveData()
  if guihooks then
    guihooks.trigger("toastrMsg", {
      type = job.status == "passed" and "success" or "warning",
      title = "Engine stress test complete",
      msg = job.status == "passed" and (job.packageName .. " passed its stress test.")
        or (job.packageName .. " exceeded its declared stress limit.")
    })
  end
end

local function processJobs()
  for packageId, job in pairs(jobs) do
    if not career_modules_enginePackages.getPackage(packageId) then
      jobs[packageId] = nil
    elseif not job.completed and activeSeconds >= (tonumber(job.readyAtActive) or math.huge) then
      completeJob(packageId, job)
    end
  end
end

local function startPersonalCertification(packageId, shopId)
  processJobs()
  packageId = tostring(packageId or "")
  local package = career_modules_enginePackages.getPackage(packageId)
  if not package or package.ownerType == "business" then return {success = false, message = "Choose a personal Engine Package."} end
  if career_modules_enginePackages.getPackageStatus(package) ~= "stored" then
    return {success = false, message = "Certification requires a stored Engine Package."}
  end
  local existing = jobs[packageId]
  if existing and not existing.completed then return {success = false, message = "This package is already being certified."} end
  local freshValue, recipe = career_modules_enginePackages.getFreshPackageValue(package)
  if not freshValue then return {success = false, message = recipe or "Package value could not be calculated."} end
  local prior = package.engineShopCertification
  if prior and prior.recipeSignature == recipe.signature and (prior.status == "passed" or prior.status == "failed") then
    return {success = false, message = prior.status == "passed"
      and "This exact configuration already passed its stress test."
      or "This exact configuration already failed its stress test. Change the package before testing it again."}
  end
  local analysis, err = analyzeRecipe(recipe)
  if not analysis then return {success = false, message = err} end
  local fee = math.max(1, math.floor(freshValue * 0.10 + 0.5))
  if not career_modules_payment.pay({money = {amount = fee, canBeNegative = false}}, {
    label = "Engine stress test", tags = {"engineCertification", "maintenance"}
  }) then return {success = false, message = "You cannot afford the stress-test fee."} end
  jobs[packageId] = {
    packageId = packageId, packageName = package.name, shopId = tostring(shopId or ""),
    recipeSignature = recipe.signature, fee = fee, submittedAtActive = activeSeconds, readyAtActive = activeSeconds + 60,
    status = "pending", completed = false, analysis = analysis
  }
  career_modules_enginePackages.setEngineShopCertification(packageId, {
    status = "pending", recipeSignature = recipe.signature, submittedAtActive = activeSeconds,
    readyAtActive = activeSeconds + 60, fee = fee, shopId = tostring(shopId or "")
  })
  saveData()
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

local function initialize()
  if initialized then return end
  initialized = true
  loadData()
  if career_modules_enginePackages and career_modules_enginePackages.registerPackageReferenceGuard then
    career_modules_enginePackages.registerPackageReferenceGuard(packageGuard)
  end
end

M.analyzeRecipe = analyzeRecipe
M.startPersonalCertification = startPersonalCertification
M.getPersonalJobs = getPersonalJobs
M.processJobs = processJobs
M.onUpdate = function(dtReal)
  if not (career_career and career_career.isActive()) then return end
  if simTimeAuthority and simTimeAuthority.getPause and simTimeAuthority.getPause() then return end
  activeSeconds = activeSeconds + math.max(0, tonumber(dtReal) or 0)
  processJobs()
end
M.onCareerActivated = initialize
M.onCareerModulesActivated = initialize
M.onSaveCurrentProfile = function(path) saveData(path) end

return M
