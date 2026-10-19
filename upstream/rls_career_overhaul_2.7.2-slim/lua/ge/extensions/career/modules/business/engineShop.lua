local M = {}

M.dependencies = {
  "career_career", "career_saveSystem", "career_modules_bank", "career_modules_inventory",
  "career_modules_partInventory", "career_modules_enginePackages", "career_modules_dynamicWeather",
  "career_modules_engineCertification",
  "career_modules_business_businessManager", "career_modules_business_businessTabRegistry",
  "career_modules_business_businessInventory", "career_modules_business_businessPartInventory",
  "career_modules_delivery_generator", "career_modules_delivery_general",
  "career_modules_delivery_parcelManager", "freeroam_facilities"
}

local jbeamIO = require("jbeam/io")
local devConsole = require("ge/extensions/career/modules/devConsole")
local SHOP_TYPE = "engineShop"
local SAVE_VERSION = 3
local SAVE_PATH = "/career/rls_career/engineShops.json"
local STARTING_WAREHOUSE = 15
local FRESH_VALUE_MARKET_MULTIPLIER = 1.55
local LANDED_COST_FLOOR_MULTIPLIER = 1.15
local CERTIFICATION_DURATION_SECONDS = 600
local ENGINE_SALE_MIN_SECONDS = 300
local ENGINE_SALE_MAX_SECONDS = 900
local LEGACY_LINE_DURATION_MINUTES = {480, 420, 360, 300}
local LINE_DURATION_SECONDS = {900, 720, 480, 300}
local LINE_SUCCESS_CHANCES = {0.90, 0.94, 0.97, 0.99}
local LINE_BREAKDOWN_CHANCES = {0.05, 0.03, 0.02, 0.01}
local LINE_OVERHAUL_BASES = {2500, 5000, 10000}
local SHOP_SITE = "/levels/west_coast_usa/engineShop.sites.json"
local SHOP_ZONE = "West Coast Engine Works Garage"
local states = {}
local activeBusinessId
local shopZones
local supplyPickupOpen = false
local supplyLoadInProgress = false
local normalizeBlueprintPrice

local capacityUpgrades = {
  warehouse1 = {name = "Warehouse Expansion I", cost = 25000, effect = "Shared storage 15 to 25 spots."},
  warehouse2 = {name = "Warehouse Expansion II", cost = 75000, requires = "warehouse1", effect = "Shared storage 25 to 50 spots."},
  line2 = {name = "Production Line II", cost = 100000, effect = "Unlocks the second production line."},
  line3 = {name = "Production Line III", cost = 200000, requires = "line2", effect = "Unlocks the third production line."},
}

local lineUpgradeDefs = {
  speed = {name = "Production Speed", costs = {5000, 15000, 30000}, descriptions = {"15m to 12m per engine", "12m to 8m per engine", "8m to 5m per engine"}},
  quality = {name = "Quality Control", costs = {5000, 15000, 30000}, descriptions = {"90% to 94% success", "94% to 97% success", "97% to 99% success"}},
  maintenance = {name = "Preventive Maintenance", costs = {5000, 15000, 30000}, descriptions = {"3% breakdown, 15% cheaper overhaul", "2% breakdown, 30% cheaper overhaul", "1% breakdown, 40% cheaper overhaul"}},
}

local function nowWorldMinutes()
  local weather = career_modules_dynamicWeather and career_modules_dynamicWeather.getUiState and career_modules_dynamicWeather.getUiState() or {}
  local day = math.max(0, math.floor(tonumber(weather.dayIndex) or 0))
  local minute = math.max(0, math.min(1439, math.floor(tonumber(weather.minuteOfDay) or 0)))
  return day * 1440 + minute, day, minute
end

local function indexed(value)
  local economy = career_modules_globalEconomy
  local index = economy and economy.getGlobalIndex and economy.getGlobalIndex() or 1
  return math.floor((tonumber(value) or 0) * index + 0.5)
end

local function notify(kind, title, message)
  if guihooks then guihooks.trigger("toastrMsg", {type = kind, title = title, msg = message}) end
end

local function accountFor(id)
  return career_modules_bank and career_modules_bank.getBusinessAccount and career_modules_bank.getBusinessAccount(SHOP_TYPE, tostring(id))
end

local function pay(id, amount, label, description)
  amount = math.max(0, math.floor(tonumber(amount) or 0))
  if amount == 0 then return true end
  local account = accountFor(id)
  return account and career_modules_bank.payFromAccount({money = {amount = amount, canBeNegative = false}}, account.id, label, description) == true
end

local function reward(id, amount, label, description)
  amount = math.max(0, math.floor(tonumber(amount) or 0))
  if amount == 0 then return true end
  local account = accountFor(id)
  return account and career_modules_bank.rewardToAccount({money = {amount = amount}}, account.id, label, description) == true
end

local function newLine(id)
  return {id = id, blueprintId = nil, running = false, broken = false, progressSeconds = 0,
    attemptStarted = false, upgrades = {speed = 0, quality = 0, maintenance = 0}, attempts = {}, overhaulCostSinceLastAttempt = 0}
end

local function migrateLegacyState(id, state)
  if tonumber(state.version) and tonumber(state.version) >= 2 then return state end
  local blueprints = {}
  for revisionId, revision in pairs(state.revisions or {}) do
    local certification = revision.certification or {}
    if certification.status == "passed" then
      local product
      for _, candidate in pairs(state.products or {}) do
        for _, candidateRevisionId in ipairs(candidate.revisionIds or {}) do
          if tostring(candidateRevisionId) == tostring(revisionId) then product = candidate break end
        end
        if product then break end
      end
      local blueprintId = tostring(revisionId)
      blueprints[blueprintId] = {id = blueprintId,
        name = (product and product.name) or (revision.recipe and revision.recipe.rootEngineNiceName) or "Certified Engine",
        recipe = deepcopy(revision.recipe or {}), recipeSignature = revision.recipeSignature or (revision.recipe and revision.recipe.signature),
        freshValue = math.max(1, math.floor(tonumber(revision.freshValue) or 1)), certification = deepcopy(certification),
        listed = product and product.listed == true and tostring(product.salesRevisionId or product.activeRevisionId) == tostring(revisionId) or false,
        price = math.max(1, math.floor(tonumber(product and product.price) or (tonumber(revision.freshValue) or 1) * FRESH_VALUE_MARKET_MULTIPLIER)),
        awareness = math.max(0, math.min(100, tonumber(product and product.awareness) or 0)), createdAt = revision.createdAt or os.time()}
    end
  end
  state.blueprints = blueprints
  state.legacyFinishedToMaterialize = deepcopy(state.finishedStock or {})
  state.version = 2
  state.migrationPending = true
  return state
end

local function normalizeState(id, state)
  local loadedVersion = math.max(1, math.floor(tonumber(state and state.version) or 1))
  state = migrateLegacyState(id, type(state) == "table" and state or {})
  state.id = tostring(id)
  state.version = SAVE_VERSION
  state.blueprints = type(state.blueprints) == "table" and state.blueprints or {}
  state.certificationJobs = type(state.certificationJobs) == "table" and state.certificationJobs or {}
  state.rawStock = type(state.rawStock) == "table" and state.rawStock or {}
  state.reservations = type(state.reservations) == "table" and state.reservations or {}
  state.salesHistory = type(state.salesHistory) == "table" and state.salesHistory or {}
  state.manufacturedPackageIds = type(state.manufacturedPackageIds) == "table" and state.manufacturedPackageIds or {}
  state.upgrades = type(state.upgrades) == "table" and state.upgrades or {}
  state.brandPopularity = math.max(0, math.min(100, tonumber(state.brandPopularity) or 0))
  state.nextBlueprintId = math.max(1, math.floor(tonumber(state.nextBlueprintId) or 1))
  state.nextReservationId = math.max(1, math.floor(tonumber(state.nextReservationId) or 1))
  for key in pairs(state.blueprints) do local numeric = tonumber(key); if numeric then state.nextBlueprintId = math.max(state.nextBlueprintId, numeric + 1) end end
  local oldLines = state.lines or {}
  state.lines = {}
  for lineId = 1, 3 do
    local old = oldLines[lineId] or {}
    local line = newLine(lineId)
    line.blueprintId = old.blueprintId or old.revisionId
    line.running = old.running == true or old.status == "running"
    line.broken = old.broken == true
    line.attemptStarted = old.attemptStarted == true
    line.attempts = type(old.attempts) == "table" and old.attempts or {}
    for _, attempt in ipairs(line.attempts) do
      if attempt.success == true and attempt.packageId ~= nil then
        state.manufacturedPackageIds[tostring(attempt.packageId)] = true
      end
    end
    line.overhaulCostSinceLastAttempt = math.max(0, tonumber(old.overhaulCostSinceLastAttempt) or 0)
    if old.upgrades then
      for kind in pairs(line.upgrades) do line.upgrades[kind] = math.max(0, math.min(3, math.floor(tonumber(old.upgrades[kind]) or 0))) end
    elseif old.hires then
      line.upgrades.speed = old.hires.specialist and 1 or 0
      line.upgrades.quality = old.hires.inspector and 1 or 0
      line.upgrades.maintenance = old.hires.maintenance and 1 or 0
    end
    local speedLevel = math.max(0, math.min(3, math.floor(tonumber(line.upgrades.speed) or 0)))
    local newDuration = LINE_DURATION_SECONDS[speedLevel + 1]
    if loadedVersion < 3 then
      local oldDuration = LEGACY_LINE_DURATION_MINUTES[speedLevel + 1]
      local oldProgress = math.max(0, tonumber(old.progressMinutes) or tonumber(old.progressSeconds) or 0)
      line.progressSeconds = math.min(newDuration, oldDuration > 0 and oldProgress / oldDuration * newDuration or 0)
    else
      line.progressSeconds = math.max(0, tonumber(old.progressSeconds) or 0)
    end
    state.lines[lineId] = line
  end
  for _, job in pairs(state.certificationJobs) do
    if type(job) == "table" and not job.completed then
      if loadedVersion < 3 then
        local absolute = nowWorldMinutes()
        local submittedAt = tonumber(job.submittedAt) or absolute
        local readyAt = tonumber(job.readyAt) or (submittedAt + 60)
        local legacyDuration = math.max(1, readyAt - submittedAt)
        local legacyProgress = math.max(0, math.min(legacyDuration, absolute - submittedAt))
        job.progressSeconds = CERTIFICATION_DURATION_SECONDS * legacyProgress / legacyDuration
      else
        job.progressSeconds = math.max(0, tonumber(job.progressSeconds) or 0)
      end
      job.durationSeconds = CERTIFICATION_DURATION_SECONDS
    end
  end
  state.lastWorldMinutes = tonumber(state.lastWorldMinutes) or nowWorldMinutes()
  state.salesCycleProgressSeconds = math.max(0, tonumber(state.salesCycleProgressSeconds) or 0)
  state.salesUpdateAccumulatorSeconds = math.max(0, tonumber(state.salesUpdateAccumulatorSeconds) or 0)
  state.salesCycleDurationSeconds = tonumber(state.salesCycleDurationSeconds)
  if loadedVersion < 3 and state.salesCycleDurationSeconds and state.salesCycleDurationSeconds > 0 then
    state.salesCycleMigrationRatio = math.max(0, math.min(1, state.salesCycleProgressSeconds / state.salesCycleDurationSeconds))
    state.salesCycleProgressSeconds = 0
    state.salesCycleDurationSeconds = nil
  end
  state.salesCurrentBlueprintId = state.salesCurrentBlueprintId and tostring(state.salesCurrentBlueprintId) or nil
  state.salesCursorBlueprintId = state.salesCursorBlueprintId and tostring(state.salesCursorBlueprintId) or nil
  for _, reservation in pairs(state.reservations) do
    reservation.blueprintId = tostring(reservation.blueprintId or reservation.revisionId or "")
    reservation.revisionId = reservation.blueprintId
    if reservation.status == "inTransit" then reservation.status, reservation.cargoId = "available", nil end
  end
  return state
end

local function ensureState(id)
  id = tostring(id)
  if not states[id] then states[id] = normalizeState(id, {}) end
  return states[id]
end

local function upgradeLiquidationValue(id)
  local state = ensureState(id)
  local total = 0
  for upgradeId, definition in pairs(capacityUpgrades) do
    if state.upgrades[upgradeId] then total = total + indexed(definition.cost) end
  end
  for _, line in ipairs(state.lines or {}) do
    for kind, definition in pairs(lineUpgradeDefs) do
      local level = math.max(0, math.min(3, math.floor(tonumber(line.upgrades and line.upgrades[kind]) or 0)))
      for index = 1, level do total = total + indexed(definition.costs[index]) end
    end
  end
  return math.floor(total + 0.5)
end

local function getLiquidationValue(id)
  local state = ensureState(id)
  local total = upgradeLiquidationValue(id)
  if career_modules_business_businessPartInventory and career_modules_business_businessPartInventory.getLiquidationValue then
    total = total + (career_modules_business_businessPartInventory.getLiquidationValue(id) or 0)
  end
  for blueprintId, quantity in pairs(state.rawStock) do
    local blueprint = state.blueprints[tostring(blueprintId)]
    if blueprint then total = total + math.max(0, tonumber(quantity) or 0) * math.max(0, tonumber(blueprint.freshValue) or 0) end
  end
  for _, reservation in pairs(state.reservations) do
    if reservation.status ~= "cancelled" and reservation.status ~= "delivered" then
      total = total + math.max(0, tonumber(reservation.paidCost) or 0)
    end
  end
  return math.floor(total + 0.5)
end

local function saveData(currentSavePath)
  if not currentSavePath then local _, path = career_saveSystem.getCurrentProfile(); currentSavePath = path end
  if currentSavePath then jsonWriteFile(currentSavePath .. SAVE_PATH, {version = SAVE_VERSION, states = states}, true) end
end

local function loadData()
  states = {}
  local _, savePath = career_saveSystem.getCurrentProfile()
  local data = savePath and jsonReadFile(savePath .. SAVE_PATH) or {}
  local pricesAdjusted = false
  for id, state in pairs(data and data.states or {}) do
    state = normalizeState(id, state)
    states[tostring(id)] = state
    for _, blueprint in pairs(state.blueprints) do
      if normalizeBlueprintPrice(blueprint, state) then pricesAdjusted = true end
    end
    if career_modules_enginePackages and career_modules_enginePackages.repairManufacturedPackageYears then
      career_modules_enginePackages.repairManufacturedPackageYears(state.manufacturedPackageIds)
    end
  end
  if pricesAdjusted then saveData(savePath) end
end

local function owned(id)
  return career_modules_business_businessManager and career_modules_business_businessManager.isPurchasedBusiness(SHOP_TYPE, tostring(id)) == true
end

local function warehouseCapacity(state)
  if state.upgrades.warehouse2 then return 50 end
  if state.upgrades.warehouse1 then return 25 end
  return STARTING_WAREHOUSE
end

local function lineCapacity(state)
  if state.upgrades.line3 then return 3 end
  if state.upgrades.line2 then return 2 end
  return 1
end

local function rawCount(state)
  local total = 0
  for _, count in pairs(state.rawStock) do total = total + math.max(0, math.floor(tonumber(count) or 0)) end
  return total
end

local function reservationCount(state)
  local total = 0
  for _, reservation in pairs(state.reservations) do if reservation.status ~= "cancelled" and reservation.status ~= "delivered" then total = total + 1 end end
  return total
end

local function warehousePackages(id, blueprintId)
  local result = {}
  for _, package in ipairs(career_modules_enginePackages.listPackages({ownerType = "business", businessType = SHOP_TYPE, businessId = tostring(id)})) do
    if package.warehouseStock == true and (not blueprintId or tostring(package.blueprintId or package.productRevisionId) == tostring(blueprintId)) then result[#result + 1] = package end
  end
  table.sort(result, function(a, b) return tonumber(a.id) < tonumber(b.id) end)
  return result
end

local function warehouseUsed(id, state)
  return rawCount(state) + reservationCount(state) + #warehousePackages(id)
end

local function findBlueprintBySignature(state, signature)
  for _, blueprint in pairs(state.blueprints) do if tostring(blueprint.recipeSignature) == tostring(signature) then return blueprint end end
end

local function lineDuration(line) return LINE_DURATION_SECONDS[(line.upgrades.speed or 0) + 1] end
local function lineSuccessChance(line) return LINE_SUCCESS_CHANCES[(line.upgrades.quality or 0) + 1] end
local function lineBreakdownChance(line) return LINE_BREAKDOWN_CHANCES[(line.upgrades.maintenance or 0) + 1] end
local function lineMaintenanceDiscount(line) return ({0, 0.15, 0.30, 0.40})[(line.upgrades.maintenance or 0) + 1] end

local function getShopZones()
  if shopZones then return shopZones end
  local sites = gameplay_sites_sitesManager and gameplay_sites_sitesManager.loadSites(SHOP_SITE)
  shopZones = sites and sites.zones or false
  return shopZones
end

local function isInShopZone(vehObj)
  local zones = getShopZones()
  if not vehObj or not zones then return false end
  for _, zone in ipairs(zones.sorted or {}) do
    if zone.name == SHOP_ZONE and zone.containsVehicle and zone:containsVehicle(vehObj, true) then return true end
    if zone.name == SHOP_ZONE and zone.containsPoint2D and zone:containsPoint2D(vehObj:getPosition()) then return true end
  end
  return false
end

local selectedBayInventoryId

local function localizedVehicles()
  local result = {}
  for inventoryId, vehicle in pairs(career_modules_inventory.getVehicles() or {}) do
    local vehId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
    local vehObj = vehId and getObjectByID(vehId)
    if vehObj and vehicle.owned == true and isInShopZone(vehObj) then
      result[#result + 1] = {inventoryId = inventoryId, vehId = vehId, niceName = vehicle.niceName or vehicle.model, model = vehicle.model}
    end
  end
  table.sort(result, function(a, b) return tostring(a.inventoryId) < tostring(b.inventoryId) end)
  return result
end

local function localizedVehicle()
  local vehicles = localizedVehicles()
  local current = career_modules_inventory.getCurrentVehicle and career_modules_inventory.getCurrentVehicle()
  local fallback
  for _, entry in ipairs(vehicles) do
    if selectedBayInventoryId and tostring(entry.inventoryId) == tostring(selectedBayInventoryId) then return entry end
    if not fallback and current and tostring(entry.inventoryId) == tostring(current) then fallback = entry end
  end
  return fallback or vehicles[1]
end

local function selectBayVehicle(_, inventoryId)
  for _, entry in ipairs(localizedVehicles()) do
    if tostring(entry.inventoryId) == tostring(inventoryId) then
      selectedBayInventoryId = entry.inventoryId
      return {success = true, message = "Selected " .. tostring(entry.niceName) .. " for work bay service."}
    end
  end
  return {success = false, message = "That vehicle is not inside the Engine Works service zone."}
end

local function legacyRecipeCertificationData(recipe)
  if type(recipe) ~= "table" or not recipe.vehicleModel or not recipe.tree then return nil, "Recipe metadata is incomplete." end
  local vehicleDir = string.format("/vehicles/%s/", recipe.vehicleModel)
  if not FS:directoryExists(vehicleDir) then return nil, "The source vehicle model is unavailable." end
  local ioCtx = jbeamIO.startLoading({vehicleDir, "/vehicles/common/"})
  if not ioCtx then return nil, "The engine JBeam could not be loaded." end
  local rating, legacyRating, declaredMaxRpm, limiterRpm
  local bestSamples, bestPeakTorque, bestPeakHp = {}, 0, 0
  local function readCurve(curve)
    if type(curve) == "string" then
      local includePath = curve:match("include%s*%(%s*['\"]([^'\"]+)['\"]%s*%)")
      if not includePath then return end
      if includePath:sub(1, 1) ~= "/" then includePath = "/" .. includePath end
      local csv = readFile(includePath)
      if type(csv) ~= "string" or csv == "" then return end
      local resolved = {}
      for line in csv:gmatch("[^\r\n]+") do
        local first, second = line:match("^%s*([^,]+)%s*,%s*([^,]+)")
        if first and second then
          first = first:gsub('[%s\"]', '')
          second = second:gsub('[%s\"]', '')
          local rpm, torque = tonumber(first), tonumber(second)
          if rpm and torque then resolved[#resolved + 1] = {rpm = rpm, torque = torque} end
        end
      end
      curve = resolved
    end
    if type(curve) ~= "table" then return end
    local samples, peakTorque, peakHp = {}, 0, 0
    for key, value in pairs(curve) do
      local rpm, torque
      if type(value) == "table" then rpm, torque = tonumber(value.rpm or value[1]), tonumber(value.torque or value[2]) else rpm, torque = tonumber(key), tonumber(value) end
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
  local seen = {}
  local function scan(value)
    if type(value) ~= "table" or seen[value] then return end
    seen[value] = true
    for key, child in pairs(value) do
      local lower = string.lower(tostring(key))
      if lower == "maxtorquerating" then rating = tonumber(child) or rating
      elseif lower == "maxovertorquedamage" then legacyRating = tonumber(child) or legacyRating
      elseif lower == "maxrpm" then declaredMaxRpm = tonumber(child) or declaredMaxRpm
      elseif lower == "revlimiterrpm" or lower == "limiterrpm" then limiterRpm = tonumber(child) or limiterRpm
      elseif lower == "maxav" and not limiterRpm then limiterRpm = tonumber(child) and tonumber(child) * 9.549296596 or nil
      elseif lower == "torque" then readCurve(child) end
      if type(child) == "table" then scan(child) end
    end
  end
  local function visit(node)
    local data = jbeamIO.getPart(ioCtx, node.name)
    if data then scan(data) end
    for _, child in pairs(node.children or {}) do visit(child) end
  end
  visit(recipe.tree)
  local usedLegacy = not rating and legacyRating ~= nil
  rating = rating or legacyRating
  if not rating or rating <= 0 then return nil, "This engine has no declared torque rating and is not certifiable." end
  if #bestSamples == 0 then return nil, "This engine has no readable torque curve and is not certifiable." end
  limiterRpm = limiterRpm or declaredMaxRpm or bestSamples[#bestSamples].rpm
  local failed = false
  for _, sample in ipairs(bestSamples) do if sample.torque > rating + 0.001 then failed = true break end end
  if declaredMaxRpm and limiterRpm and limiterRpm > declaredMaxRpm + 1 then failed = true end
  return {result = failed and "failed" or "passed", peakHorsepower = bestPeakHp, peakTorque = bestPeakTorque,
    rating = rating, limiterRpm = limiterRpm, declaredMaxRpm = declaredMaxRpm, usedLegacyRating = usedLegacy, samples = bestSamples}
end

local function recipeCertificationData(recipe)
  if career_modules_engineCertification and career_modules_engineCertification.analyzeRecipe then
    return career_modules_engineCertification.analyzeRecipe(recipe)
  end
  return legacyRecipeCertificationData(recipe)
end

local function completeCertification(id, state, packageId, job)
  if job.completed then return end
  job.completed, job.status = true, job.result
  job.completedAt = nowWorldMinutes()
  local package = career_modules_enginePackages.getPackage(packageId)
  if package then
    career_modules_enginePackages.setEngineShopCertification(packageId, {status = job.result, businessId = tostring(id),
      recipeSignature = job.recipeSignature, completedAt = job.completedAt, fee = job.fee, peakHorsepower = job.peakHorsepower,
      peakTorque = job.peakTorque, rating = job.rating, limiterRpm = job.limiterRpm, samples = job.samples})
  end
  if job.result == "passed" then
    local blueprint = findBlueprintBySignature(state, job.recipeSignature)
    if not blueprint then
      local blueprintId = tostring(state.nextBlueprintId); state.nextBlueprintId = state.nextBlueprintId + 1
      blueprint = {id = blueprintId, name = job.packageName, recipe = deepcopy(job.recipe), recipeSignature = job.recipeSignature,
        freshValue = job.freshValue, certification = {peakHorsepower = job.peakHorsepower, peakTorque = job.peakTorque,
          rating = job.rating, limiterRpm = job.limiterRpm, samples = deepcopy(job.samples)}, listed = false,
        price = math.max(1, math.floor(job.freshValue * FRESH_VALUE_MARKET_MULTIPLIER + 0.5)), awareness = 0, createdAt = job.completedAt,
        sourcePackageId = tostring(packageId)}
      state.blueprints[blueprintId] = blueprint
    end
    job.blueprintId = blueprint.id
    notify("success", "Engine certification passed", string.format("%s is certified at %.0f hp and %.0f Nm.", job.packageName, job.peakHorsepower, job.peakTorque))
  else
    notify("error", "Engine certification failed", job.packageName .. " exceeded its declared torque or RPM limit. The stored package was returned intact with a Failed tag.")
  end
  saveData()
end

local function processCertifications(id, state, elapsedSeconds)
  elapsedSeconds = math.max(0, tonumber(elapsedSeconds) or 0)
  for packageId, job in pairs(state.certificationJobs) do
    if not job.completed then
      job.durationSeconds = CERTIFICATION_DURATION_SECONDS
      job.progressSeconds = math.min(job.durationSeconds, math.max(0, tonumber(job.progressSeconds) or 0) + elapsedSeconds)
      if job.progressSeconds >= job.durationSeconds then completeCertification(id, state, packageId, job) end
    end
  end
end

local function startCertification(id, packageId)
  local state = ensureState(id)
  local package = career_modules_enginePackages.getPackage(packageId)
  if not package or package.ownerType == "business" then return {success = false, message = "Choose a personal Engine Package."} end
  local status = career_modules_enginePackages.getPackageStatus(package)
  if status ~= "stored" then return {success = false, message = "Certification requires the Engine Package to be stored, not installed in a car."} end
  local existing = state.certificationJobs[tostring(packageId)]
  if existing and not existing.completed then return {success = false, message = "This Engine Package is already in certification."} end
  local freshValue, recipe = career_modules_enginePackages.getFreshPackageValue(package)
  if not freshValue then return {success = false, message = recipe or "The package value could not be calculated."} end
  local signature = recipe.signature or career_modules_enginePackages.computeRecipeSignature(recipe)
  local data, certError = recipeCertificationData(recipe)
  if not data then return {success = false, message = certError} end
  local fee = math.max(1, math.floor(freshValue * 0.05 + 0.5))
  if not pay(id, fee, "Engine certification", "10 active-minute stored-package certification") then return {success = false, message = "The Engine Works account cannot cover the certification fee."} end
  local absolute = nowWorldMinutes()
  local job = {packageId = tostring(packageId), packageName = package.name, recipe = recipe, recipeSignature = signature,
    freshValue = freshValue, fee = fee, submittedAt = absolute, durationSeconds = CERTIFICATION_DURATION_SECONDS,
    progressSeconds = 0, status = "pending", result = data.result,
    peakHorsepower = data.peakHorsepower, peakTorque = data.peakTorque, rating = data.rating, limiterRpm = data.limiterRpm, samples = data.samples}
  state.certificationJobs[tostring(packageId)] = job
  career_modules_enginePackages.setEngineShopCertification(packageId, {status = "pending", businessId = tostring(id),
    recipeSignature = signature, submittedAt = absolute, durationSeconds = CERTIFICATION_DURATION_SECONDS, progressSeconds = 0, fee = fee})
  saveData()
  return {success = true, message = string.format("%s entered certification for $%d. It will finish in 10 active minutes.", package.name, fee)}
end

local function packageReferenceGuard(package)
  if package.ownerType == "business" then return true end
  for _, state in pairs(states) do
    local job = state.certificationJobs[tostring(package.id)]
    if job and not job.completed then return false, "This Engine Package is locked during certification." end
  end
  return true
end

local function assignLineBlueprint(id, lineId, blueprintId)
  local state = ensureState(id)
  lineId = tonumber(lineId)
  local line, blueprint = state.lines[lineId], state.blueprints[tostring(blueprintId)]
  if not line or lineId > lineCapacity(state) then return {success = false, message = "That production line is locked."} end
  if not blueprint then return {success = false, message = "Select a certified engine blueprint."} end
  if line.attemptStarted and tostring(line.blueprintId) ~= tostring(blueprintId) then
    return {success = false, message = "Stop after the current attempt before changing this line's blueprint."}
  end
  line.blueprintId = tostring(blueprintId)
  line.progressSeconds = 0
  line.attemptStarted = false
  saveData()
  return {success = true, message = blueprint.name .. " assigned to Production Line " .. tostring(lineId) .. "."}
end

local function setLineRunning(id, lineId, running)
  local state = ensureState(id)
  lineId = tonumber(lineId)
  local line = state.lines[lineId]
  if not line or lineId > lineCapacity(state) then return {success = false, message = "That production line is locked."} end
  if running and not line.blueprintId then return {success = false, message = "Choose a certified engine blueprint first."} end
  if running and line.broken then return {success = false, message = "Overhaul this line before restarting it."} end
  line.running = running == true
  saveData()
  return {success = true, message = line.running and "Production line started." or "Production line stopped with progress preserved."}
end

local function purchaseLineUpgrade(id, lineId, upgradeKind)
  local state = ensureState(id)
  lineId = tonumber(lineId)
  local line, definition = state.lines[lineId], lineUpgradeDefs[tostring(upgradeKind)]
  if not line or lineId > lineCapacity(state) or not definition then return {success = false, message = "Line upgrade is unavailable."} end
  local currentLevel = math.max(0, math.min(3, tonumber(line.upgrades[upgradeKind]) or 0))
  if currentLevel >= 3 then return {success = false, message = "This line upgrade is already at Level 3."} end
  local cost = indexed(definition.costs[currentLevel + 1])
  if not pay(id, cost, definition.name, "Production Line " .. tostring(lineId) .. " upgrade") then
    return {success = false, message = "The Engine Works account cannot fund this upgrade."}
  end
  line.upgrades[upgradeKind] = currentLevel + 1
  saveData()
  return {success = true, message = definition.name .. " upgraded to Level " .. tostring(currentLevel + 1) .. "."}
end

local function overhaulLine(id, lineId)
  local state = ensureState(id)
  lineId = tonumber(lineId)
  local line = state.lines[lineId]
  if not line or not line.broken then return {success = false, message = "This line does not need an overhaul."} end
  local baseCost = indexed(LINE_OVERHAUL_BASES[lineId] or LINE_OVERHAUL_BASES[1])
  local cost = math.floor(baseCost * (1 - lineMaintenanceDiscount(line)) + 0.5)
  if not pay(id, cost, "Production line overhaul", "Restore Production Line " .. tostring(lineId)) then
    return {success = false, message = "The Engine Works account cannot fund the overhaul."}
  end
  line.broken = false
  line.overhaulCostSinceLastAttempt = (line.overhaulCostSinceLastAttempt or 0) + cost
  saveData()
  return {success = true, message = "Production Line " .. tostring(lineId) .. " was overhauled for $" .. tostring(cost) .. "."}
end

local function createFinishedPackage(id, state, blueprint)
  if warehouseUsed(id, state) > warehouseCapacity(state) then return nil, "Shared storage is full." end
  local package, err = career_modules_enginePackages.cloneFreshBusinessPackageFromRecipe(blueprint.recipe, blueprint.name,
    SHOP_TYPE, tostring(id), {blueprintId = tostring(blueprint.id), productRevisionId = tostring(blueprint.id), warehouseStock = true,
      recipeSignature = blueprint.recipeSignature, manufacturedAt = nowWorldMinutes(),
      manufacturedYear = career_modules_enginePackages.getCurrentManufacturingYear()})
  if package then state.manufacturedPackageIds[tostring(package.id)] = true end
  return package, err
end

local function processAttempt(id, state, line, forcedSuccess, forcedBreakdown)
  local blueprintId = tostring(line.blueprintId or "")
  local blueprint = state.blueprints[blueprintId]
  if not blueprint or (state.rawStock[blueprintId] or 0) <= 0 then
    line.attemptStarted = false
    line.progressSeconds = 0
    return false
  end
  state.rawStock[blueprintId] = state.rawStock[blueprintId] - 1
  local success = forcedSuccess ~= nil and forcedSuccess == true or nil
  if forcedSuccess == nil then success = math.random() < lineSuccessChance(line) end
  local package, packageError
  if success then
    package, packageError = createFinishedPackage(id, state, blueprint)
    if not package then success = false end
  end
  local cost = (blueprint.freshValue or 0) + (line.overhaulCostSinceLastAttempt or 0)
  line.attempts[#line.attempts + 1] = {at = nowWorldMinutes(), cost = cost, success = success, packageId = package and package.id, error = packageError}
  while #line.attempts > 20 do table.remove(line.attempts, 1) end
  line.overhaulCostSinceLastAttempt = 0
  line.attemptStarted = false
  local breakdown = forcedBreakdown ~= nil and forcedBreakdown == true or nil
  if forcedBreakdown == nil then breakdown = math.random() < lineBreakdownChance(line) end
  if breakdown then line.broken, line.running = true, false end
  return true
end

local function processProduction(id, state, elapsedSeconds)
  for lineId, line in ipairs(state.lines) do
    if lineId <= lineCapacity(state) and line.running and not line.broken and line.blueprintId then
      local blueprintId = tostring(line.blueprintId)
      if (state.rawStock[blueprintId] or 0) > 0 then
        line.attemptStarted = true
        line.progressSeconds = (line.progressSeconds or 0) + elapsedSeconds
        local duration = lineDuration(line)
        while line.running and not line.broken and line.progressSeconds >= duration and (state.rawStock[blueprintId] or 0) > 0 do
          line.progressSeconds = line.progressSeconds - duration
          processAttempt(id, state, line)
        end
      end
    end
  end
end

local function landedCost(blueprint, lines)
  local total, successes = 0, 0
  local rows = {}
  for _, line in ipairs(lines or {}) do
    if tostring(line.blueprintId or "") == tostring(blueprint.id) then
      for _, attempt in ipairs(line.attempts or {}) do rows[#rows + 1] = attempt end
    end
  end
  table.sort(rows, function(a, b) return (a.at or 0) > (b.at or 0) end)
  for index = 1, math.min(20, #rows) do
    total = total + (rows[index].cost or 0)
    if rows[index].success then successes = successes + 1 end
  end
  return successes > 0 and total / successes or (blueprint.freshValue or 1)
end

local function supportedMarketPrice(blueprint, cost, state)
  local freshValue = math.max(1, tonumber(blueprint and blueprint.freshValue) or 1)
  cost = math.max(1, tonumber(cost) or freshValue)
  local marketAnchor = freshValue * FRESH_VALUE_MARKET_MULTIPLIER
  local costFloor = cost * LANDED_COST_FLOOR_MULTIPLIER
  local brandPremium = math.min(0.10, math.max(0, tonumber(state and state.brandPopularity) or 0) / 1000)
  local awarenessPremium = math.min(0.05, math.max(0, tonumber(blueprint and blueprint.awareness) or 0) / 2000)
  return math.max(marketAnchor, costFloor) * (1 + brandPremium + awarenessPremium)
end

local function salePriceLimit(blueprint, cost, state)
  local supportedPrice = math.max(1, supportedMarketPrice(blueprint, cost, state))
  local brand = math.max(0, math.min(100, tonumber(state and state.brandPopularity) or 0))
  local awareness = math.max(0, math.min(100, tonumber(blueprint and blueprint.awareness) or 0))
  local maturity = (brand + awareness) / 200
  local supportedSeconds = ENGINE_SALE_MAX_SECONDS - (ENGINE_SALE_MAX_SECONDS - ENGINE_SALE_MIN_SECONDS) * maturity
  -- A premium can only use the timer headroom left before the fifteen-minute limit.
  local maxRatio = (ENGINE_SALE_MAX_SECONDS / supportedSeconds + 1) / 2
  return math.max(1, math.floor(supportedPrice * maxRatio + 0.5)), supportedPrice, supportedSeconds
end

normalizeBlueprintPrice = function(blueprint, state)
  local limit, supportedPrice = salePriceLimit(blueprint, landedCost(blueprint, state.lines), state)
  local price = tonumber(blueprint.price) or supportedPrice
  if price ~= price or price == math.huge or price == -math.huge then price = supportedPrice end
  price = math.max(1, math.min(limit, math.floor(price)))
  local changed = blueprint.price ~= price
  blueprint.price = price
  return changed
end

local function saleCycleSeconds(blueprint, cost, state)
  local limit, supportedPrice, supportedSeconds = salePriceLimit(blueprint, cost, state)
  local priceRatio = math.max(0.01, math.min(tonumber(blueprint and blueprint.price) or supportedPrice, limit) / supportedPrice)
  local multiplier
  if priceRatio <= 1 then
    multiplier = math.max(0.5, priceRatio)
  else
    multiplier = 1 + (priceRatio - 1) * 2
  end
  local seconds = math.max(ENGINE_SALE_MIN_SECONDS, math.min(ENGINE_SALE_MAX_SECONDS, supportedSeconds * multiplier))
  return math.floor(seconds + 0.5), supportedPrice
end

local function destroyWarehousePackage(id, package)
  if not package or package.ownerType ~= "business" or tostring(package.businessId) ~= tostring(id) or package.warehouseStock ~= true then return false end
  local partIds = career_modules_enginePackages.getPartIdsFromPackageTree(package.tree)
  local removed = career_modules_enginePackages.removeBusinessPackage(package.id)
  if not removed then return false end
  for _, partId in ipairs(partIds) do career_modules_business_businessPartInventory.removePart(partId, tostring(id)) end
  return true
end

local function resetSalesCycle(state)
  state.salesCurrentBlueprintId = nil
  state.salesCycleProgressSeconds = 0
  state.salesCycleDurationSeconds = nil
  state.salesCycleMigrationRatio = nil
end

local function saleCandidates(id, state)
  local rows = {}
  for _, blueprint in pairs(state.blueprints or {}) do
    if blueprint.listed and #warehousePackages(id, blueprint.id) > 0 then rows[#rows + 1] = blueprint end
  end
  table.sort(rows, function(a, b)
    local aId, bId = tonumber(a.id), tonumber(b.id)
    if aId and bId then return aId < bId end
    return tostring(a.id) < tostring(b.id)
  end)
  return rows
end

local function ensureSalesCycle(id, state)
  local current = state.salesCurrentBlueprintId and state.blueprints[tostring(state.salesCurrentBlueprintId)]
  if current and current.listed and #warehousePackages(id, current.id) > 0 then
    if not state.salesCycleDurationSeconds or state.salesCycleDurationSeconds <= 0 then
      state.salesCycleDurationSeconds = saleCycleSeconds(current, landedCost(current, state.lines), state)
      if state.salesCycleMigrationRatio then
        state.salesCycleProgressSeconds = state.salesCycleDurationSeconds * state.salesCycleMigrationRatio
        state.salesCycleMigrationRatio = nil
      end
    end
    state.salesCycleProgressSeconds = math.min(state.salesCycleProgressSeconds or 0, state.salesCycleDurationSeconds)
    return current
  end

  resetSalesCycle(state)
  local candidates = saleCandidates(id, state)
  if #candidates == 0 then return nil end
  local selected = candidates[1]
  if state.salesCursorBlueprintId then
    for index, candidate in ipairs(candidates) do
      if tostring(candidate.id) == tostring(state.salesCursorBlueprintId) then
        selected = candidates[index % #candidates + 1]
        break
      end
    end
  end
  state.salesCurrentBlueprintId = tostring(selected.id)
  state.salesCycleDurationSeconds = saleCycleSeconds(selected, landedCost(selected, state.lines), state)
  return selected
end

local function completeCurrentSale(id, state, blueprint)
  local available = warehousePackages(id, blueprint.id)
  local package = available[1]
  if not package or not destroyWarehousePackage(id, package) then
    resetSalesCycle(state)
    return false
  end
  local cost = landedCost(blueprint, state.lines)
  local duration = state.salesCycleDurationSeconds or saleCycleSeconds(blueprint, cost, state)
  local supportedPrice = supportedMarketPrice(blueprint, cost, state)
  local price = math.max(1, math.min(salePriceLimit(blueprint, cost, state), math.floor(tonumber(blueprint.price) or supportedPrice)))
  reward(id, price, blueprint.name .. " sale", "One physical engine sold from the timed sales queue")
  state.brandPopularity = math.min(100, state.brandPopularity + 1)
  blueprint.awareness = math.max(0, (tonumber(blueprint.awareness) or 0) - 1)
  local _, day, minute = nowWorldMinutes()
  state.salesHistory[#state.salesHistory + 1] = {day = day, minuteOfDay = minute, blueprintId = blueprint.id,
    name = blueprint.name, sold = 1, price = price, landedCost = cost,
    supportedPrice = math.floor(supportedPrice + 0.5), saleCycleSeconds = duration}
  while #state.salesHistory > 120 do table.remove(state.salesHistory, 1) end
  state.salesCursorBlueprintId = tostring(blueprint.id)
  resetSalesCycle(state)
  return true
end

local function advanceSales(id, state, elapsedSeconds)
  local remainingElapsed = math.max(0, tonumber(elapsedSeconds) or 0)
  local completed = 0
  while remainingElapsed > 0 and completed < 1000 do
    local blueprint = ensureSalesCycle(id, state)
    if not blueprint then break end
    local duration = math.max(1, tonumber(state.salesCycleDurationSeconds) or ENGINE_SALE_MAX_SECONDS)
    local remaining = math.max(0, duration - (state.salesCycleProgressSeconds or 0))
    if remainingElapsed < remaining then
      state.salesCycleProgressSeconds = (state.salesCycleProgressSeconds or 0) + remainingElapsed
      remainingElapsed = 0
    else
      remainingElapsed = remainingElapsed - remaining
      state.salesCycleProgressSeconds = duration
      if not completeCurrentSale(id, state, blueprint) then break end
      completed = completed + 1
    end
  end
  ensureSalesCycle(id, state)
end

local function setBlueprintListed(id, blueprintId, listed)
  local state = ensureState(id)
  local blueprint = state.blueprints[tostring(blueprintId)]
  if not blueprint then return {success = false, message = "Certified engine blueprint not found."} end
  normalizeBlueprintPrice(blueprint, state)
  blueprint.listed = listed == true
  if tostring(state.salesCurrentBlueprintId or "") == tostring(blueprintId) then resetSalesCycle(state) end
  ensureSalesCycle(id, state)
  saveData()
  return {success = true, message = blueprint.listed and "Engine added to the timed sales queue." or "Engine removed from the sales queue."}
end

local function setBlueprintPrice(id, blueprintId, price)
  local state = ensureState(id)
  local blueprint = state.blueprints[tostring(blueprintId)]
  if not blueprint then return {success = false, message = "Certified engine blueprint not found."} end
  local priceLimit = salePriceLimit(blueprint, landedCost(blueprint, state.lines), state)
  price = tonumber(price)
  if not price or price ~= price or price < 1 then return {success = false, message = "Enter a positive sale price."} end
  if price > priceLimit then return {success = false, message = string.format("The current maximum for this engine is $%d.", priceLimit)} end
  price = math.floor(price)
  local changed = blueprint.price ~= price
  blueprint.price = price
  if changed and tostring(state.salesCurrentBlueprintId or "") == tostring(blueprintId) then resetSalesCycle(state) end
  ensureSalesCycle(id, state)
  saveData()
  return {success = true, message = changed and "Sale price updated; this engine's countdown restarted." or "Sale price unchanged."}
end

local function purchaseUpgrade(id, upgradeId)
  local state = ensureState(id)
  local definition = capacityUpgrades[tostring(upgradeId)]
  if not definition or state.upgrades[upgradeId] then return {success = false, message = "Upgrade is unavailable."} end
  if definition.requires and not state.upgrades[definition.requires] then return {success = false, message = "Purchase the required earlier upgrade first."} end
  local cost = indexed(definition.cost)
  if not pay(id, cost, definition.name, "Engine Works capacity upgrade") then return {success = false, message = "The Engine Works account cannot fund this upgrade."} end
  state.upgrades[upgradeId] = true
  saveData()
  return {success = true, message = definition.name .. " purchased."}
end

local function orderRawMaterials(id, blueprintId, quantity)
  local state = ensureState(id)
  local blueprint = state.blueprints[tostring(blueprintId)]
  quantity = math.max(1, math.floor(tonumber(quantity) or 1))
  if not blueprint then return {success = false, message = "Choose a certified engine blueprint."} end
  if warehouseUsed(id, state) + quantity > warehouseCapacity(state) then return {success = false, message = "The shared warehouse lacks enough unreserved spots."} end
  local cost = math.floor((blueprint.freshValue or 1) * quantity)
  if not pay(id, cost, "Engine raw materials", tostring(quantity) .. " prepaid 128-slot production load(s)") then
    return {success = false, message = "The Engine Works account cannot fund this order."}
  end
  for _ = 1, quantity do
    local reservationId = tostring(state.nextReservationId); state.nextReservationId = state.nextReservationId + 1
    state.reservations[reservationId] = {id = reservationId, businessId = tostring(id), blueprintId = tostring(blueprintId),
      revisionId = tostring(blueprintId), quantity = 1, status = "available", supplierFacilityId = "spearleafLogistics",
      supplierParkingSpotName = "spearleafLogistics_parkingA", paidCost = blueprint.freshValue}
  end
  saveData()
  if career_modules_delivery_general and career_modules_delivery_general.requestDeliveryPoiRefresh then
    career_modules_delivery_general.requestDeliveryPoiRefresh(true)
  end
  return {success = true, message = string.format("Ordered %d paid load%s. Park at Spearleaf Warehouse Parking and choose Pickup engine materials; each needs 128 cargo slots.", quantity, quantity == 1 and "" or "s")}
end

local function junkWarehousePackage(id, packageId)
  local package = career_modules_enginePackages.getPackage(packageId)
  if not destroyWarehousePackage(id, package) then return {success = false, message = "That physical warehouse engine could not be junked."} end
  saveData()
  return {success = true, message = "The selected physical engine was permanently junked. One storage spot is now free."}
end

local function installWarehousePackage(id, packageId)
  local vehicle = localizedVehicle()
  if not vehicle then return {success = false, message = "Spawn a personal vehicle inside the marked Engine Works garage zone first."} end
  local package = career_modules_enginePackages.getPackage(packageId)
  if not package or package.ownerType ~= "business" or tostring(package.businessId) ~= tostring(id) or package.warehouseStock ~= true then
    return {success = false, message = "Physical warehouse engine not found."}
  end
  local personal, transferError = career_modules_enginePackages.transferBusinessPackageToPersonal(packageId)
  if not personal then return {success = false, message = transferError or "The warehouse engine could not be moved into personal ownership."} end
  local started, installError = career_modules_enginePackages.installPackageIntoVehicle(personal.id, vehicle.inventoryId)
  if not started then return {success = false, message = installError or "The engine installation could not start."} end
  saveData()
  return {success = true, message = "The physical engine left business storage. Installation started; the outgoing engine will be captured into My Engine Packages."}
end

local function openEnginePackages(id)
  local vehicle = localizedVehicle()
  local opened = career_modules_enginePackages.openMenu(vehicle and vehicle.inventoryId or nil, nil,
    {businessType = SHOP_TYPE, businessId = tostring(id)})
  if not opened then return {success = false, message = "The Engine Packages screen could not be opened."} end
  return {success = true, message = vehicle and
    "Opened the garage-style Engine Packages manager for the vehicle in the shop." or
    "Opened the garage-style Engine Packages manager in browse-only mode."}
end

local function openParts(id)
  local vehicle = localizedVehicle()
  if not vehicle then return {success = false, message = "Spawn a personal vehicle inside the marked Engine Works garage zone first."} end
  career_modules_partShopping.startShopping(vehicle.inventoryId, nil, {
    name = "business-computer",
    params = {businessType = SHOP_TYPE, businessId = tostring(id)}
  })
  return {success = true, message = "Opened Part Customization for the localized vehicle."}
end

local function openMyParts(id)
  career_modules_partInventory.openMenu(nil, {
    name = "business-computer",
    params = {businessType = SHOP_TYPE, businessId = tostring(id)}
  })
  return {success = true, message = "Opened My Parts."}
end

local function openTuning(id)
  local vehicle = localizedVehicle()
  if not vehicle then return {success = false, message = "Spawn a personal vehicle inside the marked Engine Works garage zone first."} end
  career_modules_tuning.start(vehicle.inventoryId, nil, {
    name = "business-computer",
    params = {businessType = SHOP_TYPE, businessId = tostring(id)}
  })
  return {success = true, message = "Opened Tuning for the localized vehicle."}
end

local function openRepair(id)
  local vehicle = localizedVehicle()
  if not vehicle then return {success = false, message = "Spawn a personal vehicle inside the marked Engine Works garage zone first."} end
  career_modules_insurance_repairScreen.openRepairMenu(career_modules_inventory.getVehicles()[vehicle.inventoryId], nil)
  return {success = true, message = "Opened Repair for the localized vehicle."}
end

local function availableRawReservations()
  local result = {}
  for businessId, state in pairs(states) do
    if owned(businessId) then
      for _, reservation in pairs(state.reservations) do
        if reservation.status == "available" then
          local row = deepcopy(reservation); row.businessId = businessId; result[#result + 1] = row
        end
      end
    end
  end
  table.sort(result, function(a, b) return tostring(a.id) < tostring(b.id) end)
  return result
end

local function cargoSource()
  local generator = career_modules_delivery_generator
  local facility = generator and generator.getFacilityById("spearleafLogistics")
  local access = facility and facility.accessPointsByName and facility.accessPointsByName.spearleafLogistics_parkingA
  return access and {type = "facilityParkingspot", facId = facility.id, psPath = access.psPath} or nil
end

local function cargoDestinations()
  local result, generator = {}, career_modules_delivery_generator
  local facility = generator and generator.getFacilityById("wcusaEngineWorksReceiving")
  local access = facility and facility.accessPointsByName and facility.accessPointsByName.engineWorksReceiving
  if access then result[1] = {type = "facilityParkingspot", facId = facility.id, psPath = access.psPath} end
  return result
end


-- Preview image of a spawned vehicle (its current config), for the pickup UI.
local function vehicleThumb(vehId)
  if not vehId then return nil end
  -- Player-owned vehicles carry their own thumbnail (their real parts/paint); the stock config
  -- preview is only a fallback for vehicles outside the inventory.
  local inv = career_modules_inventory
  if inv and inv.getInventoryIdFromVehicleId and inv.getVehicleThumbnail then
    local invId = inv.getInventoryIdFromVehicleId(vehId)
    if invId then
      -- no captured picture yet: render one now and push the screen data again when it lands
      if inv.ensureVehicleThumbnail then
        inv.ensureVehicleThumbnail(invId, function() if M.requestSupplyPickupData then M.requestSupplyPickupData() end end)
      end
      local ok, thumb = pcall(inv.getVehicleThumbnail, invId)
      if ok and type(thumb) == "string" and thumb ~= "" then return thumb end
    end
  end
  if not core_vehicles or not core_vehicles.getVehicleDetails then return nil end
  local ok, d = pcall(core_vehicles.getVehicleDetails, vehId)
  if not ok or type(d) ~= "table" then return nil end
  local cfg = d.configs
  return type(cfg) == "table" and cfg.preview or nil
end
local function supplierFacilityInfo()
  local gen = career_modules_delivery_generator
  local fac = gen and gen.getFacilityById and gen.getFacilityById("spearleafLogistics")
  return fac and fac.name or "Spearleaf Marine Logistics", fac and fac.preview or nil
end

local function formatCargoEquipment(containers)
  local equipment, capacity = {}, 0
  for _, container in ipairs(containers or {}) do
    local supports = container.cargoTypesLookup and container.cargoTypesLookup.parcel
    local free = math.max(0, tonumber(container.freeCargoSlots) or 0)
    local pallets = supports and math.floor(free / 128) or 0
    capacity = capacity + pallets
    equipment[#equipment + 1] = {vehId = container.vehId, containerId = container.containerId,
      vehicleName = container.vehName or "Vehicle", containerName = container.name or "Cargo container",
      thumbnail = vehicleThumb(container.vehId),
      used = container.usedCargoSlots or 0, capacity = container.totalCargoSlots or 0, free = free,
      pallets = pallets, eligible = pallets > 0,
      reason = supports and (pallets > 0 and nil or "Less than 128 slots free") or "Parcel freight is not supported"}
  end
  return equipment, capacity
end

local function supplyPickupData(containers)
  local equipment, vehicleCapacity = formatCargoEquipment(containers)
  local available = #availableRawReservations()
  local facilityName, facilityPreview = supplierFacilityInfo()
  return {available = available > 0, reason = available == 0 and "Order raw material at the Engine Works first." or nil,
    facilityName = facilityName, facilityPreview = facilityPreview,
    supplyName = "Engine Production Materials", slotsPerPallet = 128, paidAtSupplier = available,
    vehicleCapacity = vehicleCapacity, maximumLoad = math.min(available, vehicleCapacity), equipment = equipment,
    loading = supplyLoadInProgress}
end

local function requestSupplyPickupData()
  if not supplyPickupOpen or not career_modules_delivery_general then return false end
  career_modules_delivery_general.getNearbyVehicleCargoContainers(function(containers)
    if supplyPickupOpen and guihooks then guihooks.trigger("engineShopSupplyPickupData", supplyPickupData(containers)) end
  end)
  return true
end

local function hasPaidSupplyAt(facId, psPath)
  local source = cargoSource()
  if not source or source.facId ~= facId or source.psPath ~= psPath then return false end
  return #availableRawReservations() > 0
end

local function getPaidSupplyPickupLocations()
  if #availableRawReservations() <= 0 then return {} end
  local source = cargoSource()
  return source and {source} or {}
end

local function getSupplyOfferCard(facId, psPath, containers)
  local source = cargoSource()
  if not source or source.facId ~= facId or source.psPath ~= psPath or #availableRawReservations() == 0 then return nil end
  local data = supplyPickupData(containers)
  local enabled = data.maximumLoad > 0
  local reason = data.paidAtSupplier <= 0 and "Order and pay for engine material first." or
    (data.vehicleCapacity <= 0 and "Bring a freight container with at least 128 free parcel slots." or nil)
  local distance = 0
  local destinations = cargoDestinations()
  if destinations[1] and career_modules_delivery_generator.getDistanceBetweenFacilities then
    distance = career_modules_delivery_generator.getDistanceBetweenFacilities(source, destinations[1]) or 0
  end
  return {id = "engineShopPaidMaterials", cardType = "engineShopSupplyOffer", isFacilityCard = true,
    name = "Paid Engine Materials Pickup", type = "parcel", rewardMoney = 0,
    destinationName = "West Coast Engine Works", destinationNameLong = "West Coast Engine Works Receiving",
    distance = distance, slots = 128, enabled = enabled,
    disableReason = not enabled and {type = "noSpace", label = reason or "Engine materials are unavailable."} or nil,
    modifiers = {}, bigMapIds = {}, supplyLimits = data, sourceFacId = facId,
    origin = {facId = facId, psPath = psPath}}
end

local function enterSupplyPickupScreen(facId, psPath)
  local source = cargoSource()
  if not source or source.facId ~= facId or source.psPath ~= psPath or #availableRawReservations() == 0 then return false end
  supplyPickupOpen, supplyLoadInProgress = true, false
  gameplay_markerInteraction.closeViewDetailPrompt(true)
  simTimeAuthority.pause(true)
  guihooks.trigger("ChangeState", {state = "career.engineShopSupplyPickup"})
  return true
end

local function closeSupplyPickupScreen()
  supplyPickupOpen, supplyLoadInProgress = false, false
  simTimeAuthority.pause(false)
  guihooks.trigger("ChangeState", {state = "play"})
  gameplay_markerInteraction.setForceReevaluateOpenPrompt()
end

local function loadSupply(quantity)
  if not supplyPickupOpen or supplyLoadInProgress then return false end
  supplyLoadInProgress = true
  career_modules_delivery_general.getNearbyVehicleCargoContainers(function(containers)
    local limits = supplyPickupData(containers)
    local count = math.min(math.max(0, math.floor(tonumber(quantity) or 0)), limits.maximumLoad)
    if count <= 0 then
      supplyLoadInProgress = false
      guihooks.trigger("engineShopSupplyPickupResult", {success = false, message = "No paid order can be loaded. Bring at least 128 free parcel slots."})
      requestSupplyPickupData()
      return
    end
    local source, destinations = cargoSource(), cargoDestinations()
    if not source or #destinations == 0 then
      supplyLoadInProgress = false
      guihooks.trigger("engineShopSupplyPickupResult", {success = false, message = "The supplier or Engine Works receiving point is unavailable."})
      return
    end
    if not career_modules_delivery_general.isDeliveryModeActive() then career_modules_delivery_general.startDeliveryMode() end
    local eligible = {}
    for _, container in ipairs(containers or {}) do
      local pallets = container.cargoTypesLookup and container.cargoTypesLookup.parcel and math.floor(math.max(0, container.freeCargoSlots or 0) / 128) or 0
      if pallets > 0 then eligible[#eligible + 1] = {container = container, pallets = pallets} end
    end
    local reservations, loaded = availableRawReservations(), 0
    for _, entry in ipairs(eligible) do
      while entry.pallets > 0 and loaded < count do
        local reservation = reservations[loaded + 1]
        local cargo = career_modules_delivery_generator.addEngineShopSupplyCargo(entry.container, reservation, source, destinations)
        if not cargo then break end
        local state = states[tostring(reservation.businessId)]
        local savedReservation = state and state.reservations[tostring(reservation.id)]
        if savedReservation then savedReservation.status, savedReservation.cargoId = "inTransit", cargo.id end
        loaded, entry.pallets = loaded + 1, entry.pallets - 1
      end
    end
    if loaded > 0 then
      career_modules_delivery_parcelManager.applyTransientMoves(source)
      career_modules_delivery_general.requestUpdateContainerWeights()
      if career_modules_delivery_tasklist then career_modules_delivery_tasklist.sendCargoToTasklist() end
      saveData()
      guihooks.trigger("engineShopSupplyPickupResult", {success = true, message = "Loaded " .. tostring(loaded) .. " paid engine material load(s)."})
      closeSupplyPickupScreen()
    else
      supplyLoadInProgress = false
      guihooks.trigger("engineShopSupplyPickupResult", {success = false, message = "No compatible 128-slot cargo space was available."})
      requestSupplyPickupData()
    end
  end)
  return true
end

local function getReservationForCargo(cargo)
  local reservationId = cargo and cargo.data and cargo.data.engineShopSupplyReservationId
  local businessId = cargo and cargo.data and cargo.data.engineShopBusinessId
  local state = businessId and states[tostring(businessId)]
  return state and state.reservations[tostring(reservationId)], state
end

local function canDeliverSupplyCargo(cargo, location)
  local reservation, state = getReservationForCargo(cargo)
  return reservation ~= nil and state ~= nil and location and location.facId == "wcusaEngineWorksReceiving"
end

local function deliverSupplyCargo(cargo, location)
  local reservation, state = getReservationForCargo(cargo)
  if not reservation or not state then return false end
  reservation.status = "delivered"
  state.rawStock[tostring(reservation.blueprintId)] = (state.rawStock[tostring(reservation.blueprintId)] or 0) + 1
  state.reservations[tostring(reservation.id)] = nil
  saveData()
  return true
end

local function returnCargoToSupplier(cargo, forfeited)
  local reservation, state = getReservationForCargo(cargo)
  if not reservation then return false end
  if forfeited then state.reservations[tostring(reservation.id)] = nil else reservation.status, reservation.cargoId = "available", nil end
  if cargo.id then career_modules_delivery_parcelManager.changeCargoLocation(cargo.id, {type = "deleted"}) end
  saveData()
  return true
end

local function onRlsFreeroamRaceResultFinalized(payload)
  payload = payload or {}
  if payload.success == false or payload.completed == false or payload.didNotFinish == true then return end
  local inventoryId = payload.vehicleId and career_modules_inventory.getInventoryIdFromVehicleId and career_modules_inventory.getInventoryIdFromVehicleId(payload.vehicleId)
  if not inventoryId and payload.vehicleId then
    for candidateId, vehId in pairs(career_modules_inventory.getMapInventoryIdToVehId and career_modules_inventory.getMapInventoryIdToVehId() or {}) do
      if tonumber(vehId) == tonumber(payload.vehicleId) then inventoryId = candidateId break end
    end
  end
  if not inventoryId then return end
  local installed
  for _, package in ipairs(career_modules_enginePackages.listPackages({ownerType = "personal"})) do
    if tonumber(package.installedInventoryId) == tonumber(inventoryId) then installed = package break end
  end
  if not installed then return end
  local recipe = career_modules_enginePackages.getRecipeFromPackage(installed)
  if not recipe then return end
  local signature = recipe.signature
  for id, state in pairs(states) do
    if owned(id) then
      local blueprint = findBlueprintBySignature(state, signature)
      if blueprint and blueprint.listed then
        blueprint.awareness = math.min(100, (blueprint.awareness or 0) + 30 * (1 - (blueprint.awareness or 0) / 100))
        saveData()
        notify("success", "Engine promotion complete", string.format("%s awareness increased to %.0f.", blueprint.name, blueprint.awareness))
      end
    end
  end
end

local function clearEngineSlot(config, slotName)
  local function visit(node)
    for name, child in pairs(node and node.children or {}) do
      if name == slotName then child.chosenPartName, child.children, child.emptyPlaceholder = "", {}, true return true end
      if visit(child) then return true end
    end
  end
  return config and config.partsTree and visit(config.partsTree) or false
end

local function migratePromoFleet(id, state)
  if not state.migrationPending then return true end
  local legacyVehicles = career_modules_business_businessInventory.getBusinessVehicles(tostring(id)) or {}
  local vehicleModels = {}
  for _, vehicle in ipairs(legacyVehicles) do
    vehicleModels[tostring(vehicle.vehicleId)] = (vehicle.vehicleConfig and vehicle.vehicleConfig.model_key)
      or vehicle.model_key or vehicle.model
  end
  local allPackages = career_modules_enginePackages.listPackages({ownerType = "business", businessType = SHOP_TYPE, businessId = tostring(id)})
  for _, package in ipairs(allPackages) do
    if not package.warehouseStock then
      career_modules_enginePackages.transferBusinessPackageToPersonal(package.id,
        vehicleModels[tostring(package.businessVehicleId or package.businessVehicleRef or "")])
    end
  end
  local remaining = {}
  for _, vehicle in ipairs(legacyVehicles) do
    local model = (vehicle.vehicleConfig and vehicle.vehicleConfig.model_key) or vehicle.model_key or vehicle.model
    local config = deepcopy(vehicle.config or {})
    if not config.partsTree and vehicle.vehicleConfig and vehicle.vehicleConfig.config then config = deepcopy(vehicle.vehicleConfig.config) end
    if vehicle.enginePackageId then
      local migratedPackage = career_modules_enginePackages.getPackage(vehicle.enginePackageId)
      if migratedPackage then clearEngineSlot(config, migratedPackage.rootSlotName) end
    end
    local spawned
    if model and config then
      local ok, result = pcall(core_vehicles.spawnNewVehicle, model, {config = config, autoEnterVehicle = false,
        pos = vec3(-18, 828, 75), rot = quat(0, 0, 1, 0)})
      if ok then spawned = result end
    end
    if spawned then
      local inventoryId = career_modules_inventory.addVehicle(spawned:getID(), nil, {owned = true, takesNoInventorySpace = true})
      if inventoryId then
        local personal = career_modules_inventory.getVehicles()[inventoryId]
        personal.niceName = vehicle.niceName or personal.niceName
        personal.partConditions = deepcopy(vehicle.partConditions or personal.partConditions)
        personal.mileage = vehicle.mileage or personal.mileage
        career_modules_business_businessInventory.removeBusinessVehicleObject(tostring(id), vehicle.vehicleId)
        career_modules_business_businessInventory.removeVehicle(tostring(id), vehicle.vehicleId)
      else
        spawned:delete()
        remaining[#remaining + 1] = vehicle.vehicleId
      end
    else
      remaining[#remaining + 1] = vehicle.vehicleId
    end
  end
  for blueprintId, count in pairs(state.legacyFinishedToMaterialize or {}) do
    local blueprint = state.blueprints[tostring(blueprintId)]
    count = math.max(0, math.floor(tonumber(count) or 0))
    while blueprint and count > 0 and warehouseUsed(id, state) < warehouseCapacity(state) do
      local package = createFinishedPackage(id, state, blueprint)
      if not package then break end
      count = count - 1
    end
    state.legacyFinishedToMaterialize[blueprintId] = count
  end
  local stockRemaining = false
  for _, count in pairs(state.legacyFinishedToMaterialize or {}) do if tonumber(count) and tonumber(count) > 0 then stockRemaining = true end end
  state.migrationPending = #remaining > 0 or stockRemaining
  if not state.migrationPending then state.legacyFinishedToMaterialize = nil end
  saveData()
  return not state.migrationPending
end

local function packageCard(package, state)
  local status, installedId, missing = career_modules_enginePackages.getPackageStatus(package)
  local freshValue = career_modules_enginePackages.getFreshPackageValue(package)
  local certification = deepcopy(package.engineShopCertification)
  local job = state.certificationJobs[tostring(package.id)]
  if certification and certification.status == "pending" and job and not job.completed then
    certification.durationSeconds = CERTIFICATION_DURATION_SECONDS
    certification.progressSeconds = math.min(CERTIFICATION_DURATION_SECONDS, math.max(0, tonumber(job.progressSeconds) or 0))
    certification.remainingSeconds = math.max(0, certification.durationSeconds - certification.progressSeconds)
  end
  local recipe = career_modules_enginePackages.getRecipeFromPackage(package)
  local blueprint = recipe and findBlueprintBySignature(state, recipe.signature)
  return {id = tostring(package.id), name = package.name, engineName = package.rootEngineNiceName or package.rootEngineName,
    status = status, installedInventoryId = installedId, missingCount = missing, stored = status == "stored",
    freshValue = freshValue or 0, certificationFee = math.floor((freshValue or 0) * 0.05 + 0.5),
    certification = certification, certified = blueprint ~= nil, blueprintId = blueprint and blueprint.id,
    thumbnail = career_modules_enginePackages.getPackageThumbnailPath(package.id),
    dirtyDate = package.thumbnailAt or package.updatedAt or 0}
end

local function reconcileCertifiedPackages(state)
  local changed = false
  for _, package in ipairs(career_modules_enginePackages.listPackages({ownerType = "personal"})) do
    local certification = package.engineShopCertification
    if certification and certification.status == "passed" and certification.recipeSignature and
        not findBlueprintBySignature(state, certification.recipeSignature) then
      local freshValue, recipe = career_modules_enginePackages.getFreshPackageValue(package)
      if freshValue and recipe and tostring(recipe.signature) == tostring(certification.recipeSignature) then
        local blueprintId = tostring(state.nextBlueprintId); state.nextBlueprintId = state.nextBlueprintId + 1
        state.blueprints[blueprintId] = {id = blueprintId, name = package.name, recipe = recipe,
          recipeSignature = recipe.signature, freshValue = freshValue,
          certification = {peakHorsepower = certification.peakHorsepower, peakTorque = certification.peakTorque,
            rating = certification.rating, limiterRpm = certification.limiterRpm, samples = deepcopy(certification.samples or {})},
          listed = false, price = math.max(1, math.floor(freshValue * FRESH_VALUE_MARKET_MULTIPLIER + 0.5)), awareness = 0,
          createdAt = certification.completedAt or os.time(), sourcePackageId = tostring(package.id)}
        changed = true
      end
    end
  end
  if changed then saveData() end
end

local function ensureTabsRegistered()
  career_modules_business_businessTabRegistry.clearTabs(SHOP_TYPE)
  local tabs = {
    {id = "dashboard", label = "Dashboard", section = "ENGINE SHOP"},
    {id = "engines", label = "Engines", section = "ENGINE SHOP"},
    {id = "myParts", label = "My Parts", section = "ENGINE SHOP"},
    {id = "production", label = "Production", section = "ENGINE SHOP"},
    {id = "warehouse", label = "Warehouse", section = "ENGINE SHOP"},
    {id = "sales", label = "Sales", section = "ENGINE SHOP"},
    {id = "upgrades", label = "Upgrades", section = "ENGINE SHOP"},
    {id = "finances", label = "Finances", section = "ENGINE SHOP"},
    {id = "overview", label = "Overview", section = "REFERENCE"},
  }
  for order, tab in ipairs(tabs) do
    career_modules_business_businessTabRegistry.registerTab(SHOP_TYPE, {
      id = tab.id,
      label = tab.label,
      icon = '<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M7 12h10M12 7v10"/>',
      component = "EngineShopTab",
      data = {view = tab.id},
      section = tab.section,
      order = order
    })
  end
end

local function getUIData(id)
  id = tostring(id)
  ensureTabsRegistered()
  local state = ensureState(id)
  local absolute, day, minute = nowWorldMinutes()
  processCertifications(id, state, 0)
  migratePromoFleet(id, state)
  reconcileCertifiedPackages(state)
  local currentSale = ensureSalesCycle(id, state)
  local personalPackages = {}
  for _, package in ipairs(career_modules_enginePackages.listPackages({ownerType = "personal"})) do personalPackages[#personalPackages + 1] = packageCard(package, state) end
  table.sort(personalPackages, function(a, b) return string.lower(a.name or "") < string.lower(b.name or "") end)
  local blueprints = {}
  for _, blueprint in pairs(state.blueprints) do
    local copy = deepcopy(blueprint)
    copy.finishedCount = #warehousePackages(id, blueprint.id)
    copy.rawCount = state.rawStock[tostring(blueprint.id)] or 0
    copy.landedCost = landedCost(blueprint, state.lines)
    copy.marketValue = math.floor((copy.freshValue or 1) * FRESH_VALUE_MARKET_MULTIPLIER + 0.5)
    copy.suggestedPrice = math.floor(supportedMarketPrice(blueprint, copy.landedCost, state) + 0.5)
    copy.maxSalePrice = salePriceLimit(blueprint, copy.landedCost, state)
    local displayPrice = tonumber(copy.price) or copy.suggestedPrice
    if not displayPrice or displayPrice ~= displayPrice or displayPrice == math.huge or displayPrice == -math.huge then
      displayPrice = copy.suggestedPrice
    end
    copy.price = math.max(1, math.min(copy.maxSalePrice, math.floor(displayPrice)))
    copy.estimatedProfit = math.floor(copy.suggestedPrice - copy.landedCost + 0.5)
    copy.saleCycleSeconds = saleCycleSeconds(blueprint, copy.landedCost, state)
    blueprints[#blueprints + 1] = copy
  end
  table.sort(blueprints, function(a, b) return tonumber(a.id) < tonumber(b.id) end)
  local finished = {}
  for _, package in ipairs(warehousePackages(id)) do
    local blueprint = state.blueprints[tostring(package.blueprintId or package.productRevisionId)]
    finished[#finished + 1] = {id = tostring(package.id), name = package.name,
      engineName = package.rootEngineNiceName or package.rootEngineName, blueprintId = package.blueprintId or package.productRevisionId,
      thumbnail = package.thumbnail, manufacturedAt = package.manufacturedAt, recipeSignature = package.recipeSignature,
      compatible = localizedVehicle() ~= nil, blueprintName = blueprint and blueprint.name}
  end
  local upgrades = {}
  for key, definition in pairs(capacityUpgrades) do
    upgrades[#upgrades + 1] = {id = key, name = definition.name, cost = indexed(definition.cost), effect = definition.effect,
      requires = definition.requires, owned = state.upgrades[key] == true}
  end
  table.sort(upgrades, function(a, b) return a.cost < b.cost end)
  local lineUpgrades = {}
  for kind, definition in pairs(lineUpgradeDefs) do
    lineUpgrades[kind] = {id = kind, name = definition.name, costs = {}, descriptions = deepcopy(definition.descriptions)}
    for index, cost in ipairs(definition.costs) do lineUpgrades[kind].costs[index] = indexed(cost) end
  end
  local account = accountFor(id)
  local localVehicle = localizedVehicle()
  local reservations = {}
  for _, reservation in pairs(state.reservations) do reservations[#reservations + 1] = deepcopy(reservation) end
  table.sort(reservations, function(a, b) return tonumber(a.id) < tonumber(b.id) end)
  local listedCount = 0
  for _, blueprint in pairs(state.blueprints) do if blueprint.listed then listedCount = listedCount + 1 end end
  local salesState = currentSale and "selling" or (listedCount > 0 and "waitingForStock" or "notListed")
  local salesDuration = currentSale and (tonumber(state.salesCycleDurationSeconds) or ENGINE_SALE_MAX_SECONDS) or 0
  local salesProgress = currentSale and math.min(salesDuration, math.max(0, tonumber(state.salesCycleProgressSeconds) or 0)) or 0
  local salesCurrentPrice = nil
  if currentSale then
    local saleCost = landedCost(currentSale, state.lines)
    local saleLimit = salePriceLimit(currentSale, saleCost, state)
    local rawSalePrice = tonumber(currentSale.price) or supportedMarketPrice(currentSale, saleCost, state)
    if not rawSalePrice or rawSalePrice ~= rawSalePrice or rawSalePrice == math.huge or rawSalePrice == -math.huge then
      rawSalePrice = supportedMarketPrice(currentSale, saleCost, state)
    end
    salesCurrentPrice = math.max(1, math.min(saleLimit, math.floor(rawSalePrice)))
  end
  local lines = deepcopy(state.lines)
  for _, line in ipairs(lines) do
    line.progressSeconds = math.max(0, tonumber(line.progressSeconds) or 0)
    line.cycleSeconds = lineDuration(line)
    line.successChance = lineSuccessChance(line)
    line.breakdownChance = lineBreakdownChance(line)
    line.maintenanceDiscount = lineMaintenanceDiscount(line)
  end
  return {success = owned(id), businessId = id, businessType = SHOP_TYPE, businessName = "West Coast Engine Works",
    tabs = career_modules_business_businessTabRegistry.getTabs(SHOP_TYPE), showBusinessAccount = true,
    accountId = account and account.id, balance = account and (career_modules_bank.getAccountBalance(account.id) or 0) or 0,
    brandPopularity = state.brandPopularity, packages = personalPackages, blueprints = blueprints, lines = lines,
    salesState = salesState, salesCurrentBlueprintId = currentSale and tostring(currentSale.id) or nil,
    salesCurrentName = currentSale and currentSale.name or nil, salesCurrentPrice = salesCurrentPrice,
    salesCycleSeconds = salesDuration, salesCycleProgressSeconds = salesProgress,
    salesCycleRemainingSeconds = math.max(0, salesDuration - salesProgress),
    lineCapacity = lineCapacity(state), lineUpgrades = lineUpgrades, warehousePackages = finished,
    rawStock = deepcopy(state.rawStock), reservations = reservations, warehouseCapacity = warehouseCapacity(state),
    warehouseUsed = warehouseUsed(id, state), warehouseFree = warehouseCapacity(state) - warehouseUsed(id, state),
    salesHistory = deepcopy(state.salesHistory), upgrades = upgrades, localizedVehicle = localVehicle,
    bayVehicles = localizedVehicles(),
    dayIndex = day, minuteOfDay = minute, migrationPending = state.migrationPending == true,
    devTools = devConsole.isDevToolsEnabled()}
end

local function runInvariantTests()
  local failures = {}
  local function check(value, name) if not value then failures[#failures + 1] = name end end
  local absolute = nowWorldMinutes()
  local state = normalizeState("test", {version = 3})
  check(#state.lines == 3 and lineCapacity(state) == 1, "three visible lines and one starting unlock")
  check(warehouseCapacity(state) == 15, "starting warehouse")
  state.upgrades.warehouse1 = true; check(warehouseCapacity(state) == 25, "warehouse I")
  state.upgrades.warehouse2 = true; check(warehouseCapacity(state) == 50, "warehouse II")
  local line = newLine(1)
  check(lineDuration(line) == 900 and lineSuccessChance(line) == 0.90 and lineBreakdownChance(line) == 0.05, "base production")
  local exactCurve = true
  for level = 0, 3 do
    line.upgrades = {speed = level, quality = level, maintenance = level}
    exactCurve = exactCurve and lineDuration(line) == LINE_DURATION_SECONDS[level + 1]
      and lineSuccessChance(line) == LINE_SUCCESS_CHANCES[level + 1]
      and lineBreakdownChance(line) == LINE_BREAKDOWN_CHANCES[level + 1]
  end
  check(exactCurve, "exact production timer and risk curves")
  check(CERTIFICATION_DURATION_SECONDS == 600 and LINE_OVERHAUL_BASES[1] == 2500
    and LINE_OVERHAUL_BASES[2] == 5000 and LINE_OVERHAUL_BASES[3] == 10000,
    "exact certification timer and overhaul bases")
  line.upgrades = {speed = 3, quality = 3, maintenance = 3}
  check(lineDuration(line) == 300 and lineSuccessChance(line) == 0.99 and lineBreakdownChance(line) == 0.01 and lineMaintenanceDiscount(line) == 0.40, "level three production")
  local awareness = 50 + 30 * (1 - 50 / 100)
  check(math.abs(awareness - 65) < 0.001, "promotion diminishing returns")
  check(math.floor(10000 * 0.05 + 0.5) == 500, "five percent certification fee")
  local testBlueprint = {id = "1", freshValue = 10000, awareness = 0, listed = true}
  state.blueprints[testBlueprint.id] = testBlueprint
  check(math.floor(supportedMarketPrice(testBlueprint, 13500, state) + 0.5) == 15525, "fresh-value market anchor with cost protection")
  check(salePriceLimit(testBlueprint, 13500, state) == 15525, "new brand cannot charge beyond the saturated timer")
  testBlueprint.price = 15525
  check(saleCycleSeconds(testBlueprint, 13500, state) == 900, "supported-price sale takes fifteen minutes")
  testBlueprint.price = 7762
  check(saleCycleSeconds(testBlueprint, 13500, state) == 450, "half-price launch discount halves the base interval")
  state.brandPopularity = 100
  testBlueprint.awareness = 100
  testBlueprint.price = math.floor(supportedMarketPrice(testBlueprint, 13500, state) + 0.5)
  check(saleCycleSeconds(testBlueprint, 13500, state) == 300, "mature supported-price sale takes five minutes")
  local matureLimit = salePriceLimit(testBlueprint, 13500, state)
  check(matureLimit == testBlueprint.price * 2, "mature brand can charge twice the supported price")
  testBlueprint.price = 1000000
  check(saleCycleSeconds(testBlueprint, 13500, state) == 900, "overpriced saved listing cannot shorten capped interval")
  local savedLimit = salePriceLimit(testBlueprint, landedCost(testBlueprint, state.lines), state)
  check(normalizeBlueprintPrice(testBlueprint, state) and testBlueprint.price == savedLimit, "overpriced saved listing is capped")
  local migrated = normalizeState("migration", {version = 2,
    lines = {{progressMinutes = 240, upgrades = {speed = 0, quality = 0, maintenance = 0}}},
    certificationJobs = {one = {submittedAt = absolute - 30, readyAt = absolute + 30, completed = false}},
    salesCycleProgressSeconds = 450, salesCycleDurationSeconds = 900})
  check(math.abs((migrated.lines[1].progressSeconds or 0) - 450) < 0.001, "production migration preserves progress ratio")
  check(math.abs((migrated.certificationJobs.one.progressSeconds or 0) - 300) < 0.001, "certification migration preserves progress ratio")
  check(math.abs((migrated.salesCycleMigrationRatio or 0) - 0.5) < 0.001, "sales migration preserves progress ratio")
  local expectedHourlyProfit = (15500 - ((10000 + 0.05 * 2500) / 0.90)) * 0.90 * 4
  check(expectedHourlyProfit >= 14000 and expectedHourlyProfit <= 17000, "base ten-thousand-dollar engine hourly profit target")
  local stockV8 = recipeCertificationData({vehicleModel = "bluebuck", tree = {name = "bluebuck_engine_v8_423", children = {}}})
  check(stockV8 and #stockV8.samples > 0 and stockV8.peakTorque > 0, "CSV-backed stock V8 torque curve")
  local classicI4 = recipeCertificationData({vehicleModel = "bluebuck", tree = {name = "c_bluebuck_134_engine_flathead_i4", children = {}}})
  check(classicI4 and #classicI4.samples > 0 and classicI4.peakTorque > 0, "CSV-backed classic I4 torque curve")
  return {success = #failures == 0, failures = failures, checks = 24}
end

local function debugAdvanceCalendar(id, minutes)
  if not devConsole.isDevToolsEnabled() then return devConsole.devToolsDisabledResult() end
  local state = ensureState(id); minutes = math.max(0, tonumber(minutes) or 0)
  local seconds = minutes * 60
  processProduction(id, state, seconds); processCertifications(id, state, seconds); advanceSales(id, state, seconds)
  saveData()
  return {success = true, message = "Advanced Engine Works by " .. tostring(minutes) .. " active minutes."}
end

local function debugForceCertification(id, packageId, passed)
  if not devConsole.isDevToolsEnabled() then return devConsole.devToolsDisabledResult() end
  local state = ensureState(id); local job = state.certificationJobs[tostring(packageId)]
  if not job then return {success = false, message = "Start certification for this package first."} end
  job.result = passed == false and "failed" or "passed"
  job.progressSeconds = CERTIFICATION_DURATION_SECONDS
  completeCertification(id, state, tostring(packageId), job)
  return {success = true, message = "Certification result forced."}
end

local function debugForceProduction(id, lineId, success, breakdown)
  if not devConsole.isDevToolsEnabled() then return devConsole.devToolsDisabledResult() end
  local state = ensureState(id); local line = state.lines[tonumber(lineId)]
  if not line or not line.blueprintId then return {success = false, message = "Assign a blueprint first."} end
  if (state.rawStock[tostring(line.blueprintId)] or 0) <= 0 then return {success = false, message = "Add raw material first."} end
  processAttempt(id, state, line, success ~= false, breakdown == true); saveData()
  return {success = true, message = "Forced production outcome applied."}
end

local function debugAddRaw(id, blueprintId, quantity)
  if not devConsole.isDevToolsEnabled() then return devConsole.devToolsDisabledResult() end
  local state = ensureState(id); quantity = math.max(1, math.floor(tonumber(quantity) or 1))
  if not state.blueprints[tostring(blueprintId)] then return {success = false, message = "Blueprint not found."} end
  if warehouseUsed(id, state) + quantity > warehouseCapacity(state) then return {success = false, message = "Not enough shared warehouse space."} end
  state.rawStock[tostring(blueprintId)] = (state.rawStock[tostring(blueprintId)] or 0) + quantity; saveData()
  return {success = true, message = "Debug raw material added."}
end

local function onUpdate(dtReal, dtSim)
  if not career_career.isActive() then return end
  local elapsed = math.max(0, tonumber(dtSim) or 0)
  if elapsed <= 0 then return end
  for id, state in pairs(states) do
    if owned(id) then
      processCertifications(id, state, elapsed)
      processProduction(id, state, elapsed)
      state.salesUpdateAccumulatorSeconds = (state.salesUpdateAccumulatorSeconds or 0) + elapsed
      if state.salesUpdateAccumulatorSeconds >= 1 then
        local salesStep = math.floor(state.salesUpdateAccumulatorSeconds)
        state.salesUpdateAccumulatorSeconds = state.salesUpdateAccumulatorSeconds - salesStep
        advanceSales(id, state, salesStep)
      end
    end
  end
end

local function resetBusinessForSale(id)
  id = tostring(id)
  local state = states[id]
  if not state then return true end
  if career_modules_delivery_parcelManager and career_modules_delivery_parcelManager.getAllCargoCustomFilter then
    local cargoList = career_modules_delivery_parcelManager.getAllCargoCustomFilter(function(cargo)
      return cargo and cargo.data and tostring(cargo.data.engineShopBusinessId or "") == id
    end) or {}
    for _, cargo in ipairs(cargoList) do returnCargoToSupplier(cargo, true) end
  end
  for _, package in ipairs(career_modules_enginePackages.listPackages({ownerType = "personal"})) do
    if package.engineShopCertification and tostring(package.engineShopCertification.businessId or "") == id then
      career_modules_enginePackages.setEngineShopCertification(package.id, nil)
    end
  end
  for _, package in ipairs(career_modules_enginePackages.listPackages({ownerType = "business", businessType = SHOP_TYPE, businessId = id})) do
    career_modules_enginePackages.removeBusinessPackage(package.id)
  end
  if career_modules_business_businessPartInventory and career_modules_business_businessPartInventory.clearBusinessParts then
    career_modules_business_businessPartInventory.clearBusinessParts(id)
  end
  if career_modules_business_businessInventory and career_modules_business_businessInventory.clearBusinessInventory then
    career_modules_business_businessInventory.clearBusinessInventory(id)
  end
  states[id] = nil
  if activeBusinessId == id then activeBusinessId = nil end
  supplyPickupOpen, supplyLoadInProgress = false, false
  saveData()
  if career_modules_delivery_general and career_modules_delivery_general.requestDeliveryPoiRefresh then
    career_modules_delivery_general.requestDeliveryPoiRefresh(true)
  end
  return true
end

local businessObject = {businessType = SHOP_TYPE, resaleMultiplier = 1,
  features = {bankAccount = true, inventory = false, finances = true, skillTrees = false, personalVehicle = true,
    xpSystem = false, operatingCosts = false},
  getUIData = getUIData, getLiquidationValue = getLiquidationValue, getMaxPulledOutVehicles = function() return 0 end,
  isVehicleKitLocked = function() return false end, resetBusinessForSale = resetBusinessForSale}

local function openMenu(id)
  id = tostring(id); activeBusinessId = id; ensureTabsRegistered(); migratePromoFleet(id, ensureState(id))
  if career_modules_business_businessComputer and career_modules_business_businessComputer.setBusinessContext then
    career_modules_business_businessComputer.setBusinessContext(SHOP_TYPE, id)
  end
  extensions.ui_router.navigate("business-computer", {businessType = SHOP_TYPE, businessId = id})
  return true
end

local function onCareerActivated()
  loadData()
  career_modules_business_businessManager.registerBusiness(SHOP_TYPE, businessObject)
  career_modules_business_businessManager.registerBusinessCallback(SHOP_TYPE, {onPurchase = function(id)
    ensureState(id)
    local capital = career_modules_business_businessManager.getPurchaseCapitalInjectionAmount(0)
    if capital > 0 then reward(id, capital, "Capital Injection", "Initial operating capital") end
    saveData()
  end, onMenuOpen = openMenu})
  ensureTabsRegistered()
  career_modules_enginePackages.registerPackageReferenceGuard(packageReferenceGuard)
end

M.getUIData = getUIData
M.openMenu = openMenu
M.startCertification = startCertification
M.assignLineBlueprint = assignLineBlueprint
M.setLineRunning = setLineRunning
M.purchaseLineUpgrade = purchaseLineUpgrade
M.overhaulLine = overhaulLine
M.orderRawMaterials = orderRawMaterials
M.junkWarehousePackage = junkWarehousePackage
M.installWarehousePackage = installWarehousePackage
M.setBlueprintListed = setBlueprintListed
M.setBlueprintPrice = setBlueprintPrice
M.purchaseUpgrade = purchaseUpgrade
M.openEnginePackages = openEnginePackages
M.openParts = openParts
M.openMyParts = openMyParts
M.selectBayVehicle = selectBayVehicle
M.openTuning = openTuning
M.openRepair = openRepair
M.getSupplyOfferCard = getSupplyOfferCard
M.hasPaidSupplyAt = hasPaidSupplyAt
M.getPaidSupplyPickupLocations = getPaidSupplyPickupLocations
M.enterSupplyPickupScreen = enterSupplyPickupScreen
M.requestSupplyPickupData = requestSupplyPickupData
M.loadSupply = loadSupply
M.closeSupplyPickupScreen = closeSupplyPickupScreen
M.canDeliverSupplyCargo = canDeliverSupplyCargo
M.deliverSupplyCargo = deliverSupplyCargo
M.returnCargoToSupplier = returnCargoToSupplier
M.runInvariantTests = runInvariantTests
M.debugAdvanceCalendar = debugAdvanceCalendar
M.debugForceCertification = debugForceCertification
M.debugForceProduction = debugForceProduction
M.debugAddRaw = debugAddRaw
M.onRlsFreeroamRaceResultFinalized = onRlsFreeroamRaceResultFinalized
M.onCareerActivated = onCareerActivated
M.onSaveCurrentProfile = function(path) saveData(path) end
M.onUpdate = onUpdate
M.getMaxPulledOutVehicles = function() return 0 end

return M
