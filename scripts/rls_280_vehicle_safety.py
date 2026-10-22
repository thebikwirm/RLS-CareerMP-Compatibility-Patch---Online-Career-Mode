"""Disable RLS career startup vehicle purges only in explicit CareerMP sessions.

The RLS 2.8 start/transitions.lua contains two vehicle deletion paths.
Guard only those two under a live CareerMP compatibility extension.
"""
from __future__ import annotations

TRANSITIONS = "lua/ge/extensions/overhaul/career/start/transitions.lua"

def patch_overhaul_mp_vehicle_safety(entries: dict[str, bytes]) -> None:
    if TRANSITIONS not in entries:
        raise RuntimeError("Missing RLS 2.8 career transitions module")
    source = entries[TRANSITIONS].decode("utf-8")
    marker = "-- CareerMP040 protect remote BeamMP vehicles"
    if marker in source:
        return
    old = """    if currentLevel then
      if removeVehicles then
        core_vehicles.removeAll()
      else
        context.removeNonTrafficVehicles()
      end
      return finishActivateInLevel(attempt, true)
    end"""
    new = """    if currentLevel then
      -- CareerMP040 protect remote BeamMP vehicles: neither stock removal
      -- branch understands other players' ownership. Local starter vehicle
      -- cleanup remains CareerMP's responsibility after activation.
      local mpCareer = type(extensions) == "table" and
        type(extensions.careerMP_compat) == "table" and
        type(extensions.careerMPEnabler) == "table"
      if not mpCareer then
        if removeVehicles then
          core_vehicles.removeAll()
        else
          context.removeNonTrafficVehicles()
        end
      else
        log("I", "RLSCareerMP040", "Skipping career activation vehicle purge in multiplayer")
      end
      return finishActivateInLevel(attempt, true)
    end"""
    if source.count(old) != 1:
        raise RuntimeError("RLS 2.8 vehicle removal implementation changed: review safety")
    entries[TRANSITIONS] = source.replace(old, new, 1).encode("utf-8")
