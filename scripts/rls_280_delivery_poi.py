"""Guard only the vanilla delivery POI callback during RLS multiplayer.

BeamNG 0.40 vanilla general.lua may receive onGetRawPoiListForLevel before
its private dParcelManager is initialized. Do not suppress other exceptions,
disable vanilla deliveries, or change standalone RLS behavior.
"""
from __future__ import annotations

VANILLA_SERVICES = "lua/ge/extensions/overhaul/integration/vanillaServices.lua"
ANCHOR = '''local function createLevelPatches()
  listen("gameplay_crawl_saveSystem"'''
REPLACEMENT = '''local function createLevelPatches()
  -- CareerMP040: protect this one vanilla POI provider from the known
  -- dParcelManager initialization race. Retry the original on later calls.
  local deliveryPoiWarned = false
  listen("career_modules_delivery_general", {
    onGetRawPoiListForLevel = function(original, _, ...)
      local ok, result = pcall(original, ...)
      if ok then
        deliveryPoiWarned = false
        return result
      end
      if type(result) == "string"
          and result:find("dParcelManager", 1, true)
          and result:find("nil value", 1, true) then
        if not deliveryPoiWarned then
          log("W", "RLSCareerMP040", "Vanilla delivery POIs deferred until parcel manager initializes: " .. result)
          deliveryPoiWarned = true
        end
        return
      end
      error(result)
    end,
  })
  listen("gameplay_crawl_saveSystem"'''

def patch_delivery_poi(entries: dict[str, bytes]) -> None:
    if VANILLA_SERVICES not in entries:
        raise RuntimeError("RLS vanilla services integration is missing")
    src = entries[VANILLA_SERVICES].decode("utf-8")
    if "-- CareerMP040: protect this one vanilla POI provider" in src:
        return
    if src.count(ANCHOR) != 1:
        raise RuntimeError("RLS vanilla services level-patch layout changed")
    entries[VANILLA_SERVICES] = src.replace(ANCHOR, REPLACEMENT, 1).encode("utf-8")
