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

-- Explicit high-level RLS consumers. These may already have been discovered by
-- BeamNG's career activation before the ordered loader takes its startup
-- snapshot, so they cannot be identified reliably as "newly added" modules.
-- Tear them down before inventory/property foundations disappear.
local shutdownLeaves = {
    "career_modules_business_tuningShopTechs",
    "career_modules_business_tuningShopKits",
    "career_modules_business_businessVehicleTuning",
    "career_modules_business_businessVehicleModificationUtil",
    "career_modules_business_businessPartCustomization",
    "career_modules_business_businessPartInventory",
    "career_modules_business_tuningShop",
    "career_modules_business_racingTeam",

    -- Consumers must unload before the business foundations they reference.
    "career_modules_vehicleShopping",
    "career_modules_business_businessComputer",
    "career_modules_business_businessSkillTree",
    "career_modules_business_businessTabRegistry",
    "career_modules_business_businessHelpers",
    "career_modules_business_businessInventory",
    "career_modules_business_businessManager",

    "career_modules_usedCarAuctionNpcs",
    "career_modules_usedCarAuctionLots",
    "career_modules_usedCarAuction",
    "career_modules_vehiclePopularity",
    "career_modules_rlsRentals",
    "career_modules_propertyRentals",
    "career_modules_marketplaceCustomers",
    "career_modules_carmeets",
    "career_modules_enforcement",
    "career_modules_damageManager",
    "career_modules_assignRole",
    "career_modules_globalEconomy",
    "career_modules_pauseTime",
    "career_modules_sleep",
    "career_modules_stamina",
    "career_modules_switchMap",
    "career_modules_insurance_repairScreen",
    "career_modules_insurance_insurance",
    "career_modules_maintenanceComputer",
    "career_modules_delivery_parcelManager",
    "career_modules_delivery_generator",
}

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

local function shouldTrackBulkExtension(name)
    if type(name) ~= "string" then return false end
    if name:find("^careerMP") or name:find("^multiplayer_") then return false end
    return
        name:find("^career_modules_") ~= nil or
        name:find("^gameplay_") ~= nil or
        name:find("^overhaul_") ~= nil or
        name:find("^ui_phone_") ~= nil or
        name == "dynamicRoutes" or
        name == "editor_dynamicRoutesEditor" or
        name == "editor_freeroamEventEditor" or
        name == "vehicleMaintenance"
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
        if not before[name] and shouldTrackBulkExtension(name) then
            finalManualLoaded[#finalManualLoaded + 1] = name
        end
    end
    table.sort(finalManualLoaded)

    log("I", logTag,
        "final manual-extension load completed; tracked " ..
        tostring(#finalManualLoaded) .. " added extension(s)")
    return true
end

-- Diagnostics for the two business dependencies still reported by BeamNG
-- during shutdown. Do not try to load a missing foundation while tearing down.
local shutdownDependencies = {
    career_modules_business_businessComputer = "career_modules_business_businessHelpers",
    career_modules_vehicleShopping = "career_modules_business_businessInventory",
}

local function requestUnload(name)
    if not name or not extensions or type(extensions.unload) ~= "function" then return end
    if not isLoaded(name) then return end

    local dependency = shutdownDependencies[name]
    if dependency then
        log("I", logTag, string.format(
            "shutdown consumer %s: dependency %s loaded=%s",
            name, dependency, tostring(isLoaded(dependency))))
    end

    local ok, err = pcall(extensions.unload, name)
    if not ok then
        log("W", logTag, "unload failed for " .. tostring(name) .. ": " .. tostring(err))
    elseif dependency then
        log("I", logTag, string.format(
            "shutdown consumer %s: loaded after request=%s; dependency loaded=%s",
            name, tostring(isLoaded(name)), tostring(isLoaded(dependency))))
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

    -- Explicit RLS leaf modules first. BeamNG may have loaded these during
    -- career activation before our bulk-load snapshot, so snapshot-only
    -- tracking is insufficient for a deterministic shutdown.
    for index = 1, #shutdownLeaves do
        requestUnload(shutdownLeaves[index])
    end

    -- Then unload any additional leaves that really were introduced by the
    -- final broad manual load.
    for index = #finalManualLoaded, 1, -1 do
        requestUnload(finalManualLoaded[index])
    end

    -- Tear profile-dependent dependency layers down in reverse startup order.
    -- Phase 1 (settings/maps) deliberately stays resident; it is profile
    -- independent and keeping it warm prevents switchMap/POI races on re-entry.
    for phaseIndex = #phases, 2, -1 do
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
