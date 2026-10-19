import { computed, ref } from "vue"
import { defineStore } from "pinia"
import { lua, useBridge } from "@/bridge"

const LIST_TTL_MS = 15000
const DETAIL_TTL_MS = 30000

function normalizeCollection(value) {
  if (Array.isArray(value)) return value
  if (!value || typeof value !== "object") return []

  const numericKeys = Object.keys(value)
    .filter(key => String(Number(key)) === key)
    .sort((left, right) => Number(left) - Number(right))

  if (numericKeys.length > 0) {
    return numericKeys.map(key => value[key])
  }

  return []
}

function normalizeRowArray(rows) {
  return normalizeCollection(rows)
}

function normalizeDestinationArray(destinations) {
  return normalizeCollection(destinations)
}

function normalizeSectionArray(sections) {
  return normalizeCollection(sections).map(section => ({
    ...section,
    rows: normalizeRowArray(section?.rows),
    destinations: normalizeDestinationArray(section?.destinations),
  }))
}

function normalizeProgression(progression) {
  if (!progression || typeof progression !== "object") return {}
  return {
    ...progression,
    logistics: progression.logistics && typeof progression.logistics === "object"
      ? { ...progression.logistics }
      : null,
  }
}

function normalizeFacilityList(facilities) {
  return normalizeCollection(facilities).map(facility => ({
    ...facility,
    badges: normalizeCollection(facility?.badges),
  }))
}

function normalizeFacilityDetail(data) {
  return {
    ...data,
    progression: normalizeProgression(data?.progression),
    contracts: normalizeCollection(data?.contracts),
    contractsUnlocked: data?.contractsUnlocked === true,
    contractsUnlockLevel: data?.contractsUnlockLevel || 30,
    contractsLevel: data?.contractsLevel || 0,
    activeContract: data?.activeContract || null,
    onShift: data?.onShift === true,
    parcelDestinations: normalizeSectionArray(data?.parcelDestinations),
    materialSources: normalizeSectionArray(data?.materialSources),
    vehicleOfferDestinations: normalizeSectionArray(data?.vehicleOfferDestinations),
    trailerOfferDestinations: normalizeSectionArray(data?.trailerOfferDestinations),
  }
}

export const usePhoneLogisticsStore = defineStore("phoneLogistics", () => {
  const { events } = useBridge()

  const initialized = ref(false)
  const loaded = ref(false)
  const loadingList = ref(false)
  const loadingDetail = ref(false)
  const loadingDetailFor = ref("")
  const careerActive = ref(true)
  const levelId = ref("")
  const listFetchedAt = ref(0)
  const facilities = ref([])
  const selectedFacilityId = ref("")
  const detailByFacility = ref({})
  const detailErrors = ref({})
  const error = ref(null)

  const contracts = ref([])
  const contractsUnlocked = ref(false)
  const contractsUnlockLevel = ref(30)
  const contractsLevel = ref(0)
  const contractsLoading = ref(false)
  const activeContract = ref(null)
  const selectedContractId = ref("")
  const selectedVehicleKeys = ref([])
  const boardMode = ref("contracts")
  const onCompanyShift = ref(false)
  const actionMessage = ref("")

  const onFacilityList = data => {
    loaded.value = true
    loadingList.value = false
    error.value = null

    const nextLevelId = data?.levelId || ""
    if (levelId.value && nextLevelId !== levelId.value) {
      detailByFacility.value = {}
      detailErrors.value = {}
      selectedFacilityId.value = ""
    }

    levelId.value = nextLevelId
    careerActive.value = data?.careerActive !== false
    facilities.value = normalizeFacilityList(data?.facilities)
    listFetchedAt.value = Date.now()

    if (selectedFacilityId.value) {
      const selectedStillExists = facilities.value.some(facility => facility.id === selectedFacilityId.value)
      if (!selectedStillExists) {
        selectedFacilityId.value = ""
        loadingDetail.value = false
        loadingDetailFor.value = ""
      }
    }
  }

  const onFacilityDetail = data => {
    const facilityId = data?.facilityId
    if (!facilityId) return

    detailByFacility.value = {
      ...detailByFacility.value,
      [facilityId]: {
        data: normalizeFacilityDetail(data),
        fetchedAt: Date.now(),
      },
    }

    contractsUnlocked.value = data?.contractsUnlocked === true
    contractsUnlockLevel.value = data?.contractsUnlockLevel || 30
    contractsLevel.value = data?.contractsLevel || 0
    contracts.value = normalizeCollection(data?.contracts)
    activeContract.value = data?.activeContract || null
    onCompanyShift.value = data?.onShift === true
    contractsLoading.value = false

    if (detailErrors.value[facilityId]) {
      const nextErrors = { ...detailErrors.value }
      delete nextErrors[facilityId]
      detailErrors.value = nextErrors
    }

    if (loadingDetailFor.value === facilityId) {
      loadingDetail.value = false
      loadingDetailFor.value = ""
    }
  }

  const onLogisticsError = data => {
    const payload = data || { code: "unknown_error" }
    if (payload.facilityId) {
      detailErrors.value = {
        ...detailErrors.value,
        [payload.facilityId]: payload,
      }
      if (loadingDetailFor.value === payload.facilityId) {
        loadingDetail.value = false
        loadingDetailFor.value = ""
      }
      return
    }

    loadingList.value = false
    loaded.value = true
    error.value = payload
  }

  const selectedFacility = computed(() => (
    facilities.value.find(facility => facility.id === selectedFacilityId.value) || null
  ))

  const selectedDetail = computed(() => (
    selectedFacilityId.value && detailByFacility.value[selectedFacilityId.value]
      ? detailByFacility.value[selectedFacilityId.value].data
      : null
  ))

  const selectedDetailError = computed(() => (
    selectedFacilityId.value ? detailErrors.value[selectedFacilityId.value] || null : null
  ))

  const onContracts = data => {
    contractsLoading.value = false
    contractsUnlocked.value = data?.unlocked === true
    contractsUnlockLevel.value = data?.unlockLevel || 30
    contractsLevel.value = data?.level || 0
    contracts.value = normalizeCollection(data?.contracts)
    activeContract.value = data?.active || null
    onCompanyShift.value = data?.onShift === true
  }

  const onContractResult = data => {
    if (data?.board) onContracts(data.board)
    actionMessage.value = data?.abandoned ? (data.message || "Contract abandoned.")
      : data?.ok ? "" : (data?.message || "Could not take that contract.")
    if (data?.ok) {
      selectedContractId.value = ""
      selectedVehicleKeys.value = []
      if (activeContract.value?.kind === "finkHaul") {
        boardMode.value = "finkTrip"
      }
    }
  }

  function registerEvents() {
    events.on("phoneLogisticsFacilityList", onFacilityList)
    events.on("phoneLogisticsFacilityDetail", onFacilityDetail)
    events.on("phoneLogisticsError", onLogisticsError)
    events.on("phoneLogisticsContracts", onContracts)
    events.on("phoneLogisticsContractResult", onContractResult)
  }

  function unregisterEvents() {
    events.off("phoneLogisticsFacilityList", onFacilityList)
    events.off("phoneLogisticsFacilityDetail", onFacilityDetail)
    events.off("phoneLogisticsError", onLogisticsError)
    events.off("phoneLogisticsContracts", onContracts)
    events.off("phoneLogisticsContractResult", onContractResult)
  }

  function resetState() {
    loaded.value = false
    loadingList.value = false
    loadingDetail.value = false
    loadingDetailFor.value = ""
    careerActive.value = true
    levelId.value = ""
    listFetchedAt.value = 0
    facilities.value = []
    selectedFacilityId.value = ""
    detailByFacility.value = {}
    detailErrors.value = {}
    error.value = null
    contracts.value = []
    contractsUnlocked.value = false
    contractsLoading.value = false
    activeContract.value = null
    selectedContractId.value = ""
    selectedVehicleKeys.value = []
    boardMode.value = "contracts"
    onCompanyShift.value = false
    actionMessage.value = ""
  }

  async function init() {
    if (initialized.value) {
      await refreshList(true)
      return
    }
    resetState()
    registerEvents()
    initialized.value = true
    await lua.extensions.load("ui_phone_logistics")
    await refreshList(true)
  }

  async function cleanup() {
    if (!initialized.value) return
    unregisterEvents()
    initialized.value = false
    await lua.extensions.unload("ui_phone_logistics")
    resetState()
  }

  async function refreshList(force = false) {
    const isFresh = Date.now() - listFetchedAt.value < LIST_TTL_MS
    if (!force && loaded.value && isFresh) return
    loadingList.value = true
    error.value = null
    await lua.ui_phone_logistics.requestFacilityList()
  }

  async function refreshContracts(facilityId = "") {
    contractsLoading.value = true
    const id = facilityId || selectedFacilityId.value || ""
    await lua.ui_phone_logistics.requestContracts(id)
  }

  async function selectFacility(facilityId, force = false) {
    selectedFacilityId.value = facilityId || ""
    selectedContractId.value = ""
    selectedVehicleKeys.value = []
    if (!facilityId) {
      loadingDetail.value = false
      loadingDetailFor.value = ""
      contracts.value = []
      return
    }

    const cached = detailByFacility.value[facilityId]
    const isFresh = cached && (Date.now() - cached.fetchedAt < DETAIL_TTL_MS)
    if (!force && isFresh) {
      const data = cached.data
      contracts.value = normalizeCollection(data?.contracts)
      contractsUnlocked.value = data?.contractsUnlocked === true
      contractsUnlockLevel.value = data?.contractsUnlockLevel || 30
      contractsLevel.value = data?.contractsLevel || 0
      activeContract.value = data?.activeContract || null
      onCompanyShift.value = data?.onShift === true
      return
    }

    if (force && cached) {
      const nextDetails = { ...detailByFacility.value }
      delete nextDetails[facilityId]
      detailByFacility.value = nextDetails
    }

    loadingDetail.value = true
    loadingDetailFor.value = facilityId
    contractsLoading.value = true
    detailErrors.value = {
      ...detailErrors.value,
      [facilityId]: null,
    }
    await lua.ui_phone_logistics.requestFacilityDetail(facilityId)
  }

  function backToList() {
    selectedFacilityId.value = ""
    selectedContractId.value = ""
    selectedVehicleKeys.value = []
    contracts.value = []
    loadingDetail.value = false
    loadingDetailFor.value = ""
    actionMessage.value = ""
  }

  async function navigateToFacility(facilityId, parkingSpotPath = "") {
    if (!facilityId) return
    await lua.ui_phone_logistics.navigateToFacility(facilityId, parkingSpotPath)
  }

  function selectContract(contractId) {
    selectedContractId.value = contractId || ""
    selectedVehicleKeys.value = []
    actionMessage.value = ""
  }

  function toggleVehicleKey(key) {
    const set = new Set(selectedVehicleKeys.value)
    if (set.has(key)) set.delete(key)
    else set.add(key)
    selectedVehicleKeys.value = Array.from(set)
  }

  async function acceptSelectedContract() {
    if (!selectedContractId.value) return
    await lua.ui_phone_logistics.acceptContract(selectedContractId.value, {})
  }

  async function abandonHubContract(contractId) {
    if (!activeContract.value || activeContract.value.kind === "finkHaul" || activeContract.value.id !== contractId) return
    await lua.ui_phone_logistics.abandonHubContract(contractId)
  }

  function openCarHaulTripPlanner() {
    if (activeContract.value?.kind !== "finkHaul") return
    boardMode.value = "finkTrip"
    selectedVehicleKeys.value = []
  }

  function closeCarHaulTripPlanner() {
    boardMode.value = "contracts"
    selectedVehicleKeys.value = []
  }

  async function stageCarHaulTrip() {
    if (activeContract.value?.kind !== "finkHaul") return
    await lua.ui_phone_logistics.stageCarHaulTrip({
      selectedVehicleKeys: selectedVehicleKeys.value,
    })
    selectedVehicleKeys.value = []
  }

  const selectedContract = computed(() => (
    contracts.value.find(c => c.id === selectedContractId.value) || null
  ))

  return {
    loaded,
    loadingList,
    loadingDetail,
    loadingDetailFor,
    careerActive,
    levelId,
    listFetchedAt,
    facilities,
    selectedFacilityId,
    detailByFacility,
    detailErrors,
    error,
    selectedFacility,
    selectedDetail,
    selectedDetailError,
    boardMode,
    contracts,
    contractsUnlocked,
    contractsUnlockLevel,
    contractsLevel,
    contractsLoading,
    activeContract,
    selectedContractId,
    selectedVehicleKeys,
    selectedContract,
    onCompanyShift,
    actionMessage,
    init,
    cleanup,
    refreshList,
    refreshContracts,
    selectFacility,
    backToList,
    navigateToFacility,
    selectContract,
    toggleVehicleKey,
    acceptSelectedContract,
    abandonHubContract,
    openCarHaulTripPlanner,
    closeCarHaulTripPlanner,
    stageCarHaulTrip,
  }
})
