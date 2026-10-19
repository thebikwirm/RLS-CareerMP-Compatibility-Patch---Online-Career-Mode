<!-- Business computer: the vehicle currently pulled out, house style. Caption + hint, photo first,
     name biggest, payment in gold, goal progress as facts + a scaleX bar, then the actions: Go to Tuning
     is the one orange, Put Away neutral, Abandon Job danger when the customer car is damaged. -->
<template>
  <div class="vehicle-card rls-house">
    <div class="card-head">
      <span class="caption">Current Vehicle in Garage</span>
      <p class="hint">This vehicle is currently pulled out and ready for work</p>
    </div>
    <div class="vehicle-content">
      <div class="vehicle-image">
        <img v-if="vehicle.vehicleImage" :src="vehicle.vehicleImage" :alt="vehicle.vehicleName" />
        <BngIcon v-else class="photo-fallback" :type="icons.car" />
        <span v-if="vehicle.isPersonal" class="pill photo-pill">Personal</span>
        <span v-else class="pill photo-pill">In Garage</span>
      </div>
      <div class="vehicle-info">
        <div class="name-row">
          <h3 class="vehicle-name">{{ vehicle.vehicleYear }} {{ vehicle.vehicleName }}</h3>
          <span v-if="vehicle.vehicleType" class="pill">{{ vehicle.vehicleType }}</span>
        </div>

        <p v-if="vehicle.isPersonal" class="hint">Personal vehicle: tune your own vehicle using shop equipment</p>

        <div v-if="(job && !vehicle.isPersonal)" class="facts">
          <div class="fact money">
            <span class="fact-key">Payment</span>
            <span class="fact-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ (job.reward || 0).toLocaleString() }}</span>
          </div>
          <div class="fact">
            <span class="fact-key">Goal</span>
            <span class="fact-value wrap">{{ job.goal }}</span>
          </div>
          <div class="fact">
            <span class="fact-key">Current</span>
            <span class="fact-value">{{ formattedCurrentTime }}</span>
          </div>
        </div>
        <div v-if="job && !vehicle.isPersonal" class="goal-bar" aria-hidden="true">
          <span :style="{ transform: `scaleX(${(goalProgress || 0) / 100})` }"></span>
        </div>

        <div class="vehicle-actions" :class="{ locked: store.isDamageLocked || kitInstallLocked }">
          <template v-if="kitInstallLocked">
            <div class="notice status">
              <BngIcon :type="icons.wrench" />
              <span>Installing {{ vehicle?.kitInstallKitName || 'kit' }}</span>
              <span class="status-time">{{ formatKitInstallTime(kitInstallSecondsRemaining) }} remaining</span>
            </div>
          </template>
          <template v-else-if="hasTechAssigned">
            <div class="notice status">{{ techName || 'Tech' }} is working on this</div>
          </template>
          <template v-else-if="store.isDamageLocked">
            <div class="notice bad status">
              <BngIcon :type="icons.warning" />
              <span>Customer Vehicle Damaged</span>
            </div>
            <HouseButton
              variant="danger"
              block
              @mousedown.stop
              @click.stop="$emit('abandon')"
            >
              Abandon Job
            </HouseButton>
          </template>
          <template v-else>
            <HouseButton v-if="!vehicle?.isPersonal" @click.stop="$emit('put-away', vehicle?.vehicleId)">Put Away Vehicle</HouseButton>
            <HouseButton variant="primary" @click.stop="goToTuning">Go to Tuning</HouseButton>
          </template>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed, ref, onMounted, onUnmounted, watch } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import { BngIcon, icons } from "@/common/components/base"
import { HouseButton } from "../house"

const props = defineProps({
  vehicle: Object,
  job: {
    type: Object,
    default: null
  }
})

const store = useBusinessComputerStore()
defineEmits(['put-away', 'abandon'])

const techAssigned = computed(() => {
  if (!props.job?.techAssigned) return null
  return props.job.techAssigned
})
const techName = computed(() => {
  if (!techAssigned.value) return null
  const techs = store.techs || []
  const tech = techs.find(t => String(t.id) === String(techAssigned.value))
  return tech?.name || null
})
const hasTechAssigned = computed(() => !!techAssigned.value)

const kitInstallSecondsRemaining = ref(0)
const kitInstallTimer = ref(null)

const syncKitInstallTime = () => {
  const serverTime = props.vehicle?.kitInstallTimeRemaining || 0
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

const kitInstallLocked = computed(() => {
  if (props.vehicle?.kitInstallLocked === true) return true
  return kitInstallSecondsRemaining.value > 0
})

onMounted(() => {
  startKitInstallCountdown()
})

onUnmounted(() => {
  stopKitInstallCountdown()
})

watch(() => props.vehicle?.kitInstallTimeRemaining, () => {
  startKitInstallCountdown()
})

const goToTuning = () => {
  store.switchVehicleView('tuning')
}

const formatKitInstallTime = (seconds) => {
  if (!seconds || seconds <= 0) return '0s'
  const numSeconds = Number(seconds)
  if (isNaN(numSeconds)) return '0s'
  if (numSeconds < 60) return `${Math.round(numSeconds)}s`
  const minutes = Math.floor(numSeconds / 60)
  const remainingSeconds = Math.round(numSeconds % 60)
  if (remainingSeconds === 0) return `${minutes}m`
  return `${minutes}m ${remainingSeconds}s`
}

const formatTime = (time) => {
  if (typeof time !== "number" || isNaN(time)) {
    return time || "0"
  }
  if (time >= 60) {
    const minutes = Math.floor(time / 60)
    const seconds = Math.round(time % 60)
    if (seconds >= 1) {
      return `${minutes} min ${seconds} s`
    }
    return `${minutes} min`
  }
  return Math.round(time) + " s"
}

const formatTimeWithUnit = (time, timeUnit) => {
  if (typeof time !== "number" || isNaN(time)) {
    return (time || "0") + (timeUnit || "")
  }
  return formatTime(time)
}

const formattedCurrentTime = computed(() => {
  if (!props.job) {
    return "--"
  }
  const time = typeof props.job.currentTime === "number" ? props.job.currentTime : props.job.baselineTime
  return formatTimeWithUnit(time, props.job.timeUnit)
})

const goalProgress = computed(() => {
  if (!props.job || props.job.baselineTime === undefined || props.job.goalTime === undefined) {
    return 0
  }
  const baseline = Number(props.job.baselineTime)
  const goal = Number(props.job.goalTime)
  const current = Number(props.job.currentTime ?? props.job.baselineTime)
  if (!isFinite(baseline) || !isFinite(goal) || baseline === goal) {
    return 0
  }
  const progress = ((baseline - current) / (baseline - goal)) * 100
  return Math.max(0, Math.min(100, progress))
})
</script>

<style scoped lang="scss">
@import "../../styles/rlsHouse.scss";

.vehicle-card {
  display: grid;
  gap: 0.9em;
  padding: var(--inset);
  border-radius: var(--radius-panel);
  background: var(--panel);
}

.card-head {
  display: grid;
  gap: 0.25em;
}

.vehicle-content {
  display: grid;
  grid-template-columns: minmax(12em, 18em) minmax(0, 1fr);
  gap: 1.1em;
  align-items: stretch;
}

.vehicle-image {
  position: relative;
  display: grid;
  place-items: center;
  align-self: start;
  aspect-ratio: 16 / 9;
  border-radius: var(--radius-thumb);
  overflow: hidden;
  background: var(--photo);

  img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
}
.photo-fallback {
  font-size: 2.4em;
  color: rgba(255, 255, 255, 0.25);
}
.photo-pill {
  position: absolute;
  top: 0.55em;
  left: 0.55em;
  background: rgba(0, 0, 0, 0.6);
  color: #fff;
}

.vehicle-info {
  display: flex;
  flex-direction: column;
  gap: 0.75em;
  min-width: 0;
}
.name-row {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.35em 0.6em;
}
.vehicle-name {
  margin: 0;
  color: #fff;
  font-size: 1.3em;
  font-weight: 800;
  line-height: 1.2;
  overflow-wrap: anywhere;
}

.fact-value {
  font-variant-numeric: tabular-nums;
  &.wrap {
    white-space: normal;
    overflow: visible;
    text-overflow: clip;
    overflow-wrap: anywhere;
  }
}

.goal-bar {
  position: relative;
  height: 0.4em;
  border-radius: 1em;
  overflow: hidden;
  background: rgba(255, 255, 255, 0.12);
  > span {
    position: absolute;
    inset: 0;
    border-radius: inherit;
    background: var(--accent);
    transform-origin: left center;
    transition: transform 0.3s ease;
  }
}

.vehicle-actions {
  display: flex;
  flex-wrap: wrap;
  justify-content: flex-end;
  gap: 0.45em;
  margin-top: auto;

  &.locked {
    flex-direction: column;
    align-items: stretch;
  }
}

.notice.status {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.3em 0.5em;
  font-weight: 700;
}
.status-time {
  margin-left: auto;
  color: var(--faint);
  font-size: 0.88em;
  font-variant-numeric: tabular-nums;
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
