function onInit()
    MP.RegisterEvent("onPlayerAuth", "dbgPlayerAuth")
    MP.RegisterEvent("onPlayerConnecting", "dbgPlayerConnecting")
    MP.RegisterEvent("onPlayerJoining", "dbgPlayerJoining")
    MP.RegisterEvent("onPlayerJoin", "dbgPlayerJoin")
    MP.RegisterEvent("onPlayerDisconnect", "dbgPlayerDisconnect")

    print("[CareerDebug] Debug plugin loaded")
end

function dbgPlayerAuth(name, role, isGuest, identifiers)
    print(string.format(
        "[CareerDebug] AUTH name=%s role=%s guest=%s",
        tostring(name),
        tostring(role),
        tostring(isGuest)
    ))
end

function dbgPlayerConnecting(playerID)
    print("[CareerDebug] CONNECTING playerID=" .. tostring(playerID))
end

function dbgPlayerJoining(playerID)
    print("[CareerDebug] JOINING playerID=" .. tostring(playerID))
end

function dbgPlayerJoin(playerID)
    print("[CareerDebug] JOINED playerID=" .. tostring(playerID))
end

function dbgPlayerDisconnect(playerID)
    print("[CareerDebug] DISCONNECTED playerID=" .. tostring(playerID))
end