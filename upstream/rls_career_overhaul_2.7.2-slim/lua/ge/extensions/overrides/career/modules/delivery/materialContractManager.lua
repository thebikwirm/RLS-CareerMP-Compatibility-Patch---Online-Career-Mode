-- Predetermined, multi-load bulk material hauling contracts.
local M = {}
local contractAmounts=require('gameplay/delivery/materialContractAmounts')

local sharedCalc = require('gameplay/delivery/calculators')
local xpConfig = require('gameplay/delivery/logisticsXPConfig')
local balance = require('gameplay/delivery/logisticsBalance')

local dGenerator, dGeneral, dParcelManager, dCargoScreen
local state = {
  offersByFacility = {},
  nextRefillByFacility = {},
  activeContracts = {},
  nextContractId = 1,
  storageModelVersion = 2,
  contractStateVersion = 2,
}
local initialized = false
local updateAccumulator = 0
local taskGuidanceVisible = {}
local lastTaskGuidanceSignatures = {}
local legacyMaterialTaskId = "material-contract-active"

local function materialTaskId(contractId)
  return "material-contract-active-" .. tostring(contractId)
end

local function sortedKeys(tbl)
  local keys = {}
  for key in pairs(tbl or {}) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

local function rules()
  return xpConfig.getMaterialContractRules()
end

local function now()
  return dGeneral and dGeneral.time and dGeneral.time() or 0
end

local function roundReward(value)
  return math.floor((tonumber(value) or 0) + 0.5)
end

local function getStandardLoad(materialType, materialData)
  local cfg = rules()
  local materialOverride = cfg.standardLoadByMaterial[materialType]
  if materialOverride then return materialOverride end
  local cargoType = materialData and materialData.type or materialType
  return cfg.standardLoadByType[cargoType] or 1
end
M.getStandardLoad = getStandardLoad

local function isSecureMaterial(materialType)
  return materialType == "cash" or materialType == "coin" or materialType == "gold"
end

local function getLoadRange(materialType, materialData)
  local cfg = rules()
  if isSecureMaterial(materialType) then
    return cfg.secureLoadCount.min, cfg.secureLoadCount.max
  end
  return cfg.bulkLoadCount.min, cfg.bulkLoadCount.max
end
M.getLoadRange = getLoadRange

local function getTripLoads(cargoType, standardLoad)
  local sizes = {}
  for _, size in ipairs(rules().tripLoadsByType[cargoType] or {}) do
    if size < standardLoad then sizes[#sizes + 1] = size end
  end
  table.sort(sizes)
  sizes[#sizes + 1] = standardLoad
  return sizes
end
M.getTripLoads = getTripLoads

local function tripLoadForCapacity(sizes, capacity)
  local chosen
  for _, size in ipairs(sizes) do
    if size <= capacity then chosen = size end
  end
  return chosen or math.max(1, math.floor(capacity))
end

local function leastOfferedTripLoad(facId, cargoType, sizes)
  local counts = {}
  for _, offer in ipairs(state.offersByFacility[facId] or {}) do
    local size = tonumber(offer.standardLoad)
    if offer.cargoType == cargoType and offer.quantityMode ~= "exact" and size then
      counts[size] = (counts[size] or 0) + 1
    end
  end
  local fewest, pool = math.huge, {}
  for _, size in ipairs(sizes) do
    local count = counts[size] or 0
    if count < fewest then
      fewest, pool = count, {size}
    elseif count == fewest then
      pool[#pool + 1] = size
    end
  end
  return pool[math.random(1, #pool)]
end

function M.getEmploymentTripLimits()
  local trips = rules().employmentTrips
  return trips.preferred, trips.max
end

local function locationForAccessPoint(facility, accessPoint)
  if not facility or not accessPoint then return nil end
  local path = accessPoint.psPath
  if not path and accessPoint.ps and accessPoint.ps.getPath then path = accessPoint.ps:getPath() end
  if not path then return nil end
  return {type = "facilityParkingspot", facId = facility.id, psPath = path}
end

local function findAccessPoint(facility, materialType, lookupKey, preferredName)
  if not facility then return nil end
  local function usable(accessPoint)
    return accessPoint and accessPoint[lookupKey] and accessPoint[lookupKey][materialType]
      and locationForAccessPoint(facility, accessPoint)
  end
  if preferredName and facility.accessPointsByName then
    local preferred = facility.accessPointsByName[preferredName]
    if usable(preferred) then return preferred end
  end
  for _, name in ipairs(sortedKeys(facility.accessPointsByName)) do
    local accessPoint = facility.accessPointsByName[name]
    if usable(accessPoint) then return accessPoint end
  end
  return nil
end

local function getStorage(facId, materialType)
  local fac = dGenerator and dGenerator.getFacilityById and dGenerator.getFacilityById(facId)
  return fac, fac and fac.materialStorages and fac.materialStorages[materialType]
end

local function getLogisticsMoneyBonusMultiplier()
  return balance.getLevelBonus(xpConfig.getLogisticsLevel())
end

local function getOrganizationMoneyMultiplier(organization)
  if not organization or not freeroam_organizations or not freeroam_organizations.getOrganization then return 1 end
  local data = freeroam_organizations.getOrganization(organization)
  local level = data and data.reputation and tonumber(data.reputation.level) or 0
  local levelData = data and data.reputationLevels and data.reputationLevels[level + 2]
  return math.max(0, tonumber(levelData and levelData.deliveryBonus and levelData.deliveryBonus.value) or 1)
end

local function buildQuotedRewards(materialData, materialType, amount, distance, organization)
  local baseMoney = sharedCalc.getMaterialReward(materialData, amount).money
  local organizationMultiplier = getOrganizationMoneyMultiplier(organization)
  local ok, quoted = pcall(sharedCalc.getMaterialXPReward, distance, amount, organization, organizationMultiplier, nil, baseMoney, materialData.type)
  if not ok or type(quoted) ~= "table" then
    quoted = sharedCalc.getMaterialReward(materialData, amount, distance)
    local fallbackMoney = quoted.money
    if type(fallbackMoney) == "number" and sharedCalc.applyEconomyAdjuster then
      quoted.money = sharedCalc.applyEconomyAdjuster(fallbackMoney, "delivery_" .. (materialData.type or materialType or "fluid"))
    end
  end

  -- The shared calculator exposes a legacy alias and the canonical skill key.
  -- Keep only the canonical value so normalization cannot double-award XP.
  if quoted["logistics-delivery"] ~= nil then quoted.logistics = nil end

  quoted.money = math.max(0, roundReward(quoted.money or 0))
  local levelMultiplier = getLogisticsMoneyBonusMultiplier()
  if levelMultiplier > 0 then
    quoted.money = quoted.money + roundReward(quoted.money * levelMultiplier)
  end
  for key, value in pairs(quoted) do
    if key ~= "economyMultiplier" then quoted[key] = roundReward(value) end
  end
  return quoted
end

local function existingPairLookup(facId)
  local used = {}
  for _, offer in ipairs(state.offersByFacility[facId] or {}) do
    used[string.format("%s|%s|%s", offer.materialType, offer.destination.facId, offer.offerMode or "shared")] = true
  end
  return used
end

local function buildCandidates(sourceFac)
  local candidates = {}
  local usedPairs = existingPairLookup(sourceFac.id)
  for _, generator in ipairs(sourceFac.logisticGenerators or {}) do
    local materialType = generator.materialType
    local sourceStorage = sourceFac.materialStorages and sourceFac.materialStorages[materialType]
    local materialData = dGenerator.getMaterialsTemplatesById(materialType)
    if generator.type == 'materialProvider' and sourceStorage and sourceStorage.isProvider and materialData then
      local quantity, err = contractAmounts.resolve(generator, getStandardLoad(materialType, materialData), getLoadRange(materialType, materialData))
      if err then
        if not generator._quantityErrorLogged then log('E', 'materialContracts', sourceFac.id .. ': ' .. err); generator._quantityErrorLogged = true end
      else
        local origin = locationForAccessPoint(sourceFac, findAccessPoint(sourceFac, materialType,
          'logisticTypesProvidedLookup', generator.pickUpSpotName or sourceStorage.pickUpSpotName))
        if origin then
          for _, destinationFac in ipairs(dGenerator.getFacilities() or {}) do
            local destinationStorage = destinationFac.materialStorages and destinationFac.materialStorages[materialType]
            local pairKey = materialType .. '|' .. destinationFac.id .. '|' .. (generator.offerMode or 'shared')
            if destinationFac.id ~= sourceFac.id and destinationStorage and destinationStorage.isReceiver
              and not usedPairs[pairKey] and contractAmounts.destinationAllowed(generator, nil, destinationFac.id) then
              local destination = locationForAccessPoint(destinationFac, findAccessPoint(destinationFac, materialType, 'logisticTypesReceivedLookup'))
              local distance = destination and dGenerator.getDistanceBetweenFacilities(origin, destination)
              if distance and distance >= 0 then
                candidates[#candidates + 1] = {sourceFac=sourceFac, sourceStorage=sourceStorage,
                  destinationFac=destinationFac, destinationStorage=destinationStorage, materialType=materialType,
                  materialData=materialData, origin=origin, destination=destination, standardLoad=quantity.standardLoad,
                  minLoads=quantity.minLoads, maxLoads=quantity.maxLoads, quantity=quantity, distance=distance, offerMode=generator.offerMode}
              end
            end
          end
        end
      end
    end
  end
  table.sort(candidates, function(a,b)
    if a.distance ~= b.distance then return a.distance < b.distance end
    if a.materialType ~= b.materialType then return a.materialType < b.materialType end
    return a.destinationFac.id < b.destinationFac.id
  end)
  return candidates
end

local function chooseDistanceDiverseCandidate(candidates, existingCount)
  if #candidates == 0 then return nil end
  local desiredBand = (existingCount % 3) + 1
  local band = {}
  for index, candidate in ipairs(candidates) do
    local candidateBand = math.min(3, math.floor((index - 1) * 3 / #candidates) + 1)
    if candidateBand == desiredBand then band[#band + 1] = candidate end
  end
  local pool = #band > 0 and band or candidates
  return pool[math.random(1, #pool)]
end

local function sizedCandidates(candidates, opts)
  if type(opts.tripCapacity) ~= "function" then return candidates end
  local filtered = {}
  for _, candidate in ipairs(candidates) do
    local shape = {materialType = candidate.materialType, cargoType = candidate.materialData.type, offerMode = candidate.offerMode}
    local visible = not opts.audience or dGeneral.isOfferAvailable(shape, opts.audience)
    local allowed = visible and (type(opts.allows) ~= "function" or opts.allows(shape))
    local capacity = allowed and tonumber(opts.tripCapacity(shape.cargoType))
    if capacity and capacity > 0 then
      candidate.tripCapacity = capacity
      filtered[#filtered + 1] = candidate
    end
  end
  return filtered
end

local function candidateQuantity(fac, candidate)
  local quantity = candidate.quantity
  if quantity.amounts or isSecureMaterial(candidate.materialType) then return quantity end
  local sized = deepcopy(quantity)
  local sizes = getTripLoads(candidate.materialData.type, candidate.standardLoad)
  sized.standardLoad = candidate.tripCapacity and tripLoadForCapacity(sizes, candidate.tripCapacity)
    or leastOfferedTripLoad(fac.id, candidate.materialData.type, sizes)
  local range = rules().bulkLoadCount
  if sized.minLoads == range.min and sized.maxLoads == range.max then
    sized.loadWeights = rules().bulkLoadWeights
  end
  return sized
end

local function buildOffer(fac, offers, opts)
  local candidate = chooseDistanceDiverseCandidate(sizedCandidates(buildCandidates(fac), opts), #offers)
  if not candidate then return nil end
  local quantity = candidateQuantity(fac, candidate)
  local totalAmount, loadCount, quantityMode = contractAmounts.choose(quantity)
  local organization = fac.associatedOrganization
  local id = string.format("material-contract-%d", state.nextContractId)
  state.nextContractId = state.nextContractId + 1
  local quotedRewards = buildQuotedRewards(candidate.materialData, candidate.materialType, totalAmount, candidate.distance, organization)
  local createdAt = now()
  local offer = {
    id = id,
    status = "available",
    createdAt = createdAt,
    offerExpiresAt = createdAt + rules().offerDuration,
    sourceFacId = fac.id,
    sourceName = fac.name,
    destinationFacId = candidate.destinationFac.id,
    destinationName = candidate.destinationFac.name,
    origin = deepcopy(candidate.origin),
    destination = deepcopy(candidate.destination),
    materialType = candidate.materialType,
    materialName = candidate.materialData.name,
    cargoType = candidate.materialData.type,
    units = candidate.materialData.units or "L",
    density = candidate.materialData.density,
    standardLoad = quantity.standardLoad,
    loadCount = loadCount,
    quantityMode = quantityMode,
    configuredAmounts = deepcopy(candidate.quantity.amounts),
    minLoads = candidate.minLoads,
    maxLoads = candidate.maxLoads,
    totalAmount = totalAmount,
    routeDistance = candidate.distance,
    routeFactor = sharedCalc.getMaterialRouteFactor(candidate.distance),
    quotedRewards = quotedRewards,
    payRevision = balance.payRevision,
    organization = organization,
    offerMode = candidate.offerMode,
    usesVirtualStorage = true,
  }
  return offer
end

local function generateOfferForFacility(facId, opts)
  if not initialized then return nil end
  local fac = dGenerator.getFacilityById(facId)
  if not fac then return nil end
  state.offersByFacility[facId] = state.offersByFacility[facId] or {}
  local offers = state.offersByFacility[facId]
  if #offers >= rules().maxOffersPerFacility then return nil end
  local offer = buildOffer(fac, offers, type(opts) == "table" and opts or {})
  if offer then offers[#offers + 1] = offer end
  return offer
end
M.generateOfferForFacility = function(facId, opts)return generateOfferForFacility(facId, opts)end
local function expireOffersForFacility(facId)
  local currentTime = now()
  local kept = {}
  local changed = false
  for _, offer in ipairs(state.offersByFacility[facId] or {}) do
    if offer.offerExpiresAt and offer.offerExpiresAt > currentTime and #kept < rules().maxOffersPerFacility then
      kept[#kept + 1] = offer
    else
      changed = true
    end
  end
  state.offersByFacility[facId] = kept
  return changed
end

local function notifyChanged()
  if guihooks then
    guihooks.trigger("materialContractsChanged", M.getUiState())
    guihooks.trigger("requestCargoDataSimple")
  end
end

function M.generateSizedOffer(facId, opts)
  if not initialized or type(opts) ~= "table" or type(opts.tripCapacity) ~= "function" then return nil end
  local fac = dGenerator.getFacilityById(facId)
  if not fac then return nil end
  expireOffersForFacility(facId)
  local offers = state.offersByFacility[facId]
  local offer = buildOffer(fac, offers, opts)
  if not offer then return nil end
  if #offers >= rules().maxOffersPerFacility then
    local oldest
    for index, existing in ipairs(offers) do
      local visible = not opts.audience or dGeneral.isOfferAvailable(existing, opts.audience)
      local replaceable = type(opts.replaceable) ~= "function" or opts.replaceable(existing)
      if visible and replaceable and (not oldest or (existing.createdAt or 0) < (offers[oldest].createdAt or 0)) then
        oldest = index
      end
    end
    if not oldest then return nil end
    table.remove(offers, oldest)
  end
  offers[#offers + 1] = offer
  notifyChanged()
  return offer
end

local function seedFacility(facId, amount)
  state.offersByFacility[facId] = state.offersByFacility[facId] or {}
  while #state.offersByFacility[facId] < amount do
    if not generateOfferForFacility(facId) then break end
  end
end

local function setup(savedState)
  local restoringContractState = type(savedState) == "table" and savedState.offersByFacility ~= nil
  state = {
    offersByFacility = {},
    nextRefillByFacility = {},
    activeContracts = {},
    nextContractId = 1,
    storageModelVersion = 2,
    contractStateVersion = 2,
  }
  local savedStorageModelVersion = type(savedState) == "table" and tonumber(savedState.storageModelVersion) or 1
  if type(savedState) == "table" then
    state.offersByFacility = deepcopy(savedState.offersByFacility or {})
    state.nextRefillByFacility = deepcopy(savedState.nextRefillByFacility or {})
    state.nextContractId = math.max(1, math.floor(tonumber(savedState.nextContractId) or 1))
    for _, offers in pairs(state.offersByFacility) do
      for _, offer in ipairs(offers) do
        offer.usesVirtualStorage = true
        if (tonumber(offer.payRevision) or 0) < balance.payRevision
            and balance.getMaterialPay({type = offer.cargoType})
            and balance.scaleSavedOfferRewards(offer.quotedRewards) then
          offer.quotedRewards.money = roundReward(offer.quotedRewards.money)
          offer.payRevision = balance.payRevision
        end
      end
    end

    local savedActiveContracts = savedState.activeContracts
    if type(savedActiveContracts) == "table" then
      for key, savedContract in pairs(savedActiveContracts) do
        if type(savedContract) == "table" then
          local contract = deepcopy(savedContract)
          contract.id = contract.id or tostring(key)
          state.activeContracts[contract.id] = contract
        end
      end
    end
    -- v1 stored one singleton. Wrap it without losing accepted time, partial
    -- rewards, or the pre-virtual-storage migration below.
    if type(savedState.activeContract) == "table" and savedState.activeContract.id
      and not state.activeContracts[savedState.activeContract.id] then
      state.activeContracts[savedState.activeContract.id] = deepcopy(savedState.activeContract)
    end
  end

  -- Pre-v2 contracts physically removed their full quantity from the source
  -- and added delivered loads to the receiver. Return that accounting once;
  -- project supply and project consumption are virtual from v2 onward.
  for contractId, contract in pairs(state.activeContracts) do
    contract.deliveredAmount = math.max(0, tonumber(contract.deliveredAmount) or 0)
    contract.paidRewards = contract.paidRewards or {}
    contract.escrowedRewards = contract.escrowedRewards or {}
    contract.status = contract.status == "completed" and "completed" or "active"
    if contract.deliveredAmount >= (contract.totalAmount or math.huge) then
      state.activeContracts[contractId] = nil
    else
      if savedStorageModelVersion < 2 and not contract.usesVirtualStorage then
        local _, sourceStorage = getStorage(contract.sourceFacId, contract.materialType)
        local _, destinationStorage = getStorage(contract.destinationFacId, contract.materialType)
        if sourceStorage then
          sourceStorage.storedVolume = math.min(sourceStorage.capacity or math.huge,
            (sourceStorage.storedVolume or 0) + (contract.totalAmount or 0))
        end
        if destinationStorage then
          destinationStorage.storedVolume = math.max(0,
            (destinationStorage.storedVolume or 0) - (contract.deliveredAmount or 0))
        end
      end
      contract.usesVirtualStorage = true
    end
  end
  for _,offers in pairs(state.offersByFacility) do
    for _,offer in ipairs(offers) do dGeneral.migrateOfferAccess(offer) end
  end
  for _,contract in pairs(state.activeContracts) do dGeneral.migrateOfferAccess(contract) end
  local persistence = require('gameplay/delivery/persistence')
  local currentMap = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
  local parked = {}
  for contractId, contract in pairs(state.activeContracts) do
    local onMap = dGenerator and dGenerator.getFacilityById and dGenerator.getFacilityById(contract.sourceFacId)
    if onMap then
      contract.homeMap = contract.homeMap or currentMap
    else
      local home = contract.homeMap or (persistence.ownerOfFacility and persistence.ownerOfFacility(contract.sourceFacId))
      if home and currentMap and home ~= currentMap then
        contract.homeMap = home
        parked[#parked + 1] = contract
        state.activeContracts[contractId] = nil
      end
    end
  end
  if #parked > 0 and persistence.parkMaterialContracts then persistence.parkMaterialContracts(parked) end
  initialized = true

  local currentTime = now()
  for _, fac in ipairs(dGenerator.getFacilities() or {}) do
    local hasProvider = false
    for _, storage in pairs(fac.materialStorages or {}) do
      if storage.isProvider then hasProvider = true break end
    end
    if hasProvider then
      state.offersByFacility[fac.id] = state.offersByFacility[fac.id] or {}
      expireOffersForFacility(fac.id)
      if not restoringContractState and #state.offersByFacility[fac.id] == 0 then
        seedFacility(fac.id, rules().initialOffersPerFacility)
      end
      state.nextRefillByFacility[fac.id] = tonumber(state.nextRefillByFacility[fac.id]) or (currentTime + rules().refillInterval)
    end
  end
end
M.setup = setup

local function serialize()
  return deepcopy(state)
end
M.serialize = serialize

function M.restoreParkedContracts(parked)
  local currentMap = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
  for id, contract in pairs(parked or {}) do
    if type(contract) == 'table' then
      local contractId = contract.id or id
      if not state.activeContracts[contractId] then
        contract.homeMap = contract.homeMap or currentMap
        state.activeContracts[contractId] = contract
      end
    end
  end
  if guihooks then guihooks.trigger('materialContractsChanged', M.getUiState()) end
end

local function getOffersForFacility(facId, audience)
  if not initialized then return {} end
  expireOffersForFacility(facId)
  local out={}
  for _,offer in ipairs(state.offersByFacility[facId] or {}) do
    if dGeneral.isOfferAvailable(offer,audience) then out[#out+1]=offer end
  end
  return deepcopy(out)
end
M.getOffersForFacility = getOffersForFacility

local function getAllOffers(audience)
  local result = {}
  if not initialized then return result end
  for _, facId in ipairs(sortedKeys(state.offersByFacility)) do
    for _, offer in ipairs(getOffersForFacility(facId,audience)) do result[#result + 1] = offer end
  end
  return result
end
M.getAllOffers = getAllOffers

local function findOffer(offerId)
  for facId, offers in pairs(state.offersByFacility) do
    for index, offer in ipairs(offers) do
      if offer.id == offerId then return offer, facId, index end
    end
  end
  return nil
end

local function sortedActiveContracts()
  local result = {}
  for _, contract in pairs(state.activeContracts or {}) do result[#result + 1] = contract end
  table.sort(result, function(a, b)
    local aAccepted = tonumber(a.acceptedAt) or 0
    local bAccepted = tonumber(b.acceptedAt) or 0
    if aAccepted ~= bAccepted then return aAccepted < bAccepted end
    return tostring(a.id) < tostring(b.id)
  end)
  return result
end

local function activeCargoAmounts(contractId)
  local active = state.activeContracts[contractId]
  if not active or not dParcelManager then return 0, 0 end
  local inTransit, pending = 0, 0
  for _, cargo in ipairs(dParcelManager.getAllCargoCustomFilter(function(cargo)
    return cargo.data and cargo.data.materialContractId == active.id and cargo.location and cargo.location.type ~= "deleted"
  end) or {}) do
    if cargo.location.type == "vehicle" then
      inTransit = inTransit + (tonumber(cargo.slots) or 0)
    elseif cargo._transientMove and cargo._transientMove.targetLocation and cargo._transientMove.targetLocation.type == "vehicle" then
      pending = pending + (tonumber(cargo.slots) or 0)
    end
  end
  return inTransit, pending
end
M.getActiveCargoAmounts = activeCargoAmounts

local function getContractEscrowRewards(active)
  if not active then return {} end
  if type(active.escrowedRewards) == "table" and next(active.escrowedRewards) then
    return deepcopy(active.escrowedRewards)
  end
  return deepcopy(active.paidRewards or {})
end

local function snapshotContract(contractId)
  local active = state.activeContracts[contractId]
  if not active then return nil end
  local result = deepcopy(active)
  local inTransit, pending = activeCargoAmounts(contractId)
  result.inTransitAmount = inTransit
  result.pendingLoadAmount = pending
  result.remainingAmount = math.max(0, result.totalAmount - (result.deliveredAmount or 0))
  result.loadableAmount = math.max(0, result.remainingAmount - inTransit - pending)
  result.sourceReservedAmount = math.max(0, result.remainingAmount - inTransit)
  result.receiverReservedAmount = result.remainingAmount
  result.escrowedRewards = getContractEscrowRewards(active)
  result.escrowedMoney = (result.escrowedRewards and result.escrowedRewards.money) or 0
  result.paidMoney = result.escrowedMoney
  result.remainingValue = math.max(0, (result.quotedRewards.money or 0) - ((result.paidRewards and result.paidRewards.money) or 0))
  result.abandonmentFine = roundReward(result.remainingValue * rules().abandonPenaltyFactor)
  return result
end

local function getActiveContracts()
  local result = {}
  for _, contract in ipairs(sortedActiveContracts()) do
    result[#result + 1] = snapshotContract(contract.id)
  end
  return result
end
M.getActiveContracts = getActiveContracts
M.getContractById = snapshotContract
local function getActiveContract(contractId)
  if contractId ~= nil then
    return snapshotContract(contractId)
  end
  local contracts = getActiveContracts()
  return contracts[1]
end
M.getActiveContract = getActiveContract

local function sameContractLocation(a, b)
  if not a or not b then return false end
  if dParcelManager and dParcelManager.sameLocation then
    return dParcelManager.sameLocation(a, b)
  end
  return a.type == b.type and a.facId == b.facId and a.psPath == b.psPath
end

-- Bulk material is fungible once it is in a player's container. The contract
-- used at pickup reserves how much may be loaded, but every active contract for
-- that exact material may consume it at its own receiver.
local function getContractsAcceptingMaterial(materialType, location)
  local result = {}
  for _, contract in ipairs(sortedActiveContracts()) do
    local remaining = math.max(0, (tonumber(contract.totalAmount) or 0) - (tonumber(contract.deliveredAmount) or 0))
    if contract.status == "active" and contract.materialType == materialType and remaining > 0
      and (not location or sameContractLocation(contract.destination, location)) then
      local accepting = deepcopy(contract)
      accepting.remainingAmount = remaining
      result[#result + 1] = accepting
    end
  end
  return result
end
M.getContractsAcceptingMaterial = getContractsAcceptingMaterial

local function getMaterialDeliveryCapacity(materialType, location)
  local capacity = 0
  for _, contract in ipairs(getContractsAcceptingMaterial(materialType, location)) do
    capacity = capacity + math.max(0, tonumber(contract.remainingAmount) or 0)
  end
  return capacity
end
M.getMaterialDeliveryCapacity = getMaterialDeliveryCapacity

local function formatTaskAmount(value, units)
  local amount = math.max(0, math.floor((tonumber(value) or 0) + 0.5))
  return string.format("%s %s", tostring(amount), tostring(units or "L"))
end

local function clearTaskGuidance(contractId)
  if contractId then
    if taskGuidanceVisible[contractId] and guihooks then
      guihooks.trigger("DiscardTasklistItem", materialTaskId(contractId))
    end
    taskGuidanceVisible[contractId] = nil
    lastTaskGuidanceSignatures[contractId] = nil
    return
  end
  if guihooks then
    for activeId in pairs(taskGuidanceVisible) do
      guihooks.trigger("DiscardTasklistItem", materialTaskId(activeId))
    end
    guihooks.trigger("DiscardTasklistItem", legacyMaterialTaskId)
  end
  taskGuidanceVisible = {}
  lastTaskGuidanceSignatures = {}
end

local function refreshTaskGuidance(force)
  local emp = career_modules_delivery_employment
  if emp and emp.isAssignmentPaused and emp.isAssignmentPaused() then
    clearTaskGuidance()
    return false
  end
  if emp and emp.isAwaitingPark and emp.isAwaitingPark() then
    clearTaskGuidance()
    return false
  end

  local seen = {}
  local shown = false
  local persistence = require('gameplay/delivery/persistence')
  for _, active in ipairs(getActiveContracts()) do
    local onMap = dGenerator and dGenerator.getFacilityById and dGenerator.getFacilityById(active.sourceFacId)
    if active.status == "active" and onMap and (not persistence.belongsHere or persistence.belongsHere(active)) then
      seen[active.id] = true
      shown = true

      local units = active.units or "L"
      local hasCargoInTransit = (active.inTransitAmount or 0) > 0
      local label
      if hasCargoInTransit then
        label = string.format("Deliver %s to %s", _tr(active.materialName), _tr(active.destinationName))
      else
        label = string.format("Go to %s loading point", _tr(active.sourceName))
      end
      local subtext = string.format(
        "%s delivered · %s in transit · %s remaining",
        formatTaskAmount(active.deliveredAmount, units),
        formatTaskAmount(active.inTransitAmount, units),
        formatTaskAmount(active.remainingAmount, units)
      )
      local signature = table.concat({label, subtext}, "|")
      if force or signature ~= lastTaskGuidanceSignatures[active.id] then
        if ui_appContainers and ui_appContainers.showApp then
          ui_appContainers.showApp("topLeft", "tasks")
        end
        if emp and emp.ownsHudTasklist and emp.ownsHudTasklist() and guihooks then
          local header = emp.getTasklistHeaderLabel and emp.getTasklistHeaderLabel()
          if header then
            guihooks.trigger("SetTasklistHeader", { label = header })
          end
        end
        guihooks.trigger("SetTasklistTask", {
          id = materialTaskId(active.id),
          label = label,
          subtext = subtext,
          active = true,
          type = "message",
        })
        lastTaskGuidanceSignatures[active.id] = signature
      end
      taskGuidanceVisible[active.id] = true
    end
  end
  local stale = {}
  for contractId in pairs(taskGuidanceVisible) do
    if not seen[contractId] then stale[#stale + 1] = contractId end
  end
  for _, contractId in ipairs(stale) do clearTaskGuidance(contractId) end
  return shown
end
M.refreshTaskGuidance = refreshTaskGuidance
M.clearTaskGuidance = clearTaskGuidance

local function canAcceptAtSource(offer)
  if not dCargoScreen or not dCargoScreen.isCargoScreenOpen or not dCargoScreen.isCargoScreenOpen() then return false end
  local location = dCargoScreen.getCargoScreenLocation and dCargoScreen.getCargoScreenLocation()
  return location and location.facId == offer.sourceFacId
end

local function activateOffer(offer, facId, index)
  local _, sourceStorage = getStorage(offer.sourceFacId, offer.materialType)
  local _, destinationStorage = getStorage(offer.destinationFacId, offer.materialType)
  if not sourceStorage or not sourceStorage.isProvider or not destinationStorage or not destinationStorage.isReceiver then
    table.remove(state.offersByFacility[facId], index)
    state.nextRefillByFacility[facId] = math.min(state.nextRefillByFacility[facId] or math.huge, now() + rules().refillInterval)
    ui_message("That material contract is no longer available.", 5, "warning")
    notifyChanged()
    return false
  end

  table.remove(state.offersByFacility[facId], index)
  local active = deepcopy(offer)
  active.status = "active"
  active.homeMap = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
  active.acceptedAt = now()
  active.deliveredAmount = 0
  active.paidRewards = {}
  active.escrowedRewards = {}
  active.usesVirtualStorage = true
  state.activeContracts[active.id] = active
  state.nextRefillByFacility[facId] = math.min(state.nextRefillByFacility[facId] or math.huge, now() + rules().refillInterval)
  ui_message(string.format("Contract accepted. Load %s at the %s loading point, then deliver it to %s.", _tr(offer.materialName), _tr(offer.sourceName), _tr(offer.destinationName)), 8, "info")
  refreshTaskGuidance(true)
  notifyChanged()
  return true
end

local function acceptContract(offerId)
  local emp = career_modules_delivery_employment
  if emp and emp.isOnShift and emp.isOnShift() then
    ui_message("Company work is assigned by dispatch while on shift.", 5, "warning")
    return false
  end
  local offer, facId, index = findOffer(offerId)
  if not dGeneral.canAcceptOffer(offer,"independent") then return false end
  if not offer or (offer.offerExpiresAt or 0) <= now() then return false end
  if not canAcceptAtSource(offer) then
    ui_message("Material contracts can only be accepted at their pickup facility.", 5, "warning")
    return false
  end
  return activateOffer(offer, facId, index)
end
M.acceptContract = acceptContract

-- Broker holds are accepted remotely; physical loading still validates the source and containers.
function M.acceptBrokerContract(offerId)
  local emp=career_modules_delivery_employment
  if emp and emp.isEmployed and emp.isEmployed() then return false end
  local offer,facId,index=findOffer(offerId)
  if not offer or (offer.offerExpiresAt or 0)<=now() or not dGeneral.canAcceptOffer(offer,'independent') then return false end
  return activateOffer(offer,facId,index)
end

-- Employment dispatch only. Independent cargo-board accept still uses acceptContract().
local function acceptAssignedOffer(offerId)
  local offer, facId, index = findOffer(offerId)
  if not dGeneral.canAcceptOffer(offer,"employment") then return false end
  if not offer or (offer.offerExpiresAt or 0) <= now() then return false end
  return activateOffer(offer, facId, index)
end
M.acceptAssignedOffer = acceptAssignedOffer

local function proportionalRewards(contractId, amount)
  local active = state.activeContracts[contractId]
  if not active then return {money = 0} end
  local ratio = math.max(0, tonumber(amount) or 0) / math.max(1, active.totalAmount)
  local result = {}
  for key, total in pairs(active.quotedRewards or {}) do
    result[key] = key == "economyMultiplier" and total or roundReward(total * ratio)
  end
  return result
end
M.getProportionalRewards = proportionalRewards

local function cumulativeRewardDelta(totalReward, totalAmount, beforeAmount, afterAmount)
  local divisor = math.max(1, tonumber(totalAmount) or 0)
  local before = clamp(tonumber(beforeAmount) or 0, 0, divisor)
  local after = clamp(tonumber(afterAmount) or 0, before, divisor)
  return roundReward((tonumber(totalReward) or 0) * after / divisor)
    - roundReward((tonumber(totalReward) or 0) * before / divisor)
end
M.calculateCumulativeRewardDelta = cumulativeRewardDelta

local function creditDelivery(contractId, amount)
  local active = state.activeContracts[contractId]
  if not active or active.status == "completed" then return nil end
  local before = active.deliveredAmount or 0
  local delivered = math.min(math.max(0, tonumber(amount) or 0), active.totalAmount - before)
  local after = before + delivered
  local rewards = {}
  active.paidRewards = active.paidRewards or {}
  active.escrowedRewards = active.escrowedRewards or {}
  for key, total in pairs(active.quotedRewards or {}) do
    if key ~= "economyMultiplier" then
      local cumulative = roundReward(total * after / math.max(1, active.totalAmount))
      rewards[key] = cumulativeRewardDelta(total, active.totalAmount, before, after)
      active.paidRewards[key] = cumulative
    end
  end
  active.deliveredAmount = after
  if after >= active.totalAmount - 0.0001 then active.status = "completed" end
  refreshTaskGuidance(true)
  return rewards
end
M.creditDelivery = creditDelivery

local function accrueEscrowRewards(contractId, rewards)
  local active = state.activeContracts[contractId]
  if not active or type(rewards) ~= "table" then return end
  active.escrowedRewards = active.escrowedRewards or {}
  for key, amount in pairs(rewards) do
    local value = tonumber(amount) or 0
    if value ~= 0 then
      active.escrowedRewards[key] = (tonumber(active.escrowedRewards[key]) or 0) + value
    end
  end
end
M.accrueEscrowRewards = accrueEscrowRewards

local function creditMaterialDelivery(materialType, location, amount)
  local remaining = math.max(0, tonumber(amount) or 0)
  local rewards = {money = 0}
  local credited = 0
  local allocations = {}

  for _, contract in ipairs(getContractsAcceptingMaterial(materialType, location)) do
    if remaining <= 0 then break end
    local allocationAmount = math.min(remaining, math.max(0, tonumber(contract.remainingAmount) or 0))
    if allocationAmount > 0 then
      local allocationRewards = creditDelivery(contract.id, allocationAmount) or {money = 0}
      for key, value in pairs(allocationRewards) do
        rewards[key] = (rewards[key] or 0) + value
      end
      allocations[#allocations + 1] = {
        contractId = contract.id,
        amount = allocationAmount,
        rewards = allocationRewards,
      }
      credited = credited + allocationAmount
      remaining = remaining - allocationAmount
    end
  end

  return rewards, credited, allocations
end
M.creditMaterialDelivery = creditMaterialDelivery

local function claimCompletedContractPayouts()
  local payouts = {}
  for _, active in ipairs(sortedActiveContracts()) do
    if active.status == "completed" then
      local rewards = getContractEscrowRewards(active)
      payouts[#payouts + 1] = {
        id = active.id,
        name = active.materialName,
        units = active.units,
        deliveredAmount = active.deliveredAmount or 0,
        totalAmount = active.totalAmount or 0,
        rewards = rewards,
        quotedRewards = deepcopy(active.quotedRewards or {}),
      }
    end
  end
  return payouts
end
M.claimCompletedContractPayouts = claimCompletedContractPayouts

local function getActiveContractProgressSnapshots(contractIds)
  local byId = {}
  if type(contractIds) == "table" then
    for _, id in ipairs(contractIds) do
      if id ~= nil then byId[tostring(id)] = true end
    end
  end
  local progress = {}
  for _, active in ipairs(sortedActiveContracts()) do
    if not next(byId) or byId[tostring(active.id)] then
      local snap = snapshotContract(active.id)
      if snap then
        progress[#progress + 1] = {
          id = snap.id,
          name = snap.materialName,
          units = snap.units,
          deliveredAmount = snap.deliveredAmount or 0,
          totalAmount = snap.totalAmount or 0,
          remainingAmount = snap.remainingAmount or 0,
          escrowedMoney = snap.escrowedMoney or 0,
          escrowedRewards = deepcopy(snap.escrowedRewards or {}),
          quotedRewards = deepcopy(snap.quotedRewards or {}),
          complete = snap.status == "completed",
        }
      end
    end
  end
  return progress
end
M.getActiveContractProgressSnapshots = getActiveContractProgressSnapshots

local function finalizeCompletedContracts()
  local completed = {}
  for _, active in ipairs(sortedActiveContracts()) do
    if active.status == "completed" then completed[#completed + 1] = active end
  end
  if #completed == 0 then return false end
  for _, active in ipairs(completed) do
    ui_message(string.format("Material contract complete: %s", _tr(active.materialName)), 6, "success")
    state.activeContracts[active.id] = nil
    clearTaskGuidance(active.id)
    local sourceFacId = active.sourceFacId
    state.nextRefillByFacility[sourceFacId] = math.min(state.nextRefillByFacility[sourceFacId] or math.huge, now() + rules().refillInterval)
  end
  notifyChanged()
  return true
end
M.finalizeCompletedContracts = finalizeCompletedContracts
M.finalizeCompletedContract = finalizeCompletedContracts

local function removeContractCargo(contractId)
  if not dParcelManager then return end
  local cargoItems = dParcelManager.getAllCargoCustomFilter(function(cargo)
    return cargo.data and cargo.data.materialContractId == contractId and cargo.location and cargo.location.type ~= "deleted"
  end) or {}
  for _, cargo in ipairs(cargoItems) do
    if cargo._transientMove and dParcelManager.clearTransientMoveForCargo then
      dParcelManager.clearTransientMoveForCargo(cargo.id)
    end
    dParcelManager.changeCargoLocation(cargo.id, {type = "deleted"})
  end
end

local function abandonContract(contractId, opts)
  opts = type(opts) == "table" and opts or {}
  if contractId == nil then
    local any = false
    for _, active in ipairs(sortedActiveContracts()) do
      if abandonContract(active.id, opts) then any = true end
    end
    if not any then
      clearTaskGuidance()
    end
    return any
  end
  local active = state.activeContracts[contractId]
  if not active then return false end
  local remainingValue = math.max(0, (active.quotedRewards.money or 0) - ((active.paidRewards and active.paidRewards.money) or 0))
  local fine = roundReward(remainingValue * rules().abandonPenaltyFactor)
  removeContractCargo(active.id)
  if fine > 0 and not opts.noFine then
    career_modules_playerAttributes.addAttributes({money = -fine}, {
      tags = {"gameplay", "delivery", "fine"},
      label = "Material Contract Abandonment"
    })
  end
  local sourceFacId = active.sourceFacId
  state.activeContracts[active.id] = nil
  clearTaskGuidance(active.id)
  state.nextRefillByFacility[sourceFacId] = math.min(state.nextRefillByFacility[sourceFacId] or math.huge, now() + rules().refillInterval)
  if not opts.silent then
    if opts.noFine or fine <= 0 then
      ui_message("Material contract abandoned.", 6, "info")
    else
      ui_message(string.format("Material contract abandoned. Penalty: $%d", fine), 6, "warning")
    end
  end
  notifyChanged()
  if dGeneral and dGeneral.checkExitDeliveryMode then dGeneral.checkExitDeliveryMode() end
  return true
end
M.abandonContract = abandonContract

local function getUiState()
  return {
    offers = getAllOffers(),
    activeContracts = getActiveContracts(),
  }
end
M.getUiState = getUiState

local function onUpdate(dtReal, dtSim)
  if not initialized then return end
  updateAccumulator = updateAccumulator + (dtSim or 0)
  if updateAccumulator < 1 then return end
  updateAccumulator = updateAccumulator - 1
  local changed = false
  local currentTime = now()
  for facId in pairs(state.offersByFacility) do
    changed = expireOffersForFacility(facId) or changed
    local offers = state.offersByFacility[facId]
    if #offers < rules().maxOffersPerFacility and currentTime >= (state.nextRefillByFacility[facId] or 0) then
      if generateOfferForFacility(facId) then changed = true end
      state.nextRefillByFacility[facId] = currentTime + rules().refillInterval
    end
  end
  if changed then notifyChanged() end
  refreshTaskGuidance(false)
end
M.onUpdate = onUpdate

M.onCareerActivated = function()
  dGenerator = career_modules_delivery_generator
  dGeneral = career_modules_delivery_general
  dParcelManager = career_modules_delivery_parcelManager
  dCargoScreen = career_modules_delivery_cargoScreen
  taskGuidanceVisible = {}
  lastTaskGuidanceSignatures = {}
end

M.isInitialized = function() return initialized end

M.runInvariantTests = function()
  local cfg = rules()
  local result = {errors = {}, offerCount = 0, facilityCounts = {}}
  local function check(condition, message)
    if not condition then result.errors[#result.errors + 1] = message end
  end

  check(math.abs(sharedCalc.getMaterialRouteFactor(1000) - 0.55) < 0.000001, "1 km route factor is not 0.55")
  check(math.abs(sharedCalc.getMaterialRouteFactor(4000) - 1.15) < 0.000001, "4 km route factor is not 1.15")
  check(getStandardLoad("water", dGenerator.getMaterialsTemplatesById("water")) == 17000, "fluid standard load mismatch")
  check(getStandardLoad("sand", dGenerator.getMaterialsTemplatesById("sand")) == 15600, "dry-bulk standard load mismatch")
  check(getStandardLoad("cement", dGenerator.getMaterialsTemplatesById("cement")) == 7800, "concrete standard load mismatch")
  check(getStandardLoad("cash", dGenerator.getMaterialsTemplatesById("cash")) == 500, "cash secure load mismatch")
  check(getStandardLoad("coin", dGenerator.getMaterialsTemplatesById("coin")) == 100, "coin secure load mismatch")
  check(getStandardLoad("gold", dGenerator.getMaterialsTemplatesById("gold")) == 250, "gold secure load mismatch")
  local deltaSum, before = 0, 0
  for _, after in ipairs({1, 4, 7, 10}) do
    deltaSum = deltaSum + cumulativeRewardDelta(101, 10, before, after)
    before = after
  end
  check(deltaSum == 101, "cumulative split rewards do not equal the quote")

  local activeIds = {}
  for _, contract in ipairs(getActiveContracts()) do
    check(not activeIds[contract.id], "duplicate active contract id " .. tostring(contract.id))
    activeIds[contract.id] = true
    check(contract.status == "active" or contract.status == "completed", "invalid active contract status")
    check(contract.usesVirtualStorage == true, "active contract still depends on physical storage capacity")
  end

  for facId, offers in pairs(state.offersByFacility or {}) do
    result.facilityCounts[facId] = #offers
    check(#offers <= cfg.maxOffersPerFacility, "offer cap exceeded at " .. tostring(facId))
    local pairsSeen = {}
    for _, offer in ipairs(offers) do
      result.offerCount = result.offerCount + 1
      check(offer.origin and offer.origin.type == "facilityParkingspot", "offer has no fixed source")
      check(offer.destination and offer.destination.type == "facilityParkingspot", "offer has no fixed receiver")
      check(math.abs((offer.offerExpiresAt - offer.createdAt) - cfg.offerDuration) < 0.001, "offer duration is not frozen at 15 delivery minutes")
      if offer.quantityMode == 'exact' then
        local valid = false
        for _, amount in ipairs(offer.configuredAmounts or {}) do if amount == offer.totalAmount then valid = true end end
        check(valid, 'offer quantity is outside its configured amounts')
      else
        check(offer.totalAmount == offer.standardLoad * offer.loadCount, 'offer quantity is outside its load band')
      end
      check(offer.usesVirtualStorage == true, "offer still depends on physical storage capacity")
      local minLoads, maxLoads = getLoadRange(offer.materialType, dGenerator.getMaterialsTemplatesById(offer.materialType))
      check(offer.quantityMode == 'exact' or (offer.loadCount >= (offer.minLoads or minLoads) and offer.loadCount <= (offer.maxLoads or maxLoads)), "offer load count is outside configured range")
      local pairKey = tostring(offer.materialType) .. "|" .. tostring(offer.destinationFacId) .. "|" .. (offer.offerMode or "shared")
      check(not pairsSeen[pairKey], "duplicate material/receiver pair at " .. tostring(facId))
      pairsSeen[pairKey] = true
    end
  end

  result.ok = #result.errors == 0
  result.serializable = pcall(jsonEncode, serialize())
  check(result.serializable, "contract state is not JSON serializable")
  result.ok = #result.errors == 0
  return result
end

return M
