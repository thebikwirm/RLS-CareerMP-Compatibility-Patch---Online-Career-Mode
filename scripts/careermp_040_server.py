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
-- Legacy clients retain the original rxCareerSync flow. In Overhaul mode,
-- only careerModeReady acknowledges actual in-game activation.
local supportedCareerModes = { vanilla = true, overhaul = true }

function careerModeHello(player_id, data)
  local entry = pendingActivation[player_id]
  if not entry or not MP.IsPlayerConnected(player_id) then return end
  local ok, payload = pcall(Util.JsonDecode, data or "")
  if not ok or type(payload) ~= "table" or
     (payload.protocol ~= 1) or not supportedCareerModes[payload.mode] then
    log("W", "CareerMP040", "Rejected invalid career mode hello from " .. tostring(player_id))
    return
  end
  entry.mode = payload.mode
  entry.careerActive = false
  entry.modeProtocol = 1
  MP.TriggerClientEventJson(player_id, "rxCareerModeConfig", {
    protocol = 1, mode = entry.mode, config = Config.client
  })
end

function careerModeReady(player_id, data)
  local entry = pendingActivation[player_id]
  if not entry or entry.modeProtocol ~= 1 or not MP.IsPlayerConnected(player_id) then return end
  local ok, payload = pcall(Util.JsonDecode, data or "")
  if not ok or type(payload) ~= "table" or payload.protocol ~= 1
     or payload.mode ~= entry.mode or payload.active ~= true then
    return
  end
  entry.careerActive = true
  log("I", "CareerMP040", "Player " .. tostring(player_id) ..
      " activated " .. tostring(entry.mode) .. " career")
end

function careerSyncRequested(player_id)
  local entry = pendingActivation[player_id]
  if not entry then return end
  MP.TriggerClientEventJson(player_id, "rxCareerSync", Config.client)
  -- Older clients only support rxCareerSync; preserve their handshake.
  -- A negotiated 0.40 client MUST report careerModeReady separately.
  if not entry.modeProtocol then
    entry.careerActive = true
  end
end'''
    if source.count(old) != 1:
        raise RuntimeError("CareerMP server activation handshake changed")
    source = source.replace(old, new, 1)
    return source
