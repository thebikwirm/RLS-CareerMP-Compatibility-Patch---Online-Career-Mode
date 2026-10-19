<template>
  <!-- House look, same as the career ShoppingCart: plain bold heading with cart glyph and count pill,
       PART / PRICE caption header, quiet-danger remove, muted subtotal/tax, gold total on a panel,
       Confirm primary + quiet Cancel. -->
  <div class="business-shopping-cart rls-house" :class="{ expanded }" v-bng-blur>
    <!-- Confirmation Modal -->
    <Teleport to="body">
      <transition name="modal-fade">
        <div v-if="showConfirmModal" class="modal-overlay rls-house" @click.self="cancelClose">
          <div class="modal modal-content" v-bng-scoped-nav="confirmModalScope" v-bc-modal-focus v-bng-on-ui-nav:back,menu="cancelClose">
            <h3>Confirm Exit</h3>
            <p>Are you sure you want to leave this view? You will be losing progress.</p>
            <div class="modal-buttons">
              <HouseButton variant="quiet" bng-scoped-nav-autofocus @click="cancelClose">Cancel</HouseButton>
              <HouseButton variant="danger" @click="confirmCancel">Yes, Leave</HouseButton>
            </div>
          </div>
        </div>
      </transition>
    </Teleport>

    <!-- Tab Options Modal -->
    <Teleport to="body">
      <transition name="dropdown-fade">
        <div v-if="tabMenuVisible" class="tab-menu-overlay rls-house" @click.self="hideTabMenu">
          <div
            class="tab-menu-modal"
            :style="{ left: tabMenuX + 'px', top: tabMenuY + 'px' }"
            v-bng-scoped-nav="tabMenuScope" v-bc-modal-focus
            v-bng-on-ui-nav:back,menu="hideTabMenu"
            @click.stop>
            <HouseButton variant="menu" :icon="icons.edit" @click="startRenaming(tabMenuTabId)">
              Rename
            </HouseButton>
            <HouseButton variant="menu" :icon="icons.copy" @click="store.duplicateTab(tabMenuTabId); hideTabMenu()">
              Duplicate
            </HouseButton>
            <HouseButton variant="menu" :icon="icons.trashBin1" @click="clearCurrentTab(); hideTabMenu()">
              Clear
            </HouseButton>
          </div>
        </div>
      </transition>
    </Teleport>

    <div class="cart-heading">
      <BngIcon class="cart-glyph" :type="icons.shoppingCart" />
      <span class="cart-heading-text">Shopping Cart</span>
      <span v-if="itemCount" class="pill">{{ itemCount }}</span>
      <HouseButton
        class="cart-expand expand-toggle"
        variant="quiet"
        compact
        :icon="expanded ? icons.arrowLargeDown : icons.arrowLargeUp"
        :aria-label="expanded ? 'Collapse cart' : 'Expand cart'"
        @click="expanded = !expanded" />
    </div>

    <transition name="cart-collapse">
      <div v-if="expanded" class="cart-main">
        <div class="cart-tabs">
          <div class="tabs-list">
            <div v-for="tab in store.cartTabs" :key="tab.id" class="tab-wrapper"
              @contextmenu.prevent="showTabMenu($event, tab.id)">
              <button class="tab-button" type="button" :class="{ active: tab.id === store.activeTabId }"
                @click="handleTabClick(tab.id, $event)">
                <input v-if="editingTabId === tab.id" v-model="editingTabName" type="text" @focus="onRenameFocus"
                  @blur="onRenameBlur(tab.id)" @keydown.enter.stop="finishRenaming(tab.id)"
                  @keydown.esc.stop="cancelRenaming" @keydown.stop @keyup.stop @keypress.stop class="tab-rename-input"
                  v-bng-text-input :ref="el => { if (el) renameInput = el }" @click.stop @mousedown.stop />
                <span v-else class="tab-name">{{ tab.name }}</span>
                <button v-if="store.cartTabs.length > 1" class="tab-close" type="button" aria-label="Close build"
                  @click.stop="store.deleteTab(tab.id)">
                  <svg viewBox="0 0 24 24" aria-hidden="true">
                    <path d="M18 6 6 18M6 6l12 12" />
                  </svg>
                </button>
              </button>
            </div>
            <button class="tab-add" type="button" @click="store.createNewTab" title="New Build" aria-label="New build">
              <svg viewBox="0 0 24 24" aria-hidden="true">
                <path d="M12 5v14M5 12h14" />
              </svg>
            </button>
          </div>
        </div>

        <div class="cart-row cart-header">
          <div></div>
          <div>Part</div>
          <div>Price</div>
        </div>

        <div class="cart-list">
          <div v-if="partsItems.length === 0 && tuningItems.length === 0" class="empty cart-empty">
            <BngIcon class="cart-empty-glyph" :type="icons.shoppingCart" />
            <p>Cart is empty</p>
          </div>

          <template v-if="partsItems.length > 0">
            <div class="cart-section">
              <button class="cart-section-header" type="button" :aria-expanded="!partsSectionCollapsed"
                @click="partsSectionCollapsed = !partsSectionCollapsed">
                <span class="section-title">Parts</span>
                <span class="section-subtotal"><BngIcon class="cur" :type="icons.beamCurrency" />{{ partsCost.toLocaleString('en-US', {
                  minimumFractionDigits: 2, maximumFractionDigits: 2
                }) }}</span>
                <svg class="section-chevron" viewBox="0 0 24 24" aria-hidden="true" :class="{ rotated: partsSectionCollapsed }">
                  <path d="m6 9 6 6 6-6" />
                </svg>
              </button>
              <transition name="section-collapse">
                <div v-if="!partsSectionCollapsed" class="section-content">
                  <PartsTreeItem v-for="node in store.partsTree" :key="node.id" :node="node" :level="0"
                    @remove="store.removePartFromCart" />
                </div>
              </transition>
            </div>
          </template>

          <template v-if="tuningItems.length > 0">
            <div class="cart-section">
              <button class="cart-section-header" type="button" :aria-expanded="!tuningSectionCollapsed"
                @click="tuningSectionCollapsed = !tuningSectionCollapsed">
                <span class="section-title">Tuning</span>
                <span class="section-subtotal"><BngIcon class="cur" :type="icons.beamCurrency" />{{ tuningCost.toLocaleString('en-US', {
                  minimumFractionDigits: 2, maximumFractionDigits: 2
                }) }}</span>
                <svg class="section-chevron" viewBox="0 0 24 24" aria-hidden="true" :class="{ rotated: tuningSectionCollapsed }">
                  <path d="m6 9 6 6 6-6" />
                </svg>
              </button>
              <transition name="section-collapse">
                <div v-if="!tuningSectionCollapsed" class="section-content">
                  <div v-for="item in tuningItems" :key="`${item.type}-${item.varName}-${item.level || 1}`"
                    class="cart-row cart-item" :class="{
                      'cart-item-category': item.type === 'category',
                      'cart-item-subcategory': item.type === 'subCategory',
                      'cart-item-variable': item.type === 'variable'
                    }">
                    <div>
                      <HouseButton v-if="item.type === 'variable'" class="cart-remove remove-button"
                        variant="quiet-danger" compact :icon="icons.abandon"
                        :aria-label="`Remove ${item.title || item.varName}`"
                        @click="store.removeTuningFromCart(item.varName)" />
                    </div>
                    <div class="item-info" :style="{ paddingLeft: `${((item.level || 1) - 1) * 1}em` }">
                      <div class="item-name" :class="{ 'item-name-header': item.type !== 'variable' }">
                        {{ item.title || item.varName }}
                      </div>
                      <div
                        v-if="item.type === 'variable' && item.value !== undefined && item.originalValue !== undefined"
                        class="item-slot">
                        {{ convertToDisplayValue(item, item.originalValue) }} → {{ convertToDisplayValue(item,
                          item.value) }}
                      </div>
                    </div>
                    <div class="price item-price"><BngIcon class="cur" :type="icons.beamCurrency" />{{ (item.visualPrice !== undefined ? item.visualPrice : (item.price ||
                      0)).toLocaleString('en-US', {
                        minimumFractionDigits: 2,
                        maximumFractionDigits: 2
                      }) }}</div>
                  </div>
                </div>
              </transition>
            </div>
          </template>
        </div>

        <div class="cart-footer">
          <transition name="footer-collapse">
            <div v-if="!footerCollapsed" class="footer-details">
              <div v-if="store.hasDynoUpgrade" class="power-weight-stats">

                <div class="performance-section-header">
                  <span class="section-title">Performance</span>
                  <div class="seg bar view-toggles">
                    <button class="toggle-btn" type="button" :class="{ active: performanceViewMode === 'stats' }"
                      :disabled="!hasDynoData" :bng-no-nav="(!hasDynoData) ? 'true' : null" @click="performanceViewMode = 'stats'">
                      Stats
                    </button>
                    <button class="toggle-btn" type="button" :class="{ active: performanceViewMode === 'dyno' }"
                      :disabled="!hasDynoData" :bng-no-nav="(!hasDynoData) ? 'true' : null" @click="performanceViewMode = 'dyno'">
                      Dyno
                    </button>
                  </div>
                </div>

                <div v-if="hasDynoData && performanceViewMode === 'stats'" class="stats-container">
                  <div class="stat-row">
                    <div class="stat-label-col">Power</div>
                    <div class="stat-value-col">{{ dynoPowerStr(store.originalPower) }} <small>{{ Math.round(store.originalPower || 0) }} raw</small></div>
                    <div class="stat-arrow-col">
                      <svg viewBox="0 0 24 24" aria-hidden="true">
                        <path d="M5 12h14M12 5l7 7-7 7" />
                      </svg>
                    </div>
                    <div class="stat-value-col is-new">{{ dynoPowerStr(store.currentPower) }} <small>{{ Math.round(store.currentPower || 0) }} raw</small></div>
                  </div>
                  <div class="stat-row">
                    <div class="stat-label-col">Weight</div>
                    <div class="stat-value-col">{{ weightStr(store.originalWeight) }}</div>
                    <div class="stat-arrow-col">
                      <svg viewBox="0 0 24 24" aria-hidden="true">
                        <path d="M5 12h14M12 5l7 7-7 7" />
                      </svg>
                    </div>
                    <div class="stat-value-col is-new">{{ weightStr(store.currentWeight) }}</div>
                  </div>
                  <div class="stat-row">
                    <div class="stat-label-col">Power / weight</div>
                    <div class="stat-value-col">{{ store.originalPowerToWeightRatio ?
                      store.originalPowerToWeightRatio.toFixed(2) : '-' }}</div>
                    <div class="stat-arrow-col">
                      <svg viewBox="0 0 24 24" aria-hidden="true">
                        <path d="M5 12h14M12 5l7 7-7 7" />
                      </svg>
                    </div>
                    <div class="stat-value-col is-new">{{ store.powerToWeightRatio ? store.powerToWeightRatio.toFixed(2) : '-'
                    }}</div>
                  </div>
                </div>

                <div v-else-if="hasDynoData && performanceViewMode === 'dyno'" class="dyno-container">
                  <svg class="dyno-graph" width="100%" height="100%" viewBox="0 0 300 140" preserveAspectRatio="none"
                    @mousemove="handleGraphMouseMove" @mouseleave="handleGraphLeave">
                    <!-- Grid lines -->
                    <line x1="30" y1="30" x2="270" y2="30" stroke="rgba(255,255,255,0.1)" stroke-width="1" />
                    <line x1="30" y1="60" x2="270" y2="60" stroke="rgba(255,255,255,0.1)" stroke-width="1" />
                    <line x1="30" y1="90" x2="270" y2="90" stroke="rgba(255,255,255,0.1)" stroke-width="1" />

                    <!-- Y Axis Labels (Torque - Left) -->
                    <text x="25" y="34" text-anchor="end" fill="rgba(255,255,255,0.55)" font-size="10">{{ torqueVal(maxTorque * 0.75) }}</text>
                    <text x="25" y="64" text-anchor="end" fill="rgba(255,255,255,0.55)" font-size="10">{{ torqueVal(maxTorque * 0.5) }}</text>
                    <text x="25" y="94" text-anchor="end" fill="rgba(255,255,255,0.55)" font-size="10">{{ torqueVal(maxTorque * 0.25) }}</text>

                    <!-- Y Axis Labels (Power - Right) -->
                    <text x="275" y="34" text-anchor="start" fill="#ffb27a" font-size="10">{{ powerVal(maxPower * 0.75) }}</text>
                    <text x="275" y="64" text-anchor="start" fill="#ffb27a" font-size="10">{{ powerVal(maxPower * 0.5) }}</text>
                    <text x="275" y="94" text-anchor="start" fill="#ffb27a" font-size="10">{{ powerVal(maxPower * 0.25) }}</text>

                    <!-- X Axis Labels -->
                    <text x="30" y="135" text-anchor="start" fill="rgba(255,255,255,0.55)" font-size="10">0</text>
                    <text x="150" y="135" text-anchor="middle" fill="rgba(255,255,255,0.55)" font-size="10">{{
                      Math.round(maxRpm
                        * 0.5) }}</text>
                    <text x="270" y="135" text-anchor="end" fill="rgba(255,255,255,0.55)" font-size="10">{{
                      Math.round(maxRpm)
                    }}</text>

                    <!-- Graphs -->
                    <!-- Original (Before) - Dashed -->
                    <path v-if="originalTorquePath" :d="originalTorquePath" fill="none" stroke="rgba(255,255,255,0.3)"
                      stroke-width="2" stroke-dasharray="4" />
                    <path v-if="originalPowerPath" :d="originalPowerPath" fill="none" stroke="rgba(255,178,122,0.35)"
                      stroke-width="2" stroke-dasharray="4" />

                    <!-- Current (After) - Solid -->
                    <path :d="torquePath" fill="none" stroke="rgba(255,255,255,0.85)" stroke-width="2" />
                    <path :d="powerPath" fill="none" stroke="#ffb27a" stroke-width="2" />

                    <!-- Hover Indicator -->
                    <g v-if="graphHover">
                      <line :x1="graphHover.x" y1="0" :x2="graphHover.x" y2="120" stroke="rgba(255,255,255,0.5)"
                        stroke-width="1" stroke-dasharray="4" />

                      <!-- Tooltip Background -->
                      <rect :x="graphHover.tooltipX" :y="graphHover.tooltipY" width="110" height="60" rx="6"
                        fill="#1a1a1c" stroke="rgba(255,255,255,0.08)" stroke-width="1" />

                      <!-- Tooltip Text -->
                      <text :x="graphHover.tooltipX + 55" :y="graphHover.tooltipY + 14" text-anchor="middle"
                        fill="#ffb27a" font-size="10" font-weight="bold">
                        {{ powerVal(graphHover.power) }} {{ powerUnit }}
                        <tspan v-if="graphHover.originalPower" fill="rgba(255,178,122,0.55)" font-size="9"> ({{
                          powerVal(graphHover.originalPower) }})</tspan>
                      </text>
                      <text :x="graphHover.tooltipX + 55" :y="graphHover.tooltipY + 26" text-anchor="middle"
                        fill="rgba(255,255,255,0.72)" font-size="10">
                        {{ torqueVal(graphHover.torque) }} {{ torqueUnit }}
                        <tspan v-if="graphHover.originalTorque" fill="rgba(255,255,255,0.45)" font-size="9"> ({{
                          torqueVal(graphHover.originalTorque) }})</tspan>
                      </text>
                      <text :x="graphHover.tooltipX + 55" :y="graphHover.tooltipY + 38" text-anchor="middle"
                        fill="rgba(255,255,255,0.55)" font-size="9">@ {{ Math.round(graphHover.rpm) }} RPM</text>
                    </g>

                    <!-- Transparent interaction layer -->
                    <rect x="0" y="0" width="300" height="140" fill="transparent" />
                  </svg>
                </div>
                <div v-else class="dyno-placeholder">
                  <p class="hint">Waiting for dyno data…</p>
                  <HouseButton compact @click.stop="requestDynoData" @mousedown.stop="requestDynoData">
                    Refresh Dyno
                  </HouseButton>
                </div>
              </div>
              <div class="cart-summary-breakdown">
                <div class="cart-row cart-subtotal summary-row">
                  <div></div>
                  <div>Subtotal</div>
                  <div class="price"><BngIcon class="cur" :type="icons.beamCurrency" />{{ subtotal.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
                  }}</div>
                </div>
                <div class="cart-row cart-tax summary-row">
                  <div></div>
                  <div>Sales tax (7%)</div>
                  <div class="price"><BngIcon class="cur" :type="icons.beamCurrency" />{{ taxAmount.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
                  }}</div>
                </div>
              </div>
            </div>
          </transition>
          <div class="cart-row cart-total cart-total-wrapper">
            <div>
              <button class="footer-toggle" type="button" @click="footerCollapsed = !footerCollapsed"
                :title="footerCollapsed ? 'Show details' : 'Hide details'"
                :aria-label="footerCollapsed ? 'Show details' : 'Hide details'">
                <svg viewBox="0 0 24 24" aria-hidden="true" :class="{ rotated: footerCollapsed }">
                  <path d="m6 9 6 6 6-6" />
                </svg>
              </button>
            </div>
            <div>Total</div>
            <div class="price total-amount"><BngIcon class="cur" :type="icons.beamCurrency" />{{ totalCost.toLocaleString('en-US', {
              minimumFractionDigits: 2,
              maximumFractionDigits: 2
            }) }}</div>
          </div>
          <div class="cart-buttons">
            <HouseButton
              class="cart-btn cart-btn-primary btn-hold"
              variant="primary"
              :class="{ 'is-holding': isHolding, 'is-processing': isProcessing }"
              :disabled="!canPurchase || isProcessing"
              @mousedown.stop="startHold"
              @mouseup.stop="endHold"
              @mouseleave="endHold"
              @touchstart.stop.prevent="startHold"
              @touchend.stop.prevent="endHold"
              @touchcancel.stop="endHold"
              @click.stop.prevent
            >
              <span class="hold-progress" :style="{ transform: `scaleX(${holdProgress / 100})` }"></span>
              {{ isProcessing ? 'Processing…' : (totalCost > 0 ? 'Hold to Purchase' : 'Hold to Apply') }}
            </HouseButton>
            <HouseButton class="cart-btn" variant="quiet" @click="cancel">Cancel</HouseButton>
          </div>
        </div>
      </div>
    </transition>

    <transition name="cart-collapse">
      <div v-if="!expanded" class="cart-collapsed">
        <div class="cart-summary">
          <span>{{ itemCount }} item{{ itemCount !== 1 ? 's' : '' }}</span>
          <span class="summary-total"><BngIcon class="cur" :type="icons.beamCurrency" />{{ totalCost.toLocaleString('en-US', {
            minimumFractionDigits: 2,
            maximumFractionDigits: 2
          }) }}</span>
        </div>
      </div>
    </transition>
  </div>
</template>

<script setup>
import { ref, computed, watch, onMounted, onBeforeUnmount, Teleport, nextTick } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"

const confirmModalScope = bcModalScope("cart-leave")
const tabMenuScope = bcModalScope("cart-tab-menu")
import { lua, useBridge } from "@/bridge"
import { useEvents } from "@/services/events"
import { vBngBlur, vBngTextInput, vBngScopedNav, vBngOnUiNav } from "@/common/directives"
import { bcModalScope, vBcModalFocus } from "./bcModalNav"
import { BngIcon, icons } from "@/common/components/base"
import { HouseButton } from "../house"
import PartsTreeItem from "./PartsTreeItem.vue"

const store = useBusinessComputerStore()
const events = useEvents()

// Handle power/weight data from Lua
const handlePowerWeightData = (data) => {
  store.handlePowerWeightData(data)
  // Legacy handling removed in favor of TorqueCurveChanged
}

const torqueData = ref(null)
const powerData = ref(null)
const originalTorqueData = ref(null)
const originalPowerData = ref(null)
const maxPowerValue = ref(0)
const maxTorqueValue = ref(0)
const maxRpmValue = ref(0)

const processCurveData = (data) => {
  if (!data) return null

  let curves = []
  if (data.curves) {
    if (Array.isArray(data.curves)) {
      curves = data.curves
    } else if (typeof data.curves === 'object') {
      curves = Object.values(data.curves)
    }
  } else if (Array.isArray(data)) {
    curves = data
  } else {
    curves = [data]
  }

  let bestCurve = null
  let highestMaxPower = -1

  for (const curve of curves) {
    let currentMaxPower = 0
    for (const rpm in curve.power) {
      const val = curve.power[rpm]
      if (val > currentMaxPower) currentMaxPower = val
    }

    if (currentMaxPower > highestMaxPower) {
      highestMaxPower = currentMaxPower
      bestCurve = curve
    }
  }

  if (bestCurve) {
    const tPoints = []
    for (const rpm in bestCurve.torque) {
      tPoints.push([parseInt(rpm), bestCurve.torque[rpm]])
    }
    tPoints.sort((a, b) => a[0] - b[0])

    const pPoints = []
    for (const rpm in bestCurve.power) {
      const rawVal = bestCurve.power[rpm]
      const hpVal = rawVal > 10000 ? rawVal * 0.00135962 : rawVal // watts -> PS
      pPoints.push([parseInt(rpm), hpVal])
    }
    pPoints.sort((a, b) => a[0] - b[0])

    return {
      torque: tPoints,
      power: pPoints,
      maxRpm: data.maxRPM || 8000
    }
  }
  return null
}

const onTorqueCurveChanged = (data) => {
  if (!data) return

  const processed = processCurveData(data)
  if (processed) {
    // If cart is empty and we don't have original data yet, save it
    if (store.partsCart.length === 0 && store.tuningCart.length === 0 && !store.originalCurveData) {
      store.originalCurveData = data
    }

    // If we have original data in store, process it for display
    if (store.originalCurveData) {
      const originalProcessed = processCurveData(store.originalCurveData)
      if (originalProcessed) {
        originalTorqueData.value = originalProcessed.torque
        originalPowerData.value = originalProcessed.power
      }
    }

    torqueData.value = processed.torque
    powerData.value = processed.power
    maxRpmValue.value = processed.maxRpm

    // Calculate max values across both datasets
    let maxT = 0
    const allTorque = [...(torqueData.value || []), ...(originalTorqueData.value || [])]
    for (const p of allTorque) {
      if (p[1] > maxT) maxT = p[1]
    }
    maxTorqueValue.value = maxT

    let maxP = 0
    const allPower = [...(powerData.value || []), ...(originalPowerData.value || [])]
    for (const p of allPower) {
      if (p[1] > maxP) maxP = p[1]
    }
    maxPowerValue.value = maxP
  }
}

onMounted(() => {
  events.on('TorqueCurveChanged', onTorqueCurveChanged)
  if (window.bngApi) {
    window.bngApi.activeObjectLua('controller.mainController.sendTorqueData()')
  }
  loadBalance()
})

onBeforeUnmount(() => {
  events.off('TorqueCurveChanged', onTorqueCurveChanged)
})
const performanceViewMode = ref('stats') // 'stats' or 'dyno'

const torqueGraphPoints = computed(() => {
  if (!torqueData.value) return []
  return torqueData.value.map(p => ({ rpm: p[0], val: p[1] }))
})

const powerGraphPoints = computed(() => {
  if (!powerData.value) return []
  return powerData.value.map(p => ({ rpm: p[0], val: p[1] }))
})

const originalTorqueGraphPoints = computed(() => {
  if (!originalTorqueData.value) return []
  return originalTorqueData.value.map(p => ({ rpm: p[0], val: p[1] }))
})

const originalPowerGraphPoints = computed(() => {
  if (!originalPowerData.value) return []
  return originalPowerData.value.map(p => ({ rpm: p[0], val: p[1] }))
})

const maxRpm = computed(() => maxRpmValue.value || 8000)
const maxTorque = computed(() => maxTorqueValue.value || 500)
const maxPower = computed(() => maxPowerValue.value || 500)

const graphHover = ref(null)

const handleGraphMouseMove = (e) => {
  if (!torqueGraphPoints.value.length && !powerGraphPoints.value.length) return

  const svg = e.currentTarget
  const pt = svg.createSVGPoint()
  pt.x = e.clientX
  pt.y = e.clientY
  const svgP = pt.matrixTransform(svg.getScreenCTM().inverse())

  const width = 300
  const height = 120
  const paddingLeft = 30
  const paddingRight = 30

  const availableWidth = width - paddingLeft - paddingRight

  let clickRpm = ((svgP.x - paddingLeft) / availableWidth) * maxRpm.value
  clickRpm = Math.max(0, Math.min(maxRpm.value, clickRpm))

  // Find closest points
  const findClosest = (points) => {
    if (!points.length) return null
    let closest = points[0]
    let minDiff = Math.abs(points[0].rpm - clickRpm)
    for (let i = 1; i < points.length; i++) {
      const diff = Math.abs(points[i].rpm - clickRpm)
      if (diff < minDiff) {
        minDiff = diff
        closest = points[i]
      }
    }
    return closest
  }

  const closestTorque = findClosest(torqueGraphPoints.value)
  const closestPower = findClosest(powerGraphPoints.value)
  const closestOriginalTorque = findClosest(originalTorqueGraphPoints.value)
  const closestOriginalPower = findClosest(originalPowerGraphPoints.value)

  const displayRpm = closestTorque ? closestTorque.rpm : (closestPower ? closestPower.rpm : 0)

  const scaleX = availableWidth / maxRpm.value
  const x = paddingLeft + displayRpm * scaleX

  let tooltipX = x - 45
  let tooltipY = 10

  if (tooltipX < 0) tooltipX = 0
  if (tooltipX > width - 90) tooltipX = width - 90

  graphHover.value = {
    x,
    rpm: displayRpm,
    torque: closestTorque ? closestTorque.val : 0,
    power: closestPower ? closestPower.val : 0,
    originalTorque: closestOriginalTorque ? closestOriginalTorque.val : 0,
    originalPower: closestOriginalPower ? closestOriginalPower.val : 0,
    tooltipX,
    tooltipY
  }
}

const handleGraphLeave = () => {
  graphHover.value = null
}

const makePath = (points, maxValue) => {
  if (!points.length) return ''

  const width = 300
  const height = 120
  const paddingLeft = 30
  const paddingRight = 30

  const availableWidth = width - paddingLeft - paddingRight
  const availableHeight = height

  const scaleX = availableWidth / maxRpm.value
  const scaleY = availableHeight / (maxValue * 1.1)

  let path = ''
  points.forEach((p, i) => {
    const x = paddingLeft + p.rpm * scaleX
    const y = height - p.val * scaleY
    if (i === 0) path = `M ${x} ${y}`
    else path += ` L ${x} ${y}`
  })
  return path
}

const torquePath = computed(() => makePath(torqueGraphPoints.value, maxTorque.value))
const powerPath = computed(() => makePath(powerGraphPoints.value, maxPower.value))
const originalTorquePath = computed(() => makePath(originalTorqueGraphPoints.value, maxTorque.value))
const originalPowerPath = computed(() => makePath(originalPowerGraphPoints.value, maxPower.value))

const expanded = ref(true)
const hasDynoData = computed(() => store.originalPower !== null && store.currentPower !== null)
const requestDynoData = () => {
  try {
    if (store.updatePowerWeight) {
      store.updatePowerWeight()
    }
  } catch (error) {
  }
}

// dyno power is metric hp (PS; watts above 10000), torque Nm, weight kg: shown in the player's units
const { units } = useBridge()
const dynoPowerStr = (power) => {
  const raw = Number(power)
  if (!Number.isFinite(raw)) return units.buildString("power", 0, 0)
  return units.buildString("power", raw > 10000 ? raw * 0.00135962 : raw, 0)
}
const weightStr = kg => units.buildString("weight", Number(kg) || 0, 0)
const powerVal = ps => Math.round(units.power(Number(ps) || 0)?.val ?? (Number(ps) || 0))
const torqueVal = nm => Math.round(units.torque(Number(nm) || 0)?.val ?? (Number(nm) || 0))
const powerUnit = computed(() => units.power(1)?.unit || "PS")
const torqueUnit = computed(() => units.torque(1)?.unit || "Nm")
const businessBalance = ref(0)
const tabMenuVisible = ref(false)
const tabMenuTabId = ref(null)
const tabMenuX = ref(0)
const tabMenuY = ref(0)
const editingTabId = ref(null)
const editingTabName = ref('')
const renameInput = ref(null)
const showConfirmModal = ref(false)
const footerCollapsed = ref(false)
const partsSectionCollapsed = ref(false)
const tuningSectionCollapsed = ref(false)

const HOLD_DURATION = 1000
const isHolding = ref(false)
const holdProgress = ref(0)
const holdStartTime = ref(null)
const holdAnimationId = ref(null)
const isProcessing = ref(false)

const partsItems = computed(() => store.partsCart || [])
const tuningItems = computed(() => store.tuningCart || [])

const normalizeVehicleCacheKey = (value) => {
  if (value === undefined || value === null) {
    return 'noveh'
  }
  return String(value)
}

const getVehicleCacheKey = () => {
  if (!store.pulledOutVehicle) {
    return null
  }
  return normalizeVehicleCacheKey(store.pulledOutVehicle.vehicleId)
}

const convertToDisplayValue = (item, actualValue) => {
  if (actualValue === null || actualValue === undefined) return '0'
  if (!store.tuningDataCache || !store.pulledOutVehicle) return actualValue.toFixed(2)

  const cacheKey = getVehicleCacheKey()
  if (!cacheKey) return actualValue.toFixed(2)
  const tuningData = store.tuningDataCache[cacheKey]
  if (!tuningData || !tuningData[item.varName]) return actualValue.toFixed(2)

  const varData = tuningData[item.varName]

  // Removed Wheel Alignment conversion to show real values as requested
  // Relaxed check for Wheel Alignment to ensure display values are shown
  if (varData.category === "Wheel Alignment" && varData.min !== undefined && varData.max !== undefined) {
    const actualMin = varData.min
    const actualMax = varData.max
    const range = actualMax - actualMin
    if (range > 0) {
      // Formula to convert actual value back to -1 to 1 slider range (or 0-100 depending on implementation)
      // Assuming standard BeamNG slider behavior where min/max maps to -1/1 or 0/100
      // If the original value was 0-100, we want to show that.

      // Try to determine if it's a centered slider (-1 to 1) or 0-100
      // Usually Wheel Alignment is centered.

      const sliderValue = ((actualValue - actualMin) / range) * 2 - 1
      const displayValue = Math.round(sliderValue * 100)
      return displayValue.toString()
    }
  }

  return actualValue.toFixed(2)
}

const tuningCost = computed(() => {
  return store.tuningCost || 0
})

const partsCost = computed(() => {
  const total = store.getCartTotal || 0
  const tuning = tuningCost.value
  return total - tuning
})

const salesTaxRate = 0.07 // 7% sales tax (matching vanilla)

const subtotal = computed(() => {
  return store.getCartTotal || 0
})

const taxAmount = computed(() => {
  return subtotal.value * salesTaxRate
})

const totalCost = computed(() => {
  return subtotal.value + taxAmount.value
})

const totalItems = computed(() => {
  return partsItems.value.length + tuningItems.value.length
})

// display only: priced lines for the heading pill / collapsed summary (tuning category and
// sub-category header rows are not purchases themselves)
const itemCount = computed(() =>
  partsItems.value.length + tuningItems.value.filter(item => item.type === 'variable').length
)

const canPurchase = computed(() => {
  if (!store.businessId || !store.businessType) return false
  const hasItems = totalItems.value > 0
  if (!hasItems) return false
  if (totalCost.value > businessBalance.value) return false
  return true
})

const loadBalance = async () => {
  if (!store.businessType || !store.businessId) {
    businessBalance.value = 0
    return
  }

  try {
    const balance = await lua.career_modules_business_businessComputer.getBusinessAccountBalance(
      store.businessType,
      store.businessId
    )
    businessBalance.value = balance || 0
  } catch (error) {
    businessBalance.value = 0
  }
}

const handleAccountUpdate = (data) => {
  if (!data || !store.businessType || !store.businessId) return

  const accountId = "business_" + store.businessType + "_" + store.businessId

  if (data.accountId === accountId) {
    businessBalance.value = data.balance || 0
  }
}

const purchase = async () => {
  if (!canPurchase.value) return

  try {
    const accountId = "business_" + store.businessType + "_" + store.businessId
    const success = await lua.career_modules_business_businessComputer.purchaseCartItems(
      store.businessId,
      accountId,
      {
        parts: partsItems.value,
        tuning: tuningItems.value
      }
    )

    if (success) {
      store.clearCart()
      store.clearCachesForVehicle(store.pulledOutVehicle?.vehicleId)
      expanded.value = false

      await loadBalance()
      
      await finishAndReturnHome()
    }
  } catch (error) {
  }
}

const finishAndReturnHome = async () => {
  store.vehicleView = null
  store.switchView('home')
}

const cancel = () => {
  if (partsItems.value.length > 0 || tuningItems.value.length > 0) {
    showConfirmModal.value = true
    return
  }

  performCancel()
}

const startHold = () => {
  if (!canPurchase.value || isProcessing.value) return
  
  isHolding.value = true
  holdStartTime.value = Date.now()
  holdProgress.value = 0
  
  const updateProgress = () => {
    if (!isHolding.value) return
    
    const elapsed = Date.now() - holdStartTime.value
    holdProgress.value = Math.min(100, (elapsed / HOLD_DURATION) * 100)
    
    if (holdProgress.value >= 100) {
      isHolding.value = false
      holdProgress.value = 0
      handlePrimaryAction()
    } else {
      holdAnimationId.value = requestAnimationFrame(updateProgress)
    }
  }
  
  holdAnimationId.value = requestAnimationFrame(updateProgress)
}

const endHold = () => {
  if (!isHolding.value) return
  
  isHolding.value = false
  holdProgress.value = 0
  holdStartTime.value = null
  
  if (holdAnimationId.value) {
    cancelAnimationFrame(holdAnimationId.value)
    holdAnimationId.value = null
  }
}

const handlePrimaryAction = async () => {
  if (isProcessing.value || !canPurchase.value) return
  
  isProcessing.value = true
  
  try {
    await purchase()
  } finally {
    isProcessing.value = false
  }
}

const confirmCancel = async () => {
  showConfirmModal.value = false
  await performCancel()
  store.switchView('home')
  if (store.vehicleView) {
    await store.closeVehicleView()
  }
}

const cancelClose = () => {
  showConfirmModal.value = false
}

const performCancel = async () => {
  if (store.businessId && store.pulledOutVehicle?.vehicleId) {
    try {
      await lua.career_modules_business_businessComputer.resetVehicleToOriginal(
        store.businessId,
        store.pulledOutVehicle.vehicleId
      )

      setTimeout(() => {
        if (store.vehicleView === 'parts') {
          store.requestVehiclePartsTree(store.pulledOutVehicle.vehicleId)
        }
        if (store.vehicleView === 'tuning') {
          store.requestVehicleTuningData(store.pulledOutVehicle.vehicleId)
        }
      }, 100)
    } catch (error) {
    }
  }

  store.clearCart()
  expanded.value = false
}

const handleTabClick = (tabId, event) => {
  // Don't do anything if we're currently editing this tab
  if (editingTabId.value === tabId) {
    return
  }

  // If clicking on active tab, show context menu
  if (tabId === store.activeTabId) {
    // Show context menu positioned under the button
    if (event) {
      showTabMenu(event, tabId)
    }
    return
  }
  // Otherwise switch to the tab
  store.switchTab(tabId)
  hideTabMenu()
}

const showTabMenu = (event, tabId) => {
  if (tabId !== store.activeTabId) return

  // Use the button element from the event
  const button = event.currentTarget || event.target.closest('.tab-button')
  if (!button) return

  const rect = button.getBoundingClientRect()

  tabMenuTabId.value = tabId
  tabMenuX.value = rect.left
  tabMenuY.value = rect.bottom + 4 // Position just below the button with small gap
  tabMenuVisible.value = true
}

const hideTabMenu = () => {
  tabMenuVisible.value = false
  tabMenuTabId.value = null
}

const onRenameFocus = () => {
  try { lua.setCEFTyping(true) } catch (_) { }
}

const onRenameBlur = (tabId) => {
  try { lua.setCEFTyping(false) } catch (_) { }
  finishRenaming(tabId)
}

const startRenaming = async (tabId) => {
  const tab = store.cartTabs.find(t => t.id === tabId)
  if (!tab) return

  editingTabId.value = tabId
  editingTabName.value = tab.name
  hideTabMenu()

  // Wait for Vue to update the DOM, then focus the input
  await nextTick()
  await nextTick() // Double nextTick to ensure DOM is fully updated

  // Use requestAnimationFrame to ensure input is rendered
  requestAnimationFrame(() => {
    if (renameInput.value) {
      renameInput.value.focus()
      renameInput.value.select()
    }
  })
}

const finishRenaming = (tabId) => {
  if (editingTabName.value && editingTabName.value.trim()) {
    store.renameTab(tabId, editingTabName.value)
  }
  editingTabId.value = null
  editingTabName.value = ''
}

const cancelRenaming = () => {
  editingTabId.value = null
  editingTabName.value = ''
}

const clearCurrentTab = async () => {
  // Clear only the current tab's cart (not all tabs)
  store.partsCart = []
  store.tuningCart = []

  // Reset vehicle to original state
  if (store.businessId && store.pulledOutVehicle?.vehicleId) {
    try {
      await lua.career_modules_business_businessComputer.resetVehicleToOriginal(
        store.businessId,
        store.pulledOutVehicle.vehicleId
      )
      // Power/weight will be updated automatically by Lua after vehicle replacement

      // Wait a bit for vehicle replacement to complete, then reload parts tree
      setTimeout(async () => {
        if (store.pulledOutVehicle?.vehicleId) {
          await store.requestVehiclePartsTree(store.pulledOutVehicle.vehicleId)
        }
      }, 300)
    } catch (error) {
    }
  }

  // Note: Tuning UI will reload when tuning data is refreshed after vehicle reset

  // Save the cleared state to the current tab
  store.saveCurrentTabState()
}

watch([() => store.businessType, () => store.businessId], () => {
  loadBalance()
}, { immediate: true })

watch(() => store.vehicleView, (newView) => {
  if (newView !== 'parts' && newView !== 'tuning') {
    expanded.value = false
  }
})

onMounted(async () => {
  // Register event listener for power/weight data (sent automatically by Lua)
  events.on('businessComputer:onVehiclePowerWeight', handlePowerWeightData)
  // Update dyno upgrade status when skill trees are updated
  events.on('businessSkillTree:onTreesUpdated', () => {
    store.updateDynoUpgradeStatus()
  })
  // Initial update
  store.updateDynoUpgradeStatus()

  events.on('bank:onAccountUpdate', handleAccountUpdate)
  loadBalance()

  // Close context menu when clicking outside
  document.addEventListener('click', hideTabMenu)

  // Don't initialize cart here - let switchVehicleView handle it
  // This prevents clearing cart when switching between parts/tuning views
})

// Track if we've initialized for the current job to prevent re-initialization when switching views
const initializedVehicleKey = ref(null)

watch(() => store.pulledOutVehicle, async (newVehicle, oldVehicle) => {
  const newVehKey = newVehicle ? normalizeVehicleCacheKey(newVehicle.vehicleId) : null
  const oldVehKey = oldVehicle ? normalizeVehicleCacheKey(oldVehicle.vehicleId) : null

  if (newVehicle &&
    newVehKey !== initializedVehicleKey.value &&
    (store.vehicleView === 'parts' || store.vehicleView === 'tuning')) {
    // Delay until UI animation completes (600ms) to avoid vehicle spawning during animation
    setTimeout(async () => {
      // Double-check we're still in the vehicle view and vehicle is still pulled out
      if (newVehicle &&
        newVehKey === normalizeVehicleCacheKey(store.pulledOutVehicle?.vehicleId) &&
        (store.vehicleView === 'parts' || store.vehicleView === 'tuning')) {
        await store.initializeCartForVehicle()
        initializedVehicleKey.value = newVehKey
      }
    }, oldVehicle ? 100 : 600)
  }

  // Reset initialized flag when vehicle is put away or switched
  if (!newVehicle && oldVehicle) {
    initializedVehicleKey.value = null
  } else if (oldVehicle && newVehicle && newVehKey !== oldVehKey) {
    initializedVehicleKey.value = null
  }
}, { immediate: true })

onBeforeUnmount(() => {
  // Clean up event listeners
  events.off('businessComputer:onVehiclePowerWeight', handlePowerWeightData)
  events.off('businessSkillTree:onTreesUpdated', store.updateDynoUpgradeStatus)
  events.off('bank:onAccountUpdate', handleAccountUpdate)
  document.removeEventListener('click', hideTabMenu)
})
</script>

<style scoped lang="scss">
@import "../../styles/rlsHouse.scss";

// Same look as the career ShoppingCart (components/ShoppingCart.vue): near-black card, plain bold
// heading with cart glyph and count pill, PART / PRICE caption header, gold prices, muted
// subtotal / tax, gold total on a panel, Confirm primary + quiet Cancel.
.business-shopping-cart {
  position: fixed;
  bottom: 2em;
  right: 2em;
  z-index: 2000;
  width: 28em;
  max-height: calc(100vh - 4em);
  display: flex;
  flex-direction: column;
  overflow: hidden;
  color: #fff;
  background-color: rgba(21, 21, 23, 0.92);
  border-radius: var(--radius-control);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
  font-variant-numeric: tabular-nums;

  &.expanded {
    height: 40em;
  }
}

// ---- heading
.cart-heading {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
  gap: 0.55em;
  padding: 0.8em 0.7em 0.55em var(--inset);
}
.cart-glyph {
  flex: 0 0 auto;
  font-size: 1.35em;
  color: rgba(255, 255, 255, 0.6);
}
.cart-heading-text {
  flex: 0 1 auto;
  min-width: 0;
  font-size: 1.15em;
  font-weight: 800;
  line-height: 1.2;
  overflow-wrap: anywhere;
}
.cart-expand {
  margin-left: auto;
}

// ---- collapsed summary
.cart-collapsed {
  padding: 0 var(--inset) var(--inset);
  .cart-summary {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: 1em;
    color: var(--muted);
    font-weight: 600;
  }
  .summary-total {
    color: var(--money);
    font-weight: 800;
  }
}

.cart-main {
  display: flex;
  flex-direction: column;
  flex: 1 1 auto;
  min-height: 0;
  overflow: hidden;
}

// ---- build tabs (Style Guide chips)
.cart-tabs {
  flex: 0 0 auto;
  padding: 0 var(--inset) 0.5em;
}
.tabs-list {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.4em;
}
.tab-wrapper {
  display: flex;
}
.tab-button {
  appearance: none;
  display: inline-flex;
  align-items: center;
  gap: 0.4em;
  margin: 0;
  padding: 0.5em 0.7em 0.38em;
  border: 0;
  border-radius: var(--radius-control);
  background: var(--panel);
  color: var(--muted);
  font: inherit;
  font-size: 0.9em;
  font-weight: 700;
  line-height: 1;
  cursor: pointer;
  &:hover {
    background: var(--panel-2);
    color: #fff;
  }
  @include house-focus;
  &.active {
    background: var(--panel-2);
    color: #fff;
  }
  .tab-name {
    overflow-wrap: anywhere;
  }
}
.tab-rename-input {
  width: 8em;
  margin: -0.2em 0;
  padding: 0.2em 0.35em 0.1em;
  border: 1px solid var(--line);
  border-radius: var(--radius-thumb);
  background: rgba(0, 0, 0, 0.3);
  color: #fff;
  font: inherit;
  line-height: 1.1;
  &:focus {
    outline: none;
    box-shadow: var(--focus);
  }
}
.tab-close,
.tab-add,
.footer-toggle {
  appearance: none;
  display: grid;
  place-items: center;
  flex: 0 0 auto;
  margin: 0;
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
    fill: none;
    stroke: currentColor;
    stroke-width: 2.4;
    stroke-linecap: round;
    stroke-linejoin: round;
  }
}
.tab-close {
  width: 1.3em;
  height: 1.3em;
  margin-right: -0.25em;
  svg { width: 0.75em; height: 0.75em; }
}
.tab-add {
  width: 2em;
  height: 2em;
  svg { width: 0.95em; height: 0.95em; }
}

// ---- three columns: remove action, name, price. The list reserves a 0.5em scrollbar gutter,
// so rows outside it add that to their right padding to keep prices aligned.
.cart-row {
  display: grid;
  grid-template-columns: 2.4em minmax(0, 1fr) minmax(6.5em, auto);
  align-items: center;
  column-gap: var(--space-2);
  flex: 0 0 auto;
  min-height: 2.9em;
  padding: 0.45em var(--inset) 0.35em 0.35em;
  > :first-child {
    display: flex;
    justify-content: center;
  }
  > :last-child {
    text-align: right;
    white-space: nowrap;
  }
}
.price {
  color: var(--money);
  font-weight: 700;
  font-variant-numeric: tabular-nums;
}

.cart-header {
  min-height: 0;
  padding-top: 0.15em;
  padding-bottom: 0.45em;
  padding-right: calc(var(--inset) + 0.5em);
  border-bottom: 1px solid var(--line);
  > * {
    font-size: 0.78em;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: var(--faint);
  }
}

.cart-list {
  display: flex;
  flex-direction: column;
  flex: 1 1 auto;
  min-height: 0;
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
}

.cart-empty {
  flex: 0 0 auto;
  padding: 1.4em 1em 1em;
  p { color: var(--muted); }
}
.cart-empty-glyph {
  font-size: 1.8em;
  color: rgba(255, 255, 255, 0.3);
}

// ---- Parts / Tuning sections: caption + hairline, section subtotal, fold chevron
.cart-section-header {
  appearance: none;
  display: flex;
  align-items: center;
  gap: 0.7em;
  width: 100%;
  margin: 0;
  padding: 0.75em var(--inset) 0.35em 0.6em;
  border: 0;
  background: transparent;
  color: var(--faint);
  font: inherit;
  text-align: left;
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
  .section-title {
    font-size: 0.78em;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
  }
  .section-subtotal {
    order: 2;
    color: var(--money);
    font-size: 0.88em;
    font-weight: 700;
    font-variant-numeric: tabular-nums;
  }
  .section-chevron {
    order: 3;
    flex: 0 0 auto;
    width: 0.95em;
    height: 0.95em;
    fill: none;
    stroke: currentColor;
    stroke-width: 2.4;
    stroke-linecap: round;
    stroke-linejoin: round;
    transition: transform 0.12s;
    &.rotated {
      transform: rotate(-90deg);
    }
  }
}
.section-content {
  display: flex;
  flex-direction: column;
  // part tree rows are flex rows; line their prices up with the grid rows
  > :deep(.tree-node) {
    padding: 0 var(--inset) 0 0.35em;
  }
}

// ---- tuning lines
.cart-item {
  font-weight: 600;
  line-height: 1.25;
}
.cart-item + .cart-item:not(.cart-item-subcategory):not(.cart-item-variable) {
  border-top: 1px solid var(--line);
}
.cart-item-category {
  min-height: 2.5em;
  padding-top: 0.6em;
  font-weight: 800;
}
.cart-item-subcategory {
  min-height: 2.2em;
  font-weight: 700;
  color: var(--muted);
}
.cart-item-variable {
  min-height: 2.4em;
}

.cart-item .cart-remove {
  font-size: 0.85em;
  padding: 0.3em 0.4em 0.25em;
  border-radius: var(--radius-thumb);
}
.item-info {
  min-width: 0;
  display: grid;
  gap: 0.15em;
}
.item-name {
  min-width: 0;
  overflow-wrap: anywhere;
}
.item-slot {
  color: var(--faint);
  font-size: 0.82em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}

// ---- footer: performance, summary, total, actions
.cart-footer {
  flex: 0 0 auto;
  display: flex;
  flex-direction: column;
  border-top: 1px solid var(--line);
}
.footer-details {
  display: flex;
  flex-direction: column;
}

.power-weight-stats {
  display: grid;
  gap: 0.45em;
  padding: 0.6em var(--inset) 0.5em;
  border-bottom: 1px solid var(--line);
}
.performance-section-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.7em;
  .section-title {
    color: var(--faint);
    font-size: 0.78em;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
  }
}
.view-toggles {
  flex: 0 0 auto;
  font-size: 0.85em;
  button:disabled {
    opacity: 0.45;
    cursor: default;
  }
}
.stats-container {
  display: grid;
}
.stat-row {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto 1.2em auto;
  align-items: center;
  column-gap: 0.55em;
  padding: 0.35em 0 0.25em;
  border-bottom: 1px solid var(--line);
  &:last-child {
    border-bottom: 0;
  }
}
.stat-label-col {
  color: var(--faint);
  font-size: 0.85em;
  font-weight: 600;
}
.stat-value-col {
  color: var(--muted);
  font-weight: 600;
  text-align: right;
  white-space: nowrap;
  small {
    margin-left: 0.25em;
    color: var(--faint);
    font-size: 0.78em;
  }
  &.is-new {
    color: #fff;
    font-weight: 700;
  }
}
.stat-arrow-col {
  display: grid;
  place-items: center;
  color: var(--faint);
  svg {
    width: 0.95em;
    height: 0.95em;
    fill: none;
    stroke: currentColor;
    stroke-width: 2.2;
    stroke-linecap: round;
    stroke-linejoin: round;
  }
}
.dyno-container {
  height: 9em;
  border-radius: var(--radius-panel);
  background: rgba(0, 0, 0, 0.25);
  overflow: hidden;
  .dyno-graph {
    display: block;
    font-family: inherit;
  }
}
.dyno-placeholder {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.7em;
  padding: 0.3em 0;
}

.cart-summary-breakdown {
  display: flex;
  flex-direction: column;
}
.cart-subtotal,
.cart-tax {
  min-height: 2.2em;
  padding-top: 0.3em;
  padding-bottom: 0.2em;
  padding-right: calc(var(--inset) + 0.5em);
  color: var(--muted);
  font-weight: 600;
  .price { font-weight: 600; }
}
.cart-subtotal {
  padding-top: 0.55em;
}
.cart-tax {
  padding-bottom: 0.45em;
}

.cart-total {
  min-height: 2.6em;
  margin: var(--space-2) var(--space-3) 0;
  padding: 0.55em calc(var(--inset) + 0.5em - var(--space-3)) 0.4em 0;
  border-radius: var(--radius-panel);
  background: var(--panel);
  > :not(:first-child) {
    font-size: 1.15em;
    font-weight: 800;
  }
  .price {
    font-weight: 800;
  }
}
.footer-toggle {
  width: 1.7em;
  height: 1.7em;
  svg {
    width: 0.9em;
    height: 0.9em;
    transition: transform 0.12s;
    &.rotated {
      transform: rotate(180deg);
    }
  }
}

.cart-buttons {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: var(--space-2);
  padding: var(--space-3) var(--inset) var(--inset);
}
.cart-btn {
  white-space: nowrap;
}
// Primary: the single orange action (hold to confirm). The fill grows with transform only.
.cart-btn-primary {
  flex: 1 1 auto;
}
.hold-progress {
  position: absolute;
  inset: 0;
  z-index: -1;
  background: rgba(255, 255, 255, 0.22);
  transform-origin: left center;
  pointer-events: none;
}

// ---- transitions: opacity only
.cart-collapse-enter-active,
.cart-collapse-leave-active,
.section-collapse-enter-active,
.section-collapse-leave-active,
.footer-collapse-enter-active,
.footer-collapse-leave-active {
  transition: opacity 0.15s ease;
}
.cart-collapse-enter-from,
.cart-collapse-leave-to,
.section-collapse-enter-from,
.section-collapse-leave-to,
.footer-collapse-enter-from,
.footer-collapse-leave-to {
  opacity: 0;
}

// ---- teleported popups (rendered on <body>, so they set their own size)
.modal-overlay {
  position: fixed;
  inset: 0;
  z-index: 10000;
  display: grid;
  place-items: center;
  padding: 1em;
  background: rgba(0, 0, 0, 0.55);
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
}
.modal-content {
  width: min(26em, 100%);
}
.modal-buttons {
  display: flex;
  justify-content: space-between;
  gap: var(--space-2);
  margin-top: var(--space-1);
}
.modal-fade-enter-active,
.modal-fade-leave-active {
  transition: opacity 0.15s ease;
  .modal-content {
    transition: transform 0.15s ease, opacity 0.15s ease;
  }
}
.modal-fade-enter-from,
.modal-fade-leave-to {
  opacity: 0;
  .modal-content {
    transform: scale(0.97);
    opacity: 0;
  }
}

.tab-menu-overlay {
  position: fixed;
  inset: 0;
  z-index: 9999;
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
}
.tab-menu-modal {
  position: fixed;
  z-index: 10000;
  display: grid;
  gap: 0.1em;
  min-width: 11em;
  padding: 0.35em;
  border-radius: var(--radius-panel);
  background: #1a1a1c;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08), 0 12px 28px rgba(0, 0, 0, 0.5);
  :deep(.btn-icon) {
    color: var(--faint);
  }
}
.dropdown-fade-enter-active,
.dropdown-fade-leave-active {
  transition: opacity 0.12s ease;
  .tab-menu-modal {
    transition: transform 0.12s ease;
  }
}
.dropdown-fade-enter-from,
.dropdown-fade-leave-to {
  opacity: 0;
  .tab-menu-modal {
    transform: translateY(-0.3em);
  }
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
