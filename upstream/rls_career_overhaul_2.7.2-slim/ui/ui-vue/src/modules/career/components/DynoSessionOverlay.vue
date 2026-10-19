<template>
  <!-- RLS dyno session overlay, house style. Replaces the Angular dynoSessionHud: shown over the game while
       the car is in the dyno bay (Lua DynoSessionHudShow / Hide / State, then polled every 250 ms), dragged
       around by its header (position saved like the old HUD), and it lets clicks through to the game while a
       pull runs. One near-black card whose body follows the session phase: offer (fee, hub tiles, repair
       quote) / inspecting / ready + pulling (stage and what to do now, live readout with a throttle bar
       marking where recording starts and stops) / complete (peaks, curve, warnings, saved pulls to overlay).
       Mouse driven like the old HUD: during a session the pad drives the car. -->
  <div v-if="visible" class="dyno-overlay" :style="{ left: `${pos.x}px`, top: `${pos.y}px` }">
      <section ref="cardEl" class="rls-house dyno-card" :class="[`phase-${sessionData.phase || 'offer'}`, { dragging: !!drag }]">
        <header class="dyno-head" title="Drag to move" @mousedown="startDrag">
          <div class="head-copy">
            <span class="kicker">Dyno session</span>
            <h2 class="vehicle-name">{{ sessionData.vehicleName || "Current Vehicle" }}</h2>
          </div>
          <span class="pill" :class="phasePill.tone">{{ phasePill.label }}</span>
        </header>

        <!-- a failure sets both statusText and error to the same line: show it once, as the error -->
        <p v-if="sessionData.statusText && sessionData.phase !== 'inspecting' && sessionData.statusText !== sessionData.error" class="notice">{{ sessionData.statusText }}</p>
        <p v-if="sessionData.error" class="notice bad">{{ sessionData.error }}</p>
        <p v-if="supportReason" class="notice bad">{{ supportReason }}</p>

        <!-- ===================== offer / starting ===================== -->
        <template v-if="isOffer">
          <div class="offer-strip">
            <div class="stat">
              <span class="stat-key">Session</span>
              <span v-if="sessionData.ownerBenefit" class="stat-value ok-text">Free</span>
              <span v-else class="stat-value money"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(sessionData.fee) }}</span>
            </div>
            <div class="stat">
              <span class="stat-key">Pulls</span>
              <span class="stat-value">{{ sessionData.ownerBenefit || sessionData.unlimitedPulls ? "Unlimited" : sessionData.pullLimit || 3 }}</span>
            </div>
            <p class="offer-note">
              {{ sessionData.ownerBenefit ? "Owner benefit." : "" }} Hubs go on all wheels; tire wear and heat are off for the session.
            </p>
          </div>

          <div v-if="hubOptions.length" class="hub-block">
            <span class="caption">Dyno hub</span>
            <div class="hub-grid">
              <button
                v-for="hub in hubOptions"
                :key="hub.id"
                type="button"
                class="hub-tile"
                bng-nav-item
                :class="{ picked: selectedHubId === hub.id }"
                :aria-pressed="selectedHubId === hub.id"
                :disabled="hubsLocked"
                :bng-no-nav="hubsLocked ? 'true' : undefined"
                @click="selectedHubId = hub.id">
                <span class="hub-top">
                  <strong>{{ hub.label }}</strong>
                  <BngIcon v-if="selectedHubId === hub.id" class="hub-check" :type="icons.checkmark" />
                </span>
                <small>{{ hub.description }}</small>
              </button>
            </div>
          </div>

          <div v-if="sessionData.repairRequired && sessionData.repairQuote" class="panel repair-panel">
            <div class="split-head">
              <span class="caption">Repair first</span>
              <span class="hint">Private repair only. Tire wear and flats are kept as they are.</span>
            </div>
            <div class="lines">
              <div class="line"><span>Private repair</span><strong><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(sessionData.repairQuote.repairCost) }}</strong></div>
              <div class="line"><span>Dyno session</span><strong><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(sessionData.repairQuote.dynoFee) }}</strong></div>
              <div class="line total"><span>Total</span><strong class="money"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(sessionData.repairQuote.totalCost) }}</strong></div>
            </div>
          </div>

          <div class="button-row">
            <HouseButton variant="quiet" :disabled="busy" @click="handleLeaveSession">Cancel</HouseButton>
            <span class="row-gap"></span>
            <HouseButton
              v-if="!sessionData.repairRequired"
              class="dk-primary"
              variant="primary"
              :disabled="busy || !sessionData.canStart"
              @click="handleStartSession">
              <template v-if="sessionData.ownerBenefit">Start session</template>
              <template v-else>Start session <span class="btn-price"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(sessionData.fee) }}</span></template>
            </HouseButton>
            <HouseButton
              v-else
              class="dk-primary"
              variant="primary"
              :disabled="busy || !sessionData.canRepairAndStart"
              @click="handleRepairAndStart">
              Repair &amp; start <span class="btn-price"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(sessionData.repairQuote?.totalCost) }}</span>
            </HouseButton>
          </div>
        </template>

        <!-- ===================== inspecting: Lua is re-reading damage / ownership before it starts ===================== -->
        <template v-else-if="sessionData.phase === 'inspecting'">
          <div class="stage-strip">
            <BngIcon class="stage-icon" :type="icons.wrench" />
            <div class="stage-copy">
              <strong>Checking your car</strong>
              <span>{{ sessionData.statusText || "Inspecting the vehicle before the session starts." }}</span>
            </div>
          </div>
          <div class="button-row">
            <HouseButton class="dk-primary" variant="quiet" :disabled="busy || !sessionData.canLeave" @click="handleLeaveSession">Cancel</HouseButton>
          </div>
        </template>

        <!-- ===================== ready / pulling: what to do now + live readout ===================== -->
        <template v-else-if="isLive">
          <div class="stage-strip" :class="stageTone">
            <BngIcon class="stage-icon" :type="icons.powerGauge03" />
            <div class="stage-copy">
              <strong>{{ stageLabel }}</strong>
              <span>{{ guideText }}</span>
            </div>
            <div class="stage-facts">
              <span class="pill">{{ selectedHubLabel }}</span>
              <span class="pill">{{ sessionData.unlimitedPulls ? "Unlimited pulls" : `${sessionData.pullsRemaining} pull${sessionData.pullsRemaining === 1 ? "" : "s"} left` }}</span>
            </div>
          </div>

          <div class="live-grid">
            <div class="gauge"><span class="stat-key">RPM</span><span class="gauge-value">{{ liveRpm }}</span></div>
            <div class="gauge"><span class="stat-key">Wheel power</span><span class="gauge-value">{{ livePower }}</span></div>
            <div class="gauge"><span class="stat-key">Wheel torque</span><span class="gauge-value">{{ liveTorque }}</span></div>
            <div class="gauge"><span class="stat-key">Gear</span><span class="gauge-value">{{ liveGear }}</span></div>
          </div>

          <!-- throttle against the two thresholds that matter: 90% starts recording, under 75% ends it -->
          <div class="throttle">
            <div class="throttle-head">
              <span class="stat-key">Throttle</span>
              <strong>{{ liveThrottle }}</strong>
            </div>
            <div class="throttle-track">
              <span class="throttle-fill" :class="{ hot: throttlePct >= 90 }" :style="{ transform: `scaleX(${throttlePct / 100})` }"></span>
              <span class="mark" style="left: 75%"><i>75% ends</i></span>
              <span class="mark start" style="left: 90%"><i>90% starts</i></span>
            </div>
          </div>

          <p class="samples">
            <strong>{{ sessionData.acceptedSampleCount || 0 }}</strong> samples kept
            <span class="sep">·</span>
            <strong>{{ sessionData.rejectedSampleCount || 0 }}</strong> dropped
          </p>

          <!-- while a pull runs the card lets clicks through to the game, so it carries no buttons -->
          <div v-if="sessionData.phase === 'ready'" class="tool-row">
            <HouseButton compact :disabled="busy" :icon="icons.info" @click="openHowTo">How it works</HouseButton>
            <HouseButton compact :disabled="busy || !sessionData.canOpenMaintenance" :icon="icons.wrench" @click="handleOpenMaintenance">Maintenance</HouseButton>
            <HouseButton compact :disabled="busy || !sessionData.canOpenTuning" :icon="icons.engine" @click="handleOpenTuning">Engine tuning</HouseButton>
          </div>
          <div v-if="sessionData.phase === 'ready'" class="button-row">
            <HouseButton variant="quiet" :disabled="busy || !sessionData.canLeave" @click="handleLeaveSession">Leave session</HouseButton>
            <span class="row-gap"></span>
            <HouseButton class="dk-primary" variant="primary" :disabled="busy" @click="handleStartPull">Arm pull</HouseButton>
          </div>
        </template>

        <!-- ===================== complete: result, curve, warnings, history ===================== -->
        <template v-else-if="sessionData.phase === 'complete' || sessionData.phase === 'leaving'">
          <div v-if="displayedResult" class="result-grid">
            <div class="result">
              <span class="stat-key">Peak power</span>
              <span class="result-value accent-text">{{ formattedPower }}</span>
              <span class="hint">{{ formattedPowerRpm }}</span>
            </div>
            <div class="result">
              <span class="stat-key">Peak torque</span>
              <span class="result-value">{{ formattedTorque }}</span>
              <span class="hint">{{ formattedTorqueRpm }}</span>
            </div>
            <div class="result">
              <span class="stat-key">Pull quality</span>
              <span class="result-value" :class="resultIsClean ? 'ok-text' : 'warn-text'">{{ resultQualityLabel }}</span>
              <span class="hint">{{ resultSampleCounts }}</span>
            </div>
          </div>

          <div v-if="qualityFlagLabels.length" class="warn-row">
            <span class="caption">Warnings</span>
            <span v-for="flag in qualityFlagLabels" :key="flag" class="pill warn">{{ flag }}</span>
          </div>

          <!-- curve: power and torque in the player's units on one scale, RPM along the bottom; hover a point to
               read it (ported from the old Angular HUD) -->
          <div v-if="graph" class="panel curve-panel">
            <div class="curve-legend">
              <span class="legend power">Power ({{ powerUnit }})</span>
              <span class="legend torque">Torque ({{ torqueUnit }})</span>
              <template v-if="comparisonPull">
                <span class="legend power dashed">Saved power</span>
                <span class="legend torque dashed">Saved torque</span>
              </template>
            </div>
            <svg class="curve-svg" :viewBox="`0 0 ${GRAPH_W} ${GRAPH_H}`" preserveAspectRatio="xMidYMid meet" @mousemove="onGraphMove" @mouseleave="graphHover = null">
              <g class="grid">
                <line v-for="l in graph.yLabels" :key="`y${l.value}`" :x1="graph.plot.x" :x2="graph.plot.x + graph.plot.w" :y1="l.y" :y2="l.y" />
                <line v-for="l in graph.xLabels" :key="`x${l.value}`" :x1="l.x" :x2="l.x" :y1="graph.plot.y" :y2="graph.plot.y + graph.plot.h" />
              </g>
              <rect class="plot-border" :x="graph.plot.x" :y="graph.plot.y" :width="graph.plot.w" :height="graph.plot.h" />
              <polyline v-if="comparisonPull" class="comparison-curve" :points="graph.comparePower" />
              <polyline v-if="comparisonPull" class="comparison-torque-curve" :points="graph.compareTorque" />
              <polyline class="primary-torque-curve" :points="graph.torque" />
              <polyline class="primary-curve" :points="graph.power" />
              <g class="axis">
                <text v-for="l in graph.yLabels" :key="`yl${l.value}`" class="axis-y" :x="graph.plot.x - 10" :y="l.y">{{ l.value }}</text>
                <text v-for="l in graph.xLabels" :key="`xl${l.value}`" class="axis-x" :x="l.x" :y="graph.plot.y + graph.plot.h + 22">{{ l.label }}</text>
                <text class="axis-title" :x="graph.plot.x + graph.plot.w / 2" :y="GRAPH_H - 6">RPM</text>
              </g>
              <g v-if="graphHover" class="hover">
                <line class="hover-line" :x1="graphHover.x" :x2="graphHover.x" :y1="graph.plot.y" :y2="graph.plot.y + graph.plot.h" />
                <circle class="hover-power" :cx="graphHover.x" :cy="graphHover.powerY" r="5" />
                <circle class="hover-torque" :cx="graphHover.x" :cy="graphHover.torqueY" r="5" />
                <rect class="hover-box" :x="graphHover.boxX" :y="graph.plot.y + 10" width="184" height="80" rx="6" />
                <text class="hover-rpm" :x="graphHover.boxX + 12" :y="graph.plot.y + 30">{{ graphHover.rpm }}</text>
                <text class="hover-power-text" :x="graphHover.boxX + 12" :y="graph.plot.y + 55">{{ graphHover.power }}</text>
                <text class="hover-torque-text" :x="graphHover.boxX + 12" :y="graph.plot.y + 77">{{ graphHover.torque }}</text>
              </g>
            </svg>
          </div>

          <div v-if="sessionData.phase === 'complete' && sessionData.savedPulls?.length" class="history">
            <div class="split-head">
              <span class="caption">Saved pulls</span>
              <span class="hint">Pick one to overlay it on this result.</span>
              <hr class="rule" />
              <HouseButton v-if="selectedComparisonId !== null" variant="text" compact @click="selectedComparisonId = null">Clear</HouseButton>
            </div>
            <div class="history-list scroll" v-bng-ui-nav-scroll>
              <div
                v-for="pull in sessionData.savedPulls"
                :key="pull.id"
                class="history-row"
                :class="{ picked: String(selectedComparisonId) === String(pull.id) }">
                <button
                  type="button"
                  class="history-pick"
                  bng-nav-item
                  :aria-pressed="String(selectedComparisonId) === String(pull.id)"
                  @click="toggleComparison(pull)">
                  <span class="row-copy">
                    <strong>{{ formatSavedPullSummary(pull) }}</strong>
                    <span>{{ formatSavedPullDate(pull.savedAt) }}</span>
                  </span>
                  <span v-if="String(selectedComparisonId) === String(pull.id)" class="pill accent">Overlaid</span>
                  <span v-else-if="String(pull.id) === String(displayedResult?.savedPullId)" class="pill">This pull</span>
                </button>
                <HouseButton variant="quiet-danger" compact :icon="icons.trashBin1" :disabled="busy" aria-label="Delete saved pull" @click="handleDeleteSavedPull(pull)" />
              </div>
            </div>
          </div>

          <div v-if="sessionData.phase === 'complete'" class="tool-row">
            <HouseButton compact :disabled="busy" :icon="icons.info" @click="openHowTo">How it works</HouseButton>
            <HouseButton compact :disabled="busy || !sessionData.canOpenMaintenance" :icon="icons.wrench" @click="handleOpenMaintenance">Maintenance</HouseButton>
            <HouseButton compact :disabled="busy || !sessionData.canOpenTuning" :icon="icons.engine" @click="handleOpenTuning">Engine tuning</HouseButton>
          </div>
          <div class="button-row" v-if="sessionData.phase === 'complete'">
            <HouseButton variant="quiet" :disabled="busy" @click="handleLeaveSession">Done</HouseButton>
            <span class="row-gap"></span>
            <HouseButton class="dk-save" :disabled="busy || sessionData.currentResultSaved" :icon="sessionData.currentResultSaved ? icons.checkmark : icons.floppyDisk" @click="handleSavePull">
              {{ sessionData.currentResultSaved ? "Saved" : "Save pull" }}
            </HouseButton>
            <HouseButton class="dk-primary" variant="primary" :disabled="busy || !sessionData.canRetry" @click="handleRetryPull">
              {{ sessionData.unlimitedPulls ? "Another pull" : sessionData.canRetry ? `Another pull (${sessionData.pullsRemaining} left)` : "All pulls used" }}
            </HouseButton>
          </div>
        </template>
      </section>

      <!-- a trapping scope while open: focus on Got It, B / Start close it -->
      <div
        v-if="showHowTo"
        class="how-to-backdrop"
        v-bng-scoped-nav="{ activateOnMount: true, trapPolicy: 'always', canDeactivate: () => (closeHowTo(), false) }"
        v-bng-on-ui-nav:menu="closeHowTo"
        @click.self="closeHowTo">
        <div class="rls-house how-to-dialog" role="dialog" aria-modal="true" aria-labelledby="dyno-how-to-title">
          <span class="kicker">Dyno session</span>
          <h2 id="dyno-how-to-title" class="block-title">How to run a pull</h2>
          <ol class="steps">
            <li><span class="step-n">1</span><span>Start the engine.</span></li>
            <li><span class="step-n">2</span><span>Pick a high forward gear for the car, usually 3rd or 4th, and stay in it.</span></li>
            <li><span class="step-n">3</span><span>Press <strong>Arm pull</strong> and hold that gear steady for a moment.</span></li>
            <li><span class="step-n">4</span><span>Go to at least <strong>90% throttle</strong>. Recording starts on its own.</span></li>
            <li><span class="step-n">5</span><span>Hold gear and throttle through the pull. Drop below <strong>75% throttle</strong> to finish.</span></li>
          </ol>
          <p class="hint">Shifting or braking while recording shows up as a warning on the result.</p>
          <div class="how-to-foot">
            <label class="check">
              <input v-model="dontShowHowToAgain" class="pad-check" type="checkbox" />
              <span>Don't show this again</span>
            </label>
            <HouseButton variant="primary" binding="ok" bng-scoped-nav-autofocus @click="closeHowTo">Got it</HouseButton>
          </div>
        </div>
      </div>
  </div>
</template>

<script setup>
import { computed, nextTick, onMounted, onUnmounted, ref } from "vue"
import { lua, useBridge } from "@/bridge"
import { BngIcon, icons } from "@/common/components/base"
import { vBngOnUiNav, vBngScopedNav, vBngUiNavScroll } from "@/common/directives"
import { HouseButton, openHouseConfirmation } from "./house"
import { callModLua } from "../utils/installLuaBridgeFallbacks"

const bridge = useBridge()
const { units } = bridge

const HOW_TO_STORAGE_KEY = "rlsDynoHowToDismissedV1"
const busy = ref(false)
const showHowTo = ref(false)
const dontShowHowToAgain = ref(false)
const selectedComparisonId = ref(null)
const selectedHubId = ref("rls")
const sessionData = ref({
  ownerBenefit: false,
  unlimitedPulls: false,
  fee: 1000,
  pullLimit: 3,
  pullsUsed: 0,
  pullsRemaining: 3,
  phase: "offer",
  canStart: false,
  canRepairAndStart: false,
  repairRequired: false,
  repairQuote: null,
  canRetry: false,
  canOpenMaintenance: false,
  canOpenTuning: false,
  canLeave: true,
  vehicleName: "Current Vehicle",
  result: null,
  error: null,
  statusText: null,
  pullStage: null,
  liveSample: null,
  pullQuality: null,
  qualityFlags: {},
  acceptedSampleCount: 0,
  rejectedSampleCount: 0,
  selectedHubId: "rls",
  hubOptions: [],
  inventoryId: null,
  savedPulls: [],
  currentResultSaved: false,
})

let refreshTimer = null
let hubSelectionInitialized = false
let howToAutoShownThisSession = false

function howToWasDismissed() {
  try {
    return window.localStorage.getItem(HOW_TO_STORAGE_KEY) === "1"
  } catch (error) {
    return false
  }
}

function openHowTo() {
  dontShowHowToAgain.value = howToWasDismissed()
  showHowTo.value = true
}

function closeHowTo() {
  if (dontShowHowToAgain.value) {
    try {
      window.localStorage.setItem(HOW_TO_STORAGE_KEY, "1")
    } catch (error) {}
  }
  showHowTo.value = false
}

// Responses are numbered: the 250 ms poll and the refresh after an action can be in flight together, and
// an older reply must never overwrite a newer one (it would briefly show a past phase). A failed request
// is dropped; the next poll tries again.
let requestSeq = 0
let appliedSeq = 0
async function refreshSessionData() {
  const seq = ++requestSeq
  let data
  try {
    data = await lua.career_modules_dynoSession.requestSessionData()
  } catch (error) {
    return
  }
  if (seq < appliedSeq) return
  appliedSeq = seq
  if (data && visible.value) {
    sessionData.value = data
    const hubOptions = Array.isArray(data.hubOptions) ? data.hubOptions : []
    if (!hubSelectionInitialized || !hubOptions.some(hub => hub.id === selectedHubId.value)) {
      selectedHubId.value = data.selectedHubId || hubOptions[0]?.id || "rls"
      hubSelectionInitialized = true
    }
    if (!data.active) {
      howToAutoShownThisSession = false
    } else if (data.phase === "ready" && !howToAutoShownThisSession) {
      howToAutoShownThisSession = true
      if (!howToWasDismissed()) {
        dontShowHowToAgain.value = false
        showHowTo.value = true
      }
    }
    if (selectedComparisonId.value !== null && !data.savedPulls?.some(pull => String(pull.id) === String(selectedComparisonId.value))) {
      selectedComparisonId.value = null
    }
  }
}

const selectedHubLabel = computed(() => {
  const hubId = sessionData.value?.active ? sessionData.value?.selectedHubId : selectedHubId.value
  const option = sessionData.value?.hubOptions?.find(hub => hub.id === hubId)
  return option?.label || "Dyno Hub"
})

const displayedResult = computed(() => sessionData.value?.result || null)

// ---- view helpers for the house layout
const isOffer = computed(() => ["offer", "starting"].includes(sessionData.value?.phase))
const isLive = computed(() => ["ready", "pulling"].includes(sessionData.value?.phase))
const hubOptions = computed(() => (Array.isArray(sessionData.value?.hubOptions) ? sessionData.value.hubOptions : []))
const hubsLocked = computed(() => busy.value || sessionData.value?.phase === "starting")
const supportReason = computed(() => (sessionData.value?.support?.supported === false ? sessionData.value.support.reason || "" : ""))
// number only: the template puts the game currency glyph in front
const money = value => Math.max(0, Math.round(Number(value) || 0)).toLocaleString()
const throttlePct = computed(() => Math.min(100, Math.max(0, Math.round((Number(currentSample.value?.throttle) || 0) * 100))))
// status chip in the header: one word for where the session is
const phasePill = computed(() => {
  const phase = sessionData.value?.phase
  const stage = sessionData.value?.pullStage || currentSample.value?.stage
  if (phase === "starting") return { label: "Setting up", tone: "accent" }
  if (phase === "offer") return sessionData.value?.ownerBenefit ? { label: "Owner benefit", tone: "ok" } : { label: "Not started", tone: "" }
  if (phase === "ready") return { label: "Ready", tone: "" }
  if (phase === "pulling") return stage === "recording" ? { label: "Recording", tone: "accent" } : { label: "Armed", tone: "warn" }
  if (phase === "leaving") return { label: "Leaving", tone: "" }
  if (phase === "complete") return displayedResult.value && !resultIsClean.value ? { label: "With warnings", tone: "warn" } : { label: "Complete", tone: "ok" }
  return { label: "Dyno", tone: "" }
})
const stageTone = computed(() => {
  const stage = sessionData.value?.pullStage || currentSample.value?.stage
  return stage === "recording" ? "recording" : stage === "armed" ? "armed" : ""
})
function toggleComparison(pull) {
  selectedComparisonId.value = String(selectedComparisonId.value) === String(pull.id) ? null : String(pull.id)
}

const currentSample = computed(() => sessionData.value?.liveSample || sessionData.value?.result?.liveSample || null)

const stageNames = {
  armed: "Armed",
  ready: "Ready",
  recording: "Recording",
  finishing: "Finishing",
  complete: "Complete",
}

const stageLabel = computed(() => {
  const stage = sessionData.value?.pullStage || currentSample.value?.stage
  return stageNames[stage] || (stage ? String(stage) : "Ready")
})

const guideText = computed(() => {
  const stage = sessionData.value?.pullStage || currentSample.value?.stage
  if (stage === "armed") return "Hold the selected high gear steady."
  if (stage === "ready") return "Apply at least 90% throttle to start recording."
  if (stage === "recording") return "Hold gear and throttle; lift below 75% to finish."
  if (stage === "finishing") return "Processing pull."
  return "Start the engine, select a high gear, then arm the pull."
})

const liveRpm = computed(() => {
  const rpm = currentSample.value?.rpm
  return rpm == null ? "--" : String(Math.round(rpm))
})

const liveGear = computed(() => {
  const gear = currentSample.value?.gear
  return gear == null ? "--" : String(gear)
})

const liveThrottle = computed(() => {
  const throttle = currentSample.value?.throttle
  return throttle == null ? "--" : `${Math.round(throttle * 100)}%`
})

const livePower = computed(() => {
  const value = currentSample.value?.wheelPower
  return value == null ? "--" : units.buildString("power", value, 0)
})

const liveTorque = computed(() => {
  const value = currentSample.value?.wheelTorque
  if (value == null) return "--"

  try {
    return units.buildString("torque", value, 0)
  } catch (error) {
    return `${Math.round(value)} Nm`
  }
})

const formattedPower = computed(() => {
  const value = displayedResult.value?.peakPower
  return value == null ? "--" : units.buildString("power", value, 0)
})

const formattedPowerRpm = computed(() => {
  const value = displayedResult.value?.peakPowerRpm
  return value ? `at ${Math.round(value)} RPM` : "RPM unavailable"
})

const formattedTorque = computed(() => {
  const value = displayedResult.value?.peakTorque
  if (value == null) return "--"

  try {
    return units.buildString("torque", value, 0)
  } catch (error) {
    return `${Math.round(value)} Nm`
  }
})

const formattedTorqueRpm = computed(() => {
  const value = displayedResult.value?.peakTorqueRpm
  return value ? `at ${Math.round(value)} RPM` : "RPM unavailable"
})

// Lua keeps every measured pull (valid is always true now) and reports problems through pullQuality /
// measurementComplete / qualityFlags, so a pull is clean only when none of those say otherwise
const resultIsClean = computed(() => {
  const result = displayedResult.value
  if (!result) return false
  if (result.valid === false || result.measurementComplete === false) return false
  if (result.pullQuality === "warning" || result.pullQuality === "invalid") return false
  const flags = result.qualityFlags || {}
  return !Object.keys(flags).some(flag => flags[flag])
})
const resultQualityLabel = computed(() => (displayedResult.value ? (resultIsClean.value ? "Clean" : "Warning") : "--"))

const resultSampleCounts = computed(() => {
  const result = displayedResult.value
  if (!result) return "--"
  return `${result.acceptedSampleCount || 0} accepted / ${result.rejectedSampleCount || 0} rejected`
})

const flagNames = {
  gearChanged: "Gear Change",
  neutralGear: "Neutral Or Reverse",
  throttleLift: "Throttle Lift",
  brakeInput: "Brake Input",
  noRpmClimb: "No RPM Climb",
  noUsablePower: "No Usable Power",
  insufficientData: "Insufficient Clean Data",
  timeout: "Timeout",
  unstableRpm: "Unstable RPM",
  powerSpike: "Power Spike",
  torqueSpike: "Torque Spike",
  sustainedTorqueRoughness: "Sustained Torque Fluctuation",
  dynoSweepUnregulated: "Dyno Could Not Hold Sweep Rate",
  pullInterrupted: "Pull Interrupted",
  throttleBelowTarget: "Throttle Below 90%",
  waitingForStableGear: "Waiting For Gear",
  waitingForThrottle: "Waiting For Throttle",
}

const qualityFlagLabels = computed(() => {
  const flags = displayedResult.value?.qualityFlags || sessionData.value?.qualityFlags || {}
  if (Array.isArray(flags)) {
    return flags.map(flag => flagNames[flag] || String(flag))
  }

  return Object.keys(flags)
    .filter(flag => flags[flag])
    .map(flag => flagNames[flag] || flag)
})

const comparisonPull = computed(() => {
  if (selectedComparisonId.value === null) return null
  return sessionData.value?.savedPulls?.find(pull => String(pull.id) === String(selectedComparisonId.value)) || null
})

// ---- curve chart (the old Angular HUD's model): both curves in the player's display units on one shared
// scale, RPM from 1000 to the next 500 above the top of the pull, round value steps for the axis
const GRAPH_W = 720
const GRAPH_H = 320
const PLOT = { x: 84, y: 34, w: 600, h: 226 }
const toNum = v => (Number.isFinite(Number(v)) ? Number(v) : 0)
function displayValue(kind, value) {
  const n = toNum(value)
  try {
    const helper = typeof units?.[kind] === "function" ? units[kind](n) : null
    if (helper && typeof helper.val === "number") return helper.val
  } catch (_) {}
  return n
}
function unitLabel(kind, fallback) {
  try {
    const helper = typeof units?.[kind] === "function" ? units[kind](1) : null
    if (helper?.unit) return helper.unit
  } catch (_) {}
  return fallback
}
const powerUnit = computed(() => unitLabel("power", "kW"))
const torqueUnit = computed(() => unitLabel("torque", "Nm"))
const graph = computed(() => {
  const curve = displayedResult.value?.curve
  if (!Array.isArray(curve) || !curve.length) return null
  const compare = Array.isArray(comparisonPull.value?.curve) ? comparisonPull.value.curve : null
  const points = compare ? curve.concat(compare) : curve
  const minRpm = 1000
  const maxRpm = Math.max(minRpm + 500, Math.ceil(Math.max(...points.map(p => toNum(p.rpm))) / 500) * 500)
  const rawMaxY = Math.max(50, ...points.map(p => Math.max(displayValue("power", p.power), displayValue("torque", p.torque))))
  const yStep = rawMaxY > 600 ? 100 : 50
  const maxY = Math.max(yStep, Math.ceil(rawMaxY / yStep) * yStep)
  const xOf = rpm => PLOT.x + ((Math.max(minRpm, toNum(rpm)) - minRpm) / Math.max(1, maxRpm - minRpm)) * PLOT.w
  const yOf = v => PLOT.y + PLOT.h - (Math.max(0, v) / maxY) * PLOT.h
  const line = (src, kind) => src.map(p => `${xOf(p.rpm).toFixed(1)},${yOf(displayValue(kind, p[kind])).toFixed(1)}`).join(" ")
  // value axis: at most 8 lines on round steps, the top always labelled
  const lineStep = Math.max(yStep, Math.ceil(maxY / Math.min(8, Math.max(2, Math.ceil(maxY / yStep))) / yStep) * yStep)
  const yLabels = []
  for (let v = 0; v <= maxY; v += lineStep) yLabels.push({ value: v, y: yOf(v) })
  if (yLabels[yLabels.length - 1].value !== maxY) yLabels.push({ value: maxY, y: yOf(maxY) })
  // RPM axis: 1k steps (2k for very wide pulls), both ends labelled
  const rpmLabel = v => (v < 1000 ? String(Math.round(v)) : `${Math.round(v / 100) / 10}k`)
  const xStep = maxRpm - minRpm > 7000 ? 2000 : 1000
  const xLabels = [{ value: minRpm, label: rpmLabel(minRpm), x: xOf(minRpm) }]
  for (let v = Math.ceil(minRpm / xStep) * xStep; v < maxRpm; v += xStep) if (v !== minRpm) xLabels.push({ value: v, label: rpmLabel(v), x: xOf(v) })
  if (xLabels[xLabels.length - 1].value !== maxRpm) xLabels.push({ value: maxRpm, label: rpmLabel(maxRpm), x: xOf(maxRpm) })
  return {
    plot: PLOT, minRpm, maxRpm, curve, xOf, yOf, yLabels, xLabels,
    power: line(curve, "power"),
    torque: line(curve, "torque"),
    comparePower: compare ? line(compare, "power") : "",
    compareTorque: compare ? line(compare, "torque") : "",
  }
})
// hover: snap to the nearest recorded RPM and read power / torque there
const graphHover = ref(null)
function onGraphMove(e) {
  const g = graph.value
  const rect = e.currentTarget?.getBoundingClientRect?.()
  if (!g || !rect?.width) return
  const x = ((e.clientX - rect.left) / rect.width) * GRAPH_W
  const clamped = Math.max(g.plot.x, Math.min(g.plot.x + g.plot.w, x))
  const rpm = g.minRpm + ((clamped - g.plot.x) / g.plot.w) * (g.maxRpm - g.minRpm)
  const point = g.curve.reduce((best, p) => (Math.abs(toNum(p.rpm) - rpm) < Math.abs(toNum(best.rpm) - rpm) ? p : best), g.curve[0])
  const px = g.xOf(point.rpm)
  const boxX = Math.max(g.plot.x + 4, px > g.plot.x + g.plot.w - 190 ? px - 192 : px + 8)
  graphHover.value = {
    x: px,
    powerY: g.yOf(displayValue("power", point.power)),
    torqueY: g.yOf(displayValue("torque", point.torque)),
    boxX,
    rpm: `${Math.round(toNum(point.rpm)).toLocaleString()} RPM`,
    power: units.buildString("power", toNum(point.power), 0),
    torque: (() => {
      try {
        return units.buildString("torque", toNum(point.torque), 0)
      } catch (_) {
        return `${Math.round(toNum(point.torque))} Nm`
      }
    })(),
  }
}

function formatSavedPullDate(savedAt) {
  const timestamp = Number(savedAt)
  if (!Number.isFinite(timestamp) || timestamp <= 0) return "Saved Pull"
  return new Date(timestamp * 1000).toLocaleString()
}

function formatSavedPullSummary(pull) {
  return `${units.buildString("power", Number(pull?.peakPower) || 0, 0)} at ${Math.round(Number(pull?.peakPowerRpm) || 0)} RPM`
}

async function withBusy(action) {
  if (busy.value) return

  busy.value = true
  try {
    await action()
  } catch (error) {
    // a rejected Lua call: log it and fall through to the refresh, which shows whatever Lua reports now
    console.error("Dyno session action failed", error)
  } finally {
    busy.value = false
    await refreshSessionData()
  }
}

async function handleStartSession() {
  await withBusy(async () => {
    await lua.career_modules_dynoSession.startSession(selectedHubId.value)
  })
}

async function handleRepairAndStart() {
  await withBusy(async () => {
    await lua.career_modules_dynoSession.repairAndStart(selectedHubId.value)
  })
}

async function handleOpenMaintenance() {
  await withBusy(async () => {
    await lua.career_modules_dynoSession.openMaintenance()
  })
}

async function handleOpenTuning() {
  await withBusy(async () => {
    await lua.career_modules_dynoSession.openTuning()
  })
}

async function handleStartPull() {
  await withBusy(async () => {
    await lua.career_modules_dynoSession.startPull()
  })
}

async function handleRetryPull() {
  await withBusy(async () => {
    await lua.career_modules_dynoSession.retryPull()
  })
}

async function handleSavePull() {
  await withBusy(async () => {
    await lua.career_modules_dynoSession.saveCurrentPull()
  })
}

async function handleDeleteSavedPull(pull) {
  if (!pull) return
  // house popup (pad focus, B = cancel); the old Angular HUD used window.confirm, which the game never shows
  const confirmed = await openHouseConfirmation("Delete saved pull", "Delete this saved dyno pull?", [
    { label: "Delete", value: true, extras: { destructive: true } },
    { label: "Cancel", value: false, extras: { cancel: true, default: true } },
  ])
  if (!confirmed) return
  if (String(selectedComparisonId.value) === String(pull.id)) {
    selectedComparisonId.value = null
  }
  await withBusy(async () => {
    await lua.career_modules_dynoSession.deleteSavedPull(pull.id)
  })
}

async function handleLeaveSession() {
  await withBusy(async () => {
    await lua.career_modules_dynoSession.leaveSession()
  })
}

// ---- overlay: shown / hidden by Lua, polled while visible
const visible = ref(false)
// one poll at a time: a slow bridge reply skips ticks instead of piling up requests
let pollInFlight = false
async function pollOnce() {
  if (pollInFlight) return
  pollInFlight = true
  try {
    await refreshSessionData()
  } finally {
    pollInFlight = false
  }
}
function startPolling() {
  if (refreshTimer) return
  pollOnce()
  refreshTimer = setInterval(pollOnce, 250)
}
function stopPolling() {
  if (refreshTimer) clearInterval(refreshTimer)
  refreshTimer = null
}
async function onShow() {
  await loadLayout()
  visible.value = true
  startPolling()
  nextTick(clampToScreen)
}
function onHide() {
  visible.value = false
  stopPolling()
  showHowTo.value = false
  selectedComparisonId.value = null
}
function onState(payload) {
  if (payload && typeof payload === "object") sessionData.value = payload
  if (!visible.value) onShow()
}

// ---- drag by the header; the position is the old HUD's saved setting (overhaul_settings)
const LAYOUT_KEY = "dynoSessionHudLayout"
const pos = ref({ x: 18, y: 18 })
const cardEl = ref(null)
const drag = ref(null)
function clampToScreen() {
  const card = cardEl.value
  const w = card ? card.offsetWidth : 300
  const vw = window.innerWidth || 1280
  const vh = window.innerHeight || 720
  pos.value = {
    x: Math.round(Math.max(0, Math.min(pos.value.x, vw - Math.min(w, vw)))),
    // keep at least the header on screen
    y: Math.round(Math.max(0, Math.min(pos.value.y, vh - 48))),
  }
}
async function loadLayout() {
  try {
    // mod extension: not in the game's bridge signatures, so call it by name (nil-safe if not loaded)
    const saved = await callModLua("overhaul_settings.getSetting", LAYOUT_KEY)
    if (saved && typeof saved === "object") pos.value = { x: Number(saved.x) || 18, y: Number(saved.y) || 18 }
  } catch (_) {}
}
function saveLayout() {
  try {
    callModLua("overhaul_settings.setSetting", LAYOUT_KEY, { x: pos.value.x, y: pos.value.y })
  } catch (_) {}
}
function startDrag(e) {
  // the pull HUD lets clicks through, and buttons in the header keep their own clicks
  if (e.button !== 0 || sessionData.value?.phase === "pulling" || e.target.closest?.("button")) return
  drag.value = { x: e.clientX, y: e.clientY, ox: pos.value.x, oy: pos.value.y }
  window.addEventListener("mousemove", onDrag)
  window.addEventListener("mouseup", endDrag, { once: true })
  e.preventDefault()
}
function onDrag(e) {
  if (!drag.value) return
  pos.value = { x: drag.value.ox + e.clientX - drag.value.x, y: drag.value.oy + e.clientY - drag.value.y }
  clampToScreen()
}
function endDrag() {
  window.removeEventListener("mousemove", onDrag)
  if (!drag.value) return
  drag.value = null
  saveLayout()
}

const busEvents = [
  ["DynoSessionHudShow", onShow],
  ["DynoSessionHudHide", onHide],
  ["DynoSessionHudState", onState],
]
const otherBus = () => (typeof window !== "undefined" && window.vueEventBus && window.vueEventBus !== bridge.events ? window.vueEventBus : null)
onMounted(async () => {
  for (const [name, fn] of busEvents) {
    bridge.events.on(name, fn)
    otherBus()?.on(name, fn)
  }
  window.addEventListener("resize", clampToScreen)
  // Lua only says "show" when the car enters the bay, so after a UI reload mid-session the card would stay
  // hidden: ask once and come back if a session is running or the car is still in the bay
  try {
    const data = await lua.career_modules_dynoSession?.requestSessionData?.()
    if (data && (data.active || data.triggerActive)) onState(data)
  } catch (_) {}
})

onUnmounted(() => {
  for (const [name, fn] of busEvents) {
    bridge.events.off(name, fn)
    otherBus()?.off(name, fn)
  }
  window.removeEventListener("resize", clampToScreen)
  window.removeEventListener("mousemove", onDrag)
  stopPolling()
})
</script>

<style scoped lang="scss">
@import "../styles/rlsHouse.scss";

.dyno-overlay {
  position: fixed;
  z-index: 8500;
  pointer-events: none; // only the card takes the mouse
}

/* ---------- card ---------- */
.dyno-card.rls-house {
  // a touch under the house vh scale: it sits over the road while you drive
  font-size: clamp(0.7rem, calc(1.35vh * var(--ui-scale, 1)), 2.2rem);
  display: grid;
  align-content: start;
  gap: var(--space-3);
  width: min(31em, calc(100vw - 2em));
  pointer-events: auto;
  max-height: calc(100vh - 2em);
  overflow-y: auto;
  padding: 1em 1.1em 1.1em;
  border-radius: var(--radius-control);
  background: rgba(var(--bng-off-black-rgb), 0.92);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
  color: #fff;
  font-variant-numeric: tabular-nums;
}
// width per phase: compact while pulling, wide for the result and its curve
.dyno-card.phase-pulling { width: min(27em, calc(100vw - 2em)); pointer-events: none; } // clicks go to the game
.dyno-card.phase-complete,
.dyno-card.phase-leaving { width: min(46em, calc(100vw - 2em)); }
.dyno-card.dragging { user-select: none; }
.dyno-head {
  cursor: grab;
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: var(--space-3);
}
.head-copy { display: grid; gap: 0.15em; min-width: 0; }
.vehicle-name {
  margin: 0;
  font-size: 1.3em;
  font-weight: 800;
  line-height: 1.2;
  overflow-wrap: anywhere;
}
.dyno-head > .pill { flex: 0 0 auto; margin-top: 0.2em; }
.dyno-card.dragging .dyno-head { cursor: grabbing; }
.dyno-card.phase-pulling .dyno-head { cursor: default; }

.notice {
  margin: 0;
  padding: 0.55em 0.75em 0.45em;
  border-radius: var(--radius-panel);
  background: var(--panel);
  color: var(--muted);
  font-size: 0.92em;
  font-weight: 600;
  line-height: 1.35;
}
.notice.bad { background: rgba(252, 165, 165, 0.12); color: var(--bad); }
.money { color: var(--money); }
.ok-text { color: var(--ok); }
.warn-text { color: var(--warn); }
.accent-text { color: var(--accent-soft); }
.cur { --bng-icon-size: 0.95em; transform: translateY(-0.05em); }
.stat-value .cur, .result-value .cur { margin-right: 0.1em; }

/* ---------- offer ---------- */
.offer-strip {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-end;
  gap: 0.6em 2em;
}
.offer-strip .stat-value { font-size: 1.35em; font-weight: 800; }
.offer-note {
  flex: 1 1 14em;
  margin: 0;
  color: var(--faint);
  font-size: 0.85em;
  font-weight: 600;
  line-height: 1.35;
}
.hub-block { display: grid; gap: 0.45em; }
.hub-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(min(100%, 11em), 1fr));
  gap: 0.5em;
}
.hub-tile {
  @include house-focus;
  position: relative;
  appearance: none;
  display: grid;
  align-content: start;
  gap: 0.3em;
  margin: 0;
  padding: 0.7em 0.8em 0.75em;
  border: 0;
  border-radius: var(--radius-panel);
  background: var(--panel);
  color: #fff;
  font: inherit;
  text-align: left;
  cursor: pointer;
  &:hover:not(:disabled) { background: var(--panel-2); }
  &.picked { background: var(--panel-2); box-shadow: inset 0 0 0 1px rgba(255, 178, 122, 0.45); }
  &.picked strong { color: var(--accent-soft); }
  &:disabled { opacity: 0.55; cursor: default; }
  small { color: var(--muted); font-size: 0.82em; font-weight: 600; line-height: 1.35; }
}
.hub-top {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 0.5em;
  strong { font-size: 1em; line-height: 1.2; }
}
.hub-check { flex: 0 0 auto; color: var(--accent-soft); --bng-icon-size: 1.05em; }
.repair-panel .line strong { font-weight: 700; white-space: nowrap; }
.repair-panel .line.total { font-weight: 800; }
.repair-panel .split-head { flex-wrap: wrap; }

/* ---------- live ---------- */
.stage-strip {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 0.6em 0.9em;
  padding: 0.75em 0.85em;
  border-radius: var(--radius-panel);
  background: var(--panel);
}
.stage-icon {
  flex: 0 0 auto;
  display: grid;
  place-items: center;
  width: 2.1em;
  height: 2.1em;
  border-radius: 50%;
  background: rgba(255, 255, 255, 0.08);
  color: var(--muted);
  --bng-icon-size: 1.2em;
}
.stage-strip.recording .stage-icon { background: var(--accent-ink); color: var(--accent-soft); }
.stage-strip.armed .stage-icon { background: rgba(251, 191, 36, 0.18); color: var(--money); }
.stage-copy {
  flex: 1 1 14em;
  display: grid;
  gap: 0.15em;
  min-width: 0;
  strong { font-size: 1.15em; font-weight: 800; }
  span { color: var(--muted); font-weight: 600; line-height: 1.3; }
}
.stage-facts { display: flex; flex-wrap: wrap; gap: 0.35em; }

.live-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(min(100%, 8.5em), 1fr));
  gap: 0.5em;
}
.gauge {
  display: grid;
  gap: 0.25em;
  padding: 0.65em 0.8em 0.6em;
  border-radius: var(--radius-panel);
  background: var(--panel);
}
.gauge-value {
  font-size: 1.55em;
  font-weight: 800;
  line-height: 1.15;
  white-space: nowrap;
}
.throttle { display: grid; gap: 0.4em; }
.throttle-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  strong { font-size: 1.1em; font-weight: 800; }
}
.throttle-track {
  position: relative;
  height: 0.6em;
  margin-bottom: 1.1em; // room for the threshold labels
  border-radius: 1em;
  background: rgba(255, 255, 255, 0.1);
}
.throttle-fill {
  position: absolute;
  inset: 0;
  border-radius: inherit;
  background: rgba(255, 255, 255, 0.6);
  transform-origin: left center;
  // updates 4x a second: retarget smoothly over the poll interval
  transition: transform 250ms linear;
  &.hot { background: var(--accent); }
}
.mark {
  position: absolute;
  top: -0.2em;
  bottom: -0.2em;
  width: 2px;
  margin-left: -1px;
  background: rgba(255, 255, 255, 0.55);
  i {
    position: absolute;
    top: 100%;
    margin-top: 0.3em;
    right: 0.35em; // "75% ends" ends at its mark
    left: auto;
    color: var(--faint);
    font-size: 0.72em;
    font-style: normal;
    font-weight: 700;
    white-space: nowrap;
  }
  &.start { background: var(--accent-soft); }
  &.start i { right: auto; left: 50%; transform: translateX(-50%); color: var(--accent-soft); }
}
.samples {
  margin: 0;
  color: var(--faint);
  font-size: 0.88em;
  font-weight: 600;
  strong { color: #fff; }
  .sep { margin: 0 0.4em; }
}

/* ---------- result ---------- */
.result-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(min(100%, 10em), 1fr));
  gap: 0.5em;
}
.result {
  display: grid;
  gap: 0.2em;
  padding: 0.7em 0.85em 0.65em;
  border-radius: var(--radius-panel);
  background: var(--panel);
}
.result-value {
  font-size: 1.55em;
  font-weight: 800;
  line-height: 1.15;
  white-space: nowrap;
}
.warn-row { display: flex; flex-wrap: wrap; align-items: center; gap: 0.35em 0.45em; }
.warn-row .caption { margin-right: 0.2em; }

.curve-panel { gap: 0.4em; }
.curve-legend { display: flex; flex-wrap: wrap; justify-content: flex-end; gap: 0.3em 1em; }
.legend {
  display: inline-flex;
  align-items: center;
  gap: 0.4em;
  color: var(--muted);
  font-size: 0.8em;
  font-weight: 700;
  &::before {
    content: "";
    width: 1.2em;
    height: 0;
    border-top: 2px solid currentColor;
  }
  &.power::before { border-color: var(--accent); }
  &.torque::before { border-color: rgba(255, 255, 255, 0.85); }
  &.dashed::before { border-top-style: dashed; }
}
.curve-svg {
  display: block;
  width: 100%;
  aspect-ratio: 2.25 / 1;
  height: auto;
  cursor: crosshair;
  .grid line { stroke: rgba(255, 255, 255, 0.07); stroke-width: 1.5; }
  .plot-border { fill: none; stroke: rgba(255, 255, 255, 0.14); stroke-width: 1.5; }
  polyline { fill: none; stroke-linejoin: round; stroke-linecap: round; }
  .primary-curve { stroke: var(--accent); stroke-width: 4; }
  .primary-torque-curve { stroke: rgba(255, 255, 255, 0.85); stroke-width: 3.5; }
  .comparison-curve { stroke: var(--accent-soft); stroke-width: 2.5; stroke-dasharray: 9 6; opacity: 0.8; }
  .comparison-torque-curve { stroke: rgba(255, 255, 255, 0.55); stroke-width: 2.5; stroke-dasharray: 9 6; }
  .axis text { fill: var(--faint); font-size: 13px; font-weight: 700; dominant-baseline: middle; }
  .axis-y { text-anchor: end; }
  .axis-x { text-anchor: middle; }
  .axis-title { fill: var(--muted); letter-spacing: 0.08em; text-anchor: middle; }
  .hover-line { stroke: rgba(255, 255, 255, 0.5); stroke-width: 1.5; stroke-dasharray: 5 5; }
  .hover-power, .hover-torque { stroke: #131315; stroke-width: 2; }
  .hover-power { fill: var(--accent); }
  .hover-torque { fill: #fff; }
  .hover-box { fill: rgba(19, 19, 21, 0.95); stroke: rgba(255, 255, 255, 0.14); stroke-width: 1.5; }
  .hover text { font-size: 14px; font-weight: 800; text-anchor: start; dominant-baseline: middle; }
  .hover-rpm { fill: var(--muted); }
  .hover-power-text { fill: var(--accent-soft); }
  .hover-torque-text { fill: #fff; }
}


.history { display: grid; gap: 0.45em; }
.history-list {
  display: grid;
  gap: 0.35em;
  max-height: 12.5em;
}
.history-row {
  display: flex;
  align-items: center;
  gap: 0.4em;
  padding-right: 0.4em;
  border-radius: var(--radius-panel);
  background: var(--panel);
  &.picked { background: var(--panel-2); }
}
.history-pick {
  @include house-focus(var(--focus-inset));
  position: relative;
  appearance: none;
  flex: 1 1 auto;
  display: flex;
  align-items: center;
  gap: 0.7em;
  min-width: 0;
  margin: 0;
  padding: 0.55em 0.75em 0.5em;
  border: 0;
  border-radius: var(--radius-panel);
  background: transparent;
  color: inherit;
  font: inherit;
  text-align: left;
  cursor: pointer;
  .row-copy strong { font-size: 1em; }
}
.history-row.picked .row-copy strong { color: var(--accent-soft); }

/* ---------- actions ---------- */
.button-row {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.45em;
  padding-top: var(--space-2);
  border-top: 1px solid var(--line);
}
.button-row .row-gap { flex: 1 1 auto; }
// side trips (how-to, maintenance, tuning): quiet tools above the main row
.tool-row {
  display: flex;
  flex-wrap: wrap;
  gap: 0.4em;
}
.btn-price {
  display: inline-flex;
  align-items: center;
  gap: 0.15em;
  margin-left: 0.35em;
  opacity: 0.92;
}

/* ---------- How it works ---------- */
// the overlay root lets clicks through to the game; the dialog has to take them back
.how-to-backdrop {
  pointer-events: auto;
  position: fixed;
  inset: 0;
  z-index: 20;
  display: grid;
  place-items: center;
  background: rgba(0, 0, 0, 0.55);
}
.how-to-dialog.rls-house {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  display: grid;
  gap: var(--space-3);
  width: min(32em, calc(100vw - 2em));
  padding: 1.1em 1.2em 1.1em;
  border-radius: var(--radius-control);
  background: rgba(var(--bng-off-black-rgb), 0.97);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.07), 0 18px 50px rgba(0, 0, 0, 0.55);
  color: #fff;
}
.how-to-dialog .kicker { margin-bottom: -0.4em; }
.steps {
  display: grid;
  gap: 0.55em;
  margin: 0;
  padding: 0;
  list-style: none;
  li { display: flex; align-items: flex-start; gap: 0.65em; font-weight: 600; line-height: 1.35; }
  strong { color: var(--accent-soft); }
}
.step-n {
  flex: 0 0 auto;
  display: grid;
  place-items: center;
  width: 1.6em;
  height: 1.6em;
  border-radius: 50%;
  background: var(--panel-2);
  color: #fff;
  font-size: 0.85em;
  font-weight: 800;
}
.how-to-foot {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 0.6em;
  padding-top: var(--space-2);
  border-top: 1px solid var(--line);
}
.check input.pad-check { position: relative; @include house-focus; }
</style>
