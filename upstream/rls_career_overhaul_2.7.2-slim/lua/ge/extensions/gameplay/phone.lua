local M = {}

local speedUnit = 2.2369362921

local isPhoneOpen = false
local isClosing = false
local suppressOpenUntil = 0
local updateTimer = 0
local updateInterval = 2.5

local closePhone

local function nowTime()
    if os and os.clock then
        return os.clock()
    end
    return 0
end

local function suppressOpensFor(seconds)
    local untilT = nowTime() + (tonumber(seconds) or 2)
    if untilT > suppressOpenUntil then
        suppressOpenUntil = untilT
    end
end

local function opensSuppressed()
    return isClosing or nowTime() < suppressOpenUntil
end

local function getCurrentRouteName()
    if type(extensions) ~= "table" or type(extensions.ui_router) ~= "table"
        or type(extensions.ui_router.getCurrent) ~= "function" then
        return nil
    end
    local current = extensions.ui_router.getCurrent()
    if not current then
        return nil
    end
    if current.resolved and type(current.resolved.name) == "string" then
        return current.resolved.name
    end
    if current.request and type(current.request.name) == "string" then
        return current.request.name
    end
    if current.toRoute and type(current.toRoute.name) == "string" then
        return current.toRoute.name
    end
    return nil
end

local function isComputerRouteName(name)
    if type(name) ~= "string" then
        return false
    end
    if name == "career.computer" or name:find("^career%.computer%.", 1) then
        return true
    end
    if name == "business-computer" then
        return true
    end
    return false
end

local function isComputerMenuOpen()
    if isComputerRouteName(getCurrentRouteName()) then
        return true
    end
    if career_modules_partShopping and career_modules_partShopping.isShoppingSessionActive
        and career_modules_partShopping.isShoppingSessionActive() then
        return true
    end
    return false
end

local function notifyCloseComputerToOpenPhone()
    guihooks.trigger("toastrMsg", {
        type = "info",
        title = "Phone",
        msg = "Close the computer to open the phone.",
    })
end

local function blockPhoneIfComputerOpen()
    if not isComputerMenuOpen() then
        return false
    end
    notifyCloseComputerToOpenPhone()
    return true
end

local function isPhoneUiAllowed()
    local routeName = getCurrentRouteName()
    if type(routeName) == "string" then
        if routeName == "menu" or routeName:find("^menu%.") == 1 then
            return false
        end
        if routeName:find("^career%.profiles") == 1 then
            return false
        end
    end
    local gs = core_gamestate and core_gamestate.state
    if type(gs) == "table" and gs.state == "menu" then
        return false
    end
    return true
end

local function isPhoneRouteName(name)
    if type(name) ~= "string" then
        return false
    end
    if name == "car-meets-phone" then
        return true
    end
    return name:find("^phone%-") == 1
end

local function navigateToPlay()
    if type(extensions) == "table" and type(extensions.ui_router) == "table"
        and type(extensions.ui_router.navigate) == "function" then
        extensions.ui_router.navigate("play")
    end
end

closePhone = function()
    local onPhoneRoute = isPhoneRouteName(getCurrentRouteName())
    if not isPhoneOpen and not onPhoneRoute and not isClosing then
        return
    end
    isPhoneOpen = false
    isClosing = true
    suppressOpensFor(2.5)
    guihooks.trigger('closePhone')
    if onPhoneRoute or isPhoneRouteName(getCurrentRouteName()) then
        navigateToPlay()
    end
end

local function togglePhone(reason)
    if isPhoneOpen or isPhoneRouteName(getCurrentRouteName()) or isClosing then
        closePhone()
        return
    end
    if opensSuppressed() then
        return
    end
    if not isPhoneUiAllowed() then
        return
    end
    if blockPhoneIfComputerOpen() then
        return
    end
    local playerVehId = be:getPlayerVehicleID(0)
    local playerSpeed = 0
    if playerVehId and playerVehId >= 0 then
        playerSpeed = math.abs(be:getObjectVelocityXYZ(playerVehId)) * speedUnit
    end
    local inTaxiRide = gameplay_taxi and gameplay_taxi.isTaxiRideActive and gameplay_taxi.isTaxiRideActive()
    if (not inTaxiRide) and playerSpeed > 5 then
        if reason then
            ui_message(reason, 5, "info", "info")
        else
            ui_message("You must be stationary to open the phone.", 3, "info", "info")
        end
        return
    end
    isClosing = false
    isPhoneOpen = true
    if gameplay_rlsTaxi and gameplay_rlsTaxi.isTaxiJobActive and gameplay_rlsTaxi.isTaxiJobActive() then
        extensions.ui_router.navigate('phone-taxi')
    else
        extensions.ui_router.navigate('phone-main')
    end
end

local function onExtensionLoaded()
    isPhoneOpen = false
    isClosing = false
    suppressOpenUntil = 0
    print("Phone extension loaded")
end

local function onUpdate(dt)
    updateTimer = updateTimer + dt
    if updateTimer > updateInterval then
        updateTimer = 0
        if isPhoneOpen and not isClosing then
            local walking = gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking()
            if not walking then
                local playerSpeed = math.abs(be:getObjectVelocityXYZ(be:getPlayerVehicleID(0))) * speedUnit
                local inTaxiRide = gameplay_taxi and gameplay_taxi.isTaxiRideActive and gameplay_taxi.isTaxiRideActive()
                if (not inTaxiRide) and playerSpeed > 5 then
                    ui_message("Phone closed due to player movement.", 3, "info", "info")
                    closePhone()
                end
            end
        end
    end
end

M.onUIPlayStateChanged = function(changed)
    if changed then
        isPhoneOpen = false
        isClosing = false
    end
end

local function markClosed()
    isPhoneOpen = false
end

local function markOpen()
    if opensSuppressed() or isClosing then
        return
    end
    isPhoneOpen = true
    isClosing = false
end

local function openRoute(routeName, params)
    if type(routeName) ~= "string" or routeName == "" then
        return {success = false, reason = "invalid_route"}
    end
    if opensSuppressed() then
        return {success = false, reason = "opening_suppressed"}
    end
    if not isPhoneUiAllowed() then
        return {success = false, reason = "ui_not_ready"}
    end
    if blockPhoneIfComputerOpen() then
        return {success = false, reason = "computer_open"}
    end

    isClosing = false
    isPhoneOpen = true
    local result = extensions.ui_router.navigate(routeName, params or {})
    if result and result.success == false then
        isPhoneOpen = false
    end
    return result
end

local function openForTutorial()
    if opensSuppressed() then
        return false
    end
    if not (career_career and career_career.isActive and career_career.isActive()) then
        return false
    end
    if gameplay_vehicleTransfer and gameplay_vehicleTransfer.isOnShift and gameplay_vehicleTransfer.isOnShift() then
        return false
    end
    if not isPhoneUiAllowed() then
        return false
    end
    if blockPhoneIfComputerOpen() then
        return false
    end
    isClosing = false
    isPhoneOpen = true
    if gameplay_rlsTaxi and gameplay_rlsTaxi.isTaxiJobActive and gameplay_rlsTaxi.isTaxiJobActive() then
        extensions.ui_router.navigate('phone-taxi')
    else
        extensions.ui_router.navigate('phone-main')
    end
    return true
end

M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded
M.togglePhone = togglePhone
M.closePhone = closePhone
M.markClosed = markClosed
M.markOpen = markOpen
M.openRoute = openRoute
M.openForTutorial = openForTutorial
M.isPhoneOpen = function()
    return isPhoneOpen and not isClosing
end
M.isComputerMenuOpen = isComputerMenuOpen
M.isPhoneUiAllowed = isPhoneUiAllowed

return M
