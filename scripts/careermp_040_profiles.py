"""Route CareerMP save/profile helper calls to RLS 2.8's own save system.

No vanilla career fallback. The original RLS save-system implementation remains
unchanged; CareerMP's compatibility wrapper is patched in memory instead.
"""
from __future__ import annotations
from careermp_040 import COMPAT

def patch_careermp_overhaul_profiles(entries: dict[str, bytes]) -> None:
    if COMPAT not in entries:
        raise RuntimeError("CareerMP compat source missing")
    source = entries[COMPAT].decode("utf-8")
    marker = "-- CareerMP040 use Overhaul-owned save profiles"
    if marker in source:
        return
    # CareerMP 0.39 compat.lua is a single point of contact for save API.
    # Restrict this rewrite to that module, never overwrite RLS saveSystem.
    expected = [
        'callPick(career_saveSystem, {"getCurrentProfile", "getCurrentSaveSlot"})',
        'callPick(career_saveSystem, {"getAllProfiles", "getAllSaveSlots"})',
        'callPick(career_saveSystem, {"setProfile", "setSaveSlot"}',
        'callPick(career_saveSystem, {"getAllSaveFolders", "getAllAutosaves"}',
        'pick(career_saveSystem, "getNewestSave")',
        'pick(career_saveSystem, "getAutosave")',
        'pick(career_saveSystem, "getCurrentDisplayName")',
    ]
    for expression in expected:
        if source.count(expression) != 1:
            raise RuntimeError("CareerMP profile mapping changed: " + expression)
    # Use a central RLS-only accessor, so missing RLS is an explicit failure,
    # not an accidental read from another career's save directory.
    anchor = 'function M.getCurrentProfile()'
    accessor = '''-- CareerMP040 use Overhaul-owned save profiles
local function overhaulSaveSystem()
  local saves = type(extensions) == "table" and extensions.overhaul_career_saveSystem
  if type(saves) ~= "table" then
    log("E", "careerMP.compat", "RLS Overhaul save system not yet available")
    return nil
  end
  return saves
end

'''
    if source.count(anchor) != 1:
        raise RuntimeError("Expected CareerMP profile accessor not found")
    source = source.replace(anchor, accessor + anchor, 1)
    for expression in expected:
        source = source.replace(expression, expression.replace("career_saveSystem", "overhaulSaveSystem()"), 1)
    # API report checks should use the same RLS module as actual save access.
    source = source.replace(', career_saveSystem, {', ', overhaulSaveSystem(), {')
    entries[COMPAT] = source.encode("utf-8")
