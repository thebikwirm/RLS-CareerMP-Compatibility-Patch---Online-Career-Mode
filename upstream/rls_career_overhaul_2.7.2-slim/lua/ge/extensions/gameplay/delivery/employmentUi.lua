local M = {}

local TASK = {
  id = "employment-shift",
  main = "employment-shift-main",
  vehicle = "employment-shift-vehicle",
  repo = "employment-shift-repo",
  ending = "employment-shift-ending",
}
local TASK_IDS = { TASK.id, TASK.main, TASK.vehicle, TASK.repo, TASK.ending }
local PHONE_NOTIF_SOUND = { soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open" }
local lastTaskSignature = nil
local lastSpawnActionSignature = nil
local taskVisible = false
local endingTaskVisible = false

M.TASK = TASK
M.TASK_IDS = TASK_IDS

function M.resetTasklistCache()
  endingTaskVisible = false
  lastTaskSignature = nil
  lastSpawnActionSignature = nil
  taskVisible = false
end

function M.translateText(value, fallback)
  if type(value) ~= "string" or value == "" then
    return fallback or value
  end
  if type(_tr) == "function" then
    local ok, translated = pcall(_tr, value)
    if ok and type(translated) == "string" and translated ~= "" then
      return translated
    end
  end
  if type(translate) == "function" then
    local ok, translated = pcall(translate, value)
    if ok and type(translated) == "string" and translated ~= "" then
      return translated
    end
  end
  if core_locales and core_locales.translateWithOrWithoutContext then
    local translated = core_locales.translateWithOrWithoutContext(value)
    if type(translated) == "string" and translated ~= "" then
      return translated
    end
  end
  return fallback or value
end

function M.orgDisplayName(org, orgId)
  return M.translateText(org and org.name, orgId or "Company")
end

function M.reputationLabel(org, level)
  level = tonumber(level)
  local info = org and org.reputationLevels and org.reputationLevels[level + 2]
  if type(info) == "table" and type(info.label) == "string" and info.label ~= "" then
    return info.label
  end
  return nil
end

function M.commissionPercent(companyShare)
  return math.floor(math.min(1, math.max(0, 1 - companyShare)) * 100 + 0.5)
end

function M.formatDamageStatus(strikes, warnMax, dockMax, dockPercent)
  strikes = tonumber(strikes) or 0
  if strikes <= 0 then return nil end
  warnMax = tonumber(warnMax) or 0
  dockMax = tonumber(dockMax) or 0
  if strikes <= warnMax then
    return {
      strikes = strikes,
      phase = "warning",
      detail = string.format("Warning %d of %d", strikes, warnMax),
      warnMax = warnMax,
      dockMax = dockMax,
    }
  end
  if strikes <= warnMax + dockMax then
    return {
      strikes = strikes,
      phase = "dock",
      detail = string.format("Pay dock %d of %d (~%d%% of held wages)", strikes - warnMax, dockMax, math.floor((tonumber(dockPercent) or 0) * 100 + 0.5)),
      warnMax = warnMax,
      dockMax = dockMax,
    }
  end
  return {
    strikes = strikes,
    phase = "terminated",
    detail = "Repeated equipment damage",
    warnMax = warnMax,
    dockMax = dockMax,
  }
end

function M.offeringsWorkSummary(offerings)
  local bits = {}
  for _, offering in ipairs(offerings or {}) do
    if offering and offering.label then
      table.insert(bits, offering.label)
    end
  end
  return #bits > 0 and table.concat(bits, ", ") or "assigned loads"
end

function M.formatListing(view)
  if not view then return nil end
  local offerings = view.offerings
  local skillLocked = view.skillLocked and true or false
  return {
    orgId = view.orgId,
    orgName = view.orgName,
    facId = view.facId,
    facName = view.facName,
    workSummary = M.offeringsWorkSummary(offerings),
    offerings = offerings,
    employerProfile = view.employerProfile,
    sideWork = false,
    rehireBlocked = view.rehireBlocked,
    rehireDaysRemaining = view.rehireDaysRemaining,
    skillLocked = skillLocked,
    preview = view.preview,
    requiredLevel = view.requiredLevel,
    skillMessage = skillLocked
      and (view.skillMessage or "You can't take work at this yard with your current unlocks yet.")
      or nil,
  }
end

function M.formatAssignedVehicles(entries, inventory)
  if not entries or not inventory then return {} end
  local result = {}
  for _, entry in ipairs(entries) do
    local info = inventory.getVehicle and inventory.getVehicle(entry.id)
    if info then
      local thumbnail = inventory.getVehicleThumbnail and inventory.getVehicleThumbnail(entry.id) or nil
      if thumbnail and info.dirtyDate then thumbnail = thumbnail .. "?" .. tostring(info.dirtyDate) end
      result[#result + 1] = {
        inventoryId = entry.id,
        name = inventory.getVehicleNiceNameTranslated and inventory.getVehicleNiceNameTranslated(entry.id)
          or info.niceName or info.model or "Vehicle",
        thumbnail = thumbnail or "/ui/images/appDefault.png",
        role = entry.role,
      }
    end
  end
  return result
end

function M.formatAccident(view)
  if not view then return nil end
  return {
    label = view.label or "Accident recovery",
    subtext = view.subtext or "Replacement equipment is being issued",
    canClaim = view.canClaim and true or false,
    spawning = view.spawning and true or false,
  }
end

function M.assignmentDescription(view)
  local label, subtext
  local busState = view.busState
  if view.held then
    label = "Held assignment"
    subtext = view.outboundLabel or "Clock in to continue this job"
  elseif view.spawnBlocked then
    label = view.spawnBlockedReady and "Ready to spawn" or "Spawn area blocked"
    subtext = "Clear the highlighted stalls, then select Spawn vehicle"
  elseif view.useParamedicGuidance then
    local guidance = view.paramedicGuidance
    label, subtext = guidance.label, guidance.subtext
  elseif busState and busState.paused then
    label, subtext = "Bus route paused", "Return to your bus to continue the route"
  elseif busState and view.endAfterAssignment then
    label = "Finishing bus shift"
    subtext = string.format("Drop off your %d passengers at the next stop to collect pay. No new passengers will board.", busState.passengers)
  elseif busState then
    local guidance = view.busGuidance
    label = guidance and guidance.label or view.outboundLabel or "Bus routes"
    subtext = guidance and guidance.subtext or "End Day pays immediately when empty, or after dropping off remaining passengers at the next stop."
  elseif view.openEnded then
    label = view.outboundLabel or "On company time"
    subtext = view.outboundSubtext or "End day anytime to collect today's wages and return the company vehicle"
  elseif view.phase == "loopComplete" or view.wrecked then
    label = view.returnLabel or "Assignment complete"
    subtext = view.returnSubtext or "Take another job or end your day"
  elseif view.phase == "return" then
    if view.returnIsBackhaul and view.assignedReturnCargoInVehicle then
      label = view.returnDeliverLabel or view.returnLabel or "Deliver return parcels"
    else
      label = view.returnLabel or "Return to the company yard"
    end
    subtext = view.returnSubtext or "Deliver the return load, then choose your next job or end the day"
  elseif view.isBundle and view.inProgress then
    label = view.outboundLabel or "Two company assignments"
    subtext = view.outboundSubtext or "Complete both assignments in any order"
  elseif view.inProgress then
    label = view.outboundLabel or "Continue the company assignment"
    subtext = view.phase == "outbound" and view.outboundSubtext
      or "Finish this assignment. End day marks it as your final assignment."
    if view.stringMode and view.hasStops and view.phase == "outbound" then
      local n = math.max(tonumber(view.stringStopTotal) or 0, tonumber(view.stopCount) or 0)
      local i = math.min(view.stopIndex or 1, math.max(n, 1))
      if n > 0 then subtext = string.format("Stop %d of %d · %s", i, n, subtext or "parcels") end
    end
    if view.isDistributorHaul and view.phase == "outbound" then
      local remaining = tonumber(view.distributorRemaining) or 0
      if remaining > 0 then
        subtext = string.format("%d vehicle%s left · company truck and trailer", remaining, remaining == 1 and "" or "s")
      end
    end
  elseif view.phase == "outbound" then
    label = view.outboundLabel
    subtext = view.outboundSubtext
  else
    label = view.returnLabel
    subtext = view.returnSubtext
  end
  return label, subtext
end

function M.formatAssignment(view)
  if not view then return nil end
  local label, subtext = M.assignmentDescription(view)
  local held = view.held and true or false
  local spawnBlocked = view.spawnBlocked and true or false
  local inProgress = view.inProgress and true or false
  return {
    phase = view.phase,
    jobKind = view.jobKind,
    cargoType = view.cargoType,
    label = label,
    subtext = subtext,
    loopComplete = view.loopComplete,
    wrecked = view.wrecked and true or false,
    held = held,
    endAfterAssignment = view.endAfterAssignment == true,
    busShift = view.busState,
    canEndBusShiftNow = view.canEndBusShiftNow,
    openEnded = view.openEnded,
    holdsOnEndDay = view.holdsOnEndDay,
    spawnBlocked = spawnBlocked,
    canSpawnBlockedEquipment = view.canSpawnBlockedEquipment,
    accident = view.accident,
    canReportAccident = view.canReportAccident,
    awaitingPark = view.awaitingPark and true or false,
    vehiclesParked = view.vehiclesParked and true or false,
    yardDropOffPending = view.yardDropOffPending == true,
    canEndDay = view.canEndDay,
    canAbandonAssignment = view.canAbandonAssignment,
    abandonFine = view.abandonFine,
    canNextRun = view.canNextRun,
    dropOffEscrowPending = view.dropOffEscrowPending and true or false,
    canContinue = view.canContinue,
    inProgress = inProgress,
    shiftAssignments = view.shiftAssignments,
    bundle = view.isBundle and true or false,
    stringMode = view.stringMode and true or false,
    stopIndex = view.stopIndex,
    stopCount = view.stopCount,
  }
end

function M.formatUiState(view)
  if not view then return nil end
  return {
    employed = view.employed,
    onShift = view.onShift,
    roleplayFacility = view.roleplayFacility,
    roleplaySetup = view.roleplaySetup,
    canClockInHere = view.canClockInHere,
    employerOrgId = view.employerOrgId,
    employerName = view.employerName,
    employerPreview = view.employerPreview,
    employerRepLevel = view.employerRepLevel,
    employerRepLabel = view.employerRepLabel,
    commissionPercent = view.commissionPercent,
    employerOfferings = view.employerOfferings,
    companyVehicles = view.companyVehicles,
    assignedVehicles = view.assignedVehicles,
    shiftStartPending = view.shiftStartPending,
    shiftStartReady = view.shiftStartReady,
    logisticsEmployerOrgId = view.logisticsEmployerOrgId,
    logisticsEmployerName = view.logisticsEmployerName,
    homeFacId = view.homeFacId,
    pending = view.pending,
    assignment = view.assignment,
    canReportAccident = view.canReportAccident,
    escrowMoney = view.escrowMoney,
    escrowLegs = view.escrowLegs,
    surgeBonusHeld = view.surgeBonusHeld,
    damageStrikeCount = view.damageStrikeCount,
    showDamageNotice = view.showDamageNotice,
    damageStatus = view.damageStatus,
    listings = view.listings,
    atEmployerYard = view.atEmployerYard,
    deliveryLevel = view.deliveryLevel,
    skillLevel = view.skillLevel,
    skillLabel = view.skillLabel,
    unlocked = view.unlocked,
    apprenticeship = view.apprenticeship,
    independentCargoLevel = view.independentCargoLevel,
    devTools = view.devTools,
    headhunterOffer = view.headhunterOffer,
  }
end

function M.employerTasklistHeader(view)
  local facName = view and view.facName
  if type(facName) == "string" and facName ~= "" then
    return M.translateText(facName, facName)
  end
  return (view and view.orgName) or (view and view.orgId) or "Company"
end

function M.firePhoneNotification(channelKey, title, message, kind, extra, opts)
  if not ui_phone_layout and extensions and extensions.load then
    pcall(extensions.load, "ui_phone_layout")
  end
  if not (ui_phone_layout and ui_phone_layout.fireNotification) then return end
  local payload = {
    title = title,
    message = message,
    kind = kind or "invite",
    ttl = 10,
    source = "Employment",
    sound = PHONE_NOTIF_SOUND,
  }
  if type(extra) == "table" then
    for key, value in pairs(extra) do
      payload[key] = value
    end
  end
  ui_phone_layout.fireNotification(channelKey, payload, opts)
end

function M.clearTaskGuidance(hooks)
  endingTaskVisible = false
  hooks = hooks or guihooks
  if hooks then
    hooks.trigger("EmploymentSpawnAction", {visible = false})
    for _, id in ipairs(TASK_IDS) do
      hooks.trigger("DiscardTasklistItem", id)
    end
    hooks.trigger("DiscardTasklistItem", "bus_passenger_count")
    hooks.trigger("SetTasklistHeader", nil)
  end
  taskVisible = false
  lastTaskSignature = nil
end

local function publishSpawnAction(hooks, shift, force)
  local spawnAction = {
    visible = shift ~= nil and shift.spawnBlocked ~= nil and not shift.paused,
    ready = shift and shift.spawnBlocked and shift.spawnBlocked.ready == true
      and not shift.spawnBlocked.retryInFlight or false,
  }
  local spawnSignature = tostring(spawnAction.visible) .. tostring(spawnAction.ready)
  if force or spawnSignature ~= lastSpawnActionSignature then
    if hooks then hooks.trigger("EmploymentSpawnAction", spawnAction) end
    lastSpawnActionSignature = spawnSignature
  end
end

local function refreshTaskGuidance(ctx, force)
  ctx = ctx or {}
  local hooks = ctx.guihooks or guihooks
  local shift = ctx.shift
  publishSpawnAction(hooks, shift, force)
  if not shift then
    M.clearTaskGuidance(hooks)
    return
  end
  if shift.awaitingPark then
    if ctx.purgeIndependent then ctx.purgeIndependent() end
    local holding = ctx.assignmentStillInProgress
    local label = "Park the company vehicle"
    local subtext = holding and "Put it in the marked stall to hold this assignment" or "Put it in the marked stall to clock out"
    local signature = table.concat({label, subtext, "park"}, "|")
    if force or signature ~= lastTaskSignature then
      if hooks then
        hooks.trigger("SetTasklistHeader", { label = ctx.header })
        hooks.trigger("DiscardTasklistItem", TASK.vehicle)
        hooks.trigger("DiscardTasklistItem", TASK.repo)
        hooks.trigger("SetTasklistTask", {
          id = TASK.main,
          label = label,
          subtext = subtext,
          active = true,
          type = "message",
          clear = false,
        })
      end
      lastTaskSignature = signature
    end
    taskVisible = true
    return
  end
  if shift.spawnBlocked then
    if ctx.purgeIndependent then ctx.purgeIndependent() end
    local label = shift.spawnBlocked.ready and "Ready to spawn" or "Clear the spawn area"
    local subtext = "Clear the highlighted stalls, then select Spawn vehicle"
    local signature = table.concat({label, subtext, "spawnBlocked"}, "|")
    if force or signature ~= lastTaskSignature then
      if hooks then
        hooks.trigger("SetTasklistHeader", { label = ctx.header })
        hooks.trigger("DiscardTasklistItem", TASK.vehicle)
        hooks.trigger("DiscardTasklistItem", TASK.repo)
        hooks.trigger("SetTasklistTask", {
          id = TASK.main,
          label = label,
          subtext = subtext,
          active = true,
          type = "message",
          clear = false,
        })
      end
      lastTaskSignature = signature
    end
    taskVisible = true
    return
  end
  if shift.paused then
    M.clearTaskGuidance(hooks)
    return
  end
  if shift.phase == "loopComplete" then
    M.clearTaskGuidance(hooks)
    if ctx.purgeIndependent then ctx.purgeIndependent() end
    return
  end
  if shift.jobKind == "materials" then
    local active = ctx.getMaterialsActive and ctx.getMaterialsActive()
    if active and active.status == "active" then
      M.clearTaskGuidance(hooks)
      if ctx.purgeIndependent then ctx.purgeIndependent() end
      return
    end
  end

  if shift.jobKind == "police" then
    if ctx.purgeIndependent then ctx.purgeIndependent() end
    if hooks then
      for _, id in ipairs(TASK_IDS) do
        if id ~= TASK.ending then hooks.trigger("DiscardTasklistItem", id) end
      end
    end
    taskVisible = false
    lastTaskSignature = nil
    if ctx.handoffPolice then ctx.handoffPolice() end
    return
  end

  local header = ctx.header
  if ctx.isBundle then
    local items = ctx.bundleItems or {}
    local repo = ctx.getRepo and ctx.getRepo()
    local repoActive = repo and repo.isEmploymentRepoActive and repo.isEmploymentRepoActive()
    local repoGuidance = repoActive and repo.getEmploymentTaskGuidance and repo.getEmploymentTaskGuidance() or nil
    local vehInfo = ctx.getVehicleTaskInfo and ctx.getVehicleTaskInfo()
    local bits = {}
    for _, item in ipairs(items) do
      local live = ""
      local useLive = vehInfo and (
        item.id == "vehicle"
        or (item.id == "repo" and shift.assignments and shift.assignments.vehicle and shift.assignments.vehicle.complete)
      )
      if useLive then
        live = tostring(vehInfo.stepType) .. "|" .. tostring(vehInfo.inCargoVehicle) .. "|" .. tostring(vehInfo.haulAcquired)
      end
      table.insert(bits, (item.complete and "done|" or "open|") .. tostring(item.id) .. "|" .. tostring(item.label) .. "|" .. tostring(repoGuidance and repoGuidance.label) .. "|" .. tostring(repoGuidance and repoGuidance.subtext) .. "|" .. live)
    end
    local signature = table.concat({header, table.concat(bits, ";"), tostring(shift.phase)}, "|")
    if force or signature ~= lastTaskSignature then
      if ctx.purgeIndependent then ctx.purgeIndependent() end
      if hooks then
        hooks.trigger("SetTasklistHeader", { label = header })
        hooks.trigger("DiscardTasklistItem", TASK.id)
        hooks.trigger("DiscardTasklistItem", TASK.main)
        for _, item in ipairs(items) do
          local taskId = item.id == "repo" and TASK.repo or TASK.vehicle
          if item.complete then
            hooks.trigger("DiscardTasklistItem", taskId)
          else
            local label = item.label or ""
            local subtext = item.subtext or ""
            local liveInfo = (item.id == "vehicle" or (item.id == "repo" and shift.assignments and shift.assignments.vehicle and shift.assignments.vehicle.complete)) and vehInfo
            if liveInfo and not item.complete then
              local needsEnter = (liveInfo.stepType == "enterVehicle" and not liveInfo.inCargoVehicle)
                or (liveInfo.stepType == "bringToDestination" and not liveInfo.inCargoVehicle and not liveInfo.haulAcquired)
              if needsEnter then
                label = "Enter the assigned vehicle"
                subtext = "Then deliver it to the marked destination"
              elseif liveInfo.stepType == "confirmDropOff" then
                label = item.label or "Drop off the vehicle"
                subtext = "Use the marked drop-off"
              end
            end
            if item.id == "repo" and not liveInfo then
              if repoGuidance then
                label = repoGuidance.label or label
                subtext = repoGuidance.subtext or subtext
              elseif not item.complete then
                subtext = "Get in the company flatbed to start"
              end
            end
            hooks.trigger("SetTasklistTask", {
              id = taskId,
              label = label,
              subtext = subtext,
              done = false,
              active = true,
              type = "message",
              clear = false,
            })
          end
        end
      end
      lastTaskSignature = signature
    end
    taskVisible = true
    return
  end

  local label, subtext
  local busGuidance = shift.jobKind == "bus" and ctx.getBusGuidance and ctx.getBusGuidance() or nil
  local ambulanceGuidance = shift.jobKind == "paramedic" and ctx.getAmbulanceGuidance and ctx.getAmbulanceGuidance() or nil
  if busGuidance then
    label, subtext = busGuidance.label, busGuidance.subtext
  elseif ambulanceGuidance then
    label, subtext = ambulanceGuidance.label, ambulanceGuidance.subtext
  elseif shift.phase == "active" then
    label = shift.outboundLabel or "On company time"
    subtext = shift.outboundSubtext or "End day to collect today's wages and return the company vehicle"
  elseif shift.jobKind == "repo" and shift.phase == "outbound" then
    if shift.repoPendingStart then
      label = "Get in the company flatbed"
      subtext = "The dispatcher is waiting to assign a pickup"
    else
      local repo = ctx.getRepo and ctx.getRepo()
      local guidance = repo and repo.getEmploymentTaskGuidance and repo.getEmploymentTaskGuidance()
      if guidance then
        label = guidance.label
        subtext = guidance.subtext
      else
        label = shift.outboundLabel or "Pickup — haul a vehicle back to the yard"
        subtext = shift.outboundSubtext or "Pick it up with the company flatbed"
      end
    end
  elseif ctx.accidentTask then
    local accidentTask = ctx.accidentTask
    label = accidentTask and accidentTask.label or "Accident recovery"
    subtext = accidentTask and accidentTask.subtext or ""
  elseif shift.wrecked then
    label = "Return the company vehicle to the yard"
    subtext = "Equipment is too damaged for another load"
  elseif shift.phase == "outbound" then
    label = shift.outboundLabel or "Deliver the assigned load"
    subtext = shift.outboundSubtext or "Company assignment"
    if shift.stringMode and shift.stops then
      local n = math.max(tonumber(shift.stringStopTotal) or 0, #shift.stops)
      local i = math.min(shift.stopIndex or 1, math.max(n, 1))
      if n > 0 and not (shift.outboundLabel and shift.outboundLabel:find("Stop ", 1, true) == 1) then
        label = string.format("Stop %d/%d · %s", i, n, label)
      end
      subtext = shift.outboundSubtext or (n > 0 and string.format("Stop %d of %d", i, n) or subtext)
    end
  elseif shift.phase == "return" then
    if shift.returnIsBackhaul and ctx.assignedReturnCargoInVehicle then
      if ctx.clearReturnNeedsPickup then ctx.clearReturnNeedsPickup() end
      label = shift.returnDeliverLabel or shift.returnLabel or "Deliver return load"
    else
      label = shift.returnLabel or "Return to the company yard"
    end
    subtext = shift.returnSubtext
      or (shift.awaitingLoopChoice and "Then choose your next job or end the day")
      or "Company return"
  else
    label = "On company time"
    subtext = ""
  end

  local signature = table.concat({header, label, subtext, tostring(shift.phase)}, "|")
  if force or signature ~= lastTaskSignature then
    if ctx.purgeIndependent then ctx.purgeIndependent() end
    if hooks then
      hooks.trigger("SetTasklistHeader", { label = header })
      hooks.trigger("DiscardTasklistItem", TASK.id)
      hooks.trigger("DiscardTasklistItem", TASK.vehicle)
      hooks.trigger("DiscardTasklistItem", TASK.repo)
      hooks.trigger("SetTasklistTask", {
        id = TASK.main,
        label = label,
        subtext = subtext,
        active = true,
        type = "message",
        clear = false,
      })
    end
    lastTaskSignature = signature
  end
  taskVisible = true
end

function M.refreshTaskGuidance(ctx, force)
  ctx = ctx or {}
  refreshTaskGuidance(ctx, force)
  local shift = ctx.shift
  local hooks = ctx.guihooks or guihooks
  local ending = shift ~= nil and shift.endAfterAssignment == true and not shift.paused and shift.phase ~= "loopComplete"
  if hooks and (force or ending ~= endingTaskVisible) then
    if ending then
      hooks.trigger("SetTasklistTask", {
        id = TASK.ending,
        label = "Final assignment",
        subtext = "Finish your current assignment to collect pay and clock out.",
        active = true,
        type = "message",
        clear = false,
      })
    else
      hooks.trigger("DiscardTasklistItem", TASK.ending)
    end
    endingTaskVisible = ending
  end
end

return M
