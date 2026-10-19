local M = {}

M.dependencies = {"ui_router_routeManager"}

local routeSourceId = "rls-career-overhaul"

-- In 0.39 the Lua router is authoritative in release builds. Vue routes that
-- only exist in a mod are not discovered automatically (the built-in Vue route
-- sync is HMR-only), so every custom screen needs a matching runtime route.
local customRouteNames = {
  "business-computer",
  "card-games",
  "card-tester",
  "career.computer.enginePackages",
  "career.engineRetail",
  "career.milestones",
  "career.materialContractPickup",
  "career.passiveBusinessSupplyPickup",
  "career.engineShopSupplyPickup",
  "career.employeeShift",
  "career.employeeDropOff",
  "carMeetOffers",
  "car-meets-phone",
  "challenge-completed",
  "dakar",
  "garage-listing",
  "garage-listings",
  "garage-offers",
  "loans-menu",
  "maintenance",
  "phone-app-store",
  "phone-bank",
  "phone-bank-account",
  "phone-bank-rename",
  "phone-beam-eats",
  "phone-vehicle-transfer",
  "phone-camera",
  "phone-credit",
  "phone-dakar",
  "phone-events",
  "phone-facility-work",
  "phone-fre-contracts",
  "phone-gallery",
  "phone-guide",
  "phone-loan-details",
  "phone-loans",
  "phone-loan-settings",
  "phone-logistics",
  "phone-employment",
  "phone-main",
  "phone-marketplace",
  "phone-marketplace-negotiate",
  "phone-marketplace-sell",
  "phone-marketplace-vehicle",
  "phone-market-watch",
  "phone-minimap",
  "phone-notification-app-settings",
  "phone-notification-dnd",
  "phone-notification-lock-screen",
  "phone-notification-settings",
  "phone-obd-scanner",
  "phone-offroad-recovery",
  "phone-offer-details",
  "phone-quarry",
  "phone-racing-team",
  "phone-real-estate",
  "phone-rentals",
  "phone-repo",
  "phone-road-authority",
  "phone-settings",
  "phone-skills",
  "phone-skills-details",
  "phone-taxi",
  "phone-tuning-shop",
  "phone-travel-journal",
  "phone-weather",
  "purchase-business",
  "purchase-garage",
  "realEstateNegotiation",
  "roadside-service",
  "equipment-rental",
  "roleAssignment",
  "sleep-menu",
  "travel-journal",
  "used-car-auction",
}

-- Route-aware Back targets for the custom flat route names. BeamNG's Lua
-- router cannot infer parents for these names, so a blanket `play` target
-- breaks every nested phone flow (for example Bank -> Account -> Rename).
local routeBackTargets = {
  ["career.computer.enginePackages"] = "career.computer",
  ["career.engineRetail"] = "play",
  ["career.milestones"] = "career.domainSelection",
  ["career.materialContractPickup"] = "play",
  ["career.passiveBusinessSupplyPickup"] = "play",
  ["career.engineShopSupplyPickup"] = "play",
  ["career.employeeShift"] = "play",
  ["career.employeeDropOff"] = "play",
  ["challenge-completed"] = "play",
  ["roadside-service"] = "play",
  ["equipment-rental"] = "play",
  ["travel-journal"] = "play",
  ["garage-listings"] = "career.computer",
  ["garage-offers"] = "garage-listings",

  ["phone-main"] = "play",

  -- Top-level phone apps.
  ["car-meets-phone"] = "phone-main",
  ["phone-app-store"] = "phone-main",
  ["phone-bank"] = "phone-main",
  ["phone-beam-eats"] = "phone-main",
  ["phone-vehicle-transfer"] = "phone-main",
  ["phone-camera"] = "phone-main",
  ["phone-dakar"] = "phone-main",
  ["phone-events"] = "phone-main",
  ["phone-facility-work"] = "phone-main",
  ["phone-fre-contracts"] = "phone-main",
  ["phone-gallery"] = "phone-main",
  ["phone-guide"] = "phone-main",
  ["phone-loans"] = "phone-main",
  ["phone-logistics"] = "phone-main",
  ["phone-employment"] = "phone-main",
  ["phone-market-watch"] = "phone-main",
  ["phone-marketplace"] = "phone-main",
  ["phone-minimap"] = "phone-main",
  ["phone-obd-scanner"] = "phone-main",
  ["phone-quarry"] = "phone-main",
  ["phone-racing-team"] = "phone-main",
  ["phone-real-estate"] = "phone-main",
  ["phone-rentals"] = "phone-main",
  ["phone-offroad-recovery"] = "phone-main",
  ["phone-repo"] = "phone-main",
  ["phone-road-authority"] = "phone-main",
  ["phone-settings"] = "phone-main",
  ["phone-skills"] = "phone-main",
  ["phone-taxi"] = "phone-main",
  ["phone-tuning-shop"] = "phone-main",
  ["phone-travel-journal"] = "phone-main",
  ["phone-weather"] = "phone-main",

  -- Nested phone flows.
  ["phone-bank-account"] = "phone-bank",
  ["phone-bank-rename"] = "phone-bank-account",
  ["phone-credit"] = "phone-loans",
  ["phone-loan-details"] = "phone-loans",
  ["phone-loan-settings"] = "phone-loans",
  ["phone-offer-details"] = "phone-loans",
  ["phone-marketplace-sell"] = "phone-marketplace",
  ["phone-marketplace-negotiate"] = "phone-marketplace-sell",
  ["phone-marketplace-vehicle"] = "phone-marketplace",
  ["phone-notification-settings"] = "phone-settings",
  ["phone-notification-app-settings"] = "phone-notification-settings",
  ["phone-notification-lock-screen"] = "phone-notification-settings",
  ["phone-notification-dnd"] = "phone-notification-settings",
  ["phone-skills-details"] = "phone-skills",
}

-- Breadcrumb labels. Vanilla routes carry theirs as `title` on the Lua route
-- definition; without one the router falls back to the raw route id.
local routeTitles = {
  ["sleep-menu"] = "Sleep",
  ["loans-menu"] = "Loans",
  ["maintenance"] = "Maintenance",
  ["career.computer.enginePackages"] = "Engine Packages",
  ["career.engineRetail"] = "Engine Shop",
  ["business-computer"] = "Business Computer",
  ["garage-listings"] = "Garage Listings",
  ["garage-offers"] = "Garage Offers",
}

local function makeRoute(name)
  local backTarget = routeBackTargets[name] or "play"
  local luaRoute = {backTarget = backTarget, title = routeTitles[name]}
  if name == "career.materialContractPickup" then
    luaRoute.onLeave = "career_modules_delivery_cargoScreen.onMaterialContractPickupRouteLeave"
  elseif name == "career.passiveBusinessSupplyPickup" then
    luaRoute.onLeave = "career_modules_delivery_cargoScreen.onPassiveBusinessSupplyPickupRouteLeave"
  elseif name == "career.employeeShift" then
    luaRoute.onLeave = "career_modules_delivery_employment.onShiftRouteLeave"
  elseif name == "career.employeeDropOff" then
    luaRoute.onLeave = "career_modules_delivery_employment.onDropOffRouteLeave"
  end
  return {
    name = name,
    meta = {
      infoBar = {visible = false, showSysInfo = false},
      topBar = {visible = false},
      uiApps = {shown = false},
      luaRoute = luaRoute,
    },
  }
end

local function registerRoutes()
  if not ui_router_routeManager or not ui_router_routeManager.registerModRoutes then
    log("E", "overhaul_uiRoutes", "BeamNG 0.39 route manager is unavailable")
    return false
  end

  -- The vanilla tuning route inherits career.computer as its BACK target. A
  -- tuning tent has no computer screen, so route BACK through tuning cleanup;
  -- the handler dynamically returns to the computer for normal garages.
  local routes = {
    {
      name = "career.computer.tuning",
      meta = {
        luaRoute = {
          back = {mode = "handler", handler = "tuningExitHandler"},
        },
      },
    },
  }
  for _, name in ipairs(customRouteNames) do
    -- Never replace a vanilla/static definition if BeamNG gains one later.
    if not ui_router_routeManager.getRoute(name) then
      table.insert(routes, makeRoute(name))
    end
  end

  -- The Overhaul Manager is a legacy Angular state. Runtime routes default to
  -- Vue-only, so declare its UI type explicitly for BeamNG 0.39's router.
  if not ui_router_routeManager.getRoute("menu.overhaulManager") then
    table.insert(routes, {
      name = "menu.overhaulManager",
      meta = {
        uiTypes = {"angular"},
        uiTypesFilter = "only",
        infoBar = {visible = false, showSysInfo = false},
        topBar = {visible = false},
        uiApps = {shown = false},
        luaRoute = {backTarget = "menu"},
      },
    })
  end

  local result = ui_router_routeManager.registerModRoutes(routeSourceId, routes)
  if not result or result.success ~= true then
    log("E", "overhaul_uiRoutes", "Failed to register overhaul UI routes")
    return false
  end
  log("I", "overhaul_uiRoutes", string.format("Registered %d BeamNG 0.39 UI routes", #routes))
  return true
end

local function unregisterRoutes()
  if ui_router_routeManager and ui_router_routeManager.unregisterModRoutes then
    ui_router_routeManager.unregisterModRoutes(routeSourceId)
  end
end

M.onExtensionLoaded = registerRoutes
M.onExtensionUnloaded = unregisterRoutes
M.registerRoutes = registerRoutes
M.unregisterRoutes = unregisterRoutes

return M
