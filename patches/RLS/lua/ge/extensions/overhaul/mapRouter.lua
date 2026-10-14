local M = {}

local logTag = "RLSCareerMP39.MapRouter"

local providers = {}
local transports = {}
local defaultTransport = "local"

local function copyTable(src)
    local out = {}
    for k, v in pairs(src or {}) do out[k] = v end
    return out
end

function M.registerProvider(name, fn, priority)
    if type(name) ~= "string" or type(fn) ~= "function" then return false end
    providers[name] = {
        fn = fn,
        priority = tonumber(priority) or 0
    }
    return true
end

function M.unregisterProvider(name)
    providers[name] = nil
end

function M.registerTransport(name, fn)
    if type(name) ~= "string" or type(fn) ~= "function" then return false end
    transports[name] = fn
    return true
end

function M.unregisterTransport(name)
    transports[name] = nil
end

function M.setDefaultTransport(name)
    if transports[name] then
        defaultTransport = name
        return true
    end
    return false
end

local function providerOrder()
    local names = {}
    for name in pairs(providers) do names[#names + 1] = name end
    table.sort(names, function(a, b)
        local pa = providers[a].priority or 0
        local pb = providers[b].priority or 0
        if pa == pb then return a < b end
        return pa > pb
    end)
    return names
end

function M.getDestinations(context)
    local merged = {}

    for _, name in ipairs(providerOrder()) do
        local provider = providers[name]
        local ok, destinations = pcall(provider.fn, context or {})
        if ok and type(destinations) == "table" then
            for id, entry in pairs(destinations) do
                if type(entry) == "string" then
                    merged[id] = {
                        id = id,
                        label = entry,
                        type = "local",
                        level = id,
                        transport = "local"
                    }
                elseif type(entry) == "table" then
                    local item = copyTable(entry)
                    item.id = item.id or id
                    item.label = item.label or tostring(item.id)
                    item.type = item.type or "local"
                    item.transport = item.transport or item.type or defaultTransport
                    merged[item.id] = item
                end
            end
        elseif not ok then
            log("E", logTag, "destination provider '" .. name .. "' failed: " .. tostring(destinations))
        end
    end

    return merged
end

function M.route(destination, context)
    if type(destination) == "string" then
        destination = M.getDestinations(context)[destination]
    end
    if type(destination) ~= "table" then
        return false, "invalid destination"
    end

    local transportName = destination.transport or destination.type or defaultTransport
    local transport = transports[transportName]
    if not transport then
        return false, "no transport registered for " .. tostring(transportName)
    end

    log("I", logTag,
        "routing destination '" .. tostring(destination.id) ..
        "' via " .. tostring(transportName))

    local ok, result, err = pcall(transport, destination, context or {})
    if not ok then
        log("E", logTag, "transport '" .. tostring(transportName) .. "' threw: " .. tostring(result))
        return false, result
    end
    return result ~= false, err
end

-- Built-in local career map switch.
M.registerTransport("local", function(destination)
    local levelName = destination.level or destination.id
    if not levelName then return false, "missing level" end

    if getCurrentLevelIdentifier and getCurrentLevelIdentifier() == levelName then
        return true
    end

    core_gamestate.requestEnterLoadingScreen("careerLoading")
    if gameplay_parking and gameplay_parking.resetAll then
        gameplay_parking.resetAll()
    end
    career_career.switchCareerLevel(levelName)
    return true
end)

-- Built-in provider for the current RLS compatible map list.
M.registerProvider("rls-local-maps", function(context)
    local maps = nil
    if overhaul_maps and overhaul_maps.getOtherAvailableMaps then
        maps = overhaul_maps
    elseif type(extensions) == "table" then
        maps = rawget(extensions, "overhaul_maps")
    end
    if not maps or type(maps.getOtherAvailableMaps) ~= "function" then
        return {}
    end

    local currentLevel = context and context.currentLevel
    local available = maps.getOtherAvailableMaps(currentLevel) or {}
    local result = {}
    for level, label in pairs(available) do
        result[level] = {
            id = level,
            label = label,
            type = "local",
            transport = "local",
            level = level
        }
    end
    return result
end, 0)

return M
