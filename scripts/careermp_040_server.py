"""Opt-in server-side CareerMP / RLS 2.8 Overhaul session protocol.

Operate on the upstream CareerMP 0.39 server Lua SOURCE in memory. This does
not deploy or activate new events unless used by a future 0.40 build.
"""
from __future__ import annotations

EVENT_START = 'MP.RegisterEvent("careerModeHello", "careerModeHello")'
EVENT_READY = 'MP.RegisterEvent("careerModeReady", "careerModeReady")'

def patch_server(source: str) -> str:
    marker = "-- CareerMP040 explicit game-mode negotiation"
    if marker in source:
        return source
    register = '\tMP.RegisterEvent("careerSyncRequested","careerSyncRequested")'
    if source.count(register) != 1:
        raise RuntimeError("CareerMP server sync registration changed")
    source = source.replace(register, register + '\n\t' + EVENT_START + '\n\t' + EVENT_READY, 1)

    old = '''function careerSyncRequested(player_id)
\tMP.TriggerClientEventJson(player_id, "rxCareerSync", Config.client)
\t-- Guard: the entry is gone if the player disconnected between join and sync.
\tif pendingActivation[player_id] then
\t\tpendingActivation[player_id].careerActive = true
\tend
end'''
    new = '''-- CareerMP040 explicit game-mode negotiation
-- This server requires RLS Overhaul mode; only careerModeReady confirms
-- actual in-game activation. Legacy clients are not supported.
local supportedCareerModes = { overhaul = true }

function careerModeHello(player_id, data)
  local entry = pendingActivation[player_id]
  print("[CareerMP040-DIAG] hello player=" .. tostring(player_id) .. " pending=" .. tostring(entry ~= nil) .. " connected=" .. tostring(MP.IsPlayerConnected(player_id)))
  if not entry or not MP.IsPlayerConnected(player_id) then return end
  local ok, payload = pcall(Util.JsonDecode, data or "")
  if not ok or type(payload) ~= "table" or
     (payload.protocol ~= 1) or not supportedCareerModes[payload.mode] then
    print("[CareerMP040] Rejected invalid career mode hello from " .. tostring(player_id))
    return
  end
  entry.mode = payload.mode
  entry.careerActive = false
  entry.modeProtocol = 1
  print("[CareerMP040-DIAG] negotiated player=" .. tostring(player_id) .. " mode=" .. tostring(entry.mode) .. " careerActive=" .. tostring(entry.careerActive))
  MP.TriggerClientEventJson(player_id, "rxCareerModeConfig", {
    protocol = 1, mode = entry.mode, config = Config.client
  })
end

function careerModeReady(player_id, data)
  local entry = pendingActivation[player_id]
  print("[CareerMP040-DIAG] ready received player=" .. tostring(player_id) .. " pending=" .. tostring(entry ~= nil) .. " protocol=" .. tostring(entry and entry.modeProtocol) .. " mode=" .. tostring(entry and entry.mode) .. " connected=" .. tostring(MP.IsPlayerConnected(player_id)))
  if not entry or entry.modeProtocol ~= 1 or not MP.IsPlayerConnected(player_id) then return end
  local ok, payload = pcall(Util.JsonDecode, data or "")
  if not ok or type(payload) ~= "table" or payload.protocol ~= 1
     or payload.mode ~= entry.mode or payload.active ~= true then
    return
  end
  entry.careerActive = true
  print("[CareerMP040-DIAG] ready accepted player=" .. tostring(player_id) .. " careerActive=" .. tostring(entry.careerActive))
  MP.TriggerClientEventJson(player_id, "rxCareerModeReadyAck", { protocol = 1, mode = entry.mode, active = true })
  print("[CareerMP040] Player " .. tostring(player_id) ..
      " activated " .. tostring(entry.mode) .. " career")
end

function careerSyncRequested(player_id)
  local entry = pendingActivation[player_id]
  print("[CareerMP040-DIAG] sync requested player=" .. tostring(player_id) .. " pending=" .. tostring(entry ~= nil) .. " mode=" .. tostring(entry and entry.mode) .. " protocol=" .. tostring(entry and entry.modeProtocol))
  if not entry then return end
  if entry.mode ~= "overhaul" or entry.modeProtocol ~= 1 then return end
  MP.TriggerClientEventJson(player_id, "rxCareerSync", Config.client)
  -- No vanilla fallback: a successful sync is not an activated mode.
  -- Negotiation and mode readiness must be confirmed separately.
end'''
    if source.count(old) != 1:
        raise RuntimeError("CareerMP server activation handshake changed")
    source = source.replace(old, new, 1)
    # Do not allow the default upstream updater to replace our experimental
    # server code. Existing user config.json can override the default.
    if source.count("autoUpdate = true,") != 1:
        raise RuntimeError("CareerMP server autoUpdate default changed")
    source = source.replace("autoUpdate = true,", "autoUpdate = false,", 1)
    return source
