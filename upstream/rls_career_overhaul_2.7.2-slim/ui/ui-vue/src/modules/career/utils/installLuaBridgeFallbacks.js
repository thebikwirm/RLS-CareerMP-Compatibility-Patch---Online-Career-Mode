import { lua as luaImport } from "@/bridge"

const MOD_NAMESPACES = [
  "career_challengeModes",
  "career_modules_assignRole",
  "career_modules_bank",
  "career_modules_business_businessComputer",
  "career_modules_business_businessInventory",
  "career_modules_business_businessManager",
  "career_modules_business_businessPartCustomization",
  "career_modules_business_businessSkillTree",
  "career_modules_business_businessVehicleTuning",
  "career_modules_business_racingTeam",
  "career_modules_business_tuningShop",
  "career_modules_business_tuningShopKits",
  "career_modules_carmeets",
  "career_modules_carmeetRep",
  "career_modules_credit",
  "career_modules_delivery_employment",
  "career_modules_dynamicWeather",
  "career_modules_dynoSession",
  "career_modules_economyAdjusterPolicy",
  "career_modules_enginePackages",
  "career_modules_engineCertification",
  "career_modules_engineRetail",
  "career_modules_garageManager",
  "career_modules_globalEconomy",
  "career_modules_guide",
  "career_modules_hardcore",
  "career_modules_loans",
  "career_modules_maintenanceComputer",
  "career_modules_maintenanceMode",
  "career_modules_payment",
  "career_modules_playerAttributes",
  "career_modules_propertyMortgage",
  "career_modules_propertyRentals",
  "career_modules_realEstateNegotiation",
  "career_modules_roadsideServiceComputer",
  "career_modules_equipmentRental",
  "career_modules_sleep",
  "career_modules_switchMap",
  "career_modules_tutorial",
  "career_modules_usedCarAuction",
  "career_modules_xpAdjusterPolicy",
  "gameplay_beamEats",
  "gameplay_vehicleTransfer",
  "gameplay_cardGames",
  "gameplay_facilityWork",
  "gameplay_loading",
  "gameplay_offroadRecovery",
  "gameplay_phone",
  "gameplay_obdScanner",
  "gameplay_phoneCamera",
  "gameplay_repo",
  "gameplay_rlsTaxi",
  "guihooks",
  "overhaul_maps",
  "overhaul_rlsTesterMenu",
  "ui_phone_freContracts",
  "ui_phone_freeroamEvents",
  "ui_phone_layout",
  "ui_phone_logistics",
  "ui_phone_realEstate",
  "ui_phone_time",
]

const MOD_FUNCTIONS = ["ui_message"]

function getApi() {
  return window.bngApi || window.beamng
}

function serializeArgs(args) {
  const api = getApi()
  return args.map(arg => (typeof api?.serializeToLua === "function" ? api.serializeToLua(arg) : "nil")).join(", ")
}

export function callModLua(path, ...args) {
  const api = getApi()
  if (!api?.engineLua) return Promise.resolve(undefined)
  const serialized = serializeArgs(args)
  const parts = String(path || "").split(".")
  // Stub namespaces (e.g. career_modules_delivery_employment) can exist on the
  // JS bridge before Lua has loaded the extension. Indexing a nil global is a
  // fatal engine error, so resolve roots via rawget and skip missing methods.
  if (parts.length >= 2) {
    const root = parts[0]
    const method = parts.slice(1).join(".")
    const expr =
      `(function()` +
      ` local m=rawget(_G,${JSON.stringify(root)})` +
      ` if type(m)~="table" then return nil end` +
      ` local f=m[${JSON.stringify(method)}]` +
      ` if type(f)~="function" then return nil end` +
      ` return f(${serialized})` +
      ` end)()`
    return new Promise(resolve => {
      api.engineLua(expr, resolve)
    })
  }
  return new Promise(resolve => {
    api.engineLua(`${path}(${serialized})`, resolve)
  })
}

export function callModLuaIfAvailable(path, ...args) {
  const api = getApi()
  if (!api?.engineLua) return Promise.resolve(undefined)
  const separator = path.lastIndexOf(".")
  const namespace = separator > 0 ? path.slice(0, separator) : path
  return new Promise(resolve => {
    api.engineLua(
      `(${namespace} and ${path}) and ${path}(${serializeArgs(args)}) or nil`,
      resolve,
    )
  })
}

function luaTargets() {
  const targets = []
  if (luaImport) targets.push(luaImport)
  if (window.bridge?.lua && window.bridge.lua !== luaImport) targets.push(window.bridge.lua)
  return targets
}

function wrapNamespace(nsName, ns) {
  if (!ns || typeof ns !== "object") return ns
  if (ns.__overhaulProxy) return ns
  return new Proxy(ns, {
    get(target, prop, receiver) {
      if (prop === "__overhaulProxy") return true
      if (typeof prop === "symbol") return Reflect.get(target, prop, receiver)
      const value = Reflect.get(target, prop, receiver)
      if (typeof value === "function") return value.bind(target)
      if (value !== undefined) return value
      return (...args) => callModLua(`${nsName}.${String(prop)}`, ...args)
    },
  })
}

function patchLuaObject(lua) {
  if (!lua) return

  if (!lua.__overhaulBridgeInstalled) {
    for (const key of Object.keys(lua)) {
      if (lua[key] && typeof lua[key] === "object") {
        lua[key] = wrapNamespace(key, lua[key])
      }
    }
  }

  for (const name of MOD_NAMESPACES) {
    const current = lua[name]
    if (!current || typeof current !== "object") {
      lua[name] = wrapNamespace(name, {})
    } else if (!current.__overhaulProxy) {
      lua[name] = wrapNamespace(name, current)
    }
  }

  for (const name of MOD_FUNCTIONS) {
    if (typeof lua[name] !== "function") {
      lua[name] = (...args) => callModLua(name, ...args)
    }
  }

  lua.__overhaulBridgeInstalled = true
}

export function installLuaBridgeFallbacks() {
  for (const lua of luaTargets()) patchLuaObject(lua)
  return luaImport
}

installLuaBridgeFallbacks()
