local M = {}

M.dependencies = {
  "career_career",
  "career_saveSystem",
  "career_modules_inventory",
  "career_modules_partInventory",
  "career_modules_computer",
  "career_modules_garageManager",
  "career_modules_permissions",
  "career_modules_playerAttributes",
  "career_modules_valueCalculator",
  "career_modules_business_businessPartInventory"
}

local jbeamIO = require("jbeam/io")
local jbeamSlotSystem = require("jbeam/slotSystem")

local logTag = "enginePackages"
local saveVersion = 2
local saveRelativePath = "/career/rls_career/enginePackages.json"
local thumbnailRelativeDir = "/career/rls_career/enginePackages/"
local thumbnailCaptureVersion = 5

local packages = {}
local nextPackageId = 1
local menuOpen = false
local currentInventoryId
local originComputerId
local originBusinessContext
local transactionBusy = false
local activeTransactionId = 0

local function beginTransaction()
  activeTransactionId = activeTransactionId + 1
  transactionBusy = true
  return activeTransactionId
end

local function isActiveTransaction(transactionId)
  return transactionId ~= nil and transactionId == activeTransactionId
end

local function endTransaction(transactionId)
  if not isActiveTransaction(transactionId) then return false end
  transactionBusy = false
  return true
end
local activeInstallCallback
local loaded = false
local getPackageStatus
local packageReferenceGuards = {}
local authoredPartValueCache = {}
local computeRecipeSignature
local refreshCertificationValidity
local getInventoryForPackage
local getPartIdsFromPackageTree

local function countTableEntries(value)
  local count = 0
  for _ in pairs(value or {}) do
    count = count + 1
  end
  return count
end

local function trim(value)
  if type(value) ~= "string" then return "" end
  return value:match("^%s*(.-)%s*$") or ""
end

-- Part valuation uses the real calendar year as its age reference. Factory
-- engines therefore need a production year of their own; using the donor
-- vehicle's model year makes a newly-built engine look decades old.
local function getCurrentManufacturingYear()
  local date = os.date("*t") or {}
  return math.max(1, math.floor(tonumber(date.year) or tonumber(os.date("%Y")) or 2026))
end

local function markPartAsManufactured(part, manufacturedYear, factoryPackageId)
  if not part then return false end
  manufacturedYear = math.max(1, math.floor(tonumber(part.manufacturedYear) or tonumber(manufacturedYear)
    or getCurrentManufacturingYear()))
  local changed = part.year ~= manufacturedYear or part.manufacturedYear ~= manufacturedYear
    or part.engineShopManufactured ~= true or tostring(part.factoryPackageId or "") ~= tostring(factoryPackageId or "")
  part.year = manufacturedYear
  part.manufacturedYear = manufacturedYear
  part.engineShopManufactured = true
  part.factoryPackageId = tostring(factoryPackageId or part.factoryPackageId or "")
  part.tags = type(part.tags) == "table" and part.tags or {}
  part.tags.engineShopManufactured = true
  part.tags.manufacturedYear = manufacturedYear
  part.tags.factoryPackageId = part.factoryPackageId
  return changed
end

local function markPackageAsManufactured(package, manufacturedYear)
  if not package then return false end
  manufacturedYear = math.max(1, math.floor(tonumber(package.manufacturedYear) or tonumber(manufacturedYear)
    or getCurrentManufacturingYear()))
  local changed = package.manufacturedYear ~= manufacturedYear or package.engineShopManufactured ~= true
  package.manufacturedYear = manufacturedYear
  package.engineShopManufactured = true
  local inventory = getInventoryForPackage and getInventoryForPackage(package) or nil
  if inventory then
    for _, partId in ipairs(getPartIdsFromPackageTree and getPartIdsFromPackageTree(package.tree) or {}) do
      changed = markPartAsManufactured(inventory[tonumber(partId) or partId], manufacturedYear, package.id) or changed
    end
  end
  return changed
end

local function getCurrentSavePath()
  local _, savePath = career_saveSystem.getCurrentProfile()
  return savePath
end

local function normalizeSavePath(savePath)
  savePath = savePath or getCurrentSavePath()
  if not savePath then return nil end
  if savePath:sub(1, 1) ~= "/" then
    savePath = "/" .. savePath
  end
  return savePath
end

local function ensureSaveDirectory(filePath)
  local dirPath = filePath and filePath:match("^(.*)/[^/]+$")
  if dirPath and not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath, true)
  end
end

local function getPackageThumbnailDiskPath(packageId, savePath)
  savePath = savePath or getCurrentSavePath()
  if not savePath or not packageId then return nil end
  return savePath .. thumbnailRelativeDir .. tostring(packageId) .. ".jpg"
end

local function getPackageThumbnailUiPath(packageId, savePath)
  local filePath = getPackageThumbnailDiskPath(packageId, savePath)
  return filePath and normalizeSavePath(filePath) or nil
end

local function packageThumbnailExists(packageId)
  local diskPath = getPackageThumbnailDiskPath(packageId)
  local uiPath = getPackageThumbnailUiPath(packageId)
  return (diskPath and FS:fileExists(diskPath)) or (uiPath and FS:fileExists(uiPath)) or false
end

local function getPackageThumbnailPath(packageId, savePath)
  if not packageThumbnailExists(packageId) then return nil end
  return getPackageThumbnailUiPath(packageId, savePath)
end

local function deletePackageThumbnail(packageId)
  local diskPath = getPackageThumbnailDiskPath(packageId)
  local uiPath = getPackageThumbnailUiPath(packageId)
  if diskPath and FS:fileExists(diskPath) then FS:removeFile(diskPath) end
  if uiPath and uiPath ~= diskPath and FS:fileExists(uiPath) then FS:removeFile(uiPath) end
end

local function saveData(currentSavePath)
  currentSavePath = currentSavePath or getCurrentSavePath()
  if not currentSavePath then return false end

  local filePath = currentSavePath .. saveRelativePath
  ensureSaveDirectory(filePath)
  jsonWriteFile(filePath, {
    version = saveVersion,
    nextPackageId = nextPackageId,
    packages = packages
  }, true)
  return true
end

local function getPartInventory()
  return career_modules_partInventory and career_modules_partInventory.getInventory and
    career_modules_partInventory.getInventory() or {}
end

local function isBusinessPackage(package)
  return package and package.ownerType == "business"
end

getInventoryForPackage = function(package)
  if isBusinessPackage(package) then
    return career_modules_business_businessPartInventory
      and career_modules_business_businessPartInventory.getInventory
      and career_modules_business_businessPartInventory.getInventory() or {}
  end
  return getPartInventory()
end

local function restoreTable(target, snapshot)
  table.clear(target)
  for key, value in pairs(snapshot or {}) do
    target[key] = deepcopy(value)
  end
end

local function getPackageById(packageId)
  packageId = tostring(packageId or "")
  for _, package in ipairs(packages) do
    if tostring(package.id) == packageId then
      return package
    end
  end
end

getPartIdsFromPackageTree = function(node, result)
  result = result or {}
  if not node then return result end
  if node.partId then
    table.insert(result, tonumber(node.partId) or node.partId)
  end
  for _, child in pairs(node.children or {}) do
    getPartIdsFromPackageTree(child, result)
  end
  return result
end

local function packageTreeContainsPartId(node, partId)
  if not node or partId == nil then return false end
  if tostring(node.partId or "") == tostring(partId) then return true end
  for _, child in pairs(node.children or {}) do
    if packageTreeContainsPartId(child, partId) then return true end
  end
  return false
end

local function clearPackageFlags(package)
  local inventory = getInventoryForPackage(package)
  for _, partId in ipairs(getPartIdsFromPackageTree(package and package.tree)) do
    local part = inventory[partId]
    if part and tostring(part.enginePackageId or "") == tostring(package.id) then
      part.enginePackageId = nil
      part.mainPart = part.containingSlot == "/"
    end
  end
end

local function removePackage(packageId, clearFlags)
  packageId = tostring(packageId or "")
  for index, package in ipairs(packages) do
    if tostring(package.id) == packageId then
      if clearFlags then clearPackageFlags(package) end
      table.remove(packages, index)
      return package
    end
  end
end

local function repairPackageFlags()
  local inventory = getPartInventory()
  local validPackageIds = {}
  for _, package in ipairs(packages) do
    validPackageIds[tostring(package.id)] = true
  end

  for _, part in pairs(inventory) do
    local packageId = part.enginePackageId and tostring(part.enginePackageId)
    if packageId and not validPackageIds[packageId] then
      -- Keep the former package ID just long enough for the Engine Works state
      -- to identify and repair factory parts from saves made before production
      -- provenance was persisted.
      part.orphanedEnginePackageId = packageId
      part.enginePackageId = nil
      part.mainPart = part.containingSlot == "/"
    end
  end

  for _, package in ipairs(packages) do
    local packageInventory = getInventoryForPackage(package)
    for _, partId in ipairs(getPartIdsFromPackageTree(package.tree)) do
      local part = packageInventory[partId]
      if part then
        part.enginePackageId = tostring(package.id)
        part.mainPart = true
        if package.engineShopManufactured == true then
          markPartAsManufactured(part, package.manufacturedYear, package.id)
        end
      end
    end
    if getPackageStatus then
      local status, installedInventoryId = getPackageStatus(package)
      if status == "installed" then package.installedInventoryId = installedInventoryId end
      if status == "stored" then package.installedInventoryId = nil end
    end
  end
end

local function loadData()
  packages = {}
  nextPackageId = 1

  local savePath = getCurrentSavePath()
  local filePath = savePath and (savePath .. saveRelativePath)
  local data = filePath and FS:fileExists(filePath) and jsonReadFile(filePath) or nil
  if type(data) == "table" and type(data.packages) == "table" then
    packages = data.packages
    nextPackageId = math.max(tonumber(data.nextPackageId) or 1, 1)
  end

  for _, package in ipairs(packages) do
    package.id = tostring(package.id)
    package.ownerType = package.ownerType or "personal"
    local numericId = tonumber(package.id)
    if numericId then
      nextPackageId = math.max(nextPackageId, numericId + 1)
    end
  end

  repairPackageFlags()
  loaded = true
end

local function getSpawnedVehicleObject(inventoryId)
  local vehId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
  return vehId and getObjectByID(vehId), vehId
end

local function getRuntimeVehicleData(inventoryId)
  local vehObj, vehId = getSpawnedVehicleObject(inventoryId)
  if not vehObj or not vehId then return nil, nil, nil end
  return extensions.core_vehicle_manager.getVehicleData(vehId), vehObj, vehId
end

local function pathDepth(path)
  local depth = 0
  for _ in string.gmatch(path or "", "[^/]+") do depth = depth + 1 end
  return depth
end

local function jbeamHasDeviceType(partData, deviceType)
  if type(partData) ~= "table" then return false end
  local target = string.lower(deviceType)
  local function walk(value)
    if type(value) == "string" then
      -- Substring match so "classic_combustionEngine" matches "combustionEngine".
      return string.find(string.lower(value), target, 1, true) ~= nil
    end
    if type(value) ~= "table" then return false end
    for _, child in pairs(value) do
      if walk(child) then return true end
    end
    return false
  end
  return walk(partData.powertrain)
end

local function partIsCombustionEngine(ioCtx, partName)
  if not partName or partName == "" or not ioCtx then return false end
  return jbeamHasDeviceType(jbeamIO.getPart(ioCtx, partName), "combustionEngine")
end

local function partIsElectricMotor(ioCtx, partName)
  if not partName or partName == "" or not ioCtx then return false end
  return jbeamHasDeviceType(jbeamIO.getPart(ioCtx, partName), "electricMotor")
end

local function nodePartName(node)
  return node and (node.chosenPartName or node.name) or nil
end

local function subtreeContainsCombustionEngine(node, ioCtx)
  if not node then return false end
  if partIsCombustionEngine(ioCtx, nodePartName(node)) then return true end
  for _, child in pairs(node.children or {}) do
    if subtreeContainsCombustionEngine(child, ioCtx) then return true end
  end
  return false
end

local function findCombustionEnginePartName(node, ioCtx)
  if not node then return nil end
  local partName = nodePartName(node)
  if partIsCombustionEngine(ioCtx, partName) then return partName end
  for _, child in pairs(node.children or {}) do
    local found = findCombustionEnginePartName(child, ioCtx)
    if found then return found end
  end
end

local function collectPowertrainFlags(tree, ioCtx)
  local hasCombustion, hasElectric = false, false
  local function visit(node)
    if not node then return end
    local name = node.chosenPartName
    if name and name ~= "" then
      if partIsCombustionEngine(ioCtx, name) then hasCombustion = true end
      if partIsElectricMotor(ioCtx, name) then hasElectric = true end
    end
    for _, child in pairs(node.children or {}) do visit(child) end
  end
  visit(tree)
  return hasCombustion, hasElectric
end

local function vehicleIsElectric(inventoryId)
  local vehicle = inventoryId and career_modules_inventory.getVehicles()[inventoryId]
  local fuel = vehicle and vehicle.certificationData and vehicle.certificationData.fuelType
  if type(fuel) == "string" and string.find(string.lower(fuel), "electric", 1, true) then
    return true
  end
  if type(fuel) == "table" then
    local hasLiquid = fuel["fuelTank:gasoline"] or fuel["fuelTank:diesel"]
    if fuel["fuelTank:electric"] and not hasLiquid then return true end
  end

  local runtimeData = getRuntimeVehicleData(inventoryId)
  if not runtimeData or not runtimeData.config then return false end
  local hasCombustion, hasElectric = collectPowertrainFlags(runtimeData.config.partsTree, runtimeData.ioCtx)
  if hasCombustion then return false end
  return hasElectric
end

local function findEngineCandidates(tree, includeEmpty, ioCtx)
  local candidates = {}

  local function visit(node, parentPartName)
    if not node then return end
    for slotName, child in pairs(node.children or {}) do
      local lowerSlot = string.lower(slotName)
      local hasInstalledPart = child and child.chosenPartName and child.chosenPartName ~= ""
      local looksLikeEngineSlot = child and string.find(lowerSlot, "engine", 1, true)
        and not string.find(lowerSlot, "electric", 1, true)
      -- Adapter packs such as CEEP attach a wrapper to the vehicle's real
      -- engine slot, then put the combustion engine one or more slots below
      -- it. The package root must remain at that outer attachment surface or
      -- standard and wrapped engines can never replace one another.
      local containsCombustion = hasInstalledPart and subtreeContainsCombustionEngine(child, ioCtx)
      local include = looksLikeEngineSlot and (containsCombustion or (includeEmpty and not hasInstalledPart))
      if include then
        table.insert(candidates, {
          node = child,
          slotName = slotName,
          path = child.path or ((node.path or "/") .. slotName .. "/"),
          parentPartName = node.chosenPartName,
          combustionPartName = containsCombustion and findCombustionEnginePartName(child, ioCtx) or nil
        })
      else
        -- Once an engine assembly root is found, do not expose any nested
        -- adapter slots as independent vehicle compatibility surfaces.
        visit(child, child.chosenPartName or parentPartName)
      end
    end
  end

  visit(tree, tree and tree.chosenPartName)
  table.sort(candidates, function(a, b)
    local depthA, depthB = pathDepth(a.path), pathDepth(b.path)
    if depthA ~= depthB then return depthA < depthB end
    return tostring(a.path) < tostring(b.path)
  end)
  return candidates
end

local function nodePartName(node)
  if not node then return nil end
  local name = node.chosenPartName
  if name and name ~= "" then return name end
  name = node.name
  if name and name ~= "" then return name end
  return nil
end

local function isCeepHubNode(node, ioCtx)
  local partName = nodePartName(node)
  if not partName then return false end
  if partIsCombustionEngine(ioCtx, partName) then return false end
  local function hasCombustionDescendant(partNode)
    for _, child in pairs(partNode.children or {}) do
      local childName = nodePartName(child)
      if childName and partIsCombustionEngine(ioCtx, childName) then
        return true
      end
      if hasCombustionDescendant(child) then return true end
    end
    return false
  end
  return hasCombustionDescendant(node)
end

local function findEngineBaySlots(tree, ioCtx)
  local bays = {}

  local function visit(node)
    if not node then return end
    for slotName, child in pairs(node.children or {}) do
      local lowerSlot = string.lower(slotName)
      if child and string.find(lowerSlot, "engine", 1, true) and not string.find(lowerSlot, "electric", 1, true) then
        table.insert(bays, {
          node = child,
          slotName = slotName,
          path = child.path or ((node.path or "/") .. slotName .. "/"),
          parentPartName = node.chosenPartName,
          isBay = true
        })
      else
        visit(child)
      end
    end
  end

  visit(tree)
  table.sort(bays, function(a, b)
    local depthA, depthB = pathDepth(a.path), pathDepth(b.path)
    if depthA ~= depthB then return depthA < depthB end
    return tostring(a.path) < tostring(b.path)
  end)
  return bays
end

local function getPrimaryEngine(tree, ioCtx)
  return findEngineCandidates(tree, false, ioCtx)[1]
end

local function resolveEngineCaptureAnchor(tree, ioCtx)
  local primary = getPrimaryEngine(tree, ioCtx)
  if not primary then return nil end
  for _, bay in ipairs(findEngineBaySlots(tree, ioCtx)) do
    if string.find(primary.path, bay.path, 1, true) == 1 and isCeepHubNode(bay.node, ioCtx) then
      return bay
    end
  end
  return primary
end

local function partNameLooksLikeCeepHub(partName)
  if not partName or partName == "" then return false end
  return string.find(string.lower(partName), "^classic_.-_engines$") ~= nil
end

local function partProvidesEngineMount(partData)
  if type(partData) ~= "table" then return false end
  if type(partData.slots) == "table" then
    for _, slot in ipairs(partData.slots) do
      local slotType = type(slot[1]) == "string" and string.lower(slot[1]) or ""
      if string.find(slotType, "engine", 1, true) then
        return true
      end
    end
  end
  if type(partData.slots2) == "table" then
    for _, slot in ipairs(partData.slots2) do
      if type(slot) == "table" then
        local slotType = slot.type or slot[1]
        if type(slotType) == "string" and string.find(string.lower(slotType), "engine", 1, true) then
          return true
        end
        local allowTypes = slot.allowTypes or slot[2]
        if type(allowTypes) == "table" then
          for _, allowType in ipairs(allowTypes) do
            if type(allowType) == "string" and string.find(string.lower(allowType), "engine", 1, true) then
              return true
            end
          end
        end
      end
    end
  end
  return false
end

local function parentIsCeepHub(parentPartName, ioCtx)
  if not parentPartName or parentPartName == "" or not ioCtx then return false end
  if partIsCombustionEngine(ioCtx, parentPartName) then return false end
  if partNameLooksLikeCeepHub(parentPartName) then return true end
  local partData = jbeamIO.getPart(ioCtx, parentPartName)
  if not partData then return false end
  local slotType = string.lower(partData.slotType or "")
  if string.find(slotType, "classic_", 1, true) and string.find(slotType, "engines", 1, true) then
    return true
  end
  return string.find(slotType, "engine", 1, true) ~= nil and partProvidesEngineMount(partData)
end

local function packageUsesCeepMount(package, ioCtx)
  if not ioCtx or not package.tree then return false end
  if package.tree.name and partIsCombustionEngine(ioCtx, package.tree.name) then
    return false
  end
  if package.tree.name and partNameLooksLikeCeepHub(package.tree.name) then
    return true
  end
  if isCeepHubNode({name = package.tree.name, children = package.tree.children or {}}, ioCtx) then
    return true
  end
  return false
end

local function packageTreesStructurallyMatch(expected, actual)
  if not expected or not actual then return false end
  if tostring(expected.partId) ~= tostring(actual.partId) then return false end
  for slotName, expectedChild in pairs(expected.children or {}) do
    local actualChild = (actual.children or {})[slotName]
    if not actualChild or not packageTreesStructurallyMatch(expectedChild, actualChild) then
      return false
    end
  end
  return true
end

local function packageTreesFullyMatch(expected, actual)
  if not expected or not actual then return false end
  if tostring(expected.partId) ~= tostring(actual.partId) then return false end
  if tostring(expected.name or "") ~= tostring(actual.name or "") then return false end
  local expectedChildren = expected.children or {}
  local actualChildren = actual.children or {}
  local expectedCount, actualCount = 0, 0
  for slotName, expectedChild in pairs(expectedChildren) do
    expectedCount = expectedCount + 1
    local actualChild = actualChildren[slotName]
    if not actualChild or not packageTreesFullyMatch(expectedChild, actualChild) then
      return false
    end
  end
  for _ in pairs(actualChildren) do
    actualCount = actualCount + 1
  end
  return expectedCount == actualCount
end

local function installedPackageTreeMatches(packageTree, captureTree)
  if not packageTree or not captureTree then return false end
  if packageTreesStructurallyMatch(packageTree, captureTree) then return true end
  local function walk(node)
    if packageTreesStructurallyMatch(packageTree, node) then return true end
    for _, child in pairs(node.children or {}) do
      if walk(child) then return true end
    end
    return false
  end
  return walk(captureTree)
end

local function getDescriptionText(description, fallback)
  if type(description) == "string" then return description end
  if type(description) == "table" then
    if type(description.description) == "string" then return description.description end
    if type(description.description) == "table" then
      return getDescriptionText(description.description, fallback)
    end
    if type(description.name) == "string" then return description.name end
  end
  return fallback
end

local function getPartNiceName(ioCtx, partName)
  local availableParts = ioCtx and jbeamIO.getAvailableParts(ioCtx) or {}
  local description = availableParts and availableParts[partName]
  return getDescriptionText(description, partName or "Engine")
end

local function getAuthoredPartValue(vehicleModel, partName)
  vehicleModel = tostring(vehicleModel or "")
  partName = tostring(partName or "")
  if vehicleModel == "" or partName == "" then return 0 end
  local modelCache = authoredPartValueCache[vehicleModel]
  if not modelCache then
    local vehicleDir = string.format("/vehicles/%s/", vehicleModel)
    local ioCtx = FS:directoryExists(vehicleDir) and jbeamIO.startLoading({vehicleDir, "/vehicles/common/"}) or nil
    modelCache = {ioCtx = ioCtx, available = ioCtx and (jbeamIO.getAvailableParts(ioCtx) or {}) or {}, values = {}}
    authoredPartValueCache[vehicleModel] = modelCache
  end
  if modelCache.values[partName] ~= nil then return modelCache.values[partName] end
  local info = modelCache.available[partName] or {}
  local data = modelCache.ioCtx and (jbeamIO.getPart(modelCache.ioCtx, partName) or {}) or {}
  local value = math.max(0, tonumber(info.value)
    or tonumber(info.information and info.information.value)
    or tonumber(data.information and data.information.value) or 0)
  modelCache.values[partName] = value
  return value
end

local function collectVariableNamesFromValue(value, result, seen)
  if type(value) ~= "table" or seen[value] then return end
  seen[value] = true

  if type(value.name) == "string" and value.name:sub(1, 1) == "$" then
    result[value.name] = true
  end
  if type(value[1]) == "string" and value[1]:sub(1, 1) == "$" then
    result[value[1]] = true
  end

  for key, child in pairs(value) do
    if type(key) == "string" and key:sub(1, 1) == "$" then
      result[key] = true
    end
    if type(child) == "table" then
      collectVariableNamesFromValue(child, result, seen)
    end
  end
end

local function collectEngineVariableNames(packageTree, ioCtx)
  local result = {}
  local function visit(node)
    if not node then return end
    local partData = node.name and jbeamIO.getPart(ioCtx, node.name)
    if partData and partData.variables then
      collectVariableNamesFromValue(partData.variables, result, {})
    end
    for _, child in pairs(node.children or {}) do visit(child) end
  end
  visit(packageTree)
  return result
end

local function filterRecipeTuning(packageTree, vehicleModel, values, existingIoCtx)
  if type(packageTree) ~= "table" or type(values) ~= "table" then return {} end
  -- Config vars also contain alignment, tires, suspension, and controls. A
  -- recursive JBeam ownership scan is too costly for cold dealership stock,
  -- so retain only authored variables whose names are powertrain-specific.
  local tokens = {"engine", "boost", "turbo", "supercharger", "wastegate", "rev", "rpm", "limiter",
    "fuel", "nitro", "ignition", "timing", "compression", "cam", "idle", "torque", "power", "throttle"}
  local excludedTokens = {"camber", "differential", "difftorque", "brake", "suspension", "spring", "damp",
    "caster", "toe", "steering", "lsd"}
  local filtered = {}
  for variableName, value in pairs(values) do
    local lower = string.lower(tostring(variableName))
    local excluded = lower == "fuel" or lower == "$fuel"
    for _, token in ipairs(excludedTokens) do
      if string.find(lower, token, 1, true) then excluded = true; break end
    end
    if not excluded then
      for _, token in ipairs(tokens) do
        if string.find(lower, token, 1, true) then
          filtered[variableName] = deepcopy(value)
          break
        end
      end
    end
  end
  return filtered
end

local function captureTuning(packageTree, runtimeData, vehicleConfig)
  local tuning = {}
  local definitions = runtimeData and runtimeData.vdata and runtimeData.vdata.variables or {}
  local names = collectEngineVariableNames(packageTree, runtimeData and runtimeData.ioCtx)
  for variableName in pairs(names) do
    local definition = definitions and definitions[variableName]
    local value = definition and definition.val
    if value == nil and vehicleConfig and vehicleConfig.vars then value = vehicleConfig.vars[variableName] end
    if value == nil and definition then value = definition.default end
    if value ~= nil then tuning[variableName] = value end
  end
  return tuning
end

local function makePackageTree(node, inventoryId)
  local inventory = getPartInventory()

  local function findPartId(path)
    for partId, part in pairs(inventory) do
      if tonumber(part.location) == tonumber(inventoryId) and part.containingSlot == path then
        return partId
      end
    end
  end

  local function copyNode(source, relativeSlot)
    local partId = findPartId(source.path)
    if not partId then return nil, "Could not locate owned part for " .. tostring(source.chosenPartName) end
    local result = {
      name = source.chosenPartName,
      partId = partId,
      relativeSlot = relativeSlot,
      children = {}
    }
    for slotName, child in pairs(source.children or {}) do
      if child.chosenPartName and child.chosenPartName ~= "" then
        local copied, err = copyNode(child, slotName)
        if not copied then return nil, err end
        result.children[slotName] = copied
      end
    end
    return result
  end

  return copyNode(node)
end

local function collectTreePartEntries(node, basePath, result)
  result = result or {}
  if not node then return result end
  table.insert(result, {
    partId = tonumber(node.partId) or node.partId,
    name = node.name,
    containingSlot = basePath,
    partPath = basePath .. tostring(node.name or "")
  })
  for slotName, child in pairs(node.children or {}) do
    collectTreePartEntries(child, basePath .. slotName .. "/", result)
  end
  return result
end

local function makeConfigTree(node, basePath, slotId)
  local result = {
    id = slotId or node.relativeSlot,
    chosenPartName = node.name,
    path = basePath,
    partPath = basePath .. tostring(node.name or ""),
    decisionMethod = "user",
    children = {}
  }
  for slotName, child in pairs(node.children or {}) do
    result.children[slotName] = makeConfigTree(child, basePath .. slotName .. "/", slotName)
  end
  return result
end

local function findPackageForInventory(inventoryId)
  for _, package in ipairs(packages) do
    if tonumber(package.installedInventoryId) == tonumber(inventoryId) then
      return package
    end
  end
end

local function uniquePackageName(baseName, exceptPackageId)
  baseName = trim(baseName)
  if baseName == "" then baseName = "Engine Package" end
  local used = {}
  for _, package in ipairs(packages) do
    if tostring(package.id) ~= tostring(exceptPackageId or "") then
      used[string.lower(package.name or "")] = true
    end
  end
  if not used[string.lower(baseName)] then return baseName end
  local suffix = 2
  while used[string.lower(baseName .. " " .. suffix)] do suffix = suffix + 1 end
  return baseName .. " " .. suffix
end

local function captureCurrentEngineActual(inventoryId, requestedName, existingPackage, captureAnchor)
  local vehicles = career_modules_inventory.getVehicles()
  local vehicle = vehicles and vehicles[inventoryId]
  local runtimeData, vehObj = getRuntimeVehicleData(inventoryId)
  if not vehicle or not runtimeData or not runtimeData.config or not runtimeData.config.partsTree or not vehObj then
    return nil, "The selected vehicle is not spawned."
  end

  local engine = captureAnchor or resolveEngineCaptureAnchor(runtimeData.config.partsTree, runtimeData.ioCtx)
  if not engine then return nil, "No installed engine slot was found." end

  local packageTree, treeError = makePackageTree(engine.node, inventoryId)
  if not packageTree then return nil, treeError end

  local package = existingPackage
  if not package then
    package = {id = tostring(nextPackageId), ownerType = "personal"}
    nextPackageId = nextPackageId + 1
    table.insert(packages, package)
  else
    local newIds = {}
    for _, id in ipairs(getPartIdsFromPackageTree(packageTree)) do newIds[id] = true end
    local inventory = getPartInventory()
    for _, oldId in ipairs(getPartIdsFromPackageTree(package.tree)) do
      if not newIds[oldId] then
        local oldPart = inventory[oldId]
        if oldPart and tostring(oldPart.enginePackageId or "") == tostring(package.id) then
          oldPart.enginePackageId = nil
          oldPart.mainPart = oldPart.containingSlot == "/"
        end
      end
    end
  end

  local enginePartName = engine.combustionPartName or findCombustionEnginePartName(engine.node, runtimeData.ioCtx)
    or packageTree.name
  local engineNiceName = getPartNiceName(runtimeData.ioCtx, enginePartName)
  local desiredName = trim(requestedName)
  if desiredName == "" then desiredName = package.name or (engineNiceName .. " Package") end
  package.name = uniquePackageName(desiredName, package.id)
  package.rootSlotName = engine.slotName
  package.rootPath = engine.path
  package.rootEngineName = enginePartName
  package.rootEngineNiceName = engineNiceName
  package.tree = packageTree
  package.tuning = captureTuning(packageTree, runtimeData, vehicle.config)
  package.createdModel = package.createdModel or vehicle.model
  package.lastInstalledModel = vehicle.model
  package.installedInventoryId = inventoryId
  package.installedViaCeep = isCeepHubNode(engine.node, runtimeData.ioCtx)
  package.updatedAt = os.time()
  package.createdAt = package.createdAt or package.updatedAt

  local inventory = getPartInventory()
  for _, partId in ipairs(getPartIdsFromPackageTree(package.tree)) do
    local part = inventory[partId]
    if part then
      part.enginePackageId = tostring(package.id)
      part.mainPart = true
    end
  end

  if refreshCertificationValidity then refreshCertificationValidity(package) end

  return package
end

getPackageStatus = function(package)
  local inventory = getInventoryForPackage(package)
  local location
  local missing = 0
  local mixed = false
  local ids = getPartIdsFromPackageTree(package.tree)
  for _, partId in ipairs(ids) do
    local part = inventory[partId]
    if not part then
      missing = missing + 1
    elseif location == nil then
      location = tonumber(part.location) or part.location
    elseif tostring(location) ~= tostring(part.location) then
      mixed = true
    end
  end

  if missing > 0 then return "incomplete", nil, missing end
  if mixed or location == nil then return "incomplete", nil, missing end
  if tonumber(location) == 0 or tostring(location) == "stored" then return "stored", nil, 0 end
  return "installed", tonumber(location) or location, 0
end

local function getSlotInfo(availableParts, parentPartName, slotName, ioCtx)
  local parentInfo = availableParts and availableParts[parentPartName]
  local slotInfo = parentInfo and parentInfo.slotInfoUi and parentInfo.slotInfoUi[slotName]
  if slotInfo then return slotInfo end
  local parentJbeam = ioCtx and jbeamIO.getPart(ioCtx, parentPartName) or nil
  return parentJbeam and parentJbeam.slotInfoUi and parentJbeam.slotInfoUi[slotName] or nil
end

local function partFitsSlotOrDeclaredDefault(parentPartName, slotName, partData, partName, slotInfo, ioCtx)
  if slotInfo and jbeamSlotSystem.partFitsSlot(partData, slotInfo) then return true end
  local parentJbeam = ioCtx and jbeamIO.getPart(ioCtx, parentPartName) or nil
  if not parentJbeam then return false end
  local defaultName
  if type(parentJbeam.slots2) == "table" then
    for _, slot in ipairs(parentJbeam.slots2) do
      if type(slot) == "table" and (slot.name or slot[1]) == slotName then
        defaultName = slot.default or slot[4]
        break
      end
    end
  end
  if type(parentJbeam.slots) == "table" then
    for _, slot in ipairs(parentJbeam.slots) do
      if type(slot) == "table" and slot.type == slotName then
        defaultName = slot.default
        break
      end
    end
  end
  return defaultName ~= nil and tostring(defaultName) == tostring(partName)
end

local function validatePackageTreeFits(node, parentPartName, slotName, ioCtx, availableParts)
  if not node or not node.name then return false, "Package tree is incomplete." end
  local partData = jbeamIO.getPart(ioCtx, node.name)
  if not partData then return false, "Missing part: " .. tostring(node.name) end
  local slotInfo = getSlotInfo(availableParts, parentPartName, slotName, ioCtx)
  if not partFitsSlotOrDeclaredDefault(parentPartName, slotName, partData, node.name, slotInfo, ioCtx) then
    return false, tostring(node.name) .. " does not fit " .. tostring(slotName)
  end
  for childSlot, child in pairs(node.children or {}) do
    local ok, err = validatePackageTreeFits(child, node.name, childSlot, ioCtx, availableParts)
    if not ok then return false, err end
  end
  return true
end

local function findNodeByPath(tree, path)
  if not tree or not path then return nil end
  if path == "/" or path == tree.path then return tree end
  local current = tree
  for segment in string.gmatch(path, "[^/]+") do
    if not current.children or not current.children[segment] then return nil end
    current = current.children[segment]
  end
  return current
end

local function parentPathFromSlotPath(slotPath)
  if type(slotPath) ~= "string" or slotPath == "" or slotPath == "/" then return nil end
  local trimmed = slotPath:gsub("/+$", "")
  local parent = trimmed:match("^(.*)/[^/]+$")
  if not parent or parent == "" then return "/" end
  if parent:sub(-1) ~= "/" then parent = parent .. "/" end
  return parent
end

local function ensureChildSlotNode(parentNode, slotName, path)
  if not parentNode or not slotName then return nil end
  parentNode.children = parentNode.children or {}
  local child = parentNode.children[slotName]
  if not child then
    child = {id = slotName, path = path, chosenPartName = ""}
    parentNode.children[slotName] = child
  else
    if not child.id then child.id = slotName end
    if path and (not child.path or child.path == "") then child.path = path end
  end
  return child
end

local function peekChildSlotNode(parentNode, slotName, path)
  local existing = parentNode and parentNode.children and parentNode.children[slotName]
  if existing then return existing, true end
  return {id = slotName, path = path, chosenPartName = ""}, false
end

local function collectDeclaredEngineBayCandidates(tree, availableParts, ioCtx)
  local bays = {}
  local function visit(node)
    if not node then return end
    local parentName = nodePartName(node)
    local parentInfo = parentName and availableParts and availableParts[parentName]
    local slotInfoUi = parentInfo and parentInfo.slotInfoUi
    if not slotInfoUi and parentName and ioCtx then
      local parentJbeam = jbeamIO.getPart(ioCtx, parentName)
      slotInfoUi = parentJbeam and parentJbeam.slotInfoUi
    end
    if slotInfoUi then
      for slotName, _ in pairs(slotInfoUi) do
        local lowerSlot = string.lower(tostring(slotName))
        if string.find(lowerSlot, "engine", 1, true) and not string.find(lowerSlot, "electric", 1, true) then
          local path = ((node.path or "/") .. slotName .. "/")
          local child, existed = peekChildSlotNode(node, slotName, path)
          table.insert(bays, {
            node = child,
            parentNode = node,
            slotName = slotName,
            path = child.path or path,
            parentPartName = parentName,
            isBay = true,
            synthesized = not existed
          })
        end
      end
    end
    for _, child in pairs(node.children or {}) do
      visit(child)
    end
  end
  visit(tree)
  return bays
end

local function rememberedAttachmentCandidate(package, tree)
  if not package or not tree then return nil end
  local slotName = package.rootSlotName
  local path = package.rootPath
  if (not slotName or slotName == "") and type(path) == "string" then
    slotName = path:match("/([^/]+)/?$")
  end
  if not slotName or slotName == "" then return nil end
  local parentPath = parentPathFromSlotPath(path)
  local parentNode = parentPath and findNodeByPath(tree, parentPath) or nil
  if not parentNode then
    parentNode = tree
  end
  local parentName = nodePartName(parentNode)
  if not parentName or parentName == "" then return nil end
  local synthesizedPath = ((parentNode.path or "/") .. slotName .. "/")
  local child, existed = peekChildSlotNode(parentNode, slotName, synthesizedPath)
  local childPath = (existed and type(child.path) == "string" and child.path ~= "") and child.path or synthesizedPath
  if not child.path or child.path == "" then child.path = childPath end
  return {
    node = child,
    parentNode = parentNode,
    slotName = slotName,
    path = childPath,
    parentPartName = parentName,
    isBay = true,
    remembered = true
  }
end

local function findCompatibleTarget(package, inventoryId)
  if vehicleIsElectric(inventoryId) then
    return nil, "Electric vehicles cannot swap engines."
  end
  local runtimeData = getRuntimeVehicleData(inventoryId)
  if not runtimeData or not runtimeData.config or not runtimeData.config.partsTree or not runtimeData.ioCtx then
    return nil, "The selected vehicle is not spawned."
  end

  local inventory = getPartInventory()
  for _, partId in ipairs(getPartIdsFromPackageTree(package.tree)) do
    if not inventory[partId] then return nil, "The package is missing one or more parts." end
  end

  local availableParts = jbeamIO.getAvailableParts(runtimeData.ioCtx)
  local usesCeep = packageUsesCeepMount(package, runtimeData.ioCtx)
  local matches = {}
  local seenPaths = {}

  local function tryCandidate(candidate)
    local path = tostring(candidate.path or "")
    if seenPaths[path] then return end
    seenPaths[path] = true
    local ok = validatePackageTreeFits(package.tree, candidate.parentPartName, candidate.slotName, runtimeData.ioCtx, availableParts)
    if ok then table.insert(matches, candidate) end
  end

  local remembered = rememberedAttachmentCandidate(package, runtimeData.config.partsTree)
  if remembered then tryCandidate(remembered) end

  if usesCeep then
    for _, candidate in ipairs(findEngineBaySlots(runtimeData.config.partsTree, runtimeData.ioCtx)) do
      tryCandidate(candidate)
    end
  else
    for _, candidate in ipairs(findEngineBaySlots(runtimeData.config.partsTree, runtimeData.ioCtx)) do
      tryCandidate(candidate)
    end
    for _, candidate in ipairs(findEngineCandidates(runtimeData.config.partsTree, true, runtimeData.ioCtx)) do
      if not parentIsCeepHub(candidate.parentPartName, runtimeData.ioCtx) then
        tryCandidate(candidate)
      end
    end
    for _, candidate in ipairs(findEngineCandidates(runtimeData.config.partsTree, true, runtimeData.ioCtx)) do
      if parentIsCeepHub(candidate.parentPartName, runtimeData.ioCtx) then
        tryCandidate(candidate)
      end
    end
  end

  if #matches == 0 then
    for _, candidate in ipairs(collectDeclaredEngineBayCandidates(runtimeData.config.partsTree, availableParts, runtimeData.ioCtx)) do
      tryCandidate(candidate)
    end
  end

  if #matches == 0 then return nil, "This engine package does not fit the selected vehicle." end
  for _, candidate in ipairs(matches) do
    if candidate.slotName == package.rootSlotName then return candidate end
  end
  table.sort(matches, function(a, b)
    local depthA, depthB = pathDepth(a.path), pathDepth(b.path)
    if depthA ~= depthB then return depthA < depthB end
    return tostring(a.path) < tostring(b.path)
  end)
  if #matches > 1 and pathDepth(matches[1].path) == pathDepth(matches[2].path) then
    return nil, "More than one compatible engine slot was found."
  end
  return matches[1]
end

local function getConditionSummary(package)
  local inventory = getInventoryForPackage(package)
  local integrityTotal, integrityCount, maxOdometer = 0, 0, 0
  for _, partId in ipairs(getPartIdsFromPackageTree(package.tree)) do
    local condition = inventory[partId] and inventory[partId].partCondition
    if type(condition) == "table" then
      local integrity = tonumber(condition.integrityValue)
      if integrity then
        integrityTotal = integrityTotal + integrity
        integrityCount = integrityCount + 1
      end
      maxOdometer = math.max(maxOdometer, tonumber(condition.odometer) or 0)
    end
  end
  return integrityCount > 0 and (integrityTotal / integrityCount) or 1, maxOdometer
end

local function getPackageSaleValue(package)
  local inventory = getInventoryForPackage(package)
  local total = 0
  for _, partId in ipairs(getPartIdsFromPackageTree(package and package.tree)) do
    local part = inventory[tonumber(partId) or partId]
    if not part then return nil end
    if part.value == nil then
      part.value = getAuthoredPartValue(part.vehicleModel or package.createdModel or package.lastInstalledModel, part.name)
    end
    total = total + math.max(0, tonumber(career_modules_valueCalculator.getPartValue(part)) or 0)
  end
  return math.max(0, math.floor(total + 0.5))
end

local function getVehicleName(inventoryId)
  local vehicle = career_modules_inventory.getVehicles()[tonumber(inventoryId)]
  if not vehicle then return nil end
  local name = vehicle.niceName or vehicle.model
  if core_locales and core_locales.translateWithOrWithoutContext then
    return core_locales.translateWithOrWithoutContext(name)
  end
  return type(name) == "table" and (name.txt or vehicle.model) or name
end

local function buildUIData()
  local result = {
    busy = transactionBusy,
    currentInventoryId = currentInventoryId,
    currentVehicleName = currentInventoryId and getVehicleName(currentInventoryId) or nil,
    browseOnly = currentInventoryId == nil,
    currentPackageId = nil,
    hasInstalledEngine = false,
    packages = {}
  }
  if currentInventoryId then
    local runtimeData = getRuntimeVehicleData(currentInventoryId)
    result.hasInstalledEngine = runtimeData and runtimeData.config and not vehicleIsElectric(currentInventoryId) and getPrimaryEngine(runtimeData.config.partsTree, runtimeData.ioCtx) ~= nil or false
  end
  local currentPackage = currentInventoryId and findPackageForInventory(currentInventoryId)
  result.currentPackageId = currentPackage and tostring(currentPackage.id) or nil

  for _, package in ipairs(packages) do
    if not isBusinessPackage(package) then
    local status, installedInventoryId, missingCount = getPackageStatus(package)
    package.installedInventoryId = installedInventoryId
    local compatible, compatibilityReason = false, nil
    if currentInventoryId and status ~= "incomplete" then
      local target, err = findCompatibleTarget(package, currentInventoryId)
      compatible = target ~= nil
      compatibilityReason = err
      if not compatible and err == "This engine package does not fit the selected vehicle."
          and result.currentVehicleName then
        compatibilityReason = "Does not fit " .. tostring(result.currentVehicleName) .. "."
      end
    end
    local integrity, odometer = getConditionSummary(package)
    local saleValue = status == "stored" and getPackageSaleValue(package) or nil
    local thumbnailPath = getPackageThumbnailPath(package.id)
    table.insert(result.packages, {
      id = tostring(package.id),
      name = package.name,
      rootEngineName = package.rootEngineName,
      rootEngineNiceName = package.rootEngineNiceName or package.rootEngineName,
      partCount = #getPartIdsFromPackageTree(package.tree),
      tuningCount = countTableEntries(package.tuning),
      integrity = integrity,
      odometer = odometer,
      status = status,
      missingCount = missingCount,
      installedInventoryId = installedInventoryId,
      installedVehicleName = installedInventoryId and getVehicleName(installedInventoryId) or nil,
      createdModel = package.createdModel,
      lastInstalledModel = package.lastInstalledModel,
      compatible = compatible,
      compatibilityReason = compatibilityReason,
      canInstall = not transactionBusy and status == "stored" and compatible,
      canStore = not transactionBusy and status == "installed" and tonumber(installedInventoryId) == tonumber(currentInventoryId),
      canDismantle = not transactionBusy,
      canSell = not transactionBusy and status == "stored" and saleValue ~= nil,
      saleValue = saleValue,
      thumbnail = thumbnailPath,
      dirtyDate = package.thumbnailAt or package.updatedAt or 0,
      certification = deepcopy(package.engineShopCertification)
    })
    end
  end

  table.sort(result.packages, function(a, b)
    if a.status ~= b.status then return a.status == "installed" end
    return string.lower(a.name or "") < string.lower(b.name or "")
  end)
  return result
end

-- Parts list for the package detail view: every part in the package tree (parent before children,
-- slots in name order) with its condition and value. Missing parts are kept, flagged missing.
local function getPackageDetails(packageId)
  local package = getPackageById(packageId)
  if not package or isBusinessPackage(package) then return nil end
  local inventory = getInventoryForPackage(package)
  local fallbackModel = package.createdModel or package.lastInstalledModel
  local parts = {}

  local function walk(node, slotPath, slotName, depth)
    if not node then return end
    local partId = tonumber(node.partId) or node.partId
    local part = partId ~= nil and inventory[partId] or nil
    local condition = part and part.partCondition
    local value = nil
    if part then
      if part.value == nil then
        part.value = getAuthoredPartValue(part.vehicleModel or fallbackModel, part.name)
      end
      value = math.max(0, math.floor((tonumber(career_modules_valueCalculator.getPartValue(part)) or 0) + 0.5))
    end
    table.insert(parts, {
      partId = partId,
      name = node.name,
      niceName = part and getDescriptionText(part.description, node.name) or node.name,
      slot = slotName,
      slotPath = slotPath,
      depth = depth,
      integrity = condition and tonumber(condition.integrityValue) or nil,
      odometer = condition and tonumber(condition.odometer) or nil,
      value = value,
      missing = part == nil
    })
    local slotNames = {}
    for childSlot in pairs(node.children or {}) do table.insert(slotNames, childSlot) end
    table.sort(slotNames)
    for _, childSlot in ipairs(slotNames) do
      walk(node.children[childSlot], slotPath .. childSlot .. "/", childSlot, depth + 1)
    end
  end

  walk(package.tree, "/", package.tree and package.tree.relativeSlot or nil, 0)
  return {
    id = tostring(package.id),
    name = package.name,
    parts = parts,
    tuningCount = countTableEntries(package.tuning),
    certification = deepcopy(package.engineShopCertification)
  }
end

local function sendUIData()
  if not menuOpen then return end
  guihooks.trigger("enginePackagesData", buildUIData())
end

local function sendResult(success, message)
  guihooks.trigger("enginePackagesActionResult", {success = success == true, message = message or ""})
  sendUIData()
  if activeInstallCallback then
    local callback = activeInstallCallback
    activeInstallCallback = nil
    local ok, err = pcall(callback, success == true, message or "")
    if not ok then log("E", logTag, "Engine installation callback failed: " .. tostring(err)) end
  end
end

local function collectLivePartPaths(node, result)
  result = result or {}
  if not node then return result end
  local partPath = node.partPath
  if (not partPath or partPath == "") and node.path and (node.chosenPartName or node.name) then
    partPath = node.path .. tostring(node.chosenPartName or node.name)
  end
  if partPath and partPath ~= "" then
    result[partPath] = true
  end
  for _, child in pairs(node.children or {}) do
    collectLivePartPaths(child, result)
  end
  return result
end

local function collectLivePartNames(node, result)
  result = result or {}
  if not node then return result end
  local name = node.chosenPartName or node.name
  if name and name ~= "" then result[name] = true end
  for _, child in pairs(node.children or {}) do
    collectLivePartNames(child, result)
  end
  return result
end

local function expandPartPathsFromVdata(vdata, partNames, partPaths)
  partPaths = partPaths or {}
  if not vdata or not partNames then return partPaths end

  local function consider(path)
    if type(path) ~= "string" or path == "" or partPaths[path] then return end
    local name = path:match("([^/]+)$")
    if name and partNames[name] then
      partPaths[path] = true
    end
  end

  if vdata.flexbodies then
    for _, flexbody in pairs(vdata.flexbodies) do
      if type(flexbody) == "table" then consider(flexbody.partPath) end
    end
  end
  if vdata.props then
    for _, prop in pairs(vdata.props) do
      if type(prop) == "table" then consider(prop.partPath) end
    end
  end
  if vdata.nodes then
    for _, node in pairs(vdata.nodes) do
      if type(node) == "table" then consider(node.partPath) end
    end
  end
  return partPaths
end

-- Vehicle ids whose highlight cache may still be engine-only. replaceVehicle
-- reuses the id, and freeroam keeps that cache when the JBeam name is unchanged.
local isolatedVehicleIds = {}
local visibilityRetry = {}

local function vehicleReadyForHighlightReset(vehId)
  if not vehId or not core_vehicle_partmgmt or not core_vehicle_manager then return nil end
  local vehObj = getObjectByID(vehId)
  if not vehObj then return nil end
  local vehData = core_vehicle_manager.getVehicleData(vehId)
  if not vehData or not vehData.config then return nil end
  return vehObj
end

local function applyFullPartVisibility(vehId)
  local vehObj = vehicleReadyForHighlightReset(vehId)
  if not vehObj then return false end
  -- reset(false) drops the cache. It no-ops when the object or vehicle data is
  -- missing, which is what leaves wheels at alpha 0 after a same-model replace.
  pcall(core_vehicle_partmgmt.resetVehicleHighlights, false, vehId)
  pcall(core_vehicle_partmgmt.setNewParts, vehId)
  pcall(core_vehicle_partmgmt.showHighlightedParts, vehId)
  pcall(function() vehObj:setMeshAlpha(1, "", false) end)
  isolatedVehicleIds[vehId] = nil
  return true
end

local function scheduleVisibilityRetry(vehId)
  if not vehId or visibilityRetry[vehId] or not core_jobsystem then return end
  visibilityRetry[vehId] = true
  core_jobsystem.create(function(job)
    local startClock = os.clock()
    while os.clock() - startClock < 3 do
      job.sleep(0.15)
      if applyFullPartVisibility(vehId) then
        visibilityRetry[vehId] = nil
        return
      end
    end
    visibilityRetry[vehId] = nil
    if isolatedVehicleIds[vehId] then
      log("W", logTag, "Part visibility restore timed out for vehicle " .. tostring(vehId))
    end
  end, 1)
end

local function restoreVehiclePartVisibility(vehObj, vehId)
  -- highlightParts leaves engine-only state in partmgmt. Always reset that
  -- and force mesh alpha, using the live object for this vehId when possible.
  if vehId then
    local live = getObjectByID(vehId)
    if live then vehObj = live end
  elseif vehObj and vehObj.getID then
    vehId = vehObj:getID()
  end
  if vehId and applyFullPartVisibility(vehId) then
    visibilityRetry[vehId] = nil
    return
  end
  if vehObj then
    pcall(function() vehObj:setMeshAlpha(1, "", false) end)
  end
  if vehId then
    scheduleVisibilityRetry(vehId)
  end
end

local function unhideInventoryVehicle(inventoryId)
  local vehObj, vehId = getSpawnedVehicleObject(inventoryId)
  restoreVehiclePartVisibility(vehObj, vehId)
end

-- Parts that extend far from the engine block and should not dominate framing.
local function isPeripheralEnginePart(name)
  if not name then return false end
  local lower = string.lower(name)
  if string.find(lower, "exhaust", 1, true) then return true end
  if string.find(lower, "transmission", 1, true) then return true end
  if string.find(lower, "gearbox", 1, true) then return true end
  if string.find(lower, "transfercase", 1, true) then return true end
  if string.find(lower, "driveshaft", 1, true) then return true end
  if string.find(lower, "radiator", 1, true) then return true end
  if string.find(lower, "intercooler", 1, true) then return true end
  return false
end

local function frameEngineCamera(vehObj, vdata, partPaths, partNames)
  local vehPos = vehObj:getPosition()
  local minP, maxP
  local seen = {}
  local nodeCount = 0

  -- Separate core engine parts from peripheral parts (exhaust, trans, etc.).
  local corePartPaths = {}
  local corePartNames = {}
  local peripheralPartPaths = {}
  for path in pairs(partPaths) do
    local name = path:match("([^/]+)$")
    if isPeripheralEnginePart(name) then
      peripheralPartPaths[path] = true
    else
      corePartPaths[path] = true
    end
  end
  for name in pairs(partNames) do
    if not isPeripheralEnginePart(name) then
      corePartNames[name] = true
    end
  end

  local function considerCid(cid)
    if cid == nil or seen[cid] then return end
    seen[cid] = true
    local nodePos = vehObj:getNodePosition(cid)
    if not nodePos then return end
    local world = nodePos + vehPos
    nodeCount = nodeCount + 1
    if not minP then
      minP = vec3(world.x, world.y, world.z)
      maxP = vec3(world.x, world.y, world.z)
    else
      minP.x = math.min(minP.x, world.x)
      minP.y = math.min(minP.y, world.y)
      minP.z = math.min(minP.z, world.z)
      maxP.x = math.max(maxP.x, world.x)
      maxP.y = math.max(maxP.y, world.y)
      maxP.z = math.max(maxP.z, world.z)
    end
  end

  -- First pass: only core engine parts (block, heads, intake, etc.).
  if vdata and vdata.nodes then
    for _, node in pairs(vdata.nodes) do
      if type(node) == "table" and node.cid ~= nil then
        local pathMatch = node.partPath and corePartPaths[node.partPath]
        local nameMatch = node.partOrigin and corePartNames[node.partOrigin]
        if pathMatch or nameMatch then considerCid(node.cid) end
      end
    end
  end

  -- If no core nodes found, fall back to all engine parts.
  if nodeCount == 0 and vdata and vdata.nodes then
    for _, node in pairs(vdata.nodes) do
      if type(node) == "table" and node.cid ~= nil then
        local match = (node.partPath and partPaths[node.partPath]) or (node.partOrigin and partNames[node.partOrigin])
        if match then considerCid(node.cid) end
      end
    end
  end

  local bb = vehObj:getSpawnWorldOOBB()
  local axis0, axis1, axis2 = bb:getAxis(0), bb:getAxis(1), bb:getAxis(2)
  local lookAt, size
  if minP and maxP then
    lookAt = (minP + maxP) * 0.5
    size = maxP - minP
  else
    local half = bb:getHalfExtents()
    lookAt = bb:getCenter() + axis1 * (half.y * 0.4) + axis2 * (half.z * 0.2)
    size = vec3(0.8, 1.0, 0.6)
  end

  -- Never aim at the pavement; thin hoods/covers sit just above the ground AABB.
  local groundZ = bb:getCenter().z - bb:getHalfExtents().z
  local minLookZ = groundZ + 0.45
  if lookAt.z < minLookZ then
    lookAt = lookAt + axis2 * (minLookZ - lookAt.z)
  end
  lookAt = lookAt + axis2 * math.max(size.z * 0.2, 0.12)

  -- Use the plan-view size so a flat cover still gets a sensible standoff.
  local xyDim = math.max(size.x, size.y, 0.55)
  local maxDim = math.max(xyDim, size.z * 1.3, 0.55)
  local fov = 28
  local distance = (maxDim * 0.95) / math.tan(math.rad(fov) * 0.5)
  distance = math.max(1.05, math.min(distance, 2.8))

  -- 3/4 view, only a little above horizontal so the part fills the frame instead of the lot.
  local camOffset = (axis0 * -0.72 + axis1 * -0.88 + axis2 * 0.22):normalized()
  local camPos = lookAt + camOffset * distance
  local camRot = quatFromDir(lookAt - camPos, axis2)
  log("I", logTag, string.format("Engine frame nodes=%d size=%.2f dist=%.2f fov=%d lookZ=%.2f", nodeCount, maxDim, distance, fov, lookAt.z))
  return camPos, camRot, fov
end

local thumbnailQueue = {}
local thumbnailBusy = false
local capturingPackageId
local canceledThumbnailPackageIds = {}

local function packageInstalledOnInventory(package, inventoryId)
  if not package or inventoryId == nil then return false end
  local status, installedInventoryId = getPackageStatus(package)
  return status == "installed" and tonumber(installedInventoryId) == tonumber(inventoryId)
end

local function cancelThumbnailsForPackage(packageId)
  if packageId == nil then return end
  packageId = tostring(packageId)
  canceledThumbnailPackageIds[packageId] = true
  local kept = {}
  for _, job in ipairs(thumbnailQueue) do
    if tostring(job.packageId) ~= packageId then
      kept[#kept + 1] = job
    elseif job.callback then
      local cbOk, cbErr = pcall(job.callback, false)
      if not cbOk then
        log("E", logTag, "Canceled thumbnail callback failed: " .. tostring(cbErr))
      end
    end
  end
  thumbnailQueue = kept
end

local function clearThumbnailCancel(packageId)
  if packageId == nil then return end
  canceledThumbnailPackageIds[tostring(packageId)] = nil
end

local function isThumbnailCanceled(packageId)
  return packageId ~= nil and canceledThumbnailPackageIds[tostring(packageId)] == true
end
local pendingAfterIdle = {}

local function captureEngineThumbnailNow(packageId, inventoryId, callback)
  local finished = false
  local isolated = false
  local vehObj, vehId, runtimeData

  local function restore()
    if not isolated then return end
    unhideInventoryVehicle(inventoryId)
    restoreVehiclePartVisibility(vehObj, vehId)
    isolated = false
  end

  local function done(ok, reason)
    if finished then return end
    finished = true
    restore()
    if not ok then
      log("W", logTag, "Engine thumbnail failed for package " .. tostring(packageId) .. ": " .. tostring(reason or "unknown"))
    else
      log("I", logTag, "Engine thumbnail saved for package " .. tostring(packageId))
    end
    if callback then
      local cbOk, cbErr = pcall(callback, ok == true)
      if not cbOk then
        log("E", logTag, "Engine thumbnail callback failed: " .. tostring(cbErr))
      end
    end
  end

  local package = getPackageById(packageId)
  runtimeData, vehObj, vehId = getRuntimeVehicleData(inventoryId)
  if not package then
    done(false, "package not found")
    return
  end
  if isThumbnailCanceled(packageId) then
    done(false, "thumbnail canceled")
    return
  end
  if not packageInstalledOnInventory(package, inventoryId) then
    done(false, "package not installed on capture vehicle")
    return
  end
  if not runtimeData or not vehObj then
    done(false, "vehicle is not spawned")
    return
  end

  local engine = runtimeData.config and resolveEngineCaptureAnchor(runtimeData.config.partsTree, runtimeData.ioCtx)
  if not engine or not engine.node then
    done(false, "no installed engine slot")
    return
  end

  local partPaths = collectLivePartPaths(engine.node)
  local partNames = collectLivePartNames(engine.node)
  expandPartPathsFromVdata(runtimeData.vdata, partNames, partPaths)
  if not next(partPaths) then
    done(false, "engine part paths were empty")
    return
  end
  log("I", logTag, "Engine isolate parts=" .. tostring(countTableEntries(partPaths)))

  local filename = getPackageThumbnailDiskPath(package.id)
  local uiPath = getPackageThumbnailUiPath(package.id)
  if not filename then
    done(false, "no save path")
    return
  end
  ensureSaveDirectory(filename)

  if not core_vehicle_partmgmt or not core_vehicle_partmgmt.highlightParts then
    done(false, "part highlight API missing")
    return
  end

  local camPos, camRot, fov = frameEngineCamera(vehObj, runtimeData.vdata, partPaths, partNames)
  if not camPos or not camRot then
    done(false, "could not frame engine camera")
    return
  end

  if not render_renderViews or not render_renderViews.takeScreenshot then
    extensions.load("render_renderViews")
  end
  if not render_renderViews or not render_renderViews.takeScreenshot then
    done(false, "render view screenshot missing")
    return
  end

  local jobHandle = core_jobsystem.create(function(job)
    isolated = true
    if vehId then isolatedVehicleIds[vehId] = true end
    local highlightOk, highlightErr = pcall(core_vehicle_partmgmt.highlightParts, partPaths, vehId)
    if not highlightOk then
      done(false, "highlightParts failed: " .. tostring(highlightErr))
      return
    end
    job.sleep(0.3)

    if isThumbnailCanceled(packageId) or not packageInstalledOnInventory(getPackageById(packageId), inventoryId) then
      done(false, "thumbnail canceled before screenshot")
      return
    end

    local screenshotDone = false
    local screenshotOk, screenshotErr = pcall(function()
      render_renderViews.takeScreenshot({
        renderViewName = "enginePkgThumb",
        screenshotDelay = 0.4,
        resolution = vec3(1000, 562, 0),
        downscaleFactor = 2,
        copyMainViewExposure = false,
        manualEV = 12,
        rot = camRot,
        pos = camPos,
        fov = fov or 32,
        nearPlane = 0.04,
        filename = filename
      }, function(success)
        screenshotDone = true
        if isThumbnailCanceled(packageId) then
          done(false, "thumbnail canceled after capture")
          return
        end
        local livePackage = getPackageById(packageId)
        if not packageInstalledOnInventory(livePackage, inventoryId) then
          done(false, "package no longer installed on capture vehicle")
          return
        end
        local exists = (filename and FS:fileExists(filename)) or (uiPath and FS:fileExists(uiPath))
        if success == true or exists then
          package.thumbnailAt = os.time()
          package.thumbnailCaptureVersion = thumbnailCaptureVersion
          saveData()
          sendUIData()
          done(true)
        else
          done(false, "screenshot callback reported failure")
        end
      end)
    end)

    if not screenshotOk then
      done(false, "takeScreenshot error: " .. tostring(screenshotErr))
      return
    end

    local waitStart = os.clock()
    while not screenshotDone and (os.clock() - waitStart) < 6 do
      job.sleep(0.1)
    end
    if not finished then
      done(false, "screenshot timed out")
    end
  end, 1)
  if jobHandle and jobHandle.setExitCallback then
    jobHandle.setExitCallback(function()
      if not finished then
        done(false, "thumbnail job ended")
      end
    end)
  end
end

local function flushThumbnailWaiters()
  if thumbnailBusy or thumbnailQueue[1] then return end
  local waiters = pendingAfterIdle
  pendingAfterIdle = {}
  for _, waiter in ipairs(waiters) do
    local ok, err = pcall(waiter)
    if not ok then
      log("E", logTag, "Thumbnail idle callback failed: " .. tostring(err))
    end
  end
end

local function pumpThumbnailQueue()
  if thumbnailBusy then return end
  local job = table.remove(thumbnailQueue, 1)
  if not job then
    capturingPackageId = nil
    flushThumbnailWaiters()
    return
  end
  thumbnailBusy = true
  capturingPackageId = job.packageId
  captureEngineThumbnailNow(job.packageId, job.inventoryId, function(ok)
    thumbnailBusy = false
    capturingPackageId = nil
    if job.callback then
      local cbOk, cbErr = pcall(job.callback, ok)
      if not cbOk then
        log("E", logTag, "Queued engine thumbnail callback failed: " .. tostring(cbErr))
      end
    end
    pumpThumbnailQueue()
  end)
end

local function whenThumbnailsIdle(callback)
  if not callback then return end
  if not thumbnailBusy and not thumbnailQueue[1] then
    local ok, err = pcall(callback)
    if not ok then
      log("E", logTag, "Thumbnail idle callback failed: " .. tostring(err))
    end
    return
  end
  table.insert(pendingAfterIdle, callback)
end

local function whenThumbnailsIdleOrTimeout(callback, timeoutSec)
  if not callback then return end
  local finished = false
  local function run()
    if finished then return end
    finished = true
    local ok, err = pcall(callback)
    if not ok then
      log("E", logTag, "Thumbnail idle/timeout callback failed: " .. tostring(err))
    end
  end
  whenThumbnailsIdle(run)
  if core_jobsystem then
    core_jobsystem.create(function(job)
      job.sleep(math.max(1, tonumber(timeoutSec) or 8))
      run()
    end, 1)
  else
    run()
  end
end

local function isThumbnailPending(packageId)
  if capturingPackageId and tostring(capturingPackageId) == tostring(packageId) then
    return true
  end
  for _, job in ipairs(thumbnailQueue) do
    if tostring(job.packageId) == tostring(packageId) then
      return true
    end
  end
  return false
end

local function enqueueEngineThumbnail(package, inventoryId, callback)
  if not package or not inventoryId then
    if callback then callback(false) end
    return
  end
  if not packageInstalledOnInventory(package, inventoryId) then
    if callback then callback(false) end
    return
  end
  clearThumbnailCancel(package.id)
  if isThumbnailPending(package.id) then
    if callback then whenThumbnailsIdle(function() callback(true) end) end
    return
  end
  table.insert(thumbnailQueue, {
    packageId = package.id,
    inventoryId = inventoryId,
    callback = callback
  })
  pumpThumbnailQueue()
end

local function packageNeedsThumbnail(package)
  if not package then return false end
  return not packageThumbnailExists(package.id) or tonumber(package.thumbnailCaptureVersion) ~= thumbnailCaptureVersion
end

local function maybeCaptureMissingThumbnails()
  for _, package in ipairs(packages) do
    if packageNeedsThumbnail(package) then
      local status, installedInventoryId = getPackageStatus(package)
      local inventoryId = installedInventoryId
      if status == "installed" and inventoryId then
        local spawnedId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
        if not spawnedId and tonumber(inventoryId) == tonumber(currentInventoryId) then
          spawnedId = career_modules_inventory.getVehicleIdFromInventoryId(currentInventoryId)
          inventoryId = currentInventoryId
        end
        if spawnedId then
          log("I", logTag, "Queueing engine thumbnail for package " .. tostring(package.id) .. " on vehicle " .. tostring(inventoryId))
          enqueueEngineThumbnail(package, inventoryId)
        end
      end
    end
  end
end

local function validateSelectedVehicle()
  local vehicle = currentInventoryId and career_modules_inventory.getVehicles()[currentInventoryId]
  if not vehicle then return false, "No vehicle is selected." end
  if vehicle.owned ~= true then return false, "The selected vehicle is not owned." end
  if vehicle.timeToAccess then return false, "The selected vehicle is not accessible." end
  if not career_modules_inventory.getVehicleIdFromInventoryId(currentInventoryId) then
    return false, "The selected vehicle is not spawned."
  end
  if not career_modules_insurance_insurance or not career_modules_insurance_insurance.inventoryVehNeedsRepair then
    return false, "Insurance is still loading. Reopen the garage computer."
  end
  if career_modules_insurance_insurance.inventoryVehNeedsRepair(currentInventoryId) then
    return false, "Repair this vehicle before managing engine packages."
  end
  local permission = career_modules_permissions.getStatusForTag({"partSwapping", "vehicleModification"}, {inventoryId = currentInventoryId})
  if not permission.allow then return false, permission.label or "Vehicle modification is not allowed." end
  if vehicleIsElectric(currentInventoryId) then
    return false, "Electric vehicles cannot swap engines."
  end
  return true
end

local function createFromCurrent(name)
  if transactionBusy then return end
  local valid, err = validateSelectedVehicle()
  if not valid then sendResult(false, err) return end
  local inventoryId = currentInventoryId
  if findPackageForInventory(inventoryId) then
    sendResult(false, "This engine is already grouped as a package.")
    return
  end
  local transactionId = beginTransaction()
  sendUIData()
  career_modules_inventory.updatePartConditions(nil, inventoryId, function()
    if not isActiveTransaction(transactionId) then return end
    local package, captureError = captureCurrentEngineActual(inventoryId, name)
    if not package then
      endTransaction(transactionId)
      sendResult(false, captureError)
      return
    end
    career_modules_inventory.setVehicleDirty(inventoryId)
    saveData()
    enqueueEngineThumbnail(package, inventoryId)
    whenThumbnailsIdleOrTimeout(function()
      if not isActiveTransaction(transactionId) then return end
      if career_career.isAutosaveEnabled() then career_saveSystem.saveCurrent() end
      endTransaction(transactionId)
      sendResult(true, "Created engine package " .. tostring(package.name) .. ".")
    end, 8)
  end)
end

local function renamePackage(packageId, name)
  if transactionBusy then return end
  local package = getPackageById(packageId)
  if not package then sendResult(false, "Engine package not found.") return end
  name = trim(name)
  if name == "" then sendResult(false, "Enter a package name.") return end
  package.name = uniquePackageName(name, package.id)
  package.updatedAt = os.time()
  saveData()
  if career_career.isAutosaveEnabled() then career_saveSystem.saveCurrent() end
  sendResult(true, "Renamed engine package.")
end

local function dismantlePackage(packageId)
  if transactionBusy then return end
  local package = getPackageById(packageId)
  if not package then sendResult(false, "Engine package not found.") return end
  for _, guard in ipairs(packageReferenceGuards) do
    local ok, reason = guard(package)
    if ok == false then
      sendResult(false, reason or "This engine package is protected by an active reference.")
      return
    end
  end
  local _, installedInventoryId = getPackageStatus(package)
  deletePackageThumbnail(package.id)
  removePackage(package.id, true)
  if installedInventoryId then career_modules_inventory.setVehicleDirty(installedInventoryId) end
  saveData()
  if career_career.isAutosaveEnabled() then
    career_saveSystem.saveCurrent()
  end
  sendResult(true, "Dismantled engine package. Its parts are available in My Parts again.")
end

local function sellPackage(packageId)
  if transactionBusy then return end
  local package = getPackageById(packageId)
  if not package or isBusinessPackage(package) then sendResult(false, "Personal engine package not found.") return end
  if getPackageStatus(package) ~= "stored" then
    sendResult(false, "Only a stored engine package can be sold.")
    return
  end
  for _, guard in ipairs(packageReferenceGuards) do
    local ok, reason = guard(package)
    if ok == false then
      sendResult(false, reason or "This engine package is protected by an active reference.")
      return
    end
  end
  local inventory = getPartInventory()
  local partIds = getPartIdsFromPackageTree(package.tree)
  local saleValue = getPackageSaleValue(package)
  if saleValue == nil then sendResult(false, "The engine package is missing one or more parts.") return end
  for _, partId in ipairs(partIds) do
    local part = inventory[tonumber(partId) or partId]
    if not part or (tonumber(part.location) ~= 0 and tostring(part.location) ~= "stored") then
      sendResult(false, "Every engine package part must be stored before sale.")
      return
    end
  end
  deletePackageThumbnail(package.id)
  removePackage(package.id, false)
  for _, partId in ipairs(partIds) do inventory[tonumber(partId) or partId] = nil end
  career_modules_playerAttributes.addAttributes({money = saleValue}, {
    tags = {"partsSold", "enginePackageSold", "selling"},
    label = "Sold " .. tostring(package.name)
  }, true)
  Engine.Audio.playOnce("AudioGui", "event:>UI>Career>Buy_01")
  saveData()
  if career_modules_partInventory.onPartShoppingTransactionComplete then
    career_modules_partInventory.onPartShoppingTransactionComplete()
  end
  if career_career.isAutosaveEnabled() then career_saveSystem.saveCurrent() end
  sendResult(true, string.format("Sold %s for $%d.", tostring(package.name), saleValue))
end

local function storeFuelLevels(vehObj, callback)
  if not vehObj then callback({}) return end
  core_vehicleBridge.requestValue(vehObj, function(data)
    local result = {}
    if data and data[1] then
      for _, tank in ipairs(data[1]) do
        if tank.energyType ~= "n2o" then
          result[tank.name] = {
            currentEnergy = tank.currentEnergy,
            maxEnergy = tank.maxEnergy,
            energyType = tank.energyType,
            relativeFuel = tank.maxEnergy > 0 and tank.currentEnergy / tank.maxEnergy or 0
          }
        end
      end
    end
    callback(result)
  end, "energyStorage")
end

local function restoreFuelLevels(vehObj, storedLevels)
  if not vehObj or not storedLevels or not next(storedLevels) then return end
  core_vehicleBridge.requestValue(vehObj, function(data)
    if not data or not data[1] then return end
    for _, tank in ipairs(data[1]) do
      local stored = storedLevels[tank.name]
      if stored and stored.energyType == tank.energyType then
        local amount = math.min(stored.currentEnergy, tank.maxEnergy)
        if tank.maxEnergy > stored.maxEnergy then amount = tank.maxEnergy * stored.relativeFuel end
        core_vehicleBridge.executeAction(vehObj, "setEnergyStorageEnergy", tank.name, math.max(amount, tank.maxEnergy * 0.05))
      end
    end
  end, "energyStorage")
end

local function pathIsUnder(childPath, parentPath)
  childPath = childPath or ""
  parentPath = parentPath or ""
  if parentPath == "" then return false end
  return childPath == parentPath or string.find(childPath, parentPath, 1, true) == 1
end

local function partIdSetFromTree(node)
  local ids = {}
  for _, partId in ipairs(getPartIdsFromPackageTree(node)) do
    ids[tostring(partId)] = true
  end
  return ids
end

local function findOuterEngineBay(tree, ioCtx, path)
  local match
  for _, bay in ipairs(findEngineBaySlots(tree, ioCtx)) do
    if not path or pathIsUnder(path, bay.path) then
      if not match or pathDepth(bay.path) < pathDepth(match.path) then
        match = bay
      end
    end
  end
  return match
end

local function isLeftoverEngineMount(bay, ioCtx)
  if not bay or not bay.node then return false end
  local name = nodePartName(bay.node)
  if not name or name == "" then return false end
  if partIsCombustionEngine(ioCtx, name) then return false end
  if isCeepHubNode(bay.node, ioCtx) then return true end
  return partProvidesEngineMount(jbeamIO.getPart(ioCtx, name))
end

local function findInventoryPartAtSlot(inventory, slotPath, inventoryId)
  local fallbackId
  for partId, part in pairs(inventory) do
    if part.containingSlot == slotPath then
      if inventoryId and tonumber(part.location) == tonumber(inventoryId) then
        return partId, part
      end
      if not inventoryId then
        fallbackId = fallbackId or partId
      end
    end
  end
  if inventoryId then
    return nil
  end
  return fallbackId, fallbackId and inventory[fallbackId]
end

local function copyLeftoverPackageTree(source, skipIds, inventory, inventoryId, relativeSlot)
  if not source then return nil end
  local partId = findInventoryPartAtSlot(inventory, source.path, inventoryId)
  if partId and skipIds[tostring(partId)] then
    return nil
  end
  if not partId or not source.chosenPartName or source.chosenPartName == "" then
    return nil
  end
  local result = {
    name = source.chosenPartName,
    partId = partId,
    relativeSlot = relativeSlot,
    children = {}
  }
  for slotName, child in pairs(source.children or {}) do
    local copied = copyLeftoverPackageTree(child, skipIds, inventory, inventoryId, slotName)
    if copied then result.children[slotName] = copied end
  end
  return result
end

local function packageContainsPartId(package, partId)
  if not package or not partId then return false end
  for _, id in ipairs(getPartIdsFromPackageTree(package.tree)) do
    if tostring(id) == tostring(partId) then return true end
  end
  return false
end

local function parkLeftoverParts(leftoverTree, package, inventory, newConditions, basePath)
  if not leftoverTree or not package then return end
  for _, entry in ipairs(collectTreePartEntries(leftoverTree, basePath)) do
    local part = inventory[entry.partId]
    if part then
      if newConditions[part.partPath] then part.partCondition = deepcopy(newConditions[part.partPath]) end
      newConditions[part.partPath] = nil
      part.location = 0
      part.mainPart = true
      part.enginePackageId = tostring(package.id)
      part.containingSlot = entry.containingSlot
      part.partPath = entry.partPath
    end
  end
end

local function mergeLeftoverIntoOutgoing(outgoingPackage, leftoverTree, innerSlotName, bay, ioCtx)
  if not leftoverTree then return outgoingPackage end
  if not outgoingPackage then
    outgoingPackage = {id = tostring(nextPackageId)}
    nextPackageId = nextPackageId + 1
    table.insert(packages, outgoingPackage)
    outgoingPackage.name = uniquePackageName((getPartNiceName(ioCtx, leftoverTree.name) or "Engine") .. " Package")
    outgoingPackage.createdAt = os.time()
  elseif packageContainsPartId(outgoingPackage, leftoverTree.partId) then
    outgoingPackage.rootSlotName = bay.slotName
    outgoingPackage.rootPath = bay.path
    outgoingPackage.updatedAt = os.time()
    return outgoingPackage
  else
    leftoverTree.children = leftoverTree.children or {}
    if innerSlotName and not leftoverTree.children[innerSlotName] and outgoingPackage.tree then
      leftoverTree.children[innerSlotName] = outgoingPackage.tree
      leftoverTree.children[innerSlotName].relativeSlot = innerSlotName
    end
  end
  outgoingPackage.tree = leftoverTree
  outgoingPackage.rootSlotName = bay.slotName
  outgoingPackage.rootPath = bay.path
  outgoingPackage.rootEngineName = leftoverTree.name
  outgoingPackage.rootEngineNiceName = getPartNiceName(ioCtx, leftoverTree.name)
  outgoingPackage.installedInventoryId = nil
  outgoingPackage.updatedAt = os.time()
  outgoingPackage.createdAt = outgoingPackage.createdAt or outgoingPackage.updatedAt
  return outgoingPackage
end

local function hoistPackageToBay(bay, package, inventory, newConditions, vehicle, inventoryId)
  local previousEntries = collectTreePartEntries(package.tree, package.rootPath or bay.path)
  for _, entry in ipairs(previousEntries) do
    newConditions[entry.partPath] = nil
  end
  local config = makeConfigTree(package.tree, bay.path, bay.slotName)
  bay.node.id = bay.slotName or bay.node.id
  bay.node.chosenPartName = package.tree.name
  bay.node.children = config.children
  bay.node.path = bay.path
  bay.node.partPath = bay.path .. tostring(package.tree.name)
  for _, entry in ipairs(collectTreePartEntries(package.tree, bay.path)) do
    local part = inventory[entry.partId]
    if part then
      part.location = inventoryId or vehicle.id
      part.containingSlot = entry.containingSlot
      part.partPath = entry.partPath
      part.mainPart = true
      part.enginePackageId = tostring(package.id)
      newConditions[entry.partPath] = deepcopy(part.partCondition or {integrityValue = 1, visualValue = 1, odometer = 0})
    end
  end
  package.rootSlotName = bay.slotName
  package.rootPath = bay.path
  vehicle.changedSlots = vehicle.changedSlots or {}
  vehicle.changedSlots[bay.path] = true
end

local function rehomeLeftoverEngineMount(opts)
  local bay = findOuterEngineBay(opts.tree, opts.ioCtx, opts.installPath)
  if not bay then return opts.outgoingPackage, false end
  if not isLeftoverEngineMount(bay, opts.ioCtx) then return opts.outgoingPackage, false end
  if opts.expectedRootName and nodePartName(bay.node) == opts.expectedRootName then
    return opts.outgoingPackage, false
  end

  local skipIds = opts.skipIds or {}
  local leftoverTree = copyLeftoverPackageTree(bay.node, skipIds, opts.inventory, opts.inventoryId)
  local outgoingPackage = mergeLeftoverIntoOutgoing(opts.outgoingPackage, leftoverTree, opts.innerSlotName, bay, opts.ioCtx)
  parkLeftoverParts(leftoverTree, outgoingPackage, opts.inventory, opts.newConditions, bay.path)

  if opts.incomingPackage then
    hoistPackageToBay(bay, opts.incomingPackage, opts.inventory, opts.newConditions, opts.vehicle, opts.inventoryId)
  else
    bay.node.id = bay.slotName or bay.node.id
    bay.node.chosenPartName = ""
    bay.node.children = {}
    bay.node.partPath = nil
    opts.vehicle.changedSlots = opts.vehicle.changedSlots or {}
    opts.vehicle.changedSlots[bay.path] = true
  end
  return outgoingPackage, true
end

local function engineBayMatchesPackage(tree, ioCtx, package, inventoryId)
  if not tree or not ioCtx or not package or not package.tree then return false end
  local anchor = findOuterEngineBay(tree, ioCtx, package.rootPath) or resolveEngineCaptureAnchor(tree, ioCtx)
  if not anchor or not anchor.node then return false end
  local rebuiltTree = makePackageTree(anchor.node, inventoryId)
  if not rebuiltTree then return false end
  return packageTreesFullyMatch(package.tree, rebuiltTree)
end

local function engineBayIsEmptyOfMount(tree, ioCtx, package)
  if not tree then return true end
  if getPrimaryEngine(tree, ioCtx) then
    return false
  end
  local bay = findOuterEngineBay(tree, ioCtx, package and package.rootPath)
  if not bay or not bay.node then return true end
  local function hasPart(node)
    local name = nodePartName(node)
    if name and name ~= "" then return true end
    for _, child in pairs(node.children or {}) do
      if hasPart(child) then return true end
    end
    return false
  end
  return not hasPart(bay.node)
end

local function storeInstalledPackage(packageId)
  if transactionBusy then return end
  local valid, validationError = validateSelectedVehicle()
  if not valid then sendResult(false, validationError) return end
  local package = getPackageById(packageId)
  if not package then sendResult(false, "Engine package not found.") return end
  local inventoryId = currentInventoryId
  local status, installedInventoryId = getPackageStatus(package)
  if status ~= "installed" or tonumber(installedInventoryId) ~= tonumber(inventoryId) then
    sendResult(false, "Only the selected vehicle's installed engine package can be stored.")
    return
  end

  local transactionId = beginTransaction()
  sendUIData()
  career_modules_inventory.updatePartConditions(nil, inventoryId, function()
    if not isActiveTransaction(transactionId) then return end
    local inventory = getPartInventory()
    local vehicles = career_modules_inventory.getVehicles()
    local vehicle = vehicles[inventoryId]
    local runtimeData, oldVehObj = getRuntimeVehicleData(inventoryId)
    local engine = runtimeData and runtimeData.config and resolveEngineCaptureAnchor(runtimeData.config.partsTree, runtimeData.ioCtx)
    if not vehicle or not runtimeData or not oldVehObj or not engine then
      endTransaction(transactionId)
      sendResult(false, "The installed engine could not be read.")
      return
    end

    local currentTree, treeError = makePackageTree(engine.node, inventoryId)
    if not currentTree or not installedPackageTreeMatches(package.tree, currentTree) then
      endTransaction(transactionId)
      sendResult(false, treeError or "The installed engine no longer matches this package.")
      return
    end

    local inventorySnapshot = deepcopy(inventory)
    local packagesSnapshot = deepcopy(packages)
    local vehicleSnapshot = deepcopy(vehicle)
    package = captureCurrentEngineActual(inventoryId, package.name, package, engine)
    if not package then
      restoreTable(inventory, inventorySnapshot)
      packages = packagesSnapshot
      endTransaction(transactionId)
      sendResult(false, "The installed engine package could not be refreshed.")
      return
    end

    local function continueStore()
    cancelThumbnailsForPackage(package.id)
    if not isActiveTransaction(transactionId) then return end
    local storePath = package.rootPath or engine.path
    local entries = collectTreePartEntries(package.tree, storePath)
    local newConditions = deepcopy(vehicle.partConditions or {})

    for _, entry in ipairs(entries) do
      local part = inventory[entry.partId]
      if not part then
        restoreTable(inventory, inventorySnapshot)
        packages = packagesSnapshot
        endTransaction(transactionId)
        sendResult(false, "The engine package is missing one or more parts.")
        return
      end
      if newConditions[part.partPath] then part.partCondition = deepcopy(newConditions[part.partPath]) end
      newConditions[part.partPath] = nil
      part.location = 0
      part.mainPart = true
      part.enginePackageId = tostring(package.id)
    end

    engine.node.id = engine.slotName or engine.node.id
    engine.node.chosenPartName = ""
    engine.node.children = {}
    engine.node.partPath = nil
    vehicle.config.partsTree = runtimeData.config.partsTree
    vehicle.config.vars = vehicle.config.vars or {}
    for variableName in pairs(package.tuning or {}) do vehicle.config.vars[variableName] = nil end
    vehicle.partConditions = newConditions
    vehicle.partList = nil
    vehicle.changedSlots = vehicle.changedSlots or {}
    vehicle.changedSlots[engine.path] = true
    package.installedInventoryId = nil
    package.updatedAt = os.time()

    rehomeLeftoverEngineMount({
      tree = runtimeData.config.partsTree,
      ioCtx = runtimeData.ioCtx,
      inventory = inventory,
      inventoryId = inventoryId,
      vehicle = vehicle,
      installPath = engine.path,
      skipIds = partIdSetFromTree(package.tree),
      innerSlotName = engine.slotName,
      outgoingPackage = package,
      newConditions = newConditions
    })

    local transactionFinished = false
    local function rollback(message)
      if transactionFinished then return end
      transactionFinished = true
      restoreTable(inventory, inventorySnapshot)
      packages = packagesSnapshot
      vehicles[inventoryId] = vehicleSnapshot
      if career_modules_partInventory.onPartShoppingTransactionComplete then
        career_modules_partInventory.onPartShoppingTransactionComplete()
      end
      local respawnOk, spawnedVehicle = pcall(career_modules_inventory.spawnVehicle, inventoryId, 2, repairPackageFlags)
      if not respawnOk then
        log("E", logTag, "Engine package rollback respawn failed: " .. tostring(spawnedVehicle))
        repairPackageFlags()
      elseif not spawnedVehicle then
        log("E", logTag, "Engine package rollback respawn returned nil")
        repairPackageFlags()
      end
      endTransaction(transactionId)
      sendResult(false, message or "Storing the engine failed and was rolled back.")
    end

    storeFuelLevels(oldVehObj, function(fuelLevels)
      if not isActiveTransaction(transactionId) then return end
      local ok, spawnedVehicle = pcall(career_modules_inventory.spawnVehicle, inventoryId, 2, function()
        if transactionFinished or not isActiveTransaction(transactionId) then return end
        local callbackOk, callbackError = pcall(function()
          local newVehObj = getSpawnedVehicleObject(inventoryId)
          restoreFuelLevels(newVehObj, fuelLevels)
          unhideInventoryVehicle(inventoryId)
          local liveData = getRuntimeVehicleData(inventoryId)
          local liveTree = liveData and liveData.config and liveData.config.partsTree
          if not engineBayIsEmptyOfMount(liveTree, liveData and liveData.ioCtx or runtimeData.ioCtx, package) then
            error("leftover engine mount")
          end
          if career_modules_partInventory.onPartShoppingTransactionComplete then
            career_modules_partInventory.onPartShoppingTransactionComplete()
          end
          repairPackageFlags()
          if career_modules_vehiclePerformance and career_modules_vehiclePerformance.invalidateCertification then
            career_modules_vehiclePerformance.invalidateCertification(inventoryId)
          end
          career_modules_inventory.setVehicleDirty(inventoryId)
        end)
        if not callbackOk then
          log("E", logTag, "Engine package storage completion failed: " .. tostring(callbackError))
          rollback("The stored engine transaction could not be finalized and was rolled back.")
          return
        end
        if not isActiveTransaction(transactionId) then return end
        transactionFinished = true
        endTransaction(transactionId)
        saveData()
        career_saveSystem.saveCurrent()
        sendResult(true, "Stored " .. tostring(package.name) .. ". Use Part Customization to build another engine.")
      end)
      if not ok then
        log("E", logTag, "Storing engine package failed while rebuilding the vehicle: " .. tostring(spawnedVehicle))
      end
      if not ok or not spawnedVehicle then rollback("The vehicle could not be rebuilt without the stored engine.") end
      if ok and spawnedVehicle and core_jobsystem then
        core_jobsystem.create(function(job)
          job.sleep(15)
          if not transactionFinished then rollback("The vehicle rebuild timed out and was rolled back.") end
        end, 1)
      end
    end)
    end

    if packageNeedsThumbnail(package) then
      enqueueEngineThumbnail(package, inventoryId)
    end
    whenThumbnailsIdleOrTimeout(continueStore, 8)
  end)
end

local function installPackage(packageId)
  if transactionBusy then return end
  local valid, validationError = validateSelectedVehicle()
  if not valid then sendResult(false, validationError) return end
  local targetPackage = getPackageById(packageId)
  if not targetPackage then sendResult(false, "Engine package not found.") return end
  local status = getPackageStatus(targetPackage)
  if status ~= "stored" then sendResult(false, "Only stored engine packages can be installed.") return end

  local inventoryId = currentInventoryId
  local targetCandidate, fitError = findCompatibleTarget(targetPackage, inventoryId)
  if not targetCandidate then sendResult(false, fitError) return end

  local transactionId = beginTransaction()
  sendUIData()
  career_modules_inventory.updatePartConditions(nil, inventoryId, function()
    if not isActiveTransaction(transactionId) then return end
    local inventory = getPartInventory()
    local vehicles = career_modules_inventory.getVehicles()
    local vehicle = vehicles[inventoryId]
    local runtimeData, oldVehObj = getRuntimeVehicleData(inventoryId)
    if not vehicle or not runtimeData or not oldVehObj then
      endTransaction(transactionId)
      sendResult(false, "The selected vehicle is no longer available.")
      return
    end

    local inventorySnapshot = deepcopy(inventory)
    local packagesSnapshot = deepcopy(packages)
    local vehicleSnapshot = deepcopy(vehicle)

    local outgoingPackage
    local currentEngine = getPrimaryEngine(runtimeData.config.partsTree, runtimeData.ioCtx)
    if currentEngine then
      outgoingPackage = findPackageForInventory(inventoryId)
      local outgoingName = outgoingPackage and outgoingPackage.name or nil
      local outgoingCaptureAnchor = currentEngine
      local isInnerCeepTarget = parentIsCeepHub(targetCandidate.parentPartName, runtimeData.ioCtx)
      if not isInnerCeepTarget then
        outgoingCaptureAnchor = resolveEngineCaptureAnchor(runtimeData.config.partsTree, runtimeData.ioCtx) or currentEngine
      end
      outgoingPackage, validationError = captureCurrentEngineActual(inventoryId, outgoingName, outgoingPackage, outgoingCaptureAnchor)
      if not outgoingPackage then
        endTransaction(transactionId)
        sendResult(false, validationError)
        return
      end
    end

    local outgoingEntries = outgoingPackage and collectTreePartEntries(outgoingPackage.tree, outgoingPackage.rootPath) or {}
    local incomingEntries = collectTreePartEntries(targetPackage.tree, targetCandidate.path)
    local newConditions = deepcopy(vehicle.partConditions or {})

    for _, entry in ipairs(outgoingEntries) do
      local part = inventory[entry.partId]
      if part then
        if newConditions[part.partPath] then part.partCondition = deepcopy(newConditions[part.partPath]) end
        newConditions[part.partPath] = nil
        part.location = 0
        part.mainPart = true
        part.enginePackageId = tostring(outgoingPackage.id)
      end
    end

    local targetModel = vehicle.model
    local availableParts = jbeamIO.getAvailableParts(runtimeData.ioCtx)
    for _, entry in ipairs(incomingEntries) do
      local part = inventory[entry.partId]
      if not part or tonumber(part.location) ~= 0 then
        restoreTable(inventory, inventorySnapshot)
        packages = packagesSnapshot
        endTransaction(transactionId)
        sendResult(false, "An engine package part became unavailable during the swap.")
        return
      end
      part.location = inventoryId
      part.containingSlot = entry.containingSlot
      part.partPath = entry.partPath
      part.vehicleModel = targetModel
      part.description = availableParts[entry.name] or part.description
      part.mainPart = true
      part.enginePackageId = tostring(targetPackage.id)
      newConditions[entry.partPath] = deepcopy(part.partCondition or {integrityValue = 1, visualValue = 1, odometer = 0})
    end

    if targetCandidate.parentNode then
      targetCandidate.node = ensureChildSlotNode(targetCandidate.parentNode, targetCandidate.slotName, targetCandidate.path)
    end
    targetCandidate.node.id = targetCandidate.slotName or targetCandidate.node.id
    targetCandidate.node.chosenPartName = targetPackage.tree.name
    targetCandidate.node.children = makeConfigTree(targetPackage.tree, targetCandidate.path, targetCandidate.slotName).children
    targetCandidate.node.path = targetCandidate.path
    targetCandidate.node.partPath = targetCandidate.path .. targetPackage.tree.name
    vehicle.config.partsTree = runtimeData.config.partsTree
    vehicle.config.vars = vehicle.config.vars or {}
    if outgoingPackage then
      for variableName in pairs(outgoingPackage.tuning or {}) do vehicle.config.vars[variableName] = nil end
    end
    for variableName, value in pairs(targetPackage.tuning or {}) do vehicle.config.vars[variableName] = value end
    vehicle.partConditions = newConditions
    vehicle.partList = nil
    vehicle.changedSlots = vehicle.changedSlots or {}
    vehicle.changedSlots[targetCandidate.path] = true

    local rehomed
    outgoingPackage, rehomed = rehomeLeftoverEngineMount({
      tree = runtimeData.config.partsTree,
      ioCtx = runtimeData.ioCtx,
      inventory = inventory,
      inventoryId = inventoryId,
      vehicle = vehicle,
      installPath = targetCandidate.path,
      expectedRootName = targetPackage.tree.name,
      skipIds = partIdSetFromTree(targetPackage.tree),
      innerSlotName = targetCandidate.slotName,
      outgoingPackage = outgoingPackage,
      incomingPackage = targetPackage,
      newConditions = newConditions
    })

    if outgoingPackage then
      outgoingPackage.installedInventoryId = nil
      outgoingPackage.updatedAt = os.time()
    end
    targetPackage.installedInventoryId = inventoryId
    targetPackage.lastInstalledModel = targetModel
    if not rehomed then
      targetPackage.rootSlotName = targetCandidate.slotName
      targetPackage.rootPath = targetCandidate.path
    end
    targetPackage.updatedAt = os.time()

    local transactionFinished = false
    local function rollback(message)
      if transactionFinished then return end
      transactionFinished = true
      restoreTable(inventory, inventorySnapshot)
      packages = packagesSnapshot
      vehicles[inventoryId] = vehicleSnapshot
      if career_modules_partInventory.onPartShoppingTransactionComplete then
        career_modules_partInventory.onPartShoppingTransactionComplete()
      end
      local respawnOk, spawnedVehicle = pcall(career_modules_inventory.spawnVehicle, inventoryId, 2, repairPackageFlags)
      if not respawnOk then
        log("E", logTag, "Engine package rollback respawn failed: " .. tostring(spawnedVehicle))
        repairPackageFlags()
      elseif not spawnedVehicle then
        log("E", logTag, "Engine package rollback respawn returned nil")
        repairPackageFlags()
      end
      endTransaction(transactionId)
      sendResult(false, message or "The engine swap failed and was rolled back.")
    end

    storeFuelLevels(oldVehObj, function(fuelLevels)
      if not isActiveTransaction(transactionId) then return end
      local ok, spawnedVehicle = pcall(career_modules_inventory.spawnVehicle, inventoryId, 2, function()
        if transactionFinished or not isActiveTransaction(transactionId) then return end
        local callbackOk, callbackError = pcall(function()
          local newVehObj = getSpawnedVehicleObject(inventoryId)
          restoreFuelLevels(newVehObj, fuelLevels)
          unhideInventoryVehicle(inventoryId)
          local liveData = getRuntimeVehicleData(inventoryId)
          local liveTree = liveData and liveData.config and liveData.config.partsTree
          if not engineBayMatchesPackage(liveTree, liveData and liveData.ioCtx or runtimeData.ioCtx, targetPackage, inventoryId) then
            error("leftover engine mount")
          end
          if career_modules_partInventory.onPartShoppingTransactionComplete then
            career_modules_partInventory.onPartShoppingTransactionComplete()
          end
          repairPackageFlags()
          if career_modules_vehiclePerformance and career_modules_vehiclePerformance.invalidateCertification then
            career_modules_vehiclePerformance.invalidateCertification(inventoryId)
          end
          career_modules_inventory.setVehicleDirty(inventoryId)
        end)
        if not callbackOk then
          log("E", logTag, "Engine swap completion failed: " .. tostring(callbackError))
          rollback("The rebuilt vehicle could not be finalized; the engine swap was rolled back.")
          return
        end
        if not isActiveTransaction(transactionId) then return end
        transactionFinished = true
        endTransaction(transactionId)
        saveData()
        career_saveSystem.saveCurrent()
        local successMessage = "Installed " .. tostring(targetPackage.name) .. "."
        if outgoingPackage then
          successMessage = successMessage .. " The outgoing engine was stored as " .. tostring(outgoingPackage.name) .. "."
        end
        sendResult(true, successMessage)
        if packageNeedsThumbnail(targetPackage) then
          enqueueEngineThumbnail(targetPackage, inventoryId)
        end
      end)
      if not ok then
        log("E", logTag, "Installing engine package failed while rebuilding the vehicle: " .. tostring(spawnedVehicle))
      end
      if not ok or not spawnedVehicle then rollback("The vehicle could not be rebuilt; the engine swap was rolled back.") end
      if ok and spawnedVehicle and core_jobsystem then
        core_jobsystem.create(function(job)
          job.sleep(15)
          if not transactionFinished then
            rollback("The vehicle rebuild timed out; the engine swap was rolled back.")
          end
        end, 1)
      end
    end)
  end)
end

local function refreshInstalledPackage(inventoryId, refreshTree)
  local package = findPackageForInventory(inventoryId)
  if not package then return false end
  local runtimeData = getRuntimeVehicleData(inventoryId)
  local vehicle = career_modules_inventory.getVehicles()[inventoryId]
  if not runtimeData or not vehicle then return false end
  if refreshTree then
    local anchor = runtimeData.config and resolveEngineCaptureAnchor(runtimeData.config.partsTree, runtimeData.ioCtx)
    local currentTree = anchor and makePackageTree(anchor.node, inventoryId)
    if not currentTree or not installedPackageTreeMatches(package.tree, currentTree) then
      package.installedInventoryId = nil
      package.updatedAt = os.time()
      local inventory = getPartInventory()
      for _, partId in ipairs(getPartIdsFromPackageTree(package.tree)) do
        local part = inventory[partId]
        if part and tonumber(part.location) == tonumber(inventoryId) then
          part.enginePackageId = nil
          part.mainPart = part.containingSlot == "/"
        end
      end
      return true
    end
    local refreshed = captureCurrentEngineActual(inventoryId, package.name, package, anchor)
    return refreshed ~= nil
  end
  package.tuning = captureTuning(package.tree, runtimeData, vehicle.config)
  package.updatedAt = os.time()
  if refreshCertificationValidity then refreshCertificationValidity(package) end
  return true
end

local function onPartShoppingTransactionComplete()
  if transactionBusy then return end
  local changed = false
  for _, package in ipairs(packages) do
    local inventoryId = tonumber(package.installedInventoryId)
    if inventoryId and career_modules_inventory.getVehicleIdFromInventoryId(inventoryId) then
      changed = refreshInstalledPackage(inventoryId, true) or changed
    end
  end
  if changed then saveData() end
  sendUIData()
end

local function onCareerTuningApplied()
  if transactionBusy then return end
  local inventoryId = career_modules_inventory.getCurrentVehicle()
  if inventoryId and refreshInstalledPackage(inventoryId, false) then saveData() end
  sendUIData()
end

local function onVehicleRemoved(inventoryId)
  for index = #packages, 1, -1 do
    if tonumber(packages[index].installedInventoryId) == tonumber(inventoryId) then
      table.remove(packages, index)
    end
  end
  saveData()
  sendUIData()
end

local function requestData()
  sendUIData()
  maybeCaptureMissingThumbnails()
  return buildUIData()
end

local function openMenu(inventoryId, computerId, businessContext)
  currentInventoryId = tonumber(inventoryId)
  originComputerId = tonumber(computerId) or computerId
  originBusinessContext = type(businessContext) == "table" and deepcopy(businessContext) or nil
  if not currentInventoryId and not originBusinessContext and not originComputerId then return false end
  menuOpen = true
  extensions.ui_router.navigate("career.computer.enginePackages")
  maybeCaptureMissingThumbnails()
  if core_jobsystem then
    core_jobsystem.create(function(job)
      job.sleep(0.8)
      if menuOpen then maybeCaptureMissingThumbnails() end
    end, 1)
  end
  return true
end

local function closeMenu()
  menuOpen = false
  if originBusinessContext then
    local context = originBusinessContext
    currentInventoryId = nil
    originComputerId = nil
    originBusinessContext = nil
    if context.businessType == "engineShop" and career_modules_business_engineShop then
      career_modules_business_engineShop.openMenu(context.businessId)
      return
    end
  end
  if originComputerId then
    local computer = freeroam_facilities.getFacility("computer", originComputerId)
    if computer then
      career_modules_computer.openMenu(computer)
      currentInventoryId = nil
      originComputerId = nil
      return
    end
  end
  currentInventoryId = nil
  originComputerId = nil
  career_career.closeAllMenus()
end

local function onComputerAddFunctions(menuData, computerFunctions)
  local computerId = menuData.computerFacility and menuData.computerFacility.id
  computerFunctions.general.enginePackages = {
    id = "enginePackages",
    label = "My Engine Packages",
    routeTarget = "career.computer.enginePackages",
    callback = function(callbackComputerId) openMenu(nil, callbackComputerId or computerId) end,
    order = 6
  }

  -- The general entry is the package library and deliberately opens without a
  -- selected vehicle. Keep a separate garage action so capture, removal, and
  -- installation operate on the vehicle represented by that card.
  local garageId = computerId and career_modules_garageManager.computerIdToGarageId(computerId)
  if not garageId or not career_modules_garageManager.isPurchasedGarage(garageId) then return end

  for _, vehicleData in ipairs(menuData.vehiclesInGarage or {}) do
    local inventoryId = vehicleData.inventoryId
    local vehicle = career_modules_inventory.getVehicles()[inventoryId]
    local data = {
      id = "enginePackageWorkshop",
      label = "Engine Package Workshop",
      routeTarget = "career.computer.enginePackages",
      callback = function(callbackComputerId)
        openMenu(inventoryId, callbackComputerId or computerId)
      end,
      order = 6
    }
    if not vehicle or vehicle.owned ~= true or vehicle.timeToAccess
        or not career_modules_inventory.getVehicleIdFromInventoryId(inventoryId) then
      data.disabled = true
      data.reason = {type = "text", label = "The vehicle must be owned, accessible, and spawned."}
    elseif vehicleIsElectric(inventoryId) then
      data.disabled = true
      data.reason = {type = "text", label = "Electric vehicles cannot use combustion engine packages."}
    elseif vehicleData.needsRepair then
      data.disabled = true
      data.reason = career_modules_computer.reasons.needsRepair
    else
      local permission = career_modules_permissions.getStatusForTag(
        {"partSwapping", "vehicleModification"}, {inventoryId = inventoryId})
      if not permission.allow then data.disabled = true end
      if permission.permission ~= "allowed" then data.reason = permission end
    end
    computerFunctions.vehicleSpecific[inventoryId][data.id] = data
  end
end

local function onSaveCurrentProfile(currentSavePath)
  saveData(currentSavePath)
end

local function initialize()
  if loaded then return end
  loadData()
end

-- Public ownership-aware package API. Personal garage actions above continue to
-- use the same physical records; business modules use these adapters so their
-- packages share persistence without appearing in the personal garage screen.
local function listPackages(ownerContext)
  local result = {}
  local ownerType = ownerContext and (ownerContext.ownerType or ownerContext.type)
  for _, package in ipairs(packages) do
    local matches = not ownerContext or (package.ownerType or "personal") == (ownerType or "personal")
    if matches and ownerType == "business" then
      matches = tostring(package.businessType or "") == tostring(ownerContext.businessType or "")
        and tostring(package.businessId or "") == tostring(ownerContext.businessId or "")
    end
    if matches then result[#result + 1] = package end
  end
  return result
end

local function stableEncode(value)
  local kind = type(value)
  if kind ~= "table" then return kind .. ":" .. tostring(value) end
  local keys = {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local out = {"{"}
  for _, key in ipairs(keys) do
    out[#out + 1] = stableEncode(key)
    out[#out + 1] = "="
    out[#out + 1] = stableEncode(value[key])
    out[#out + 1] = ";"
  end
  out[#out + 1] = "}"
  return table.concat(out)
end

local function hashText(text)
  local hash = 2166136261
  for index = 1, #text do
    hash = (hash * 16777619 + string.byte(text, index)) % 4294967296
  end
  return string.format("%08x", hash)
end

computeRecipeSignature = function(recipe)
  local normalized = deepcopy(recipe or {})
  normalized.signature = nil
  normalized.recipeSignature = nil
  return "ep2-" .. hashText(stableEncode(normalized))
end

-- Compatibility is determined by the exact engine attachment surfaces present
-- in the spawned vehicle, not just by its model name. Retail stock uses this
-- key so two configurations of the same model do not share incompatible stock.
local function getEngineCompatibilityKey(inventoryId)
  inventoryId = tonumber(inventoryId)
  local vehicle = career_modules_inventory.getVehicles()[inventoryId]
  local runtimeData = getRuntimeVehicleData(inventoryId)
  if not vehicle or not runtimeData or not runtimeData.config or not runtimeData.config.partsTree or not runtimeData.ioCtx then
    return nil, "The selected vehicle is not spawned."
  end
  local surfaces = {}
  for _, candidate in ipairs(findEngineCandidates(runtimeData.config.partsTree, true, runtimeData.ioCtx)) do
    surfaces[#surfaces + 1] = {
      path = tostring(candidate.path or ""),
      slotName = tostring(candidate.slotName or ""),
      parentPartName = tostring(candidate.parentPartName or "")
    }
  end
  if #surfaces == 0 then return nil, "No combustion-engine attachment point was found." end
  table.sort(surfaces, function(a, b)
    return (a.path .. "|" .. a.slotName .. "|" .. a.parentPartName)
      < (b.path .. "|" .. b.slotName .. "|" .. b.parentPartName)
  end)
  return computeRecipeSignature({vehicleModel = tostring(vehicle.model), attachmentSurfaces = surfaces})
end

local function recipeTreeFromPackageNode(node)
  if type(node) ~= "table" or not node.name then return nil end
  local result = {name = node.name, slotName = node.slotName or node.relativeSlot, children = {}}
  for slotName, child in pairs(node.children or {}) do
    result.children[slotName] = recipeTreeFromPackageNode(child)
  end
  return result
end

local function getRecipeFromPackage(packageId)
  local package = type(packageId) == "table" and packageId or getPackageById(packageId)
  if not package or type(package.tree) ~= "table" then return nil, "Engine Package not found." end
  local recipe = {
    vehicleModel = package.createdModel or package.lastInstalledModel,
    rootSlotName = package.rootSlotName,
    rootPath = package.rootPath,
    rootEngineName = package.rootEngineName or package.tree.name,
    rootEngineNiceName = package.rootEngineNiceName or package.rootEngineName or package.tree.name,
    tree = recipeTreeFromPackageNode(package.tree),
    tuning = deepcopy(package.tuning or {})
  }
  if not recipe.vehicleModel or not recipe.rootSlotName or not recipe.tree then
    return nil, "Engine Package compatibility metadata is incomplete."
  end
  recipe.signature = computeRecipeSignature(recipe)
  return recipe
end

local function getFreshPackageValue(packageId)
  local package = type(packageId) == "table" and packageId or getPackageById(packageId)
  local recipe, err = getRecipeFromPackage(package)
  if not recipe then return nil, err end
  local ioCtx
  local vehicleDir = string.format("/vehicles/%s/", recipe.vehicleModel)
  if FS:directoryExists(vehicleDir) then ioCtx = jbeamIO.startLoading({vehicleDir, "/vehicles/common/"}) end
  if not ioCtx then return nil, "The package vehicle model is unavailable." end
  local available = jbeamIO.getAvailableParts(ioCtx) or {}
  local total = 0
  local function visit(node)
    local info = available[node.name] or {}
    local data = jbeamIO.getPart(ioCtx, node.name) or {}
    total = total + math.max(0, tonumber(info.value)
      or tonumber(info.information and info.information.value)
      or tonumber(data.information and data.information.value) or 0)
    for _, child in pairs(node.children or {}) do visit(child) end
  end
  visit(recipe.tree)
  return math.max(1, math.floor(total + 0.5)), recipe
end

local function setEngineShopCertification(packageId, certification)
  local package = getPackageById(packageId)
  if not package or isBusinessPackage(package) then return false, "Personal Engine Package not found." end
  package.engineShopCertification = certification and deepcopy(certification) or nil
  package.updatedAt = os.time()
  saveData()
  sendUIData()
  return true
end

refreshCertificationValidity = function(package)
  local certification = package and package.engineShopCertification
  if not certification or not certification.recipeSignature then return end
  local recipe = getRecipeFromPackage(package)
  if not recipe or tostring(recipe.signature) ~= tostring(certification.recipeSignature) then
    package.engineShopCertification = nil
  end
end

local function registerPackageReferenceGuard(callback)
  if type(callback) ~= "function" then return false end
  packageReferenceGuards[#packageReferenceGuards + 1] = callback
  return true
end

local function upsertBusinessPackage(data)
  if type(data) ~= "table" or not data.businessId or not data.tree then
    return nil, "Business package data is incomplete."
  end
  local package = data.id and getPackageById(data.id) or nil
  if package and not isBusinessPackage(package) then return nil, "Package ownership mismatch." end
  if not package then
    package = {id = tostring(nextPackageId)}
    nextPackageId = nextPackageId + 1
    packages[#packages + 1] = package
  else
    clearPackageFlags(package)
  end
  for key, value in pairs(data) do package[key] = deepcopy(value) end
  package.id = tostring(package.id)
  package.ownerType = "business"
  package.businessType = package.businessType or "engineShop"
  package.name = trim(package.name) ~= "" and trim(package.name) or "Business Engine Package"
  package.createdAt = package.createdAt or os.time()
  package.updatedAt = os.time()
  local inventory = getInventoryForPackage(package)
  for _, partId in ipairs(getPartIdsFromPackageTree(package.tree)) do
    local part = inventory[partId]
    if part then
      part.enginePackageId = package.id
      part.productRevisionId = package.productRevisionId
      part.mainPart = true
    end
  end
  saveData()
  return package
end

local function removeBusinessPackage(packageId)
  local package = getPackageById(packageId)
  if not isBusinessPackage(package) then return false, "Business package not found." end
  for _, guard in ipairs(packageReferenceGuards) do
    local ok, reason = guard(package)
    if ok == false then return false, reason or "Package is protected." end
  end
  clearPackageFlags(package)
  removePackage(package.id, false)
  saveData()
  return true
end

local function addPersonalRecipeNode(node, packageId, vehicleModel, manufacturedYear, parentSlot, path)
  local copy = {name = node.name, slotName = node.slotName, children = {}}
  local before = {}
  for id in pairs(getPartInventory()) do before[tostring(id)] = true end
  career_modules_partInventory.addPartToInventory({
    name = node.name,
    vehicleModel = vehicleModel,
    value = getAuthoredPartValue(vehicleModel, node.name),
    slot = node.slotName or parentSlot,
    containingSlot = path or "/",
    location = 0,
    enginePackageId = packageId,
    year = manufacturedYear,
    manufacturedYear = manufacturedYear,
    engineShopManufactured = true,
    factoryPackageId = tostring(packageId),
    tags = {engineShopManufactured = true, manufacturedYear = manufacturedYear, factoryPackageId = tostring(packageId)},
    mainPart = true,
    partCondition = {integrityValue = 1, visualValue = 1, odometer = 0}
  })
  for id in pairs(getPartInventory()) do
    if not before[tostring(id)] then copy.partId = tonumber(id) or id break end
  end
  if not copy.partId then return nil, "Could not create a physical engine part." end
  -- Newer career saves reload the inventory as a list keyed by each row's
  -- explicit partId. The vanilla insertion helper only assigns the table key,
  -- so generated packages must mirror that key into the persisted record.
  getPartInventory()[copy.partId].partId = copy.partId
  for slotName, child in pairs(node.children or {}) do
    local childCopy, err = addPersonalRecipeNode(child, packageId, vehicleModel, manufacturedYear,
      slotName, (path or "/") .. slotName .. "/")
    if not childCopy then return nil, err end
    copy.children[slotName] = childCopy
  end
  return copy
end

local function addBusinessRecipeNode(node, packageId, vehicleModel, businessId, revisionId, manufacturedYear, parentSlot, path)
  local copy = {name = node.name, slotName = node.slotName, children = {}}
  local partId = career_modules_business_businessPartInventory.addPart({
    name = node.name,
    vehicleModel = vehicleModel,
    slot = node.slotName or parentSlot,
    containingSlot = path or "/",
    partPath = (path or "/") .. tostring(node.name or ""),
    location = 0,
    enginePackageId = packageId,
    productRevisionId = revisionId,
    year = manufacturedYear,
    manufacturedYear = manufacturedYear,
    engineShopManufactured = true,
    factoryPackageId = tostring(packageId),
    tags = {engineShopManufactured = true, manufacturedYear = manufacturedYear, factoryPackageId = tostring(packageId)},
    mainPart = true,
    partCondition = {integrityValue = 1, visualValue = 1, odometer = 0}
  }, businessId)
  if not partId then return nil, "Could not create a physical business engine part." end
  copy.partId = partId
  for slotName, child in pairs(node.children or {}) do
    local childCopy, err = addBusinessRecipeNode(child, packageId, vehicleModel, businessId, revisionId,
      manufacturedYear, slotName, (path or "/") .. slotName .. "/")
    if not childCopy then return nil, err end
    copy.children[slotName] = childCopy
  end
  return copy
end

local function cloneFreshPackageFromRecipe(recipe, name)
  if type(recipe) ~= "table" or type(recipe.tree) ~= "table" then return nil, "Recipe is incomplete." end
  if type(recipe.vehicleModel) ~= "string" or trim(recipe.vehicleModel) == "" then return nil, "Recipe has no compatible vehicle model." end
  local packageId = tostring(nextPackageId)
  local manufacturedYear = getCurrentManufacturingYear()
  local tree, err = addPersonalRecipeNode(recipe.tree, packageId, recipe.vehicleModel, manufacturedYear, recipe.rootSlotName, "/")
  if not tree then return nil, err end
  local package = {
    id = packageId,
    ownerType = "personal",
    name = uniquePackageName(name or recipe.name or "Manufactured Engine Package"),
    rootSlotName = recipe.rootSlotName,
    rootPath = recipe.rootPath,
    rootEngineName = tree.name,
    rootEngineNiceName = recipe.rootEngineNiceName or tree.name,
    tree = tree,
    tuning = deepcopy(recipe.tuning or {}),
    manufacturedYear = manufacturedYear,
    engineShopManufactured = true,
    manufacturedAt = os.time(),
    createdModel = recipe.vehicleModel,
    lastInstalledModel = recipe.vehicleModel,
    createdAt = os.time(), updatedAt = os.time()
  }
  nextPackageId = nextPackageId + 1
  packages[#packages + 1] = package
  saveData()
  return package
end

-- Retail and other systems can materialize a used or new physical package from
-- a recipe without duplicating the package/inventory invariants maintained here.
local function clonePersonalPackageFromRecipe(recipe, name, metadata)
  local package, err = cloneFreshPackageFromRecipe(recipe, name)
  if not package then return nil, err end
  metadata = metadata or {}
  local integrity = math.max(0, math.min(1, tonumber(metadata.integrity) or 1))
  local odometer = math.max(0, tonumber(metadata.odometer) or 0)
  local manufacturedYear = math.max(1, math.floor(tonumber(metadata.manufacturedYear)
    or package.manufacturedYear or getCurrentManufacturingYear()))
  package.manufacturedYear = manufacturedYear
  package.engineRetailListingId = metadata.listingId and tostring(metadata.listingId) or nil
  package.engineRetailShopId = metadata.shopId and tostring(metadata.shopId) or nil
  package.engineRetailType = metadata.type
  package.reliability = metadata.reliability
  package.aftermarketUnknown = metadata.aftermarketUnknown == true
  package.updatedAt = os.time()
  package.engineShopManufactured = nil
  package.factoryPackageId = nil
  package.manufacturedAt = nil
  package.engineRetailAcquiredAt = os.time()
  for _, partId in ipairs(getPartIdsFromPackageTree(package.tree)) do
    local part = getPartInventory()[tonumber(partId) or partId]
    if part then
      part.year = manufacturedYear
      part.manufacturedYear = manufacturedYear
      part.partCondition = {
        integrityValue = integrity,
        visualValue = math.max(0.2, math.min(1, tonumber(metadata.visual) or integrity)),
        odometer = odometer
      }
      part.tags = type(part.tags) == "table" and part.tags or {}
      part.tags.engineRetailListingId = package.engineRetailListingId
      part.tags.engineRetailShopId = package.engineRetailShopId
      part.tags.aftermarketUnknown = package.aftermarketUnknown
      part.engineShopManufactured = nil
      part.factoryPackageId = nil
      part.tags.engineShopManufactured = nil
      part.tags.factoryPackageId = nil
      part.tags.engineRetail = true
    end
  end
  if metadata.certification then
    package.engineShopCertification = deepcopy(metadata.certification)
  end
  saveData()
  return package
end

local function getRecipeValue(recipe, existingIoCtx, metadata)
  if type(recipe) ~= "table" or type(recipe.tree) ~= "table" or not recipe.vehicleModel then
    return nil, "Recipe is incomplete."
  end
  local vehicleDir = string.format("/vehicles/%s/", recipe.vehicleModel)
  local ioCtx = existingIoCtx or (FS:directoryExists(vehicleDir) and jbeamIO.startLoading({vehicleDir, "/vehicles/common/"}) or nil)
  if not ioCtx then return nil, "The recipe vehicle model is unavailable." end
  local available, total = jbeamIO.getAvailableParts(ioCtx) or {}, 0
  local function visit(node)
    local info = available[node.name] or {}
    local data = jbeamIO.getPart(ioCtx, node.name) or {}
    local value = math.max(0, tonumber(info.value)
      or tonumber(info.information and info.information.value)
      or tonumber(data.information and data.information.value) or 0)
    if metadata then
      -- Use the exact provenance and condition materialized by the retail clone.
      value = career_modules_valueCalculator.getPartValue({
        value = value,
        manufacturedYear = math.max(1, math.floor(tonumber(metadata.manufacturedYear) or getCurrentManufacturingYear())),
        partCondition = {
          odometer = math.max(0, tonumber(metadata.odometer) or 0),
          integrityValue = math.max(0, math.min(1, tonumber(metadata.integrity) or 1))
        }
      })
    end
    total = total + value
    for _, child in pairs(node.children or {}) do visit(child) end
  end
  visit(recipe.tree)
  return math.max(1, math.floor(total + 0.5))
end

local function getInstalledRecipeAndValue(inventoryId)
  inventoryId = tonumber(inventoryId)
  local vehicle = career_modules_inventory.getVehicles()[inventoryId]
  local runtimeData = getRuntimeVehicleData(inventoryId)
  if not vehicle or not runtimeData or not runtimeData.config then return nil, "The selected vehicle is not spawned." end
  local engine = getPrimaryEngine(runtimeData.config.partsTree, runtimeData.ioCtx)
  if not engine then return nil, "No installed engine was found." end
  local physicalTree, err = makePackageTree(engine.node, inventoryId)
  if not physicalTree then return nil, err end
  local enginePartName = engine.combustionPartName or findCombustionEnginePartName(engine.node, runtimeData.ioCtx)
    or physicalTree.name
  local recipe = {
    vehicleModel = vehicle.model,
    rootSlotName = engine.slotName,
    rootPath = engine.path,
    rootEngineName = enginePartName,
    rootEngineNiceName = getPartNiceName(runtimeData.ioCtx, enginePartName),
    tree = recipeTreeFromPackageNode(physicalTree),
    tuning = captureTuning(physicalTree, runtimeData, vehicle.config)
  }
  recipe.signature = computeRecipeSignature(recipe)
  local value = 0
  for _, partId in ipairs(getPartIdsFromPackageTree(physicalTree)) do
    local part = getPartInventory()[tonumber(partId) or partId]
    if part and career_modules_valueCalculator and career_modules_valueCalculator.getPartValue then
      value = value + math.max(0, tonumber(career_modules_valueCalculator.getPartValue(part)) or 0)
    end
  end
  return recipe, math.floor(value + 0.5)
end

local function consumeStoredPersonalPackage(packageId)
  local package = getPackageById(packageId)
  if not package or isBusinessPackage(package) then return false, "Personal Engine Package not found." end
  if getPackageStatus(package) ~= "stored" then return false, "Only a stored Engine Package can be traded in." end
  for _, guard in ipairs(packageReferenceGuards) do
    local ok, reason = guard(package)
    if ok == false then return false, reason or "Package is protected." end
  end
  local inventory = getPartInventory()
  for _, partId in ipairs(getPartIdsFromPackageTree(package.tree)) do inventory[tonumber(partId) or partId] = nil end
  deletePackageThumbnail(package.id)
  removePackage(package.id, false)
  saveData()
  if career_modules_partInventory.onPartShoppingTransactionComplete then
    career_modules_partInventory.onPartShoppingTransactionComplete()
  end
  return true
end

local function findCompatibleRecipeTarget(recipe, inventoryId)
  if type(recipe) ~= "table" or type(recipe.tree) ~= "table" then return nil, "Recipe is incomplete." end
  if vehicleIsElectric(inventoryId) then return nil, "Electric vehicles cannot swap engines." end
  local runtimeData = getRuntimeVehicleData(inventoryId)
  if not runtimeData or not runtimeData.config or not runtimeData.config.partsTree or not runtimeData.ioCtx then
    return nil, "The selected vehicle is not spawned."
  end
  local availableParts = jbeamIO.getAvailableParts(runtimeData.ioCtx)
  local matches = {}
  local seenPaths = {}
  local function tryCandidate(candidate)
    local path = tostring(candidate.path or "")
    if seenPaths[path] then return end
    seenPaths[path] = true
    local ok = validatePackageTreeFits(recipe.tree, candidate.parentPartName, candidate.slotName, runtimeData.ioCtx, availableParts)
    if ok then matches[#matches + 1] = candidate end
  end
  local remembered = rememberedAttachmentCandidate(recipe, runtimeData.config.partsTree)
  if remembered then tryCandidate(remembered) end
  for _, candidate in ipairs(findEngineCandidates(runtimeData.config.partsTree, true, runtimeData.ioCtx)) do
    tryCandidate(candidate)
  end
  if #matches == 0 then
    for _, candidate in ipairs(collectDeclaredEngineBayCandidates(runtimeData.config.partsTree, availableParts, runtimeData.ioCtx)) do
      tryCandidate(candidate)
    end
  end
  if #matches == 0 then return nil, "This engine recipe does not fit the selected vehicle." end
  for _, candidate in ipairs(matches) do
    if candidate.slotName == recipe.rootSlotName then
      return {slotName = candidate.slotName, path = candidate.path, parentPartName = candidate.parentPartName}
    end
  end
  if #matches > 1 then return nil, "More than one compatible engine slot was found." end
  local candidate = matches[1]
  return {slotName = candidate.slotName, path = candidate.path, parentPartName = candidate.parentPartName}
end

local function cloneFreshBusinessPackageFromRecipe(recipe, name, businessType, businessId, metadata)
  if type(recipe) ~= "table" or type(recipe.tree) ~= "table" or not recipe.vehicleModel then
    return nil, "Recipe is incomplete."
  end
  local packageId = tostring(nextPackageId)
  local revisionId = metadata and (metadata.blueprintId or metadata.productRevisionId)
  local manufacturedYear = math.max(1, math.floor(tonumber(metadata and metadata.manufacturedYear)
    or getCurrentManufacturingYear()))
  local tree, err = addBusinessRecipeNode(recipe.tree, packageId, recipe.vehicleModel, tostring(businessId),
    revisionId, manufacturedYear, recipe.rootSlotName, "/")
  if not tree then return nil, err end
  local package = {
    id = packageId,
    ownerType = "business",
    businessType = businessType,
    businessId = tostring(businessId),
    name = name or recipe.name or "Manufactured Engine Package",
    rootSlotName = recipe.rootSlotName,
    rootPath = recipe.rootPath,
    rootEngineName = tree.name,
    rootEngineNiceName = recipe.rootEngineNiceName or tree.name,
    tree = tree,
    tuning = deepcopy(recipe.tuning or {}),
    recipe = deepcopy(recipe),
    recipeSignature = recipe.signature or computeRecipeSignature(recipe),
    productRevisionId = revisionId,
    warehouseStock = true,
    manufacturedYear = manufacturedYear,
    engineShopManufactured = true,
    createdModel = recipe.vehicleModel,
    lastInstalledModel = recipe.vehicleModel,
    createdAt = os.time(), updatedAt = os.time()
  }
  for key, value in pairs(metadata or {}) do package[key] = deepcopy(value) end
  nextPackageId = nextPackageId + 1
  packages[#packages + 1] = package
  saveData()
  return package
end

local function transferBusinessPackageToPersonal(packageId, fallbackVehicleModel)
  local package = getPackageById(packageId)
  if not isBusinessPackage(package) then return nil, "Business Engine Package not found." end
  local businessInventory = getInventoryForPackage(package)
  local personalInventory = getPartInventory()
  local createdIds = {}
  local manufacturedYear = math.max(1, math.floor(tonumber(package.manufacturedYear)
    or getCurrentManufacturingYear()))
  markPackageAsManufactured(package, manufacturedYear)
  local function copyNode(node)
    local source = businessInventory[tonumber(node.partId) or node.partId]
    if not source then return nil, "A physical warehouse part is missing." end
    local before = {}
    for id in pairs(personalInventory) do before[tostring(id)] = true end
    local part = deepcopy(source)
    part.location, part.businessId, part.productRevisionId = 0, nil, nil
    part.partId = nil
    markPartAsManufactured(part, manufacturedYear, package.id)
    part.vehicleModel = part.vehicleModel or fallbackVehicleModel or package.createdModel
      or package.lastInstalledModel or package.vehicleModel or (package.recipe and package.recipe.vehicleModel)
    if not part.vehicleModel then return nil, "The warehouse engine has no compatible vehicle model." end
    part.enginePackageId, part.mainPart = tostring(package.id), true
    career_modules_partInventory.addPartToInventory(part)
    local newId
    for id in pairs(personalInventory) do if not before[tostring(id)] then newId = tonumber(id) or id break end end
    if not newId then return nil, "Could not transfer a warehouse engine part." end
    personalInventory[newId].partId = newId
    createdIds[#createdIds + 1] = newId
    local result = {name = node.name, slotName = node.slotName, relativeSlot = node.relativeSlot, partId = newId, children = {}}
    for slotName, child in pairs(node.children or {}) do
      local childResult, childError = copyNode(child)
      if not childResult then return nil, childError end
      result.children[slotName] = childResult
    end
    return result
  end
  local newTree, err = copyNode(package.tree)
  if not newTree then
    for _, partId in ipairs(createdIds) do personalInventory[partId] = nil end
    return nil, err
  end
  local oldIds = getPartIdsFromPackageTree(package.tree)
  package.tree = newTree
  package.ownerType = "personal"
  package.createdModel = package.createdModel or fallbackVehicleModel or package.lastInstalledModel
    or package.vehicleModel or (package.recipe and package.recipe.vehicleModel)
  package.lastInstalledModel = package.lastInstalledModel or package.createdModel
  package.manufacturedYear = manufacturedYear
  package.engineShopManufactured = true
  package.businessType, package.businessId, package.warehouseStock = nil, nil, nil
  package.productRevisionId, package.blueprintId = nil, nil
  package.updatedAt = os.time()
  for _, partId in ipairs(oldIds) do career_modules_business_businessPartInventory.removePart(partId) end
  repairPackageFlags()
  saveData()
  return package
end

-- Repairs pre-provenance Engine Works output without touching ordinary old
-- parts. The caller supplies IDs recorded by successful production attempts.
-- This also catches already-dismantled output: load-time package flag repair
-- temporarily retains its former package ID in orphanedEnginePackageId.
local function repairManufacturedPackageYears(manufacturedPackageIds, fallbackYear)
  local wanted = {}
  for key, value in pairs(manufacturedPackageIds or {}) do
    local packageId = type(key) == "number" and value or key
    if value == true then packageId = key end
    if packageId ~= nil then wanted[tostring(packageId)] = true end
  end
  fallbackYear = math.max(1, math.floor(tonumber(fallbackYear) or getCurrentManufacturingYear()))
  local changed, repairedParts = false, 0
  for _, package in ipairs(packages) do
    if wanted[tostring(package.id)] or package.engineShopManufactured == true
      or (package.manufacturedAt ~= nil and package.recipeSignature ~= nil) then
      changed = markPackageAsManufactured(package, package.manufacturedYear or fallbackYear) or changed
      wanted[tostring(package.id)] = true
    end
  end
  for _, part in pairs(getPartInventory()) do
    local formerId = tostring(part.factoryPackageId or part.orphanedEnginePackageId or "")
    if formerId ~= "" and wanted[formerId] then
      if markPartAsManufactured(part, part.manufacturedYear or fallbackYear, formerId) then repairedParts = repairedParts + 1 end
      part.orphanedEnginePackageId = nil
      changed = true
    end
  end
  if changed then
    repairPackageFlags()
    saveData()
    -- The stock part inventory persists on its vehicle-save hook rather than
    -- exposing a save method. Invoke that same hook so a one-time legacy
    -- repair survives even when the player does not modify a vehicle first.
    local savePath = getCurrentSavePath()
    if savePath and career_modules_partInventory and career_modules_partInventory.onVehicleSaveFinished then
      pcall(career_modules_partInventory.onVehicleSaveFinished, savePath)
    end
    if career_modules_business_businessPartInventory and career_modules_business_businessPartInventory.saveInventory then
      career_modules_business_businessPartInventory.saveInventory()
    end
  end
  return {changed = changed, repairedParts = repairedParts, manufacturedYear = fallbackYear}
end

local function installPackageIntoVehicle(packageId, inventoryId, callback)
  if transactionBusy then return false, "Another engine package transaction is in progress." end
  currentInventoryId = tonumber(inventoryId)
  if not currentInventoryId then return false, "Target vehicle not found." end
  activeInstallCallback = type(callback) == "function" and callback or nil
  installPackage(packageId)
  if not transactionBusy then
    activeInstallCallback = nil
    return false, "The engine installation could not be started."
  end
  return true
end

local function storePackageFromVehicle(packageId, inventoryId, callback)
  if transactionBusy then return false, "Another engine package transaction is in progress." end
  currentInventoryId = tonumber(inventoryId)
  if not currentInventoryId then return false, "Target vehicle not found." end
  activeInstallCallback = type(callback) == "function" and callback or nil
  storeInstalledPackage(packageId)
  if not transactionBusy then
    activeInstallCallback = nil
    return false, "The installed engine could not be removed."
  end
  return true
end

local function onExtensionLoaded()
  if not career_career.isActive() then return false end
  initialize()
end

local function onCareerActivated()
  initialize()
end

local function onCareerModulesActivated()
  initialize()
end

M.openMenu = openMenu
M.requestData = requestData
M.createFromCurrent = createFromCurrent
M.renamePackage = renamePackage
M.installPackage = installPackage
M.storeInstalledPackage = storeInstalledPackage
M.dismantlePackage = dismantlePackage
M.sellPackage = sellPackage
M.closeMenu = closeMenu
M.getPackage = getPackageById
M.getPackageDetails = getPackageDetails
M.listPackages = listPackages
M.upsertBusinessPackage = upsertBusinessPackage
M.removeBusinessPackage = removeBusinessPackage
M.cloneFreshPackageFromRecipe = cloneFreshPackageFromRecipe
M.clonePersonalPackageFromRecipe = clonePersonalPackageFromRecipe
M.getFreshRecipeValue = function(recipe, existingIoCtx)
  return getRecipeValue(recipe, existingIoCtx)
end
M.getConditionedRecipeValue = function(recipe, metadata, existingIoCtx)
  return getRecipeValue(recipe, existingIoCtx, metadata or {})
end
M.getInstalledRecipeAndValue = getInstalledRecipeAndValue
M.consumeStoredPersonalPackage = consumeStoredPersonalPackage
M.cloneFreshBusinessPackageFromRecipe = cloneFreshBusinessPackageFromRecipe
M.transferBusinessPackageToPersonal = transferBusinessPackageToPersonal
M.repairManufacturedPackageYears = repairManufacturedPackageYears
M.getCurrentManufacturingYear = getCurrentManufacturingYear
M.installPackageIntoVehicle = installPackageIntoVehicle
M.storePackageFromVehicle = storePackageFromVehicle
M.getRecipeFromPackage = getRecipeFromPackage
M.getFreshPackageValue = getFreshPackageValue
M.setEngineShopCertification = setEngineShopCertification
M.computeRecipeSignature = computeRecipeSignature
M.getEngineCompatibilityKey = getEngineCompatibilityKey
M.registerPackageReferenceGuard = registerPackageReferenceGuard
M.filterRecipeTuning = filterRecipeTuning
M.getPackageStatus = getPackageStatus
M.getPartIdsFromPackageTree = getPartIdsFromPackageTree
M.validatePackageTreeFits = validatePackageTreeFits
M.findCompatibleRecipeTarget = findCompatibleRecipeTarget
M.findEngineAssemblyCandidates = findEngineCandidates
M.getPackageThumbnailPath = getPackageThumbnailPath

local function onVehicleSpawned(vehId)
  -- A same-model replace during thumbnail capture re-applies the engine-only
  -- highlight map from freeroam. Put the meshes back once this object exists.
  if not isolatedVehicleIds[vehId] then return end
  restoreVehiclePartVisibility(getObjectByID(vehId), vehId)
end

M.onExtensionLoaded = onExtensionLoaded
M.onCareerActivated = onCareerActivated
M.onCareerModulesActivated = onCareerModulesActivated
M.onComputerAddFunctions = onComputerAddFunctions
M.onPartShoppingTransactionComplete = onPartShoppingTransactionComplete
M.onCareerTuningApplied = onCareerTuningApplied
M.onVehicleRemoved = onVehicleRemoved
M.onVehicleSpawned = onVehicleSpawned
M.onSaveCurrentProfile = onSaveCurrentProfile

return M
