-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {'career_career'}

local function isTaxiFareReason(reason)
  if not reason then return false end
  local label = reason.label
  if type(label) ~= "string" or label == "" then return false end
  local fareLabel = (_tr and _tr("ui.taxi.fareLabel")) or "Taxi fare"
  return label == fareLabel or label == "ui.taxi.fareLabel" or label == "Taxi fare"
end

local function taxiFareSponsorName()
  if gameplay_vehicleTransfer and gameplay_vehicleTransfer.isOnShift and gameplay_vehicleTransfer.isOnShift() then
    return "CarGo"
  end
  local emp = career_modules_delivery_employment
  if emp and emp.isOnShift and emp.isOnShift() then
    local name
    if emp.getUiState then
      local ui = emp.getUiState()
      name = ui and ui.employerName
    end
    if (not name or name == "") and emp.getTasklistHeaderLabel then
      name = emp.getTasklistHeaderLabel()
    end
    if type(name) == "string" and name ~= "" then
      return name
    end
    return "Company"
  end
  return nil
end

local function canPay(price, accountId)
  if career_modules_cheats and career_modules_cheats.isCheatsMode() then
    return true
  end

  if accountId and career_modules_bank then
    local accountBalance = career_modules_bank.getAccountBalance(accountId)
    for currency, info in pairs(price) do
      if currency == "money" then
        if not info.canBeNegative and accountBalance < info.amount then
          return false
        end
      end
    end
    return true
  end

  for currency, info in pairs(price) do
    if not info.canBeNegative and career_modules_playerAttributes.getAttributeValue(currency) < info.amount then
      return false
    end
  end
  return true
end

local function pay(price, reason, accountId)
  if isTaxiFareReason(reason) then
    local sponsor = taxiFareSponsorName()
    if sponsor then
      if ui_message then
        ui_message(string.format("Fare paid by %s", sponsor), 5, "taxi", "info")
      end
      return true
    end
  end

  if not canPay(price, accountId) then return false end
  if career_modules_cheats and career_modules_cheats.isCheatsMode() then
    return true
  end

  if accountId and career_modules_bank then
    reason = reason or {}
    return career_modules_bank.payFromAccount(price, accountId, reason.label, reason.description)
  end

  local change = {}
  for currency, info in pairs(price) do
    change[currency] = -info.amount
  end
  career_modules_playerAttributes.addAttributes(change, reason)
  return true
end

local function reward(price, reason, fullReward, accountId)
  if accountId and career_modules_bank then
    reason = reason or {}
    return career_modules_bank.rewardToAccount(price, accountId, reason.label, reason.description)
  end
  
  local change = {}
  for currency, info in pairs(price) do
    change[currency] = info.amount
  end
  career_modules_playerAttributes.addAttributes(change, reason, fullReward)
  return true
end

M.canPay = canPay
M.pay = pay
M.reward = reward

return M