-- CareerMP Party Shared Vehicles
-- Server-side v1 implementation:
-- - create party
-- - invite player
-- - accept invite
-- - leave party
-- - sync party state to clients

local DATA_DIR = "Resources/Server/CareerMPPartySharedVehicles/data/"
local DATA_PATH = DATA_DIR .. "state.json"

local state = {
    nextPartyId = 1,
    nextListingId = 1,
    nextLoanId = 1,
    nextPendingSaleId = 1,
    parties = {},
    invites = {},
    memberships = {},
    listings = {},
    loans = {},
    pendingSales = {},
}

local function decodeJson(data)
    local ok, decoded = pcall(Util.JsonDecode, data or "{}")
    if ok and type(decoded) == "table" then
        return decoded
    end

    return {}
end

local function trim(text)
    text = tostring(text or "")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return text
end

local function normalizeKey(text)
    return string.lower(trim(text))
end

local function ensureDataDir()
    if not FS.IsDirectory("Resources/Server/CareerMPPartySharedVehicles") then
        FS.CreateDirectory("Resources/Server/CareerMPPartySharedVehicles")
    end
    if not FS.IsDirectory(DATA_DIR) then
        FS.CreateDirectory(DATA_DIR)
    end
end

local function readJsonFile(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end

    local raw = file:read("*all")
    file:close()
    return decodeJson(raw)
end

local function writeJsonFile(path, value)
    local file = io.open(path, "w")
    if not file then
        return false
    end

    file:write(Util.JsonEncode(value))
    file:close()
    return true
end

local function normalizeState(candidate)
    candidate = type(candidate) == "table" and candidate or {}
    candidate.nextPartyId = tonumber(candidate.nextPartyId) or 1
    candidate.nextListingId = tonumber(candidate.nextListingId) or 1
    candidate.nextLoanId = tonumber(candidate.nextLoanId) or 1
    candidate.nextPendingSaleId = tonumber(candidate.nextPendingSaleId) or 1
    candidate.parties = type(candidate.parties) == "table" and candidate.parties or {}
    candidate.invites = type(candidate.invites) == "table" and candidate.invites or {}
    candidate.memberships = type(candidate.memberships) == "table" and candidate.memberships or {}
    candidate.listings = type(candidate.listings) == "table" and candidate.listings or {}
    candidate.loans = type(candidate.loans) == "table" and candidate.loans or {}
    candidate.pendingSales = {}
    return candidate
end

local function rebuildMemberships()
    local nextPartyId = 1
    local nextListingId = 1
    local nextLoanId = 1
    state.memberships = {}

    for partyId, party in pairs(state.parties) do
        local numericPartyId = tonumber(partyId) or 0
        if numericPartyId >= nextPartyId then
            nextPartyId = numericPartyId + 1
        end

        party.id = tostring(partyId)
        party.members = type(party.members) == "table" and party.members or {}
        party.sharedVehicles = type(party.sharedVehicles) == "table" and party.sharedVehicles or {}
        party.ownerKey = normalizeKey(party.ownerName or party.ownerKey or "")
        local normalizedMembers = {}
        for memberKey, member in pairs(party.members) do
            local normalizedMemberKey = normalizeKey(member.name or memberKey)
            if normalizedMemberKey ~= "" then
                member.key = normalizedMemberKey
                member.name = trim(member.name or memberKey)
                normalizedMembers[normalizedMemberKey] = member
                state.memberships[normalizedMemberKey] = tostring(partyId)
            end
        end
        party.members = normalizedMembers

        local normalizedSharedVehicles = {}
        for ownerKey, ownerBucket in pairs(party.sharedVehicles or {}) do
            local normalizedOwnerKey = normalizeKey(ownerKey)
            if normalizedOwnerKey ~= "" then
                normalizedSharedVehicles[normalizedOwnerKey] = {}
                for inventoryId, vehicle in pairs(ownerBucket or {}) do
                    local normalizedInventoryId = trim(inventoryId)
                    if normalizedInventoryId ~= "" then
                        normalizedSharedVehicles[normalizedOwnerKey][normalizedInventoryId] = {
                            inventoryId = normalizedInventoryId,
                            ownerKey = normalizedOwnerKey,
                            ownerName = trim(vehicle.ownerName or (normalizedMembers[normalizedOwnerKey] and normalizedMembers[normalizedOwnerKey].name) or ownerKey),
                            vehicleName = trim(vehicle.vehicleName or ("Vehicle " .. normalizedInventoryId)),
                            model = trim(vehicle.model or ""),
                            createdAt = tonumber(vehicle.createdAt) or os.time(),
                        }
                    end
                end
                if next(normalizedSharedVehicles[normalizedOwnerKey]) == nil then
                    normalizedSharedVehicles[normalizedOwnerKey] = nil
                end
            end
        end
        party.sharedVehicles = normalizedSharedVehicles
    end

    local normalizedListings = {}
    local normalizedLoans = {}
    local now = os.time()
    for listingId, listing in pairs(state.listings or {}) do
        local numericListingId = tonumber(listingId) or 0
        if numericListingId >= nextListingId then
            nextListingId = numericListingId + 1
        end

        local normalizedListingId = tostring(listingId)
        local sellerName = trim(listing.sellerName or "")
        local sellerKey = normalizeKey(listing.sellerKey or sellerName)
        local inventoryId = trim(listing.inventoryId)
        local vehicleName = trim(listing.vehicleName or ("Vehicle " .. inventoryId))
        local askingPrice = math.max(1, math.floor(tonumber(listing.askingPrice) or 0))

        if sellerKey ~= "" and inventoryId ~= "" and askingPrice > 0 then
            normalizedListings[normalizedListingId] = {
                id = normalizedListingId,
                sellerKey = sellerKey,
                sellerName = sellerName ~= "" and sellerName or sellerKey,
                inventoryId = inventoryId,
                vehicleName = vehicleName,
                model = trim(listing.model or ""),
                askingPrice = askingPrice,
                createdAt = tonumber(listing.createdAt) or os.time(),
                vehicleData = type(listing.vehicleData) == "table" and listing.vehicleData or nil,
            }
        end
    end

    for loanId, loan in pairs(state.loans or {}) do
        local numericLoanId = tonumber(loanId) or 0
        if numericLoanId >= nextLoanId then
            nextLoanId = numericLoanId + 1
        end

        local normalizedLoanId = tostring(loanId)
        local ownerName = trim(loan.ownerName or "")
        local borrowerName = trim(loan.borrowerName or "")
        local ownerKey = normalizeKey(loan.ownerKey or ownerName)
        local borrowerKey = normalizeKey(loan.borrowerKey or borrowerName)
        local inventoryId = trim(loan.inventoryId)
        local createdAt = tonumber(loan.createdAt) or now
        local durationMinutes = math.max(1, math.floor(tonumber(loan.durationMinutes) or 0))
        local expiresAt = math.floor(tonumber(loan.expiresAt) or 0)

        if ownerKey ~= "" and borrowerKey ~= "" and inventoryId ~= "" and type(loan.vehicleData) == "table" then
            if expiresAt <= 0 then
                expiresAt = createdAt + (durationMinutes * 60)
            end

            normalizedLoans[normalizedLoanId] = {
                id = normalizedLoanId,
                ownerKey = ownerKey,
                ownerName = ownerName ~= "" and ownerName or ownerKey,
                borrowerKey = borrowerKey,
                borrowerName = borrowerName ~= "" and borrowerName or borrowerKey,
                inventoryId = inventoryId,
                vehicleName = trim(loan.vehicleName or ("Vehicle " .. inventoryId)),
                model = trim(loan.model or ""),
                vehicleData = loan.vehicleData,
                createdAt = createdAt,
                durationMinutes = durationMinutes,
                expiresAt = expiresAt,
            }
        end
    end

    state.listings = normalizedListings
    state.loans = normalizedLoans
    state.nextPartyId = nextPartyId
    state.nextListingId = nextListingId
    state.nextLoanId = nextLoanId
end

local function saveState()
    ensureDataDir()
    writeJsonFile(DATA_PATH, state)
end

local function loadState()
    ensureDataDir()
    state = normalizeState(readJsonFile(DATA_PATH))
    rebuildMemberships()
end

local function eachConnectedPlayer(callback)
    for playerId in pairs(MP.GetPlayers() or {}) do
        callback(playerId, MP.GetPlayerName(playerId) or ("Player " .. tostring(playerId)))
    end
end

local function playerName(playerId)
    return trim(MP.GetPlayerName(playerId) or ("Player " .. tostring(playerId)))
end

local function playerKey(playerId)
    return normalizeKey(playerName(playerId))
end

local function findConnectedPlayerIdsByKey(key)
    local ids = {}
    eachConnectedPlayer(function(id, name)
        if normalizeKey(name) == key then
            table.insert(ids, id)
        end
    end)
    return ids
end

local function findPlayerIdByName(query)
    query = normalizeKey(query)
    if query == "" then
        return nil, "Please provide a player name."
    end

    local exactMatch = nil
    local partialMatches = {}

    eachConnectedPlayer(function(id, name)
        local key = normalizeKey(name)
        if key == query then
            exactMatch = id
            return
        end
        if string.find(key, query, 1, true) then
            table.insert(partialMatches, id)
        end
    end)

    if exactMatch then
        return exactMatch
    end
    if #partialMatches == 1 then
        return partialMatches[1]
    end
    if #partialMatches > 1 then
        return nil, "Multiple players match that name. Please be more specific."
    end

    return nil, "That player is not online."
end

local function getPartyIdForKey(key)
    return state.memberships[normalizeKey(key)]
end

local function getPartyForKey(key)
    local partyId = getPartyIdForKey(key)
    return partyId and state.parties[tostring(partyId)] or nil
end

local function isPlayerOnlineByKey(key)
    return #findConnectedPlayerIdsByKey(key) > 0
end

local function clearInvitesForParty(partyId)
    local partyIdString = tostring(partyId)
    for inviteeKey, inviteBucket in pairs(state.invites) do
        if type(inviteBucket) == "table" then
            inviteBucket[partyIdString] = nil
            if next(inviteBucket) == nil then
                state.invites[inviteeKey] = nil
            end
        end
    end
end

local function clearInvitesForPlayer(inviteeKey)
    state.invites[normalizeKey(inviteeKey)] = nil
end

local function buildSharedVehiclesView(party, viewerKey)
    local data = {
        own = {},
        borrowed = {},
        ownCount = 0,
        borrowedCount = 0,
        partyTotal = 0,
    }

    if not party then
        return data
    end

    for ownerKey, ownerBucket in pairs(party.sharedVehicles or {}) do
        local ownerName = (party.members[ownerKey] and party.members[ownerKey].name) or ownerBucket.ownerName or ownerKey
        for inventoryId, entry in pairs(ownerBucket or {}) do
            local vehicle = {
                key = ownerKey .. "::" .. tostring(inventoryId),
                inventoryId = tostring(inventoryId),
                ownerKey = ownerKey,
                ownerName = trim(entry.ownerName or ownerName),
                vehicleName = trim(entry.vehicleName or ("Vehicle " .. tostring(inventoryId))),
                model = trim(entry.model or ""),
                isOwner = ownerKey == viewerKey,
                createdAt = tonumber(entry.createdAt) or os.time(),
            }

            if ownerKey == viewerKey then
                table.insert(data.own, vehicle)
            else
                table.insert(data.borrowed, vehicle)
            end
        end
    end

    table.sort(data.own, function(left, right)
        return string.lower(left.vehicleName or "") < string.lower(right.vehicleName or "")
    end)
    table.sort(data.borrowed, function(left, right)
        if string.lower(left.ownerName or "") ~= string.lower(right.ownerName or "") then
            return string.lower(left.ownerName or "") < string.lower(right.ownerName or "")
        end
        return string.lower(left.vehicleName or "") < string.lower(right.vehicleName or "")
    end)

    data.ownCount = #data.own
    data.borrowedCount = #data.borrowed
    data.partyTotal = data.ownCount + data.borrowedCount
    return data
end

local function buildMarketplaceView(viewerKey)
    local data = {
        myListings = {},
        publicListings = {},
        listingCount = 0,
    }

    for listingId, listing in pairs(state.listings or {}) do
        local entry = {
            listingId = tostring(listingId),
            sellerKey = listing.sellerKey,
            sellerName = listing.sellerName,
            inventoryId = listing.inventoryId,
            vehicleName = listing.vehicleName,
            model = listing.model,
            thumbnail = trim(listing.thumbnail or ""),
            askingPrice = listing.askingPrice,
            createdAt = listing.createdAt,
            isOwn = listing.sellerKey == viewerKey,
        }

        if entry.isOwn then
            table.insert(data.myListings, entry)
        else
            table.insert(data.publicListings, entry)
        end
    end

    table.sort(data.myListings, function(left, right)
        return string.lower(left.vehicleName or "") < string.lower(right.vehicleName or "")
    end)
    table.sort(data.publicListings, function(left, right)
        if (left.askingPrice or 0) ~= (right.askingPrice or 0) then
            return (left.askingPrice or 0) < (right.askingPrice or 0)
        end
        return string.lower(left.vehicleName or "") < string.lower(right.vehicleName or "")
    end)

    data.listingCount = #data.myListings + #data.publicListings
    return data
end

local function buildLoansView(viewerKey)
    local data = {
        given = {},
        received = {},
        givenCount = 0,
        receivedCount = 0,
        total = 0,
    }
    local now = os.time()

    for loanId, loan in pairs(state.loans or {}) do
        local entry = {
            loanId = tostring(loanId),
            ownerKey = loan.ownerKey,
            ownerName = loan.ownerName,
            borrowerKey = loan.borrowerKey,
            borrowerName = loan.borrowerName,
            inventoryId = loan.inventoryId,
            vehicleName = loan.vehicleName,
            model = loan.model,
            durationMinutes = loan.durationMinutes,
            createdAt = loan.createdAt,
            expiresAt = loan.expiresAt,
            secondsRemaining = math.max(0, (tonumber(loan.expiresAt) or now) - now),
            ownerOnline = isPlayerOnlineByKey(loan.ownerKey),
            borrowerOnline = isPlayerOnlineByKey(loan.borrowerKey),
        }

        if loan.ownerKey == viewerKey then
            table.insert(data.given, entry)
        elseif loan.borrowerKey == viewerKey then
            entry.vehicleData = loan.vehicleData
            table.insert(data.received, entry)
        end
    end

    local function sortByExpiry(left, right)
        if (left.secondsRemaining or 0) ~= (right.secondsRemaining or 0) then
            return (left.secondsRemaining or 0) < (right.secondsRemaining or 0)
        end
        return string.lower(left.vehicleName or "") < string.lower(right.vehicleName or "")
    end

    table.sort(data.given, sortByExpiry)
    table.sort(data.received, sortByExpiry)

    data.givenCount = #data.given
    data.receivedCount = #data.received
    data.total = data.givenCount + data.receivedCount
    return data
end

local function buildPartyView(party, viewerKey)
    if not party then
        return nil
    end

    local members = {}
    for memberKey, member in pairs(party.members or {}) do
        table.insert(members, {
            key = memberKey,
            name = member.name,
            isOwner = memberKey == party.ownerKey,
            isSelf = memberKey == viewerKey,
            online = isPlayerOnlineByKey(memberKey),
        })
    end

    table.sort(members, function(left, right)
        if left.isOwner ~= right.isOwner then
            return left.isOwner
        end
        return string.lower(left.name) < string.lower(right.name)
    end)

    return {
        id = party.id,
        ownerName = party.ownerName,
        isOwner = party.ownerKey == viewerKey,
        members = members,
        memberCount = #members,
    }
end

local function buildInvitesView(inviteeKey)
    local invites = {}
    local bucket = state.invites[inviteeKey] or {}

    for partyId, invite in pairs(bucket) do
        local party = state.parties[tostring(partyId)]
        if party then
            table.insert(invites, {
                partyId = tostring(partyId),
                fromName = invite.fromName or party.ownerName,
            })
        end
    end

    table.sort(invites, function(left, right)
        return string.lower(left.fromName or "") < string.lower(right.fromName or "")
    end)

    return invites
end

local function buildStateForPlayer(playerId)
    local name = playerName(playerId)
    local key = normalizeKey(name)
    local party = getPartyForKey(key)

    return {
        selfName = name,
        party = buildPartyView(party, key),
        invites = buildInvitesView(key),
        sharedVehicles = buildSharedVehiclesView(party, key),
        marketplace = buildMarketplaceView(key),
        loaners = buildLoansView(key),
    }
end

local function sendJson(playerId, eventName, payload)
    MP.TriggerClientEventJson(playerId, eventName, payload or {})
end

local function sendNotice(playerId, title, message)
    sendJson(playerId, "careerMPPartySharedVehiclesRxNotice", {
        title = title,
        message = message,
    })
end

local function sendError(playerId, title, message)
    sendJson(playerId, "careerMPPartySharedVehiclesRxError", {
        title = title,
        message = message,
    })
end

local function cleanupExpiredLoans()
    local now = os.time()
    local expiredLoans = {}

    for loanId, loan in pairs(state.loans or {}) do
        if (tonumber(loan.expiresAt) or 0) <= now then
            state.loans[loanId] = nil
            table.insert(expiredLoans, loan)
        end
    end

    if #expiredLoans == 0 then
        return false
    end

    saveState()

    for _, loan in ipairs(expiredLoans) do
        for _, ownerId in ipairs(findConnectedPlayerIdsByKey(loan.ownerKey)) do
            sendNotice(ownerId, "Temporary keys expired", loan.vehicleName .. " is no longer loaned to " .. loan.borrowerName .. ".")
        end
        for _, borrowerId in ipairs(findConnectedPlayerIdsByKey(loan.borrowerKey)) do
            sendNotice(borrowerId, "Temporary keys expired", "Your access to " .. loan.vehicleName .. " from " .. loan.ownerName .. " has expired.")
        end
    end

    return true
end

local function sendState(playerId)
    cleanupExpiredLoans()
    sendJson(playerId, "careerMPPartySharedVehiclesRxState", buildStateForPlayer(playerId))
end

local function broadcastState()
    eachConnectedPlayer(function(id)
        sendState(id)
    end)
end

local function notifyPartyMembers(party, message, excludeKey)
    if not party then
        return
    end

    for memberKey, member in pairs(party.members or {}) do
        if memberKey ~= excludeKey then
            for _, memberId in ipairs(findConnectedPlayerIdsByKey(memberKey)) do
                sendNotice(memberId, "Party vehicles", message)
            end
        end
    end
end

local function removeListingsForSeller(sellerKey)
    local removedListingIds = {}
    sellerKey = normalizeKey(sellerKey)
    for listingId, listing in pairs(state.listings or {}) do
        if listing.sellerKey == sellerKey then
            state.listings[listingId] = nil
            table.insert(removedListingIds, tostring(listingId))
        end
    end
    return removedListingIds
end

local function removePendingSalesForPlayer(playerKey, reason)
    playerKey = normalizeKey(playerKey)
    local affectedPlayers = {}

    for pendingSaleId, sale in pairs(state.pendingSales or {}) do
        if sale.buyerKey == playerKey or sale.sellerKey == playerKey then
            state.pendingSales[pendingSaleId] = nil
            affectedPlayers[sale.buyerKey] = sale.buyerName
            affectedPlayers[sale.sellerKey] = sale.sellerName
        end
    end

    for affectedKey, affectedName in pairs(affectedPlayers) do
        if affectedKey ~= playerKey then
            for _, targetId in ipairs(findConnectedPlayerIdsByKey(affectedKey)) do
                sendError(targetId, "Marketplace", reason or "The pending sale was cancelled.")
            end
        end
    end
end

local function createPartyInternal(ownerPlayerId)
    local ownerName = playerName(ownerPlayerId)
    local ownerKey = playerKey(ownerPlayerId)

    if getPartyForKey(ownerKey) then
        return nil, "You are already in a party."
    end

    local partyId = tostring(state.nextPartyId)
    state.nextPartyId = state.nextPartyId + 1

    state.parties[partyId] = {
        id = partyId,
        ownerKey = ownerKey,
        ownerName = ownerName,
        sharedVehicles = {},
        members = {
            [ownerKey] = {
                key = ownerKey,
                name = ownerName,
            }
        }
    }

    rebuildMemberships()
    saveState()
    return state.parties[partyId]
end

local function addInviteInternal(inviterPlayerId, targetPlayerId)
    local inviterName = playerName(inviterPlayerId)
    local inviterKey = playerKey(inviterPlayerId)
    local targetName = playerName(targetPlayerId)
    local targetKey = playerKey(targetPlayerId)
    local party = getPartyForKey(inviterKey)

    if not party then
        return nil, "You are not in a party."
    end
    if party.ownerKey ~= inviterKey then
        return nil, "Only the party owner can invite players."
    end
    if targetKey == inviterKey then
        return nil, "You cannot invite yourself."
    end
    if getPartyForKey(targetKey) then
        return nil, targetName .. " is already in a party."
    end

    state.invites[targetKey] = state.invites[targetKey] or {}
    if state.invites[targetKey][party.id] then
        return nil, targetName .. " already has an invite to your party."
    end

    state.invites[targetKey][party.id] = {
        partyId = party.id,
        fromName = inviterName,
    }

    saveState()
    return party, targetName
end

local function acceptInviteInternal(playerId, preferredFromName)
    local name = playerName(playerId)
    local key = playerKey(playerId)
    local inviteBucket = state.invites[key]

    if getPartyForKey(key) then
        return nil, "You are already in a party."
    end
    if not inviteBucket or next(inviteBucket) == nil then
        return nil, "You do not have any pending invites."
    end

    local selectedInvite = nil
    local selectedParty = nil
    local preferredKey = normalizeKey(preferredFromName)

    for partyId, invite in pairs(inviteBucket) do
        local party = state.parties[tostring(partyId)]
        if party then
            local inviteOwnerKey = normalizeKey(invite.fromName or party.ownerName)
            if preferredKey == "" or preferredKey == inviteOwnerKey then
                if selectedInvite and preferredKey == "" then
                    return nil, "You have multiple invites. Specify the party owner name."
                end
                selectedInvite = invite
                selectedParty = party
                if preferredKey ~= "" then
                    break
                end
            end
        end
    end

    if not selectedInvite or not selectedParty then
        return nil, "That invite was not found."
    end

    selectedParty.members[key] = {
        key = key,
        name = name,
    }
    clearInvitesForPlayer(key)

    rebuildMemberships()
    saveState()
    return selectedParty
end

local function shareVehicleInternal(playerId, payload)
    local sharerName = playerName(playerId)
    local sharerKey = playerKey(playerId)
    local party = getPartyForKey(sharerKey)

    if not party then
        return nil, "You must be in a party to share vehicles."
    end

    local inventoryId = trim(payload.inventoryId)
    if inventoryId == "" then
        return nil, "A valid inventory ID is required."
    end

    local vehicleName = trim(payload.vehicleName)
    if vehicleName == "" then
        vehicleName = "Vehicle " .. inventoryId
    end

    party.sharedVehicles = type(party.sharedVehicles) == "table" and party.sharedVehicles or {}
    party.sharedVehicles[sharerKey] = party.sharedVehicles[sharerKey] or {}
    party.sharedVehicles[sharerKey][inventoryId] = {
        inventoryId = inventoryId,
        ownerKey = sharerKey,
        ownerName = sharerName,
        vehicleName = vehicleName,
        model = trim(payload.model or ""),
        createdAt = os.time(),
    }

    saveState()
    return party, party.sharedVehicles[sharerKey][inventoryId]
end

local function revokeVehicleInternal(playerId, payload)
    local sharerKey = playerKey(playerId)
    local party = getPartyForKey(sharerKey)

    if not party then
        return nil, "You must be in a party to revoke a shared vehicle."
    end

    local inventoryId = trim(payload.inventoryId)
    if inventoryId == "" then
        return nil, "A valid inventory ID is required."
    end

    local ownerBucket = party.sharedVehicles and party.sharedVehicles[sharerKey]
    if not ownerBucket or not ownerBucket[inventoryId] then
        return nil, "That vehicle is not currently shared with your party."
    end

    local removedVehicle = ownerBucket[inventoryId]
    ownerBucket[inventoryId] = nil
    if next(ownerBucket) == nil then
        party.sharedVehicles[sharerKey] = nil
    end

    saveState()
    return party, removedVehicle
end

local function removeSharedVehicleByOwnerAndInventory(ownerKey, inventoryId)
    ownerKey = normalizeKey(ownerKey)
    inventoryId = trim(inventoryId)
    if ownerKey == "" or inventoryId == "" then
        return
    end

    local party = getPartyForKey(ownerKey)
    if not party or not party.sharedVehicles or not party.sharedVehicles[ownerKey] then
        return
    end

    party.sharedVehicles[ownerKey][inventoryId] = nil
    if next(party.sharedVehicles[ownerKey]) == nil then
        party.sharedVehicles[ownerKey] = nil
    end
end

local function findLoanByOwnerAndInventory(ownerKey, inventoryId)
    ownerKey = normalizeKey(ownerKey)
    inventoryId = trim(inventoryId)

    for loanId, loan in pairs(state.loans or {}) do
        if loan.ownerKey == ownerKey and loan.inventoryId == inventoryId then
            return tostring(loanId), loan
        end
    end
end

local function removeLoansByOwnerAndInventory(ownerKey, inventoryId, title, ownerMessageBuilder, borrowerMessageBuilder)
    ownerKey = normalizeKey(ownerKey)
    inventoryId = trim(inventoryId)

    local removedLoans = {}
    for loanId, loan in pairs(state.loans or {}) do
        if loan.ownerKey == ownerKey and loan.inventoryId == inventoryId then
            state.loans[loanId] = nil
            table.insert(removedLoans, loan)
        end
    end

    if #removedLoans == 0 then
        return removedLoans
    end

    saveState()

    for _, loan in ipairs(removedLoans) do
        local ownerMessage = type(ownerMessageBuilder) == "function" and ownerMessageBuilder(loan) or ownerMessageBuilder
        local borrowerMessage = type(borrowerMessageBuilder) == "function" and borrowerMessageBuilder(loan) or borrowerMessageBuilder

        for _, ownerId in ipairs(findConnectedPlayerIdsByKey(loan.ownerKey)) do
            if ownerMessage then
                sendNotice(ownerId, title or "Temporary keys", ownerMessage)
            end
        end

        for _, borrowerId in ipairs(findConnectedPlayerIdsByKey(loan.borrowerKey)) do
            if borrowerMessage then
                sendNotice(borrowerId, title or "Temporary keys", borrowerMessage)
            end
        end
    end

    return removedLoans
end

local function findListingBySellerAndInventory(sellerKey, inventoryId)
    sellerKey = normalizeKey(sellerKey)
    inventoryId = trim(inventoryId)
    for listingId, listing in pairs(state.listings or {}) do
        if listing.sellerKey == sellerKey and listing.inventoryId == inventoryId then
            return tostring(listingId), listing
        end
    end
end

local function hasPendingSaleForListing(listingId)
    for _, sale in pairs(state.pendingSales or {}) do
        if sale.listingId == tostring(listingId) then
            return true
        end
    end
    return false
end

local function listVehicleInternal(playerId, payload)
    cleanupExpiredLoans()
    local sellerName = playerName(playerId)
    local sellerKey = playerKey(playerId)
    local inventoryId = trim(payload.inventoryId)
    local askingPrice = math.max(1, math.floor(tonumber(payload.askingPrice) or 0))

    if inventoryId == "" then
        return nil, "A valid inventory ID is required."
    end
    if askingPrice <= 0 then
        return nil, "Choose a valid asking price."
    end
    if type(payload.vehicleData) ~= "table" then
        return nil, "Vehicle snapshot data is required."
    end

    local existingListingId = findListingBySellerAndInventory(sellerKey, inventoryId)
    if existingListingId then
        return nil, "That vehicle is already listed in your dealership."
    end
    if findLoanByOwnerAndInventory(sellerKey, inventoryId) then
        return nil, "Revoke the temporary keys for that vehicle before listing it for sale."
    end

    local listingId = tostring(state.nextListingId)
    state.nextListingId = state.nextListingId + 1
    state.listings[listingId] = {
        id = listingId,
        sellerKey = sellerKey,
        sellerName = sellerName,
        inventoryId = inventoryId,
        vehicleName = trim(payload.vehicleName or ("Vehicle " .. inventoryId)),
        model = trim(payload.model or ""),
        thumbnail = trim(payload.thumbnail or payload.image or ""),
        askingPrice = askingPrice,
        createdAt = os.time(),
        vehicleData = payload.vehicleData,
    }

    saveState()
    return state.listings[listingId]
end

local function delistVehicleInternal(playerId, payload)
    local sellerKey = playerKey(playerId)
    local listingId = trim(payload.listingId)
    local listing = state.listings[listingId]

    if not listing or listing.sellerKey ~= sellerKey then
        return nil, "That listing is no longer available."
    end

    state.listings[listingId] = nil
    saveState()
    return listing
end

local function beginPurchaseInternal(playerId, payload)
    local buyerName = playerName(playerId)
    local buyerKey = playerKey(playerId)
    local listingId = trim(payload.listingId)
    local listing = state.listings[listingId]

    if not listing then
        return nil, "That listing is no longer available."
    end
    if listing.sellerKey == buyerKey then
        return nil, "You cannot buy your own listing."
    end
    if hasPendingSaleForListing(listingId) then
        return nil, "That listing is already being purchased by someone else."
    end

    local sellerIds = findConnectedPlayerIdsByKey(listing.sellerKey)
    if #sellerIds == 0 then
        return nil, "The seller is no longer online."
    end

    local pendingSaleId = tostring(state.nextPendingSaleId)
    state.nextPendingSaleId = state.nextPendingSaleId + 1
    local pendingSale = {
        id = pendingSaleId,
        listingId = listingId,
        buyerKey = buyerKey,
        buyerName = buyerName,
        sellerKey = listing.sellerKey,
        sellerName = listing.sellerName,
        inventoryId = listing.inventoryId,
        vehicleName = listing.vehicleName,
        model = listing.model,
        thumbnail = listing.thumbnail,
        askingPrice = listing.askingPrice,
        vehicleData = listing.vehicleData,
        buyerReady = false,
        sellerReady = false,
        createdAt = os.time(),
    }

    state.pendingSales[pendingSaleId] = pendingSale
    return pendingSale, sellerIds
end

local function grantLoanInternal(playerId, payload)
    cleanupExpiredLoans()
    local ownerName = playerName(playerId)
    local ownerKey = playerKey(playerId)
    local targetPlayerId, findError = findPlayerIdByName(payload.borrowerName or payload.targetName or payload.name)
    if not targetPlayerId then
        return nil, findError
    end

    local borrowerName = playerName(targetPlayerId)
    local borrowerKey = playerKey(targetPlayerId)
    local inventoryId = trim(payload.inventoryId)
    local durationMinutes = math.max(1, math.floor(tonumber(payload.durationMinutes) or 0))
    local vehicleData = type(payload.vehicleData) == "table" and payload.vehicleData or nil

    if inventoryId == "" then
        return nil, "Choose a valid vehicle first."
    end
    if not vehicleData then
        return nil, "Vehicle snapshot data is required."
    end
    if borrowerKey == ownerKey then
        return nil, "You cannot grant temporary keys to yourself."
    end
    if findListingBySellerAndInventory(ownerKey, inventoryId) then
        return nil, "Remove that vehicle from your dealership before granting temporary keys."
    end
    if findLoanByOwnerAndInventory(ownerKey, inventoryId) then
        return nil, "That vehicle already has an active temporary key grant."
    end

    local loanId = tostring(state.nextLoanId)
    state.nextLoanId = state.nextLoanId + 1
    state.loans[loanId] = {
        id = loanId,
        ownerKey = ownerKey,
        ownerName = ownerName,
        borrowerKey = borrowerKey,
        borrowerName = borrowerName,
        inventoryId = inventoryId,
        vehicleName = trim(payload.vehicleName or ("Vehicle " .. inventoryId)),
        model = trim(payload.model or ""),
        vehicleData = vehicleData,
        createdAt = os.time(),
        durationMinutes = durationMinutes,
        expiresAt = os.time() + (durationMinutes * 60),
    }

    saveState()
    return state.loans[loanId]
end

local function revokeLoanInternal(playerId, payload)
    local ownerKey = playerKey(playerId)
    local loanId = trim(payload.loanId)
    local loan = state.loans[loanId]

    if not loan or loan.ownerKey ~= ownerKey then
        return nil, "That temporary key grant is no longer available."
    end

    state.loans[loanId] = nil
    saveState()
    return loan
end

local function returnLoanInternal(playerId, payload)
    local borrowerKey = playerKey(playerId)
    local loanId = trim(payload.loanId)
    local loan = state.loans[loanId]

    if not loan or loan.borrowerKey ~= borrowerKey then
        return nil, "That borrowed vehicle access is no longer available."
    end

    state.loans[loanId] = nil
    saveState()
    return loan
end

local function cancelPendingSale(pendingSaleId, title, buyerMessage, sellerMessage)
    local sale = state.pendingSales[tostring(pendingSaleId)]
    if not sale then
        return
    end

    state.pendingSales[tostring(pendingSaleId)] = nil

    for _, buyerId in ipairs(findConnectedPlayerIdsByKey(sale.buyerKey)) do
        if buyerMessage then
            sendError(buyerId, title or "Marketplace", buyerMessage)
        end
    end

    for _, sellerId in ipairs(findConnectedPlayerIdsByKey(sale.sellerKey)) do
        if sellerMessage then
            sendError(sellerId, title or "Marketplace", sellerMessage)
        end
    end
end

local function maybeFinalizePendingSale(pendingSaleId)
    local sale = state.pendingSales[tostring(pendingSaleId)]
    if not sale or not sale.buyerReady or not sale.sellerReady then
        return
    end

    local listing = state.listings[sale.listingId]
    if not listing then
        cancelPendingSale(pendingSaleId, "Marketplace", "The listing disappeared before purchase could finish.", "The listing disappeared before purchase could finish.")
        return
    end

    removeSharedVehicleByOwnerAndInventory(sale.sellerKey, sale.inventoryId)
    removeLoansByOwnerAndInventory(
        sale.sellerKey,
        sale.inventoryId,
        "Temporary keys revoked",
        function(loan)
            return loan.vehicleName .. " was sold, so its temporary keys were closed."
        end,
        function(loan)
            return loan.vehicleName .. " was sold by " .. loan.ownerName .. ", so your temporary access was removed."
        end
    )
    state.listings[sale.listingId] = nil
    state.pendingSales[tostring(pendingSaleId)] = nil
    saveState()

    for _, buyerId in ipairs(findConnectedPlayerIdsByKey(sale.buyerKey)) do
        sendJson(buyerId, "careerMPPartyDealershipFinalizePurchase", {
            pendingSaleId = tostring(pendingSaleId),
            listingId = sale.listingId,
            sellerName = sale.sellerName,
            vehicleName = sale.vehicleName,
            askingPrice = sale.askingPrice,
            vehicleData = sale.vehicleData,
        })
        sendNotice(buyerId, "Vehicle purchased", "You bought " .. sale.vehicleName .. " from " .. sale.sellerName .. ".")
    end

    for _, sellerId in ipairs(findConnectedPlayerIdsByKey(sale.sellerKey)) do
        sendJson(sellerId, "careerMPPartyDealershipFinalizeSale", {
            pendingSaleId = tostring(pendingSaleId),
            listingId = sale.listingId,
            buyerName = sale.buyerName,
            inventoryId = sale.inventoryId,
            vehicleName = sale.vehicleName,
            askingPrice = sale.askingPrice,
        })
        sendNotice(sellerId, "Vehicle sold", sale.buyerName .. " bought " .. sale.vehicleName .. ".")
    end

    broadcastState()
end

local function leavePartyInternal(playerId)
    local name = playerName(playerId)
    local key = playerKey(playerId)
    local party = getPartyForKey(key)

    if not party then
        return nil, "You are not in a party."
    end

    if party.ownerKey == key then
        local memberNames = {}
        for _, member in pairs(party.members or {}) do
            if member.name ~= name then
                table.insert(memberNames, member.name)
            end
        end

        state.parties[party.id] = nil
        clearInvitesForParty(party.id)
        rebuildMemberships()
        saveState()
        return {
            disbanded = true,
            formerMembers = memberNames,
            party = party,
        }
    end

    if party.sharedVehicles then
        party.sharedVehicles[key] = nil
    end
    party.members[key] = nil
    rebuildMemberships()
    saveState()
    return {
        disbanded = false,
        party = party,
    }
end

function careerMPPartySharedVehiclesGetState(playerId, data)
    sendState(playerId)
end

function careerMPPartyCreate(playerId, data)
    local party, errorMessage = createPartyInternal(playerId)
    if not party then
        sendError(playerId, "Party", errorMessage)
        return
    end

    sendNotice(playerId, "Party created", "Your party is now active.")
    broadcastState()
end

function careerMPPartyInvite(playerId, data)
    local payload = decodeJson(data)
    local targetPlayerId, findError = findPlayerIdByName(payload.targetName or payload.name)
    if not targetPlayerId then
        sendError(playerId, "Party invite", findError)
        return
    end

    local party, targetNameOrError = addInviteInternal(playerId, targetPlayerId)
    if not party then
        sendError(playerId, "Party invite", targetNameOrError)
        return
    end

    local targetName = targetNameOrError
    sendNotice(playerId, "Invite sent", "Invite sent to " .. targetName .. ".")
    sendNotice(targetPlayerId, "Party invite", playerName(playerId) .. " invited you to a party.")
    broadcastState()
end

function careerMPPartyAcceptInvite(playerId, data)
    local payload = decodeJson(data)
    local party, errorMessage = acceptInviteInternal(playerId, payload.fromName)
    if not party then
        sendError(playerId, "Party invite", errorMessage)
        return
    end

    sendNotice(playerId, "Party joined", "You joined " .. party.ownerName .. "'s party.")
    for _, ownerId in ipairs(findConnectedPlayerIdsByKey(party.ownerKey)) do
        if ownerId ~= playerId then
            sendNotice(ownerId, "Party update", playerName(playerId) .. " joined your party.")
        end
    end
    broadcastState()
end

function careerMPPartyLeave(playerId, data)
    local result, errorMessage = leavePartyInternal(playerId)
    if not result then
        sendError(playerId, "Party", errorMessage)
        return
    end

    if result.disbanded then
        sendNotice(playerId, "Party disbanded", "You disbanded the party.")
        for _, memberName in ipairs(result.formerMembers or {}) do
            for _, memberId in ipairs(findConnectedPlayerIdsByKey(normalizeKey(memberName))) do
                sendNotice(memberId, "Party disbanded", "The party owner left, so the party was disbanded.")
            end
        end
    else
        sendNotice(playerId, "Party left", "You left the party.")
        for _, ownerId in ipairs(findConnectedPlayerIdsByKey(result.party.ownerKey)) do
            sendNotice(ownerId, "Party update", playerName(playerId) .. " left your party.")
        end
    end

    broadcastState()
end

function careerMPPartyShareVehicle(playerId, data)
    local payload = decodeJson(data)
    local party, vehicleOrError = shareVehicleInternal(playerId, payload)
    if not party then
        sendError(playerId, "Shared vehicles", vehicleOrError)
        return
    end

    sendNotice(playerId, "Vehicle shared", vehicleOrError.vehicleName .. " is now shared with your party.")
    notifyPartyMembers(party, playerName(playerId) .. " shared " .. vehicleOrError.vehicleName .. " with the party.", playerKey(playerId))
    broadcastState()
end

function careerMPPartyRevokeVehicle(playerId, data)
    local payload = decodeJson(data)
    local party, vehicleOrError = revokeVehicleInternal(playerId, payload)
    if not party then
        sendError(playerId, "Shared vehicles", vehicleOrError)
        return
    end

    sendNotice(playerId, "Vehicle revoked", vehicleOrError.vehicleName .. " is no longer shared with your party.")
    notifyPartyMembers(party, playerName(playerId) .. " revoked access to " .. vehicleOrError.vehicleName .. ".", playerKey(playerId))
    broadcastState()
end

function careerMPPartyListVehicle(playerId, data)
    local payload = decodeJson(data)
    local listing, errorMessage = listVehicleInternal(playerId, payload)
    if not listing then
        sendError(playerId, "Marketplace", errorMessage)
        return
    end

    sendNotice(playerId, "Dealership listing created", listing.vehicleName .. " is now listed for $" .. tostring(listing.askingPrice) .. ".")
    broadcastState()
end

function careerMPPartyDelistVehicle(playerId, data)
    local payload = decodeJson(data)
    local listing, errorMessage = delistVehicleInternal(playerId, payload)
    if not listing then
        sendError(playerId, "Marketplace", errorMessage)
        return
    end

    sendNotice(playerId, "Listing removed", listing.vehicleName .. " was removed from your dealership.")
    broadcastState()
end

function careerMPPartyBuyListing(playerId, data)
    local payload = decodeJson(data)
    local sale, sellerIdsOrError = beginPurchaseInternal(playerId, payload)
    if not sale then
        sendError(playerId, "Marketplace", sellerIdsOrError)
        return
    end

    sendJson(playerId, "careerMPPartyDealershipPreparePurchase", {
        pendingSaleId = sale.id,
        listingId = sale.listingId,
        sellerName = sale.sellerName,
        vehicleName = sale.vehicleName,
        askingPrice = sale.askingPrice,
    })

    for _, sellerId in ipairs(sellerIdsOrError) do
        sendJson(sellerId, "careerMPPartyDealershipPrepareSale", {
            pendingSaleId = sale.id,
            listingId = sale.listingId,
            buyerName = sale.buyerName,
            inventoryId = sale.inventoryId,
            vehicleName = sale.vehicleName,
            askingPrice = sale.askingPrice,
        })
    end
end

function careerMPPartyGrantLoan(playerId, data)
    local payload = decodeJson(data)
    local loan, errorMessage = grantLoanInternal(playerId, payload)
    if not loan then
        sendError(playerId, "Temporary keys", errorMessage)
        return
    end

    sendNotice(playerId, "Temporary keys granted", "You shared " .. loan.vehicleName .. " with " .. loan.borrowerName .. " for " .. tostring(loan.durationMinutes) .. " minute(s).")
    for _, borrowerId in ipairs(findConnectedPlayerIdsByKey(loan.borrowerKey)) do
        sendNotice(borrowerId, "Temporary keys received", loan.ownerName .. " shared " .. loan.vehicleName .. " with you for " .. tostring(loan.durationMinutes) .. " minute(s).")
    end
    broadcastState()
end

function careerMPPartyRevokeLoan(playerId, data)
    local payload = decodeJson(data)
    local loan, errorMessage = revokeLoanInternal(playerId, payload)
    if not loan then
        sendError(playerId, "Temporary keys", errorMessage)
        return
    end

    sendNotice(playerId, "Temporary keys revoked", "You revoked access to " .. loan.vehicleName .. ".")
    for _, borrowerId in ipairs(findConnectedPlayerIdsByKey(loan.borrowerKey)) do
        sendNotice(borrowerId, "Temporary keys revoked", loan.ownerName .. " revoked your access to " .. loan.vehicleName .. ".")
    end
    broadcastState()
end

function careerMPPartyReturnLoan(playerId, data)
    local payload = decodeJson(data)
    local loan, errorMessage = returnLoanInternal(playerId, payload)
    if not loan then
        sendError(playerId, "Temporary keys", errorMessage)
        return
    end

    sendNotice(playerId, "Vehicle returned", "You returned access to " .. loan.vehicleName .. ".")
    for _, ownerId in ipairs(findConnectedPlayerIdsByKey(loan.ownerKey)) do
        sendNotice(ownerId, "Vehicle returned", loan.borrowerName .. " returned " .. loan.vehicleName .. ".")
    end
    broadcastState()
end

function careerMPPartySaleBuyerReady(playerId, data)
    local payload = decodeJson(data)
    local sale = state.pendingSales[tostring(payload.pendingSaleId)]
    if not sale or sale.buyerKey ~= playerKey(playerId) then
        return
    end

    sale.buyerReady = true
    maybeFinalizePendingSale(payload.pendingSaleId)
end

function careerMPPartySaleBuyerAbort(playerId, data)
    local payload = decodeJson(data)
    local sale = state.pendingSales[tostring(payload.pendingSaleId)]
    if not sale or sale.buyerKey ~= playerKey(playerId) then
        return
    end

    cancelPendingSale(payload.pendingSaleId, "Marketplace", payload.reason or "Purchase cancelled.", sale.buyerName .. " could not complete the purchase.")
    broadcastState()
end

function careerMPPartySaleSellerReady(playerId, data)
    local payload = decodeJson(data)
    local sale = state.pendingSales[tostring(payload.pendingSaleId)]
    if not sale or sale.sellerKey ~= playerKey(playerId) then
        return
    end

    sale.sellerReady = true
    if type(payload.vehicleData) == "table" then
        sale.vehicleData = payload.vehicleData
    end
    maybeFinalizePendingSale(payload.pendingSaleId)
end

function careerMPPartySaleSellerAbort(playerId, data)
    local payload = decodeJson(data)
    local sale = state.pendingSales[tostring(payload.pendingSaleId)]
    if not sale or sale.sellerKey ~= playerKey(playerId) then
        return
    end

    cancelPendingSale(payload.pendingSaleId, "Marketplace", sale.sellerName .. " could not complete that sale.", payload.reason or "Sale cancelled.")
    broadcastState()
end

function careerMPPartySharedVehiclesReset(playerId, data)
    state = normalizeState({})
    rebuildMemberships()
    saveState()
    sendNotice(playerId, "Party reset", "The party state file was reset.")
    broadcastState()
end

function careerMPPartySharedVehiclesOnPlayerJoin(playerId)
    sendState(playerId)
    broadcastState()
end

function careerMPPartySharedVehiclesOnPlayerDisconnect(playerId)
    removeListingsForSeller(playerKey(playerId))
    removePendingSalesForPlayer(playerKey(playerId), "The other player disconnected, so the pending sale was cancelled.")
    saveState()
    broadcastState()
end

loadState()
cleanupExpiredLoans()

MP.RegisterEvent("careerMPPartySharedVehiclesGetState", "careerMPPartySharedVehiclesGetState")
MP.RegisterEvent("careerMPPartyCreate", "careerMPPartyCreate")
MP.RegisterEvent("careerMPPartyInvite", "careerMPPartyInvite")
MP.RegisterEvent("careerMPPartyAcceptInvite", "careerMPPartyAcceptInvite")
MP.RegisterEvent("careerMPPartyLeave", "careerMPPartyLeave")
MP.RegisterEvent("careerMPPartyShareVehicle", "careerMPPartyShareVehicle")
MP.RegisterEvent("careerMPPartyRevokeVehicle", "careerMPPartyRevokeVehicle")
MP.RegisterEvent("careerMPPartyListVehicle", "careerMPPartyListVehicle")
MP.RegisterEvent("careerMPPartyDelistVehicle", "careerMPPartyDelistVehicle")
MP.RegisterEvent("careerMPPartyBuyListing", "careerMPPartyBuyListing")
MP.RegisterEvent("careerMPPartyGrantLoan", "careerMPPartyGrantLoan")
MP.RegisterEvent("careerMPPartyRevokeLoan", "careerMPPartyRevokeLoan")
MP.RegisterEvent("careerMPPartyReturnLoan", "careerMPPartyReturnLoan")
MP.RegisterEvent("careerMPPartySaleBuyerReady", "careerMPPartySaleBuyerReady")
MP.RegisterEvent("careerMPPartySaleBuyerAbort", "careerMPPartySaleBuyerAbort")
MP.RegisterEvent("careerMPPartySaleSellerReady", "careerMPPartySaleSellerReady")
MP.RegisterEvent("careerMPPartySaleSellerAbort", "careerMPPartySaleSellerAbort")
MP.RegisterEvent("careerMPPartySharedVehiclesReset", "careerMPPartySharedVehiclesReset")
MP.RegisterEvent("onPlayerJoin", "careerMPPartySharedVehiclesOnPlayerJoin")
MP.RegisterEvent("onPlayerDisconnect", "careerMPPartySharedVehiclesOnPlayerDisconnect")

print("[CareerMPPartySharedVehicles] ---------- Party module loaded")
