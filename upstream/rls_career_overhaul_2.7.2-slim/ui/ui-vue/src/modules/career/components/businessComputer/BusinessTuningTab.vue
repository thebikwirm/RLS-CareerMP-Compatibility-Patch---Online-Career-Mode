<template>
  <!-- Same look as the career Tuning screen (Tuning.vue with the house prop) and BusinessWorkshopTuning:
       Style Guide captions, grouped translucent rows, house slider / switches / buttons, hairline bottom bar. -->
  <div class="tuning-tab rls-house">
    <div v-if="!store.pulledOutVehicle" class="state-message">
      <p>No vehicle in garage. Pull out a vehicle from Active Jobs to access tuning options.</p>
    </div>

    <template v-else>
      <!-- Loading State -->
      <div v-if="loading" class="state-message">
        <p>Loading tuning data…</p>
      </div>

      <!-- Content - Only show when not loading -->
      <div v-else class="tuning-content-wrapper">
        <div class="search-section">
          <label class="search">
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <circle cx="11" cy="11" r="7" />
              <path d="m20 20-3.6-3.6" />
            </svg>
            <input v-model="searchQuery" type="text" placeholder="Search tuning options" class="search-input"
              @focus="onSearchFocus" @blur="onSearchBlur" @keydown.enter.stop="triggerSearch" @keydown.stop @keyup.stop
              @keypress.stop v-bng-text-input :disabled="loading" :bng-no-nav="(loading) ? 'true' : null" />
            <button v-if="searchQuery.length > 0" @click="clearSearch" class="clear-search-button" type="button"
              aria-label="Clear search">
              <svg viewBox="0 0 24 24" aria-hidden="true">
                <path d="M18 6 6 18M6 6l12 12" />
              </svg>
            </button>
          </label>
        </div>

        <div class="tuning-scrollable">
          <div v-if="filteredBuckets.length === 0" class="state-message">
            <p v-if="activeSearchQuery">No tuning options found matching "{{ activeSearchQuery }}"</p>
            <p v-else>No tuning options available for this vehicle.</p>
          </div>

          <section v-for="category in filteredBuckets" :key="category.name" class="tuning-category"
            v-show="category.items && category.items.length > 0">
            <!-- Style Guide caption + hairline rule; still folds the section -->
            <button class="category-heading" type="button" :aria-expanded="!isSectionCollapsed(category.name)"
              @click="toggleSection(category.name)">
              <span class="category-name">{{ category.name }}</span>
              <svg class="chevron-icon" viewBox="0 0 24 24" aria-hidden="true"
                :class="{ rotated: !isSectionCollapsed(category.name) }">
                <path d="m6 9 6 6 6-6" />
              </svg>
            </button>
            <transition name="section-collapse">
              <div v-if="!isSectionCollapsed(category.name)" class="section-content">
                <div v-for="subCategory in category.items" :key="subCategory.name" class="tuning-subcategory">
                  <h3 v-if="subCategory.name !== 'Other' && subCategory.name" class="subcategory-heading">
                    {{ subCategory.name }}
                  </h3>
                  <BngRow v-for="varData in subCategory.items" :key="varData.name" vertical class="variable-box"
                    :tooltip="varData.description">
                    <template #label>{{ varData.title || varData.name }}</template>
                    <HouseSlider
                      :min="getDisplayMin(varData)"
                      :max="getDisplayMax(varData)"
                      :step="getDisplayStep(varData)"
                      :unit="unitLabel(varData.unit)"
                      with-input
                      with-reset
                      :orig-value="origDisplayValue(varData)"
                      :disabled="isSliderDisabled(varData)"
                      v-model="varData.displayValue"
                      @valueChanged="onSliderChange(varData)"
                    />
                  </BngRow>
                </div>
              </div>
            </transition>
          </section>
        </div>

        <div class="tuning-controls">
          <BusinessWheelData v-if="wheelDataExpanded" ref="wheelDataRef" class="wheel-data"
            :business-id="store.businessId" :vehicle-id="store.pulledOutVehicle?.vehicleId" />
          <div class="controls-row">
            <HouseSwitch :model-value="wheelDataExpanded" @update:modelValue="toggleWheelData">
              Live Wheel Data
            </HouseSwitch>
            <HouseSwitch v-model="liveUpdates">Live Updates</HouseSwitch>
            <div class="buttons">
              <HouseButton
                compact
                variant="quiet"
                :icon="icons.undo"
                aria-label="Reset"
                v-bng-tooltip="'Reset'"
                @click="resetSettings" />
              <HouseButton @click="applySettings">Apply</HouseButton>
            </div>
          </div>
        </div>
      </div>
    </template>
  </div>
</template>

<script setup>
import { ref, computed, watch, onMounted, onBeforeUnmount } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import { lua } from "@/bridge"
import { BngRow, icons } from "@/common/components/base"
import { vBngTextInput, vBngTooltip } from "@/common/directives"
import { useEvents } from "@/services/events"
import { HouseButton, HouseSlider, HouseSwitch } from "../house"
import BusinessWheelData from "./BusinessWheelData.vue"

const store = useBusinessComputerStore()
const events = useEvents()

const liveUpdates = ref(false)
const loading = ref(true)
const tuningVariables = ref({})
const originalTuningVariables = ref({})
const buckets = ref([])
const collapsedSections = ref({})
const searchQuery = ref("")
const activeSearchQuery = ref("")
const wheelDataExpanded = ref(false)
const wheelDataRef = ref(null)
const liveUpdateDebounceTimer = ref(null)
const LIVE_UPDATE_DEBOUNCE_MS = 150
const damageLockWarning = () => {
  const info = store.damageLockInfo || {}
  const damage = Math.round(info.damage || 0)
  const threshold = info.threshold || 1000
  const message = `Vehicle damage (${damage}) exceeds the ${threshold} limit. Abandon the job to continue.`
  try {
    lua.ui_message(message, 5, "Business Computer", "error")
  } catch (error) {
  }
}
const isDamageLocked = computed(() => store.isDamageLocked)
const guardDamageLock = () => {
  if (isDamageLocked.value) {
    damageLockWarning()
    return true
  }
  return false
}

const toggleWheelData = () => {
  wheelDataExpanded.value = !wheelDataExpanded.value
  if (wheelDataExpanded.value && wheelDataRef.value && wheelDataRef.value.reloadExtension) {
    wheelDataRef.value.reloadExtension()
  }
}

const onSearchFocus = () => {
  try { lua.setCEFTyping(true) } catch (_) { }
}

const onSearchBlur = () => {
  try { triggerSearch() } catch (_) { }
  try { lua.setCEFTyping(false) } catch (_) { }
}

const triggerSearch = () => {
  activeSearchQuery.value = searchQuery.value.trim()
  if (activeSearchQuery.value.length > 0) {
    filteredBuckets.value.forEach(bucket => {
      collapsedSections.value[bucket.name] = false
    })
  }
}

const clearSearch = () => {
  searchQuery.value = ""
  activeSearchQuery.value = ""
  try { lua.setCEFTyping(false) } catch (_) { }
}

const hasActiveSearch = computed(() => activeSearchQuery.value.length > 0)

const filteredBuckets = computed(() => {
  if (!hasActiveSearch.value) {
    return buckets.value
  }

  const query = activeSearchQuery.value.toLowerCase()
  const filtered = []

  buckets.value.forEach(bucket => {
    const matchingSubCategories = []

    bucket.items.forEach(subCategory => {
      const matchingItems = subCategory.items.filter(item => {
        const title = (item.title || item.name || '').toLowerCase()
        return title.includes(query)
      })

      if (matchingItems.length > 0) {
        matchingSubCategories.push({
          ...subCategory,
          items: matchingItems.sort((a, b) => {
            const titleA = (a.title || a.name || '').toLowerCase()
            const titleB = (b.title || b.name || '').toLowerCase()
            return titleA.localeCompare(titleB)
          })
        })
      }
    })

    if (matchingSubCategories.length > 0) {
      filtered.push({
        ...bucket,
        items: matchingSubCategories.sort((a, b) => a.name.localeCompare(b.name))
      })
    }
  })

  return filtered.sort((a, b) => a.name.localeCompare(b.name))
})

const toggleSection = (sectionName) => {
  collapsedSections.value[sectionName] = !collapsedSections.value[sectionName]
}

const isSectionCollapsed = (sectionName) => {
  return collapsedSections.value[sectionName] === true
}

const getActualMin = (varData) => {
  if (typeof varData.min === 'number') return varData.min
  if (typeof varData.options?.min === 'number') return varData.options.min
  return 0
}

const getActualMax = (varData) => {
  if (typeof varData.max === 'number') return varData.max
  if (typeof varData.options?.max === 'number') return varData.options.max
  return 100
}

const getDisplayBounds = (varData) => {
  const actualMin = getActualMin(varData)
  const actualMax = getActualMax(varData)
  const minDis = typeof varData.options?.minDis === 'number'
    ? varData.options.minDis
    : (typeof varData.minDis === 'number' ? varData.minDis : actualMin)
  const maxDis = typeof varData.options?.maxDis === 'number'
    ? varData.options.maxDis
    : (typeof varData.maxDis === 'number' ? varData.maxDis : actualMax)
  return {
    actualMin,
    actualMax,
    minDis,
    maxDis
  }
}

const roundDisplayValue = (value) => {
  return Math.round(value * 100) / 100
}

const convertActualToDisplay = (varData, actualValue) => {
  const { actualMin, actualMax, minDis, maxDis } = getDisplayBounds(varData)
  const actualRange = actualMax - actualMin
  const displayRange = maxDis - minDis
  let displayValue
  if ((minDis !== actualMin || maxDis !== actualMax) && actualRange !== 0 && displayRange !== 0) {
    displayValue = ((actualValue - actualMin) / actualRange) * displayRange + minDis
  } else {
    displayValue = actualValue
  }
  return roundDisplayValue(displayValue)
}

const convertDisplayToActual = (varData, displayValue) => {
  const { actualMin, actualMax, minDis, maxDis } = getDisplayBounds(varData)
  const actualRange = actualMax - actualMin
  const displayRange = maxDis - minDis
  if ((minDis !== actualMin || maxDis !== actualMax) && actualRange !== 0 && displayRange !== 0) {
    return ((displayValue - minDis) / displayRange) * actualRange + actualMin
  }
  return displayValue
}

// Organize tuning variables into buckets (categories) with subcategories
const organizeTuningData = (tuningData) => {
  if (!tuningData) return []

  const bucketsMap = {}

  // Iterate through all tuning variables
  for (const [varName, varData] of Object.entries(tuningData)) {
    if (!varData || typeof varData !== 'object') continue

    const category = varData.category || 'Other'
    const subCategory = varData.subCategory || 'Other'

    // Initialize category bucket if it doesn't exist
    if (!bucketsMap[category]) {
      bucketsMap[category] = {
        name: category,
        items: {}
      }
    }

    // Initialize subcategory if it doesn't exist
    if (!bucketsMap[category].items[subCategory]) {
      bucketsMap[category].items[subCategory] = {
        name: subCategory,
        items: []
      }
    }

    // Add variable to subcategory
    const actualValue = varData.val ?? (varData.default ?? getActualMin(varData))
    const displayVal = convertActualToDisplay(varData, actualValue)

    bucketsMap[category].items[subCategory].items.push({
      ...varData,
      name: varName,
      displayValue: displayVal
    })
  }

  // Convert buckets map to array
  const bucketsArray = []
  for (const [categoryName, categoryData] of Object.entries(bucketsMap)) {
    const subCategories = []
    for (const [subCategoryName, subCategoryData] of Object.entries(categoryData.items)) {
      subCategories.push(subCategoryData)
    }
    bucketsArray.push({
      name: categoryName,
      items: subCategories
    })
  }

  // Sort buckets, subcategories, and items alphabetically
  bucketsArray.sort((a, b) => a.name.localeCompare(b.name))
  bucketsArray.forEach(bucket => {
    bucket.items.sort((a, b) => a.name.localeCompare(b.name))
    bucket.items.forEach(subCategory => {
      subCategory.items.sort((a, b) => {
        const titleA = (a.title || a.name || '').toLowerCase()
        const titleB = (b.title || b.name || '').toLowerCase()
        return titleA.localeCompare(titleB)
      })
    })
  })

  return bucketsArray
}

const formatValue = (value, unit) => {
  if (unit === '%' || unit === 'percent') {
    return value.toFixed(2)
  }
  if (unit) {
    return `${value}${unit}`
  }
  return value.toString()
}

const getDisplayValue = (varData) => {
  const actualValue = varData.valDis ?? varData.val ?? (varData.default ?? getActualMin(varData))
  return convertActualToDisplay(varData, actualValue)
}

// display-only helpers for the house slider: unit suffix and the loaded (stock) position for its
// reset button and default-value notch
const unitLabel = (unit) => (unit === 'percent' ? '%' : unit || '')
const origDisplayValue = (varData) => originalTuningVariables.value?.[varData.name]?.displayValue

const getDisplayMin = (varData) => {
  return getDisplayBounds(varData).minDis
}

const getDisplayMax = (varData) => {
  return getDisplayBounds(varData).maxDis
}

const getDisplayStep = (varData) => {
  if (typeof varData.stepDis === 'number' && varData.stepDis > 0) {
    return varData.stepDis
  }

  return getStepValue(varData)
}

const onValueInput = (varData) => {
  let displayValue = Number(varData.displayValue)
  if (!isFinite(displayValue)) {
    return
  }

  const { minDis, maxDis } = getDisplayBounds(varData)
  displayValue = Math.max(minDis, Math.min(maxDis, displayValue))
  displayValue = roundDisplayValue(displayValue)

  const actualValue = convertDisplayToActual(varData, displayValue)

  varData.val = actualValue
  varData.valDis = actualValue
  varData.displayValue = displayValue

  if (tuningVariables.value[varData.name]) {
    tuningVariables.value[varData.name].val = actualValue
    tuningVariables.value[varData.name].valDis = actualValue
    tuningVariables.value[varData.name].displayValue = displayValue
  }

  onTuningChange(varData.name, actualValue)
}

const onValueFocus = () => {
  lua.setCEFTyping(true)
}

const onValueBlur = (varData) => {
  lua.setCEFTyping(false)
  // Ensure display value is synced with actual value
  varData.displayValue = getDisplayValue(varData)
}

const getStepValue = (varData) => {
  // If stepDis is provided and valid, use it
  if (varData.stepDis !== undefined && varData.stepDis !== null && !isNaN(varData.stepDis) && varData.stepDis > 0) {
    return varData.stepDis
  }

  // If step is provided and valid, use it
  if (varData.step !== undefined && varData.step !== null && !isNaN(varData.step) && varData.step > 0) {
    return varData.step
  }

  // Calculate a reasonable step based on the display range
  const { minDis, maxDis } = getDisplayBounds(varData)
  const range = Math.abs(maxDis - minDis)

  // Use 1/1000th of the range, but ensure it's at least 0.001 and not too small
  const calculatedStep = Math.max(0.001, Math.min(1, range / 1000))

  return calculatedStep
}

const isSliderDisabled = (varData) => {
  const min = varData.minDis ?? 0
  const max = varData.maxDis ?? 100

  // Disable if min equals max or values are invalid
  if (min === max || isNaN(min) || isNaN(max)) {
    return true
  }

  // Disable if step is invalid or zero
  const step = getStepValue(varData)
  if (isNaN(step) || step <= 0) {
    return true
  }

  return false
}

const getSliderStyle = (varData) => {
  const minDis = varData.minDis ?? varData.min ?? 0
  const maxDis = varData.maxDis ?? varData.max ?? 100
  const displayValue = varData.displayValue ?? minDis

  if (isNaN(minDis) || isNaN(maxDis) || isNaN(displayValue)) {
    return {
      '--slider-percentage': '0%'
    }
  }

  if (maxDis === minDis) {
    return {
      '--slider-percentage': '0%'
    }
  }

  let percentage = ((displayValue - minDis) / (maxDis - minDis)) * 100
  percentage = Math.max(0, Math.min(100, percentage))

  if (isNaN(percentage)) {
    percentage = 0
  }

  return {
    '--slider-percentage': `${percentage}%`
  }
}

const normalizeVehicleCacheKey = (value) => {
  if (value === undefined || value === null) {
    return 'noveh'
  }
  return String(value)
}

const handleTuningData = (data) => {
  if (!data || !data.success) {
    loading.value = false
    return
  }

  const cacheKey = normalizeVehicleCacheKey(data.vehicleId)

  if (String(data.vehicleId) === String(store.pulledOutVehicle?.vehicleId) &&
    String(data.businessId) === String(store.businessId)) {
    if (data.tuningData) {
      // Cache the data in the store
      if (store.tuningDataCache) {
        store.tuningDataCache[cacheKey] = data.tuningData
      }

      tuningVariables.value = data.tuningData

      const baseline = {}

      for (const [varName, varData] of Object.entries(data.tuningData)) {
        baseline[varName] = JSON.parse(JSON.stringify(varData))

        const currentVal = varData.val ?? (varData.default ?? getActualMin(varData))
        baseline[varName].val = currentVal
        baseline[varName].valDis = currentVal
        baseline[varName].displayValue = convertActualToDisplay(varData, currentVal)
      }

      originalTuningVariables.value = baseline
      buckets.value = organizeTuningData(data.tuningData)

      // Load cart values into UI after tuning data is set up
      loadTuningFromCart()
    }
    loading.value = false
  } else {
    loading.value = false
  }
}

const loadTuningData = async () => {
  if (guardDamageLock()) {
    loading.value = false
    return
  }
  if (!store.pulledOutVehicle || !store.pulledOutVehicle.vehicleId) {
    loading.value = false
    return
  }

  // Always show loading state immediately
  loading.value = true

  // Request data (returns immediately, data comes via hook)
  // Lua will check cache and return instantly if cached
  store.requestVehicleTuningData(store.pulledOutVehicle.vehicleId).catch(error => {
    loading.value = false
  })
}

const debouncedLiveUpdate = () => {
  if (liveUpdateDebounceTimer.value) {
    clearTimeout(liveUpdateDebounceTimer.value)
  }
  liveUpdateDebounceTimer.value = setTimeout(() => {
    applySettings()
  }, LIVE_UPDATE_DEBOUNCE_MS)
}

const onSliderChange = (varData) => {
  if (!varData || !tuningVariables.value[varData.name]) return

  let displayValue = Number(varData.displayValue)
  const { minDis, maxDis } = getDisplayBounds(varData)
  displayValue = Math.max(minDis, Math.min(maxDis, displayValue))
  displayValue = roundDisplayValue(displayValue)

  const actualValue = convertDisplayToActual(varData, displayValue)

  varData.displayValue = displayValue
  varData.val = actualValue
  varData.valDis = actualValue

  tuningVariables.value[varData.name].val = actualValue
  tuningVariables.value[varData.name].valDis = actualValue
  tuningVariables.value[varData.name].displayValue = displayValue

  for (const bucket of buckets.value) {
    for (const subCategory of bucket.items) {
      for (const item of subCategory.items) {
        if (item.name === varData.name) {
          item.displayValue = displayValue
          item.valDis = actualValue
          break
        }
      }
    }
  }

  if (liveUpdates.value) {
    debouncedLiveUpdate()
  }
}

const onTuningChange = (varName, actualValue) => {
  if (guardDamageLock()) {
    return
  }
  if (!tuningVariables.value[varName]) return

  const varData = tuningVariables.value[varName]

  tuningVariables.value[varName].val = actualValue
  tuningVariables.value[varName].valDis = actualValue

  varData.displayValue = convertActualToDisplay(varData, actualValue)

  for (const bucket of buckets.value) {
    for (const subCategory of bucket.items) {
      for (const item of subCategory.items) {
        if (item.name === varName) {
          item.displayValue = varData.displayValue
          item.valDis = actualValue
          break
        }
      }
    }
  }

  if (liveUpdates.value) {
    debouncedLiveUpdate()
  }
}

const hasChanges = computed(() => {
  if (!tuningVariables.value || !originalTuningVariables.value) return false

  for (const [varName, varData] of Object.entries(tuningVariables.value)) {
    const original = originalTuningVariables.value[varName]
    if (!original) continue

    if (varData.valDis !== original.valDis) {
      return true
    }
  }

  return false
})

const loadTuningFromCart = () => {
  if (guardDamageLock()) {
    return
  }
  if (!tuningVariables.value || !originalTuningVariables.value) return

  const cart = Array.isArray(store.tuningCart) ? store.tuningCart : []

  const cartTuningMap = {}
  cart.forEach(item => {
    // Only process variables, skip categories and subcategories
    if (item.type === 'variable' && item.varName && item.value !== undefined) {
      cartTuningMap[item.varName] = item.value
    }
  })

  for (const [varName, varData] of Object.entries(tuningVariables.value)) {
    if (cartTuningMap.hasOwnProperty(varName)) {
      const actualValue = cartTuningMap[varName]
      varData.val = actualValue
      varData.valDis = actualValue
    } else {
      const originalData = originalTuningVariables.value[varName]
      const resetVal = originalData
        ? (originalData.val ?? getActualMin(varData))
        : (varData.val ?? getActualMin(varData))
      varData.val = resetVal
      varData.valDis = resetVal
    }

    varData.displayValue = convertActualToDisplay(varData, varData.valDis)
  }

  buckets.value = organizeTuningData(tuningVariables.value)

  store.updatePowerWeight()
}

const resetSettings = async () => {
  if (guardDamageLock()) {
    return
  }
  if (!originalTuningVariables.value || !store.pulledOutVehicle || !store.pulledOutVehicle.vehicleId) return

  const baselineTuningVars = {}
  for (const [varName, varData] of Object.entries(tuningVariables.value)) {
    const originalData = originalTuningVariables.value[varName]
    const baselineVal = originalData
      ? (originalData.val ?? getActualMin(varData))
      : (varData.val ?? getActualMin(varData))
    baselineTuningVars[varName] = baselineVal
  }

  for (const [varName, varData] of Object.entries(tuningVariables.value)) {
    const originalData = originalTuningVariables.value[varName]
    const resetVal = originalData
      ? (originalData.val ?? getActualMin(varData))
      : (varData.val ?? getActualMin(varData))

    tuningVariables.value[varName].val = resetVal
    tuningVariables.value[varName].valDis = resetVal
    tuningVariables.value[varName].displayValue = convertActualToDisplay(varData, resetVal)
  }

  buckets.value = organizeTuningData(tuningVariables.value)

  try {
    if (store.businessId) {
      await lua.career_modules_business_businessComputer.applyTuningToVehicle(
        store.businessId,
        store.pulledOutVehicle.vehicleId,
        baselineTuningVars
      )

      setTimeout(() => {
        if (store.vehicleView === 'parts') {
          store.requestVehiclePartsTree(store.pulledOutVehicle.vehicleId)
        }
      }, 100)
    }
  } catch (error) {
  }

  await store.addTuningToCart({}, originalTuningVariables.value)

  store.updatePowerWeight()

  if (liveUpdates.value) {
    applySettings()
  }
}

const applySettings = async () => {
  if (guardDamageLock()) {
    return
  }
  if (!store.pulledOutVehicle || !store.pulledOutVehicle.vehicleId) return

  const tuningVars = {}
  for (const [varName, varData] of Object.entries(tuningVariables.value)) {
    if (varData.val !== undefined) {
      tuningVars[varName] = varData.val
    } else if (varData.valDis !== undefined) {
      tuningVars[varName] = varData.valDis
    } else if (varData.displayValue !== undefined) {
      tuningVars[varName] = convertDisplayToActual(varData, varData.displayValue)
    }
  }

  try {
    await store.addTuningToCart(tuningVars, originalTuningVariables.value)

    if (store.businessId) {
      await lua.career_modules_business_businessComputer.applyTuningToVehicle(
        store.businessId,
        store.pulledOutVehicle.vehicleId,
        tuningVars
      )

      setTimeout(() => {
        if (store.vehicleView === 'parts') {
          store.requestVehiclePartsTree(store.pulledOutVehicle.vehicleId)
        }
      }, 100)
    }

    store.updatePowerWeight()
  } catch (error) {
  }
}

watch(() => store.pulledOutVehicle, (newVehicle, oldVehicle) => {
  if (!newVehicle) {
    tuningVariables.value = {}
    originalTuningVariables.value = {}
    buckets.value = []
    loading.value = false
    store.clearCart()
  } else {
    if (oldVehicle && newVehicle && oldVehicle.vehicleId !== newVehicle.vehicleId && store.vehicleView === 'tuning') {
      loading.value = true
      setTimeout(() => {
        loadTuningData()
      }, 100)
    }
  }
})

onMounted(() => {
  events.on('businessComputer:onVehicleTuningData', handleTuningData)

  requestAnimationFrame(() => {
    setTimeout(() => {
      if (store.pulledOutVehicle) {
        loadTuningData()
      }
    }, 350)
  })
})

onBeforeUnmount(() => {
  events.off('businessComputer:onVehicleTuningData', handleTuningData)
  if (liveUpdateDebounceTimer.value) {
    clearTimeout(liveUpdateDebounceTimer.value)
  }
})

watch(() => store.activeTabId, () => {
  if (store.vehicleView === 'tuning' && !store.isCurrentTabApplied) {
    loadTuningFromCart()
  }
})

defineExpose({
  resetSettings,
  loadTuningFromCart
})
</script>

<style scoped lang="scss">
@import "../../styles/rlsHouse.scss";

// Same look as the career Tuning screen (Tuning.vue, house prop) and views/BusinessWorkshopTuning.vue:
// Style Guide captions, translucent grouped rows, slim scrollbar, hairline bottom bar.
.tuning-tab {
  display: flex;
  flex-direction: column;
  height: 100%;
  min-height: 0;
  overflow: hidden;
  color: #fff;
}

.state-message {
  padding: 1.2em 1em;
  color: var(--muted);
  font-weight: 600;
  text-align: center;
  p {
    margin: 0;
  }
}

.tuning-content-wrapper {
  display: flex;
  flex-direction: column;
  flex: 1 1 auto;
  height: 100%;
  min-height: 0;
  overflow: hidden;
}

// ---- house search field
.search-section {
  flex: 0 0 auto;
  padding: 0 0.5em 0.35em 0.75em;
}
.search {
  cursor: text;
}
.search .clear-search-button {
  appearance: none;
  display: grid;
  place-items: center;
  flex: 0 0 auto;
  width: 1.6em;
  height: 1.6em;
  margin: 0 -0.3em 0 0;
  padding: 0;
  border: 0;
  border-radius: var(--radius-thumb);
  background: transparent;
  color: var(--faint);
  cursor: pointer;
  &:hover {
    background: var(--panel);
    color: #fff;
  }
  @include house-focus;
  svg {
    width: 0.85em;
    height: 0.85em;
    fill: none;
    stroke: currentColor;
    stroke-width: 2.4;
    stroke-linecap: round;
  }
}

// ---- scrolling settings list (class name is also the controller's joystick-scroll target)
.tuning-scrollable {
  flex: 1 1 auto;
  min-height: 0;
  padding: 0.35em 0.5em 1em 0.75em;
  overflow-x: hidden;
  overflow-y: auto;
  scrollbar-gutter: stable;
  &::-webkit-scrollbar { width: 0.5em; height: 0.5em; }
  &::-webkit-scrollbar-track { background: transparent; }
  &::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.22);
    border-radius: 1em;
    border: 0.12em solid transparent;
    background-clip: padding-box;
  }
  &::-webkit-scrollbar-thumb:hover { background: rgba(255, 255, 255, 0.38); background-clip: padding-box; }
  &::-webkit-scrollbar-thumb:active { background: var(--accent); background-clip: padding-box; }
}

.tuning-category {
  display: flex;
  flex-direction: column;
  padding: 0.2em 0 0.5em;
}

// Style Guide .caption + hairline rule; a quiet button so the section still folds
.category-heading {
  appearance: none;
  display: flex;
  align-items: center;
  gap: 0.7em;
  width: 100%;
  margin: 0;
  padding: 0.9em 0.15em 0.5em;
  border: 0;
  border-radius: var(--radius-thumb);
  background: transparent;
  color: var(--faint);
  font: inherit;
  font-size: 0.78em;
  font-style: normal;
  font-weight: 700;
  letter-spacing: 0.06em;
  line-height: 1.2;
  text-align: left;
  text-transform: uppercase;
  cursor: pointer;
  &::after {
    content: "";
    order: 1;
    flex: 1 1 auto;
    height: 1px;
    background: var(--line);
  }
  &:hover {
    color: #fff;
  }
  @include house-focus;
  .category-name {
    flex: 0 1 auto;
    min-width: 0;
    overflow-wrap: anywhere;
  }
  .chevron-icon {
    order: 2;
    flex: 0 0 auto;
    width: 1.1em;
    height: 1.1em;
    fill: none;
    stroke: currentColor;
    stroke-width: 2.4;
    stroke-linecap: round;
    stroke-linejoin: round;
    transform: rotate(-90deg);
    transition: transform 0.12s;
    &.rotated {
      transform: rotate(0deg);
    }
  }
}

.section-content {
  display: flex;
  flex-direction: column;
}

// fold: opacity only
.section-collapse-enter-active,
.section-collapse-leave-active {
  transition: opacity 0.15s ease;
}
.section-collapse-enter-from,
.section-collapse-leave-to {
  opacity: 0;
}

.tuning-subcategory {
  display: flex;
  flex-direction: column;
}
.tuning-subcategory + .tuning-subcategory {
  margin-top: 0.15em;
}
.subcategory-heading {
  margin: 0;
  padding: 0.7em 0.15em 0.35em;
  color: var(--muted);
  font-size: 0.85em;
  font-style: normal;
  font-weight: 700;
}

// each setting is a translucent line; a subcategory's lines read as one rounded group
.variable-box {
  --bng-bg-enabled: rgba(255, 255, 255, 0.06);
  --bng-bg-hover: rgba(255, 255, 255, 0.1);
  --bng-bg-active: rgba(255, 255, 255, 0.1);
  --bng-bg-border-enabled: transparent;
  --bng-bg-border-hover: transparent;
  --bng-bg-border-active: transparent;
  --bng-bg-enabled-opacity: 1;
  --bng-bg-hover-opacity: 1;
  --bng-bg-active-opacity: 1;
  --bng-bg-border-radius: 0;
  --bng-row-label-padding: 0 0 0.2em;
  --bng-slider-margin: 0.45em;
  --input-width: 6.5em;
  margin: 0;
  padding: 0.6em 0.75em 0.45em;
  border-radius: 0;
  &.focus-visible:not(.no-focus-frame) {
    --bng-bg-enabled: rgba(255, 255, 255, 0.12);
  }
  :deep(.bng-row-background) {
    border-radius: inherit;
  }
  :deep(.bng-row-label) {
    color: #fff;
    font-size: 0.92em;
    font-weight: 600;
    line-height: 1.25;
  }
}
.variable-box + .variable-box {
  border-top: 1px solid var(--line);
}
div.variable-box:first-of-type {
  border-top-left-radius: var(--radius-panel);
  border-top-right-radius: var(--radius-panel);
}
div.variable-box:last-of-type {
  border-bottom-left-radius: var(--radius-panel);
  border-bottom-right-radius: var(--radius-panel);
}

// ---- bottom bar: wheel data, switches, Reset + Apply
.tuning-controls {
  flex: 0 0 auto;
  max-height: calc(100% - 1.5em);
  padding: 0.6em 0.75em;
  border-top: 1px solid var(--line);
  overflow: hidden;
}
.wheel-data {
  max-height: 18em;
  margin-bottom: 0.5em;
  overflow: auto;
}
.controls-row {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.5em 1.2em;
}
.buttons {
  display: flex;
  align-items: center;
  gap: 0.4em;
  margin-left: auto;
}
</style>
