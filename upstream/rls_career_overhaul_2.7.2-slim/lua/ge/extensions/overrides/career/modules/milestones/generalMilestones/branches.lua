-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
M.dependencies = {"career_branches"}
local attKeyToMilestone = {}
local milestones

local branchIcon = {
  motorsport = "raceFlag",
  labourer = "deliveryTruckArrows",
  specialized = "carChase01",
  adventurer = "jump",
}

local function skillLinear(step)
  return {{attributeKey = "money", rewardAmount = 10 * (step + 1)}}
end

local function setNotificationTarget(attKey)
  local milestoneConfig = attKeyToMilestone[attKey]
  local step = milestones.saveData.general[milestoneConfig.id].notificationStep + 1
  -- check if milestone is completed
  if milestoneConfig.maxStep and step > milestoneConfig.maxStep then return end
  local target = milestoneConfig.getTarget(step)
  if target then
    milestoneConfig._target = target
  end
end

local function onPlayerAttributesChanged(change)
  for attKey, val in pairs(change) do
    if val > 0 then
      local milestoneConfig = attKeyToMilestone[attKey]
      if not milestoneConfig then return end
      local step = milestones.saveData.general[milestoneConfig.id].notificationStep + 1
      if milestoneConfig._target and milestoneConfig.getValue() >= milestoneConfig._target then
        extensions.hook("onBranchTierReached", milestoneConfig.branchKey, step + 1)
        milestones.milestoneReached(milestoneConfig.getLabel(step))
        milestoneConfig._target = nil
        milestones.saveData.general[milestoneConfig.id].notificationStep = step
        M.setNotificationTarget(attKey)
      end
    end
  end
end

-- Several skills write their XP to a parent attribute (careerSkills-police -> careerSkills-emergency,
-- fre-trail -> careerSkills-offroad, ...). Their milestones would only mirror the parent's progress and pay
-- the same rewards twice, so only the branch that owns the canonical attribute gets a milestone.
local function canonicalKey(attKey)
  local pa = career_modules_playerAttributes
  if pa and pa.canonicalAttributeKey then
    return pa.canonicalAttributeKey(attKey) or attKey
  end
  return attKey
end

local function buildMilestoneOwners(sortedBranches)
  local owners = {}
  for _, branchInfo in ipairs(sortedBranches) do
    local attKey = branchInfo.attributeKey
    if not branchInfo.isInDevelopment and attKey then
      local canonical = canonicalKey(attKey)
      if canonical == attKey or not owners[canonical] then
        owners[canonical] = branchInfo
      end
    end
  end
  return owners
end

-- After general.lua claims one tier, claim every further tier the player has already reached so a maxed
-- skill does not need 49 separate clicks before its card reflects the real level.
local function onGeneralMilestoneClaimed(milestoneConfig)
  if not milestones or type(milestoneConfig) ~= "table" or milestoneConfig.type ~= "branch" then return end
  if not milestoneConfig.branchKey or attKeyToMilestone[milestoneConfig._attKey or ""] ~= milestoneConfig then return end
  local save = milestones.saveData.general[milestoneConfig.id]
  if not save then return end
  local current = milestoneConfig.getValue() or 0
  local sumChange, claimed = {}, 0
  while true do
    local step = (save.claimedStep or 0) + 1
    if milestoneConfig.maxStep and step > milestoneConfig.maxStep then break end
    local target = milestoneConfig.getTarget(step)
    if type(target) ~= "number" or current < target then break end
    for _, reward in pairs(milestoneConfig.getRewards(step - 1) or {}) do
      sumChange[reward.attributeKey] = (sumChange[reward.attributeKey] or 0) + (reward.rewardAmount or 0)
    end
    save.claimedStep = step
    claimed = claimed + 1
  end
  if claimed == 0 then return end
  -- keep the "milestone reached" notifications from re-announcing tiers that were just claimed
  if (save.notificationStep or 0) < save.claimedStep then
    save.notificationStep = save.claimedStep
    milestoneConfig._target = nil
    M.setNotificationTarget(milestoneConfig._attKey)
  end
  local label = milestoneConfig.getLabel(save.claimedStep)
  career_modules_playerAttributes.addAttributes(sumChange, {tags = {"milestone", "reward", "gameplay"}, label = {txt = "ui.career.milestones.claimedRewardsFor", context = {milestoneName = label}}})
  local rewardsLabel = {}
  for attributeKey, amount in pairs(sumChange) do
    table.insert(rewardsLabel, string.format("%s: +%d", attributeKey, amount))
  end
  table.sort(rewardsLabel)
  guihooks.trigger("toastrMsg", {type = "success", label = "Milestone-" .. milestoneConfig.id .. "-batch", msg = "ui.career.milestones.claimedRewardsForWithRewards", context = {milestoneName = label, rewards = table.concat(rewardsLabel, ", ")}})
end

local function onGeneralMilestonesCollect(milestonesList)
  milestones = career_modules_milestones_milestones
  table.clear(attKeyToMilestone)

  local sortedBranches = career_branches.getSortedBranches()
  local owners = buildMilestoneOwners(sortedBranches)
  for i, branchInfo in ipairs(sortedBranches) do
    if not branchInfo.isInDevelopment and owners[canonicalKey(branchInfo.attributeKey)] == branchInfo then
      local levelCount = branchInfo.maxReachableLevel - 1 -- account for entry 0
      local attKey = branchInfo.attributeKey
      local isBranch = not branchInfo.isSkill
      local color = branchInfo.color
      if not color then
        local parentBranch = career_branches.getBranchById(branchInfo.parentBranch)
        color = parentBranch.color
      end

      local milestoneConfig = {
        id = "branch_" .. branchInfo.id,
        sortIndex = 100 + i,
        branchKey = branchInfo.id,
        _attKey = attKey,
        filter = {branch = true, ["branch_" .. branchInfo.id] = true},
        type = "branch",
        minValueIsPreviousStepTarget = true,
        icon = branchIcon[branchInfo.parentBranch or branchInfo.id],
        color = color,
        getValue = function() return career_modules_playerAttributes.getAttributeValue(attKey) end,
        getLabel = function(step, displayValue, target) return {txt = isBranch and "ui.career.branchSemicolon" or "ui.career.skillSemicolon", context = {branch = branchInfo.name}} end,
        getDescription = function(step, displayValue, target) return {txt = isBranch and "ui.career.milestones.branches.reachBranchLevel.description" or "ui.career.milestones.branches.reachSkillLevel.description", context = {lvl = step + 1, name = branchInfo.name}} end,
        getProgressLabel = function(step, current, target) return {txt = "ui.career.milestones.branches.progressLabel", context = {current = current, target = target}} end,
        getTarget = function(step) return branchInfo.levels[step + 1].requiredValue end,
        getRewards = isBranch and milestones.majorLinear or skillLinear,
        maxStep = levelCount
      }
      if isBranch then
        milestoneConfig.filter.general = true
      end
      attKeyToMilestone[branchInfo.attributeKey] = milestoneConfig
      milestones.saveData.general[milestoneConfig.id] = milestones.saveData.general[milestoneConfig.id] or {claimedStep = 0, notificationStep = 0}
      table.insert(milestonesList, milestoneConfig)
    end
  end
end

local function onGeneralMilestonesSetupCallbacks()
  for attKey, milestone in pairs(attKeyToMilestone) do
    M.setNotificationTarget(attKey)
  end
end

M.setNotificationTarget = setNotificationTarget
M.onPlayerAttributesChanged = onPlayerAttributesChanged
M.onGeneralMilestoneClaimed = onGeneralMilestoneClaimed
M.onGeneralMilestonesCollect = onGeneralMilestonesCollect
M.onGeneralMilestonesSetupCallbacks = onGeneralMilestonesSetupCallbacks

return M
