"""Narrow BeamNG 0.40 / RLS 2.8.0 multiplayer entry compatibility.

Patch the exact 2.8.0 shell source in a future opt-in builder; never copy the
0.39 extensionManager or interfere with existing 2.8.0 scope loading.
This is an experimental source patch, not proof of in-game compatibility.
"""
from __future__ import annotations
import re

SHELL = "lua/ge/extensions/overhaul/shell/extensionManager.lua"
SAVE = "lua/ge/extensions/overhaul/career/saveSystem.lua"
CAREER = "lua/ge/extensions/overhaul/career/career.lua"
INVENTORY = "lua/ge/extensions/overhaul/career/garage/inventory.lua"

OLD = '''  if not isBeamMPActive() then return false end
  log("W", "extensionManager", "BeamMP is active; Career Overhaul cannot start until it is disabled")'''
NEW = '''  if not isBeamMPActive() then return false end
  -- CareerMP040: permit BeamMP only after this client's Overhaul-only
  -- session was explicitly negotiated with the CareerMP server.
  -- The generic careerMP_compat extension can unload during transitions,
  -- and its presence alone does not prove multiplayer mode was accepted.
  local enabler = type(extensions) == "table" and rawget(extensions, "careerMPEnabler")
  if type(enabler) == "table" and type(enabler.isOverhaulModeNegotiated) == "function" then
    local ok, negotiated = pcall(enabler.isOverhaulModeNegotiated)
    if ok and negotiated == true then
      log("I", "RLSCareerMP040", "Negotiated Overhaul session; allowing BeamMP career startup")
      return false
    end
  end
  log("W", "extensionManager", "BeamMP is active; Career Overhaul cannot start until it is disabled")'''

def patch_rls_280_multiplayer(entries: dict[str, bytes]) -> None:
    for path in (SHELL, SAVE, CAREER, INVENTORY):
        if path not in entries:
            raise RuntimeError("Missing RLS 2.8.0 compatibility source: " + path)
    shell = entries[SHELL].decode("utf-8")
    if "CareerMP040: permit BeamMP only after this client's Overhaul-only" not in shell:
        # Whitespace can vary across slim exports and checked-out files.
        # Match the explicit BeamMP gate and warning as a single unit;
        # do not remove the version check, warning, or standalone refusal.
        pattern = re.compile(
            r'^[ \t]*if not isBeamMPActive\(\) then return false end[ \t]*\n'
            r'[ \t]*log\("W",\s*"extensionManager",\s*"BeamMP is active; Career Overhaul cannot start until it is disabled"\)',
            re.MULTILINE,
        )
        shell, count = pattern.subn(lambda _: NEW, shell)
        if count != 1:
            raise RuntimeError(
                f"RLS 2.8.0 BeamMP refusal differs from audited source (matches={count}); "
                "check upstream/rls_2.8.0_slim or restore it from git. Refusing unsafe patch."
            )
        entries[SHELL] = shell.encode("utf-8")
    if "SUPPORTED_GAME_MINOR_VERSION = 40" not in shell:
        raise RuntimeError("Expected RLS 2.8.0 shell game version check missing")
    save = entries[SAVE].decode("utf-8")
    if ("M.getCurrentProfile = getCurrentProfile" not in save
            or "M.getCurrentSaveSlot = getCurrentProfile" not in save
            or "return currentProfile, currentSavePath" not in save):
        raise RuntimeError("RLS 2.8.0 profile name/path API changed")
    career = entries[CAREER].decode("utf-8")
    if "overhaul_career_saveSystem.getCurrentProfile()" not in career:
        raise RuntimeError("RLS 2.8.0 career uses an unexpected profile API")
    inventory = entries[INVENTORY].decode("utf-8")
    for needle in ("M.spawnVehicle = parts.spawn.spawnVehicle",
                   "M.getVehicleIdFromInventoryId = parts.ui.getVehicleIdFromInventoryId",
                   "M.getInventoryIdFromVehicleId = parts.ui.getInventoryIdFromVehicleId"):
        if needle not in inventory:
            raise RuntimeError("RLS 2.8.0 inventory API changed: " + needle)
