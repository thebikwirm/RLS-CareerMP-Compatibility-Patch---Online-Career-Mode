-- Keep accepted material work deliverable when a map retires material aliases/routes.
-- This adds access only for saved active contracts; it never creates generators.
local M = {}
function M.restoreMaterialAccess(data, api)
  local saved=data.materialContracts or {}
  local contracts={}
  for _,contract in pairs(saved.activeContracts or {}) do contracts[#contracts+1]=contract end
  if saved.activeContract then contracts[#contracts+1]=saved.activeContract end
  local aliasesByContract={}
  local restored=0
  local function enable(location, materialType, provider, quantity)
    local facility=location and api.getFacility(location.facId)
    if not facility then return end
    local spot=api.getSpot(location.psPath)
    if not spot then return end
    local name=spot.name
    local ap=facility.accessPointsByName[name] or {name=name,facId=facility.id,psPath=location.psPath,ps=spot,
      logisticTypesProvidedLookup={},logisticTypesReceivedLookup={}}
    facility.accessPointsByName[name]=ap
    local key=provider and 'logisticTypesProvidedLookup' or 'logisticTypesReceivedLookup'
    ap[key][materialType]=true
    facility[key][materialType]=true
    local spots=provider and facility.pickUpSpots or facility.dropOffSpots
    local found=false;for _,existing in ipairs(spots)do if existing==spot then found=true end end
    if not found then spots[#spots+1]=spot end
    local storage=facility.materialStorages[materialType] or {materialType=materialType,id=facility.id..'-storage-'..materialType,
      target=provider and quantity or 0,storedVolume=provider and quantity or 0,capacity=quantity,standardLoad=quantity,maxContractVolume=quantity}
    storage[provider and 'isProvider' or 'isReceiver']=true
    storage.capacity=math.max(storage.capacity or 0,quantity)
    facility.materialStorages[materialType]=storage
    if api.getSystems then
      local systems=facility[provider and 'providedSystemsLookup' or 'receivedSystemsLookup']
      for system,enabled in pairs(api.getSystems(materialType,facility))do
        if enabled then systems[system]=true end
      end
    end
  end
  for _,contract in ipairs(contracts)do
    if contract.status~='completed' and (contract.deliveredAmount or 0)<(contract.totalAmount or 0) then
      local source=api.getFacility(contract.sourceFacId)
      if source and source.legacyMaterialAliases then
        local oldType=contract.materialType
        local material=(source.legacyMaterialAliases or {})[oldType] or oldType
        if api.getMaterial(material) then
          contract.materialType=material
          aliasesByContract[contract.id]=material
          enable(contract.origin,material,true,contract.totalAmount)
          enable(contract.destination,material,false,contract.totalAmount)
          restored=restored+1
        end
      end
    end
  end
  for _,cargo in ipairs(data.parcels or {})do
    local material=cargo.data and aliasesByContract[cargo.data.materialContractId]
    if material then cargo.materialType=material end
  end
  return restored
end
return M
