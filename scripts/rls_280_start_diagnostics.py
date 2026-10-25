"""Preserve RLS career-start failure details in experimental 0.40 builds.

Never change the return value or retry behavior: diagnostic-only instrumentation.
"""
from __future__ import annotations

GAME_MODE = "lua/ge/extensions/overhaul/shell/gameMode.lua"
OLD = '''  local loaded = career.createOrLoadCareerAndStart(saveName, specificAutosave, startingOptions)
  if loaded == false then error("career_start_failed") end'''
NEW = '''  local loaded, reason = career.createOrLoadCareerAndStart(saveName, specificAutosave, startingOptions)
  if loaded == false then
    local profile, path
    if type(overhaul_career_saveSystem) == "table"
        and type(overhaul_career_saveSystem.getCurrentProfile) == "function" then
      local profileOk, current, currentPath = pcall(overhaul_career_saveSystem.getCurrentProfile)
      if profileOk then profile, path = current, currentPath end
    end
    log("E", "RLSCareerMP040", "Career start returned false; reason=" .. tostring(reason)
      .. ", requestedProfile=" .. tostring(saveName)
      .. ", currentProfile=" .. tostring(profile)
      .. ", savePathAvailable=" .. tostring(path ~= nil)
      .. ", level=" .. tostring(getCurrentLevelIdentifier()))
    error("career_start_failed: " .. tostring(reason))
  end'''


def patch_start_diagnostics(entries: dict[str, bytes]) -> None:
    if GAME_MODE not in entries:
        raise RuntimeError("Missing RLS gameMode.lua for startup diagnostics")
    source = entries[GAME_MODE].decode("utf-8")
    if NEW in source:
        return
    if source.count(OLD) != 1:
        raise RuntimeError("Unexpected RLS career-start source; refusing diagnostic injection")
    entries[GAME_MODE] = source.replace(OLD, NEW, 1).encode("utf-8")
