import { ref } from "vue"
import { defineStore } from "pinia"
import { roundDec, round } from "@/utils/maths"
import { useBridge } from "@/bridge"

export const useTuningStore = defineStore("tuning", () => {
  const { lua, events } = useBridge()

  const buckets = ref({})
  const tuningVariables = ref({})
  let editedTuningVars = {}

  let isCareer = false
  const shoppingData = ref({})

  const noapi = () => {
    throw new Error("Tuning store must be initialised first")
  }
  let api = {
    request: noapi,
    apply: noapi,
    reset: noapi,
    close: () => {},
    menuClose: () => {},
  }

  async function init() {
    editedTuningVars = {}
    isCareer = await lua.career_career.isActive()
    if (isCareer) {
      api.request = async () => processTuningData(await lua.career_modules_tuning.getTuningData())
      api.apply = (values, edited) => {
        const res = {}
        for (const [varName] of Object.entries(edited)) {
          if (values[varName]) res[varName] = valDisToVal(values[varName])
        }
        lua.career_modules_tuning.apply(res)
      }
      api.reset = () => {}
      api.close = () => {
        events.off("sendTuningShoppingData", setShoppingData)
        events.off("updateTuningVariable", updateTuningVariable)
        shoppingData.value = {}
      }

      events.on("sendTuningShoppingData", setShoppingData)
      events.on("updateTuningVariable", updateTuningVariable)
    } else {
      api.request = async () => await lua.extensions.core_vehicle_partmgmt.sendDataToUI()
      api.apply = (values, edited) => {
        const res = {}
        for (const varName in values) res[varName] = valDisToVal(values[varName])
        lua.extensions.core_vehicle_partmgmt.setConfigVars(res)
      }
      api.reset = async () => await lua.extensions.core_vehicle_partmgmt.resetVarsToLoadedConfig()
      api.close = () => {
        events.off("VehicleFocusChanged", api.request)
        events.off("VehicleConfigChange", processTuningData)
      }
      api.menuClose = api.close
      events.on("VehicleFocusChanged", api.request)
      events.on("VehicleConfigChange", processTuningData)
    }
    for (const name in api) {
      if (api[name] === noapi) api[name] = () => {}
    }
  }

  function apply() {
    api.apply(tuningVariables.value, editedTuningVars)
    editedTuningVars = {}
  }

  function setShoppingData(data) {
    shoppingData.value = data
  }

  function updateTuningVariable(tuningVar) {
    if (tuningVariables.value[tuningVar.name]) {
      tuningVariables.value[tuningVar.name].valDis = Number(valToValDis(tuningVar))
    }
  }

  const processTuningData = data => {
    if (!data) {
      tuningVariables.value = {}
      buckets.value = []
      return
    }
    if (data.variables) data = data.variables

    if (isCareer) {
      delete data["$fuel"]
      delete data["$fuel_R"]
      delete data["$fuel_L"]
    }

    const newBuckets = []
    const newTuningVariables = {}

    for (const varData of Object.values(data)) {
      if ((isCareer && varData.category === "Cargo") || varData.hideInUI) continue

      if (!varData.category) varData.category = "Other"
      if (!varData.subCategory) varData.subCategory = "Other"

      const cat = (newBuckets.find(cat => cat.name === varData.category) || newBuckets[newBuckets.push({ name: varData.category, items: [] }) - 1]).items
      const list = (cat.find(sub => sub.name === varData.subCategory) || cat[cat.push({ name: varData.subCategory, items: [] }) - 1]).items
      list.push(varData)

      newTuningVariables[varData.name] = {
        valDis: Number(valToValDis(varData)),
        minDis: varData.minDis,
        maxDis: varData.maxDis,
        min: varData.min,
        max: varData.max,
        default: Number(valToValDis(varData, true)),
      }
    }

    const sorter = (a, b) => a.name.localeCompare(b.name)
    newBuckets.sort(sorter)
    for (const cat of newBuckets) {
      cat.items.sort(sorter)
      for (const sub of cat.items) sub.items.sort(sorter)
    }

    tuningVariables.value = newTuningVariables
    buckets.value = newBuckets
  }

  function countDecimals(num) {
    if (typeof num !== "number" || ~~num === num) return 0
    return num.toString().split(".")[1].length || 0
  }

  function valToValDis(varData, useDef = false) {
    const vData = ((useDef ? varData.default : varData.val) - varData.min) / (varData.max - varData.min)
    return roundDec(round(vData * (varData.maxDis - varData.minDis), varData.stepDis) + varData.minDis, countDecimals(varData.stepDis))
  }

  function valDisToVal(varData) {
    const vData = (varData.valDis - varData.minDis) / (varData.maxDis - varData.minDis)
    return vData * (varData.max - varData.min) + varData.min
  }

  function tuningVarChanged(varName) {
    editedTuningVars[varName] = true
  }

  async function refreshFromBackend() {
    editedTuningVars = {}
    await api.request()
  }

  return {
    init,
    buckets,
    tuningVariables,
    shoppingData,
    apply,
    requestInitialData: () => api.request(),
    refreshFromBackend,
    close: () => api.close(),
    notifyOnMenuClosed: () => api.menuClose(),
    tuningVarChanged,
    resetTuningData: () => api.reset(),
  }
})
