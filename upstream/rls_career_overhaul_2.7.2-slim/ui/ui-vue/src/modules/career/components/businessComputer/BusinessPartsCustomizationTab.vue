<template>
  <!-- Same look as views/BusinessWorkshopParts.vue and the career Part Shop (partShopping/*): slot rows
       with the current-part chip, part rows with gold price, neutral Install, installed row brighter
       with an accent-soft name. -->
  <div class="parts-customization rls-house">
    <!-- Search Bar - Always visible -->
    <div class="search-section">
      <label class="search">
        <svg viewBox="0 0 24 24" aria-hidden="true">
          <circle cx="11" cy="11" r="7" />
          <path d="m20 20-3.6-3.6" />
        </svg>
        <input
          v-model="searchQuery"
          type="text"
          placeholder="Search for parts"
          class="search-input"
          @focus="onSearchFocus"
          @blur="onSearchBlur"
          @keydown.enter.stop="triggerSearch"
          @keydown.stop @keyup.stop @keypress.stop
          v-bng-text-input
          :disabled="loading" :bng-no-nav="(loading) ? 'true' : null"
        />
        <button
          v-if="searchQuery.length > 0"
          @click="clearSearch"
          class="clear-search-button"
          type="button"
          aria-label="Clear search"
        >
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <path d="M18 6 6 18M6 6l12 12" />
          </svg>
        </button>
      </label>
    </div>

    <!-- Loading State -->
    <div v-if="loading" class="state-message">
      <p>Loading parts…</p>
    </div>

    <!-- Content - Only show when not loading -->
    <template v-else>
      <!-- Breadcrumb Navigation (hidden when searching) -->
      <nav v-if="navigationPath.length > 0 && !hasActiveSearch" class="breadcrumb-nav" aria-label="Slot path">
        <button
          @click="navigateToPath(-1)"
          class="breadcrumb-link"
          type="button"
        >
          All Parts
        </button>
        <template v-if="showEllipsis">
          <svg class="breadcrumb-separator" viewBox="0 0 24 24" aria-hidden="true">
            <path d="m9 18 6-6-6-6" />
          </svg>
          <button
            class="breadcrumb-link more"
            type="button"
            @click="navigateToPath(-1)"
            title="Show all breadcrumbs"
            aria-label="Show all breadcrumbs"
          >
            More
          </button>
        </template>
        <template v-for="(pathId, index) in visibleBreadcrumbs" :key="`breadcrumb-${index}-${pathId}`">
          <svg class="breadcrumb-separator" viewBox="0 0 24 24" aria-hidden="true">
            <path d="m9 18 6-6-6-6" />
          </svg>
          <button
            @click="navigateToPath(getBreadcrumbIndex(index))"
            type="button"
            :class="['breadcrumb-link', { active: getBreadcrumbIndex(index) === navigationPath.length - 1 }]"
          >
            {{ getCategoryByPath(navigationPath.slice(0, getBreadcrumbIndex(index) + 1))?.slotNiceName || getCategoryByPath(navigationPath.slice(0, getBreadcrumbIndex(index) + 1))?.slotName }}
          </button>
        </template>
      </nav>

      <!-- Scrollable Content Area -->
      <div class="scrollable-content">
        <!-- Search Results View -->
        <div v-if="hasActiveSearch">
          <div v-if="searchResults.length === 0" class="state-message">
            <p>No parts found matching "{{ activeSearchQuery }}"</p>
          </div>

          <div v-else class="search-results">
            <section
              v-for="result in searchResults"
              :key="result.slotPath"
              class="search-result-section"
              :class="{ collapsed: !openSearchSections[result.slotPath] }"
            >
              <button
                class="section-caption result-section-header"
                type="button"
                :aria-expanded="!!openSearchSections[result.slotPath]"
                @click.stop="toggleSearchSection(result.slotPath)"
                @mousedown.stop
              >
                <span class="caption-text">{{ result.slotNiceName || result.slotName }}</span>
                <svg class="chevron-icon" :class="{ open: openSearchSections[result.slotPath] }" viewBox="0 0 24 24" aria-hidden="true">
                  <path d="m6 9 6 6 6-6" />
                </svg>
              </button>

              <div v-if="openSearchSections[result.slotPath]" class="parts-list result-parts-list">
                <div
                  v-for="part in result.parts"
                  :key="part.name"
                  class="part-item option-item"
                  :class="{ installed: part.installed }"
                >
                  <div class="part-info option-info">
                    <span class="part-name">{{ part.niceName || part.name }}</span>
                    <span class="price option-price"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(part.value) }}</span>
                  </div>
                  <div class="option-actions">
                    <div v-if="part.installed" class="installed-button-wrapper">
                      <HouseButton
                        v-if="result.canRemove !== true"
                        class="part-action"
                        variant="quiet"
                        compact
                        disabled
                      >
                        Installed
                      </HouseButton>
                      <template v-else>
                        <HouseButton
                          class="part-action"
                          variant="quiet"
                          compact
                          @click.stop="toggleRemoveMenu(result.slotPath, part.name)"
                        >
                          Installed
                          <svg class="menu-chevron" viewBox="0 0 24 24" aria-hidden="true"><path d="m6 9 6 6 6-6" /></svg>
                        </HouseButton>
                        <div v-if="removeMenuVisible === `${result.slotPath}_${part.name}`" class="pop-menu remove-menu">
                          <HouseButton variant="menu" class="remove-menu-item" @click="removePart(part, result)">
                            Remove
                          </HouseButton>
                        </div>
                      </template>
                    </div>
                    <div v-else class="install-button-wrapper">
                      <HouseButton
                        v-if="!hasOwnedVariants(part)"
                        class="part-action"
                        compact
                        @click="installPart(part, result)"
                      >
                        Install
                      </HouseButton>
                      <div v-else class="install-dropdown-wrapper">
                        <HouseButton
                          class="part-action"
                          compact
                          @click.stop="toggleInstallMenu(result.slotPath, part.name)"
                        >
                          Install
                          <svg class="menu-chevron" viewBox="0 0 24 24" aria-hidden="true"><path d="m6 9 6 6 6-6" /></svg>
                        </HouseButton>
                        <div v-if="installMenuVisible === `${result.slotPath}_${part.name}`" class="pop-menu install-menu">
                          <HouseButton v-if="!part.fromInventory" variant="menu" class="install-menu-item-button" @click="installPart(part, result)">
                            <span class="menu-label">New</span>
                            <span class="price price-badge"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(part.value) }}</span>
                          </HouseButton>
                          <HouseButton
                            v-for="usedPart in getOwnedVariants(part)"
                            :key="usedPart.partId"
                            variant="menu"
                            class="install-menu-item-button"
                            @click="installUsedPart(usedPart, result)"
                          >
                            <span class="menu-label">Owned</span>
                            <span class="mileage-badge">{{ formatMileage(getUsedPartMileage(usedPart)) }}</span>
                            <span class="price price-badge"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(usedPart.finalValue || usedPart.value) }}</span>
                          </HouseButton>
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </section>
          </div>
        </div>

        <!-- Normal Navigation View -->
        <div v-else>
          <!-- Parts Options (if available) -->
          <section v-if="currentCategoryOptions && currentCategoryOptions.length > 0" class="parts-options-section" :class="{ collapsed: !isPartsOpen }">
            <button
              class="section-caption options-header"
              type="button"
              :aria-expanded="isPartsOpen"
              @click.stop="isPartsOpen = !isPartsOpen"
              @mousedown.stop
            >
              <span class="caption-text">{{ currentCategory?.slotNiceName || currentCategory?.slotName }} parts</span>
              <span class="current-part-chip installed-summary">{{ installedPartLabel }}</span>
              <svg class="chevron-icon" :class="{ open: isPartsOpen }" viewBox="0 0 24 24" aria-hidden="true">
                <path d="m6 9 6 6 6-6" />
              </svg>
            </button>

            <div v-if="isPartsOpen" class="parts-list options-list">
              <div
                v-for="option in currentCategoryOptions"
                :key="option.name"
                class="part-item option-item"
                :class="{ installed: option.installed }"
              >
                <div class="part-info option-info">
                  <span class="part-name">{{ option.niceName || option.name }}</span>
                  <span class="price option-price"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(option.value) }}</span>
                </div>
                <div class="option-actions">
                  <div v-if="option.installed" class="installed-button-wrapper">
                    <HouseButton
                      v-if="currentCategory.canRemove !== true"
                      class="part-action"
                      variant="quiet"
                      compact
                      disabled
                    >
                      Installed
                    </HouseButton>
                    <template v-else>
                      <HouseButton
                        class="part-action"
                        variant="quiet"
                        compact
                        @click.stop="toggleRemoveMenu(currentCategory.path, option.name)"
                      >
                        Installed
                        <svg class="menu-chevron" viewBox="0 0 24 24" aria-hidden="true"><path d="m6 9 6 6 6-6" /></svg>
                      </HouseButton>
                      <div v-if="removeMenuVisible === `${currentCategory.path}_${option.name}`" class="pop-menu remove-menu">
                        <HouseButton variant="menu" class="remove-menu-item" @click="removePart(option, currentCategory)">
                          Remove
                        </HouseButton>
                      </div>
                    </template>
                  </div>
                  <div v-else class="install-button-wrapper">
                    <HouseButton
                      v-if="!hasOwnedVariants(option)"
                      class="part-action"
                      compact
                      @click="installPart(option, currentCategory)"
                    >
                      Install
                    </HouseButton>
                    <div v-else class="install-dropdown-wrapper">
                      <HouseButton
                        class="part-action"
                        compact
                        @click.stop="toggleInstallMenu(currentCategory.path, option.name)"
                      >
                        Install
                        <svg class="menu-chevron" viewBox="0 0 24 24" aria-hidden="true"><path d="m6 9 6 6 6-6" /></svg>
                      </HouseButton>
                      <div v-if="installMenuVisible === `${currentCategory.path}_${option.name}`" class="pop-menu install-menu">
                        <HouseButton v-if="!option.fromInventory" variant="menu" class="install-menu-item-button" @click="installPart(option, currentCategory)">
                          <span class="menu-label">New</span>
                          <span class="price price-badge"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(option.value) }}</span>
                        </HouseButton>
                        <HouseButton
                          v-for="usedPart in getOwnedVariants(option)"
                          :key="usedPart.partId"
                          variant="menu"
                          class="install-menu-item-button"
                          @click="installUsedPart(usedPart, currentCategory)"
                        >
                          <span class="menu-label">Owned</span>
                          <span class="mileage-badge">{{ formatMileage(getUsedPartMileage(usedPart)) }}</span>
                          <span class="price price-badge"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(usedPart.finalValue || usedPart.value) }}</span>
                        </HouseButton>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </section>

          <!-- Category/Subcategory List -->
          <div v-if="displayCategories && displayCategories.length > 0" class="categories-list">
            <button
              v-for="category in displayCategories"
              :key="category.id"
              @click.stop="navigateToCategory(category)"
              @mousedown.stop
              class="category-item"
              type="button"
            >
              <span class="category-name">{{ category.slotNiceName || category.slotName }}</span>
              <span class="current-part-chip selected-part-badge">{{ category.partNiceName || '-' }}</span>
              <svg class="chevron-icon" viewBox="0 0 24 24" aria-hidden="true">
                <path d="m9 18 6-6-6-6" />
              </svg>
            </button>
          </div>

          <!-- Empty State -->
          <div v-if="partsTree.length === 0" class="state-message">
            <p>No parts available for this vehicle</p>
          </div>

          <div v-if="partsTree.length > 0 && (!displayCategories || displayCategories.length === 0) && (!currentCategoryOptions || currentCategoryOptions.length === 0)" class="state-message">
            <p>No parts available in this category</p>
          </div>
        </div>
      </div>
    </template>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, watch, onBeforeUnmount } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import { lua, useBridge } from "@/bridge"
import { BngIcon, icons } from "@/common/components/base"
import { bigLengthUnit, METERS_PER_MILE } from "../../utils/units"
import { vBngTextInput } from "@/common/directives"
import { HouseButton } from "../house"
import { useEvents } from "@/services/events"

const store = useBusinessComputerStore()
const normalizeVehicleCacheKey = (value) => {
  if (value === undefined || value === null) {
    return 'noveh'
  }
  return String(value)
}
const getCacheKeyForVehicle = () => {
  if (!store.pulledOutVehicle) {
    return null
  }
  return normalizeVehicleCacheKey(store.pulledOutVehicle.vehicleId)
}
const events = useEvents()

const searchQuery = ref("")
const activeSearchQuery = ref("")
const navigationPath = ref([])
const isPartsOpen = ref(false)
const partsTree = ref([])
const slotsNiceName = ref({})
const partsNiceName = ref({})
const loading = ref(true) // Start with loading = true to show loading message immediately
const openSearchSections = ref({})
const removeMenuVisible = ref(null)
const installMenuVisible = ref(null)
const lastAutoOpenedKey = ref(null)

const hasActiveSearch = computed(() => activeSearchQuery.value.length > 0)

const onSearchFocus = () => {
  try { lua.setCEFTyping(true) } catch (_) {}
}

const onSearchBlur = () => {
  try { triggerSearch() } catch (_) {}
  try { lua.setCEFTyping(false) } catch (_) {}
}

const triggerSearch = () => {
  activeSearchQuery.value = searchQuery.value.trim()
  if (hasActiveSearch.value && searchResults.value.length > 0) {
    searchResults.value.forEach(result => {
      openSearchSections.value[result.slotPath] = true
    })
  } else {
    openSearchSections.value = {}
  }
}

const toggleSearchSection = (slotPath) => {
  openSearchSections.value[slotPath] = !openSearchSections.value[slotPath]
}

const clearSearch = () => {
  searchQuery.value = ""
  activeSearchQuery.value = ""
  openSearchSections.value = {}
  try { lua.setCEFTyping(false) } catch (_) {}
}

const searchResults = computed(() => {
  if (!hasActiveSearch.value || !partsTree.value.length) return []
  
  const query = activeSearchQuery.value.toLowerCase()
  const results = []
  const slotMap = {}
  
  // Recursively search through the parts tree
  const searchTree = (nodes) => {
    if (!nodes || !Array.isArray(nodes)) return
    
    nodes.forEach(node => {
      // Check if this slot has parts that match
      if (node.availableParts && node.availableParts.length > 0) {
        const matchingParts = node.availableParts.filter(part => {
          const partName = (part.niceName || part.name || '').toLowerCase()
          return partName.includes(query)
        })
        
        if (matchingParts.length > 0) {
          const slotKey = node.path || node.id
          if (!slotMap[slotKey]) {
            slotMap[slotKey] = {
              slotPath: slotKey,
              slotName: node.slotName || '',
              slotNiceName: node.slotNiceName || node.slotName || '',
              canRemove: node.canRemove === true,
              parts: [],
              compatibleInventoryParts: node.compatibleInventoryParts || []
            }
            results.push(slotMap[slotKey])
          }
          slotMap[slotKey].parts.push(...matchingParts)
        }
      }
      
      // Recursively search children
      if (node.children && node.children.length > 0) {
        searchTree(node.children)
      }
    })
  }
  
  searchTree(partsTree.value)
  
  return results.map(result => ({
    ...result,
    parts: [...result.parts].sort((a, b) => {
      const nameA = (a.niceName || a.name || '').toLowerCase()
      const nameB = (b.niceName || b.name || '').toLowerCase()
      return nameA.localeCompare(nameB)
    })
  })).sort((a, b) => {
    const nameA = (a.slotNiceName || a.slotName || '').toLowerCase()
    const nameB = (b.slotNiceName || b.slotName || '').toLowerCase()
    return nameA.localeCompare(nameB)
  })
})

const getCategoryByPath = (path) => {
  if (!path || path.length === 0) return null
  
  let current = null
  let categories = partsTree.value
  
  for (const pathId of path) {
    current = categories.find(cat => cat.id === pathId)
    if (!current) return null
    if (current.children && current.children.length > 0) {
      categories = current.children
    } else {
      break
    }
  }
  
  return current || null
}

const currentCategory = computed(() => {
  return getCategoryByPath(navigationPath.value)
})

const currentCategoryOptions = computed(() => {
  const parts = currentCategory.value?.availableParts || null
  if (!parts) return null
  return [...parts].sort((a, b) => {
    const nameA = (a.niceName || a.name || '').toLowerCase()
    const nameB = (b.niceName || b.name || '').toLowerCase()
    return nameA.localeCompare(nameB)
  })
})

const shouldAutoOpenParts = () => {
  const options = currentCategoryOptions.value
  if (!options || options.length === 0) return false

  const childCount = Array.isArray(displayCategories.value) ? displayCategories.value.length : 0
  const noCategories = childCount === 0
  const singleChild = childCount === 1

  if (options.length === 1) return true
  if (noCategories) return true
  if (singleChild) return true

  return false
}

const getAutoOpenKey = () => {
  const nav = (navigationPath.value || []).join('>')
  const path = currentCategory.value?.path || ''
  return `${nav}|${path}`
}

const displayCategories = computed(() => {
  let categories = []
  if (navigationPath.value.length === 0) {
    categories = partsTree.value
  } else {
    const category = getCategoryByPath(navigationPath.value)
    categories = category?.children || []
  }
  return [...categories].sort((a, b) => {
    const nameA = (a.slotNiceName || a.slotName || '').toLowerCase()
    const nameB = (b.slotNiceName || b.slotName || '').toLowerCase()
    return nameA.localeCompare(nameB)
  })
})

const visibleBreadcrumbs = computed(() => {
  const maxVisible = 3
  if (navigationPath.value.length <= maxVisible) {
    return navigationPath.value
  }
  return navigationPath.value.slice(-maxVisible)
})

const showEllipsis = computed(() => {
  return navigationPath.value.length > 3
})

const getBreadcrumbIndex = (visibleIndex) => {
  if (!showEllipsis.value) {
    return visibleIndex
  }
  const startIndex = navigationPath.value.length - visibleBreadcrumbs.value.length
  return startIndex + visibleIndex
}

const navigateToCategory = (category) => {
  navigationPath.value.push(category.id)
}

const navigateToPath = (index) => {
  if (index === -1) {
    navigationPath.value = []
  } else {
    navigationPath.value = navigationPath.value.slice(0, index + 1)
  }
}

const installPart = async (part, slot) => {
  let slotPath = slot.slotPath || slot.path
  
  if (!slotPath.startsWith('/')) {
    slotPath = '/' + slotPath
  }
  if (!slotPath.endsWith('/')) {
    slotPath = slotPath + '/'
  }
  
  const normalizedSlot = {
    path: slotPath,
    slotPath: slotPath,
    slotNiceName: slot.slotNiceName || slot.slotName,
    slotName: slot.slotName
  }
  
  await store.addPartToCart(part, normalizedSlot)
}

const toggleRemoveMenu = (slotPath, partName) => {
  const menuKey = `${slotPath}_${partName}`
  if (removeMenuVisible.value === menuKey) {
    removeMenuVisible.value = null
  } else {
    removeMenuVisible.value = menuKey
    installMenuVisible.value = null
  }
}

const toggleInstallMenu = (slotPath, partName) => {
  const menuKey = `${slotPath}_${partName}`
  if (installMenuVisible.value === menuKey) {
    installMenuVisible.value = null
  } else {
    installMenuVisible.value = menuKey
    removeMenuVisible.value = null
  }
}

const { units } = useBridge()

// part odometer (metres) in the player's distance unit, compact past 1000: "850 km", "12.3k mi"
const formatMileage = (metres) => {
  const { perMetre, unit } = bigLengthUnit(units)
  const dist = (Number(metres) || 0) * perMetre
  if (!dist) return `0 ${unit}`
  if (dist < 1000) return `${Math.round(dist)} ${unit}`
  return `${(dist / 1000).toFixed(1)}k ${unit}`
}

const formatPrice = (value) => {
  const num = value || 0
  return num.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

// metres: the part odometer, else Lua's variant.mileage, which is miles (odometer / 1609.344)
const getUsedPartMileage = (usedPart) => {
  if (!usedPart) return 0
  const odometer = usedPart.partCondition?.odometer
  if (typeof odometer === "number") return odometer
  return typeof usedPart.mileage === "number" ? usedPart.mileage * METERS_PER_MILE : 0
}

const getOwnedVariants = (part) => {
  if (!part) return []
  if (Array.isArray(part.ownedVariants) && part.ownedVariants.length > 0) {
    return part.ownedVariants
  }
  if (part.fromInventory && part.partId) {
    return [{
      partId: part.partId,
      name: part.name,
      partCondition: part.partCondition,
      finalValue: part.finalValue,
      value: part.value,
      mileage: part.mileage
    }]
  }
  return []
}

const hasOwnedVariants = (part) => {
  return getOwnedVariants(part).length > 0
}

const installedPartLabel = computed(() => {
  const options = currentCategoryOptions.value
  if (options && options.length > 0) {
    const installedOption = options.find(opt => opt.installed)
    if (installedOption) {
      return installedOption.niceName || installedOption.name || '-'
    }
  }
  const categoryPart = currentCategory.value?.partNiceName
  if (categoryPart && categoryPart !== '-') {
    return categoryPart
  }
  return '-'
})

const installUsedPart = async (usedPart, slot) => {
  installMenuVisible.value = null
  
  let slotPath = slot.slotPath || slot.path
  if (!slotPath.startsWith('/')) {
    slotPath = '/' + slotPath
  }
  if (!slotPath.endsWith('/')) {
    slotPath = slotPath + '/'
  }
  
  const normalizedSlot = {
    path: slotPath,
    slotPath: slotPath,
    slotNiceName: slot.slotNiceName || slot.slotName,
    slotName: slot.slotName
  }
  
  const partToAdd = {
    name: usedPart.name,
    partName: usedPart.name,
    partNiceName: usedPart.niceName || usedPart.name,
    value: usedPart.finalValue || usedPart.value || 0,
    fromInventory: true,
    partId: usedPart.partId,
    partCondition: usedPart.partCondition,
    mileage: usedPart.mileage
  }
  
  await store.addPartToCart(partToAdd, normalizedSlot)
}

const removePart = async (part, slot) => {
  removeMenuVisible.value = null
  
  let slotPath = slot.slotPath || slot.path
  
  if (!slotPath.startsWith('/')) {
    slotPath = '/' + slotPath
  }
  if (!slotPath.endsWith('/')) {
    slotPath = slotPath + '/'
  }
  
  await store.removePartBySlotPath(slotPath)
  
  setTimeout(() => {
    loadPartsTree()
  }, 300)
}

const handlePartsTreeData = (data) => {
  if (!data || !data.success) {
    partsTree.value = []
    slotsNiceName.value = {}
    partsNiceName.value = {}
    loading.value = false
    return
  }
  
  if (
    String(data.vehicleId) === String(store.pulledOutVehicle?.vehicleId) &&
    String(data.businessId) === String(store.businessId)
  ) {
    if (data.partsTree) {
      const cacheKey = normalizeVehicleCacheKey(data.vehicleId)
      if (store.partsTreeCache) {
        store.partsTreeCache[cacheKey] = {
          vehicleId: data.vehicleId,
          partsTree: data.partsTree,
          slotsNiceName: data.slotsNiceName,
          partsNiceName: data.partsNiceName
        }
      }
      
      slotsNiceName.value = data.slotsNiceName || {}
      partsNiceName.value = data.partsNiceName || {}
      const tree = buildHierarchy(data.partsTree, data.slotsNiceName || {})
      partsTree.value = tree
    } else {
      partsTree.value = []
      slotsNiceName.value = {}
      partsNiceName.value = {}
    }
    loading.value = false
  } else {
    loading.value = false
  }
}

const loadPartsTree = async () => {
  if (!store.pulledOutVehicle || !store.businessId) {
    loading.value = false
    return
  }
  
  loading.value = true
  
  const cacheKey = getCacheKeyForVehicle()
  const cachedEntry = cacheKey && store.partsTreeCache && store.partsTreeCache[cacheKey]
  if (cachedEntry && cachedEntry.vehicleId === store.pulledOutVehicle.vehicleId) {
    slotsNiceName.value = cachedEntry.slotsNiceName || {}
    partsNiceName.value = cachedEntry.partsNiceName || {}
    const tree = buildHierarchy(cachedEntry.partsTree || [], cachedEntry.slotsNiceName || {})
    partsTree.value = tree
    loading.value = false
    return
  }
  
  store.requestVehiclePartsTree(store.pulledOutVehicle.vehicleId).catch(error => {
    loading.value = false
  })
}

const buildHierarchy = (flatList, slotsNiceNameMap) => {
  const map = {}
  const roots = []
  
  // Helper to get or create a node
  const getOrCreateNode = (pathParts) => {
    const id = pathParts.join('-')
    if (map[id]) {
      return map[id]
    }
    
    const path = '/' + pathParts.join('/')
    const slotName = pathParts[pathParts.length - 1]
    
    // Get slot nice name from mapping
    let slotNiceName = slotName
    if (slotName && slotsNiceNameMap[slotName]) {
      slotNiceName = typeof slotsNiceNameMap[slotName] === 'object'
        ? slotsNiceNameMap[slotName].description || slotsNiceNameMap[slotName]
        : slotsNiceNameMap[slotName]
    }
    
    const node = {
      id: id,
      path: path,
      slotName: slotName,
      slotNiceName: slotNiceName,
      partNiceName: '-',
      canRemove: false,
      availableParts: [],
      children: []
    }
    
    map[id] = node
    
    // Recursively create parent if needed
    if (pathParts.length > 1) {
      const parentPathParts = pathParts.slice(0, -1)
      const parent = getOrCreateNode(parentPathParts)
      parent.children.push(node)
    } else {
      roots.push(node)
    }
    
    return node
  }
  
  // First pass: create all nodes from flat list
  flatList.forEach(slot => {
    const pathParts = slot.path.split('/').filter(p => p)
    const id = pathParts.join('-')
    const slotName = pathParts[pathParts.length - 1] || slot.slotName || ''
    
    // Get slot nice name from slot data or mapping
    let slotNiceName = slot.slotNiceName
    if (!slotNiceName && slotName && slotsNiceNameMap[slotName]) {
      slotNiceName = typeof slotsNiceNameMap[slotName] === 'object' 
        ? slotsNiceNameMap[slotName].description || slotsNiceNameMap[slotName]
        : slotsNiceNameMap[slotName]
    }
    if (!slotNiceName && slotName) {
      slotNiceName = slotName
    }
    
    // Get or create the node
    const node = getOrCreateNode(pathParts)
    
    // Update node with slot data
    node.slotName = slotName
    node.slotNiceName = slotNiceName
    node.partNiceName = slot.partNiceName || '-'
    node.canRemove = slot.canRemove === true
    node.availableParts = slot.availableParts || []
    node.compatibleInventoryParts = slot.compatibleInventoryParts || []
  })
  
  return roots.sort((a, b) => {
    const nameA = (a.slotNiceName || a.slotName || '').toLowerCase()
    const nameB = (b.slotNiceName || b.slotName || '').toLowerCase()
    return nameA.localeCompare(nameB)
  })
}


watch(() => store.pulledOutVehicle, (newVehicle, oldVehicle) => {
  if (!newVehicle) {
    partsTree.value = []
    navigationPath.value = []
    slotsNiceName.value = {}
    partsNiceName.value = {}
    loading.value = false
    store.clearCart()
  } else {
    navigationPath.value = []
    if (oldVehicle && newVehicle && oldVehicle.vehicleId !== newVehicle.vehicleId && store.vehicleView === 'parts') {
      loading.value = true
      setTimeout(() => {
        loadPartsTree()
      }, 100)
    }
  }
})

watch(() => searchResults.value, (newResults) => {
  if (hasActiveSearch.value && newResults.length > 0) {
    newResults.forEach(result => {
      if (openSearchSections.value[result.slotPath] === undefined) {
        openSearchSections.value[result.slotPath] = true
      }
    })
  }
}, { immediate: true })

// Watch for tab changes and reload parts tree to reflect the new tab's cart
watch(() => store.activeTabId, async (newTabId, oldTabId) => {
  if (newTabId && newTabId !== oldTabId && store.pulledOutVehicle && store.vehicleView === 'parts') {
    if (store.isCurrentTabApplied) {
      return
    }
    setTimeout(() => {
      if (!store.isCurrentTabApplied) {
        loadPartsTree()
      }
    }, 600)
  }
})

watch(currentCategoryOptions, (options) => {
  if (!options || options.length === 0) {
    isPartsOpen.value = false
    return
  }

  const key = getAutoOpenKey()
  if (shouldAutoOpenParts() && lastAutoOpenedKey.value !== key) {
    isPartsOpen.value = true
    lastAutoOpenedKey.value = key
  }
}, { immediate: true })

watch(navigationPath, () => {
  const options = currentCategoryOptions.value
  if (!options || options.length === 0) {
    isPartsOpen.value = false
    return
  }

  const key = getAutoOpenKey()
  if (shouldAutoOpenParts() && lastAutoOpenedKey.value !== key) {
    isPartsOpen.value = true
    lastAutoOpenedKey.value = key
  } else {
    isPartsOpen.value = false
  }
}, { deep: true })

const handleClickOutside = (e) => {
  if (!e.target.closest('.installed-button-wrapper')) {
    removeMenuVisible.value = null
  }
  if (!e.target.closest('.install-dropdown-wrapper')) {
    installMenuVisible.value = null
  }
}

onMounted(() => {
  // Register event listener for parts tree data
  events.on('businessComputer:onVehiclePartsTree', handlePartsTreeData)
  
  // Close remove menu when clicking outside
  document.addEventListener('click', handleClickOutside)
  
  // Wait for UI animation to complete (600ms) before requesting parts tree data
  // This ensures vehicle spawning doesn't happen until animation is finished
  requestAnimationFrame(() => {
    setTimeout(() => {
      if (store.pulledOutVehicle && store.vehicleView === 'parts') {
        loadPartsTree()
      }
    }, 600) // Wait for full animation to complete
  })
})

onBeforeUnmount(() => {
  // Clean up event listener
  events.off('businessComputer:onVehiclePartsTree', handlePartsTreeData)
  document.removeEventListener('click', handleClickOutside)
})
</script>

<style scoped lang="scss">
@import "../../styles/rlsHouse.scss";

// Same look as views/BusinessWorkshopParts.vue and the career Part Shop (Categories / SlotItem /
// PartsList): translucent slot rows with a current-part chip, part lines with gold prices,
// neutral Install, installed line brighter with an accent-soft name. No orange gradients.
.parts-customization {
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

// ---- house search field
.search-section {
  flex: 0 0 auto;
  padding: 0 0.5em 0.5em 0.75em;
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

// ---- breadcrumb: quiet text links, current slot white
.breadcrumb-nav {
  flex: 0 0 auto;
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.25em 0.4em;
  padding: 0 0.5em 0.5em 0.75em;
}
.breadcrumb-link {
  appearance: none;
  margin: 0;
  padding: 0.2em 0.1em 0.1em;
  border: 0;
  border-radius: var(--radius-thumb);
  background: transparent;
  color: var(--muted);
  font: inherit;
  font-size: 0.9em;
  font-weight: 600;
  line-height: 1.2;
  text-align: left;
  overflow-wrap: anywhere;
  cursor: pointer;
  &:hover {
    color: #fff;
  }
  @include house-focus;
  &.active {
    color: #fff;
    font-weight: 700;
    cursor: default;
  }
  &.more {
    color: var(--faint);
  }
}
.breadcrumb-separator {
  flex: 0 0 auto;
  width: 0.8em;
  height: 0.8em;
  fill: none;
  stroke: var(--faint);
  stroke-width: 2.4;
  stroke-linecap: round;
  stroke-linejoin: round;
}

// ---- scrolling list (class name is also the controller's joystick-scroll target)
.scrollable-content {
  flex: 1 1 auto;
  min-height: 0;
  padding: 0 0.35em 0.75em 0.75em;
  overflow: hidden auto;
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

// ---- section captions (Style Guide caption + hairline), fold chevron
.section-caption {
  appearance: none;
  display: flex;
  align-items: center;
  gap: 0.7em;
  width: 100%;
  margin: 0;
  padding: 0.6em 0.15em 0.45em;
  border: 0;
  border-radius: var(--radius-thumb);
  background: transparent;
  color: var(--faint);
  font: inherit;
  text-align: left;
  cursor: pointer;
  &::after {
    content: "";
    order: 1;
    flex: 1 1 auto;
    min-width: 1em;
    height: 1px;
    background: var(--line);
  }
  &:hover {
    color: #fff;
  }
  @include house-focus;
  .caption-text {
    flex: 0 1 auto;
    min-width: 0;
    font-size: 0.78em;
    font-weight: 700;
    letter-spacing: 0.06em;
    line-height: 1.2;
    text-transform: uppercase;
    overflow-wrap: anywhere;
  }
  .current-part-chip {
    order: 2;
  }
  .chevron-icon {
    order: 3;
    flex: 0 0 auto;
    width: 0.95em;
    height: 0.95em;
    fill: none;
    stroke: currentColor;
    stroke-width: 2.4;
    stroke-linecap: round;
    stroke-linejoin: round;
    transform: rotate(-90deg);
    transition: transform 0.12s;
    &.open {
      transform: rotate(0deg);
    }
  }
}

.parts-options-section {
  margin-bottom: 0.6em;
  &.collapsed {
    margin-bottom: 0.25em;
  }
}
.search-results {
  display: flex;
  flex-direction: column;
  gap: 0.25em;
}

// current-part chip (SlotItem's buy-button look): muted text on a slightly brighter tile
.current-part-chip {
  flex: 0 1 auto;
  max-width: 13em;
  padding: 0.45em 0.7em 0.32em;
  border-radius: var(--radius-tile);
  background: var(--panel-2);
  color: var(--muted);
  font-size: 0.9em;
  font-weight: 600;
  letter-spacing: 0;
  line-height: 1.2;
  text-align: right;
  text-transform: none;
  overflow-wrap: anywhere;
}

// ---- part lines
.parts-list {
  display: flex;
  flex-direction: column;
}
.part-item {
  display: flex;
  align-items: center;
  gap: var(--space-2);
  min-height: 3.6em;
  padding: 0.45em 0.5em 0.4em 0.6em;
  border-bottom: 1px solid var(--line);
  color: #fff;
  &:last-child {
    border-bottom-color: transparent;
  }
  // installed part: slightly brighter panel + accent-soft name, no orange gradient
  &.installed {
    border-radius: var(--radius-panel);
    border-bottom-color: transparent;
    background: var(--panel-2);
    .part-name {
      color: var(--accent-soft);
    }
  }
}
.part-info {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 0.25em 0.75em;
  flex: 1 1 auto;
  min-width: 0;
}
.part-name {
  flex: 1 1 10em;
  min-width: 0;
  font-size: 1.05em;
  font-weight: 700;
  line-height: 1.2;
  overflow-wrap: anywhere;
}
.price {
  color: var(--money);
  font-weight: 700;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}
.option-price {
  margin-left: auto;
  font-size: 0.95em;
}
.option-actions {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
}
.part-action {
  min-width: 6.25em;
}
.menu-chevron {
  width: 0.75em;
  height: 0.75em;
  margin-left: 0.35em;
  fill: none;
  stroke: currentColor;
  stroke-width: 2.6;
  stroke-linecap: round;
  stroke-linejoin: round;
  transform: translateY(-0.05em);
}

// ---- install / remove menus (Style Guide .menu-list)
.installed-button-wrapper,
.install-button-wrapper,
.install-dropdown-wrapper {
  position: relative;
  display: inline-block;
}
.pop-menu {
  position: absolute;
  top: calc(100% + 0.35em);
  right: 0;
  z-index: 10;
  display: grid;
  gap: 0.1em;
  width: max-content;
  min-width: 100%;
  padding: 0.35em;
  border-radius: var(--radius-panel);
  background: #1a1a1c;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08), 0 12px 28px rgba(0, 0, 0, 0.5);
}
.install-menu {
  min-width: 14em;
}
.install-menu-item-button {
  gap: 0.6em;
  .menu-label {
    font-weight: 700;
  }
  .mileage-badge {
    color: var(--faint);
    font-size: 0.85em;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
  }
  .price-badge {
    margin-left: auto;
  }
}
.pop-menu .remove-menu-item.house-button {
  color: var(--bad);
}

// ---- slot rows: translucent lines grouped as one rounded list, current-part chip on the right
.categories-list {
  display: flex;
  flex-direction: column;
  gap: 0.25em;
}
.category-item {
  appearance: none;
  display: flex;
  align-items: center;
  gap: 0.6em;
  width: 100%;
  min-height: 3.1em;
  margin: 0;
  padding: 0.4em 0.6em 0.35em 0.75em;
  border: 0;
  border-radius: var(--radius-panel);
  background: var(--panel);
  color: #fff;
  font: inherit;
  text-align: left;
  cursor: pointer;
  &:hover {
    background: var(--panel-2);
    .current-part-chip {
      color: #fff;
    }
    .chevron-icon {
      stroke: #fff;
    }
  }
  @include house-focus;
  .category-name {
    flex: 1 1 auto;
    min-width: 0;
    font-weight: 600;
    line-height: 1.25;
    overflow-wrap: anywhere;
  }
  .chevron-icon {
    flex: 0 0 auto;
    width: 0.9em;
    height: 0.9em;
    fill: none;
    stroke: var(--faint);
    stroke-width: 2.4;
    stroke-linecap: round;
    stroke-linejoin: round;
  }
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
