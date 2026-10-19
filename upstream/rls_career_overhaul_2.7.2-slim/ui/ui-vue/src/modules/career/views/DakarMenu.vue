<template>
  <!-- Controller (no scope on this screen): B / Start close, LB / RB switch Sign Up / Accolades, and each
       view puts focus on its main action when it opens -->
  <div
    class="dakar-shell"
    v-bng-on-ui-nav:back,menu="onNavClose"
    v-bng-on-ui-nav:tab_l="prevTab"
    v-bng-on-ui-nav:tab_r="nextTab">
    <div class="dakar-panel" v-bng-ui-nav-scroll>
      <header class="topbar">
        <div>
          <h1>Dakar</h1>
          <p>{{ subtitle }}</p>
        </div>
        <BngButton :accent="ACCENTS.secondary" @click="close">Close</BngButton>
      </header>

      <div class="tabs">
        <BngBinding v-if="activeTab !== 'start'" class="tab-glyph" ui-event="tab_l" controller track-ignore />
        <BngButton class="tab-signup" :accent="activeTab === 'signup' ? ACCENTS.main : ACCENTS.secondary" @click="activeTab = 'signup'">Event Sign Up</BngButton>
        <BngButton class="tab-accolades" :accent="activeTab === 'accolades' ? ACCENTS.main : ACCENTS.secondary" @click="activeTab = 'accolades'">Dakar Accolades</BngButton>
        <BngBinding v-if="activeTab !== 'start'" class="tab-glyph" ui-event="tab_r" controller track-ignore />
      </div>

      <section v-if="activeTab === 'start'" class="start-confirm">
        <h2>Dakar Start</h2>
        <p>Begin the run when you are ready.</p>
        <div class="details-grid">
          <div class="detail">
            <span>Class</span>
            <strong>{{ data.pending?.classLabel || data.classInfo?.label || 'Unlimited' }}</strong>
          </div>
          <div class="detail">
            <span>Repair Kits</span>
            <strong>{{ data.pending?.repairsLeft || 0 }}</strong>
          </div>
        </div>
        <BngButton class="signup-button" :accent="ACCENTS.main" @click="startEvent">Start Event</BngButton>
      </section>

      <section v-else-if="showIntroScreen" class="intro">
        <div class="intro-copy">
          <h2>The desert does not care how fast you are.</h2>
          <p>Read the land, protect the machine, and keep moving. Dakar rewards the driver who can finish what they start.</p>
        </div>

        <div class="intro-list">
          <div>Use the checkpoint photo, name, and distance to navigate.</div>
          <div>No GPS route is provided once the Dakar begins.</div>
          <div>Checkpoint markers only appear when you are close.</div>
          <div>Repair Kits must fit in your cargo boxes and add time penalties when used.</div>
          <div>Placement and time bonus are revealed after the finish.</div>
        </div>

        <label class="intro-check">
          <input type="checkbox" class="intro-check-box" v-model="dontShowIntroAgain">
          <span>Do not show again</span>
        </label>

        <BngButton class="signup-button" :accent="ACCENTS.main" @click="continueIntro">Continue</BngButton>
      </section>

      <section v-else-if="activeTab === 'signup'" class="signup">
        <div v-if="data.setupBlockedReason" class="blocked-banner">
          {{ data.setupBlockedReason }}
        </div>

        <div class="class-section">
          <div class="section-label">Class:</div>
          <div class="class-breakdown">
            <div v-for="classId in classOrder" :key="`${classId}-description`" class="class-description" :class="{ selected: data.classInfo?.id === classId }">
              <strong>{{ classTitle(classId) }} Class <span>{{ classes[classId]?.checkpointCount || 0 }} CP</span></strong>
              <span>{{ classDescriptions[classId] || 'Dakar eligible vehicles.' }}</span>
            </div>
          </div>
        </div>

        <div class="registration-section">
          <div class="section-label">Registration Info:</div>
          <div class="details-grid">
            <div class="detail">
              <span>Registered Vehicle</span>
              <strong>{{ data.classInfo?.vehicleName || 'No vehicle detected' }}</strong>
            </div>
            <div class="detail">
              <span>Cargo Space</span>
              <strong>{{ cargoSpaceLabel }}</strong>
            </div>
            <div class="detail kit-detail">
              <span>Repair Kits Ordered</span>
              <div class="kit-controls">
                <!-- disabled buttons leave pad navigation (bng-no-nav); a limit hit while focused moves
                     focus to the other button (see the kitCount watcher) -->
                <BngButton class="kit-less" :accent="ACCENTS.secondary" :disabled="kitCount <= 0" :bng-no-nav="kitCount <= 0 ? 'true' : null" @click="kitCount--">-</BngButton>
                <strong>{{ kitCount }}</strong>
                <BngButton class="kit-more" :accent="ACCENTS.secondary" :disabled="kitCount >= maxKits" :bng-no-nav="kitCount >= maxKits ? 'true' : null" @click="kitCount++">+</BngButton>
              </div>
            </div>
            <div class="detail">
              <span>Repair Kit Cost</span>
              <strong><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(data.repairKit.cost) }}</strong>
            </div>
          </div>
        </div>

        <div class="totals">
          <span>{{ kitCount * (data.repairKit.slots || 0) }} cargo slots</span>
          <span>{{ units.buildString('weight', kitCount * (data.repairKit.weightKg || 0), 0) }}</span>
          <strong><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(kitCount * (data.repairKit.cost || 0)) }}</strong>
        </div>

        <div v-if="data.lastResult && props.tab === 'result'" class="result">
          <h2>{{ data.lastResult.placement }}</h2>
          <div class="result-grid">
            <span>Time</span><strong>{{ time(data.lastResult.adjustedSeconds) }}</strong>
            <span>Target</span><strong>{{ time(data.lastResult.targetSeconds) }}</strong>
            <span>Penalty</span><strong>{{ time(data.lastResult.repairPenaltySeconds) }}</strong>
            <span>Reward</span><strong><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(data.lastResult.totalReward) }}</strong>
          </div>
        </div>

        <BngButton
          class="signup-button"
          :accent="ACCENTS.main"
          :disabled="signUpBlocked"
          :bng-no-nav="signUpBlocked ? 'true' : null"
          @click="signUp">Sign Up</BngButton>
      </section>

      <section v-else class="accolades">
        <div v-for="acc in data.accolades" :key="acc.id" class="accolade">
          <div>
            <h2>{{ acc.title }}</h2>
            <p>{{ acc.description }}</p>
            <div class="progress"><span :style="{ width: progressWidth(acc) }"></span></div>
            <div class="accolade-meta">
              <small>{{ acc.progress }} / {{ acc.target }}</small>
              <strong><template v-if="acc.rewardLabel">{{ acc.rewardLabel }}</template><template v-else><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(acc.rewardMoney) }}</template></strong>
            </div>
          </div>
          <BngButton
            class="claim-button"
            :accent="acc.ready ? ACCENTS.main : ACCENTS.secondary"
            :disabled="!acc.ready"
            :bng-no-nav="!acc.ready ? 'true' : null"
            @click="claim(acc.id)">
            {{ acc.claimed ? 'Claimed' : 'Claim' }}
          </BngButton>
        </div>
      </section>
    </div>
  </div>
</template>

<script setup>
import { computed, onMounted, onUnmounted, reactive, ref, watch } from 'vue'
import { BngButton, ACCENTS, BngBinding, BngIcon, icons } from '@/common/components/base'
import { vBngOnUiNav, vBngUiNavScroll } from '@/common/directives'
import { useBridge } from '@/bridge'
import { refocusIfLost } from '../composables/useScreenEntryFocus'

const props = defineProps({
  tab: {
    type: String,
    default: 'signup'
  }
})

const { events, units } = useBridge()
const activeTab = ref(['accolades', 'start'].includes(props.tab) ? props.tab : 'signup')
const kitCount = ref(0)
const introDismissedThisOpen = ref(false)
const dontShowIntroAgain = ref(false)
const data = reactive({
  phase: 'idle',
  classInfo: null,
  setupBlockedReason: null,
  showIntro: false,
  classes: {},
  classOrder: [],
  repairKit: {},
  pending: null,
  accolades: [],
  lastResult: null
})

const classes = computed(() => data.classes || {})
const classOrder = computed(() => data.classOrder || [])
const maxKits = computed(() => Math.max(0, data.repairKit?.maxByCargo || 0))
const subtitle = computed(() => data.phase === 'signedUp' ? 'Proceed to the Dakar start' : 'Navigation and endurance')
const showIntroScreen = computed(() => activeTab.value === 'signup' && data.showIntro && !introDismissedThisOpen.value)
const classDescriptions = {
  SSV: 'Side by Side Vehicles, UTVs, and Buggies.',
  Raid: 'Pickup and SUV bodies only.',
  Heavy: 'Stambecco, MD-series, and T-series.',
  Unlimited: "Everything else that doesn't fit."
}
const signUpBlocked = computed(() => data.phase === 'active' || !!data.setupBlockedReason)
const cargoSpaceLabel = computed(() => {
  const slots = data.repairKit?.freeCargoSlots || 0
  const boxes = data.repairKit?.cargoContainerCount || 0
  if (!boxes) return `${slots} slots`
  return `${slots} slots / ${boxes} ${boxes === 1 ? 'box' : 'boxes'}`
})

function applyData(payload) {
  if (!payload) return
  data.phase = payload.phase || 'idle'
  data.classInfo = payload.classInfo || null
  data.setupBlockedReason = payload.setupBlockedReason || null
  data.showIntro = payload.showIntro === true
  data.classes = payload.classes || {}
  data.classOrder = payload.classOrder || []
  data.repairKit = payload.repairKit || {}
  data.pending = payload.pending || null
  data.accolades = payload.accolades || []
  data.lastResult = payload.lastResult || null
  kitCount.value = Math.min(kitCount.value, maxKits.value)
}

function luaString(value) {
  return `"${String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`
}

function callDakar(expression) {
  window.bngApi.engineLua(`local name = overhaul_maps and overhaul_maps.getOptionalFeatureExtension and overhaul_maps.getOptionalFeatureExtension('dakar'); local feature = name and extensions[name]; if feature then feature.${expression} end`)
}

function refresh() {
  callDakar('requestDakarMenuData()')
}

// Template puts the game currency glyph before it.
function money(value) {
  return Math.round(value || 0).toLocaleString()
}

function time(seconds) {
  seconds = Math.max(0, Math.floor(seconds || 0))
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`
}

function progressWidth(acc) {
  return `${Math.min(100, Math.round((acc.progress / Math.max(1, acc.target)) * 100))}%`
}

function classTitle(classId) {
  return classes.value[classId]?.label || classId
}

function signUp() {
  callDakar(`signUp(${Math.max(0, Math.floor(kitCount.value || 0))})`)
}

function continueIntro() {
  introDismissedThisOpen.value = true
  callDakar(`dismissIntro(${dontShowIntroAgain.value ? 'true' : 'false'})`)
}

function startEvent() {
  callDakar('startEvent()')
}

function claim(id) {
  callDakar(`claimAccolade(${luaString(id)})`)
}

function close() {
  callDakar('closeMenu()')
}

// ---- controller
const TABS = ['signup', 'accolades']
// unscoped screen: the directive's listener does not stop the ui_nav event, so B would also reach the
// game's global ui_router.back() fallback
function onNavClose(event) {
  event?.stopPropagation?.()
  close()
}
function prevTab(event) {
  event?.stopPropagation?.()
  if (activeTab.value === 'start') return
  activeTab.value = TABS[(TABS.indexOf(activeTab.value) + TABS.length - 1) % TABS.length]
}
function nextTab(event) {
  event?.stopPropagation?.()
  if (activeTab.value === 'start') return
  activeTab.value = TABS[(TABS.indexOf(activeTab.value) + 1) % TABS.length]
}
// each view's main action: Start Event, the intro's Continue, Sign Up (else the kit stepper), the
// first claimable accolade (else the accolades tab button)
const enabled = sel => document.querySelector(`.dakar-panel ${sel}:not([disabled])`)
function pickViewFocus() {
  if (activeTab.value === 'start' || showIntroScreen.value) return enabled('.signup-button')
  if (activeTab.value === 'signup') return enabled('.signup-button') || enabled('.kit-more') || enabled('.kit-less') || enabled('.tab-signup')
  return enabled('.claim-button') || enabled('.tab-accolades')
}
// a view swap unmounts the focused button: move to the new view's action
watch([activeTab, showIntroScreen], () => refocusIfLost(pickViewFocus, { force: !document.activeElement?.closest?.('.tabs') }), { flush: 'post' })
// first data (entry) and refreshes (claim / sign up re-render the buttons)
watch(() => [data.phase, data.accolades, data.setupBlockedReason], () => refocusIfLost(pickViewFocus), { flush: 'post' })
// the kit stepper disables - at 0 and + at the cargo limit, under focus: hop to the other one
// (force while the focused button is the one just disabled: the browser drops that focus only later)
watch(kitCount, () => refocusIfLost(() => enabled('.kit-more') || enabled('.kit-less') || pickViewFocus(), { force: !!document.activeElement?.disabled }), { flush: 'post' })

watch(() => props.tab, tab => {
  if (tab === 'accolades') activeTab.value = 'accolades'
  if (tab === 'start') activeTab.value = 'start'
  if (tab === 'signup' || tab === 'result') activeTab.value = 'signup'
})

onMounted(() => {
  events.on('dakarData', applyData)
  refresh()
})

onUnmounted(() => {
  events.off('dakarData', applyData)
})
</script>

<style scoped lang="scss">
.dakar-shell {
  // scaled unit: the screen keeps the same share of the display at 720p..4K (rem/px-sized it shrank at 1440p),
  // still following the player's UI scale
  --rls-u: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  font-size: var(--rls-u, var(--rls-u, 1rem));
  min-height: 100vh;
  color: white;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(0, 0, 0, 0.55);
}

.dakar-panel {
  width: min(calc(56.25 * var(--rls-u, 1rem)), 86vw);
  max-height: 86vh;
  overflow: auto;
  background: rgba(18, 18, 18, 0.94);
  border: 1px solid rgba(255, 255, 255, 0.14);
  border-radius: calc(0.5 * var(--rls-u, 1rem));
  padding: calc(1.375 * var(--rls-u, 1rem));
}

.tab-glyph {
  flex: 0 0 auto;
}
// the native "Do not show again" checkbox: house ring for keyboard / controller focus
.intro-check-box {
  position: relative;
  &.focus-visible,
  &:focus-visible {
    outline: none;
    box-shadow: 0 0 0 1.5px rgba(14, 14, 16, 0.95), 0 0 0 calc(0.2188 * var(--rls-u, 1rem)) var(--bng-orange-b400, #ff6600);
  }
  &.focus-visible::before {
    display: none !important;
  }
}

.topbar,
.tabs,
.totals,
.accolade {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: calc(0.75 * var(--rls-u, 1rem));
}

h1,
h2,
p {
  margin: 0;
}

.topbar p,
.detail span,
.totals,
.accolade p,
.accolade small {
  color: #cfcfcf;
}

.accolade-meta {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: calc(0.75 * var(--rls-u, 1rem));
}

.accolade-meta strong {
  color: #f5a623;
  white-space: nowrap;
}

.tabs {
  justify-content: flex-start;
  margin: calc(1.125 * var(--rls-u, 1rem)) 0;
}

.class-section,
.registration-section {
  display: grid;
  gap: calc(0.625 * var(--rls-u, 1rem));
}

.registration-section {
  margin-top: calc(1.375 * var(--rls-u, 1rem));
}

.section-label {
  color: #f5a623;
  font-size: calc(0.78 * var(--rls-u, var(--rls-u, 1rem)));
  font-weight: 800;
  letter-spacing: 0.06em;
  text-transform: uppercase;
}

.details-grid,
.class-breakdown {
  display: grid;
  gap: calc(0.625 * var(--rls-u, 1rem));
}

.details-grid {
  grid-template-columns: repeat(2, 1fr);
}

.class-breakdown {
  grid-template-columns: repeat(2, 1fr);
}

.class-description,
.detail,
.totals,
.result,
.intro-list,
.blocked-banner,
.accolade {
  background: rgba(255, 255, 255, 0.08);
  border-radius: calc(0.375 * var(--rls-u, 1rem));
  padding: calc(0.75 * var(--rls-u, 1rem));
}

.intro {
  display: grid;
  gap: calc(0.875 * var(--rls-u, 1rem));
}

.intro-copy {
  display: grid;
  gap: calc(0.5 * var(--rls-u, 1rem));
}

.intro-copy h2 {
  font-size: calc(1.35 * var(--rls-u, var(--rls-u, 1rem)));
}

.intro-copy p {
  color: #d9d9d9;
  line-height: 1.4;
}

.intro-list {
  display: grid;
  gap: calc(0.5 * var(--rls-u, 1rem));
}

.intro-list div {
  position: relative;
  padding-left: calc(1.125 * var(--rls-u, 1rem));
  color: #efefef;
}

.intro-list div::before {
  content: "";
  position: absolute;
  left: 0;
  top: 0.55em;
  width: calc(0.4375 * var(--rls-u, 1rem));
  height: calc(0.4375 * var(--rls-u, 1rem));
  border-radius: 50%;
  background: #f5a623;
}

.intro-check {
  display: inline-flex;
  align-items: center;
  gap: calc(0.5 * var(--rls-u, 1rem));
  color: #cfcfcf;
  width: fit-content;
}

.intro-check input {
  width: calc(1 * var(--rls-u, 1rem));
  height: calc(1 * var(--rls-u, 1rem));
}

.blocked-banner {
  margin-bottom: calc(0.75 * var(--rls-u, 1rem));
  color: #ffd4a8;
  border: 1px solid rgba(255, 160, 80, 0.45);
  background: rgba(255, 120, 40, 0.12);
  font-weight: 700;
}

.class-description {
  display: grid;
  gap: calc(0.25 * var(--rls-u, 1rem));
  border: 1px solid transparent;
}

.class-description.selected {
  border-color: rgba(245, 166, 35, 0.55);
  background: rgba(245, 166, 35, 0.13);
}

.class-description strong {
  display: flex;
  justify-content: space-between;
  gap: calc(0.625 * var(--rls-u, 1rem));
  font-size: calc(0.84 * var(--rls-u, var(--rls-u, 1rem)));
}

.class-description strong span {
  color: #ffffff;
  white-space: nowrap;
}

.class-description span {
  color: #cfcfcf;
  font-size: calc(0.82 * var(--rls-u, var(--rls-u, 1rem)));
  line-height: 1.25;
}

.detail {
  display: grid;
  gap: calc(0.25 * var(--rls-u, 1rem));
  min-height: calc(5.125 * var(--rls-u, 1rem));
}

.kit-detail {
  align-items: center;
}

.kit-controls {
  display: grid;
  grid-template-columns: minmax(calc(4.75 * var(--rls-u, 1rem)), 1fr) auto minmax(calc(4.75 * var(--rls-u, 1rem)), 1fr);
  align-items: center;
  gap: calc(0.875 * var(--rls-u, 1rem));
}

.kit-controls strong {
  min-width: calc(2.625 * var(--rls-u, 1rem));
  text-align: center;
  font-size: calc(1.75 * var(--rls-u, var(--rls-u, 1rem)));
  line-height: 1;
}

.totals {
  margin-top: calc(0.625 * var(--rls-u, 1rem));
}

.signup-button {
  width: 100%;
  margin-top: calc(0.875 * var(--rls-u, 1rem));
}

.result {
  margin-top: calc(0.875 * var(--rls-u, 1rem));
}

.result-grid {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: calc(0.5 * var(--rls-u, 1rem)) calc(1.125 * var(--rls-u, 1rem));
  margin-top: calc(0.5 * var(--rls-u, 1rem));
}

.accolades {
  display: grid;
  gap: calc(0.625 * var(--rls-u, 1rem));
}

.progress {
  height: calc(0.5 * var(--rls-u, 1rem));
  background: rgba(255, 255, 255, 0.15);
  border-radius: calc(0.25 * var(--rls-u, 1rem));
  overflow: hidden;
  margin: calc(0.5 * var(--rls-u, 1rem)) 0 calc(0.25 * var(--rls-u, 1rem));
}

.progress span {
  display: block;
  height: 100%;
  background: #f5a623;
}

@media (max-width: 720px) {
  .details-grid,
  .class-breakdown {
    grid-template-columns: 1fr;
  }

  .topbar,
  .accolade {
    align-items: stretch;
    flex-direction: column;
  }
}

/* Game currency glyph before amounts; inherits colour/size. */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
