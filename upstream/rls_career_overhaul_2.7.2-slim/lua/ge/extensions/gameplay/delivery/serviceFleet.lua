-- Service fleets are resolved independently of the commercial rental UI.
-- No organization, facility or save data is mutated by this compatibility layer.
local M = {}
local roles = require('gameplay/delivery/facilityRole')
local defaults = {
  bus = {file='/gameplay/organizations/roleplay.organizations.json', id='busWork'},
  police = {file='/gameplay/organizations/rlslogistics.organizations.json', id='policeLoaner'},
  paramedic = {file='/gameplay/organizations/roleplay.organizations.json', id='wcuParamedicWork'},
}
local policyKeys = {'loanerUnlockMode', 'loanerUnlockSkillPathIds', 'loanerUnlockSkillPathId',
  'loanerUnlockSkillLabel', 'loanerUnlockSkillIcon'}
local documents = {}

local function readOrganization(source)
  if documents[source.file] == nil then
    documents[source.file] = jsonReadFile(source.file) or false
  end
  local doc = documents[source.file]
  return doc and doc[source.id] or nil
end

local function copyPolicy(from, to)
  if from and from.loanerUnlockSkillPathId ~= nil and from.loanerUnlockSkillPathIds == nil then
    to.loanerUnlockSkillPathIds = nil
  end
  for _, key in ipairs(policyKeys) do
    if from and from[key] ~= nil then to[key] = from[key] end
  end
end

function M.resolve(facility, org)
  local role = roles.resolve(facility, org)
  if not role then return nil end
  local defaultOrg = readOrganization(defaults[role]) or {}
  local source, sourceName
  -- Presence, not length: an explicit empty list disables loaners at this yard.
  if facility.loanableVehicles ~= nil then
    source, sourceName = facility, 'facility'
  else
    -- Only this old map/facility/organization combination needs the overwritten
    -- definition recovered. Explicit role metadata opts out on updated maps.
    local mapId = getCurrentLevelIdentifier and getCurrentLevelIdentifier()
    if facility.roleplayType == nil and facility.employerType == nil
        and mapId == 'pepper_valley' and facility.id == 'remotePitMainBus'
        and facility.associatedOrganization == 'localDeliveryAssociation' then
      local legacy = readOrganization({file='/gameplay/organizations/pepper.organizations.json',
        id='localDeliveryAssociation'})
      if legacy and roles.organization(legacy) == role and legacy.loanableVehicles ~= nil then
        source, sourceName = legacy, 'legacyPepperBus'
      end
    end
    if not source and org and roles.organization(org) == role and org.loanableVehicles ~= nil then
      source, sourceName = org, 'organization'
    end
    -- Dedicated pre-metadata police organizations used by supported map packs.
    if not source and org and roles.organization(org) == nil
        and ((role == 'police' and facility.associatedOrganization == 'policePepperLoaner'
              and mapId == 'pepper_valley' and facility.id == 'policePepperLoaner')
          or (role == 'police' and facility.associatedOrganization == 'poliziaAuto'
              and mapId == 'italy' and facility.id == 'policeItalyLoaner'))
        and org.loanableVehicles ~= nil then
      source, sourceName = org, 'legacyPolice'
    end
    if not source then source, sourceName = defaultOrg, 'default' end
  end
  local policy = {}
  copyPolicy(defaultOrg, policy)
  if sourceName == 'facility' and org and roles.organization(org) == role then
    policy.loanerUnlockMode = org.loanerUnlockMode or 'orgReputation'
    copyPolicy(org, policy)
  end
  if sourceName == 'organization' or sourceName == 'legacyPolice' then
    policy.loanerUnlockMode = source.loanerUnlockMode or 'orgReputation'
  end
  copyPolicy(source, policy)
  copyPolicy(facility, policy)
  return {role=role, entries=type(source.loanableVehicles)=='table' and source.loanableVehicles or {},
    policy=policy, source=sourceName, organizationId=facility.associatedOrganization}
end

local function skillLevel(policy)
  local paths = policy.loanerUnlockSkillPathIds
  if type(paths) ~= 'table' or not paths[1] then
    paths = policy.loanerUnlockSkillPathId and {policy.loanerUnlockSkillPathId}
      or {'careerSkills-emergency', 'emergency'}
  end
  local best = 0
  for _, id in ipairs(paths) do
    local level = career_branches and career_branches.getBranchLevel and career_branches.getBranchLevel(id)
    best = math.max(best, tonumber(level) or 0)
  end
  return best
end

function M.offers(facility, org, repLevel)
  local fleet = M.resolve(facility, org)
  if not fleet then return nil end
  local offers = {}
  local level = skillLevel(fleet.policy)
  local usesSkill = fleet.policy.loanerUnlockMode == 'skillLevel'
  local rep = tonumber(repLevel) or tonumber(org and org.reputation and org.reputation.level) or 0
  local anyConfig, anyUnlocked = false, false
  for index, entry in ipairs(fleet.entries) do
    local valid = type(entry.model)=='string' and type(entry.config)=='string'
    local info = valid and core_vehicles and core_vehicles.getConfig and core_vehicles.getConfig(entry.model, entry.config)
    local exists = valid and type(info)=='table'
    if exists and FS and FS.fileExists then
      exists = FS:fileExists(string.format('/vehicles/%s/%s.pc', entry.model, entry.config))
    end
    local requiredSkill = tonumber(entry.requiredSkillLevel) or tonumber(entry.requiredPoliceLevel) or 0
    local requiredRep = tonumber(entry.reputationLvl)
    local skillLabel = string.format('%s level %d', fleet.policy.loanerUnlockSkillLabel
      or (fleet.role == 'bus' and 'Bus Skill' or fleet.role == 'police' and 'Police Skill' or 'Paramedic Skill'), requiredSkill)
    local reason
    if not exists then reason = 'Vehicle configuration is not installed'
    elseif usesSkill and level < requiredSkill then reason = 'Requires ' .. skillLabel
    elseif requiredRep and rep < requiredRep then reason = 'Requires company reputation ' .. requiredRep end
    local offer = {}
    for key, value in pairs(entry) do offer[key] = value end
    offer.id = string.format('service-%s-%s-%s-%d', tostring(facility.id), tostring(entry.model), tostring(entry.config), index)
    offer.sourceFacility = {type='deliveryProvider', id=facility.id}
    offer.loanType = 'company'
    offer.enabled = reason == nil
    offer._unlocked = reason == nil
    offer.disableReason = reason
    offer.serviceUnlockLabel = usesSkill and requiredSkill > 0 and skillLabel or nil
    offer._serviceRole = fleet.role
    offers[#offers+1] = offer
    anyConfig = anyConfig or exists
    anyUnlocked = anyUnlocked or reason == nil
  end
  if #offers == 0 then fleet.unavailableReason = 'No company vehicles are configured for this service'
  elseif not anyConfig then fleet.unavailableReason = 'No service vehicle configurations are installed'
  elseif not anyUnlocked then fleet.unavailableReason = 'No company vehicle is unlocked yet' end
  return offers, fleet
end

function M.playerUnlockProgress(facility, org)
  local fleet = M.resolve(facility, org)
  if not fleet then return nil end
  local label = fleet.policy.loanerUnlockSkillLabel
  if not label then
    if fleet.role == 'bus' then label = 'Passenger Skill'
    elseif fleet.role == 'police' then label = 'Police Skill'
    else label = 'Paramedic Skill' end
  end
  return {
    role = fleet.role,
    unlockMode = fleet.policy.loanerUnlockMode or 'orgReputation',
    skillLevel = skillLevel(fleet.policy),
    skillLabel = label,
  }
end

return M
