"""Surgical RLS 2.7.2 gameplay compatibility port.

Keep all original 2.7.2 gameplay modules. Install the existing CareerMP
inventory bridge at the time career modules become active, rather than
replacing the old playerDriving.lua with its 2.6.7 copy.
"""
from __future__ import annotations

PLAYER = "lua/ge/extensions/overrides/career/modules/playerDriving.lua"
SPEED = "lua/ge/extensions/overrides/career/modules/speedTraps.lua"
TUNING = "lua/ge/extensions/overrides/career/modules/tuning.lua"
CARDS = "lua/ge/extensions/overrides/career/modules/delivery/cargoCards.lua"
SCREEN = "lua/ge/extensions/overrides/career/modules/delivery/cargoScreen.lua"

def patch_rls_272_gameplay(entries: dict[str, bytes]) -> None:
    for path in (PLAYER, SPEED, TUNING, CARDS, SCREEN):
        if path not in entries:
            raise RuntimeError("RLS 2.7.2 gameplay module missing: " + path)

    player = entries[PLAYER].decode("utf-8")
    marker = "-- RLSCareerMP39 inventory bridge during career module activation"
    if marker not in player:
        original = """local function onCareerModulesActivated(alreadyInLevel)
  M.ensureTraffic = true
  setupTraffic(true)
end"""
        replacement = """local function onCareerModulesActivated(alreadyInLevel)
  -- RLSCareerMP39 inventory bridge during career module activation
  -- Use the 2.7.2 traffic lifecycle; only add the missing CareerMP hooks.
  local ok, compat = pcall(require, 'lua.ge.extensions.overrides.career.modules.careermpCompat')
  if ok and compat and type(compat.install) == 'function' then
    local installed, err = pcall(compat.install)
    if not installed or not err then
      log('W', 'RLSCareerMP39', 'inventory bridge not installed: ' .. tostring(err))
    end
  else
    log('W', 'RLSCareerMP39', 'inventory bridge module unavailable')
  end
  M.ensureTraffic = true
  setupTraffic(true)
end"""
        if player.count(original) != 1:
            raise RuntimeError("RLS 2.7.2 playerDriving activation changed; refuse compatibility rewrite")
        player = player.replace(original, replacement, 1)
        entries[PLAYER] = player.encode("utf-8")

    if "M.onCareerModulesActivated = onCareerModulesActivated" not in player:
        raise RuntimeError("2.7.2 playerDriving career activation hook missing")
    if "restoreTrafficAfterTutorialPhase" not in player:
        raise RuntimeError("2.7.2 playerDriving tutorial traffic restoration lost")

    speed = entries[SPEED].decode("utf-8")
    if "career_saveSystem.getCurrentProfile()" not in speed:
        raise RuntimeError("2.7.2 speed-trap profile API missing")
    if "career_saveSystem.getCurrentSaveSlot()" in speed:
        raise RuntimeError("Legacy speed-trap save slot API reintroduced")

    tuning = entries[TUNING].decode("utf-8")
    if "career_modules_inventory.getInventoryIdFromVehicleId" not in tuning:
        raise RuntimeError("2.7.2 tuning inventory lookup missing")

    screen = entries[SCREEN].decode("utf-8")
    if "getPlayerVehicleID" not in screen:
        raise RuntimeError("2.7.2 cargo screen player-vehicle handling missing")
    print("  - 2.7.2 driving inventory bridge installed; delivery/speed/tuning contracts checked")
