"""Stage matching client-side Overhaul-only server handshake.

Requires scripts/careermp_040_server.py and the dedicated RLS mode adapter.
No standalone CareerMP support is included.
"""
from __future__ import annotations

CLIENT = "lua/ge/extensions/careerMPEnabler.lua"

def patch_client_handshake(entries: dict[str, bytes]) -> None:
    if CLIENT not in entries:
        raise RuntimeError("CareerMP enabler missing")
    source = entries[CLIENT].decode("utf-8").replace("\r\n", "\n")
    marker = "-- CareerMP040 negotiated Overhaul-only session"
    if marker in source:
        return

    anchor = "local function rxCareerSync(data)"
    prelude = '''-- CareerMP040 negotiated Overhaul-only session
local modeConfirmed = false
local modeReadySent = false

-- Expose the server-negotiated state to the RLS startup guard.
-- Unlike careerMP_compat, this only returns true after rxCareerModeConfig.
function M.isOverhaulModeNegotiated()
  return modeConfirmed == true
end

local function rxCareerModeConfig(data)
  local ok, payload = pcall(jsonDecode, data)
  if not ok or type(payload) ~= "table" or payload.protocol ~= 1 or payload.mode ~= "overhaul" then
    log("E", logTag, "RLS Overhaul session refused by server")
    return
  end
  modeConfirmed = true
  TriggerServerEvent("careerSyncRequested", "")
end

-- CareerMP040: wait for the complete RLS package and multiplayer-safe shell.
-- Deferring the pending start does not change the negotiated server protocol.
local rlsWaitLogged = false
local function careerMP040RlsReady()
  if not modeConfirmed then return false end
  local fsReady = FS and type(FS.fileExists) == "function"
    and FS:fileExists("/lua/ge/extensions/overhaul/career/saveSystem.lua")
    and FS:fileExists("/lua/ge/extensions/overhaul/shell/gameMode.lua")
  local mode = type(extensions) == "table" and rawget(extensions, "overhaul_shell_gameMode")
  local ready = fsReady and type(mode) == "table"
    and type(mode.start) == "function" and mode.careerMPVehicleSafety == true
  if not ready and not rlsWaitLogged then
    log("I", logTag, "CareerMP040 waiting for RLS mount and protected game mode")
    rlsWaitLogged = true
  elseif ready and rlsWaitLogged then
    log("I", logTag, "CareerMP040 RLS ready, resuming deferred activation")
    rlsWaitLogged = false
  end
  return ready
end

local function sendOverhaulReady()
  if modeReadySent or not careerMPActive then return end
  local mode = type(extensions) == "table" and rawget(extensions, "overhaul_shell_gameMode")
  local career = type(extensions) == "table" and rawget(extensions, "overhaul_career_career")
  if not (mode and type(mode.isActive) == "function" and mode.isActive()
      and career and type(career.isActive) == "function" and career.isActive()) then return end
  TriggerServerEvent("careerModeReady", jsonEncode({ protocol = 1, mode = "overhaul", active = true }))
  modeReadySent = true
  log("I", logTag, "RLS Overhaul mode confirmed active to CareerMP server")
end

'''
    if source.count(anchor) != 1:
        raise RuntimeError("CareerMP sync handler anchor changed")
    source = source.replace(anchor, prelude + anchor, 1)
    # User-provided CareerMP.zip employs requestCareerSync(), plus a jobsystem
    # recovery request. Route BOTH through mode negotiation before sync.
    if 'local function requestCareerSync(reason)' in source:
        old = 'TriggerServerEvent("careerSyncRequested", "")'
        # The inserted rxCareerModeConfig handler contains the one *allowed*
        # careerSyncRequested send; do not replace that server-response step.
        pre, post = source.split("local function rxCareerSync(data)", 1)
        if post.count(old) != 2:
            raise RuntimeError(f"Custom CareerMP sync event call sites changed (found {post.count(old)})")
        post = post.replace(
            old,
            'TriggerServerEvent("careerModeHello", jsonEncode({ protocol = 1, mode = "overhaul" }))',
        )
        source = pre + "local function rxCareerSync(data)" + post
        hook = '\tAddEventHandler("rxCareerSync", rxCareerSync)'
        if source.count(hook) != 1:
            raise RuntimeError("Custom CareerMP event registry changed")
        source = source.replace(hook, '\tAddEventHandler("rxCareerModeConfig", rxCareerModeConfig)\n' + hook, 1)
        tick = '''local function onUpdate(dtReal, dtSim, dtRaw)
\tprocessPendingCareerStart(dtReal)'''
        if source.count(tick) != 1:
            raise RuntimeError("Custom CareerMP update callback changed")
        source = source.replace(tick, '''local function onUpdate(dtReal, dtSim, dtRaw)
  sendOverhaulReady()
  if not careerMP040RlsReady() then return end
\tprocessPendingCareerStart(dtReal)''', 1)
        leave = '''\tcareerMPActive = false
\tsyncRequested = false'''
        if source.count(leave) != 1:
            raise RuntimeError("Custom CareerMP disconnect state changed")
        source = source.replace(leave, '''\tcareerMPActive = false
\tsyncRequested = false
  modeConfirmed = false
  modeReadySent = false''', 1)
        sync = '''local function rxCareerSync(data)
\tclientConfig = jsonDecode(data)'''
        if source.count(sync) != 1:
            raise RuntimeError("Custom CareerMP rxCareerSync changed")
        source = source.replace(sync, '''local function rxCareerSync(data)
  if not modeConfirmed then
    log("E", logTag, "Ignoring sync before RLS Overhaul mode negotiation")
    return
  end
\tclientConfig = jsonDecode(data)''', 1)
        entries[CLIENT] = source.encode("utf-8")
        return

    old = '''\t\tTriggerServerEvent("careerSyncRequested", "")
\t\tsyncRequested = true'''
    new = '''\t\tTriggerServerEvent("careerModeHello", jsonEncode({ protocol = 1, mode = "overhaul" }))
\t\tsyncRequested = true'''
    if source.count(old) != 1:
        raise RuntimeError("CareerMP world ready handshake changed")
    source = source.replace(old, new, 1)
    hook = '\tAddEventHandler("rxCareerSync", rxCareerSync)'
    if source.count(hook) != 1:
        raise RuntimeError("CareerMP event registration changed")
    source = source.replace(hook, '\tAddEventHandler("rxCareerModeConfig", rxCareerModeConfig)\n' + hook, 1)
    tick = '''local function onUpdate(dtReal, dtSim, dtRaw)
\tif worldReadyState ~= 2 or not clientConfig then return end'''
    if source.count(tick) != 1:
        raise RuntimeError("CareerMP frame callback changed")
    source = source.replace(tick, '''local function onUpdate(dtReal, dtSim, dtRaw)
  sendOverhaulReady()
  if not careerMP040RlsReady() then return end
\tif worldReadyState ~= 2 or not clientConfig then return end''', 1)
    leave = '''\tcareerMPActive = false
\tsyncRequested = false'''
    if source.count(leave) != 1:
        raise RuntimeError("CareerMP disconnect state changed")
    source = source.replace(leave, '''\tcareerMPActive = false
\tsyncRequested = false
  modeConfirmed = false
  modeReadySent = false''', 1)
    sync = '''local function rxCareerSync(data)
\tclientConfig = jsonDecode(data)'''
    if source.count(sync) != 1:
        raise RuntimeError("CareerMP sync entry changed")
    source = source.replace(sync, '''local function rxCareerSync(data)
  if not modeConfirmed then
    log("E", logTag, "Ignoring career sync before Overhaul mode negotiation")
    return
  end
\tclientConfig = jsonDecode(data)''', 1)
    entries[CLIENT] = source.encode("utf-8")
