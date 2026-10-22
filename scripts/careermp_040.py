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


# RLS 2.8 has its own Overhaul gamestate ("overhaul"), and MUST start via
# overhaul_shell_gameMode.start(). Do not call vanilla career_career as a
# substitute or attempt to alias overhaul_career_career globally.
RLS280_GAME_MODE = "lua/ge/extensions/overhaul/shell/gameMode.lua"
RLS280_CONTEXT = "lua/ge/extensions/overhaul/lib/career/context.lua"

def verify_rls_280_mode(entries: dict[str, bytes]) -> None:
    for path in (RLS280_GAME_MODE, RLS280_CONTEXT):
        if path not in entries:
            raise RuntimeError("RLS 2.8 Overhaul mode source missing: " + path)
    mode = entries[RLS280_GAME_MODE].decode("utf-8")
    context = entries[RLS280_CONTEXT].decode("utf-8")
    for required in (
        'core_gamestate.setGameState("overhaul", "overhaul", nil)',
        "function M.start(saveName, specificAutosave, startingOptions)",
        "career.createOrLoadCareerAndStart(saveName, specificAutosave, startingOptions)",
        'extensions.hook("onOverhaulModeStarted", saveName)',
        "function M.stop()",
        "function M.onOverhaulBeforeCareerActivate()",
    ):
        if required not in mode:
            raise RuntimeError("RLS 2.8 game mode contract changed: " + required)
    if 'function M.isOverhaulActive()' not in context:
        raise RuntimeError("RLS 2.8 mode context check missing")


def patch_careermp_040_overhaul_adapter(entries: dict[str, bytes]) -> None:
    """Stage the RLS-only 0.40 start adapter, failing closed without Overhaul.

    CareerMP 0.40 in this project is not a standalone vanilla career mod.
    It must never start stock career if RLS has not initialized.
    """
    if COMPAT not in entries:
        raise RuntimeError("CareerMP compat.lua missing")
    source = entries[COMPAT].decode("utf-8").replace("\r\n", "\n")
    marker = "-- CareerMP040 RLS 2.8 dedicated game mode adapter"
    if marker in source:
        return
    original = """function M.createOrLoadCareerAndStart(name, specificSaveFolder, startMode)
\tlocal career = career_career
\tif not career or type(career.createOrLoadCareerAndStart) ~= "function" then
\t\tlog("E", "careerMP.compat", "career_career.createOrLoadCareerAndStart missing")
\t\treturn false
\tend
\tif M.usesStartingOptions() then
\t\treturn career.createOrLoadCareerAndStart(name, specificSaveFolder, {
\t\t\tstartMode = startMode or M.defaultStartMode,
\t\t})
\tend
\t-- 0.38 and older: third arg was the tutorial flag; never enable it in MP.
\treturn career.createOrLoadCareerAndStart(name, specificSaveFolder, false)
end"""
    replacement = """function M.createOrLoadCareerAndStart(name, specificSaveFolder, startMode)
\t-- CareerMP040 RLS 2.8 dedicated game mode adapter (Overhaul-only)
\tlocal mode = type(extensions) == "table" and rawget(extensions, "overhaul_shell_gameMode")
\tif not (mode and type(mode.start) == "function" and mode.careerMPVehicleSafety == true) then
\t\tlog("E", "careerMP.compat", "RLS 2.8 game mode or multiplayer vehicle safety patch missing")
\t\treturn false
\tend
\tlocal ok, reason = mode.start(name, specificSaveFolder, {
\t\tstartMode = startMode or M.defaultStartMode,
\t})
\tif not ok then
\t\tlog("E", "careerMP.compat", "Overhaul career start failed: " .. tostring(reason))
\tend
\treturn ok
end"""
    if source.count(original) != 1:
        raise RuntimeError("CareerMP career activation source layout changed")
    entries[COMPAT] = source.replace(original, replacement, 1).encode("utf-8")
