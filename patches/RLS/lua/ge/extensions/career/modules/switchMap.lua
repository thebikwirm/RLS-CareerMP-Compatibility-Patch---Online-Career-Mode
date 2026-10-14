local M = {}

M.dependencies = {'career_career'}

local warnedMapsUnavailable = false

local function getMapsModule()
    if overhaul_maps and type(overhaul_maps.getOtherAvailableMaps) == "function" then
        return overhaul_maps
    end

    if type(extensions) == "table" then
        local ext = rawget(extensions, "overhaul_maps")
        if ext and type(ext.getOtherAvailableMaps) == "function" then
            return ext
        end
    end

    if not warnedMapsUnavailable then
        warnedMapsUnavailable = true
        log("W", "RLSCareerMP39",
            "switchMap deferred: overhaul_maps is not loaded yet")
    end
    return nil
end

local function getRouter()
    if type(extensions) == "table" then
        local router = rawget(extensions, "overhaul_mapRouter")
        if router then return router end
    end
    return overhaul_mapRouter
end

local function switchMap(destinationId)
    local router = getRouter()
    if router and type(router.route) == "function" then
        local ok, err = router.route(destinationId, {
            currentLevel = getCurrentLevelIdentifier(),
            source = "career_modules_switchMap"
        })
        if not ok then
            log("E", "RLSCareerMP39", "map route failed for " ..
                tostring(destinationId) .. ": " .. tostring(err))
        end
        return ok
    end

    -- Compatibility fallback if the router was not loaded for some reason.
    local currentLevel = getCurrentLevelIdentifier()
    if currentLevel == destinationId then return true end
    core_gamestate.requestEnterLoadingScreen("careerLoading")
    gameplay_parking.resetAll()
    career_career.switchCareerLevel(destinationId)
    return true
end

local function isOverhaulAddonActive(levelName)
    local mods = core_modmanager.getMods()
    for modName, modData in pairs(mods) do
        local OverhaulAddon = "rls_career_overhaul_" .. levelName
        if modName:lower():find(OverhaulAddon) and modData.active then
            return true
        end
    end
    return false
end

local function onBeamNGTrigger(data)
    if be:getPlayerVehicleID(0) ~= data.subjectID then
        return
    end
    if gameplay_walk.isWalking() then return end
    if career_career.isActive() and not career_modules_inventory.getInventoryIdFromVehicleId(data.subjectID) then return end
    if data.event ~= "exit" then
        return
    end
    local triggerName = data.triggerName

    if triggerName:match("^switchTo_") or triggerName:match("^switchMaps") then
        simTimeAuthority.pause(true)
        guihooks.trigger('ChangeState', {state = 'level-switch'})
        return
    end
end

function M.onGetRawPoiListForLevel(levelIdentifier, elements)
    local router = getRouter()
    local destinations = nil

    if router and type(router.getDestinations) == "function" then
        destinations = router.getDestinations({
            currentLevel = levelIdentifier,
            source = "career_modules_switchMap"
        })
    else
        local maps = getMapsModule()
        if not maps then return end

        destinations = {}
        local available = maps.getOtherAvailableMaps(levelIdentifier) or {}
        for level, label in pairs(available) do
            destinations[level] = {
                id = level,
                label = label,
                type = "local",
                transport = "local",
                level = level
            }
        end
    end

    if not destinations or not next(destinations) then return end
    warnedMapsUnavailable = false

    local switchToObj = scenetree.findObject("switchMaps")
    if not switchToObj then
        for id, destination in pairs(destinations) do
            local level = destination.level or id
            local obj = scenetree.findObject("switchTo_" .. tostring(level))
            if obj then
                switchToObj = obj
                break
            end
        end
    end

    if not switchToObj then return end

    local pos = switchToObj:getPosition()
    if not pos then return end

    local description = "Available destinations:\n"
    local rows = {}

    for id, destination in pairs(destinations) do
        rows[#rows + 1] = {
            id = destination.id or id,
            label = destination.label or tostring(id),
            type = destination.type or "local",
            server = destination.server
        }
    end

    table.sort(rows, function(a, b)
        return string.lower(a.label) < string.lower(b.label)
    end)

    for _, row in ipairs(rows) do
        if row.type == "server" and row.server then
            description = description .. "• " .. row.label .. " [" ..
                tostring(row.server) .. "]\n"
        else
            description = description .. "• " .. row.label .. "\n"
        end
    end

    local preview = "/levels/" .. levelIdentifier .. "/facilities/switchMap.jpg"
    local poi = {
        id = "map_switcher",
        data = {
            type = "travel",
            facility = {},
            destinations = rows
        },
        markerInfo = {
            bigmapMarker = {
                pos = pos,
                icon = "poi_fasttravel_round_orange_green",
                name = "Map / Server Travel",
                description = description,
                previews = {preview},
                thumbnail = preview
            }
        }
    }

    table.insert(elements, poi)
end

M.switchMap = switchMap
M.onBeamNGTrigger = onBeamNGTrigger

return M
