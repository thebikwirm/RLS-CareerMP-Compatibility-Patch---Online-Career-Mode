"""Experimental BeamNG 0.40 CareerMP adapter preparation.

This handles only demonstrably version-independent fixes in the 0.39 client.
It does NOT make CareerMP 0.39 compatible with BeamNG 0.40 or RLS 2.8.
Call on in-memory ZIP entries; release remains blocked pending real 0.40 tests.
"""
from __future__ import annotations

COMPAT = "lua/ge/extensions/careerMP/compat.lua"
PATCHES = "lua/ge/extensions/careerMP/careerPatches.lua"
ENABLER = "lua/ge/extensions/careerMPEnabler.lua"

def stage_careermp_040(entries: dict[str, bytes]) -> dict[str, bytes]:
    for path in (COMPAT, PATCHES, ENABLER):
        if path not in entries:
            raise RuntimeError("CareerMP 0.40 preparation missing " + path)
    compat = entries[COMPAT].decode("utf-8").replace("\r\n", "\n")
    if 'M.targetGameVersion = "0.39"' not in compat:
        raise RuntimeError("Expected CareerMP 0.39 baseline; source changed, re-audit")

    # The 0.39 upstream adapter truncates (profile, savePath) to a single
    # value by returning fn(...), matched. Never rename the advertised target
    # version until all game 0.40 entrypoints are verified.
    old = "return fn(...), matched"
    if old in compat:
        compat = compat.replace(old, "return fn(...)", 1)
    if "return fn(...)" not in compat:
        raise RuntimeError("CareerMP profile multi-return fix not found")
    entries[COMPAT] = compat.encode("utf-8")

    enabler = entries[ENABLER].decode("utf-8")
    patches = entries[PATCHES].decode("utf-8")
    if "compat.createOrLoadCareerAndStart" not in enabler:
        raise RuntimeError("CareerMP career activation entrypoint changed")
    if "withRemoteVehiclesProtected" not in patches:
        raise RuntimeError("CareerMP remote vehicle protection missing")

    # These legacy assumptions need a dedicated 0.40 port (and RLS 2.8
    # uses overhaul_career_*, not the built-in career_career interface).
    return entries


def report_unported_040() -> list[str]:
    return [
        "CareerMP's 0.39 Lua runtime still targets career_career and career_saveSystem",
        "RLS 2.8's career and save modules are overhaul_career_career and overhaul_career_saveSystem",
        "CareerMP activation may bypass RLS 2.8's new career lifecycle",
        "Remote vehicle protection in careerPatches.lua requires 0.40 verification",
        "BeamMP 0.40 connection and Vue bootstrap require runtime testing",
    ]
