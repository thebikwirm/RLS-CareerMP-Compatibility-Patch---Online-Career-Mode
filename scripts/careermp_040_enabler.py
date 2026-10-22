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

    # The user-supplied CareerMP ZIP has a different 0.39 fork with a
    # direct-start fallback and a deferred retry path. These must not silently
    # activate vanilla career or install its stale vehicle protection patches.
    custom_lookup = 'extensions and extensions["careerMP_careerPatches"]'
    if source.count(custom_lookup) == 2 and "local function tryDirectCareerStart(dtReal)" in source:
        if source.count("careerPatches.withRemoteVehiclesProtected(function()") != 2:
            raise RuntimeError("Custom CareerMP activation wrappers changed")
        if source.count('extensions and extensions["career_career"] or career_career') != 2:
            raise RuntimeError("Custom CareerMP active-state checks changed")
        anchor = "local M = {}"
        if source.count(anchor) != 1:
            raise RuntimeError("Custom CareerMP module declaration changed")
        shim = '''-- CareerMP040 Overhaul-specific activation protection
-- RLS 2.8 transitions guard both remote-vehicle purge branches.
local careerMP040Protection = {
  ensure = function()
    local mode = type(extensions) == "table" and extensions.overhaul_shell_gameMode
    return mode and mode.careerMPVehicleSafety == true
  end,
  withRemoteVehiclesProtected = function(fn)
    if not careerMP040Protection.ensure() then
      log("E", "CareerMP040", "RLS Overhaul multiplayer vehicle safety missing")
      return false
    end
    return fn()
  end,
}
'''
        # Resolve the shim's self reference through a local forward declaration.
        shim = shim.replace("local careerMP040Protection = {", "local careerMP040Protection\ncareerMP040Protection = {")
        source = source.replace(anchor, anchor + "\n" + shim, 1)
        source = source.replace(custom_lookup, "careerMP040Protection")
        # The unnegotiated fallback bypasses the RLS-only server handshake.
        source = source.replace(
            "local function tryDirectCareerStart(dtReal)",
            "local function tryDirectCareerStart(dtReal)\n  -- CareerMP040: no offline/direct start without server negotiation\n  if true then return end",
            1,
        )
        source = source.replace(
            'extensions and extensions["career_career"] or career_career',
            'extensions and extensions["overhaul_career_career"]',
        )
        entries[ENABLER] = source.encode("utf-8")
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
