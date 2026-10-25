"""Log early RLS 2.8 career profile refusal reasons without changing behavior."""
from __future__ import annotations

STARTING = "lua/ge/extensions/overhaul/career/start/startingModes.lua"
TRANSITIONS = "lua/ge/extensions/overhaul/career/start/transitions.lua"

def replace_once(source: str, old: str, new: str, path: str) -> str:
    if source.count(new) == 1:
        return source
    if source.count(old) != 1:
        raise RuntimeError(f"RLS profile diagnostic anchor changed: {path}: {old[:75]}")
    return source.replace(old, new, 1)

def patch_rls_profile_diagnostics(entries: dict[str, bytes]) -> None:
    for path in (STARTING, TRANSITIONS):
        if path not in entries:
            raise RuntimeError("Missing RLS profile startup source: " + path)

    s = entries[STARTING].decode("utf-8")
    s = replace_once(s,
        '''  if overhaul_shell_extensionManager.refuseCareerStart() then
    return false
  end''',
        '''  if overhaul_shell_extensionManager.refuseCareerStart() then
    log("E", "RLSCareerMP040", "Profile start refused by extensionManager; requested=" .. tostring(name))
    return false
  end''', STARTING)
    s = replace_once(s,
        '''  if not paths.displayName(name) or (specificAutosave ~= nil
    and (not paths.valid(name) or not paths.valid(specificAutosave))) then return false end''',
        '''  if not paths.displayName(name) or (specificAutosave ~= nil
    and (not paths.valid(name) or not paths.valid(specificAutosave))) then
    log("E", "RLSCareerMP040", "Invalid profile name/autosave: name=" .. tostring(name)
      .. ", autosave=" .. tostring(specificAutosave))
    return false
  end''', STARTING)
    s = replace_once(s,
        '''  if legacyMigrationBlocks(career, request) then
    return false
  end''',
        '''  if legacyMigrationBlocks(career, request) then
    log("W", "RLSCareerMP040", "Career start blocked by legacy migration: " .. tostring(name))
    return false
  end''', STARTING)
    s = replace_once(s,
        '''    log("W", "", "Ignoring duplicate career start; a load is already in progress")
    return false''',
        '''    log("W", "RLSCareerMP040", "Duplicate career start while existing load in progress: " .. tostring(name))
    return false''', STARTING)
    s = replace_once(s,
        '''    saveSlots.refuseUnreadableSave(name, specificAutosave)
    return false''',
        '''    saveSlots.refuseUnreadableSave(name, specificAutosave)
    log("E", "RLSCareerMP040", "Unreadable profile/autosave: " .. tostring(name))
    return false''', STARTING)
    s = replace_once(s,
        '''  if not selectPreparedProfile(request) then
    abortCareerStart(career)
    return
  end''',
        '''  if not selectPreparedProfile(request) then
    log("E", "RLSCareerMP040", "Failed selecting prepared profile: " .. tostring(name))
    abortCareerStart(career)
    return
  end''', STARTING)
    entries[STARTING] = s.encode("utf-8")
    t = entries[TRANSITIONS].decode("utf-8")
    t = replace_once(t,
        '''  if not profile then
    session.startInProgress = false''',
        '''  if not profile then
    log("E", "RLSCareerMP040", "Activation has no current profile; savePath=" .. tostring(savePath))
    session.startInProgress = false''', TRANSITIONS)
    entries[TRANSITIONS] = t.encode("utf-8")
