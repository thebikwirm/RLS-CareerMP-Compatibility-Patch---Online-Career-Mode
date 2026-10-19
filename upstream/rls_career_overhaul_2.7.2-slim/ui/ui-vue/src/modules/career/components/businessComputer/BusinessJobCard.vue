<template>
  <article class="rls-house job-card" :class="[layout === 'full' ? 'is-full' : 'is-compact', { active: isActive }]">
    <!-- the car first: big photo on full cards, a wide thumbnail on the compact (widget) card -->
    <div class="job-photo">
      <img :src="job.vehicleImage" :alt="job.vehicleName" />
      <span v-if="vehicleCooldownSec > 0" class="photo-pill cooldown">
        <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10" /><polyline points="12 6 12 12 16 14" /></svg>
        <span>{{ layout === 'full' ? 'Cooling down ' : '' }}{{ formatCooldownMSS(vehicleCooldownSec) }}</span>
      </span>
      <span v-if="layout === 'full' && expirationText" class="photo-pill expires" :class="{ expired: isExpired }">
        <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10" /><polyline points="12 6 12 12 16 14" /></svg>
        <span>{{ expirationText }}</span>
      </span>
    </div>

    <div class="job-body">
      <div class="job-head">
        <strong class="job-name" :title="`${job.vehicleYear || ''} ${job.vehicleName || ''}`.trim()">{{ job.vehicleYear }} {{ job.vehicleName }}</strong>
        <strong class="job-pay">{{ moneySign(job.reward) }}<BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoneyCompact(job.reward) }}</strong>
      </div>

      <div class="job-goal">
        <span class="caption">Goal</span>
        <span class="goal-value">{{ job.goal }}</span>
      </div>

      <!-- compact cards have no photo pill, so expiry sits under the goal -->
      <div v-if="layout !== 'full' && !isActive && expirationText" class="job-goal">
        <span class="caption">Expires</span>
        <span class="goal-value" :class="{ bad: isExpired }">{{ expirationText.replace('Expires in ', '') }}</span>
      </div>

      <!-- active job: tech progress, or the run time against the goal -->
      <template v-if="isActive">
        <div v-if="hasTechAssigned" class="job-progress">
          <div class="progress-head">
            <span class="caption">{{ techStatus }}</span>
            <span class="hint">{{ techName || 'Tech' }}</span>
          </div>
          <div class="slim-bar"><span :style="{ transform: `scaleX(${techProgress / 100})` }"></span></div>
        </div>
        <div v-else class="job-progress">
          <div class="progress-head">
            <span class="caption">Current</span>
            <span class="progress-value">{{ formatTime(job.currentTime ?? job.baselineTime, job.decimalPlaces) }}</span>
          </div>
          <div class="slim-bar"><span :style="{ transform: `scaleX(${progressPercent / 100})` }"></span></div>
          <p v-if="completionBlockedMessage" class="notice warn">{{ completionBlockedMessage }}</p>
        </div>
      </template>

      <div class="job-actions" :class="{ locked: damageLockApplies || kitInstallLocked }">
        <template v-if="isActive">
          <template v-if="kitInstallLocked">
            <div class="notice kit-install">
              <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10" /><path d="M12 6v6l4 2" /></svg>
              <span class="kit-copy">
                <span>Installing {{ kitInstallKitName }}</span>
                <span class="hint">{{ formatTime(kitInstallSecondsRemaining) }} remaining</span>
              </span>
            </div>
          </template>
          <template v-else-if="!hasTechAssigned">
            <template v-if="damageLockApplies">
              <p class="notice bad">Vehicle damaged</p>
              <HouseButton variant="quiet-danger" block @mousedown.stop @click.stop="$emit('abandon', job)">
                {{ abandonActionLabel }}
              </HouseButton>
            </template>
            <template v-else>
              <HouseButton v-if="showCompleteButton" variant="primary" class="grow"
                @click.stop="$emit('complete', job)">
                {{ store.businessType === 'racingTeam' ? 'Sell' : 'Complete' }}
              </HouseButton>
              <template v-else>
                <HouseButton v-if="showRacingTeamRepair" block @click.stop="runRepair">
                  Repair
                </HouseButton>
                <HouseButton variant="primary" class="grow"
                  :disabled="(!isPulledOut && hasPulledOutVehicle) || pullOutBlockedByCooldown"
                  :title="pullOutButtonTitle"
                  @click.stop="isPulledOut ? $emit('put-away') : $emit('pull-out', job)">
                  {{ isPulledOut ? 'Put Away' : 'Pull Out' }}
                </HouseButton>
                <HouseButton variant="quiet-danger" :title="abandonActionLabel"
                  @mousedown.stop @click.stop="$emit('abandon', job)">
                  {{ abandonActionLabel }}
                </HouseButton>
              </template>
            </template>
          </template>
        </template>
        <template v-else-if="assignMode">
          <HouseButton variant="primary" class="grow" @click.stop="$emit('assign', job)">
            Assign
          </HouseButton>
        </template>
        <template v-else>
          <HouseButton variant="primary" class="grow" :disabled="isAcceptDisabled" :title="acceptButtonTitle"
            @click.stop="$emit('accept', job)">
            {{ store.businessType === 'racingTeam' ? 'Purchase' : 'Accept' }}
          </HouseButton>
          <HouseButton variant="quiet" @click.stop="$emit('decline', job)">
            Decline
          </HouseButton>
        </template>
      </div>
    </div>
  </article>
</template>

<script setup>
import { computed, ref, onMounted, onUnmounted, watch } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import { lua } from "@/bridge"
import { formatMoneyCompact, moneySign, formatTime, formatPhase, normalizeId } from "../../utils/businessUtils"
import { BngIcon, icons } from "@/common/components/base"
import { HouseButton } from "../house"

const props = defineProps({
  job: Object,
  isActive: Boolean,
  businessId: String,
  assignMode: {
    type: Boolean,
    default: false
  },
  layout: {
    type: String,
    default: 'compact',
    validator: (value) => ['compact', 'full'].includes(value)
  }
})

const emit = defineEmits(['pull-out', 'put-away', 'abandon', 'accept', 'decline', 'complete', 'assign'])

const store = useBusinessComputerStore()

const abandonActionLabel = computed(() => (store.businessType === 'racingTeam' ? 'Sell' : 'Abandon'))

const jobIdentifier = computed(() => normalizeId(props.job?.jobId ?? props.job?.id))

const vehicleRowMatchesJob = (vehicle) => {
  if (!vehicle || !props.job) return false
  const sv = normalizeId(props.job.storedVehicleId)
  if (sv !== null && normalizeId(vehicle.vehicleId) === sv) return true
  const jid = normalizeId(props.job?.jobId ?? props.job?.id)
  return jid !== null && normalizeId(vehicle?.jobId) === jid
}
const techAssigned = computed(() => {
  if (!props.job?.techAssigned) return null
  return props.job.techAssigned
})
const assignedTech = computed(() => {
  if (!techAssigned.value) return null
  const techs = store.techs || []
  const tech = techs.find(t => String(t.id) === String(techAssigned.value)) || null
  if (!tech) return null
  const techJobId = normalizeId(tech.jobId)
  if (techJobId !== jobIdentifier.value) return null
  return tech
})
const techName = computed(() => {
  return assignedTech.value?.name || null
})
const hasTechAssigned = computed(() => !!assignedTech.value)
const techProgress = computed(() => {
  if (!assignedTech.value || !assignedTech.value.jobId) return 0
  const progress = assignedTech.value.progress
  return typeof progress === 'number' ? Math.min(100, Math.max(0, progress * 100)) : 0
})
const techStatus = computed(() => {
  if (!assignedTech.value) return null
  return formatPhase(assignedTech.value, false)
})
const pulledOutVehicleForJob = computed(() => {
  if (Array.isArray(store.pulledOutVehicles)) {
    const fromList = store.pulledOutVehicles.find(vehicle => vehicleRowMatchesJob(vehicle))
    if (fromList) {
      return fromList
    }
  }
  const pv = store.pulledOutVehicle
  if (pv && vehicleRowMatchesJob(pv)) {
    return pv
  }
  return null
})
const vehicleForJob = computed(() => {
  if (!Array.isArray(store.vehicles)) {
    return null
  }
  return store.vehicles.find(vehicle => vehicleRowMatchesJob(vehicle)) || null
})

/** Inventory vehicle id for racingTeamFleetCooldowns (Lua keys are tostring(vehicleId)). */
const fleetVehicleIdForCooldown = computed(() => {
  const row = vehicleForJob.value || pulledOutVehicleForJob.value
  const fromRow = row?.vehicleId
  if (fromRow !== undefined && fromRow !== null && fromRow !== "") {
    return fromRow
  }
  const stored = props.job?.storedVehicleId
  if (stored !== undefined && stored !== null && stored !== "") {
    return stored
  }
  const jv = props.job?.vehicleId
  if (jv !== undefined && jv !== null && jv !== "") {
    return jv
  }
  return null
})

const fleetCooldownSecondsFromServer = computed(() => {
  const map = store.businessData?.racingTeamFleetCooldowns
  const id = fleetVehicleIdForCooldown.value
  if (store.businessType !== "racingTeam" || !map || id === null || id === undefined || id === "") {
    return 0
  }
  const keys = new Set([String(id)])
  const norm = normalizeId(id)
  if (norm !== null) {
    keys.add(String(norm))
  }
  for (const k of keys) {
    const v = map[k]
    if (v !== undefined && v !== null && Number.isFinite(Number(v))) {
      return Number(v)
    }
  }
  return 0
})

const damageLockApplies = computed(() => {
  if (!pulledOutVehicleForJob.value) {
    return false
  }
  return !!pulledOutVehicleForJob.value.damageLocked
})
const kitInstallLocked = computed(() => {
  const vehicle = vehicleForJob.value || pulledOutVehicleForJob.value
  if (vehicle?.kitInstallLocked === true) return true
  return kitInstallSecondsRemaining.value > 0
})
const kitInstallSecondsRemaining = ref(0)
const kitInstallTimer = ref(null)
const kitInstallKitName = computed(() => {
  const vehicle = vehicleForJob.value || pulledOutVehicleForJob.value
  return vehicle?.kitInstallKitName || 'kit'
})
const syncKitInstallTime = () => {
  const vehicle = vehicleForJob.value || pulledOutVehicleForJob.value
  const serverTime = vehicle?.kitInstallTimeRemaining || 0
  kitInstallSecondsRemaining.value = Math.max(0, Math.floor(serverTime))
}
const startKitInstallCountdown = () => {
  stopKitInstallCountdown()
  syncKitInstallTime()
  if (kitInstallSecondsRemaining.value <= 0) return
  kitInstallTimer.value = setInterval(() => {
    if (kitInstallSecondsRemaining.value <= 0) {
      stopKitInstallCountdown()
      return
    }
    kitInstallSecondsRemaining.value = kitInstallSecondsRemaining.value - 1
  }, 1000)
}
const stopKitInstallCountdown = () => {
  if (kitInstallTimer.value) {
    clearInterval(kitInstallTimer.value)
    kitInstallTimer.value = null
  }
}
const canComplete = ref(false)
const completionStatusMessage = ref(null)
const completionStatusFetched = ref(false)
const remainingSeconds = ref(null)
const countdownTimer = ref(null)
const hasRequestedAfterExpiry = ref(false)

const canCompleteLocal = computed(() => {
  if (store.businessType === 'tuningShop') {
    return false
  }
  if (!props.isActive || props.job.currentTime === undefined || props.job.currentTime === null || props.job.goalTime === undefined || props.job.goalTime === null) {
    return false
  }

  // For track races and drag races, lower time is better (currentTime <= goalTime)
  // Both times should be in the same unit (seconds from leaderboard)
  if (props.job.raceType === "track" || props.job.raceType === "trackAlt" || props.job.raceType === "drag") {
    // Ensure we have valid numbers
    const currentTime = Number(props.job.currentTime)
    const goalTime = Number(props.job.goalTime)

    if (isNaN(currentTime) || isNaN(goalTime) || goalTime <= 0) {
      return false
    }

    return currentTime <= goalTime
  }

  return false
})

const completionBlockedMessage = computed(() => {
  if (store.businessType !== 'tuningShop' || !props.isActive) {
    return null
  }
  if (!props.job.goalTimeMet) {
    return null
  }
  if (completionStatusFetched.value) {
    return completionStatusMessage.value || null
  }
  if (completionStatusMessage.value) {
    return completionStatusMessage.value
  }
  return props.job.completionBlockedMessage || null
})

const showCompleteButton = computed(() => {
  if (completionBlockedMessage.value) {
    return false
  }
  if (store.businessType === 'tuningShop') {
    return canComplete.value === true
  }
  return canComplete.value || canCompleteLocal.value
})

const statusText = computed(() => {
  return props.isActive ? "In Progress" : "Available"
})

const statusClass = computed(() => {
  return props.isActive ? "status-active" : "status-available"
})

const progressPercent = computed(() => {
  if (!props.isActive || !props.job.baselineTime || !props.job.goalTime) return 0
  const progress = ((props.job.baselineTime - props.job.currentTime) /
    (props.job.baselineTime - props.job.goalTime)) * 100
  return Math.max(0, Math.min(100, progress))
})

const isPulledOut = computed(() => {
  return !!pulledOutVehicleForJob.value
})

const liftsFull = computed(() => {
  if (Array.isArray(store.pulledOutVehicles)) {
    return store.pulledOutVehicles.length >= store.maxPulledOutVehicles
  }
  return !!store.pulledOutVehicle
})

const hasPulledOutVehicle = computed(() => {
  return liftsFull.value && !isPulledOut.value
})

const showRacingTeamRepair = computed(() => {
  if (store.businessType !== "racingTeam" || !props.isActive || hasTechAssigned.value || kitInstallLocked.value) {
    return false
  }
  if (!isPulledOut.value) {
    return false
  }
  const d = pulledOutVehicleForJob.value?.damage
  return typeof d === "number" && d >= 1
})

const runRepair = async () => {
  const v = pulledOutVehicleForJob.value
  if (!v?.vehicleId) {
    return
  }
  await store.repairBusinessVehicle(v.vehicleId)
}

const stopCountdown = () => {
  if (countdownTimer.value) {
    clearInterval(countdownTimer.value)
    countdownTimer.value = null
  }
}

const syncRemainingSeconds = () => {
  if (props.isActive) {
    remainingSeconds.value = null
    return
  }

  if (typeof props.job?.expiresInSeconds === "number") {
    remainingSeconds.value = Math.max(0, Math.floor(props.job.expiresInSeconds))
  } else {
    remainingSeconds.value = null
  }
}

const requestJobsAfterExpiry = async () => {
  if (hasRequestedAfterExpiry.value) {
    return
  }

  hasRequestedAfterExpiry.value = true

  const currentBusinessId = store.businessId
  const currentBusinessType = store.businessType

  if (!currentBusinessId || !currentBusinessType || !store.loadBusinessData) {
    return
  }

  try {
    await store.loadBusinessData(currentBusinessType, currentBusinessId)
  } catch (error) {
  }
}

const startCountdown = () => {
  stopCountdown()
  hasRequestedAfterExpiry.value = false
  syncRemainingSeconds()
  if (remainingSeconds.value === null) {
    return
  }

  countdownTimer.value = setInterval(() => {
    if (remainingSeconds.value === null) {
      stopCountdown()
      return
    }

    if (remainingSeconds.value <= 0) {
      remainingSeconds.value = 0
      requestJobsAfterExpiry()
      stopCountdown()
      return
    }

    remainingSeconds.value = remainingSeconds.value - 1
  }, 1000)
}

const checkCanComplete = async () => {
  if (!props.isActive || !props.businessId || !props.job.jobId) {
    canComplete.value = false
    completionStatusMessage.value = null
    completionStatusFetched.value = false
    return
  }

  try {
    if (store.businessType === 'tuningShop') {
      const response = await lua.career_modules_business_tuningShop.getJobCompletionStatus(props.businessId, props.job.jobId)
      const status = response && typeof response === 'object' ? response : {}
      canComplete.value = status.canComplete === true
      completionStatusMessage.value = status.goalTimeMet ? (status.blockedMessage || null) : null
      completionStatusFetched.value = true
      return
    }

    completionStatusFetched.value = false
    const result = await lua.career_modules_business_businessComputer.canCompleteJob(props.businessId, props.job.jobId)
    canComplete.value = result === true
    completionStatusMessage.value = null
  } catch (error) {
    canComplete.value = false
    completionStatusMessage.value = null
    completionStatusFetched.value = store.businessType === 'tuningShop'
  }
}

const isExpired = computed(() => {
  if (props.isActive) {
    return false
  }
  return remainingSeconds.value !== null && remainingSeconds.value <= 0
})

const expirationText = computed(() => {
  if (props.isActive || remainingSeconds.value === null) {
    return null
  }
  if (remainingSeconds.value <= 0) {
    return "Expired"
  }
  return `Expires in ${formatTime(remainingSeconds.value, 0)}`
})

const cooldownTick = ref(0)
let cooldownTickTimer = null
const cooldownStartMs = ref(0)
const cooldownStartSec = ref(0)

watch(
  () => fleetCooldownSecondsFromServer.value,
  (sec) => {
    cooldownStartSec.value = Math.max(0, Math.floor(sec || 0))
    cooldownStartMs.value = Date.now()
  },
  { immediate: true }
)

const vehicleCooldownSec = computed(() => {
  void cooldownTick.value
  const start = cooldownStartSec.value
  if (start <= 0) return 0
  const elapsed = Math.floor((Date.now() - cooldownStartMs.value) / 1000)
  return Math.max(0, start - elapsed)
})

const formatCooldownMSS = (totalSec) => {
  const s = Math.max(0, Math.floor(Number(totalSec) || 0))
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const r = s % 60
  if (h > 0) return `${h}:${String(m).padStart(2, "0")}:${String(r).padStart(2, "0")}`
  return `${m}:${String(r).padStart(2, "0")}`
}

const pullOutBlockedByCooldown = computed(() => {
  // Fleet vehicle post-race cooldown must not block pulling out to work on the car.
  return false
})

const pullOutButtonTitle = computed(() => {
  if (!pullOutBlockedByCooldown.value) {
    return ""
  }
  return `Vehicle cooling down (${formatCooldownMSS(vehicleCooldownSec.value)} remaining)`
})

const isAcceptDisabled = computed(() => {
  if (props.isActive) {
    return false
  }
  if (store.activeJobs.length >= store.maxActiveJobs) {
    return true
  }
  if (store.businessType === "racingTeam" && vehicleCooldownSec.value > 0) {
    return true
  }
  return false
})

const acceptButtonTitle = computed(() => {
  if (!isAcceptDisabled.value) {
    return ""
  }
  if (store.activeJobs.length >= store.maxActiveJobs) {
    return `Active job limit reached (${store.maxActiveJobs} max)`
  }
  if (store.businessType === "racingTeam" && vehicleCooldownSec.value > 0) {
    return `Vehicle cooling down (${formatCooldownMSS(vehicleCooldownSec.value)})`
  }
  return ""
})

onMounted(() => {
  checkCanComplete()
  startCountdown()
  startKitInstallCountdown()
  cooldownTickTimer = setInterval(() => {
    cooldownTick.value++
  }, 1000)
})

onUnmounted(() => {
  stopCountdown()
  stopKitInstallCountdown()
  if (cooldownTickTimer) {
    clearInterval(cooldownTickTimer)
    cooldownTickTimer = null
  }
})

watch(() => [props.isActive, props.job.currentTime, props.job.goalTime, props.job.jobId, props.job.completionBlockedMessage, props.job.buildChanged], () => {
  checkCanComplete()
}, { immediate: false })

watch(() => props.job, () => {
  hasRequestedAfterExpiry.value = false
  checkCanComplete()
}, { deep: true })

watch(() => props.isActive, () => {
  hasRequestedAfterExpiry.value = false
})

watch(() => [props.job?.jobId, props.job?.expiresInSeconds, props.isActive], () => {
  startCountdown()
})

watch(() => [vehicleForJob.value?.kitInstallTimeRemaining, pulledOutVehicleForJob.value?.kitInstallTimeRemaining], () => {
  startKitInstallCountdown()
})
</script>

<style scoped lang="scss">
@import "../../styles/rlsHouse.scss";

.job-card {
  display: flex;
  flex-direction: column;
  height: 100%;
  min-width: 0;
  border-radius: var(--radius-panel);
  overflow: hidden;
  background: var(--panel);
}

/* ---- photo ---- */
.job-photo {
  position: relative;
  flex: 0 0 auto;
  width: 100%;
  aspect-ratio: 16 / 9;
  overflow: hidden;
  background: var(--photo);

  img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
}

.photo-pill {
  position: absolute;
  display: inline-flex;
  align-items: center;
  gap: 0.35em;
  padding: 0.45em 0.6em 0.25em;
  border-radius: var(--radius-pill);
  background: rgba(0, 0, 0, 0.72);
  color: #fff;
  font-size: 0.78em;
  font-weight: 700;
  line-height: 1;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;

  svg {
    width: 1em;
    height: 1em;
    flex: 0 0 auto;
    fill: none;
    stroke: currentColor;
    stroke-width: 2.4;
    stroke-linecap: round;
    stroke-linejoin: round;
    transform: translateY(-0.08em);
  }

  &.cooldown {
    top: 0.55em;
    left: 0.55em;
    color: var(--accent-soft);
  }

  &.expires {
    right: 0.55em;
    bottom: 0.55em;
  }

  &.expired {
    background: rgba(127, 29, 29, 0.9);
    color: var(--bad);
  }
}

/* ---- copy ---- */
.job-body {
  flex: 1 1 auto;
  display: flex;
  flex-direction: column;
  gap: var(--space-3);
  min-width: 0;
  padding: var(--inset);
}

.job-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 0.2em 0.8em;
  min-width: 0;
}

.job-name {
  flex: 1 1 10em;
  min-width: 0;
  font-size: 1.2em;
  font-weight: 800;
  line-height: 1.2;
  letter-spacing: -0.01em;
  overflow-wrap: anywhere;
  /* long names: two lines, then ellipsis */
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
  line-clamp: 2;
  overflow: hidden;
}

.job-pay {
  flex: 0 0 auto;
  color: var(--money);
  font-size: 1.08em;
  font-weight: 800;
  line-height: 1.2;
  font-variant-numeric: tabular-nums;
}

.job-goal {
  display: grid;
  gap: 0.2em;
  min-width: 0;

  .goal-value {
    color: #fff;
    font-size: 0.95em;
    font-weight: 600;
    line-height: 1.3;
    font-variant-numeric: tabular-nums;

    &.bad {
      color: var(--bad);
    }
  }
}

.job-progress {
  display: grid;
  gap: 0.4em;
}

.progress-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 0.8em;

  .progress-value {
    color: #fff;
    font-weight: 700;
    font-variant-numeric: tabular-nums;
  }
}

.slim-bar {
  height: 0.3em;
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
    transition: transform 0.3s ease-out;
  }
}

.notice {
  font-size: 0.85em;
}

.kit-install {
  display: flex;
  align-items: center;
  gap: 0.6em;
  width: 100%;
  color: var(--accent-soft);

  svg {
    width: 1.15em;
    height: 1.15em;
    flex: 0 0 auto;
    fill: none;
    stroke: currentColor;
    stroke-width: 2.2;
    stroke-linecap: round;
    stroke-linejoin: round;
  }

  .kit-copy {
    display: grid;
    gap: 0.15em;
    font-weight: 700;
  }

  .hint {
    font-variant-numeric: tabular-nums;
  }
}

/* ---- actions ---- */
.job-actions {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: var(--space-2);
  margin-top: auto;

  .notice {
    width: 100%;
  }

  .grow {
    flex: 1 1 auto;
  }
}

/* ---- compact (Home widget): wide thumbnail beside the name ---- */
.job-card.is-compact {
  display: grid;
  grid-template-columns: 7.5em minmax(0, 1fr);
  align-content: start;

  .job-photo {
    grid-row: 1;
    grid-column: 1;
    align-self: start;
    margin: var(--inset) 0 0 var(--inset);
    width: auto;
    border-radius: var(--radius-thumb);
  }

  .job-body {
    display: contents;
  }

  .job-head {
    grid-row: 1;
    grid-column: 2;
    align-self: center;
    flex-direction: column;
    align-items: flex-start;
    flex-wrap: nowrap;
    padding: var(--inset) var(--inset) 0 0.75em;
  }

  .job-name {
    flex: 0 0 auto;
    font-size: 1.05em;
  }

  .job-pay {
    font-size: 0.98em;
  }

  .job-goal,
  .job-progress,
  .job-actions {
    grid-column: 1 / -1;
    margin: var(--space-3) var(--inset) 0;
  }

  .job-actions {
    margin-bottom: var(--inset);
  }
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
