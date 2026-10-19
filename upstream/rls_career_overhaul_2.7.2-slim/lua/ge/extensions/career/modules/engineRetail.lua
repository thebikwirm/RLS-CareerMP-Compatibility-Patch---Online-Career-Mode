local M = {}

M.dependencies = {
  "career_career", "career_saveSystem", "career_modules_payment", "career_modules_inventory",
  "career_modules_enginePackages", "career_modules_engineCertification", "career_modules_permissions",
  "career_modules_insurance_insurance"
}

local jbeamIO = require("jbeam/io")
local jbeamSlotSystem = require("jbeam/slotSystem")
local logTag = "engineRetail"
local SAVE_PATH = "/career/rls_career/engineRetail.json"
local FACILITY_PATH = "/levels/west_coast_usa/facilities/engineRetail.facilities.json"
local STOCK_LIFETIME = 1800
local RESTOCK_INTERVAL = 300
local CATALOG_VERSION = 10
local RETAIL_MARKUP = 0.15
local state = {activeSeconds = 0, nextListingId = 1, shops = {}, jobs = {}}
local shopsById = {}
local recipeCache = {}
local analysisCache = {}
local valueCache = {}
local menuContext
local initialized = false
local updateAccumulator = 0
local parkedOwnedVehicle

local function clamp(value, low, high) return math.max(low, math.min(high, value)) end
local function round25(value) return math.floor((tonumber(value) or 0) / 25 + 0.5) * 25 end
local function shuffle(values)
  for index = #values, 2, -1 do
    local swap = math.random(index)
    values[index], values[swap] = values[swap], values[index]
  end
end
local function isPaused()
  return simTimeAuthority and simTimeAuthority.getPause and simTimeAuthority.getPause() == true
end

local function loadShopDefinitions()
  shopsById = {}
  local data = jsonReadFile(FACILITY_PATH) or {}
  for _, shop in ipairs(data.engineRetailers or {}) do shopsById[tostring(shop.id)] = shop end
end

local function saveData(savePath)
  if not savePath then local _, path = career_saveSystem.getCurrentProfile(); savePath = path end
  if savePath then jsonWriteFile(savePath .. SAVE_PATH, {version = 1, state = state}, true) end
end

local function loadData()
  local _, savePath = career_saveSystem.getCurrentProfile()
  local data = savePath and jsonReadFile(savePath .. SAVE_PATH) or nil
  state = type(data and data.state) == "table" and data.state or {activeSeconds = 0, nextListingId = 1, shops = {}, jobs = {}}
  state.activeSeconds = math.max(0, tonumber(state.activeSeconds) or 0)
  state.nextListingId = math.max(1, math.floor(tonumber(state.nextListingId) or 1))
  state.shops = type(state.shops) == "table" and state.shops or {}
  state.jobs = type(state.jobs) == "table" and state.jobs or {}
end

local function sitesForShop(shop)
  if not shop then return nil end
  return gameplay_sites_sitesManager.loadSites("/levels/" .. tostring(shop.mapId or "west_coast_usa") .. "/"
    .. tostring(shop.sitesFile or "engineShop.sites.json"))
end

local function spotFor(shop, key)
  local sites = sitesForShop(shop)
  local name = shop and shop[key]
  return sites and name and sites.parkingSpots and sites.parkingSpots.byName[name] or nil
end

local function getConfigType(info)
  local value = info and (info["Config Type"] or (info.aggregates and info.aggregates["Config Type"]))
  if type(value) == "string" then return value end
  if type(value) == "table" then for key, enabled in pairs(value) do if enabled then return tostring(key) end end end
end

local function configCategory(info)
  return string.lower(tostring(getConfigType(info) or "")) == "factory" and "factory" or "aftermarket"
end

local function configPopulation(info)
  local value = info and (info.Population or info.population or (info.aggregates and info.aggregates.Population))
  if type(value) == "table" then value = value.max or value.value or value.min end
  -- A square-root curve lets common configurations appear more often without
  -- making rare and mod-authored configurations effectively impossible to see.
  return math.sqrt(math.max(1, tonumber(value) or 100))
end

local function populationWeightedOrder(values)
  local ranked = {}
  for _, info in ipairs(values or {}) do
    -- Exponential-race keys produce a weighted shuffle without replacement.
    local roll = math.max(0.000000001, math.random())
    ranked[#ranked + 1] = {info = info, score = -math.log(roll) / configPopulation(info)}
  end
  table.sort(ranked, function(a, b) return a.score < b.score end)
  local result = {}
  for _, entry in ipairs(ranked) do result[#result + 1] = entry.info end
  return result
end

local function configPath(info)
  local key, model = tostring(info.key or ""), tostring(info.model_key or "")
  key = key:gsub("\\", "/")
  if key:sub(-3) == ".pc" then return key:sub(1, 1) == "/" and key or "/" .. key end
  local direct = string.format("/vehicles/%s/%s.pc", model, key)
  if FS:fileExists(direct) then return direct end
  return string.format("/vehicles/%s/configurations/%s.pc", model, key)
end

local function findEngineNode(tree, ioCtx)
  return career_modules_enginePackages.findEngineAssemblyCandidates(tree, false, ioCtx)[1]
end

local function recipeNode(node, slotName)
  local result = {name = node.chosenPartName, slotName = slotName or node.id, children = {}}
  for childSlot, child in pairs(node.children or {}) do
    if child.chosenPartName and child.chosenPartName ~= "" then result.children[childSlot] = recipeNode(child, childSlot) end
  end
  return result
end

local function nicePartName(ioCtx, name)
  local info = (jbeamIO.getAvailableParts(ioCtx) or {})[name] or {}
  local description = info.description
  if type(description) == "table" then description = description.description or description.name end
  return type(description) == "string" and description or name
end

local function findTransmissionNode(tree)
  for slotName, child in pairs(tree and tree.children or {}) do
    if string.find(string.lower(tostring(slotName)), "transmission", 1, true) then return tree, slotName, child end
    local parent, key, found = findTransmissionNode(child)
    if found then return parent, key, found end
  end
end

-- Category identity follows the engine build, not the source vehicle. A
-- transmission may vary while the engine remains factory-equivalent, so omit
-- the complete transmission branch while retaining engine parts and tuning.
local function engineBuildSignature(recipe)
  local parts = {}
  local definingTokens = {"engine", "internal", "intake", "turbo", "supercharger", "ecu", "exhaust",
    "head", "block", "piston", "camshaft", "carb", "injection", "nitro", "n2o"}
  local excludedTokens = {"mount", "oilpan", "radiator", "cooler", "flywheel"}
  local function visit(node, slotName, isRoot)
    if not node then return end
    local normalizedSlot = string.lower(tostring(slotName or node.slotName or ""))
    if string.find(normalizedSlot, "transmission", 1, true) then return end
    local text = normalizedSlot .. " " .. string.lower(tostring(node.name or ""))
    local excluded, defining = false, isRoot == true
    for _, token in ipairs(excludedTokens) do
      if string.find(text, token, 1, true) then excluded = true; break end
    end
    if not excluded and not defining then
      for _, token in ipairs(definingTokens) do
        if string.find(text, token, 1, true) then defining = true; break end
      end
    end
    if defining and not excluded then
      parts[#parts + 1] = {slotName = tostring(slotName or node.slotName or ""), name = tostring(node.name or "")}
    end
    for childSlot, child in pairs(node.children or {}) do visit(child, childSlot, false) end
  end
  visit(recipe and recipe.tree, recipe and recipe.rootSlotName, true)
  table.sort(parts, function(a, b)
    local left, right = a.slotName .. "=" .. a.name, b.slotName .. "=" .. b.name
    return left < right
  end)
  return career_modules_enginePackages.computeRecipeSignature({
    vehicleModel = recipe and recipe.vehicleModel,
    rootEngineName = recipe and recipe.rootEngineName,
    parts = parts,
    tuning = deepcopy(recipe and recipe.tuning or {})
  })
end

local function shopAllowsRecipe(shop, info, recipe, ioCtx)
  if shop.catalogMode ~= "filtered" then return true end
  local pieces = {tostring(configPath(info)), tostring(info.Name or ""), tostring(recipe.rootEngineName or ""),
    tostring(recipe.rootEngineNiceName or "")}
  local available = ioCtx and jbeamIO.getAvailableParts(ioCtx) or {}
  local function visit(node)
    if not node then return end
    pieces[#pieces + 1] = tostring(node.name or "")
    local description = available[node.name] and available[node.name].description
    if type(description) == "table" then description = description.description or description.name end
    pieces[#pieces + 1] = tostring(description or "")
    for _, child in pairs(node.children or {}) do visit(child) end
  end
  visit(recipe.tree)
  local haystack = string.lower(table.concat(pieces, " "))
  for _, token in ipairs(shop.catalogTokens or {}) do
    if string.find(haystack, string.lower(tostring(token)), 1, true) then return true end
  end
  return false
end

local function configInfoMatchesCatalog(shop, info)
  if shop.catalogMode ~= "filtered" then return true end
  local haystack = string.lower(table.concat({tostring(configPath(info)), tostring(info.Name or ""),
    tostring(info.Source or ""), tostring(info.SourceId or ""), tostring(info.modID or "")}, " "))
  for _, token in ipairs(shop.catalogTokens or {}) do
    if string.find(haystack, string.lower(tostring(token)), 1, true) then return true end
  end
  return false
end

-- JBeam inspection is deliberately shop-time work, never per-frame work. The
-- result is pure for a recipe signature, so reuse it across listings and UI
-- refreshes to keep opening a busy catalog inexpensive.
local function analyzeRecipe(recipe, ioCtx)
  local signature = recipe and (recipe.signature or career_modules_enginePackages.computeRecipeSignature(recipe))
  if signature and analysisCache[signature] then return deepcopy(analysisCache[signature]) end
  local analysis, err = career_modules_engineCertification.analyzeRecipe(recipe, ioCtx)
  if analysis and signature then analysisCache[signature] = deepcopy(analysis) end
  return analysis, err
end

local function recipeValue(recipe, ioCtx)
  local signature = recipe and (recipe.signature or career_modules_enginePackages.computeRecipeSignature(recipe))
  if signature and valueCache[signature] then return valueCache[signature] end
  local value, err = career_modules_enginePackages.getFreshRecipeValue(recipe, ioCtx)
  if value and signature then valueCache[signature] = value end
  return value, err
end

local function discoverRecipes(shop, inventoryId)
  local vehicle = career_modules_inventory.getVehicles()[tonumber(inventoryId)]
  if not vehicle then return {} end
  local attachmentKey = career_modules_enginePackages.getEngineCompatibilityKey(inventoryId)
  if not attachmentKey then return {} end
  local cacheKey = tostring(shop.id) .. "|" .. tostring(vehicle.model) .. "|" .. tostring(attachmentKey)
  local cached = recipeCache[cacheKey]
  if cached and state.activeSeconds - (tonumber(cached.createdAtActive) or 0) < STOCK_LIFETIME then
    return cached.results
  end
  local results, signatures, ioByModel = {}, {}, {}
  local candidates = {}
  local vehId = career_modules_inventory.getVehicleIdFromInventoryId(tonumber(inventoryId))
  local runtimeData = vehId and core_vehicle_manager.getVehicleData(vehId) or nil
  local configList = core_vehicles and core_vehicles.getConfigList and core_vehicles.getConfigList() or {}
  for _, info in pairs(configList.configs or configList) do
    if type(info) == "table" and tostring(info.model_key) == tostring(vehicle.model) and info.key then
      candidates[#candidates + 1] = info
    end
  end
  local function orderCandidates(values)
    if shop.catalogMode ~= "filtered" then return populationWeightedOrder(values) end
    local preferred, fallback = {}, {}
    for _, info in ipairs(values) do
      local bucket = configInfoMatchesCatalog(shop, info) and preferred or fallback
      bucket[#bucket + 1] = info
    end
    local ordered = populationWeightedOrder(preferred)
    for _, info in ipairs(populationWeightedOrder(fallback)) do ordered[#ordered + 1] = info end
    return ordered
  end
  candidates = orderCandidates(candidates)
  local recipeTarget = math.max(1, tonumber(shop.stockSize) or 8)
  -- One bounded search supplies the whole shop. Never resolve more complete
  -- vehicle trees than the store can display; new/used variants can fill the
  -- remaining cards when several configs resolve to the same engine package.
  local scanLimit = math.max(1, recipeTarget)
  local parsed = {}
  local function parseCandidate(info)
    local pcPath = configPath(info)
    if parsed[pcPath] ~= nil then return parsed[pcPath] or nil end
    local pc = FS:fileExists(pcPath) and jsonReadFile(pcPath) or nil
    local vehicleDir = string.format("/vehicles/%s/", tostring(info.model_key))
    if type(pc) ~= "table" or not FS:directoryExists(vehicleDir) then parsed[pcPath] = false; return nil end
    local modelKey = tostring(info.model_key)
    local ioCtx = ioByModel[modelKey]
    if ioCtx == nil then
      ioCtx = runtimeData and runtimeData.ioCtx or jbeamIO.startLoading({vehicleDir, "/vehicles/common/"})
      ioByModel[modelKey] = ioCtx or false
    end
    if not ioCtx then parsed[pcPath] = false; return nil end
    pc.mainPartName = pc.mainPartName or jbeamIO.getMainPartName(ioCtx)
    pc.mainPartPath = pc.mainPartPath or (pc.mainPartName and "/" .. pc.mainPartName)
    local _, _, _, tree = jbeamSlotSystem.findParts(ioCtx, pc)
    local engine = tree and findEngineNode(tree, ioCtx)
    if not engine then parsed[pcPath] = false; return nil end
    local recipe = {
      vehicleModel = modelKey, rootSlotName = engine.slotName, rootPath = engine.path,
      rootEngineName = engine.combustionPartName or engine.node.chosenPartName,
      rootEngineNiceName = nicePartName(ioCtx, engine.combustionPartName or engine.node.chosenPartName),
      tree = recipeNode(engine.node, engine.slotName), tuning = {}
    }
    recipe.tuning = career_modules_enginePackages.filterRecipeTuning(
      recipe.tree, recipe.vehicleModel, pc.vars or {}, ioCtx)
    recipe.signature = career_modules_enginePackages.computeRecipeSignature(recipe)
    local _, _, transmission = findTransmissionNode(recipe.tree)
    if not transmission or not career_modules_enginePackages.findCompatibleRecipeTarget(recipe, inventoryId) then
      parsed[pcPath] = false
      return nil
    end
    local entry = {recipe = recipe, info = deepcopy(info), sourceTree = engine.node, ioCtx = ioCtx,
      category = configCategory(info), engineBuildSignature = engineBuildSignature(recipe)}
    parsed[pcPath] = entry
    return entry
  end
  local function addResult(entry)
    if not entry or #results >= recipeTarget then return false end
    local signature = tostring(entry.recipe.signature)
    if signatures[signature] or not shopAllowsRecipe(shop, entry.info, entry.recipe, entry.ioCtx) then return false end
    local analysis = analyzeRecipe(entry.recipe, entry.ioCtx)
    local freshValue = recipeValue(entry.recipe, entry.ioCtx)
    if not analysis or not freshValue then return false end
    signatures[signature] = true
    entry.analysis, entry.freshValue = analysis, freshValue
    results[#results + 1] = entry
    return true
  end
  local checks = 0
  for _, info in ipairs(candidates) do
    if #results >= recipeTarget or checks >= scanLimit then break end
    checks = checks + 1
    addResult(parseCandidate(info))
  end
  table.sort(results, function(a, b) return tostring(a.recipe.rootEngineNiceName) < tostring(b.recipe.rootEngineNiceName) end)
  recipeCache[cacheKey] = {createdAtActive = state.activeSeconds, results = results}
  return results
end

local function collectVisibleParts(entry, modifiedClues, ioCtx)
  local visible = {{label = "Block / engine", value = entry.recipe.rootEngineNiceName}}
  local _, _, transmission = findTransmissionNode(entry.recipe.tree)
  if transmission and transmission.name then
    visible[#visible + 1] = {label = "Transmission", value = nicePartName(ioCtx, transmission.name)}
  end
  local found = {}
  local function visit(node)
    for slotName, child in pairs(node.children or {}) do
      local lower = string.lower(tostring(slotName))
      if #visible < 3 and not found[lower] and (lower:find("intake", 1, true) or lower:find("turbo", 1, true)
          or lower:find("supercharger", 1, true) or lower:find("ecu", 1, true)) then
        found[lower] = true
        visible[#visible + 1] = {label = modifiedClues and "Visible upgrade" or "Visible part",
          value = nicePartName(ioCtx, child.name)}
      end
      visit(child)
    end
  end
  visit(entry.recipe.tree)
  return visible
end

local function randomizeRecipe(base)
  local recipe, candidates = deepcopy(base.recipe), {}
  local function gather(recipePart, sourcePart)
    for slotName, child in pairs(recipePart.children or {}) do
      local sourceChild = sourcePart.children and sourcePart.children[slotName]
      local lower = string.lower(tostring(slotName))
      local interesting = lower:find("intake", 1, true) or lower:find("turbo", 1, true)
        or lower:find("supercharger", 1, true) or lower:find("ecu", 1, true)
      if interesting and sourceChild and #(sourceChild.suitablePartNames or {}) > 1 and not next(child.children or {}) then
        candidates[#candidates + 1] = {recipePart = child, sourcePart = sourceChild, slotName = slotName}
      end
      if sourceChild then gather(child, sourceChild) end
    end
  end
  gather(recipe.tree, base.sourceTree)
  local clues = {}
  if #candidates > 0 then
    local candidate = candidates[math.random(#candidates)]
    local alternatives = {}
    for _, name in ipairs(candidate.sourcePart.suitablePartNames or {}) do
      if name ~= "" and name ~= candidate.recipePart.name then alternatives[#alternatives + 1] = name end
    end
    if #alternatives > 0 then
      candidate.recipePart.name = alternatives[math.random(#alternatives)]
      clues[#clues + 1] = "Aftermarket-looking " .. candidate.slotName:gsub("_", " ")
    end
  end
  recipe.signature = career_modules_enginePackages.computeRecipeSignature(recipe)
  return recipe, clues, #clues > 0
end

local reliabilityOrder = {Reliable = 1, Fair = 2, Risky = 3, Questionable = 4}
local function reliabilityFor(integrity, analysis, unknown)
  local condition = integrity >= 0.85 and "Reliable" or integrity >= 0.65 and "Fair" or integrity >= 0.45 and "Risky" or "Questionable"
  local utilization = analysis and tonumber(analysis.torqueUtilization)
  local stress = not utilization and "Questionable" or utilization <= 0.75 and "Reliable"
    or utilization <= 0.9 and "Fair" or utilization <= 1 and "Risky" or "Questionable"
  local result = reliabilityOrder[condition] >= reliabilityOrder[stress] and condition or stress
  if unknown and reliabilityOrder[result] < reliabilityOrder.Risky then result = "Risky" end
  return result
end

local function createListing(shop, base, kind, inventoryId)
  local category = base.category == "factory" and "factory" or "aftermarket"
  local modified = kind == "usedModified"
  local recipe, clues, changed
  if modified then recipe, clues, changed = randomizeRecipe(base) else recipe, clues, changed = deepcopy(base.recipe), {}, true end
  if not changed then return nil end
  local fit = career_modules_enginePackages.findCompatibleRecipeTarget(recipe, inventoryId)
  if not fit then return nil end
  local analysis = modified and analyzeRecipe(recipe, base.ioCtx) or deepcopy(base.analysis)
  if not analysis then return nil end
  local used = kind ~= "new"
  local currentYear = career_modules_enginePackages.getCurrentManufacturingYear()
  local maximumAge = category == "factory" and 6 or 10
  local age = used and math.floor(1 + math.pow(math.random(), 0.85) * (maximumAge - 1)) or 0
  local year = currentYear - age
  local annualMiles = used and (4000 + math.random() * 6000) or 0
  local mileageMiles = used and math.max(1500, age * annualMiles * (0.82 + math.random() * 0.36)) or 0
  local mileage = math.floor(mileageMiles * 1609.344)
  local ageWear = age / maximumAge * 0.06
  local mileageWear = mileageMiles / 100000 * 0.12
  local modificationWear = modified and 0.04 or 0
  local minimumIntegrity = category == "factory" and 0.84 or 0.80
  local integrity = used and clamp(0.98 - ageWear - mileageWear - modificationWear + (math.random() - 0.5) * 0.06,
    minimumIntegrity, 0.97) or 1
  local value = modified and recipeValue(recipe, base.ioCtx) or base.freshValue
  local price = career_modules_enginePackages.getConditionedRecipeValue(recipe, {
    manufacturedYear = year, odometer = mileage, integrity = integrity
  }, base.ioCtx)
  if not price then return nil end
  -- Retail margin is separate from the parts' condition-adjusted inventory value.
  price = math.max(1, math.floor(price * (1 + RETAIL_MARKUP) + 0.5))
  local id = tostring(state.nextListingId); state.nextListingId = state.nextListingId + 1
  local certification
  if not modified then
    certification = deepcopy(analysis)
    certification.status = analysis.result == "passed" and "passed" or "failed"
    certification.recipeSignature = recipe.signature
    certification.source = category == "factory"
      and (kind == "new" and "factory recipe" or "factory donor inspection")
      or (kind == "new" and "aftermarket build sheet" or "aftermarket inspection")
  end
  -- Config-list Power is already stored in watts; the analyzer is canonical
  -- mechanical horsepower, which is what this retail payload explicitly names.
  local displayPower = analysis and analysis.peakHorsepower
  return {
    id = id, shopId = tostring(shop.id), kind = kind, category = category, name = recipe.rootEngineNiceName,
    engineBuildSignature = base.engineBuildSignature or engineBuildSignature(recipe),
    sourceConfigName = base.info.Name or base.info.key, recipe = recipe, createdAtActive = state.activeSeconds,
    expiresAtActive = state.activeSeconds + STOCK_LIFETIME, mileage = mileage, manufacturedYear = year,
    integrity = integrity, freshValue = value, price = price,
    powerHp = displayPower, peakTorqueNm = analysis and analysis.peakTorque,
    maxTorqueRatingNm = analysis and round25(analysis.rating), estimatedSafePowerHp = analysis and round25(analysis.estimatedSafePower),
    reliability = reliabilityFor(integrity, analysis, modified), certification = certification,
    inspection = modified and deepcopy(analysis) or nil, aftermarketUnknown = modified,
    exceedsStressLimit = analysis.result == "failed",
    sellerClues = clues, visibleParts = collectVisibleParts({recipe = recipe}, modified, base.ioCtx)
  }
end

local function modelStock(shop, inventoryId)
  local vehicle = career_modules_inventory.getVehicles()[tonumber(inventoryId)]
  if not vehicle then return nil end
  local attachmentKey = career_modules_enginePackages.getEngineCompatibilityKey(inventoryId)
  if not attachmentKey then return nil end
  local shopState = state.shops[tostring(shop.id)] or {models = {}}
  state.shops[tostring(shop.id)] = shopState
  shopState.models = shopState.models or {}
  local stockKey = tostring(vehicle.model) .. "|" .. tostring(attachmentKey)
  local stock = shopState.models[stockKey] or {listings = {}, lastRestock = -RESTOCK_INTERVAL}
  shopState.models[stockKey] = stock
  return stock
end

local function refreshStock(shop, inventoryId, force)
  local stock = modelStock(shop, inventoryId)
  if not stock then return nil, "No compatible vehicle is selected." end
  if stock.catalogVersion ~= CATALOG_VERSION then
    stock.listings = {}
    stock.lastRestock = -RESTOCK_INTERVAL
    stock.catalogVersion = CATALOG_VERSION
  end
  local kept = {}
  for _, listing in ipairs(stock.listings or {}) do
    if state.activeSeconds < (tonumber(listing.expiresAtActive) or 0) then kept[#kept + 1] = listing end
  end
  stock.listings = kept
  if not force and state.activeSeconds - (tonumber(stock.lastRestock) or 0) < RESTOCK_INTERVAL and #kept > 0 then return stock end
  local recipes = discoverRecipes(shop, inventoryId)
  if #recipes == 0 then return stock, "No authored engine configurations fit this vehicle." end
  local desired = math.max(1, tonumber(shop.stockSize) or 8)
  local kinds = {"new", "used"}
  local combinations = {}
  for _, base in ipairs(recipes) do
    for _, kind in ipairs(kinds) do
      combinations[#combinations + 1] = {kind = kind, base = base}
    end
  end
  shuffle(combinations)
  local consumed = {}
  for _, listing in ipairs(stock.listings) do
    consumed[tostring(listing.kind) .. "|" .. tostring(listing.recipe and listing.recipe.signature)] = true
  end
  local function addCombo(combo)
    local key = combo.kind .. "|" .. tostring(combo.base.recipe.signature)
    if consumed[key] or #stock.listings >= desired then return false end
    local listing = createListing(shop, combo.base, combo.kind, inventoryId)
    if not listing then return false end
    stock.listings[#stock.listings + 1] = listing
    consumed[key] = true
    return true
  end
  for _, combo in ipairs(combinations) do
    if #stock.listings >= desired then break end
    addCombo(combo)
  end
  stock.lastRestock = state.activeSeconds
  stock.catalogVersion = CATALOG_VERSION
  saveData()
  return stock
end

local function findListing(shopId, listingId, inventoryId)
  local shop = shopsById[tostring(shopId)]
  local stock = shop and modelStock(shop, inventoryId)
  for index, listing in ipairs(stock and stock.listings or {}) do
    if tostring(listing.id) == tostring(listingId) then return listing, stock, index end
  end
end

local function preparedRecipe(listing, inventoryId)
  local recipe = deepcopy(listing.recipe)
  local _, _, transmission = findTransmissionNode(recipe.tree)
  if not transmission then return nil, "This listing does not contain a matched transmission." end
  recipe.signature = career_modules_enginePackages.computeRecipeSignature(recipe)
  local fit, err = career_modules_enginePackages.findCompatibleRecipeTarget(recipe, inventoryId)
  if not fit then return nil, err end
  return recipe
end

local function vehicleReadyForEngineSwap(inventoryId)
  local insurance = career_modules_insurance_insurance
  if not insurance or not insurance.inventoryVehNeedsRepair then
    return false, "Vehicle repair status is unavailable. Reopen the shop and try again."
  end
  if insurance.inventoryVehNeedsRepair(tonumber(inventoryId)) then
    return false, "Repair this vehicle before purchasing an engine swap."
  end
  return true
end

local function getQuote(listingId, options)
  options = options or {}
  if not menuContext then return {success = false, message = "The engine shop is not open."} end
  if not menuContext.inventoryId then return {success = false, message = "Park an accessible owned vehicle in the service bay first."} end
  local shop = shopsById[tostring(menuContext.shopId)]
  if tonumber(parkedOwnedVehicle(shop)) ~= tonumber(menuContext.inventoryId) then
    return {success = false, message = "The selected vehicle is no longer parked in the service bay."}
  end
  local install = options.mode == "install"
  if install then
    local ready, repairError = vehicleReadyForEngineSwap(menuContext.inventoryId)
    if not ready then return {success = false, message = repairError, requiresRepair = true} end
  end
  local listing = findListing(menuContext.shopId, listingId, menuContext.inventoryId)
  if not listing then return {success = false, message = "That engine is no longer available."} end
  local recipe, err = preparedRecipe(listing, menuContext.inventoryId)
  if not recipe then return {success = false, message = err} end
  -- The package is immutable after listing creation; there is no optional
  -- transmission/removal path that would require repricing it here.
  local preparedValue = listing.freshValue
  local packagePrice = math.max(1, math.floor(listing.price * preparedValue / math.max(1, listing.freshValue) + 0.5))
  local nodes = 0
  local function count(node) nodes = nodes + 1; for _, child in pairs(node.children or {}) do count(child) end end
  count(recipe.tree)
  local installFee = install and math.max(350, math.floor(packagePrice * 0.06 + 0.5)) or 0
  local duration = install and clamp(300 + nodes * 12, 300, 600) or 0
  local _, currentValue = career_modules_enginePackages.getInstalledRecipeAndValue(menuContext.inventoryId)
  local tradeInCredit = install and options.tradeIn == true and math.floor((tonumber(currentValue) or 0) * 0.7 + 0.5) or 0
  return {success = true, listingId = tostring(listing.id), recipe = recipe, packagePrice = packagePrice,
    installFee = installFee, tradeInCredit = tradeInCredit, total = math.max(0, packagePrice + installFee - tradeInCredit),
    durationSeconds = duration, includesTransmission = true, mode = options.mode or "loose"}
end

local function payment(amount, label)
  return career_modules_payment.pay({money = {amount = math.max(0, math.floor(amount)), canBeNegative = false}},
    {label = label, tags = {"engineRetail", "vehicleModification"}})
end

local function packageMetadata(listing, recipe)
  local certification = listing.certification and deepcopy(listing.certification) or nil
  if certification then certification.recipeSignature = recipe.signature end
  return {listingId = listing.id, shopId = listing.shopId, type = listing.kind, integrity = listing.integrity,
    visual = clamp(listing.integrity - 0.04, 0.2, 1), odometer = listing.mileage,
    manufacturedYear = listing.manufacturedYear, reliability = listing.reliability,
    aftermarketUnknown = listing.aftermarketUnknown, certification = certification}
end

local function removeListing(stock, index) table.remove(stock.listings, index); saveData() end

local function riskAccepted(listing, options)
  return not listing.exceedsStressLimit or options and options.acceptRisk == true
end

local function purchaseLoose(listingId, options)
  if not menuContext then return {success = false, message = "The engine shop is not open."} end
  local shop = shopsById[tostring(menuContext.shopId)]
  if not menuContext.inventoryId or tonumber(parkedOwnedVehicle(shop)) ~= tonumber(menuContext.inventoryId) then
    return {success = false, message = "Park the selected owned vehicle in the service bay first."}
  end
  local listing, stock, index = findListing(menuContext.shopId, listingId, menuContext.inventoryId)
  if not listing then return {success = false, message = "That engine is no longer available."} end
  if not riskAccepted(listing, options) then
    return {success = false, requiresRiskConfirmation = true,
      message = "Confirm that you accept the risk of an engine package that exceeds its declared stress limit."}
  end
  if not payment(listing.price, "Loose Engine Package") then return {success = false, message = "You cannot afford this Engine Package."} end
  local package, err = career_modules_enginePackages.clonePersonalPackageFromRecipe(listing.recipe,
    listing.name .. " Package", packageMetadata(listing, listing.recipe))
  if not package then
    career_modules_payment.reward({money = {amount = listing.price}}, {label = "Engine Package refund", tags = {"engineRetail", "refund"}})
    return {success = false, message = err}
  end
  removeListing(stock, index)
  career_saveSystem.saveCurrent()
  return {success = true, message = "The Engine Package was added to My Engine Packages.", packageId = package.id}
end

local function startInstall(listingId, options)
  options = options or {}; options.mode = "install"
  if not menuContext then return {success = false, message = "The engine shop is not open."} end
  local quote = getQuote(listingId, options)
  if not quote.success then return quote end
  local listing, stock, index = findListing(menuContext.shopId, listingId, menuContext.inventoryId)
  if not listing then return {success = false, message = "That engine is no longer available."} end
  if not riskAccepted(listing, options) then
    return {success = false, requiresRiskConfirmation = true,
      message = "Confirm that you accept the risk of an engine package that exceeds its declared stress limit."}
  end
  if not payment(quote.total, "Engine Package and installation") then return {success = false, message = "You cannot afford this engine swap."} end

  local before, oldInstalledId = {}, nil
  for _, package in ipairs(career_modules_enginePackages.listPackages({ownerType = "personal"})) do
    before[tostring(package.id)] = true
    if tonumber(package.installedInventoryId) == tonumber(menuContext.inventoryId) then oldInstalledId = tostring(package.id) end
  end
  local package, err = career_modules_enginePackages.clonePersonalPackageFromRecipe(quote.recipe,
    listing.name .. " Package", packageMetadata(listing, quote.recipe))
  if not package then
    career_modules_payment.reward({money = {amount = quote.total}}, {label = "Engine swap refund", tags = {"engineRetail", "refund"}})
    return {success = false, message = err}
  end

  local inventoryId, shopId, targetPackageId = menuContext.inventoryId, menuContext.shopId, tostring(package.id)
  local accepted, installError = career_modules_enginePackages.installPackageIntoVehicle(package.id, inventoryId, function(success, message)
    if not success then
      career_modules_payment.reward({money = {amount = quote.total}}, {label = "Engine swap refund", tags = {"engineRetail", "refund"}})
      career_modules_enginePackages.consumeStoredPersonalPackage(targetPackageId)
      local alreadyStocked = false
      for _, stocked in ipairs(stock.listings or {}) do
        if tostring(stocked.id) == tostring(listing.id) then alreadyStocked = true; break end
      end
      if not alreadyStocked then stock.listings[#stock.listings + 1] = listing end
      saveData()
      return
    end
    local outgoingId = oldInstalledId
    if not outgoingId then
      for _, candidate in ipairs(career_modules_enginePackages.listPackages({ownerType = "personal"})) do
        if tostring(candidate.id) ~= targetPackageId and not before[tostring(candidate.id)]
            and career_modules_enginePackages.getPackageStatus(candidate) == "stored" then outgoingId = tostring(candidate.id); break end
      end
    end
    state.jobs[tostring(inventoryId)] = {inventoryId = inventoryId, shopId = shopId, packageId = targetPackageId,
      outgoingPackageId = outgoingId, tradeIn = options.tradeIn == true, paidTotal = quote.total,
      listing = deepcopy(listing), status = "installing", remainingSeconds = quote.durationSeconds,
      totalSeconds = quote.durationSeconds, startedAtActive = state.activeSeconds}
    local vehicle = career_modules_inventory.getVehicles()[inventoryId]
    if vehicle then
      vehicle.timeToAccess = quote.durationSeconds
      vehicle.delayReason = "engineRetailInstall"
      vehicle.engineRetailJobId = tostring(inventoryId)
      career_modules_inventory.setVehicleDirty(inventoryId)
    end
    career_modules_inventory.removeVehicleObject(inventoryId, true)
    saveData(); career_saveSystem.saveCurrent()
    guihooks.trigger("toastrMsg", {type = "info", title = "Engine swap underway",
      msg = "Return to " .. tostring(shopsById[shopId] and shopsById[shopId].name or "the engine shop") .. " when the vehicle is ready."})
  end)
  if not accepted then
    -- A synchronous package failure already invokes the callback above. Only
    -- perform fallback cleanup when the target package still exists.
    if career_modules_enginePackages.getPackage(package.id) then
      career_modules_payment.reward({money = {amount = quote.total}}, {label = "Engine swap refund", tags = {"engineRetail", "refund"}})
      career_modules_enginePackages.consumeStoredPersonalPackage(package.id)
    end
    return {success = false, message = installError}
  end
  removeListing(stock, index)
  career_career.closeAllMenus()
  return {success = true, message = "The shop is starting the engine swap."}
end

local function vehicleBlocksSpot(spot)
  if not spot or not spot.pos then return true end
  local walkingVehicleId = gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking()
    and be:getPlayerVehicleID(0) or nil
  for _, vehicle in pairs(getAllVehicles() or {}) do
    if vehicle and vehicle:getID() ~= walkingVehicleId
        and (vehicle:getPosition() - vec3(spot.pos)):length() < 4 then return true end
  end
  return false
end

local function moveVehicleToSpot(inventoryId, spot, vehObj)
  local object = vehObj or getObjectByID(career_modules_inventory.getVehicleIdFromInventoryId(inventoryId))
  if object and spot and spot.moveResetVehicleTo then spot:moveResetVehicleTo(object:getID(), nil, nil, nil, nil, true) end
end

local function refreshPoiMarkers()
  if gameplay_rawPois and gameplay_rawPois.clear then gameplay_rawPois.clear() end
end

local function restoreListingForCancelledJob(job)
  local listing = job and job.listing
  local shop = job and shopsById[tostring(job.shopId)]
  if not listing or not shop or state.activeSeconds >= (tonumber(listing.expiresAtActive) or 0) then return end
  local stock = modelStock(shop, job.inventoryId)
  if not stock then return end
  for _, current in ipairs(stock.listings or {}) do
    if tostring(current.id) == tostring(listing.id) then return end
  end
  stock.listings[#stock.listings + 1] = listing
end

local function jobPackageGuard(package)
  if not package then return true end
  for _, job in pairs(state.jobs) do
    if not job.internalMutation and (tostring(job.packageId) == tostring(package.id)
        or tostring(job.outgoingPackageId or "") == tostring(package.id)) then
      return false, "This Engine Package is locked by an engine-shop work order."
    end
  end
  return true
end

local function cancelJob(inventoryId)
  inventoryId = tonumber(inventoryId)
  local job = state.jobs[tostring(inventoryId)]
  if not job then return {success = false, message = "That engine-shop work order no longer exists."} end
  if job.status == "cancelling" or job.status == "retrieving" then
    return {success = false, message = "That work order is already being finalized."}
  end
  local shop = shopsById[tostring(job.shopId)]
  local pickup = spotFor(shop, "pickupSpotName")
  if not pickup then return {success = false, message = "The pickup bay is not configured."} end
  if vehicleBlocksSpot(pickup) then return {success = false, message = "Move the vehicle blocking the pickup bay first."} end
  local vehicle = career_modules_inventory.getVehicles()[inventoryId]
  if not vehicle then return {success = false, message = "The vehicle in this work order no longer exists."} end

  job.previousStatus = job.status
  job.status = "cancelling"
  refreshPoiMarkers()
  vehicle.timeToAccess = nil
  vehicle.delayReason = nil
  career_modules_inventory.setVehicleDirty(inventoryId)

  local function cancellationFailed(message)
    if job.status ~= "cancelling" then return end
    job.internalMutation = nil
    job.status = job.previousStatus or "installing"
    job.previousStatus = nil
    vehicle.timeToAccess = job.status == "ready" and 1 or math.max(1, tonumber(job.remainingSeconds) or 1)
    vehicle.delayReason = job.status == "ready" and "engineRetailPickup" or "engineRetailInstall"
    career_modules_inventory.setVehicleDirty(inventoryId)
    career_modules_inventory.removeVehicleObject(inventoryId, true)
    refreshPoiMarkers()
    saveData(); career_saveSystem.saveCurrent()
    guihooks.trigger("toastrMsg", {type = "error", title = "Cancellation failed", msg = message or "The original engine could not be restored."})
  end

  local function cancellationComplete(success, message)
    if job.status ~= "cancelling" then return end
    if not success then cancellationFailed(message) return end
    -- Keep the internal mutation exemption active from reversion through
    -- cleanup; public package and vehicle operations remain forbidden.
    job.internalMutation = true
    local removed, removeError = career_modules_enginePackages.consumeStoredPersonalPackage(job.packageId)
    job.internalMutation = nil
    if not removed then cancellationFailed(removeError) return end
    career_modules_payment.reward({money = {amount = math.max(0, tonumber(job.paidTotal) or 0)}},
      {label = "Cancelled engine-shop work order", tags = {"engineRetail", "refund"}})
    restoreListingForCancelledJob(job)
    vehicle.timeToAccess = nil; vehicle.delayReason = nil; vehicle.engineRetailJobId = nil
    state.jobs[tostring(inventoryId)] = nil
    career_modules_inventory.setVehicleDirty(inventoryId)
    moveVehicleToSpot(inventoryId, pickup)
    refreshPoiMarkers()
    saveData(); career_saveSystem.saveCurrent()
    guihooks.trigger("toastrMsg", {type = "success", title = "Work order cancelled",
      msg = "The original engine was restored and the purchase was refunded."})
  end

  local function beginReversion()
    job.internalMutation = true
    local accepted, err
    if job.outgoingPackageId then
      accepted, err = career_modules_enginePackages.installPackageIntoVehicle(job.outgoingPackageId, inventoryId, cancellationComplete)
    else
      accepted, err = career_modules_enginePackages.storePackageFromVehicle(job.packageId, inventoryId, cancellationComplete)
    end
    if not accepted then cancellationFailed(err) end
  end

  local spawned = career_modules_inventory.spawnVehicle(inventoryId, nil, function() beginReversion() end)
  if not spawned then
    cancellationFailed("The vehicle could not be prepared for cancellation.")
    return {success = false, message = "The vehicle could not be prepared for cancellation."}
  end
  saveData()
  return {success = true, message = "Cancellation started. The original configuration is being restored."}
end

local function retrieveVehicle(inventoryId)
  inventoryId = tonumber(inventoryId)
  local job = state.jobs[tostring(inventoryId)]
  if not job or job.status ~= "ready" then return {success = false, message = "That vehicle is not ready for pickup."} end
  local shop, vehicle = shopsById[tostring(job.shopId)], career_modules_inventory.getVehicles()[inventoryId]
  local spot = spotFor(shop, "pickupSpotName")
  if not spot then return {success = false, message = "The pickup bay is not configured."} end
  if vehicleBlocksSpot(spot) then return {success = false, message = "Move the vehicle blocking the pickup bay first."} end
  job.status = "retrieving"
  refreshPoiMarkers()
  if vehicle then vehicle.timeToAccess = nil; vehicle.delayReason = nil end
  local spawned = career_modules_inventory.spawnVehicle(inventoryId, nil, function(vehObj)
    moveVehicleToSpot(inventoryId, spot, vehObj)
  end)
  if not spawned then
    job.status = "ready"
    if vehicle then vehicle.timeToAccess = 1; vehicle.delayReason = "engineRetailPickup" end
    refreshPoiMarkers()
    return {success = false, message = "The vehicle could not be spawned in the pickup bay."}
  end
  if job.tradeIn and job.outgoingPackageId then
    job.internalMutation = true
    local consumed, consumeError = career_modules_enginePackages.consumeStoredPersonalPackage(job.outgoingPackageId)
    job.internalMutation = nil
    if not consumed then
      job.status = "ready"
      if vehicle then vehicle.timeToAccess = 1; vehicle.delayReason = "engineRetailPickup" end
      career_modules_inventory.removeVehicleObject(inventoryId, true)
      refreshPoiMarkers()
      return {success = false, message = consumeError or "The outgoing engine trade-in could not be finalized."}
    end
  end
  if vehicle then vehicle.engineRetailJobId = nil end
  state.jobs[tostring(inventoryId)] = nil
  career_modules_inventory.setVehicleDirty(inventoryId)
  refreshPoiMarkers()
  saveData(); career_saveSystem.saveCurrent()
  guihooks.trigger("toastrMsg", {type = "success", title = "Vehicle retrieved", msg = "Your vehicle is waiting in the pickup bay."})
  return {success = true, message = "Your vehicle is waiting in the pickup bay."}
end

local function jobsForShop(shop)
  local jobs = {}
  for _, job in pairs(state.jobs) do
    if tostring(job.shopId) == tostring(shop.id) then
      local copy = deepcopy(job); copy.listing = nil
      local vehicle = career_modules_inventory.getVehicles()[tonumber(job.inventoryId)]
      copy.vehicleName = vehicle and (vehicle.niceName or vehicle.name) or ("Vehicle #" .. tostring(job.inventoryId))
      jobs[#jobs + 1] = copy
    end
  end
  table.sort(jobs, function(a, b) return tonumber(a.inventoryId) < tonumber(b.inventoryId) end)
  return jobs
end

local function certificationSummary(certification)
  if not certification then return nil end
  return {
    status = certification.status,
    submittedAtActive = certification.submittedAtActive,
    readyAtActive = certification.readyAtActive,
    completedAtActive = certification.completedAtActive
  }
end

local function certifiablePackages()
  local result = {}
  for _, package in ipairs(career_modules_enginePackages.listPackages({ownerType = "personal"})) do
    if career_modules_enginePackages.getPackageStatus(package) == "stored" then
      local cert = package.engineShopCertification
      if not cert or cert.status ~= "passed" then
        local value = career_modules_enginePackages.getFreshPackageValue(package)
        if value or (cert and cert.status == "pending") then
          result[#result + 1] = {id = tostring(package.id), name = package.name,
            certification = certificationSummary(cert), estimatedFee = value and math.max(1, math.floor(value * 0.10 + 0.5)) or nil,
            canStart = not cert or cert.status ~= "pending" and cert.status ~= "failed"}
        end
      end
    end
  end
  table.sort(result, function(a, b) return string.lower(a.name or "") < string.lower(b.name or "") end)
  return result
end

local function requestData()
  if not menuContext then return {success = false, message = "The engine shop is not open."} end
  local shop = shopsById[tostring(menuContext.shopId)]
  menuContext.inventoryId = parkedOwnedVehicle(shop)
  local listings = {}
  local err
  if menuContext.inventoryId then
    local stock
    stock, err = refreshStock(shop, menuContext.inventoryId)
    for _, listing in ipairs(stock and stock.listings or {}) do
      local copy = deepcopy(listing); copy.recipe = nil; copy.certification = nil; copy.inspection = nil
      copy.remainingSeconds = math.max(0, (listing.expiresAtActive or state.activeSeconds) - state.activeSeconds)
      listings[#listings + 1] = copy
    end
    table.sort(listings, function(a, b)
      local categoryOrder = {factory = 1, aftermarket = 2}
      local categoryA = categoryOrder[a.category] or math.huge
      local categoryB = categoryOrder[b.category] or math.huge
      if categoryA ~= categoryB then return categoryA < categoryB end
      local reliabilityA = reliabilityOrder[a.reliability] or math.huge
      local reliabilityB = reliabilityOrder[b.reliability] or math.huge
      if reliabilityA ~= reliabilityB then return reliabilityA < reliabilityB end
      local priceA, priceB = tonumber(a.price) or math.huge, tonumber(b.price) or math.huge
      if priceA ~= priceB then return priceA < priceB end
      local nameA, nameB = string.lower(tostring(a.name or "")), string.lower(tostring(b.name or ""))
      if nameA ~= nameB then return nameA < nameB end
      local mileageA, mileageB = tonumber(a.mileage) or math.huge, tonumber(b.mileage) or math.huge
      if mileageA ~= mileageB then return mileageA < mileageB end
      return tostring(a.id or "") < tostring(b.id or "")
    end)
  end
  local vehicle = menuContext.inventoryId and career_modules_inventory.getVehicles()[menuContext.inventoryId] or nil
  local swapReady, swapBlockedReason = true, nil
  if vehicle then swapReady, swapBlockedReason = vehicleReadyForEngineSwap(menuContext.inventoryId) end
  return {success = true, shop = deepcopy(shop), inventoryId = menuContext.inventoryId,
    vehicle = vehicle and {id = menuContext.inventoryId, model = vehicle.model, niceName = vehicle.niceName or vehicle.name,
      engineSwapBlockedReason = not swapReady and swapBlockedReason or nil} or nil,
    listings = listings, jobs = jobsForShop(shop), certifiablePackages = certifiablePackages(),
    message = err}
end

local function requestStatus()
  if not menuContext then return {success = false, message = "The engine shop is not open."} end
  local shop = shopsById[tostring(menuContext.shopId)]
  local stressTests = {}
  for _, package in ipairs(career_modules_enginePackages.listPackages({ownerType = "personal"})) do
    local cert = package.engineShopCertification
    if cert then stressTests[#stressTests + 1] = {id = tostring(package.id), certification = certificationSummary(cert)} end
  end
  return {success = true, jobs = jobsForShop(shop), stressTests = stressTests}
end

parkedOwnedVehicle = function(shop)
  local spot = spotFor(shop, "serviceSpotName")
  if not spot or not spot.pos then return nil end
  local bestId, bestDistance
  for inventoryId, vehicle in pairs(career_modules_inventory.getVehicles() or {}) do
    local vehId = career_modules_inventory.getVehicleIdFromInventoryId(tonumber(inventoryId))
    local object = vehId and getObjectByID(vehId)
    local distance = object and (object:getPosition() - vec3(spot.pos)):length() or math.huge
    if vehicle.owned == true and not vehicle.timeToAccess and distance <= 5
        and (not bestDistance or distance < bestDistance) then
      bestId, bestDistance = tonumber(inventoryId), distance
    end
  end
  return bestId
end

local function openShop(shopId)
  local shop = shopsById[tostring(shopId)]
  if not shop then return false end
  local inventoryId = parkedOwnedVehicle(shop)
  local vehicle = inventoryId and career_modules_inventory.getVehicles()[inventoryId]
  menuContext = {shopId = tostring(shop.id), inventoryId = tonumber(inventoryId)}
  if vehicle then refreshStock(shop, inventoryId, false) end
  guihooks.trigger("ChangeState", {state = "career.engineRetail"})
  return true
end

local function startCertification(packageId)
  if not menuContext then return {success = false, message = "Open an engine shop first."} end
  return career_modules_engineCertification.startPersonalCertification(packageId, menuContext.shopId)
end

local function onUpdate(dtReal)
  if not (career_career and career_career.isActive()) then return end
  if isPaused() then return end
  local elapsed = math.max(0, tonumber(dtReal) or 0)
  state.activeSeconds = state.activeSeconds + elapsed
  updateAccumulator = updateAccumulator + elapsed
  if updateAccumulator < 1 then return end
  local tick = updateAccumulator; updateAccumulator = 0
  for inventoryId, job in pairs(state.jobs) do
    if job.status == "installing" then
      job.remainingSeconds = math.max(0, (tonumber(job.remainingSeconds) or 0) - tick)
      local vehicle = career_modules_inventory.getVehicles()[tonumber(inventoryId)]
      if vehicle then vehicle.timeToAccess = math.max(1, job.remainingSeconds); career_modules_inventory.setVehicleDirty(tonumber(inventoryId)) end
      if job.remainingSeconds <= 0 then
        job.status = "ready"
        if vehicle then vehicle.timeToAccess = 1; vehicle.delayReason = "engineRetailPickup" end
        refreshPoiMarkers()
        guihooks.trigger("toastrMsg", {type = "success", title = "Engine swap complete",
          msg = "Return to " .. tostring(shopsById[tostring(job.shopId)] and shopsById[tostring(job.shopId)].name or "the engine shop") .. " to retrieve your vehicle."})
        saveData(); career_saveSystem.saveCurrent()
      end
    end
  end
end

function M.onGetRawPoiListForLevel(levelIdentifier, elements)
  if not (career_career and career_career.isActive()) then return end
  for _, shop in pairs(shopsById) do
    if tostring(shop.mapId or "west_coast_usa") ~= tostring(levelIdentifier) then goto continue end
    local spot = spotFor(shop, "serviceSpotName")
    if spot and spot.pos then
      table.insert(elements, {id = "engineRetail-" .. tostring(shop.id),
        data = {type = "engineRetail", shopId = tostring(shop.id), name = shop.name},
        markerInfo = {inspectVehicleMarker = {pos = vec3(spot.pos), radius = 6, vehicleHeight = 4},
          bigmapMarker = {pos = vec3(spot.pos), icon = "poi_engine_round", name = shop.name,
            description = shop.description, cardIcon = "engine"}, clusterType = "activity"},
        pos = vec3(spot.pos), radius = 6})
    end
    for inventoryId, job in pairs(state.jobs) do
      if tostring(job.shopId) == tostring(shop.id) and job.status == "ready" then
        local pickup = spotFor(shop, "pickupSpotName")
        if pickup and pickup.pos then
          table.insert(elements, {id = "engineRetailPickup-" .. tostring(inventoryId),
            data = {type = "engineRetailPickup", shopId = tostring(shop.id), inventoryId = tonumber(inventoryId), name = shop.name},
            markerInfo = {inspectVehicleMarker = {pos = vec3(pickup.pos), radius = 6, vehicleHeight = 4}},
            pos = vec3(pickup.pos), radius = 6})
        end
      end
    end
    ::continue::
  end
end

function M.onActivityAcceptGatherData(elemData, activityData)
  for _, elem in ipairs(elemData or {}) do
    if elem.type == "engineRetail" then
      table.insert(activityData, {icon = "engine", heading = elem.name, preheadings = {"Engine Retailer"},
        sorting = {type = elem.type, id = elem.shopId}, startable = true, buttonLabel = "View Engine Inventory",
        buttonFun = function() openShop(elem.shopId) end})
    elseif elem.type == "engineRetailPickup" then
      table.insert(activityData, {icon = "keys1", heading = elem.name .. " Pickup", preheadings = {"Vehicle Ready"},
        sorting = {type = elem.type, id = elem.inventoryId}, startable = true, buttonLabel = "Retrieve Vehicle",
        buttonFun = function()
          local result = retrieveVehicle(elem.inventoryId)
          if not result.success then guihooks.trigger("toastrMsg", {type = "error", title = "Vehicle pickup", msg = result.message}) end
        end})
    end
  end
end

function M.onCheckPermission(tags, permissions, additionalData)
  local inventoryId = additionalData and tonumber(additionalData.inventoryId)
  local job = inventoryId and state.jobs[tostring(inventoryId)]
  if not job or job.internalMutation then return end
  local blocked = {vehicleSelling = true, vehicleRepair = true, vehicleStoring = true, partSwapping = true,
    partBuying = true, tuning = true, painting = true, vehicleModification = true, vehicleLicensePlate = true,
    junkVehicle = true, recoveryTowToGarage = true, interactMission = true}
  for _, tag in ipairs(tags or {}) do
    if blocked[tag] then
      table.insert(permissions, {permission = "forbidden", label = "This vehicle is locked by an engine-shop work order."})
    end
  end
end

local function initialize()
  if initialized then return end
  initialized = true
  loadShopDefinitions(); loadData()
  career_modules_enginePackages.registerPackageReferenceGuard(jobPackageGuard)
end

local function onExtensionLoaded()
  loadShopDefinitions()
  if career_career and career_career.isActive and career_career.isActive() then initialize() end
end

M.openShop = openShop
M.requestData = requestData
M.requestStatus = requestStatus
M.getQuote = getQuote
M.purchaseLoose = purchaseLoose
M.startInstall = startInstall
M.retrieveVehicle = retrieveVehicle
M.cancelJob = cancelJob
M.startCertification = startCertification
M.debugClearStock = function(shopId)
  state.shops[tostring(shopId or "")] = nil
  recipeCache = {}
  analysisCache = {}
  valueCache = {}
  saveData()
  return true
end
M.onCareerActivated = initialize
M.onCareerModulesActivated = initialize
M.onExtensionLoaded = onExtensionLoaded
M.onSaveCurrentProfile = function(path) saveData(path) end
M.onUpdate = onUpdate

return M
