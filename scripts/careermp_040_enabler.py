"""Replace CareerMP's vanilla activation guard with RLS 2.8 safety checks.

Accept indentation and whitespace differences between shipped CareerMP ZIPs.
Fail closed when the actual activation semantics differ.
"""
from __future__ import annotations
import re

ENABLER = "lua/ge/extensions/careerMPEnabler.lua"

PROFILE_MARKER = "-- CareerMP040 configurable RLS profile selection"

def patch_profile_selector(source: str) -> str:
    """Select the local RLS profile at the final CareerMP -> RLS start call.

    This intentionally patches the call boundary rather than depending on one
    CareerMP fork's pending-profile variable names.
    """
    if PROFILE_MARKER in source:
        return source

    anchor = "local M = {}"
    if source.count(anchor) != 1:
        raise RuntimeError("CareerMP profile config: module declaration changed")

    lua = r'''
-- CareerMP040 configurable RLS profile selection
local CAREERMP_PROFILE_CONFIG_PATH = "/settings/rls_careermp_profile.json"
local careerMPProfileConfig = nil

local function normalizeCareerMPProfileConfig(config)
  config = type(config) == "table" and config or {}
  local mode = tostring(config.mode or "server"):lower()
  if mode ~= "server" and mode ~= "existing" and mode ~= "new" then
    mode = "server"
  end
  return {
    mode = mode,
    profileName = tostring(config.profileName or ""),
    newProfileName = tostring(config.newProfileName or "RLS-CareerMP"),
  }
end

local function loadCareerMPProfileConfig()
  if careerMPProfileConfig then return careerMPProfileConfig end

  local ok, loaded = pcall(jsonReadFile, CAREERMP_PROFILE_CONFIG_PATH)
  if not ok or type(loaded) ~= "table" then
    careerMPProfileConfig = normalizeCareerMPProfileConfig(nil)
    local wrote, err = pcall(jsonWriteFile, CAREERMP_PROFILE_CONFIG_PATH, careerMPProfileConfig, true)
    if wrote then
      log("I", "CareerMP-ProfileConfig", "Created default profile config at " .. CAREERMP_PROFILE_CONFIG_PATH)
    else
      log("E", "CareerMP-ProfileConfig", "Unable to write profile config: " .. tostring(err))
    end
  else
    careerMPProfileConfig = normalizeCareerMPProfileConfig(loaded)
  end

  return careerMPProfileConfig
end

local function resolveConfiguredCareerMPProfile(serverProfile)
  local config = loadCareerMPProfileConfig()
  local selected = tostring(serverProfile or "")
  local selectedMode = "server"

  if config.mode == "existing" and config.profileName ~= "" then
    selected = config.profileName
    selectedMode = "existing"
  elseif config.mode == "new" and config.newProfileName ~= "" then
    selected = config.newProfileName
    selectedMode = "new"
  elseif config.mode ~= "server" then
    selectedMode = "server-fallback"
    log("W", "CareerMP-ProfileConfig",
      "Configured " .. tostring(config.mode) .. " profile name is blank; using server profile " .. selected)
  end

  log("I", "CareerMP-ProfileConfig",
    "career profile selected mode=" .. selectedMode ..
    " profile=" .. selected ..
    " serverProfile=" .. tostring(serverProfile))
  return selected
end
'''
    source = source.replace(anchor, anchor + "\n" + lua, 1)

    # Wrap every final CareerMP compatibility call. The current experimental
    # source has retry/direct-start variants, so there may be more than one.
    call = re.compile(
        r'(compat\.createOrLoadCareerAndStart\()\s*([^,\n]+)(\s*,)'
    )
    source, count = call.subn(
        lambda m: m.group(1)
        + (
            m.group(2)
            if "resolveConfiguredCareerMPProfile" in m.group(2)
            else "resolveConfiguredCareerMPProfile(" + m.group(2).strip() + ")"
        )
        + m.group(3),
        source,
    )
    if count < 1:
        raise RuntimeError(
            "CareerMP profile config: no compat.createOrLoadCareerAndStart call found"
        )

    return source


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
        source = patch_profile_selector(source)
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
    source = patch_profile_selector(source)
    entries[ENABLER] = source.encode("utf-8")
