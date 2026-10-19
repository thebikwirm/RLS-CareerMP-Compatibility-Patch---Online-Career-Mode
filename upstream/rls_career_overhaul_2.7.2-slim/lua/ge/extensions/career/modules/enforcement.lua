local M = {}

local jobSkillRewards = require('gameplay/jobSkillRewards')
local facilityRole = require('gameplay/delivery/facilityRole')

local POLICE_REWARD_CONFIG_PATH = "gameplay/police/rewardConfig.json"
local policeRewardConfig

local CONSTANTS = {
  COP_PITY_MULTIPLIER = 30,
  CRIMINAL_REWARD_MULTIPLIER = 11,
  ARREST_BONUS_MULTIPLIER = 180,
  ARREST_BONUS_MAX = 430,
  ARREST_BONUS_MIN = 215,
  ARREST_REPUTATION_BONUS_SCALE = 0.05,
  POLICE_PAYOUT_MULTIPLIER = 3.0,
  REWARD_DIVISOR = 6,
  POLICE_SKILL_XP_DIVISOR = 60,
  ARREST_POLICE_SKILL_XP_DIVISOR = 1.2,
  COP_PROXIMITY_DISTANCE = 15,
  LICENSE_PLATE_EVADE_BONUS = 55,
  NO_LICENSE_PLATE_EVADE_PENALTY = 35,
  POLICE_LOANER_ORG_NAME = "policeLoaner",
  REPUTATION_BONUS_AMOUNT = 10,
  SUSPECT_FREQUENCY = 1.0,
  POLICE_SKILL_ATTRIBUTE_KEY = "careerSkills-emergency",
  POLICE_SKILL_PATH_IDS = {"careerSkills-emergency", "emergency"},
}

local function applyDifficultyProgressionRewardData(rewardData)
  if not (career_modules_difficultyMode and career_modules_difficultyMode.scalePaymentRewardData) then
    return rewardData
  end
  return career_modules_difficultyMode.scalePaymentRewardData(rewardData, {includeMoney = false})
end

local function applyPoliceInteractionFrequency()
  if gameplay_police and gameplay_police.setPursuitVars then
    gameplay_police.setPursuitVars({suspectFrequency = CONSTANTS.SUSPECT_FREQUENCY})
  end
end

local function isPoliceDisabled()
  local disabled = false
  local reason = ""

  -- Check if player is walking (highest priority)
  if gameplay_walk and gameplay_walk.isWalking() then
      disabled = true
      reason = "Police service is not available while walking"
      return disabled, reason
  end

  -- Check if police multiplier is 0
  if career_economyAdjuster then
      local policeMultiplier = career_economyAdjuster.getSectionMultiplier("police") or 1.0
      if policeMultiplier == 0 then
          disabled = true
          reason = "Police multiplier is set to 0"
      end
  end

  return disabled, reason
end

local function resetPursuit()
  local vehId = be:getPlayerVehicleID(0)
  local playerTrafficData = gameplay_traffic.getTrafficData()[vehId]

  if playerTrafficData and playerTrafficData.pursuit then
    playerTrafficData.pursuit.mode = 0
    playerTrafficData.pursuit.score = 0
  end
end

local function hasLicensePlate(inventoryId)
  for partId, part in pairs(career_modules_partInventory.getInventory()) do
    if part.location == inventoryId and string.find(part.name, "licenseplate") then
      return true
    end
  end
  return false
end

local function getSectionMultiplier(sectionName)
  if career_economyAdjuster and career_economyAdjuster.getSectionMultiplier and sectionName then
    return career_economyAdjuster.getSectionMultiplier(sectionName) or 1.0
  end
  return 1.0
end

local function formatSurgeBonusText(sectionName)
  if career_modules_activityHeat and career_modules_activityHeat.formatSurgeBonusText then
    return career_modules_activityHeat.formatSurgeBonusText(sectionName)
  end
  return ""
end

local function calculateRewardAmount(baseAmount, multiplier, sectionName)
  local jobMarketIndex = career_modules_globalEconomy and career_modules_globalEconomy.getJobMarketIndex() or 1.0
  local sectionMultiplier = getSectionMultiplier(sectionName)
  return math.floor(baseAmount * multiplier * jobMarketIndex * sectionMultiplier) / 100
end

local function createRewardPayment(rewardData, label, tags)
  career_modules_payment.reward(rewardData, {
    label = label,
    tags = tags
  }, true)
end

local function calculatePoliceSkillXp(amount)
  return math.floor(amount / CONSTANTS.POLICE_SKILL_XP_DIVISOR)
end

local function calculateArrestPoliceSkillXp(amount)
  return math.floor(amount / CONSTANTS.ARREST_POLICE_SKILL_XP_DIVISOR)
end

local function getPoliceRewardConfig()
  if policeRewardConfig == nil then
    policeRewardConfig = jobSkillRewards.loadRewardConfig(POLICE_REWARD_CONFIG_PATH)
  end
  return policeRewardConfig
end

local function calculateArrestReputationBonus(rawBonus)
  rawBonus = tonumber(rawBonus) or 1
  if rawBonus <= 1 then
    return 1
  end
  return 1 + ((rawBonus - 1) * CONSTANTS.ARREST_REPUTATION_BONUS_SCALE)
end

local function calculatePoliceSkillPayoutMultiplier()
  local skillConfig = jobSkillRewards.getSkillConfig(getPoliceRewardConfig())
  local attributeKey = jobSkillRewards.getAttributeKey(skillConfig, CONSTANTS.POLICE_SKILL_ATTRIBUTE_KEY)
  local policeSkillLevel = jobSkillRewards.getSkillLevel(attributeKey, CONSTANTS.POLICE_SKILL_PATH_IDS)
  return jobSkillRewards.getJobMoneyBonusMultiplier(skillConfig, policeSkillLevel)
end

local function getArrestPoliceOrganization(vehicle)
  local owningId = vehicle and vehicle.owningOrganization
  if facilityRole.isPoliceOrganizationId(owningId) then
    local owningOrg = freeroam_organizations.getOrganization(owningId)
    if owningOrg then return owningId, owningOrg end
    log("W", "career", "Police loaner organization is unavailable: " .. owningId)
    return nil, nil
  end

  local generator = career_modules_delivery_generator
  local facilities = generator and generator.getFacilities and generator.getFacilities() or {}
  local mapPoliceFacility
  for _, facility in ipairs(facilities) do
    if facility.roleplayType == "police" then
      mapPoliceFacility = facility
      break
    end
    if not mapPoliceFacility and facilityRole.resolve(facility) == "police" then
      mapPoliceFacility = facility
    end
  end
  if mapPoliceFacility then
    local orgId = mapPoliceFacility.associatedOrganization
    if type(orgId) ~= "string" or orgId == "" then
      log("W", "career", "Map police facility has no organization: " .. tostring(mapPoliceFacility.id))
      return nil, nil
    end
    local org = freeroam_organizations.getOrganization(orgId)
    if org then return orgId, org end
    log("W", "career", "Map police organization is unavailable: " .. orgId)
    return nil, nil
  end

  local defaultId = CONSTANTS.POLICE_LOANER_ORG_NAME
  return defaultId, freeroam_organizations.getOrganization(defaultId)
end

local function handleCopEvadeReward(data)
  local pityAmount = calculateRewardAmount(data.score, CONSTANTS.COP_PITY_MULTIPLIER, "police")
  pityAmount = math.floor(pityAmount * CONSTANTS.POLICE_PAYOUT_MULTIPLIER)

  local policeSkillXp = calculatePoliceSkillXp(pityAmount)
  local rewardData = {
    money = { amount = pityAmount }
  }
  jobSkillRewards.addJobSkillXpToRewardData(rewardData, CONSTANTS.POLICE_SKILL_ATTRIBUTE_KEY, policeSkillXp)
  rewardData = applyDifficultyProgressionRewardData(rewardData)
  pityAmount = rewardData.money.amount

  local surgeText = formatSurgeBonusText("police")
  createRewardPayment(rewardData,
    "The suspect got away, Here is " .. pityAmount .. " for repairs" .. surgeText,
    {"gameplay", "reward", "police"}
  )
  career_saveSystem.saveCurrent()
  ui_message("The suspect got away, Here is $" .. pityAmount .. " for repairs" .. surgeText, 5, "Police")
end

local function handleCriminalEvadeReward(vehId, data, inventoryId)
  if vehId ~= be:getPlayerVehicleID(0) then
    return
  end

  if career_economyAdjuster.getTypeMultiplier("criminal") == 0 then
    ui_message("Criminal work is disabled", 8, "Criminal", "warning")
    return
  end

  local rewardAmount = calculateRewardAmount(data.score or 10, CONSTANTS.CRIMINAL_REWARD_MULTIPLIER, "criminal")

  local rewardData = {
    money = { amount = rewardAmount }
  }
  rewardData = applyDifficultyProgressionRewardData(rewardData)
  rewardAmount = rewardData.money.amount

  local surgeText = formatSurgeBonusText("criminal")
  createRewardPayment(rewardData,
    "You sold your dashcam footage for $" .. rewardAmount .. surgeText,
    {"gameplay", "reward", "criminal"}
  )

  ui_message("You sold your dashcam footage for $" .. rewardAmount .. surgeText, 5, "Criminal")
  career_modules_inventory.addEvade(inventoryId)
end

local function handleArrestReward(data, playerData)
  local baseBonus = calculateRewardAmount(data.score, CONSTANTS.ARREST_BONUS_MULTIPLIER)
  local bonus = math.max(CONSTANTS.ARREST_BONUS_MAX - baseBonus, CONSTANTS.ARREST_BONUS_MIN)
  local policeSkillMultiplier = calculatePoliceSkillPayoutMultiplier()

  local vehicle = career_modules_inventory.getVehicle(playerData.inventoryId)
  local policeOrgName, org = getArrestPoliceOrganization(vehicle)
  local level = org and org.reputationLevels and org.reputationLevels[(org.reputation and org.reputation.level or 0) + 2]
  local reputationBonus = calculateArrestReputationBonus(level and level.deliveryBonus and level.deliveryBonus.value)
  bonus = bonus * reputationBonus * policeSkillMultiplier

  bonus = math.floor(bonus * CONSTANTS.POLICE_PAYOUT_MULTIPLIER)
  bonus = calculateRewardAmount(bonus, 100, "police")

  local policeSkillXp = calculateArrestPoliceSkillXp(bonus / math.max(1, policeSkillMultiplier))
  local emp = career_modules_delivery_employment
  local escrowRoleplay = emp and emp.shouldEscrowRoleplayPay and emp.shouldEscrowRoleplayPay()
  local rewardData = {money = { amount = 0 }}
  if policeOrgName and org then
    rewardData[policeOrgName .. "Reputation"] = { amount = CONSTANTS.REPUTATION_BONUS_AMOUNT }
  end
  jobSkillRewards.addJobSkillXpToRewardData(rewardData, CONSTANTS.POLICE_SKILL_ATTRIBUTE_KEY, policeSkillXp)
  rewardData = applyDifficultyProgressionRewardData(rewardData)

  createRewardPayment(rewardData, "Arrest Bonus" .. formatSurgeBonusText("police"), {"gameplay", "reward", "police"})

  local surgeText = formatSurgeBonusText("police")
  local message
  if escrowRoleplay and emp.depositRoleplayEscrow then
    local keep = emp.depositRoleplayEscrow("Arrest bonus", bonus) or 0
    message = "Arrest Bonus: $" .. keep .. " (held until End day)"
    if surgeText ~= "" then
      message = message .. surgeText
    end
  else
    message = "Clock in at the station to earn arrest pay."
    if surgeText ~= "" then
      message = message .. surgeText
    end
  end
  if reputationBonus ~= 1 then
    message = message .. " (Reputation Bonus: " .. math.floor((reputationBonus - 1) * 100) .. "%)"
  end
  if policeSkillMultiplier > 1 then
    message = message .. " (Police Skill Bonus: " .. math.floor((policeSkillMultiplier - 1) * 100) .. "%)"
  end

  ui_message(message, 5, "Police")
  career_modules_inventory.addSuspectCaught(playerData.inventoryId)
  career_saveSystem.saveCurrent()
end

local function onPursuitAction(vehId, action, data)
  if gameplay_taxi and gameplay_taxi.isTaxiRideActive and gameplay_taxi.isTaxiRideActive() then
    return
  end

  local playerData = {
    isCop = career_modules_playerDriving.getPlayerIsCop(),
    inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
  }

  local policeDisabled, disabledReason = isPoliceDisabled()
  if policeDisabled and playerData.isCop then
    ui_message("Police service disabled: " .. disabledReason, 8, "Police", "warning")
    return
  end

  if not playerData.inventoryId then
    playerData.inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(be:getPlayerVehicleID(0))
  end

  if vehId ~= be:getPlayerVehicleID(0) and playerData.isCop then
    local vehicle = scenetree.findObjectById(vehId)
    local playerVeh = getPlayerVehicle(0)
    if not vehicle or not playerVeh then return end

    local distance = vehicle:getPosition():distance(playerVeh:getPosition())
    if distance > CONSTANTS.COP_PROXIMITY_DISTANCE then
      return
    end
  elseif vehId ~= be:getPlayerVehicleID(0) and not playerData.isCop then
    return
  end

  if action == "start" then
    gameplay_parking.disableTracking(vehId)

    local evadeLimit = hasLicensePlate(playerData.inventoryId)
      and CONSTANTS.LICENSE_PLATE_EVADE_BONUS
      or CONSTANTS.NO_LICENSE_PLATE_EVADE_PENALTY

    gameplay_police.setPursuitVars({ evadeLimit = evadeLimit })

    log("I", "career", "Police pursuing player, now deactivating recovery prompt buttons")

  elseif action == "reset" then
    if not gameplay_walk.isWalking() then
      gameplay_parking.enableTracking(vehId)
    end

    log("I", "career", "Pursuit ended, now activating recovery prompt buttons")
    resetPursuit()

  elseif action == "evade" then
    if not gameplay_walk.isWalking() then
      gameplay_parking.enableTracking(vehId)
    end

    if playerData.isCop then
      handleCopEvadeReward(data)
    else
      handleCriminalEvadeReward(vehId, data, playerData.inventoryId)
    end

    resetPursuit()

  elseif action == "arrest" then
    if playerData.isCop then
      handleArrestReward(data, playerData)
    end
  end
end

M.onPursuitAction = onPursuitAction
M.onExtensionLoaded = applyPoliceInteractionFrequency
M.onCareerActivated = applyPoliceInteractionFrequency
M.Constants = CONSTANTS
M.isPoliceDisabled = isPoliceDisabled

return M
