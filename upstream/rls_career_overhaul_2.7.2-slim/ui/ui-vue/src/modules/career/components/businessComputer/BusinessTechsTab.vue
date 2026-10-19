<template>
  <div class="rls-house techs-tab">
    <header class="tab-header">
      <h2 class="block-title">Techs</h2>
      <p class="hint">Monitor worker automation and assign jobs without leaving the desk.</p>
    </header>

    <div v-if="techCapabilityTier || hasManager" class="panel crew-strip">
      <div class="facts crew-facts">
        <div v-if="techCapabilityTier" class="fact">
          <span class="fact-key">Capability</span>
          <span class="fact-value">Tier {{ techCapabilityTier }}</span>
        </div>
        <div v-if="hasManager" class="fact">
          <span class="fact-key">{{ hasGeneralManager ? "General manager" : "Manager" }}</span>
          <span class="fact-value">{{ managerAssignmentFrequency || "Assigning" }}</span>
        </div>
        <div v-if="hasManager" class="fact" :class="{ ok: managerReadyToAssign && !managerPaused }">
          <span class="fact-key">Next assignment</span>
          <span class="fact-value">{{ managerPaused ? "Paused" : managerStatusText }}</span>
        </div>
      </div>
      <HouseButton
        v-if="hasManager"
        class="manager-pause-btn"
        variant="quiet"
        compact
        :disabled="isTogglingPause"
        :title="managerPaused ? 'Resume Manager' : 'Pause Manager'"
        @click.stop="handleToggleManagerPause"
        @mousedown.stop
      >
        <svg v-if="managerPaused" class="glyph" viewBox="0 0 24 24" aria-hidden="true">
          <polygon points="6 4 19 12 6 20 6 4"></polygon>
        </svg>
        <svg v-else class="glyph" viewBox="0 0 24 24" aria-hidden="true">
          <rect x="6" y="4" width="4" height="16"></rect>
          <rect x="14" y="4" width="4" height="16"></rect>
        </svg>
        {{ managerPaused ? "Resume" : "Pause" }}
      </HouseButton>
    </div>

    <p v-if="managerCantAssignMessage" class="notice bad">{{ managerCantAssignMessage }}</p>

    <div v-if="techList.length" class="techs-grid">
      <article
        v-for="tech in techList"
        :key="`tech-${tech.id}`"
        class="tech-card"
        :class="{
          'tech-card--working': tech.jobId && !tech.fired,
          'tech-card--idle': !tech.jobId && !tech.fired,
          'tech-card--fired': tech.fired
        }"
        @click.stop
        @mousedown.stop
      >
        <header class="tech-head">
          <div class="tech-name">
            <input
              v-if="editingTechId === tech.id && !tech.fired"
              v-model="editedName"
              class="field tech-name-input"
              maxlength="32"
              @keyup.enter="commitRename(tech)"
              @keydown.esc.prevent="cancelRename(tech)"
              @blur="onRenameBlur(); commitRename(tech)"
              @focus="onRenameFocus"
              @keydown.stop @keyup.stop @keypress.stop
              v-bng-text-input
              v-bng-on-ui-nav:back.focusRequired="() => cancelRename(tech)"
              v-focus
            />
            <h3 v-else :title="tech.name">{{ tech.name }}</h3>
            <button
              v-if="!tech.fired"
              type="button"
              class="rename-btn"
              :data-rename-tech="tech.id"
              :title="editingTechId === tech.id ? 'Save name' : 'Rename'"
              @click.stop="toggleRename(tech)"
              @mousedown.stop="onRenameBtnMouseDown(tech, $event)"
            >
              <svg viewBox="0 0 24 24" aria-hidden="true">
                <path d="M12 20h9"></path>
                <path d="M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4 12.5-12.5z"></path>
              </svg>
            </button>
          </div>
          <span v-if="tech.fired" class="pill">Fired</span>
          <span v-else-if="tech.jobId" class="pill" :class="statusPillClass(tech)">{{ formatPhase(tech) }}</span>
          <span v-else-if="tech.pendingRaceOffer" class="pill accent">Race booked</span>
          <span v-else class="pill">Idle</span>
        </header>

        <div v-if="tech.jobId && !tech.fired" class="tech-progress" aria-hidden="true">
          <span :style="{ transform: `scaleX(${progressFraction(tech)})` }"></span>
        </div>

        <div v-if="!tech.fired" class="facts tech-facts">
          <div v-if="tech.pendingRaceOffer || tech.jobId" class="fact wide">
            <span class="fact-key">Current assignment</span>
            <span class="fact-value">
              <template v-if="tech.pendingRaceOffer">
                {{ tech.pendingRaceOffer.raceLabel || tech.pendingRaceOffer.raceName || "Scheduled race" }}
              </template>
              <template v-else>
                {{ getJobLabel(tech.jobId) || "Unknown Job" }}
              </template>
            </span>
          </div>
          <div v-if="tech.successRate !== undefined" class="fact" :class="{ bad: isLowEfficiency(tech) }">
            <span class="fact-key">Efficiency</span>
            <span class="fact-value">{{ tech.successRate }}%</span>
          </div>
          <div v-if="tech.jobId && tech.phase !== 'baseline' && !(tech.validationAttempts === 0 && tech.maxValidationAttempts === 0)" class="fact">
            <span class="fact-key">Attempts</span>
            <span class="fact-value">{{ tech.validationAttempts }}<small> / {{ tech.maxValidationAttempts }}</small></span>
          </div>
          <div v-if="tech.jobReward !== undefined && tech.jobReward > 0" class="fact money">
            <span class="fact-key">Payment</span>
            <span class="fact-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoneyCompact(tech.jobReward) }}</span>
          </div>
          <div v-if="getBuildCost(tech) > 0" class="fact money">
            <span class="fact-key">Build cost</span>
            <span class="fact-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoneyCompact(getBuildCost(tech)) }}</span>
          </div>
          <div v-if="tech.latestResult" class="fact" :class="tech.latestResult.success ? 'ok' : 'bad'">
            <span class="fact-key">Last result</span>
            <span class="fact-value">{{ tech.latestResult.success ? "Success" : "Failed" }}</span>
          </div>
        </div>
        <p v-else class="hint">No longer on the payroll.</p>

        <div class="tech-actions">
          <HouseButton
            v-if="tech.fired"
            variant="primary"
            block
            class="btn-hire"
            @click.stop="handleHireTech(tech)"
            @mousedown.stop
          >
            Hire Tech
          </HouseButton>
          <HouseButton
            v-else-if="tech.jobId"
            block
            class="btn-stop"
            @click.stop="handleStopTech(tech)"
            @mousedown.stop
          >
            Stop Job
          </HouseButton>
          <template v-else>
            <HouseButton
              :variant="availableJobs.length === 0 ? 'neutral' : 'primary'"
              class="btn-assign"
              :disabled="availableJobs.length === 0"
              @click.stop="openJobModal(tech, $event)"
              @mousedown.stop
            >
              {{ availableJobs.length === 0 ? "No Jobs Available" : "Assign New Job" }}
            </HouseButton>
            <HouseButton
              variant="quiet-danger"
              class="btn-fire"
              @click.stop="handleFireTech(tech)"
              @mousedown.stop
            >
              Fire Tech
            </HouseButton>
          </template>
        </div>
      </article>
    </div>

    <div v-if="techList.length === 0" class="empty techs-empty">
      <BngIcon class="empty-icon" :type="icons.wrench" />
      <h3>No Technicians Hired</h3>
      <p>Purchase shop upgrades to hire technicians and automate your workflow.</p>
    </div>

    <Teleport to="body">
      <transition name="modal-fade">
        <div
          v-if="openModalTechId !== null"
          class="rls-house job-select-modal-overlay"
          @click.stop="closeJobModal"
          @mousedown.stop="closeJobModal"
        >
          <div
            class="modal job-select-modal"
            v-bng-scoped-nav="jobModalScope" v-bc-modal-focus
            v-bng-on-ui-nav:back,menu="closeJobModal"
            @click.stop
            @mousedown.stop
          >
            <div class="job-select-modal__header">
              <h3>Assign Job to Tech</h3>
              <HouseButton
                class="job-select-modal__close"
                variant="quiet"
                compact
                :icon="icons.xmark"
                title="Close"
                @click.stop="closeJobModal"
                @mousedown.stop
              />
            </div>
            <div class="job-select-modal__content scroll" v-bng-ui-nav-scroll>
              <div v-if="availableJobs.length === 0" class="empty">
                <h3>No available active jobs.</h3>
                <p>Accept jobs from the Jobs tab first.</p>
              </div>
              <div v-else class="job-select-modal__grid">
                <JobAssignCard
                  v-for="(job, i) in availableJobs"
                  :key="`modal-job-${job.jobId}`"
                  :job="job"
                  :nav-autofocus="i === 0"
                  @assign="selectJob(techList.find(t => t.id === openModalTechId), $event.jobId)"
                />
              </div>
            </div>
          </div>
        </div>
      </transition>
    </Teleport>
  </div>
</template>

<script setup>
import { computed, reactive, ref, Teleport, nextTick, onMounted, onBeforeUnmount, onUnmounted, watch } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import { useBridge, lua } from "@/bridge"
import { vBngTextInput, vBngScopedNav, vBngOnUiNav, vBngUiNavScroll } from "@/common/directives"
import { setFocus } from "@/services/uiNavFocus"
import { bcModalScope, vBcModalFocus } from "./bcModalNav"
import { formatMoneyCompact, formatTime, formatPhase } from "../../utils/businessUtils"
import JobAssignCard from "./JobAssignCard.vue"
import { HouseButton } from "../house"
import { BngIcon, icons } from "@/common/components/base"

const store = useBusinessComputerStore()
const { events } = useBridge()
const jobModalScope = bcModalScope("tech-assign")

const activeJobs = computed(() => {
  const jobs = store.activeJobs
  return Array.isArray(jobs) ? jobs : []
})
const availableJobs = computed(() => {
  const jobs = activeJobs.value
  return Array.isArray(jobs) ? jobs.filter(job => !job.techAssigned) : []
})

const techList = computed(() => store.techs || [])
const techCapabilityTier = computed(() => {
  const firstWithTier = techList.value.find(t => typeof t.maxTier === "number" && !t.fired)
  return firstWithTier ? firstWithTier.maxTier : null
})

const maxActiveJobs = computed(() => store.maxActiveJobs ?? 2)
const activeJobsCount = computed(() => store.activeJobs?.length ?? 0)
const idleTechsCount = computed(() => techList.value.filter(t => !t.jobId && !t.fired).length)
const newJobsCount = computed(() => store.newJobs?.length ?? 0)

const hasManager = computed(() => store.hasManager)
const hasGeneralManager = computed(() => store.hasGeneralManager)
const managerAssignmentInterval = computed(() => store.managerAssignmentInterval)
const managerReadyToAssign = computed(() => store.managerReadyToAssign)
const managerTimeRemainingFromStore = computed(() => store.managerTimeRemaining)
const managerPaused = computed(() => store.managerPaused)
const localManagerTimeRemaining = ref(null)

const managerAssignmentFrequency = computed(() => {
  if (hasGeneralManager.value) {
    return "Instant"
  }
  if (!managerAssignmentInterval.value) {
    return ""
  }
  const minutes = Math.floor(managerAssignmentInterval.value / 60)
  if (minutes === 1) {
    return "Every 1 minute"
  }
  return `Every ${minutes} minutes`
})

const managerStatusText = computed(() => {
  if (managerReadyToAssign.value) {
    return "Ready to assign"
  }
  const timeRemaining = localManagerTimeRemaining.value
  if (timeRemaining !== null && timeRemaining !== undefined && timeRemaining > 0) {
    const minutes = Math.floor(timeRemaining / 60)
    const seconds = Math.floor(timeRemaining % 60)
    if (minutes > 0) {
      return `Next in ${minutes}m ${seconds}s`
    }
    return `Next in ${seconds}s`
  }
  return "Not ready"
})

const managerCantAssignMessage = computed(() => {
  if (!hasManager.value || managerPaused.value) return null
  if (!managerReadyToAssign.value && !hasGeneralManager.value) return null
  if (idleTechsCount.value === 0) return null
  if (newJobsCount.value === 0) return null
  if (activeJobsCount.value < maxActiveJobs.value) return null
  return "Manager can't assign: no free active job slots"
})

const editingTechId = ref(null)
const editedName = ref("")
const openModalTechId = ref(null)

const vFocus = {
  mounted: (el) => el.focus()
}

const jobLookup = computed(() => {
  const map = new Map()
  const jobs = activeJobs.value
  if (Array.isArray(jobs)) {
    jobs.forEach(job => {
      const id = job?.jobId ?? job?.id
      if (id !== undefined && id !== null) {
        map.set(String(id), job)
      }
    })
  }
  return map
})

const getJobLabel = (jobId) => {
  if (jobId === null || jobId === undefined) return ""
  const job = jobLookup.value.get(String(jobId))
  return job?.goal || `Job #${jobId}`
}

// display helpers: busy pill tone, transform-based progress fill, low-efficiency flag
const statusPillClass = (tech) => {
  if (tech.phase === 'failed') return 'bad'
  if (tech.phase === 'completed') return 'ok'
  return 'accent'
}

const progressFraction = (tech) => Math.min(1, Math.max(0, Number(tech.progress) || 0))

const LOW_EFFICIENCY = 50
const isLowEfficiency = (tech) => typeof tech.successRate === 'number' && tech.successRate < LOW_EFFICIENCY

const getPhaseClass = (tech) => {
    if (!tech.jobId) return 'badge-idle'
    if (tech.phase === 'failed') return 'badge-failed'
    if (tech.phase === 'completed') return 'badge-success'
    return 'badge-working'
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

const openJobModal = async (tech, event) => {
  if (openModalTechId.value === tech.id) {
    closeJobModal()
    return
  }
  
  openModalTechId.value = tech.id
}

const closeJobModal = () => {
  openModalTechId.value = null
}

const selectJob = async (tech, jobId) => {
  const success = await store.assignTechToJob(tech.id, jobId)
  if (success) {
    closeJobModal()
  }
}

const handleClickOutside = (event) => {
  if (openModalTechId.value && !event.target.closest('.job-select-modal') && !event.target.closest('.btn-assign')) {
    closeJobModal()
  }
}

const handleTechsUpdated = (data) => {
  const currentBusinessId = store.businessId
  if (!currentBusinessId) return

  const eventBusinessId = data?.businessId
  if (eventBusinessId && String(eventBusinessId) !== String(currentBusinessId)) {
    return
  }

  if (data?.techs && Array.isArray(data.techs)) {
    store.updateTechs(data.techs)
  }
}

  const refreshManagerTime = async () => {
    if (!store.businessId) return
    try {
      let data
      if (store.businessType === 'tuningShop') {
        data = await lua.career_modules_business_tuningShop.getManagerData(store.businessId)
      } else {
        data = await lua.career_modules_business_businessComputer.getManagerData(store.businessId)
      }
      
      if (data) {
        if (data.managerTimeRemaining !== undefined) {
          localManagerTimeRemaining.value = data.managerTimeRemaining
        }
        managerReadyToAssign.value = data.managerReadyToAssign
      }
    } catch (e) {}
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
  document.addEventListener('click', handleClickOutside)
  events.on('businessComputer:onTechsUpdated', handleTechsUpdated)
  
  if (managerTimeRemainingFromStore.value !== null && managerTimeRemainingFromStore.value !== undefined) {
    localManagerTimeRemaining.value = managerTimeRemainingFromStore.value
  }
  
  refreshManagerTime()
  
  // Request fresh tech data to sync progress
  const fetchTechs = async () => {
    try {
      let data
      if (store.businessType === 'tuningShop') {
        data = await lua.career_modules_business_tuningShop.getTechData(store.businessId)
      } else {
        data = await lua.career_modules_business_businessComputer.getTechsOnly(store.businessId)
      }
      if (data && data.techs) {
        handleTechsUpdated(data)
      }
    } catch (e) {}
  }
  fetchTechs()

  lastTime = performance.now()
  updateProgress()
})

// leaving the tab (or the computer) mid-rename removes the field without a blur
onBeforeUnmount(() => {
  if (editingTechId.value !== null) onRenameBlur()
})

onUnmounted(() => {
  document.removeEventListener('click', handleClickOutside)
  events.off('businessComputer:onTechsUpdated', handleTechsUpdated)
  if (animationFrameId) cancelAnimationFrame(animationFrameId)
})

const toggleRename = (tech) => {
  if (editingTechId.value === tech.id) {
    commitRename(tech)
  } else {
    editingTechId.value = tech.id
    editedName.value = tech.name
  }
}

// every path that removes the name field turns CEF typing off first: a focused input that is
// removed by v-if fires no blur, so keys would stay with the UI instead of the game
const commitRename = async (tech) => {
  if (editingTechId.value !== tech.id) return
  onRenameBlur()
  editingTechId.value = null
  const trimmed = (editedName.value || "").trim()
  if (!trimmed || trimmed === tech.name) {
    return
  }
  await store.renameTech(tech.id, trimmed)
}

// B / Escape in the name field: drop the edit and put focus back on the rename button
const cancelRename = (tech) => {
  if (editingTechId.value !== tech.id) return false
  onRenameBlur()
  editingTechId.value = null
  nextTick(() => setFocus(document.querySelector(`.rename-btn[data-rename-tech="${tech.id}"]`)))
  return false
}

// clicking the pencil (Save name) while editing must not pull focus off the field first: that blur
// would commit and the click would then reopen the editor
const onRenameBtnMouseDown = (tech, event) => {
  if (editingTechId.value === tech.id) event.preventDefault()
}

const onRenameFocus = () => {
  try { lua.setCEFTyping(true) } catch (_) {}
}

const onRenameBlur = () => {
  try { lua.setCEFTyping(false) } catch (_) {}
}

const getBuildCost = (tech) => {
  const totalSpent = tech.totalSpent || 0
  const eventFunds = tech.eventFunds || 0
  return Math.max(0, totalSpent - eventFunds)
}

const handleFireTech = async (tech) => {
  if (!tech || tech.fired) return
  const success = await store.fireTech(tech.id)
  if (success) {
    closeJobModal()
  }
}

const handleHireTech = async (tech) => {
  if (!tech || !tech.fired) return
  const success = await store.hireTech(tech.id)
  if (success) {
    closeJobModal()
  }
}

const handleStopTech = async (tech) => {
  if (!tech || !tech.jobId || tech.fired) return
  const success = await store.stopTechFromJob(tech.id)
  if (success) {
    closeJobModal()
  }
}

const isTogglingPause = ref(false)
const handleToggleManagerPause = async () => {
  if (!hasManager.value) return
  if (isTogglingPause.value) return
  
  isTogglingPause.value = true
  try {
    await store.setManagerPaused(!managerPaused.value)
  } catch (error) {
    console.error('Error toggling manager pause:', error)
  } finally {
    isTogglingPause.value = false
  }
}
</script>

<style scoped lang="scss">
@import "../../styles/rlsHouse.scss";

/* Techs, house style: manager strip as .facts, near-black tech cards with the name biggest, the
   busy state as a short accent pill, one orange action (Assign) on an idle card only. */

.techs-tab {
  display: flex;
  flex-direction: column;
  gap: var(--space-4);
  padding-bottom: 1.5em;
  font-variant-numeric: tabular-nums;
}

.tab-header {
  display: grid;
  gap: 0.25em;
}

/* manager / capability strip */
.crew-strip {
  display: flex;
  align-items: center;
  gap: var(--space-4);
}
.crew-facts {
  flex: 1 1 auto;
  grid-template-columns: repeat(auto-fit, minmax(9em, 1fr));
}
.manager-pause-btn .glyph {
  width: 0.95em;
  height: 0.95em;
  fill: currentColor;
  stroke: none;
  transform: translateY(-0.05em);
}
.manager-pause-btn :deep(.btn-label) {
  display: inline-flex;
  align-items: center;
  gap: 0.45em;
}

/* facts here wrap instead of cutting the text off */
.fact-value {
  white-space: normal;
  overflow: visible;
  text-overflow: clip;
  overflow-wrap: anywhere;
  small {
    color: var(--faint);
    font-size: 0.8em;
    font-weight: 600;
  }
}

/* tech cards */
.techs-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(19em, 1fr));
  gap: var(--space-3);
}

.tech-card {
  display: flex;
  flex-direction: column;
  gap: var(--space-3);
  padding: var(--inset);
  border-radius: var(--radius-panel);
  background: var(--panel);

  &--fired {
    opacity: 0.6;
  }
}

.tech-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: var(--space-3);

  > .pill {
    flex: 0 0 auto;
    margin-top: 0.2em;
  }
}

.tech-name {
  display: flex;
  align-items: center;
  gap: 0.35em;
  flex: 1 1 auto;
  min-width: 0;

  h3 {
    margin: 0;
    min-width: 0;
    font-size: 1.3em;
    font-weight: 800;
    line-height: 1.2;
    overflow-wrap: anywhere;
    /* long names: two lines, then ellipsis */
    display: -webkit-box;
    -webkit-box-orient: vertical;
    -webkit-line-clamp: 2;
    line-clamp: 2;
    overflow: hidden;
  }
}

.tech-name-input {
  max-width: 14em;
  padding-top: 0.5em;
  padding-bottom: 0.35em;
  font-size: 1.05em;
  font-weight: 700;
}

.rename-btn {
  appearance: none;
  flex: 0 0 auto;
  display: grid;
  place-items: center;
  width: 1.9em;
  height: 1.9em;
  margin: 0;
  padding: 0;
  border: 0;
  border-radius: var(--radius-thumb);
  background: transparent;
  color: var(--faint);
  cursor: pointer;
  transition: background-color 0.12s, color 0.12s;

  svg {
    width: 1em;
    height: 1em;
    fill: none;
    stroke: currentColor;
    stroke-width: 2;
    stroke-linecap: round;
    stroke-linejoin: round;
  }
  &:hover {
    background: var(--panel);
    color: #fff;
  }
  @include house-focus;
}

/* job progress: transform-only fill */
.tech-progress {
  height: 0.4em;
  border-radius: 1em;
  overflow: hidden;
  background: rgba(255, 255, 255, 0.12);

  > span {
    display: block;
    width: 100%;
    height: 100%;
    border-radius: inherit;
    background: var(--accent);
    transform-origin: left center;
    transition: transform 0.1s linear;
  }
}

.tech-facts {
  grid-template-columns: repeat(3, minmax(0, 1fr));

  .fact.wide {
    grid-column: 1 / -1;
  }
}

.tech-actions {
  display: flex;
  gap: var(--space-2);
  margin-top: auto;

  .btn-assign {
    flex: 1 1 auto;
  }
}

/* empty state */
.techs-empty {
  border-radius: var(--radius-panel);
  background: var(--panel);
  padding: 2.5em 1.5em;
}
.empty-icon {
  font-size: 2em;
  color: var(--faint);
}

/* job picker (teleported to body: carries .rls-house + the shell's em scale itself) */
.job-select-modal-overlay {
  position: fixed;
  inset: 0;
  z-index: 10000;
  display: grid;
  place-items: center;
  padding: 1em;
  background: rgba(0, 0, 0, 0.6);
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
}

.job-select-modal {
  width: min(32em, 92vw);
  max-height: 80vh;
  display: flex;
  flex-direction: column;
  gap: var(--space-3);
}

.job-select-modal__header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--space-3);

  h3 {
    margin: 0;
    font-size: 1.15em;
    font-weight: 800;
  }
}

.job-select-modal__content {
  flex: 1 1 auto;
  min-height: 0;
  padding-right: 0.25em;
}

.job-select-modal__grid {
  display: grid;
  gap: var(--space-3);
}

.modal-fade-enter-active,
.modal-fade-leave-active {
  transition: opacity 0.18s ease;

  .job-select-modal {
    transition: transform 0.18s ease, opacity 0.18s ease;
  }
}

.modal-fade-enter-from,
.modal-fade-leave-to {
  opacity: 0;

  .job-select-modal {
    transform: scale(0.96);
    opacity: 0;
  }
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
