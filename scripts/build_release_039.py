from __future__ import annotations

import argparse
import json
import re
import shutil
from pathlib import Path

from build_release import (
    RLS_REMOVE_PREFIXES,
    build_mod,
    read_careermp_entries,
    read_zip_entries,
    sha256sum,
    overlay_directory,
    remove_entry_prefixes,
)
from rls_272_startup import patch_rls_272_startup, MODSCRIPT as RLS272_MODSCRIPT, MANAGER as RLS272_MANAGER
from rls_272_garage_insurance import verify_rls_272_garage_insurance
from rls_272_gameplay import patch_rls_272_gameplay
from zip_utils import add_zip_engine_argument, describe_zip_engine, write_zip


# RLS 2.7.2 uses a deliberately empty, version-specific overlay while its
# old whole-file replacements are being rebased. Never use patches/RLS here.
RLS272_PATCH_DIR = "RLS-2.7.2"


def stage_rls_272_entries(source: Path, patch_dir: Path, output_name: str) -> dict[str, bytes]:
    """Prepare an inspectable 2.7.2 build in memory; do not publish it yet."""
    entries = read_zip_entries(source)
    remove_entry_prefixes(entries, RLS_REMOVE_PREFIXES)
    overlay_directory(entries, patch_dir)
    patch_rls_272_startup(entries)
    patch_rls_272_gameplay(entries)
    # Register 2.7.2 phone pages in the shipped Vue mod entrypoint. Unlike
    # modifications to ui-vue/src/modules/career/routes.js, this entrypoint
    # runs with the compiled 0.39 UI and can add routes dynamically.
    if not patch_rls_vue_phone_routes_039(entries):
        raise RuntimeError("RLS 2.7.2 phone routes were not installed in staging")
    # Do NOT run patch_rls_entries() yet: that routine contains mandatory
    # assertions and whole-file rewrites developed for RLS 2.6.7. Its 2.7.2
    # migration will be reviewed separately, including info.json metadata.
    # Verify the 2.7.2 save contract and the isolated bridge. RLS 2.7.2
    # already exposes the 0.39 profile API; do not rewrite its save system.
    bridge_path = "lua/ge/extensions/overhaul/careermp39Compat.lua"
    save_path = "lua/ge/extensions/overrides/career/saveSystem.lua"
    if bridge_path not in entries or save_path not in entries:
        raise RuntimeError("RLS 2.7.2 profile bridge or native save-system override missing")
    save_source = entries[save_path].decode("utf-8")
    bridge_source = entries[bridge_path].decode("utf-8")
    for required in ("M.getCurrentProfile = getCurrentProfile",
                     "M.getCurrentSaveSlot = getCurrentProfile"):
        if required not in save_source:
            raise RuntimeError("RLS 2.7.2 save-system contract changed: " + required)
    if 'return currentProfile, currentSavePath' not in save_source:
        raise RuntimeError("RLS 2.7.2 save system no longer returns profile/path pair")
    if 'function M.getCurrentProfile()' not in bridge_source:
        raise RuntimeError("RLS 2.7.2 profile bridge missing getCurrentProfile")
    for module in ("lua/ge/extensions/career/modules/credit.lua",
                   "lua/ge/extensions/career/modules/propertyOwners.lua"):
        if module not in entries:
            raise RuntimeError("RLS 2.7.2 profile-dependent module missing: " + module)
    # The multiplayer entry must delegate to RLS 2.7.2's existing career
    # implementation; never overwrite the full career.lua implementation.
    career_entry = "lua/ge/extensions/overrides/career/careerMP.lua"
    career_original = "lua/ge/extensions/overrides/career/career.lua"
    inventory_original = "lua/ge/extensions/overrides/career/modules/inventory.lua"
    inventory_bridge = "lua/ge/extensions/overrides/career/modules/careermpCompat.lua"
    for required in (career_entry, career_original, inventory_original, inventory_bridge):
        if required not in entries:
            raise RuntimeError("RLS 2.7.2 career/inventory staging file missing: " + required)
    entry_source = entries[career_entry].decode("utf-8")
    if "require('lua.ge.extensions.overrides.career.career')" not in entry_source:
        raise RuntimeError("RLS 2.7.2 CareerMP entry no longer delegates to RLS career")
    inventory_source = entries[inventory_original].decode("utf-8")
    for required in ("M.spawnVehicle = spawnVehicle",
                     "M.getVehicleIdFromInventoryId = getVehicleIdFromInventoryId",
                     "M.getInventoryIdFromVehicleId = getInventoryIdFromVehicleId"):
        if required not in inventory_source:
            raise RuntimeError("RLS 2.7.2 inventory contract changed: " + required)
    inventory_bridge_source = entries[inventory_bridge].decode("utf-8")
    if "function M.install()" not in inventory_bridge_source:
        raise RuntimeError("RLS 2.7.2 inventory compatibility install hook missing")
    verify_rls_272_garage_insurance(entries)
    # Do not let a legacy overlay regress the updated RLS startup files.
    manager = entries[RLS272_MANAGER].decode("utf-8")
    script = entries[RLS272_MODSCRIPT].decode("utf-8")
    if "ensureInputActionsRegistered()" not in manager:
        raise RuntimeError("RLS 2.7.2 input registration was lost")
    if "-- RLSCareerMP39 2.7.2 startup gate v1" not in script:
        raise RuntimeError("RLS 2.7.2 startup gate was lost")
    return entries


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

        # V3: Some BeamMP/0.39 sessions restore/select the correct profile after
        # the map loads without ever delivering worldReadyState=2 or rxCareerSync
        # to CareerMP. In that state the save API has a valid profile/path but
        # career_career remains inactive. Detect that stable state and start the
        # current profile directly, still wrapped in remote-vehicle protection.
        direct_start_marker = "CareerMP 0.39 direct profile-start fallback v3"
        if direct_start_marker not in enabler_text:
            state_anchor_v3 = """local syncFallbackLevel = nil
"""
            state_replacement_v3 = """local syncFallbackLevel = nil

-- CareerMP 0.39 direct profile-start fallback v3
local directStartProfileKey = nil
local directStartElapsed = 0
local directStartDelay = 5
local directStartAttempted = false
"""
            if state_anchor_v3 not in enabler_text:
                raise RuntimeError(
                    "Unable to install CareerMP direct-start fallback state; "
                    "stable-level fallback state layout changed"
                )
            enabler_text = enabler_text.replace(
                state_anchor_v3, state_replacement_v3, 1
            )

            update_anchor_v3 = """local function onUpdate(dtReal, dtSim, dtRaw)
"""
            helper_v3 = """local function tryDirectCareerStart(dtReal)
	if careerMPActive or directStartAttempted then return end
	if not (MPCoreNetwork and MPCoreNetwork.isMPSession and MPCoreNetwork.isMPSession()) then
		directStartProfileKey = nil
		directStartElapsed = 0
		return
	end

	local mission = ""
	if type(getMissionFilename) == "function" then
		mission = tostring(getMissionFilename() or "")
	end
	if mission == "" then
		directStartProfileKey = nil
		directStartElapsed = 0
		return
	end

	local saveSystem = extensions and extensions["career_saveSystem"] or career_saveSystem
	if not (saveSystem and saveSystem.getCurrentProfile) then return end

	local okProfile, profileName, profilePath = pcall(saveSystem.getCurrentProfile)
	if not okProfile then
		return
	end
	profileName = tostring(profileName or "")
	profilePath = tostring(profilePath or "")
	if profileName == "" or profilePath == "" then
		directStartProfileKey = nil
		directStartElapsed = 0
		return
	end

	local career = extensions and extensions["career_career"] or career_career
	local alreadyActive = false
	if career and career.isActive then
		local okActive, active = pcall(career.isActive)
		alreadyActive = okActive and active == true
	end
	if alreadyActive then
		careerMPActive = true
		directStartAttempted = true
		log("I", logTag, "CareerMP direct-start fallback found career already active for profile '" .. profileName .. "'")
		return
	end

	local profileKey = profileName .. "|" .. profilePath .. "|" .. mission
	if directStartProfileKey ~= profileKey then
		directStartProfileKey = profileKey
		directStartElapsed = 0
		log("I", logTag, "CareerMP direct-start candidate: profile='" .. profileName ..
			"' path='" .. profilePath .. "' mission='" .. mission .. "'")
		return
	end

	directStartElapsed = directStartElapsed + (dtReal or 0)
	if directStartElapsed < directStartDelay then return end

	local careerPatches = extensions and extensions["careerMP_careerPatches"]
	if not (careerPatches and careerPatches.ensure and careerPatches.ensure()) then
		log("W", logTag, "CareerMP direct-start waiting: career protection patches not ready")
		directStartElapsed = 0
		return
	end

	directStartAttempted = true
	log("W", logTag, "CareerMP sync callbacks absent; directly starting current profile '" ..
		profileName .. "' after " .. tostring(directStartDelay) .. "s stable")

	local started = careerPatches.withRemoteVehiclesProtected(function()
		return compat.createOrLoadCareerAndStart(profileName, false, compat.defaultStartMode)
	end)

	if started then
		careerMPActive = true
		log("I", logTag, "CareerMP direct-start fallback succeeded for profile '" .. profileName .. "'")
	else
		log("E", logTag, "CareerMP direct-start fallback failed for profile '" .. profileName .. "'")
	end
end

local function onUpdate(dtReal, dtSim, dtRaw)
	tryDirectCareerStart(dtReal)
"""
            if update_anchor_v3 not in enabler_text:
                raise RuntimeError(
                    "Unable to install CareerMP direct-start fallback; onUpdate missing"
                )
            enabler_text = enabler_text.replace(
                update_anchor_v3, helper_v3, 1
            )

            leave_anchor_v3 = """	syncFallbackLevel = nil
end
"""
            leave_replacement_v3 = """	syncFallbackLevel = nil
	directStartProfileKey = nil
	directStartElapsed = 0
	directStartAttempted = false
end
"""
            if leave_anchor_v3 in enabler_text:
                enabler_text = enabler_text.replace(
                    leave_anchor_v3, leave_replacement_v3, 1
                )

            print("  - CareerMP 0.39 direct profile-start fallback v3 installed")

        if direct_start_marker not in enabler_text:
            raise RuntimeError(
                "CareerMP direct profile-start fallback v3 marker missing after patch"
            )

        # V4: BeamMP 0.39 reliably calls MPCoreNetwork.loadLevel with the server
        # map path even when CareerMP never receives worldReadyState=2 or
        # onClientPostStartMission. Observe that call and request the real server
        # config after the map has had time to settle. This keeps profile naming
        # authoritative (serverSaveName/serverSaveSuffix) and returns to the
        # normal rxCareerSync start path instead of guessing locally.
        loadlevel_marker = "CareerMP 0.39 BeamMP loadLevel sync fallback v4"
        if loadlevel_marker not in enabler_text:
            state_anchor_v4 = """local directStartAttempted = false
"""
            state_replacement_v4 = """local directStartAttempted = false

-- CareerMP 0.39 BeamMP loadLevel sync fallback v4
local beamMPLevelLoadSeen = false
local beamMPLevelLoadPath = nil
local beamMPLevelLoadElapsed = 0
local beamMPLevelLoadSyncDelay = 10
local beamMPLevelLoadWrapped = false
"""
            if state_anchor_v4 not in enabler_text:
                raise RuntimeError(
                    "Unable to install BeamMP loadLevel fallback state; "
                    "direct-start state layout changed"
                )
            enabler_text = enabler_text.replace(
                state_anchor_v4, state_replacement_v4, 1
            )

            update_anchor_v4 = """local function onUpdate(dtReal, dtSim, dtRaw)
	tryDirectCareerStart(dtReal)
"""
            update_replacement_v4 = """local function onUpdate(dtReal, dtSim, dtRaw)
	-- BeamMP's own map-load call is the most reliable 0.39 join milestone.
	if not beamMPLevelLoadWrapped and MPCoreNetwork and type(MPCoreNetwork.loadLevel) == "function" then
		local originalLoadLevel = MPCoreNetwork.loadLevel
		MPCoreNetwork.loadLevel = function(levelPath, ...)
			beamMPLevelLoadSeen = true
			beamMPLevelLoadPath = tostring(levelPath or "")
			beamMPLevelLoadElapsed = 0
			log("I", logTag, "CareerMP observed BeamMP loadLevel: " .. beamMPLevelLoadPath)
			return originalLoadLevel(levelPath, ...)
		end
		beamMPLevelLoadWrapped = true
		log("I", logTag, "CareerMP installed BeamMP loadLevel sync fallback")
	end

	if beamMPLevelLoadSeen and not syncRequested then
		beamMPLevelLoadElapsed = beamMPLevelLoadElapsed + (dtReal or 0)
		if beamMPLevelLoadElapsed >= beamMPLevelLoadSyncDelay then
			if requestCareerSync("BeamMP loadLevel fallback after " .. tostring(beamMPLevelLoadSyncDelay) .. "s") then
				log("W", logTag, "CareerMP sync requested from BeamMP loadLevel fallback for " .. tostring(beamMPLevelLoadPath))
			end
		end
	end

	tryDirectCareerStart(dtReal)
"""
            if update_anchor_v4 not in enabler_text:
                raise RuntimeError(
                    "Unable to install BeamMP loadLevel fallback; onUpdate layout changed"
                )
            enabler_text = enabler_text.replace(
                update_anchor_v4, update_replacement_v4, 1
            )

            leave_anchor_v4 = """	directStartAttempted = false
end
"""
            leave_replacement_v4 = """	directStartAttempted = false
	beamMPLevelLoadSeen = false
	beamMPLevelLoadPath = nil
	beamMPLevelLoadElapsed = 0
end
"""
            if leave_anchor_v4 in enabler_text:
                enabler_text = enabler_text.replace(
                    leave_anchor_v4, leave_replacement_v4, 1
                )

            print("  - CareerMP 0.39 BeamMP loadLevel sync fallback v4 installed")

        if loadlevel_marker not in enabler_text:
            raise RuntimeError(
                "CareerMP BeamMP loadLevel sync fallback v4 marker missing after patch"
            )

        # V5: Queue profile activation from rxCareerSync and retry until BeamNG
        # actually reports career_career.isActive(). Do not trust the return
        # value of createOrLoadCareerAndStart(): BeamNG may complete activation
        # without returning a truthy value.
        activation_marker = "CareerMP 0.39 queued career activation retry v5"
        if activation_marker not in enabler_text:
            state_anchor_v5 = """local beamMPLevelLoadWrapped = false
"""
            state_replacement_v5 = """local beamMPLevelLoadWrapped = false

-- CareerMP 0.39 queued career activation retry v5
local pendingCareerStart = false
local pendingCareerProfile = nil
local pendingCareerStartElapsed = 0
local pendingCareerRetryDelay = 5
local pendingCareerAttempt = 0
local pendingCareerMaxAttempts = 12
local careerStartInProgress = false
"""
            if state_anchor_v5 not in enabler_text:
                raise RuntimeError(
                    "Unable to install queued career activation state; "
                    "BeamMP loadLevel fallback state layout changed"
                )
            enabler_text = enabler_text.replace(
                state_anchor_v5, state_replacement_v5, 1
            )

            rx_pattern = re.compile(
                r"local function rxCareerSync\(data\)\n.*?\nend\n\nlocal function rxClientConfigUpdate",
                re.DOTALL,
            )
            rx_match = rx_pattern.search(enabler_text)
            if not rx_match:
                raise RuntimeError(
                    "Unable to replace rxCareerSync with queued activation; "
                    "careerMPEnabler.lua source layout changed"
                )

            rx_replacement = r'''local function queueCareerStart(profileName, reason)
	if careerMPActive then return end
	pendingCareerProfile = profileName
	pendingCareerStart = true
	pendingCareerStartElapsed = 0
	pendingCareerAttempt = 0
	log("I", logTag, "queued career profile '" .. tostring(profileName) ..
		"' for activation (" .. tostring(reason) .. ")")
end

local function rxCareerSync(data)
	clientConfig = jsonDecode(data)
	if not clientConfig then
		log("E", logTag, "rxCareerSync: could not decode client config")
		return
	end

	nickname = MPConfig.getNickname()
	settingsCheck()
	actionsCheck()

	local profileName = resolveProfileName()
	log("I", logTag, string.format(
		"received CareerMP server config; profile='%s' nickname='%s' startMode='%s'",
		profileName, tostring(nickname), compat.defaultStartMode))

	if careerMPActive then return end
	queueCareerStart(profileName, "rxCareerSync")
end

local function rxClientConfigUpdate'''
            enabler_text = rx_pattern.sub(rx_replacement, enabler_text, count=1)

            update_anchor_v5 = """local function onUpdate(dtReal, dtSim, dtRaw)
	-- BeamMP's own map-load call is the most reliable 0.39 join milestone.
"""
            update_replacement_v5 = """local function isCareerActuallyActive()
	local career = extensions and extensions["career_career"] or career_career
	if not (career and type(career.isActive) == "function") then
		return false
	end
	local ok, active = pcall(career.isActive)
	return ok and active == true
end

local function processPendingCareerStart(dtReal)
	if careerMPActive then
		pendingCareerStart = false
		return
	end

	if isCareerActuallyActive() then
		careerMPActive = true
		pendingCareerStart = false
		careerStartInProgress = false
		log("I", logTag, "career activation confirmed active" ..
			(pendingCareerProfile and (" for profile '" .. pendingCareerProfile .. "'") or ""))
		return
	end

	if not pendingCareerStart or not pendingCareerProfile then return end
	pendingCareerStartElapsed = pendingCareerStartElapsed + (dtReal or 0)
	if pendingCareerStartElapsed < pendingCareerRetryDelay then return end
	pendingCareerStartElapsed = 0

	if pendingCareerAttempt >= pendingCareerMaxAttempts then
		log("E", logTag, "career activation retry limit reached for profile '" ..
			tostring(pendingCareerProfile) .. "'")
		pendingCareerStart = false
		return
	end

	local careerPatches = extensions and extensions["careerMP_careerPatches"]
	if not (careerPatches and careerPatches.ensure and careerPatches.ensure()) then
		log("W", logTag, "career activation retry waiting: protection patches not ready")
		return
	end

	pendingCareerAttempt = pendingCareerAttempt + 1
	careerStartInProgress = true
	log("W", logTag, "career activation attempt " .. tostring(pendingCareerAttempt) ..
		"/" .. tostring(pendingCareerMaxAttempts) .. " for profile '" ..
		tostring(pendingCareerProfile) .. "'")

	local ok, resultOrErr = xpcall(function()
		return careerPatches.withRemoteVehiclesProtected(function()
			return compat.createOrLoadCareerAndStart(
				pendingCareerProfile,
				false,
				compat.defaultStartMode
			)
		end)
	end, debug.traceback)

	careerStartInProgress = false

	if not ok then
		log("E", logTag, "career activation attempt threw:\\n" .. tostring(resultOrErr))
		return
	end

	if isCareerActuallyActive() then
		careerMPActive = true
		pendingCareerStart = false
		log("I", logTag, "career activation confirmed immediately for profile '" ..
			tostring(pendingCareerProfile) .. "'")
	else
		log("W", logTag, "career start call returned '" .. tostring(resultOrErr) ..
			"' but career is still inactive; will retry")
	end
end

local function onUpdate(dtReal, dtSim, dtRaw)
	processPendingCareerStart(dtReal)

	-- BeamMP's own map-load call is the most reliable 0.39 join milestone.
"""
            if update_anchor_v5 not in enabler_text:
                raise RuntimeError(
                    "Unable to install queued career activation processor; "
                    "onUpdate BeamMP fallback layout changed"
                )
            enabler_text = enabler_text.replace(
                update_anchor_v5, update_replacement_v5, 1
            )

            old_oncareer = """local function onCareerActive(active)
	if not (active and careerMPActive) then return end
"""
            new_oncareer = """local function onCareerActive(active)
	if not active then return end
	if careerStartInProgress or pendingCareerStart then
		careerMPActive = true
		pendingCareerStart = false
		careerStartInProgress = false
		log("I", logTag, "onCareerActive confirmed CareerMP activation")
	end
	if not careerMPActive then return end
"""
            if old_oncareer not in enabler_text:
                raise RuntimeError(
                    "Unable to update onCareerActive for queued activation"
                )
            enabler_text = enabler_text.replace(
                old_oncareer, new_oncareer, 1
            )

            leave_anchor_v5 = """	beamMPLevelLoadElapsed = 0
end
"""
            leave_replacement_v5 = """	beamMPLevelLoadElapsed = 0
	pendingCareerStart = false
	pendingCareerProfile = nil
	pendingCareerStartElapsed = 0
	pendingCareerAttempt = 0
	careerStartInProgress = false
end
"""
            if leave_anchor_v5 in enabler_text:
                enabler_text = enabler_text.replace(
                    leave_anchor_v5, leave_replacement_v5, 1
                )

            print("  - CareerMP 0.39 queued career activation retry v5 installed")

        if activation_marker not in enabler_text:
            raise RuntimeError(
                "CareerMP queued career activation retry v5 marker missing after patch"
            )

        # V6: BeamMP 0.39 does not reliably drive careerMPEnabler.onUpdate during
        # the join sequence. Start a jobsystem worker from onExtensionLoaded so
        # sync and queued career activation no longer depend on world/update hooks.
        jobsystem_marker = "CareerMP 0.39 jobsystem handshake fallback v6"
        if jobsystem_marker not in enabler_text:
            extension_anchor_v6 = """\tAddEventHandler("rxTrafficSignalTimer", rxTrafficSignalTimer)

\tlog("I", logTag, "CareerMP Enabler LOADED (target BeamNG " .. compat.targetGameVersion .. ")")
end
"""
            extension_replacement_v6 = """\tAddEventHandler("rxTrafficSignalTimer", rxTrafficSignalTimer)

\t-- CareerMP 0.39 jobsystem handshake fallback v6
\tif core_jobsystem and type(core_jobsystem.create) == "function" then
\t\tcore_jobsystem.create(function(job)
\t\t\tlog("I", logTag, "CareerMP jobsystem handshake worker started")
\t\t\tfor workerAttempt = 1, 36 do
\t\t\t\tif careerMPActive then
\t\t\t\t\tlog("I", logTag, "CareerMP jobsystem worker exiting: career active")
\t\t\t\t\treturn
\t\t\t\tend

\t\t\t\tjob.sleep(5)

\t\t\t\tlocal inMPSession = MPCoreNetwork and MPCoreNetwork.isMPSession and MPCoreNetwork.isMPSession()
\t\t\t\tif inMPSession then
\t\t\t\t\tif not clientConfig then
\t\t\t\t\t\tlog("W", logTag, "CareerMP jobsystem requesting server sync attempt " .. tostring(workerAttempt))
\t\t\t\t\t\tTriggerServerEvent("prefabSyncRequested", "")
\t\t\t\t\t\tTriggerServerEvent("careerSyncRequested", "")
\t\t\t\t\t\tsyncRequested = true
\t\t\t\t\telseif pendingCareerStart then
\t\t\t\t\t\tprocessPendingCareerStart(5.1)
\t\t\t\t\telseif isCareerActuallyActive() then
\t\t\t\t\t\tcareerMPActive = true
\t\t\t\t\t\tlog("I", logTag, "CareerMP jobsystem observed active career")
\t\t\t\t\t\treturn
\t\t\t\t\tend
\t\t\t\tend
\t\t\tend

\t\t\tlog("E", logTag, "CareerMP jobsystem worker exhausted without activating career")
\t\tend)
\telse
\t\tlog("E", logTag, "core_jobsystem unavailable; CareerMP jobsystem fallback not started")
\tend

\tlog("I", logTag, "CareerMP Enabler LOADED (target BeamNG " .. compat.targetGameVersion .. ")")
end
"""
            if extension_anchor_v6 not in enabler_text:
                raise RuntimeError(
                    "Unable to install CareerMP jobsystem handshake fallback; "
                    "onExtensionLoaded layout changed"
                )
            enabler_text = enabler_text.replace(
                extension_anchor_v6, extension_replacement_v6, 1
            )
            print("  - CareerMP 0.39 jobsystem handshake fallback v6 installed")

        if jobsystem_marker not in enabler_text:
            raise RuntimeError(
                "CareerMP jobsystem handshake fallback v6 marker missing after patch"
            )

        # V7: avoid replacing BeamMP's initial 'play' navigation while the 0.39
        # UI router is still completing its first handoff. The first career
        # activation attempt waits through an extra jobsystem cycle (~10s from
        # queueing); normal retries remain at 5s.
        activation_settle_marker = "CareerMP 0.39 first activation settle v7"
        if activation_settle_marker not in enabler_text:
            state_anchor_v7 = """local pendingCareerRetryDelay = 5
local pendingCareerAttempt = 0
"""
            state_replacement_v7 = """local pendingCareerRetryDelay = 5
-- CareerMP 0.39 first activation settle v7
local pendingCareerInitialDelay = 10
local pendingCareerAttempt = 0
"""
            if state_anchor_v7 not in enabler_text:
                raise RuntimeError(
                    "Unable to install first activation settle state; "
                    "V5 pending career state layout changed"
                )
            enabler_text = enabler_text.replace(
                state_anchor_v7, state_replacement_v7, 1
            )

            delay_anchor_v7 = """	pendingCareerStartElapsed = pendingCareerStartElapsed + (dtReal or 0)
	if pendingCareerStartElapsed < pendingCareerRetryDelay then return end
	pendingCareerStartElapsed = 0
"""
            delay_replacement_v7 = """	pendingCareerStartElapsed = pendingCareerStartElapsed + (dtReal or 0)
	local requiredDelay =
		(pendingCareerAttempt == 0) and pendingCareerInitialDelay or pendingCareerRetryDelay
	if pendingCareerStartElapsed < requiredDelay then return end
	pendingCareerStartElapsed = 0
	if pendingCareerAttempt == 0 then
		log("I", logTag, "CareerMP initial activation settle complete after " ..
			tostring(requiredDelay) .. "s")
	end
"""
            if delay_anchor_v7 not in enabler_text:
                raise RuntimeError(
                    "Unable to install first activation settle delay; "
                    "processPendingCareerStart layout changed"
                )
            enabler_text = enabler_text.replace(
                delay_anchor_v7, delay_replacement_v7, 1
            )

            print("  - CareerMP 0.39 first activation settle v7 installed")

        if activation_settle_marker not in enabler_text:
            raise RuntimeError(
                "CareerMP first activation settle v7 marker missing after patch"
            )

        # V8: patch BeamMP's exported world-ready callback at runtime instead of
        # relying on a modified BeamMP.zip. The launcher may replace BeamMP.zip
        # before startup, but CareerMP is server-distributed and can wrap the
        # live MPCoreNetwork extension after BeamMP has loaded.
        beammp_runtime_marker = "CareerMP 0.39 BeamMP world-ready runtime guard v8"
        if beammp_runtime_marker not in enabler_text:
            state_anchor_v8 = """local careerStartInProgress = false
"""
            state_replacement_v8 = """local careerStartInProgress = false

-- CareerMP 0.39 BeamMP world-ready runtime guard v8
local beamMPWorldReadyWrapper = nil
local beamMPWorldReadyOriginal = nil

local function ensureBeamMPWorldReadyGuard()
	local mp = MPCoreNetwork or (extensions and extensions["MPCoreNetwork"])
	if not (mp and type(mp.onWorldReadyState) == "function") then
		return false
	end

	if beamMPWorldReadyWrapper and mp.onWorldReadyState == beamMPWorldReadyWrapper then
		return true
	end

	beamMPWorldReadyOriginal = mp.onWorldReadyState
	beamMPWorldReadyWrapper = function(readyState, ...)
		local inMPSession = mp.isMPSession and mp.isMPSession()
		if readyState == 2 and inMPSession then
			log("I", logTag, "delegating world-ready transition to BeamMP")
		end
		return beamMPWorldReadyOriginal(readyState, ...)
	end

	mp.onWorldReadyState = beamMPWorldReadyWrapper
	log("I", logTag, "installed BeamMP world-ready runtime guard")
	return true
end
"""
            if state_anchor_v8 not in enabler_text:
                raise RuntimeError(
                    "Unable to install BeamMP world-ready runtime guard state; "
                    "V5 state layout changed"
                )
            enabler_text = enabler_text.replace(
                state_anchor_v8, state_replacement_v8, 1
            )

            worker_anchor_v8 = """			for workerAttempt = 1, 36 do
				if careerMPActive then
"""
            worker_replacement_v8 = """			for workerAttempt = 1, 36 do
				ensureBeamMPWorldReadyGuard()
				if careerMPActive then
"""
            if worker_anchor_v8 not in enabler_text:
                raise RuntimeError(
                    "Unable to wire BeamMP world-ready runtime guard into jobsystem worker"
                )
            enabler_text = enabler_text.replace(
                worker_anchor_v8, worker_replacement_v8, 1
            )

            extension_anchor_v8 = """	AddEventHandler("rxTrafficSignalTimer", rxTrafficSignalTimer)

	-- CareerMP 0.39 jobsystem handshake fallback v6
"""
            extension_replacement_v8 = """	AddEventHandler("rxTrafficSignalTimer", rxTrafficSignalTimer)

	ensureBeamMPWorldReadyGuard()

	-- CareerMP 0.39 jobsystem handshake fallback v6
"""
            if extension_anchor_v8 not in enabler_text:
                raise RuntimeError(
                    "Unable to install BeamMP world-ready runtime guard in onExtensionLoaded"
                )
            enabler_text = enabler_text.replace(
                extension_anchor_v8, extension_replacement_v8, 1
            )

            print("  - CareerMP 0.39 BeamMP world-ready runtime guard v8 installed")

        if beammp_runtime_marker not in enabler_text:
            raise RuntimeError(
                "CareerMP BeamMP world-ready runtime guard v8 marker missing after patch"
            )

        # V9: observe native Lua requests for the remaining 'play' handoff.
        # This is diagnostic only: do not change route ownership or timing.
        play_trace_marker = "CareerMP 0.39 native play-route trace v9"
        if play_trace_marker not in enabler_text:
            trace_anchor = "local function ensureBeamMPWorldReadyGuard()" + chr(10)
            trace_replacement = r'''-- CareerMP 0.39 native play-route trace v9
local function ensureNativePlayRouteTrace()
    local router = ui_router or (extensions and extensions["ui_router"])
    if type(router) ~= "table" or type(router.navigate) ~= "function" then
        return false
    end
    if router.__careerMP39PlayRouteTrace then return true end

    local originalNavigate = router.navigate
    router.navigate = function(route, ...)
        local routeName = type(route) == "table" and
            tostring(route.name or route.route or route.id) or tostring(route)
        if routeName == "play" then
            local active = career_career and career_career.isActive and career_career.isActive()
            log("I", logTag, "native Lua play route requested; worldReadyState=" ..
                tostring(worldReadyState) .. " careerActive=" .. tostring(active))
        end
        return originalNavigate(route, ...)
    end
    router.__careerMP39PlayRouteTrace = true
    log("I", logTag, "native Lua play-route trace installed")
    return true
end

local function ensureBeamMPWorldReadyGuard()
    ensureNativePlayRouteTrace()
'''
            if trace_anchor not in enabler_text:
                raise RuntimeError("Unable to install native play-route tracing; world-ready guard missing")
            enabler_text = enabler_text.replace(trace_anchor, trace_replacement, 1)
        if play_trace_marker not in enabler_text:
            raise RuntimeError("CareerMP play-route tracing marker missing after patch")

        # Repair CareerMP.zip files produced by the first V5 builder. Because
        # built-039/CareerMP.zip can be both the source and output, a subsequent
        # build may ingest an already-patched enabler containing the old literal
        # newline. Heal it before validation so rebuilds are idempotent.
        broken_traceback = 'career activation attempt threw:' + "\n" + '" .. tostring(resultOrErr)'
        expected_traceback = 'career activation attempt threw:\\n" .. tostring(resultOrErr)'
        if broken_traceback in enabler_text:
            enabler_text = enabler_text.replace(
                broken_traceback, expected_traceback
            )
            print("  - repaired legacy broken V5 traceback string in CareerMP enabler")

        # Guard against accidentally emitting a literal newline inside the Lua
        # quoted traceback message (which makes careerMPEnabler.lua unloadable).
        if broken_traceback in enabler_text:
            raise RuntimeError(
                "Generated careerMPEnabler.lua contains broken multiline Lua string"
            )
        if expected_traceback not in enabler_text:
            raise RuntimeError(
                "CareerMP V5 traceback log string verification failed"
            )

        # Repair previously patched CareerMP.zip inputs: V8 marker may exist
        # while the old suppressing wrapper is still embedded.
        old_suppression = (
            '\\t\\tif readyState == 2 and inMPSession then\\n'
            '\\t\\t\\tlog("D", logTag,\\n'
            '\\t\\t\\t\\t"suppressed redundant BeamMP world-ready play navigation")\\n'
            '\\t\\t\\treturn\\n'
            '\\t\\tend'
        )
        new_delegation = (
            '\\t\\tif readyState == 2 and inMPSession then\\n'
            '\\t\\t\\tlog("I", logTag, "delegating world-ready transition to BeamMP")\\n'
            '\\t\\tend'
        )
        # Legacy patch strings above are stored as escaped Lua text in the
        # Python builder. Decode them to actual tabs/newlines before matching.
        old_suppression = old_suppression.encode("utf-8").decode("unicode_escape")
        new_delegation = new_delegation.encode("utf-8").decode("unicode_escape")
        if old_suppression in enabler_text:
            enabler_text = enabler_text.replace(old_suppression, new_delegation, 1)
            print("  - repaired prepatched CareerMP world-ready suppression")
        if "suppressed redundant BeamMP world-ready play navigation" in enabler_text:
            raise RuntimeError("Stale CareerMP world-ready suppression remains")
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
    print("  - careerMPEnabler.lua can direct-start a stable selected profile after 5s")
    print("  - careerMPEnabler.lua observes BeamMP loadLevel and requests sync after 10s")
    print("  - careerMPEnabler.lua queues/retries career activation until isActive() is true")
    print("  - careerMPEnabler.lua starts a jobsystem handshake/activation worker")
    print("  - careerMPEnabler.lua delays the first activation attempt to avoid BeamMP play-route collision")
    print("  - careerMPEnabler.lua runtime-wraps BeamMP world-ready navigation so launcher rewrites cannot restore it")


def patch_beammp_039_ui(entries: dict[str, bytes]) -> None:
    """Patch BeamMP's Vue navigation for BeamNG 0.39's stricter UI router."""

    required_beammp_paths = (
        "scripts/BeamMP/modScript.lua",
        "ui/ui-vue/mods/BeamMP/index.js",
    )
    missing_beammp_paths = [
        name for name in required_beammp_paths if name not in entries
    ]
    if missing_beammp_paths:
        raise RuntimeError(
            "BeamMP input is not a complete client package; missing: "
            + ", ".join(missing_beammp_paths)
        )

    index_path = "ui/ui-vue/mods/BeamMP/index.js"
    index_payload = entries.get(index_path)
    if not index_payload:
        raise RuntimeError(
            f"BeamMP input missing {index_path}; unsupported BeamMP UI layout"
        )

    index_text = index_payload.decode("utf-8").replace("\r\n", "\n")

    # BeamNG 0.39 already resolves the world-ready gameplay state itself.
    # BeamMP's additional ui_router.navigate("play") races the native router and
    # consistently times out with route_change_not_accepted. Remove only that
    # redundant transition; pause-menu resume navigation remains untouched.
    core_network_path = "lua/ge/extensions/MPCoreNetwork.lua"
    core_network_payload = entries.get(core_network_path)
    if not core_network_payload:
        raise RuntimeError(
            f"BeamMP input missing {core_network_path}; unsupported BeamMP core layout"
        )

    core_network_text = core_network_payload.decode("utf-8").replace("\r\n", "\n")
    # Keep BeamMP responsible for its normal world-ready navigation.
    # Any prior suppressing callback is restored later in this function.
    # Do not first patch a pristine callback into a suppressed form.

    # A previous build may be used as input again. Remove only the exact
    # obsolete startup-timer injection, never leave it alongside new recovery.
    stale_marker = "CareerMP39 delayed BeamMP UI reload"
    if stale_marker in core_network_text:
        stale_decl = "local careerMP39ReloadDelay = nil -- CareerMP39 delayed BeamMP UI reload\n"
        stale_update = "\tif careerMP39ReloadDelay then\n\t\tcareerMP39ReloadDelay = careerMP39ReloadDelay - (dt or 0)\n\t\tif careerMP39ReloadDelay <= 0 then\n\t\t\tcareerMP39ReloadDelay = nil\n\t\t\tif not isMpSession and not isGoingMpSession then\n\t\t\t\tlog('I', 'CareerMP39', 'performing deferred BeamMP menu UI reload')\n\t\t\t\treloadUI()\n\t\t\telse\n\t\t\t\tlog('I', 'CareerMP39', 'skipped deferred menu reload during MP session')\n\t\t\tend\n\t\tend\n\tend\n"
        stale_start = "local function onExtensionLoaded()\n\tconnectToLauncher(true)\n\tcareerMP39ReloadDelay = 5.0\n\tlog('I', 'CareerMP39', 'deferred BeamMP menu UI reload by 5s')\nend"
        restored_start = "local function onExtensionLoaded()\n\tconnectToLauncher(true)\n\treloadUI() -- required to show modified mainmenu\nend"
        if not all(part in core_network_text for part in (stale_decl, stale_update, stale_start)):
            raise RuntimeError("Unexpected old BeamMP UI delay patch; rebuild with a pristine upstream BeamMP.zip")
        core_network_text = core_network_text.replace(stale_decl, "", 1)
        core_network_text = core_network_text.replace(stale_update, "", 1)
        core_network_text = core_network_text.replace(stale_start, restored_start, 1)
        print("  - removed obsolete BeamMP startup reload timer from reused ZIP")

    # Switch back to BeamMP owning the world-ready gameplay transition.
    # This also repairs ZIPs previously generated with our suppression patch.
    restored_world_ready = (
        'local function onWorldReadyState(readyState)\n'
        '\tif readyState == 2 and isMpSession and not isGoingMpSession and extensions.ui_router then\n'
        '\t\textensions.ui_router.navigate("play")\n'
        '\tend\nend\n'
    )
    if "BeamNG 0.39 native play-route ownership" in core_network_text:
        # Locate the Lua callback by its signature and the next top-level
        # 'end'.  A previous injection can put declarations before the
        # function, so do not expect the marker to be inside regex match.
        signature = "local function onWorldReadyState(readyState)"
        start = core_network_text.find(signature)
        if start < 0 or core_network_text.find(signature, start + 1) >= 0:
            raise RuntimeError("BeamMP world-ready callback not unique")
        # Match a top-level Lua 'end' even when followed by a comment, an
        # empty line, or EOF. Previous exact '\\nend\\n' matching failed on
        # reused client ZIPs with slightly different newline layouts.
        terminator = re.search(r"(?m)^end[ \\t]*(?:--[^\\n]*)?(?:\\n|$)", core_network_text[start:])
        if terminator is None:
            excerpt = core_network_text[start:start + 1100]
            raise RuntimeError(
                "BeamMP world-ready callback terminator missing; "
                "callback excerpt: " + repr(excerpt)
            )
        ending = start + terminator.end()
        callback = core_network_text[start:ending]
        if "BeamNG 0.39 native play-route ownership" not in callback:
            raise RuntimeError("Existing BeamMP callback differs from expected patched form")
        core_network_text = (
            core_network_text[:start]
            + restored_world_ready
            + core_network_text[ending:]
        )
        print("  - restored BeamMP world-ready play navigation")
    # Observational route tracing: record the precise native Lua request and
    # its result without changing ownership, delays, or gameplay behaviour.
    # Replace the callback as a whole, so reused ZIPs don't accumulate hooks.
    route_trace_marker = "CareerMP39 route trace v11"
    traced_callback = (
        'local function onWorldReadyState(readyState)\n'
        '\t-- CareerMP39 route trace v11\n'
        '\tlog("I", "CareerMP39Route", "world-ready state=" .. tostring(readyState)'
        ' .. " mp=" .. tostring(isMpSession) .. " goingMp=" .. tostring(isGoingMpSession)'
        ' .. " router=" .. tostring(extensions and extensions.ui_router))\n'
        '\tif readyState == 2 and isMpSession and not isGoingMpSession and extensions.ui_router then\n'
        '\t\tlog("I", "CareerMP39Route", "requesting play from BeamMP onWorldReadyState")\n'
        '\t\tlocal result = extensions.ui_router.navigate("play")\n'
        '\t\tlog("I", "CareerMP39Route", "play navigate returned " .. tostring(result))\n'
        '\tend\nend\n'
    )
    if route_trace_marker not in core_network_text:
        if restored_world_ready not in core_network_text:
            raise RuntimeError("Route trace cannot find original BeamMP callback")
        core_network_text = core_network_text.replace(
            restored_world_ready, traced_callback, 1
        )
        print("  - added observational BeamMP world-ready route trace")
    # Remove the one-shot post-join reload experiment from reused ZIPs.
    recovery_decl = ("local careerMP39JoinUIRecovery = nil -- CareerMP39 post-join UI recovery\n"
                     "local careerMP39JoinUIReloaded = false\n")
    core_network_text = core_network_text.replace(recovery_decl, "")
    recovery_arm = (
        "\t\tif not careerMP39JoinUIReloaded then\n"
        "\t\t\tcareerMP39JoinUIRecovery = 3.0\n"
        "\t\t\tcareerMP39JoinUIReloaded = true\n"
        "\t\t\tlog('I', 'CareerMP39', 'scheduled one-shot post-join UI reload')\n"
        "\t\tend"
    )
    core_network_text = core_network_text.replace(recovery_arm, "")
    recovery_tick = (
        "\tif careerMP39JoinUIRecovery then\n"
        "\t\tcareerMP39JoinUIRecovery = careerMP39JoinUIRecovery - (dt or 0)\n"
        "\t\tif careerMP39JoinUIRecovery <= 0 then\n"
        "\t\t\tcareerMP39JoinUIRecovery = nil\n"
        "\t\t\tif isMpSession and worldReadyState == 2 then\n"
        "\t\t\t\tlog('I', 'CareerMP39', 'performing one-shot post-join UI reload')\n"
        "\t\t\t\treloadUI()\n"
        "\t\t\telse\n"
        "\t\t\t\tlog('I', 'CareerMP39', 'skipped post-join UI reload: session not ready')\n"
        "\t\t\tend\n"
        "\t\tend\n"
        "\tend\n"
    )
    core_network_text = core_network_text.replace(recovery_tick, "")
    # On reused ZIPs, remove the complete timer by its outermost Lua 'end'.
    # Do not use \\s in an end-of-line regex: it also matches newlines and
    # can skip nested blocks, leaving a partial timer behind.
    timer_anchor = "\tif careerMP39JoinUIRecovery then\n"
    if timer_anchor in core_network_text:
        timer_start = core_network_text.index(timer_anchor)
        # Nested 'end' lines have two or more tabs; exactly one tab denotes
        # the injected outer conditional. Keep the following onUpdate code.
        timer_end_match = re.search(
            r"(?m)^\tend[ \t]*(?:\r?\n|$)",
            core_network_text[timer_start:],
        )
        if timer_end_match is None:
            raise RuntimeError("Cannot find outer end of post-join UI timer")
        timer_end = timer_start + timer_end_match.end()
        timer_body = core_network_text[timer_start:timer_end]
        if ("performing one-shot post-join UI reload" not in timer_body
                or "careerMP39JoinUIRecovery = nil" not in timer_body):
            raise RuntimeError("Unexpected post-join UI timer content; refusing to strip")
        core_network_text = core_network_text[:timer_start] + core_network_text[timer_end:]
        print("  - removed leftover post-join UI timer from onUpdate")
    core_network_text = re.sub(
        r"(?m)^local careerMP39JoinUIRecovery[^\n]*\n", "", core_network_text,
    )
    core_network_text = re.sub(
        r"(?m)^local careerMP39JoinUIReloaded[^\n]*\n", "", core_network_text,
    )
    if "careerMP39JoinUIRecovery" in core_network_text:
        pos = core_network_text.index("careerMP39JoinUIRecovery")
        raise RuntimeError(
            "Post-join recovery cleanup still incomplete near: "
            + repr(core_network_text[max(0, pos-180):pos+360])
        )
    # Fix output produced by the earlier faulty builder: the whole callback
    # was emitted as one Lua line containing literal \n and \t characters.
    # Only replace the known exact old callback; never interpret escapes
    # throughout unrelated Lua code.
    broken_world_ready = (
        r'local function onWorldReadyState(readyState)\n'
        r'\tif readyState == 2 and isMpSession and not isGoingMpSession and extensions.ui_router then\n'
        r'\t\textensions.ui_router.navigate("play")\n'
        r'\tend\nend\n'
    )
    if broken_world_ready in core_network_text:
        core_network_text = core_network_text.replace(
            broken_world_ready, restored_world_ready, 1
        )
        print("  - repaired escaped world-ready callback in reused BeamMP ZIP")
    # Guard against the historical builder bug that wrote literal \\n / \\t
    # escape characters into Lua source instead of line breaks and tabs.
    if "\\n" in core_network_text[core_network_text.index("local function onWorldReadyState(readyState)"):][:500]:
        raise RuntimeError("Generated MPCoreNetwork.lua contains literal backslash-n escapes in world-ready callback")
    entries[core_network_path] = core_network_text.encode("utf-8")

    route_marker = "BeamNG 0.39 direct child-route handoff"
    if route_marker not in index_text:
        old_action = "    action: BEAMMP_ROUTE_NAME,\n"
        new_action = (
            "    // BeamNG 0.39 direct child-route handoff: avoid asking the Lua "
            "router to hand off to a redirecting parent route.\n"
            "    action: BEAMMP_LAUNCHER_ROUTE_NAME,\n"
        )
        if old_action not in index_text:
            if "action: BEAMMP_LAUNCHER_ROUTE_NAME" not in index_text:
                raise RuntimeError(
                    "Unable to patch BeamMP main-menu route target; index.js layout changed"
                )
        else:
            index_text = index_text.replace(old_action, new_action, 1)
    # Diagnostic-only CEF visibility. The UI router lives in BeamNG's base
    # game, so this does not pretend to monkeypatch inaccessible Vue internals.
    # Install observers on the BeamMP Vue mod, without modifying navigation.
    cef_marker = "CareerMP CEF route diagnostics v10"
    if cef_marker not in index_text:
        index_text += r"""

// CareerMP CEF route diagnostics v10
// Console messages should be forwarded into BeamNG's CEF log where supported.
if (typeof window !== 'undefined' && !window.__careerMP39RouteDiagnostics) {
  window.__careerMP39RouteDiagnostics = true;
  const stamp = () => new Date().toISOString();
  const emit = (name, details) => {
    try { console.warn('[CareerMP route diag] ' + stamp() + ' ' + name, details); }
    catch (_) { /* diagnostic-only */ }
  };
  const snapshot = () => ({
    hash: window.location.hash,
    pathname: window.location.pathname,
    runtimeDone: window.bngRuntimeStats?.done,
    runtimePresent: !!window.bngRuntimeStats,
    uiState: window.bngVue?.state?.name ?? null
  });
  emit('installed', snapshot());
  window.addEventListener('hashchange', () => emit('hashchange', snapshot()));
  window.addEventListener('popstate', () => emit('popstate', snapshot()));
  window.addEventListener('error', e => emit('js-error', {
    message: e.message, source: e.filename, line: e.lineno, column: e.colno,
    stack: e.error?.stack
  }));
  window.addEventListener('unhandledrejection', e =>
    emit('unhandled-promise-rejection', String(e.reason?.stack ?? e.reason)));
  let last = '';
  let checks = 0;
  const timer = setInterval(() => {
    const state = snapshot();
    const signature = JSON.stringify(state);
    if (signature !== last || checks % 10 === 0) {
      emit('state', state);
      last = signature;
    }
    if (++checks >= 180) clearInterval(timer);
  }, 1000);
}
"""
        print("  - installed observational CEF diagnostics in BeamMP Vue mod (180s)")
    # Passive CEF/bootstrap and history handoff probe. This lives in the
    # BeamMP Vue entry point and is reinstalled on every fresh UI boot.
    # It never forces navigation or reloads the UI.
    cef_probe_marker = "CareerMP CEF bootstrap and handoff probe v11"
    if cef_probe_marker not in index_text:
        index_text += r"""

// CareerMP CEF bootstrap and handoff probe v11
if (typeof window !== 'undefined' && !window.__careerMP39BootProbeV11) {
  window.__careerMP39BootProbeV11 = true;
  (() => {
    const tag = '[CareerMP39BootProbe] ';
    const ts = () => new Date().toISOString();
    const emit = (event, data = {}) => {
      try { console.warn(tag + ts() + ' ' + event + ' ' + JSON.stringify(data)); }
      catch (e) { console.warn(tag + event + ' serialization failed'); }
    };
    const snapshot = () => {
      const runtime = window.bngRuntimeStats;
      const vue = window.bngVue;
      const perfNav = performance.getEntriesByType?.('navigation')?.[0];
      return {
        href: location.href,
        hash: location.hash,
        readyState: document.readyState,
        visibility: document.visibilityState,
        runtimePresent: !!runtime,
        runtimeDone: runtime?.done ?? null,
        runtimeType: typeof runtime,
        vuePresent: !!vue,
        vueState: vue?.state?.name ?? null,
        navigationType: perfNav?.type ?? null,
        navigationStart: perfNav?.startTime ?? null,
        timeSinceNavigationMs: Math.round(performance.now())
      };
    };
    emit('installed', snapshot());
    ['DOMContentLoaded', 'load', 'pageshow', 'pagehide', 'hashchange',
     'popstate', 'visibilitychange'].forEach(event => {
      window.addEventListener(event, () => emit(event, snapshot()));
    });
    ['pushState', 'replaceState'].forEach(method => {
      const original = history[method];
      if (typeof original !== 'function') return;
      history[method] = function(...args) {
        emit('history-' + method + '-before', {
          from: location.href, to: String(args[2] ?? ''), ...snapshot()
        });
        const result = original.apply(this, args);
        emit('history-' + method + '-after', snapshot());
        return result;
      };
    });
    let prev = '';
    let tick = 0;
    const interval = setInterval(() => {
      const state = snapshot();
      const signature = JSON.stringify({
        href: state.href, readyState: state.readyState,
        runtimePresent: state.runtimePresent, runtimeDone: state.runtimeDone,
        vuePresent: state.vuePresent, vueState: state.vueState,
        visibility: state.visibility
      });
      if (signature !== prev || tick % 15 === 0) {
        emit('heartbeat', state);
        prev = signature;
      }
      tick += 1;
      if (tick >= 600) clearInterval(interval);
    }, 1000);
  })();
}
"""
        print("  - installed passive CEF bootstrap/history probe (v11)")
    # Earliest safe CEF hook: only inject into a *real* HTML entrypoint.
    # Do not fabricate a replacement BeamNG HTML page or alter its boot order.
    early_boot_marker = "CareerMP39 early HTML bootstrap probe v12"
    early_boot_script = r"""
<script>
// CareerMP39 early HTML bootstrap probe v12
(function () {
  if (window.__careerMP39EarlyBootV12) return;
  window.__careerMP39EarlyBootV12 = true;
  var name = '[CareerMP39EarlyBoot] ';
  function snap(event) {
    var r = window.bngRuntimeStats;
    var value = {
      event: event,
      at: Date.now(),
      ms: Math.round(performance.now()),
      url: location.href,
      ready: document.readyState,
      runtimePresent: !!r,
      runtimeDone: r ? r.done : null,
      vuePresent: !!window.bngVue
    };
    try { console.warn(name + JSON.stringify(value)); } catch (_) {}
  }
  snap('script-enter');
  ['DOMContentLoaded', 'load', 'pageshow', 'pagehide', 'hashchange',
   'unhandledrejection', 'error'].forEach(function (evt) {
    window.addEventListener(evt, function (e) {
      snap(evt);
      if (evt === 'error') console.warn(name + String(e.message || e));
      if (evt === 'unhandledrejection') console.warn(name + String(e.reason));
    });
  });
  var count = 0;
  var timer = setInterval(function () {
    snap('bootstrap-tick');
    if (++count >= 180) clearInterval(timer);
  }, 1000);
})();
</script>
"""
    html_paths = [
        name for name in entries
        if name.lower() in ("ui/ui-vue/index.html", "ui/index.html")
    ]
    if html_paths:
        for html_path in html_paths:
            html_source = entries[html_path].decode("utf-8")
            if early_boot_marker not in html_source:
                if "<head" not in html_source.lower():
                    raise RuntimeError(f"Cannot identify HTML head in {html_path}")
                html_source, hits = re.subn(
                    r"(?i)(<head\b[^>]*>)",
                    lambda m: m.group(1) + "\n" + early_boot_script,
                    html_source, count=1,
                )
                if hits != 1:
                    raise RuntimeError(f"Cannot instrument CEF head in {html_path}")
                entries[html_path] = html_source.encode("utf-8")
                print(f"  - installed early CEF bootstrap probe into {html_path}")
    else:
        print("  - early CEF HTML entrypoint not in BeamMP ZIP; native lifecycle trace remains available")

    # The BeamMP client is mounted before key bindings are parsed; the RLS
    # server-delivered ZIP is not. Ship the original RLS action with the
    # launcher-side client package so saved openPhone bindings resolve early.
    phone_action_path = "lua/ge/extensions/core/input/actions/phone.json"
    if phone_action_path not in entries:
        entries[phone_action_path] = json.dumps({
            "openPhone": {
                "cat": "gameplay",
                "order": 257,
                "ctx": "tlua",
                "onDown": "if not gameplay_phone then extensions.load('gameplay_phone') end if gameplay_phone then gameplay_phone.togglePhone() end",
                "title": "Toggle Phone",
                "desc": "Toggle Phone",
            }
        }, indent=2).encode("utf-8")
        print("  - installed early RLS openPhone input action in BeamMP client")
    else:
        print("  - openPhone action already present in BeamMP client")

    # CEF logs stringify objects as [object Object] when passed separately.
    # Keep the diagnostic useful in both successful and failed 0.39 handoffs.
    old_emit = "console.warn('[CareerMP route diag] ' + stamp() + ' ' + name, details);"
    new_emit = "console.warn('[CareerMP route diag] ' + stamp() + ' ' + name + ' ' + JSON.stringify(details));"
    if old_emit in index_text:
        index_text = index_text.replace(old_emit, new_emit)
    index_text = index_text.replace("if (++checks >= 180) clearInterval(timer);",
                                    "if (++checks >= 420) clearInterval(timer);")
    entries[index_path] = index_text.encode("utf-8")

    packaged_logo = "/ui/ui-vue/mods/BeamMP/icons/account-multiple.svg"
    logo_candidates = (
        "ui/ui-vue/mods/BeamMP/layouts/BeamMPMain.vue",
        "ui/ui-vue/mods/BeamMP/views/BeamMPLoginView.vue",
    )
    patched_logo_files: list[str] = []
    for ui_path in logo_candidates:
        payload = entries.get(ui_path)
        if not payload:
            continue
        text = payload.decode("utf-8").replace("\r\n", "\n")
        original = text
        text = text.replace(
            "/ui/assets/BeamMP/beammp_new_cropped.png",
            packaged_logo,
        )
        text = text.replace(
            "ui/assets/BeamMP/beammp_new_cropped.png",
            packaged_logo,
        )
        text = text.replace(
            "/ui/assets/BeamMP/icons/account-multiple.svg",
            packaged_logo,
        )
        if text != original:
            entries[ui_path] = text.encode("utf-8")
            patched_logo_files.append(ui_path)

    verify_index = entries[index_path].decode("utf-8", errors="replace")
    if "action: BEAMMP_LAUNCHER_ROUTE_NAME" not in verify_index:
        raise RuntimeError("BeamMP UI route patch verification failed")

    legacy_logo = "ui/assets/BeamMP/beammp_new_cropped.png"
    remaining = []
    for name, payload in entries.items():
        if not name.lower().endswith((".js", ".vue", ".html", ".css")):
            continue
        try:
            text = payload.decode("utf-8")
        except UnicodeDecodeError:
            continue
        if legacy_logo in text:
            remaining.append(name)

    if remaining:
        raise RuntimeError(
            "BeamMP legacy logo path remains after 0.39 UI patch: "
            + ", ".join(sorted(remaining))
        )

    print("Patched BeamMP for BeamNG 0.39 UI/core:")
    print("  - skips redundant BeamMP world-ready play navigation")
    print("  - main-menu action targets concrete menu.beammp.launcher child route")
    print("  - redirecting menu.beammp parent is no longer the initial Lua handoff target")
    if patched_logo_files:
        print("  - legacy BeamMP logo URL replaced with packaged Vue-mod icon:")
        for ui_path in patched_logo_files:
            print(f"    {ui_path}")
    else:
        print("  - BeamMP legacy logo URL already absent/patched")


def patch_rls_vue_phone_routes_039(entries: dict[str, bytes]) -> bool:
    """Expose 2.7+ RLS Vue phone routes through the BeamNG 0.39 mod entrypoint.

    0.39 loads the built-in Vue router, not modded /src/modules/career/routes.js.
    Keep the author's route names and views but register missing routes at runtime.
    """
    mod_entry = "ui/ui-vue/mods/rls_career_overhaul/index.js"
    source_routes = "ui/ui-vue/src/modules/career/routes.js"
    marker = "// CareerMP39 RLS phone route installer v1"
    if mod_entry not in entries or source_routes not in entries:
        print("  - RLS Vue phone route installer skipped: 2.7+ mod entry/source routes not found")
        return False

    script = entries[mod_entry].decode("utf-8")
    if marker in script:
        print("  - RLS Vue phone route installer already present")
        return False
    if 'import { getComponent } from "@/services/modManager"' not in script:
        raise RuntimeError("RLS mod entrypoint no longer exposes getComponent")
    anchor = "export async function onLoad() {"
    if script.count(anchor) != 1 or "async function waitForMainApp(" not in script:
        raise RuntimeError("Unexpected RLS Vue mod entrypoint; refusing phone route injection")

    routes_source = entries[source_routes].decode("utf-8")
    imports = dict(re.findall(
        r'import\s+(\w+)\s+from\s+"\./views/([^"]+)"', routes_source
    ))
    manifest = []
    for match in re.finditer(
        r'\{\s*path:\s*"([^"]+)"\s*,\s*name:\s*"([^"]+)"\s*,\s*component:\s*(\w+)',
        routes_source,
    ):
        route_path, route_name, component = match.groups()
        if not (route_name.startswith("phone-") or route_name == "car-meets-phone"):
            continue
        view_file = imports.get(component)
        if not view_file:
            raise RuntimeError(f"Unresolved RLS phone route component: {component}")
        source_path = "ui/ui-vue/src/modules/career/views/" + view_file
        if source_path not in entries:
            raise RuntimeError(f"Missing RLS phone route component: {source_path}")
        manifest.append({
            "path": route_path,
            "name": route_name,
            "file": "/" + source_path,
            "props": ":" in route_path,
        })

    if not any(route["name"] == "phone-main" for route in manifest):
        raise RuntimeError("RLS phone-main route missing from source routes")

    inject = r'''
// CareerMP39 RLS phone route installer v1
const phoneRouteManifest = __MANIFEST__

function createPhoneRouteComponent(file, name) {
  return window.Vue.defineAsyncComponent(async () => {
    let data = await getComponent(file, false, true)
    if (!data?.compiled && typeof data?.compile === "function") data = await data.compile()
    if (data?.error || !data?.component) {
      console.error("[CareerMP39Phone] Failed to compile " + name, data?.error, data?.errorObj)
      throw new Error("Missing RLS phone component: " + name)
    }
    return data.component
  })
}

async function registerRlsPhoneRoutes() {
  const ready = await waitForMainApp()
  if (!ready) {
    console.error("[CareerMP39Phone] Vue router not ready; phone routes not installed")
    return
  }
  const router = window.vueRouter
  if (typeof router.addRoute !== "function" || typeof router.hasRoute !== "function") {
    console.error("[CareerMP39Phone] Vue router has no dynamic route API")
    return
  }
  let added = 0
  for (const route of phoneRouteManifest) {
    if (router.hasRoute(route.name)) continue
    try {
      const routeRecord = {
        path: route.path,
        name: route.name,
        component: createPhoneRouteComponent(route.file, route.name),
        props: route.props,
      }
      // RLS defines phone pages as children of the career layout. Keeping
      // that nesting preserves its navigation shell and route context.
      if (router.hasRoute("career")) {
        router.addRoute("career", routeRecord)
      } else {
        console.warn("[CareerMP39Phone] career route missing; using absolute path for " + route.name)
        router.addRoute({ ...routeRecord, path: "/career/" + route.path })
      }
      added++
    } catch (err) {
      console.error("[CareerMP39Phone] Cannot register " + route.name, err)
    }
  }
  console.warn("[CareerMP39Phone] Registered " + added + " missing routes (" +
    phoneRouteManifest.length + " phone routes checked); phone-main=" + router.hasRoute("phone-main"))
}
'''
    inject = inject.replace("__MANIFEST__", json.dumps(manifest, separators=(",", ":")))
    script = script.replace(
        anchor, inject + "\n" + anchor.replace("{", "{\n  await registerRlsPhoneRoutes()"), 1
    )
    entries[mod_entry] = script.encode("utf-8")
    print(f"  - installed 0.39 Vue router registration for {len(manifest)} RLS phone routes")
    return True


def patch_rls_phone_039(archive: Path, zip_engine: str) -> tuple[int, str]:
    """Apply narrow BeamNG 0.39 RLS taxi API guards, preserving other logic."""
    entries = read_zip_entries(archive)
    legacy = "gameplay_taxi.isTaxiJobActive()"
    guarded = "(gameplay_taxi and type(gameplay_taxi.isTaxiJobActive) == 'function' and gameplay_taxi.isTaxiJobActive() or false)"
    changed = False
    for path in (
        "lua/ge/extensions/gameplay/phone.lua",
        "lua/ge/extensions/career/modules/rlsRentals.lua",
    ):
        payload = entries.get(path)
        if payload is None:
            print(f"WARNING: RLS compatibility source missing: {path}")
            continue
        source = payload.decode("utf-8")
        if legacy in source:
            source = source.replace(legacy, guarded)
            entries[path] = source.encode("utf-8")
            changed = True
            print(f"  - guarded removed taxi API in {path}")
        elif guarded in source:
            print(f"  - taxi guard already installed in {path}")
        else:
            print(f"WARNING: No expected taxi API call in {path}; inspect upstream")

    # On 0.39 career can run without the old linear tutorial extension.
    # Missing tutorial flags should not block opening the RLS computer menu.
    tutorial_path = "lua/ge/extensions/overrides/career/modules/computer.lua"
    payload = entries.get(tutorial_path)
    if payload is not None:
        source = payload.decode("utf-8")
        old = 'if not career_modules_linearTutorial.getTutorialFlag("partShoppingComplete") then'
        new = ('if career_modules_linearTutorial and '
               'type(career_modules_linearTutorial.getTutorialFlag) == "function" '
               'and not career_modules_linearTutorial.getTutorialFlag("partShoppingComplete") then')
        old2 = 'elseif not career_modules_linearTutorial.getTutorialFlag("tuningComplete") then'
        new2 = ('elseif career_modules_linearTutorial and '
                'type(career_modules_linearTutorial.getTutorialFlag) == "function" '
                'and not career_modules_linearTutorial.getTutorialFlag("tuningComplete") then')
        if old in source and old2 in source:
            source = source.replace(old, new).replace(old2, new2)
            entries[tutorial_path] = source.encode("utf-8")
            changed = True
            print("  - guarded optional linear tutorial in RLS computer menu")
        elif new in source and new2 in source:
            print("  - RLS computer tutorial guards already present")
        else:
            print("WARNING: RLS computer tutorial call pattern differs; review source")

    if patch_rls_vue_phone_routes_039(entries):
        changed = True

    if changed:
        write_zip(archive, entries, engine=zip_engine)
    return archive.stat().st_size, sha256sum(archive)


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent

    parser = argparse.ArgumentParser(
        description="Build the BeamNG 0.39.4 RLS compatibility zip for CareerMP-0.39."
    )
    parser.add_argument(
        "--rls-original",
        type=Path,
        default=None,
        help="Optional RLS source zip. Missing input skips the RLS rebuild.",
    )
    parser.add_argument(
        "--rls-272-dev-build",
        action="store_true",
        help="Explicitly build an EXPERIMENTAL RLS 2.7.2 test zip; do not auto-install it.",
    )
    parser.add_argument(
        "--careermp-039",
        type=Path,
        default=None,
        help="Optional CareerMP-0.39 source zip. Missing input skips the CareerMP rebuild.",
    )
    parser.add_argument(
        "--beammp-original",
        type=Path,
        default=None,
        help=(
            "Optional BeamMP.zip to patch for BeamNG 0.39 Vue-router compatibility. "
            "When supplied, a patched BeamMP.zip is built and installed alongside "
            "CareerMP/RLS."
        ),
    )
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
            "Optional BeamMP server root. When supplied, the finished CareerMP.zip, "
            "RLS compatibility zip, and optional patched BeamMP.zip are copied to "
            "Resources/Client automatically."
        ),
    )
    parser.add_argument(
        "--beammp-client-target",
        type=Path,
        default=None,
        help=(
            "Optional client-side BeamMP.zip destination. Use the BeamNG user "
            "mods/multiplayer path, not the BeamMP server Resources/Client folder."
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

    rls_original = (
        args.rls_original.expanduser().resolve()
        if args.rls_original
        else None
    )
    careermp_original = (
        args.careermp_039.expanduser().resolve()
        if args.careermp_039
        else None
    )
    beammp_original = (
        args.beammp_original.expanduser().resolve()
        if args.beammp_original
        else None
    )
    out_dir = args.out_dir.expanduser().resolve()
    server_root = args.server_root.expanduser().resolve() if args.server_root else None
    beammp_client_target = (
        args.beammp_client_target.expanduser().resolve()
        if args.beammp_client_target
        else None
    )

    if rls_original and not rls_original.is_file():
        print(f"SKIP RLS rebuild: input zip not found: {rls_original}")
        rls_original = None
    if careermp_original and not careermp_original.is_file():
        print(f"SKIP CareerMP rebuild: input zip not found: {careermp_original}")
        careermp_original = None
    if beammp_original and not beammp_original.is_file():
        print(f"SKIP BeamMP rebuild: input zip not found: {beammp_original}")
        beammp_original = None

    if careermp_original:
        validate_careermp_039(careermp_original)

    out_dir.mkdir(parents=True, exist_ok=True)

    rls_patch_dir = repo_root / "patches" / "RLS"
    # Always use one canonical RLS output name. The previous builder derived
    # the filename from the input archive, so rebuilding an already-compatible
    # zip produced names such as *_careermp_compatible_careermp039_compatible.zip.
    # Preserve the input RLS version in the output name. The previous hard-coded
    # 2.6.7 name made a 2.7.x build look like an old compatibility archive.
    rls_version_match = (
        re.search(r"rls_career_overhaul_(\d+\.\d+\.\d+)", rls_original.name, re.I)
        if rls_original else None
    )
    if rls_original and not rls_version_match:
        raise SystemExit(
            "Cannot detect RLS version from source filename. "
            "Expected rls_career_overhaul_X.Y.Z*.zip"
        )
    # RLS 2.8 is a new 0.40 architecture (overhaul/shell, /overhaul
    # Vue routes). Do not accidentally use legacy 0.39/2.7.2 rewrites.
    if rls_original and re.search(r"2[._-]8[._-]0", rls_original.name, re.I):
        raise SystemExit(
            "RLS 2.8.0 / BeamNG 0.40 must use a dedicated builder. "
            "The 0.39 builder would overwrite its new shell and phone routing. "
            "Run scripts/verify_rls_280_source.py for the first source audit; "
            "a 0.40 release builder is not ready."
        )
    rls_out = (
        out_dir / f"rls_career_overhaul_{rls_version_match.group(1)}_careermp_compatible.zip"
        if rls_original else None
    )
    careermp_out = out_dir / "CareerMP.zip"
    beammp_out = out_dir / "BeamMP.zip"

    rls_size = None
    rls_hash = None
    if rls_original and rls_out:
        if rls_version_match and rls_version_match.group(1) == "2.7.2":
            # Stage and verify against 2.7.2 originals, not the old overlay.
            # The remaining CareerMP bridge / career-entry changes are still
            # under review. Refuse to write or install an incomplete release.
            staged = stage_rls_272_entries(
                rls_original, repo_root / "patches" / RLS272_PATCH_DIR, rls_out.name
            )
            if not args.rls_272_dev_build:
                raise SystemExit(
                    "RLS 2.7.2 staged successfully, but release is BLOCKED. "
                    "Pass --rls-272-dev-build for an experimental local test zip."
                )
            if server_root or args.rls_install_name:
                raise SystemExit(
                    "Experimental RLS 2.7.2 build cannot be auto-installed to "
                    "the server. Re-run without --server-root/--rls-install-name."
                )
            info_path = "mod_info/RLSCO24/info.json"
            if info_path in staged:
                data = json.loads(staged[info_path].decode("utf-8-sig"))
                data["filename"] = rls_out.name
                staged[info_path] = (json.dumps(data, ensure_ascii=False, indent=4) + "\n").encode("utf-8")
            print("WARNING: Building EXPERIMENTAL RLS 2.7.2; runtime compatibility unverified.")
            write_zip(rls_out, staged, engine=args.zip_engine)
            rls_size, rls_hash = rls_out.stat().st_size, sha256sum(rls_out)
        else:
            rls_size, rls_hash = build_mod(
                rls_original,
                rls_patch_dir,
                rls_out,
                RLS_REMOVE_PREFIXES,
                args.zip_engine,
                apply_legacy_online_save_timing=False,
                apply_legacy_override_manager_patch=False,
            )

            rls_size, rls_hash = patch_rls_phone_039(rls_out, args.zip_engine)

        # Clean up filenames created by older versions of this builder.
        for stale_rls in out_dir.glob(
            "rls_career_overhaul*_careermp_compatible_careermp039_compatible.zip"
        ):
            if stale_rls.resolve() != rls_out.resolve():
                try:
                    stale_rls.unlink()
                    print(f"Removed stale nested RLS artifact: {stale_rls.name}")
                except OSError as exc:
                    print(f"WARNING: could not remove stale RLS artifact {stale_rls}: {exc}")
    else:
        print("SKIP RLS rebuild: no source zip supplied")

    cmp_size = None
    cmp_hash = None
    if careermp_original:
        careermp_entries = read_careermp_entries(careermp_original)
        patch_careermp_039(careermp_entries)
        install_careermp_watchdog(careermp_entries)
        write_zip(careermp_out, careermp_entries, engine=args.zip_engine)
        cmp_size = careermp_out.stat().st_size
        cmp_hash = sha256sum(careermp_out)
    else:
        print("SKIP CareerMP rebuild: no source zip supplied")
        if careermp_out.is_file():
            cmp_size = careermp_out.stat().st_size
            cmp_hash = sha256sum(careermp_out)

    beammp_size = None
    beammp_hash = None
    if beammp_original:
        beammp_entries = read_zip_entries(beammp_original)
        patch_beammp_039_ui(beammp_entries)
        write_zip(beammp_out, beammp_entries, engine=args.zip_engine)
        beammp_size = beammp_out.stat().st_size
        beammp_hash = sha256sum(beammp_out)
    else:
        print("SKIP BeamMP rebuild: no source zip supplied")
        if beammp_out.is_file():
            beammp_size = beammp_out.stat().st_size
            beammp_hash = sha256sum(beammp_out)

    checksums = out_dir / "checksums.txt"
    checksum_lines = []
    if rls_out and rls_hash:
        checksum_lines.append(f"{rls_hash}  {rls_out.name}")
    if cmp_hash:
        checksum_lines.append(f"{cmp_hash}  {careermp_out.name}")
    if beammp_hash:
        checksum_lines.append(f"{beammp_hash}  {beammp_out.name}")
    checksum_lines.append("")
    if rls_out and rls_size is not None:
        checksum_lines.append(f"{rls_out.name} size={rls_size}")
    if cmp_size is not None:
        checksum_lines.append(f"{careermp_out.name} size={cmp_size}")
    if beammp_size is not None:
        checksum_lines.append(f"{beammp_out.name} size={beammp_size}")
    checksum_lines.append(
        "Missing source inputs are skipped; existing built-039 artifacts are preserved."
    )
    checksum_lines.append(f"zip_engine={describe_zip_engine(args.zip_engine)}")
    checksums.write_text("\n".join(checksum_lines), encoding="utf-8")

    if rls_out and rls_hash:
        print(f"Built: {rls_out}")
    elif not rls_original:
        print("RLS: rebuild skipped")
    if cmp_hash:
        print(f"CareerMP available: {careermp_out}")
    else:
        print("CareerMP: no built artifact available")
    if beammp_hash:
        print(f"BeamMP available: {beammp_out}")
    else:
        print("BeamMP: no built artifact available")
    print(f"Wrote: {checksums}")

    if server_root:
        resources_client = server_root / "Resources" / "Client"
        resources_client.mkdir(parents=True, exist_ok=True)

        # BeamMP itself is launcher/client infrastructure, not a server resource.
        # Remove stale copies created by older compatibility builds because a
        # second server-delivered BeamMP.zip causes duplicate UI/mod activation.
        stale_server_beammp = resources_client / "BeamMP.zip"
        if stale_server_beammp.is_file():
            stale_server_beammp.unlink()
            print(f"Removed stale server BeamMP resource: {stale_server_beammp}")

        installed = []

        if rls_out and rls_out.is_file():
            install_name = args.rls_install_name or rls_out.name
            installed_rls = resources_client / install_name
            shutil.copy2(rls_out, installed_rls)
            installed_rls_hash = sha256sum(installed_rls)
            if rls_hash and installed_rls_hash != rls_hash:
                raise SystemExit(
                    "RLS install verification failed: installed hash does not match built zip"
                )
            installed.append(("RLS", installed_rls, installed_rls_hash))
        else:
            print("SKIP RLS install: no built artifact available")

        if careermp_out.is_file():
            installed_careermp = resources_client / "CareerMP.zip"
            shutil.copy2(careermp_out, installed_careermp)
            installed_cmp_hash = sha256sum(installed_careermp)
            if cmp_hash and installed_cmp_hash != cmp_hash:
                raise SystemExit(
                    "CareerMP install verification failed: installed hash does not match built zip"
                )
            installed.append(("CareerMP", installed_careermp, installed_cmp_hash))
        else:
            print("SKIP CareerMP install: no built artifact available")

        if beammp_out.is_file():
            print(
                "BeamMP client patch built but NOT copied to Resources/Client "
                "(BeamMP must not be distributed as a server resource)"
            )
        else:
            print("BeamMP client patch: no built artifact available")

        if installed:
            print("")
            print("Installed to BeamMP server:")
            for label, path, digest in installed:
                print(f"  {label}: {path}")
                print(f"    SHA256: {digest}")
        else:
            print("")
            print("No built artifacts were available to install.")

    if beammp_client_target:
        # BeamNG enumerates input actions before loading BeamMP.zip. Put the
        # standalone RLS action in the user VFS before the next game launch.
        # Location derives from .../mods/multiplayer/BeamMP.zip.
        user_root = beammp_client_target.parent.parent.parent
        action_target = user_root / "lua/ge/extensions/core/input/actions/phone.json"
        phone_action = {
            "openPhone": {
                "cat": "gameplay",
                "order": 257,
                "ctx": "tlua",
                "onDown": "if not gameplay_phone then extensions.load('gameplay_phone') end if gameplay_phone then gameplay_phone.togglePhone() end",
                "title": "Toggle Phone",
                "desc": "Toggle Phone",
            }
        }
        if beammp_client_target.parent.name.lower() != "multiplayer" or beammp_client_target.parent.parent.name.lower() != "mods":
            raise SystemExit("Refusing early phone action install: BeamMP client target must be in <userdir>/mods/multiplayer")
        action_target.parent.mkdir(parents=True, exist_ok=True)
        action_target.write_text(json.dumps(phone_action, indent=2) + "\n", encoding="utf-8")
        print(f"Installed early RLS phone action (before next game launch): {action_target}")

        if beammp_out.is_file():
            beammp_client_target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(beammp_out, beammp_client_target)
            installed_beammp_hash = sha256sum(beammp_client_target)
            if beammp_hash and installed_beammp_hash != beammp_hash:
                raise SystemExit(
                    "BeamMP client install verification failed: installed hash does not match built zip"
                )
            print("")
            print("Installed patched BeamMP client:")
            print(f"  {beammp_client_target}")
            print(f"  SHA256: {installed_beammp_hash}")
        else:
            print("SKIP BeamMP client install: no built BeamMP.zip available")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
