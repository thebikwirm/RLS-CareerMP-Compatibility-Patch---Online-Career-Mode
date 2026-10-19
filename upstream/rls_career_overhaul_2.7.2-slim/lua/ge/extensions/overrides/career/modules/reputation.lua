-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local minimumValue = -1000
local maximumValue = 350000

local isHardcore = false

local reputationValues = {
  returnLoanerDamaged = -300,
  discardDeliveryVehicle = -200
}

local levelDefaults = {
  [-1] = {
    label = "ui.career.organizations.reputation.questionable",
    levelLabel = {txt = "ui.career.organizations.reputation.levelLabel", context = {level = -1}},
    requiredValue = minimumValue,
    loanerCut = {
      value = isHardcore and 0.95 or 0.5,
      icon = "boxPickUp03"
    },
    deliveryBonus = {
      value = 0.9,
    }
  },
  [0] = {
    label = "ui.career.organizations.reputation.neutral",
    levelLabel = {txt = "ui.career.organizations.reputation.levelLabel", context = {level = 0}},
    requiredValue = 0,
    loanerCut = {
      value = isHardcore and 0.8 or 0.35,
      icon = "boxPickUp03"
    },
    deliveryBonus = {
      value = 1,
    }
  },
  [1] = {
    label = "ui.career.organizations.reputation.reliable",
    levelLabel = {txt = "ui.career.organizations.reputation.levelLabel", context = {level = 1}},
    requiredValue = 3900,
    loanerCut = {
      value = isHardcore and 0.7 or 0.25,
      icon = "boxPickUp03"
    },
    deliveryBonus = {
      value = 1.1,
    }
  },
  [2] = {
    label = "ui.career.organizations.reputation.preferred",
    levelLabel = {txt = "ui.career.organizations.reputation.levelLabel", context = {level = 2}},
    requiredValue = 11600,
    loanerCut = {
      value = isHardcore and 0.6 or 0.15,
      icon = "boxPickUp03"
    },
    deliveryBonus = {
      value = 1.2,
    }
  },
  [3] = {
    label = "ui.career.organizations.reputation.partner",
    levelLabel = {txt = "ui.career.organizations.reputation.levelLabel", context = {level = 3}},
    requiredValue = 44600,
    loanerCut = {
      value = isHardcore and 0.5 or 0,
      icon = "boxPickUp03"
    },
    deliveryBonus = {
      value = 1.4,
    }
  },
}

local function getloanerCutValue(level)
  local loanerCutValues = {
    [-1] = isHardcore and 0.95 or 0.5,
    [0] = isHardcore and 0.8 or 0.35,
    [1] = isHardcore and 0.7 or 0.25,
    [2] = isHardcore and 0.6 or 0.15,
    [3] = isHardcore and 0.5 or 0,
  }
  local value = loanerCutValues[level]
  if value == nil then
    value = loanerCutValues[3] or 0
  end
  return value
end

-- Employment company share (player keep is 1 - share). Independent loanerCut
-- tables stay unchanged so police/bus/paramedic payouts keep working.
local function getCompanyShareValue(level)
  local shareValues = {
    [-1] = isHardcore and 0.8 or 0.5,
    [0] = isHardcore and 0.7 or 0.4,
    [1] = isHardcore and 0.6 or 0.3,
    [2] = isHardcore and 0.5 or 0.2,
    [3] = isHardcore and 0.4 or 0.1,
  }
  return shareValues[level] or shareValues[3] or 0.5
end

local function updateLevelDefaults()
  for i, lvl in pairs(levelDefaults) do
    lvl.loanerCut.value = getloanerCutValue(i)
  end
end

local function getValueForEvent(eventId)
  return reputationValues[eventId]
end

local function calcLevelFromReputationValue(val, organization)
  local level = -1

  local levels = organization.reputationLevels or {}
  for i, lvl in ipairs(levels) do
    if not lvl.requiredValue or val >= lvl.requiredValue then
      level = i
    end
  end
  if level == -1 then
    level = 1
  end
  local currentLevelRequiredValue = (levels[level] and levels[level].requiredValue) or minimumValue
  local nextLevelRequiredValue = levels[level+1] and levels[level+1].requiredValue or maximumValue

  local prevThreshold = currentLevelRequiredValue
  local neededForNext = nextLevelRequiredValue - currentLevelRequiredValue
  local curLvlProgress = val - currentLevelRequiredValue
  local nextThreshold = nextLevelRequiredValue
  return level - 2, curLvlProgress, neededForNext, prevThreshold, nextThreshold
end

local function addReputationToOrg(organization)
  if not organization then
    return
  end

  local value = career_modules_playerAttributes.getAttributeValue(organization.id .. "Reputation")
  local level, curLvlProgress, neededForNext, prevThreshold, nextThreshold = calcLevelFromReputationValue(value, organization)

  -- Check if reputation level changed and invalidate vehicle cache if needed
  local previousLevel = organization.reputation and organization.reputation.level
  if previousLevel ~= nil and previousLevel ~= level then
    log("I", "Reputation", string.format("Organization %s reputation level changed from %d to %d, invalidating vehicle cache", organization.id, previousLevel, level))
    if career_modules_vehicleShopping then
      career_modules_vehicleShopping.invalidateVehicleCache()
    end
  end

  local data = {
    value = value,
    level = level,
    curLvlProgress = curLvlProgress,
    neededForNext = neededForNext,
    prevThreshold = prevThreshold,
    nextThreshold = nextThreshold
  }

  if organization.reputationValues then
    for i, value in pairs(organization.reputationValues) do
        reputationValues[i] = value
    end
  end

  updateLevelDefaults()

  for i, levelInfo in ipairs(organization.reputationLevels) do
    local defaultAttributes = levelDefaults[i-2] or levelDefaults[3]
    if defaultAttributes then
      for attributeKey, attributeValue in pairs(defaultAttributes) do
      if levelInfo[attributeKey] then
        if type(levelInfo[attributeKey]) == "table" then
          for key, value in pairs(attributeValue) do
            if attributeKey == "loanerCut" then
              if key == "value" then
                if isHardcore then
                  if levelInfo[attributeKey]["hardcoreValue"] then
                    levelInfo[attributeKey][key] = levelInfo[attributeKey]["hardcoreValue"]
                  else
                    levelInfo[attributeKey][key] = value
                  end
                else
                  levelInfo[attributeKey][key] = levelInfo[attributeKey][key] or value
                end
              end
            else
              if levelInfo[attributeKey][key] == nil then
                levelInfo[attributeKey][key] = value
              end
            end
          end
        end
      else
        levelInfo[attributeKey] = attributeValue
      end
      end
    end
    if levelInfo.label then
      levelInfo.label = core_locales.translateWithOrWithoutContext(levelInfo.label)
    end
    if levelInfo.levelLabel then
      levelInfo.levelLabel = core_locales.translateWithOrWithoutContext(levelInfo.levelLabel)
    end
  end
  organization.reputation = data
end

local function getLabel(lvl)
  updateLevelDefaults()
  local defaults = levelDefaults[lvl] or levelDefaults[3] or levelDefaults[0] or levelDefaults[-1]
  if not defaults or not defaults.label then return "" end
  return core_locales.translateWithOrWithoutContext(defaults.label)
end

local function getMinimumValue(organization)
  -- Stock organizations.lua calls this with no args. Per-org min is optional.
  local levels = organization and organization.reputationLevels
  local first = type(levels) == "table" and levels[1] or nil
  if type(first) == "table" and first.min ~= nil then
    return first.min
  end
  return minimumValue
end

local function getMaximumValue(organization)
  -- Stock organizations.lua calls this with no args. Per-org max is optional.
  local levels = organization and organization.reputationLevels
  local last = type(levels) == "table" and levels[#levels] or nil
  if type(last) == "table" and last.max ~= nil then
    return last.max
  end
  return maximumValue
end

local function onHardcoreModeChanged(hardcoreMode)
  isHardcore = hardcoreMode
  updateLevelDefaults()
end

M.onHardcoreModeChanged = onHardcoreModeChanged
M.addReputationToOrg = addReputationToOrg
M.getLabel = getLabel
M.getMinimumValue = getMinimumValue
M.getMaximumValue = getMaximumValue
M.getValueForEvent = getValueForEvent
M.getCompanyShareValue = getCompanyShareValue

return M
