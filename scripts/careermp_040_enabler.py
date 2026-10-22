"""Use RLS-specific safety guard instead of CareerMP's vanilla career hook patch.

This modifies only CareerMP's enabler source in the experimental output.
RLS Overhaul startup vehicle deletion is guarded in transitions.lua.
"""
from __future__ import annotations

ENABLER = "lua/ge/extensions/careerMPEnabler.lua"

def patch_overhaul_activation_flow(entries: dict[str, bytes]) -> None:
    if ENABLER not in entries:
        raise RuntimeError("Missing CareerMP enabler")
    source = entries[ENABLER].decode("utf-8").replace("\r\n", "\n")
    marker = "-- CareerMP040 Overhaul-specific activation protection"
    if marker in source:
        return
    old = '''\tlocal careerPatches = extensions.careerMP_careerPatches
\tif not (careerPatches and careerPatches.ensure()) then
\t\tlog("E", logTag, "career patches not applied - refusing to start career " ..
\t\t\t"(would delete other players' vehicles)")
\t\treturn
\tend'''
    new = '''\t-- CareerMP040 Overhaul-specific activation protection
\t-- Do not install stale vanilla-career wrappers into BeamNG 0.40.
\t-- Require a patched RLS 2.8 game mode which advertises guarded
\t-- vehicle-removal paths before any multiplayer activation attempt.
\tlocal mode = type(extensions) == "table" and extensions.overhaul_shell_gameMode
\tif not (mode and mode.careerMPVehicleSafety == true) then
\t\tlog("E", logTag, "Missing RLS Overhaul multiplayer vehicle-safety patch")
\t\treturn
\tend'''
    if source.count(old) != 1:
        raise RuntimeError("CareerMP vanilla activation protection changed")
    source = source.replace(old, new, 1)
    old_start = '''\tlocal started = careerPatches.withRemoteVehiclesProtected(function()
\t\treturn compat.createOrLoadCareerAndStart(profileName, false, compat.defaultStartMode)
\tend)'''
    new_start = '''\t-- RLS transitions.lua is patched to avoid both remote-vehicle purge paths.
\tlocal started = compat.createOrLoadCareerAndStart(profileName, false, compat.defaultStartMode)'''
    if source.count(old_start) != 1:
        raise RuntimeError("CareerMP vanilla vehicle wrapper call changed")
    source = source.replace(old_start, new_start, 1)
    entries[ENABLER] = source.encode("utf-8")
