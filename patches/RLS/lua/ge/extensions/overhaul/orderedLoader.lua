local M = {}

local logTag = "RLSCareerMP39.OrderedLoader"
local running = false
local complete = false
local failedPhase = nil
local currentPhase = 0
local phaseAttempts = {}
local finalManualLoaded = {}
local stopping = false
local maxAttemptsPerPhase = 20
local retryDelay = 0.5

local phases = {
    {
        name = "rls-services",
        required = {
            "overhaul_settings",
            "overhaul_maps",
        },
        optional = {
            "overhaul_clearLevels",
            "overhaul_addMapChanges",
        },
    },
    {
        name = "career-foundation",
        required = {
            "career_modules_playerAttributes",
            "career_modules_propertyOwners",
            "career_modules_valueCalculator",
            "career_modules_payment",
            "career_modules_difficultyMode",
        },
        optional = {
            "career_modules_log",
            "career_modules_computer",
        },
    },
    {
        name = "property-chain",
        required = {
            "freeroam_facilities",
            "career_modules_garageManager",
            "career_modules_propertyMortgage",
            "career_modules_realEstateNegotiation",
        },
        optional = {},
    },
    {
        name = "inventory-economy",
        required = {
            "career_modules_inventory",
        },
        optional = {
            "career_modules_credit",
            "career_modules_loans",
            "career_modules_bank",
        },
    },
}

local function isLoaded(name)
    if type(extensions) ~= "table" then return false end
    local ext = rawget(extensions, name)
    if ext ~= nil then return true end
    if extensions.isExtensionLoaded then
        local ok, loaded = pcall(extensions.isExtensionLoaded, name)
        if ok and loaded then return true end
    end
    return false
end

local function requestLoad(name)
    if isLoaded(name) then return true end
    if not extensions or type(extensions.load) ~= "function" then return false end

    pcall(setExtensionUnloadMode, name, "manual")
    local ok, err = pcall(extensions.load, name)
    if not ok then
        log("W", logTag, "load request failed for " .. tostring(name) .. ": " .. tostring(err))
        return false
    end
    return isLoaded(name)
end

local function loadList(list)
    local missing = {}
    for _, name in ipairs(list or {}) do
        if not requestLoad(name) then
            missing[#missing + 1] = name
        end
    end
    return missing
end

local function join(list)
    if not list or #list == 0 then return "<none>" end
    return table.concat(list, ", ")
end

local function runPhase(index)
    local phase = phases[index]
    if not phase then return true end

    phaseAttempts[index] = (phaseAttempts[index] or 0) + 1
    local attempt = phaseAttempts[index]

    local missingRequired = loadList(phase.required)
    loadList(phase.optional)

    if #missingRequired == 0 then
        log("I", logTag,
            string.format("phase %d/%d ready: %s (attempt %d)",
                index, #phases, phase.name, attempt))
        return true
    end

    log("W", logTag,
        string.format("phase %d/%d waiting: %s (attempt %d/%d), missing: %s",
            index, #phases, phase.name, attempt, maxAttemptsPerPhase,
            join(missingRequired)))
    return false
end

local function snapshotLoadedExtensions()
    local result = {}
    if type(extensions) ~= "table" then return result end
    for name, ext in pairs(extensions) do
        if type(name) == "string" and ext ~= nil then
            result[name] = true
        end
    end
    return result
end

local function runBulkManualLoad()
    if type(loadManualUnloadExtensions) ~= "function" then
        log("E", logTag, "loadManualUnloadExtensions is unavailable")
        return false
    end

    local before = snapshotLoadedExtensions()
    local ok, err = xpcall(function()
        loadManualUnloadExtensions()
    end, debug.traceback)

    if not ok then
        log("E", logTag, "final manual-extension load failed: " .. tostring(err))
        return false
    end

    finalManualLoaded = {}
    local after = snapshotLoadedExtensions()
    for name in pairs(after) do
        if not before[name] then
            finalManualLoaded[#finalManualLoaded + 1] = name
        end
    end
    table.sort(finalManualLoaded)

    log("I", logTag,
        "final manual-extension load completed; tracked " ..
        tostring(#finalManualLoaded) .. " added extension(s)")
    return true
end

local function requestUnload(name)
    if not name or not extensions or type(extensions.unload) ~= "function" then return end
    if not isLoaded(name) then return end
    local ok, err = pcall(extensions.unload, name)
    if not ok then
        log("W", logTag, "unload failed for " .. tostring(name) .. ": " .. tostring(err))
    end
end

local function unloadListReverse(list)
    for index = #(list or {}), 1, -1 do
        requestUnload(list[index])
    end
end

function M.start(onComplete)
    if complete then
        if onComplete then pcall(onComplete, true) end
        return true
    end
    if running then return false end
    if not core_jobsystem or type(core_jobsystem.create) ~= "function" then
        log("E", logTag, "core_jobsystem unavailable")
        if onComplete then pcall(onComplete, false, "core_jobsystem") end
        return false
    end

    running = true
    failedPhase = nil
    currentPhase = 0
    phaseAttempts = {}

    core_jobsystem.create(function(job)
        log("I", logTag, "ordered RLS startup beginning")

        for index = 1, #phases do
            if stopping then
                running = false
                log("W", logTag, "ordered RLS startup cancelled during shutdown")
                if onComplete then pcall(onComplete, false, "cancelled") end
                return
            end
            currentPhase = index
            local ready = false

            for _ = 1, maxAttemptsPerPhase do
                if runPhase(index) then
                    ready = true
                    break
                end
                job.sleep(retryDelay)
            end

            if not ready then
                failedPhase = phases[index].name
                running = false
                log("E", logTag, "ordered RLS startup stopped at phase: " .. failedPhase)
                if onComplete then pcall(onComplete, false, failedPhase) end
                return
            end

            -- Give BeamNG one resolver turn between dependency layers.
            job.sleep(0.1)
        end

        currentPhase = #phases + 1
        if not runBulkManualLoad() then
            failedPhase = "remaining-manual-extensions"
            running = false
            if onComplete then pcall(onComplete, false, failedPhase) end
            return
        end

        complete = true
        running = false
        log("I", logTag, "ordered RLS startup complete")
        if onComplete then pcall(onComplete, true) end
    end)

    return true
end

function M.stop(reason)
    if stopping then return true end
    stopping = true

    log("I", logTag, "ordered RLS shutdown beginning" ..
        (reason and (" (" .. tostring(reason) .. ")") or ""))

    -- Modules discovered during the broad manual load are the leaves of the
    -- dependency graph. Remove them before tearing down their foundations.
    for index = #finalManualLoaded, 1, -1 do
        requestUnload(finalManualLoaded[index])
    end

    -- Tear the explicit dependency layers down in exact reverse startup order.
    for phaseIndex = #phases, 1, -1 do
        local phase = phases[phaseIndex]
        unloadListReverse(phase.optional)
        unloadListReverse(phase.required)
        log("I", logTag,
            string.format("shutdown phase %d/%d complete: %s",
                phaseIndex, #phases, phase.name))
    end

    finalManualLoaded = {}
    phaseAttempts = {}
    currentPhase = 0
    failedPhase = nil
    complete = false
    running = false
    stopping = false

    log("I", logTag, "ordered RLS shutdown complete")
    return true
end

function M.reset()
    finalManualLoaded = {}
    phaseAttempts = {}
    currentPhase = 0
    failedPhase = nil
    complete = false
    running = false
    stopping = false
end

function M.isRunning()
    return running
end

function M.isComplete()
    return complete
end

function M.getState()
    return {
        running = running,
        complete = complete,
        failedPhase = failedPhase,
        currentPhase = currentPhase,
        phaseAttempts = phaseAttempts,
        stopping = stopping,
        finalManualLoadedCount = #finalManualLoaded,
    }
end

return M
