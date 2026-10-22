"""Replace CareerMP's vanilla activation guard with RLS 2.8 safety checks.

Accept indentation and whitespace differences between shipped CareerMP ZIPs.
Fail closed when the actual activation semantics differ.
"""
from __future__ import annotations
import re

ENABLER = "lua/ge/extensions/careerMPEnabler.lua"

def patch_overhaul_activation_flow(entries: dict[str, bytes]) -> None:
    if ENABLER not in entries:
        raise RuntimeError("Missing CareerMP enabler")
    source = entries[ENABLER].decode("utf-8-sig").replace("\r\n", "\n")
    marker = "-- CareerMP040 Overhaul-specific activation protection"
    if marker in source:
        return

    guard = re.compile(
        r'^[ \t]*local careerPatches\s*=\s*extensions\.careerMP_careerPatches\s*\n'
        r'[ \t]*if\s+not\s*\(careerPatches\s+and\s+careerPatches\.ensure\(\)\)\s+then\s*\n'
        r'[ \t]*log\("E",\s*logTag,\s*"career patches not applied - refusing to start career "\s*\.\.\s*\n'
        r'[ \t]*"\(would delete other players\' vehicles\)"\)\s*\n'
        r'[ \t]*return\s*\n[ \t]*end',
        re.MULTILINE,
    )
    replacement = """  -- CareerMP040 Overhaul-specific activation protection
  -- RLS must advertise the targeted patch to both vehicle deletion paths.
  local mode = type(extensions) == "table" and extensions.overhaul_shell_gameMode
  if not (mode and mode.careerMPVehicleSafety == true) then
    log("E", logTag, "Missing RLS Overhaul multiplayer vehicle-safety patch")
    return
  end"""
    source, guards = guard.subn(lambda _: replacement, source)
    if guards != 1:
        raise RuntimeError(
            "Could not safely identify CareerMP's vanilla activation guard "
            f"(matches={guards}). Check the original CareerMP.zip version; "
            "do not bypass vehicle protection."
        )

    wrapper = re.compile(
        r'^[ \t]*local started\s*=\s*careerPatches\.withRemoteVehiclesProtected\(function\(\)\s*\n'
        r'[ \t]*return\s+compat\.createOrLoadCareerAndStart\(profileName,\s*false,\s*compat\.defaultStartMode\)\s*\n'
        r'[ \t]*end\)',
        re.MULTILINE,
    )
    source, wrappers = wrapper.subn(
        lambda _: """  -- Overhaul transitions.lua protects remote vehicles.
  local started = compat.createOrLoadCareerAndStart(profileName, false, compat.defaultStartMode)""",
        source,
    )
    if wrappers != 1:
        raise RuntimeError(
            f"Could not safely identify CareerMP's activation wrapper (matches={wrappers}); "
            "client ZIP differs from audited upstream source."
        )
    entries[ENABLER] = source.encode("utf-8")
