-- A shared organization is not a facility's purpose. Map packs can reuse an
-- organization ID for a bus fleet and ordinary shops at the same time.
local M = {}
local profiles = {bus='bus', police='police', paramedic='paramedic', ambulance='paramedic', emt='paramedic'}
local function normalize(value)
  return type(value)=='string' and profiles[value:lower()] or nil
end

function M.organization(org)
  if not org then return nil end
  local explicit = normalize(org.roleplayType or org.employerType)
  if explicit then return explicit end
  if org.loanerUnlockMode~='skillLevel' then return nil end
  for _,path in ipairs(org.loanerUnlockSkillPathIds or {}) do
    path=tostring(path):lower()
    if path:find('passenger',1,true) or path:find('bus',1,true) then return 'bus' end
    if path:find('paramedic',1,true) or path:find('ambulance',1,true) then return 'paramedic' end
  end
  return 'police'
end

function M.isPoliceOrganizationId(orgId)
  if type(orgId) ~= 'string' then return false end
  if orgId == 'policeLoaner' or orgId == 'policeWork'
      or orgId:match('^police[%w_]*Loaner$') or orgId:match('^police[%w_]*Work$') then
    return true
  end
  local org = freeroam_organizations and freeroam_organizations.getOrganization
    and freeroam_organizations.getOrganization(orgId)
  return M.organization(org) == 'police'
end

local function hasCargo(fac)
  if next(fac.logisticGenerators or {}) then return true end
  for _,key in ipairs({'logisticTypesProvided','logisticTypesReceived',
      'logisticTypesProvidedLookup','logisticTypesReceivedLookup'}) do
    if next(fac[key] or {}) then return true end
  end
  return fac.vehicleDistributor==true or fac.carHaulFacility==true
end

function M.resolve(fac, org)
  if not fac then return nil end
  -- Explicit facility metadata wins, including false to opt out of a shared org.
  if fac.roleplayType~=nil then return normalize(fac.roleplayType) end
  if fac.employerType~=nil then return normalize(fac.employerType) end
  -- Compatibility with existing service IDs used by the map POI provider.
  -- New map facilities should declare roleplayType explicitly.
  local id=tostring(fac.id or ''):lower()
  if id=='remotepitmainbus' or id:match('buswork$') then return 'bus' end
  if id:match('policeloaner$') or id:match('policework$') then return 'police' end
  local mapId = getCurrentLevelIdentifier and getCurrentLevelIdentifier()
  if (mapId=='pepper_valley' and id=='policepepperloaner')
      or (mapId=='italy' and id=='policeitalyloaner')
      or (mapId=='utah' and id=='policeutahloaner') then return 'police' end
  if id=='frmc' or id:match('paramedicwork$') then return 'paramedic' end
  -- Never inherit a service role into a cargo/retail facility. Dedicated legacy
  -- service yards have no cargo generators; their organization remains a fallback.
  if hasCargo(fac) then return nil end
  return M.organization(org)
end

return M
