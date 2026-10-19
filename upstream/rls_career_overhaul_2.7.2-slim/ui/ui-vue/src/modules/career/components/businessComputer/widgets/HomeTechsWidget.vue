<template>
  <!-- Technicians: name + a short status pill (busy label in accent-soft, Idle neutral), progress via scaleX. -->
  <div class="rls-house home-widget techs-widget">
    <div class="widget-header">
      <h3>{{ staffTitle }}</h3>
      <span class="staff-count" v-if="store.techs && store.techs.length">
        {{ store.techs.length }} {{ staffCountLabel }}
      </span>
    </div>

    <div class="widget-content">
      <div v-if="!store.techs || store.techs.length === 0" class="empty-state">
        <svg class="empty-glyph-plain" viewBox="0 0 24 24" aria-hidden="true">
          <path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"></path>
          <circle cx="9" cy="7" r="4"></circle>
          <path d="M23 21v-2a4 4 0 0 0-3-3.87"></path>
          <path d="M16 3.13a4 4 0 0 1 0 7.75"></path>
        </svg>
        <p>{{ emptyStaffMessage }}</p>
        <HouseButton compact @click="goToStaffTab">{{ hireStaffButton }}</HouseButton>
      </div>
      <div v-else class="techs-list">
        <div
          v-for="tech in store.techs"
          :key="tech.id"
          class="tech-item"
          :class="{ 'working': isTechBusy(tech) }"
        >
          <div class="tech-line">
            <span class="tech-name" :title="tech.name">{{ tech.name }}</span>
            <span v-if="isTechBusy(tech)" class="pill accent status-pill">{{ getTechStatusText(tech) }}</span>
            <span v-else class="pill status-pill">Idle</span>
          </div>
          <div class="progress-bar-mini" v-if="tech.jobId">
            <span class="fill" :style="{ transform: `scaleX(${techProgress(tech)})` }"></span>
          </div>
        </div>
      </div>

      <div class="manager-status" v-if="hasManager">
        <span class="label">Manager status</span>
        <span class="value" :class="{ ready: managerReadyToAssign }">{{ managerStatusText }}</span>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed, ref, onMounted, onUnmounted, watch } from "vue"
import { useBusinessComputerStore } from "../../../stores/businessComputerStore"
import { lua } from "@/bridge"
import { HouseButton } from "../../house"

const store = useBusinessComputerStore()

const isRacingTeam = computed(() => store.businessType === "racingTeam")
const staffTitle = computed(() => (isRacingTeam.value ? "Drivers" : "Technicians"))
const staffCountLabel = computed(() => (isRacingTeam.value ? "drivers" : "Staff"))
const emptyStaffMessage = computed(() =>
  isRacingTeam.value ? "No drivers hired" : "No technicians hired"
)
const hireStaffButton = computed(() => (isRacingTeam.value ? "Hire Drivers" : "Hire Techs"))

const goToStaffTab = () => {
  store.switchView(isRacingTeam.value ? "drivers" : "techs")
}

const hasManager = computed(() => store.hasManager)
const managerReadyToAssign = computed(() => store.managerReadyToAssign)
const managerTimeRemainingFromStore = computed(() => store.managerTimeRemaining)
const localManagerTimeRemaining = ref(null)

const managerStatusText = computed(() => {
  if (managerReadyToAssign.value) {
    return "Ready"
  }
  const timeRemaining = localManagerTimeRemaining.value
  if (timeRemaining !== null && timeRemaining !== undefined && timeRemaining > 0) {
    const minutes = Math.floor(timeRemaining / 60)
    const seconds = Math.floor(timeRemaining % 60)
    if (minutes > 0) {
      return `${minutes}m ${seconds}s`
    }
    return `${seconds}s`
  }
  return "Waiting"
})

const isTechBusy = (tech) => {
  if (!tech) return false
  if (tech.jobId) return true
  if (isRacingTeam.value && tech.pendingRaceOffer) return true
  return false
}

// 0..1 for the progress fill (transform: scaleX)
const techProgress = (tech) => Math.min(1, Math.max(0, Number(tech?.progress) || 0))

const getTechStatusText = (tech) => {
  if (isRacingTeam.value && tech.pendingRaceOffer) {
    return tech.label || "Race scheduled"
  }
  if (!tech.jobId) return "Idle"
  
  const phaseMap = {
    baseline: "Baseline Run",
    validation: "Validation Run",
    postUpdate: "Verification",
    completed: "Completed",
    failed: "Failed",
    idle: "Idle",
    build: "Building",
    update: "Tuning",
    cooldown: "Cooling Down"
  }
  
  return tech.label || phaseMap[tech.phase] || tech.action || "Working"
}

let animationFrameId = null
let lastTime = performance.now()

const updateProgress = () => {
  const now = performance.now()
  const dt = (now - lastTime) / 1000
  lastTime = now
  
  if (localManagerTimeRemaining.value !== null && localManagerTimeRemaining.value !== undefined && localManagerTimeRemaining.value > 0) {
    localManagerTimeRemaining.value = Math.max(0, localManagerTimeRemaining.value - dt)
  }
  
  animationFrameId = requestAnimationFrame(updateProgress)
}

watch(managerTimeRemainingFromStore, (newValue) => {
  if (newValue !== null && newValue !== undefined) {
    localManagerTimeRemaining.value = newValue
  }
}, { immediate: true })

watch(managerReadyToAssign, (isReady) => {
  if (isReady) {
    localManagerTimeRemaining.value = 0
  }
})

onMounted(() => {
    lastTime = performance.now()
    updateProgress()
})

onUnmounted(() => {
    if (animationFrameId) cancelAnimationFrame(animationFrameId)
})

</script>

<style scoped lang="scss">
@import "../../../styles/rlsHouse.scss";

.home-widget {
  display: flex;
  flex-direction: column;
  height: 100%;
  overflow: hidden;
  border-radius: var(--radius-panel);
  background: var(--panel);
}

.widget-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--space-2);
  padding: 0.8em var(--inset) 0.55em;
  flex-shrink: 0;

  h3 {
    margin: 0;
    font-size: 0.78em;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: var(--faint);
  }
}

.staff-count {
  color: var(--faint);
  font-size: 0.82em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}

.widget-content {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  padding: 0.15em var(--inset) var(--inset);
}

.empty-state {
  flex: 1;
  display: grid;
  justify-items: center;
  align-content: center;
  gap: 0.7em;
  padding: 1em 0;
  text-align: center;
  color: var(--muted);

  p {
    margin: 0;
    font-size: 0.95em;
    font-weight: 600;
  }
}

.empty-glyph-plain {
  width: 2em;
  height: 2em;
  fill: none;
  stroke: var(--faint);
  stroke-width: 1.6;
  stroke-linecap: round;
  stroke-linejoin: round;
}

.techs-list {
  display: flex;
  flex-direction: column;
  gap: 0.35em;
}

.tech-item {
  display: grid;
  gap: 0.45em;
  padding: 0.62em 0.75em 0.55em;
  border-radius: var(--radius-panel);
  background: var(--panel);
}

/* name left (two lines max), status pill right; the pill never drops under a long name */
.tech-line {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.35em 0.75em;
  min-width: 0;
}

.tech-name {
  flex: 1 1 auto;
  min-width: 0;
  font-weight: 700;
  color: #fff;
  line-height: 1.2;
  overflow-wrap: anywhere;
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
  line-clamp: 2;
  overflow: hidden;
}

.status-pill {
  flex: 0 0 auto;
  max-width: 55%;
  white-space: normal;
  text-align: right;
  line-height: 1.15;
}

.progress-bar-mini {
  height: 0.3em;
  border-radius: 1em;
  overflow: hidden;
  background: rgba(255, 255, 255, 0.12);

  .fill {
    display: block;
    width: 100%;
    height: 100%;
    background: var(--accent);
    transform-origin: left center;
    transition: transform 0.3s ease;
  }
}

.manager-status {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 0.75em;
  margin-top: 0.75em;
  padding-top: 0.65em;
  border-top: 1px solid var(--line);
  font-size: 0.88em;

  .label {
    color: var(--faint);
    font-weight: 600;
  }

  .value {
    color: #fff;
    font-weight: 700;
    font-variant-numeric: tabular-nums;

    &.ready { color: var(--ok); }
  }
}
</style>
