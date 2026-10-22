local careerMPBankingBridgeReceiveEnabled = {}
local careerMPBankingBridgeOriginalPayPlayer = nil
local careerMPBankingBridgeHookInstalled = false
local careerMPBankingBridgeMissingPayPlayerLogged = false

local function careerMPBankingBridgeDecodeJson(data)
    local ok, decoded = pcall(Util.JsonDecode, data or "{}")
    if ok and decoded then
        return decoded
    end

    return {}
end

local function careerMPBankingBridgePlayerKey(playerId)
    return tostring(playerId)
end

local function careerMPBankingBridgeIncomingEnabled(playerId)
    return careerMPBankingBridgeReceiveEnabled[careerMPBankingBridgePlayerKey(playerId)] ~= false
end

local function careerMPBankingBridgeRepairPaymentConfig()
    if type(Config) ~= "table" then
        return
    end

    Config.server = Config.server or {}

    -- CareerMP 0.26 defines sessionSendingMax but payPlayer checks sessionTransactionMax.
    if Config.server.sessionTransactionMax == nil then
        Config.server.sessionTransactionMax = Config.server.sessionSendingMax or 100000
    end
end

local function careerMPBankingBridgeSendOptOut(senderId, paymentData)
    local targetId = tonumber(paymentData.target_player_id)
    paymentData.reason = "optout"
    paymentData.target_player_id = targetId
    paymentData.target_player_name = paymentData.target_player_name or (targetId and MP.GetPlayerName(targetId)) or "That player"
    MP.TriggerClientEventJson(senderId, "careerMPBankingRxOptOut", paymentData)
end

local function careerMPBankingBridgeInstallPaymentHook()
    if careerMPBankingBridgeHookInstalled then
        return
    end

    if type(payPlayer) ~= "function" then
        if not careerMPBankingBridgeMissingPayPlayerLogged then
            print("[CareerMPBanking] ---------- CareerMP payPlayer was not found yet for the Banking app bridge")
            careerMPBankingBridgeMissingPayPlayerLogged = true
        end
        return
    end

    careerMPBankingBridgeOriginalPayPlayer = payPlayer

    function payPlayer(playerId, data)
        careerMPBankingBridgeRepairPaymentConfig()

        if Config and Config.server and Config.server.allowTransactions == false then
            return careerMPBankingBridgeOriginalPayPlayer(playerId, data)
        end

        local paymentData = careerMPBankingBridgeDecodeJson(data)
        local targetId = tonumber(paymentData.target_player_id)

        if targetId and not careerMPBankingBridgeIncomingEnabled(targetId) then
            careerMPBankingBridgeSendOptOut(playerId, paymentData)
            return
        end

        return careerMPBankingBridgeOriginalPayPlayer(playerId, data)
    end

    careerMPBankingBridgeHookInstalled = true
    if MP.CancelEventTimer then
        MP.CancelEventTimer("careerMPBankingAppBridgeTimer")
    end

    print("[CareerMPBanking] ---------- CareerMP Banking app bridge hooked payPlayer")
end

function careerMPBankingAppBridgeTimer()
    careerMPBankingBridgeInstallPaymentHook()
end

function careerMPBankingSetReceiveEnabled(playerId, data)
    local decoded = careerMPBankingBridgeDecodeJson(data)
    careerMPBankingBridgeReceiveEnabled[careerMPBankingBridgePlayerKey(playerId)] = decoded.enabled ~= false
end

function careerMPBankingAppBridgeOnPlayerJoin(playerId)
    careerMPBankingBridgeReceiveEnabled[careerMPBankingBridgePlayerKey(playerId)] = true
end

function careerMPBankingAppBridgeOnPlayerDisconnect(playerId)
    careerMPBankingBridgeReceiveEnabled[careerMPBankingBridgePlayerKey(playerId)] = nil
end

MP.RegisterEvent("careerMPBankingSetReceiveEnabled", "careerMPBankingSetReceiveEnabled")
MP.RegisterEvent("careerMPBankingAppBridgeTimer", "careerMPBankingAppBridgeTimer")
MP.RegisterEvent("onPlayerJoin", "careerMPBankingAppBridgeOnPlayerJoin")
MP.RegisterEvent("onPlayerDisconnect", "careerMPBankingAppBridgeOnPlayerDisconnect")

MP.CreateEventTimer("careerMPBankingAppBridgeTimer", 1000)
careerMPBankingBridgeInstallPaymentHook()
