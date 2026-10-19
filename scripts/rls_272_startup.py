"""Staged RLS 2.7.2 startup port for BeamNG 0.39 / CareerMP.

This intentionally patches the *2.7.2 original* source, not the old 2.6.7
extensionManager replacement. The builder still has a fail-closed guard until
the remaining module/overlay audit is finished.
"""
from __future__ import annotations

from collections.abc import MutableMapping

MODSCRIPT = "scripts/rls_career_overhaul/modScript.lua"
MANAGER = "lua/ge/extensions/overhaul/extensionManager.lua"

def patch_rls_272_startup(entries: MutableMapping[str, bytes]) -> None:
    """Stage CareerMP-aware startup while retaining the 2.7.2 initialization list."""
    if MODSCRIPT not in entries or MANAGER not in entries:
        raise RuntimeError("RLS 2.7.2 startup source files missing")

    script = entries[MODSCRIPT].decode("utf-8")
    manager = entries[MANAGER].decode("utf-8")
    marker = "-- RLSCareerMP39 2.7.2 startup gate v1"
    if marker in script:
        return

    # Keep the 2.7.2 sequence verbatim, but move the job's body behind a
    # readiness predicate instead of loading the manager on mod activation.
    original = '''core_jobsystem.create(function(job)
  job.sleep(0.25)
  extensions.load("overhaul_rlsHubDyno")'''
    if script.count(original) != 1:
        raise RuntimeError("RLS 2.7.2 modScript changed; refuse unsafe startup patch")

    gate = '''-- RLSCareerMP39 2.7.2 startup gate v1
-- CareerMP selects/creates a profile asynchronously after world readiness.
-- Defer the 2.7.2 module initialization *as a group*, keeping its contents
-- intact (rlsHubDyno, extensionManager, repositoryDependencies,
-- licensePlates and saveMigration).
local function careerMP39ProfileReady()
  if worldReadyState ~= 2 then return false end
  if not (career_career and career_career.isActive and career_career.isActive()) then
    return false
  end
  local bridge = rawget(extensions, "overhaul_careermp39Compat")
  if not bridge or type(bridge.getCurrentProfile) ~= "function" then
    return false
  end
  local ok, profile, path = pcall(bridge.getCurrentProfile)
  return ok and profile ~= nil and path ~= nil
end

setExtensionUnloadMode("overhaul_careermp39Compat", "manual")
extensions.load("overhaul_careermp39Compat")

core_jobsystem.create(function(job)
  while not careerMP39ProfileReady() do
    job.sleep(0.25)
  end
  log("I", "RLSCareerMP39", "2.7.2 profile ready; initializing native RLS startup sequence")
  extensions.load("overhaul_rlsHubDyno")'''
    script = script.replace(original,gate,1)

    # RLS's regular extensionManager startup is not compatible with BeamMP
    # deactivation during multiplayer career startup.
    needle = '''local function startup()
    blockUnreloadableExtensionNames()
    deactivateBeamMP()
    ensureInputActionsRegistered()'''
    repl = '''local function startup()
    blockUnreloadableExtensionNames()
    -- RLSCareerMP39: preserve BeamMP during CareerMP startup.
    -- deactivateBeamMP() intentionally suppressed for 0.39 multiplayer.
    ensureInputActionsRegistered()'''
    if manager.count(needle) != 1:
        raise RuntimeError("RLS 2.7.2 extensionManager startup changed; refuse unsafe patch")
    manager = manager.replace(needle,repl,1)
    entries[MODSCRIPT] = script.encode("utf-8")
    entries[MANAGER] = manager.encode("utf-8")

