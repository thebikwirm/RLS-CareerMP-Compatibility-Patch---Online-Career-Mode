from __future__ import annotations

import argparse
import re
import shutil
from pathlib import Path

from build_release import (
    RLS_REMOVE_PREFIXES,
    build_mod,
    read_careermp_entries,
    sha256sum,
)
from zip_utils import add_zip_engine_argument, describe_zip_engine, write_zip


def validate_careermp_039(careermp_zip: Path) -> None:
    entries = read_careermp_entries(careermp_zip)
    compat_path = "lua/ge/extensions/careerMP/compat.lua"
    compat = entries.get(compat_path)
    if not compat:
        raise SystemExit(
            "CareerMP input is not the 0.39 port: "
            f"missing {compat_path}"
        )

    text = compat.decode("utf-8", errors="replace")
    if 'targetGameVersion = "0.39"' not in text:
        raise SystemExit(
            "CareerMP input does not advertise targetGameVersion 0.39. "
            "Use the maintained CareerMP-0.39 client zip."
        )


def install_careermp_watchdog(entries: dict[str, bytes]) -> None:
    """Add a lightweight CareerMP feature watchdog and resilient loader."""

    watchdog_path = "lua/ge/extensions/careerMP/watchdog.lua"
    watchdog = r'''local M = {}

local logTag = "careerMP.watchdog"
local features = {}
local retryDelay = 5
local elapsed = 0
local summaryPrinted = false

local function nowState(name)
  features[name] = features[name] or {
    name = name,
    attempts = 0,
    state = "pending",
    lastError = nil,
    path = name
  }
  return features[name]
end

local function extensionName(path)
  return (path or ""):gsub("[^%w_]", "_")
end

local function isLoaded(path)
  if type(extensions) ~= "table" then return false end
  return extensions[extensionName(path)] ~= nil
end

local function doLoad(path)
  local state = nowState(path)
  state.attempts = state.attempts + 1

  local ok, err = xpcall(function()
    load(path)
    setExtensionUnloadMode(path, "manual")
  end, debug.traceback)

  if ok and isLoaded(path) then
    state.state = state.attempts > 1 and "recovered" or "loaded"
    state.lastError = nil
    log("I", logTag, string.format("%s: %s on attempt %d", state.state, path, state.attempts))
    return true
  end

  state.state = state.attempts > 1 and "failed-final" or "failed-retry-pending"
  state.lastError = tostring(err or "extension not present after load()")
  log("E", logTag, string.format(
    "%s: %s attempt %d failed: %s",
    state.state, path, state.attempts, state.lastError
  ))
  return false
end

function M.loadPersistent(path)
  return doLoad(path)
end

function M.recordFailure(name, err)
  local state = nowState(name)
  state.state = "runtime-failed"
  state.lastError = tostring(err)
  log("E", logTag, "runtime failure: " .. tostring(name) .. ": " .. tostring(err))
end

function M.recordSuccess(name)
  local state = nowState(name)
  if state.state ~= "recovered" then
    state.state = "loaded"
  end
  state.lastError = nil
end

local function retryPending()
  for path, state in pairs(features) do
    if state.state == "failed-retry-pending" and state.attempts < 2 then
      log("W", logTag, "retrying failed CareerMP feature once: " .. tostring(path))
      doLoad(path)
    end
  end
end

local function stateCounts()
  local counts = {
    loaded = 0,
    recovered = 0,
    pending = 0,
    failed = 0,
    runtimeFailed = 0
  }
  for _, state in pairs(features) do
    if state.state == "loaded" then
      counts.loaded = counts.loaded + 1
    elseif state.state == "recovered" then
      counts.recovered = counts.recovered + 1
    elseif state.state == "failed-retry-pending" or state.state == "pending" then
      counts.pending = counts.pending + 1
    elseif state.state == "runtime-failed" then
      counts.runtimeFailed = counts.runtimeFailed + 1
    else
      counts.failed = counts.failed + 1
    end
  end
  return counts
end

function M.retryPending()
  retryPending()
end

function M.dumpSummary()
  local counts = stateCounts()
  log("I", logTag, "========== CareerMP feature health ==========")
  log("I", logTag, string.format(
    "loaded=%d recovered=%d pending=%d failed=%d runtimeFailed=%d",
    counts.loaded, counts.recovered, counts.pending, counts.failed, counts.runtimeFailed
  ))

  local names = {}
  for name in pairs(features) do table.insert(names, name) end
  table.sort(names)

  summaryPrinted = true

  for _, name in ipairs(names) do
    local state = features[name]
    local line = string.format("[%s] %s (attempts=%d)", state.state, name, state.attempts)
    if state.lastError then
      line = line .. " :: " .. state.lastError:gsub("[\r\n]+", " | ")
    end
    local level = (state.state == "loaded" or state.state == "recovered") and "I" or "W"
    log(level, logTag, line)
  end
  log("I", logTag, "============================================")
  return features
end

function M.getFeatureHealth()
  return features
end

function M.onUpdate(dtReal)
  elapsed = elapsed + (dtReal or 0)

  if elapsed >= retryDelay then
    retryPending()
  end

  if elapsed >= retryDelay + 2 and not summaryPrinted then
    M.dumpSummary()
  end
end

function M.onCareerActive(active)
  if active then
    retryPending()
    M.dumpSummary()
  end
end

function M.onExtensionLoaded()
  log("I", logTag, "CareerMP watchdog active; failed feature loads will continue and retry once")
end

return M
'''
    entries[watchdog_path] = watchdog.encode("utf-8")

    modscript_path = "scripts/CareerMP/modScript.lua"
    payload = entries.get(modscript_path)
    if not payload:
        raise RuntimeError(f"CareerMP input missing {modscript_path}")

    text = payload.decode("utf-8").replace("\r\n", "\n")
    if "CareerMP watchdog bootstrap" not in text:
        old = '''local function loadPersistent(path)
\tload(path)
\tsetExtensionUnloadMode(path, 'manual')
end
'''
        new = '''-- CareerMP watchdog bootstrap
load('careerMP/watchdog')
setExtensionUnloadMode('careerMP/watchdog', 'manual')

local function loadPersistent(path)
\tlocal watchdog = extensions and extensions["careerMP_watchdog"]
\tif watchdog and watchdog.loadPersistent then
\t\treturn watchdog.loadPersistent(path)
\tend

\t-- Fallback only if the watchdog itself could not be resolved.
\tlocal ok, err = xpcall(function()
\t\tload(path)
\t\tsetExtensionUnloadMode(path, 'manual')
\tend, debug.traceback)
\tif not ok then
\t\tlog("E", "careerMP.modScript", "feature load failed but startup will continue: " .. tostring(path) .. ": " .. tostring(err))
\tend
\treturn ok
end
'''
        if old not in text:
            raise RuntimeError(
                "Unable to install CareerMP watchdog loader; modScript.lua source layout changed"
            )
        text = text.replace(old, new, 1)

    if "loadPersistent('careerMP/dragSync')" in text and "watchdog.dumpSummary()" not in text:
        text = text.replace(
            "loadPersistent('careerMP/dragSync')",
            """loadPersistent('careerMP/dragSync')

local watchdog = extensions and extensions["careerMP_watchdog"]
if watchdog and watchdog.dumpSummary then
\twatchdog.dumpSummary()
end""",
            1,
        )

    entries[modscript_path] = text.encode("utf-8")
    print("CareerMP feature watchdog installed:")
    print("  - protected feature loading")
    print("  - continue after failed feature")
    print("  - one delayed retry per failed feature")
    print("  - compact feature health summary")


def patch_careermp_039(entries: dict[str, bytes]) -> None:
    """Apply narrow fixes required by BeamNG 0.39.4/RLS integration."""

    compat_path = "lua/ge/extensions/careerMP/compat.lua"
    compat = entries.get(compat_path)
    if not compat:
        raise SystemExit(f"CareerMP input missing {compat_path}")

    text = compat.decode("utf-8").replace("\r\n", "\n")
    old = """local function callPick(module, names, ...)
\tlocal fn, matched = pick(module, unpack(names))
\tif not fn then
\t\tlog("E", "careerMP.compat", "none of {" .. table.concat(names, ", ") .. "} exist on target module")
\t\treturn nil
\tend
\treturn fn(...), matched
end
"""
    new = """local function callPick(module, names, ...)
\tlocal fn = pick(module, unpack(names))
\tif not fn then
\t\tlog("E", "careerMP.compat", "none of {" .. table.concat(names, ", ") .. "} exist on target module")
\t\treturn nil
\tend
\t-- Keep all return values from the underlying BeamNG API. In Lua, placing
\t-- fn(...) before another return expression collapses it to one value.
\treturn fn(...)
end
"""
    if old not in text:
        if "return fn(...)\nend" not in text:
            raise RuntimeError("Unable to patch CareerMP 0.39 callPick return handling")
    else:
        text = text.replace(old, new, 1)
    entries[compat_path] = text.encode("utf-8")

    patches_path = "lua/ge/extensions/careerMP/careerPatches.lua"
    payload = entries.get(patches_path)
    if not payload:
        raise SystemExit(f"CareerMP input missing {patches_path}")

    text = payload.decode("utf-8").replace("\r\n", "\n")
    old = """local function installRLS039RuntimeGuards()
\t-- RLS 2.6.x markerInteraction can query BeamNG 0.39's empty KD-tree
\t-- representation (itemCount=0/tree=nil) every frame. Guard the getter at
\t-- runtime so RLS override precedence cannot replace this compatibility fix.
\tlocal markerExt = type(extensions) == "table" and extensions["gameplay_playmodeMarkers"] or nil
\tif markerExt and markerExt.getPlaymodeClustersAsQuadtree and not markerExt.__careerMP39EmptyQtGuard then
\t\tlocal originalGetQt = markerExt.getPlaymodeClustersAsQuadtree
\t\tlocal emptyQt = {}
\t\tfunction emptyQt:queryNotNested(...)
\t\t\treturn function() return nil end
\t\tend
\t\tmarkerExt.getPlaymodeClustersAsQuadtree = function(...)
\t\t\tlocal clusters = markerExt.getPlaymodeClusters and markerExt.getPlaymodeClusters() or nil
\t\t\tif not clusters or next(clusters) == nil then
\t\t\t\treturn emptyQt
\t\t\tend
\t\t\treturn originalGetQt(...)
\t\tend
\t\tmarkerExt.__careerMP39EmptyQtGuard = true
\t\tlog("I", logTag, "installed BeamNG 0.39 empty marker-quadtree runtime guard")
\tend

\tlocal deliveryExt = type(extensions) == "table" and extensions["career_modules_delivery_general"] or career_modules_delivery_general
\tif deliveryExt and deliveryExt.getDeliveryModePenalty then
\t\tif not deliveryExt.__careerMP39PenaltyGuard then
\t\t\tlocal originalPenalty = deliveryExt.getDeliveryModePenalty
\t\t\tdeliveryExt.getDeliveryModePenalty = function(...)
\t\t\t\tlocal ok, value = pcall(originalPenalty, ...)
\t\t\t\tif ok then return value end
\t\t\t\tlog("W", logTag, "delivery penalty requested before delivery modules were ready; using zero penalty")
\t\t\t\treturn {money = 0}
\t\t\tend
\t\t\tdeliveryExt.__careerMP39PenaltyGuard = true
\t\tend
\tend
end

local function withRemoteVehiclesProtected(fn, ...)
\tinstallProtection()
\tlocal results = {pcall(fn, ...)}
\tremoveProtection()
\tlocal ok = table.remove(results, 1)
\tif not ok then
\t\tlog("E", logTag, "protected call failed: " .. tostring(results[1]))
\t\treturn nil
\tend
\treturn unpack(results)
end
"""
    new = """local function installRLS039RuntimeGuards()
\t-- RLS 2.6.x markerInteraction can query BeamNG 0.39's empty KD-tree
\t-- representation (itemCount=0/tree=nil) every frame. Guard the getter at
\t-- runtime so RLS override precedence cannot replace this compatibility fix.
\tlocal markerExt = type(extensions) == "table" and extensions["gameplay_playmodeMarkers"] or nil
\tif markerExt and markerExt.getPlaymodeClustersAsQuadtree and not markerExt.__careerMP39EmptyQtGuard then
\t\tlocal originalGetQt = markerExt.getPlaymodeClustersAsQuadtree
\t\tlocal emptyQt = {}
\t\tfunction emptyQt:queryNotNested(...)
\t\t\treturn function() return nil end
\t\tend
\t\tmarkerExt.getPlaymodeClustersAsQuadtree = function(...)
\t\t\tlocal clusters = markerExt.getPlaymodeClusters and markerExt.getPlaymodeClusters() or nil
\t\t\tif not clusters or next(clusters) == nil then
\t\t\t\treturn emptyQt
\t\t\tend
\t\t\treturn originalGetQt(...)
\t\tend
\t\tmarkerExt.__careerMP39EmptyQtGuard = true
\t\tlog("I", logTag, "installed BeamNG 0.39 empty marker-quadtree runtime guard")
\tend

\tlocal deliveryExt = type(extensions) == "table" and extensions["career_modules_delivery_general"] or career_modules_delivery_general
\tif deliveryExt and deliveryExt.getDeliveryModePenalty then
\t\tif not deliveryExt.__careerMP39PenaltyGuard then
\t\t\tlocal originalPenalty = deliveryExt.getDeliveryModePenalty
\t\t\tdeliveryExt.getDeliveryModePenalty = function(...)
\t\t\t\tlocal ok, value = pcall(originalPenalty, ...)
\t\t\t\tif ok then return value end
\t\t\t\tlog("W", logTag, "delivery penalty requested before delivery modules were ready; using zero penalty")
\t\t\t\treturn {money = 0}
\t\t\tend
\t\t\tdeliveryExt.__careerMP39PenaltyGuard = true
\t\t\tlog("I", logTag, "installed RLS 0.39 delivery penalty runtime guard")
\t\tend
\tend
end

local function withRemoteVehiclesProtected(fn, ...)
\tinstallProtection()

\t-- RLS 2.6.x can query organization reputation while BeamNG is still
\t-- activating career modules, before playerAttributes has initialized.
\t-- The playerAttributes extension may not exist yet when this wrapper starts,
\t-- so install a temporary organization-layer guard as well.
\tlocal originalGetAttributeValue = nil
\tlocal originalGetOrganizations = nil
\tlocal originalExtensionsLoad = nil

\t-- Preload playerAttributes before old RLS starts its bulk career-module load.
\t-- In the old package loans can be initialized first and immediately query
\t-- reputation, so waiting for the normal career batch is too late.
\tif type(extensions) == "table" and type(extensions.load) == "function" then
\t\tpcall(extensions.load, "career_modules_playerAttributes")
\tend

\t-- Old RLS career.lua passes the whole career module list to extensions.load()
\t-- in filesystem enumeration order. Intercept that one batch during career
\t-- activation and put playerAttributes/reputation/delivery support ahead of
\t-- loans and the rest.
\tif type(extensions) == "table" and type(extensions.load) == "function" then
\t\toriginalExtensionsLoad = extensions.load
\t\textensions.load = function(arg, ...)
\t\t\tif type(arg) == "table" then
\t\t\t\tlocal priority = {
\t\t\t\t\tcareer_modules_playerAttributes = 0,
\t\t\t\t\tcareer_modules_reputation = 10,
\t\t\t\t\tcareer_modules_delivery_parcelManager = 20,
\t\t\t\t\tcareer_modules_delivery_vehicleTasks = 21,
\t\t\t\t\tcareer_modules_delivery_generator = 22,
\t\t\t\t\tcareer_modules_delivery_progress = 23,
\t\t\t\t\tcareer_modules_delivery_general = 30,
\t\t\t\t\tcareer_modules_loans = 40,
\t\t\t\t}
\t\t\t\ttable.sort(arg, function(a, b)
\t\t\t\t\tlocal pa = priority[a] or 100
\t\t\t\t\tlocal pb = priority[b] or 100
\t\t\t\t\tif pa == pb then return tostring(a) < tostring(b) end
\t\t\t\t\treturn pa < pb
\t\t\t\tend)
\t\t\t\tlog("I", logTag, "reordered career module batch before activation")
\t\t\tend
\t\t\treturn originalExtensionsLoad(arg, ...)
\t\tend
\tend

\t-- freeroam_organizations may not be loaded yet at the moment CareerMP enters
\t-- the protected career-start call, but loans will use it moments later while
\t-- the career module batch is being initialized. Load/resolve it now so we can
\t-- install the temporary guard before that happens.
\tlocal organizationsExt = type(extensions) == "table" and extensions["freeroam_organizations"] or nil
\tif not organizationsExt and type(extensions) == "table" and type(extensions.load) == "function" then
\t\tpcall(extensions.load, "freeroam_organizations")
\t\torganizationsExt = extensions["freeroam_organizations"]
\tend

\tlocal playerAttributesExt = type(extensions) == "table" and extensions["career_modules_playerAttributes"] or nil
\tif playerAttributesExt and playerAttributesExt.getAttributeValue then
\t\tlog("I", logTag, "preloaded playerAttributes and installed temporary getter guard before career activation")
\telse
\t\tlog("W", logTag, "playerAttributes preload did not resolve before career activation")
\tend

\tif organizationsExt and organizationsExt.getOrganizations then
\t\tlog("I", logTag, "installed temporary organizations guard before career activation")
\t\toriginalGetOrganizations = organizationsExt.getOrganizations
\t\torganizationsExt.getOrganizations = function(...)
\t\t\tlocal ok, value = pcall(originalGetOrganizations, ...)
\t\t\tif ok then return value end
\t\t\tlog("W", logTag, "organizations requested before playerAttributes was ready; returning empty organization list for this activation step")
\t\t\treturn {}
\t\tend
\tend

\tif playerAttributesExt and playerAttributesExt.getAttributeValue then
\t\toriginalGetAttributeValue = playerAttributesExt.getAttributeValue
\t\tplayerAttributesExt.getAttributeValue = function(attributeName)
\t\t\tlocal ok, value = pcall(originalGetAttributeValue, attributeName)
\t\t\tif ok then return value end
\t\t\tlog("W", logTag, "playerAttributes not ready during career activation for " .. tostring(attributeName) .. "; using 0")
\t\t\treturn 0
\t\tend
\tend

\tlocal args = {...}
\tlocal function invoke()
\t\treturn fn(unpack(args))
\tend
\tlocal results = {xpcall(invoke, debug.traceback)}

\tif originalGetAttributeValue and playerAttributesExt then
\t\tplayerAttributesExt.getAttributeValue = originalGetAttributeValue
\tend
\tif originalGetOrganizations and organizationsExt then
\t\torganizationsExt.getOrganizations = originalGetOrganizations
\tend
\tif originalExtensionsLoad and type(extensions) == "table" then
\t\textensions.load = originalExtensionsLoad
\tend
\tremoveProtection()

\tlocal ok = table.remove(results, 1)
\tif not ok then
\t\tlog("E", logTag, "protected call failed with traceback:\\n" .. tostring(results[1]))
\t\treturn nil
\tend
\treturn unpack(results)
end
"""
    current_markers = (
        "preloaded playerAttributes and installed temporary getter guard before career activation",
        "playerAttributes preload did not resolve before career activation",
        "reordered career module batch before activation",
        "delivery penalty requested before delivery modules were ready; using zero penalty",
        "installed BeamNG 0.39 empty marker-quadtree runtime guard",
    )

    if old in text:
        text = text.replace(old, new, 1)
    elif all(marker in text for marker in current_markers):
        # Already at the current canonical runtime-guard version.
        pass
    else:
        # CareerMP.zip is commonly reused from the previous build. Earlier
        # compatibility builds can contain only part of the runtime-guard
        # section. Replace the protected-call function and inject the complete
        # canonical section, including the delivery helper.
        pattern = re.compile(
            r"local function withRemoteVehiclesProtected\(fn, \.\.\.\)\n.*?\nend\n(?=\nlocal function |\nM\.|\nreturn M)",
            re.DOTALL,
        )
        match = pattern.search(text)
        if not match:
            raise RuntimeError(
                "Unable to upgrade CareerMP withRemoteVehiclesProtected(); source layout changed"
            )

        # Remove an older delivery helper if it exists so we do not duplicate it.
        helper_start = text.rfind("local function installRLS039RuntimeGuards()", 0, match.start())
        if helper_start != -1:
            between = text[helper_start:match.start()]
            if "local function withRemoteVehiclesProtected" not in between:
                replace_start = helper_start
            else:
                replace_start = match.start()
        else:
            replace_start = match.start()

        text = text[:replace_start] + new + text[match.end():]
        print("  - upgraded existing careerPatches.lua runtime guard section to current version")

    # Build-time proof: never silently ship an older traceback-only patch.
    required_runtime_markers = current_markers
    missing = [marker for marker in required_runtime_markers if marker not in text]
    if missing:
        raise RuntimeError(
            "CareerMP runtime-guard patch incomplete; missing markers: " + ", ".join(missing)
        )

    # Ensure RLS runtime guards are installed even when BeamNG/RLS activates
    # career modules through a path that bypasses CareerMP's explicit
    # createOrLoadCareerAndStart wrapper.
    always_guard_marker = "CareerMP39 always-on RLS runtime guard tick"
    if always_guard_marker not in text:
        old_update = """local function onUpdate()
\tif not applied then M.apply() end
\t-- Safety net: onCareerActive is deferred on the level-change path, and on a failed
\t-- activation it may never arrive at all.
\tif protection and (os.clockhp() - protection.installedAt) > PROTECTION_MAX_SECONDS then
\t\tlog("W", logTag, "vehicle protection timed out - releasing")
\t\tremoveProtection()
\tend
end
"""
        new_update = """local function onUpdate()
\t-- CareerMP39 always-on RLS runtime guard tick
\tinstallRLS039RuntimeGuards()

\tif not applied then M.apply() end
\t-- Safety net: onCareerActive is deferred on the level-change path, and on a failed
\t-- activation it may never arrive at all.
\tif protection and (os.clockhp() - protection.installedAt) > PROTECTION_MAX_SECONDS then
\t\tlog("W", logTag, "vehicle protection timed out - releasing")
\t\tremoveProtection()
\tend
end
"""
        if old_update not in text:
            raise RuntimeError(
                "Unable to install always-on RLS runtime guard tick; "
                "careerPatches.lua onUpdate layout changed"
            )
        text = text.replace(old_update, new_update, 1)
        print("  - careerPatches.lua always-on RLS runtime guard tick installed")

    if always_guard_marker not in text:
        raise RuntimeError("CareerMP always-on RLS runtime guard marker missing after patch")

    entries[patches_path] = text.encode("utf-8")

    enabler_path = "lua/ge/extensions/careerMPEnabler.lua"
    enabler_payload = entries.get(enabler_path)
    if enabler_payload:
        enabler_text = enabler_payload.decode("utf-8").replace("\\r\\n", "\\n")

        # BeamNG/BeamMP 0.39 can finish loading the MP map without ever
        # delivering onWorldReadyState(2) to CareerMP. Add a one-shot fallback
        # armed by onClientPostStartMission so profile sync cannot stall forever.
        fallback_marker = "CareerMP 0.39 world-ready fallback"
        if fallback_marker not in enabler_text:
            state_anchor = """local careerMPActive = false
local syncRequested = false
"""
            state_replacement = """local careerMPActive = false
local syncRequested = false

-- CareerMP 0.39 world-ready fallback
local syncFallbackArmed = false
local syncFallbackElapsed = 0
local syncFallbackDelay = 5
"""
            if state_anchor not in enabler_text:
                raise RuntimeError(
                    "Unable to install CareerMP world-ready fallback state; "
                    "careerMPEnabler.lua source layout changed"
                )
            enabler_text = enabler_text.replace(state_anchor, state_replacement, 1)

            world_pattern = re.compile(
                r"local function onWorldReadyState\(state\)\n.*?\nend\n\nlocal function onClientPostStartMission",
                re.DOTALL,
            )
            world_match = world_pattern.search(enabler_text)
            if not world_match:
                raise RuntimeError(
                    "Unable to install CareerMP world-ready fallback; "
                    "onWorldReadyState/onClientPostStartMission layout changed"
                )

            replacement_block = r'''local function requestCareerSync(reason)
	if syncRequested then return false end
	if not (MPCoreNetwork and MPCoreNetwork.isMPSession and MPCoreNetwork.isMPSession()) then
		return false
	end

	log("I", logTag, "requesting CareerMP sync (" .. tostring(reason) .. ")")
	TriggerServerEvent("prefabSyncRequested", "")
	TriggerServerEvent("careerSyncRequested", "")
	syncRequested = true
	syncFallbackArmed = false
	return true
end

local function onWorldReadyState(state)
	-- CareerMP watchdog world-ready checkpoint
	local watchdog = extensions and extensions["careerMP_watchdog"]
	if watchdog and watchdog.retryPending then watchdog.retryPending() end
	if watchdog and watchdog.dumpSummary then watchdog.dumpSummary() end

	if state == 2 then
		requestCareerSync("worldReadyState=2")
	end
end

local function onClientPostStartMission(levelPath)
	patchTopBar()

	if not syncRequested and MPCoreNetwork and MPCoreNetwork.isMPSession and MPCoreNetwork.isMPSession() then
		syncFallbackArmed = true
		syncFallbackElapsed = 0
		log("I", logTag, "CareerMP 0.39 world-ready fallback armed after mission start: " .. tostring(levelPath))
	end
end

local function onUpdate(dtReal, dtSim, dtRaw)
	if syncFallbackArmed and not syncRequested then
		syncFallbackElapsed = syncFallbackElapsed + (dtReal or 0)
		if syncFallbackElapsed >= syncFallbackDelay then
			if requestCareerSync("mission-start fallback after " .. tostring(syncFallbackDelay) .. "s") then
				log("W", logTag, "worldReadyState=2 was not observed; CareerMP sync requested by fallback")
			end
		end
	end

	if worldReadyState ~= 2 or not clientConfig then return end
'''
            # Replace worldReady + post-start + opening of existing onUpdate.
            old_segment = world_match.group(0)
            # Drop the trailing onClientPostStartMission token from match and
            # replace through the opening of onUpdate separately.
            start = world_match.start()
            # Find the existing onUpdate opening after the matched block.
            update_start = enabler_text.find("local function onUpdate(dtReal, dtSim, dtRaw)", start)
            if update_start == -1:
                raise RuntimeError(
                    "Unable to install CareerMP world-ready fallback; onUpdate not found"
                )
            existing_update_body_start = enabler_text.find("\n", update_start) + 1
            # Preserve the existing onUpdate body after its first guard line.
            guard_line = "\tif worldReadyState ~= 2 or not clientConfig then return end\n"
            if not enabler_text.startswith(guard_line, existing_update_body_start):
                raise RuntimeError(
                    "Unable to install CareerMP world-ready fallback; onUpdate guard changed"
                )
            body_after_guard = existing_update_body_start + len(guard_line)
            enabler_text = (
                enabler_text[:start]
                + replacement_block
                + enabler_text[body_after_guard:]
            )

            print("  - CareerMP 0.39 world-ready sync fallback installed")

        if fallback_marker not in enabler_text:
            raise RuntimeError("CareerMP world-ready fallback marker missing after patch")

        # V2: onClientPostStartMission is not guaranteed to reach CareerMP on
        # BeamMP 0.39. Self-arm from onUpdate when BeamMP reports an MP session
        # and getMissionFilename() has held a real level path long enough.
        fallback_v2_marker = "CareerMP 0.39 level-loaded fallback v2"
        if fallback_v2_marker not in enabler_text:
            old_state = """-- CareerMP 0.39 world-ready fallback
local syncFallbackArmed = false
local syncFallbackElapsed = 0
local syncFallbackDelay = 5
"""
            new_state = """-- CareerMP 0.39 world-ready fallback
-- CareerMP 0.39 level-loaded fallback v2
local syncFallbackArmed = false
local syncFallbackElapsed = 0
local syncFallbackDelay = 15
local syncFallbackLevel = nil
"""
            if old_state not in enabler_text:
                raise RuntimeError(
                    "Unable to upgrade CareerMP world-ready fallback state to v2"
                )
            enabler_text = enabler_text.replace(old_state, new_state, 1)

            old_post = """local function onClientPostStartMission(levelPath)
\tpatchTopBar()

\tif not syncRequested and MPCoreNetwork and MPCoreNetwork.isMPSession and MPCoreNetwork.isMPSession() then
\t\tsyncFallbackArmed = true
\t\tsyncFallbackElapsed = 0
\t\tlog("I", logTag, "CareerMP 0.39 world-ready fallback armed after mission start: " .. tostring(levelPath))
\tend
end
"""
            new_post = """local function onClientPostStartMission(levelPath)
\tpatchTopBar()

\tif not syncRequested and MPCoreNetwork and MPCoreNetwork.isMPSession and MPCoreNetwork.isMPSession() then
\t\tsyncFallbackArmed = true
\t\tsyncFallbackElapsed = 0
\t\tsyncFallbackLevel = tostring(levelPath or "")
\t\tlog("I", logTag, "CareerMP 0.39 fallback armed from mission start: " .. syncFallbackLevel)
\tend
end
"""
            if old_post not in enabler_text:
                raise RuntimeError(
                    "Unable to upgrade CareerMP onClientPostStartMission fallback to v2"
                )
            enabler_text = enabler_text.replace(old_post, new_post, 1)

            old_update = """local function onUpdate(dtReal, dtSim, dtRaw)
\tif syncFallbackArmed and not syncRequested then
\t\tsyncFallbackElapsed = syncFallbackElapsed + (dtReal or 0)
\t\tif syncFallbackElapsed >= syncFallbackDelay then
\t\t\tif requestCareerSync("mission-start fallback after " .. tostring(syncFallbackDelay) .. "s") then
\t\t\t\tlog("W", logTag, "worldReadyState=2 was not observed; CareerMP sync requested by fallback")
\t\t\tend
\t\tend
\tend

\tif worldReadyState ~= 2 or not clientConfig then return end
"""
            new_update = """local function onUpdate(dtReal, dtSim, dtRaw)
\tif not syncRequested and MPCoreNetwork and MPCoreNetwork.isMPSession and MPCoreNetwork.isMPSession() then
\t\tlocal mission = ""
\t\tif type(getMissionFilename) == "function" then
\t\t\tmission = tostring(getMissionFilename() or "")
\t\tend

\t\tif mission ~= "" then
\t\t\tif not syncFallbackArmed or syncFallbackLevel ~= mission then
\t\t\t\tsyncFallbackArmed = true
\t\t\t\tsyncFallbackElapsed = 0
\t\t\t\tsyncFallbackLevel = mission
\t\t\t\tlog("I", logTag, "CareerMP 0.39 level-loaded fallback armed: " .. mission)
\t\t\telse
\t\t\t\tsyncFallbackElapsed = syncFallbackElapsed + (dtReal or 0)
\t\t\tend

\t\t\tif syncFallbackElapsed >= syncFallbackDelay then
\t\t\t\tif requestCareerSync("stable loaded level fallback after " .. tostring(syncFallbackDelay) .. "s") then
\t\t\t\t\tlog("W", logTag, "worldReadyState=2 was not observed; CareerMP sync requested from stable level fallback")
\t\t\t\tend
\t\t\tend
\t\telse
\t\t\tsyncFallbackArmed = false
\t\t\tsyncFallbackElapsed = 0
\t\t\tsyncFallbackLevel = nil
\t\tend
\tend

\tif worldReadyState ~= 2 or not clientConfig then return end
"""
            if old_update not in enabler_text:
                raise RuntimeError(
                    "Unable to upgrade CareerMP onUpdate fallback to v2"
                )
            enabler_text = enabler_text.replace(old_update, new_update, 1)

            # Reset fallback state when leaving the server.
            leave_old = """\tcareerMPActive = false
\tsyncRequested = false
end
"""
            leave_new = """\tcareerMPActive = false
\tsyncRequested = false
\tsyncFallbackArmed = false
\tsyncFallbackElapsed = 0
\tsyncFallbackLevel = nil
end
"""
            if leave_old in enabler_text:
                enabler_text = enabler_text.replace(leave_old, leave_new, 1)

            print("  - CareerMP 0.39 stable-level sync fallback v2 installed")

        if fallback_v2_marker not in enabler_text:
            raise RuntimeError("CareerMP stable-level fallback v2 marker missing after patch")

        entries[enabler_path] = enabler_text.encode("utf-8")
        if "CareerMP watchdog world-ready checkpoint" not in enabler_text:
            world_ready_pattern = re.compile(
                r"(function M\.onWorldReadyState\([^\n]*\)\n)",
                re.MULTILINE,
            )
            match = world_ready_pattern.search(enabler_text)
            if match:
                injection = """\\1\\t-- CareerMP watchdog world-ready checkpoint
\\tlocal watchdog = extensions and extensions[\"careerMP_watchdog\"]
\\tif watchdog and watchdog.retryPending then watchdog.retryPending() end
\\tif watchdog and watchdog.dumpSummary then watchdog.dumpSummary() end
"""
                enabler_text = world_ready_pattern.sub(injection, enabler_text, count=1)
                entries[enabler_path] = enabler_text.encode("utf-8")
            else:
                print("  - watchdog world-ready checkpoint not inserted: onWorldReadyState layout not found")

    print("Patched CareerMP-0.39:")
    print("  - compat.lua preserves native multiple return values")
    print("  - careerPatches.lua logs full protected-call tracebacks")
    print("  - careerPatches.lua current RLS runtime guards verified")
    print("  - careerPatches.lua installs RLS guards continuously/idempotently")
    print("  - careerMPEnabler.lua has MP-only stable-level sync fallback (15s)")


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent

    parser = argparse.ArgumentParser(
        description="Build the BeamNG 0.39.4 RLS compatibility zip for CareerMP-0.39."
    )
    parser.add_argument("--rls-original", required=True, type=Path)
    parser.add_argument("--careermp-039", required=True, type=Path)
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=repo_root / "built-039",
        help="Directory for build artifacts before optional server installation.",
    )
    parser.add_argument(
        "--server-root",
        type=Path,
        default=None,
        help=(
            "Optional BeamMP server root. When supplied, the finished CareerMP.zip "
            "and RLS compatibility zip are copied to Resources/Client automatically."
        ),
    )
    parser.add_argument(
        "--rls-install-name",
        default=None,
        help=(
            "Optional filename to use for the installed RLS zip in Resources/Client. "
            "Useful for overwriting an existing server resource name."
        ),
    )
    add_zip_engine_argument(parser)
    args = parser.parse_args()

    rls_original = args.rls_original.expanduser().resolve()
    careermp_original = args.careermp_039.expanduser().resolve()
    out_dir = args.out_dir.expanduser().resolve()
    server_root = args.server_root.expanduser().resolve() if args.server_root else None

    if not rls_original.is_file():
        raise SystemExit(f"RLS original zip not found: {rls_original}")
    if not careermp_original.is_file():
        raise SystemExit(f"CareerMP 0.39 zip not found: {careermp_original}")

    validate_careermp_039(careermp_original)

    out_dir.mkdir(parents=True, exist_ok=True)

    rls_patch_dir = repo_root / "patches" / "RLS"
    rls_out = out_dir / f"{rls_original.stem}_careermp039_compatible.zip"
    careermp_out = out_dir / "CareerMP.zip"

    rls_size, rls_hash = build_mod(
        rls_original,
        rls_patch_dir,
        rls_out,
        RLS_REMOVE_PREFIXES,
        args.zip_engine,
        apply_legacy_online_save_timing=False,
        apply_legacy_override_manager_patch=False,
    )

    # Keep CareerMP-0.39's architecture intact, but apply narrow 0.39.4 fixes
    # required by the RLS integration.
    careermp_entries = read_careermp_entries(careermp_original)
    patch_careermp_039(careermp_entries)
    install_careermp_watchdog(careermp_entries)
    write_zip(careermp_out, careermp_entries, engine=args.zip_engine)
    cmp_size = careermp_out.stat().st_size
    cmp_hash = sha256sum(careermp_out)

    checksums = out_dir / "checksums.txt"
    checksums.write_text(
        "\n".join(
            [
                f"{rls_hash}  {rls_out.name}",
                f"{cmp_hash}  {careermp_out.name}",
                "",
                f"{rls_out.name} size={rls_size}",
                f"{careermp_out.name} size={cmp_size}",
                "CareerMP-0.39 patched: profile return preservation + traceback diagnostics",
                f"zip_engine={describe_zip_engine(args.zip_engine)}",
            ]
        ),
        encoding="utf-8",
    )

    print(f"Built: {rls_out}")
    print(f"Built patched CareerMP: {careermp_out}")
    print(f"Wrote: {checksums}")

    if server_root:
        resources_client = server_root / "Resources" / "Client"
        resources_client.mkdir(parents=True, exist_ok=True)

        install_name = args.rls_install_name or rls_out.name
        installed_rls = resources_client / install_name
        installed_careermp = resources_client / "CareerMP.zip"

        shutil.copy2(rls_out, installed_rls)
        shutil.copy2(careermp_out, installed_careermp)

        installed_rls_hash = sha256sum(installed_rls)
        installed_cmp_hash = sha256sum(installed_careermp)

        if installed_rls_hash != rls_hash:
            raise SystemExit(
                "RLS install verification failed: installed hash does not match built zip"
            )
        if installed_cmp_hash != cmp_hash:
            raise SystemExit(
                "CareerMP install verification failed: installed hash does not match source zip"
            )

        print("")
        print("Installed to BeamMP server:")
        print(f"  {installed_rls}")
        print(f"  {installed_careermp}")
        print("")
        print(f"Verified RLS SHA256:      {installed_rls_hash}")
        print(f"Verified CareerMP SHA256: {installed_cmp_hash}")
        print("")
        print("NOTE: remove any older/original RLS career overhaul zip from Resources/Client")
        print("      so only the generated *_careermp039_compatible.zip is active.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
