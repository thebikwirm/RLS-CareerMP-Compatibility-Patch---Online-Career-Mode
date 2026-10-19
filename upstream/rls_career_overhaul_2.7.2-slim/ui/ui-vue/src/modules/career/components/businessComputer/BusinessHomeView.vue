<template>
  <div class="rls-house home-dashboard">
    <!-- Top Row: Garage Widget (Full Width) -->
    <div class="top-row">
      <HomeScheduledRacesWidget v-if="store.businessType === 'racingTeam'" />
      <HomeGarageWidget
        v-else
        @put-away="handlePutAway"
        @abandon="handleAbandon"
        @go-to-jobs="store.switchView('jobs')"
      />
    </div>

    <!-- Bottom Grid: Racing team = Finances (left) / Driver overview + Sponsorship (right). Tuning shop = Jobs (left) / Techs + Finances (right). -->
    <div class="dashboard-grid">
      <div class="dashboard-column main-column">
        <template v-if="store.businessType === 'racingTeam'">
          <HomeFinancesWidget />
        </template>
        <HomeJobsWidget
          v-else
          @pull-out="handlePullOut"
          @put-away="handlePutAway"
          @abandon="handleAbandon"
          @complete="handleComplete"
          @accept="handleAccept"
          @decline="handleDecline"
        />
      </div>

      <div class="dashboard-column side-column">
        <div
          class="side-stack"
          :class="{ 'side-stack--racing-team': store.businessType === 'racingTeam' }"
        >
          <template v-if="store.businessType === 'racingTeam'">
            <HomeJobsWidget
              @pull-out="handlePullOut"
              @put-away="handlePutAway"
              @abandon="handleAbandon"
              @complete="handleComplete"
              @accept="handleAccept"
              @decline="handleDecline"
            />
            <HomeSponsorshipWidget />
          </template>
          <template v-else>
            <HomeTechsWidget />
            <HomeFinancesWidget />
          </template>
        </div>
      </div>
    </div>

    <!-- Confirmation Modal (teleported: carries .rls-house + the em scale itself) -->
    <Teleport to="body">
      <transition name="modal-fade">
        <div v-if="showAbandonModal" class="rls-house modal-overlay" @click.self="cancelAbandon">
          <div class="modal confirm-card" v-bng-scoped-nav="abandonModalScope" v-bc-modal-focus v-bng-on-ui-nav:back,menu="cancelAbandon">
            <h3>{{ isRacingTeamVehicleSell ? 'Sell this vehicle?' : 'Abandon this job?' }}</h3>
            <p v-if="isRacingTeamVehicleSell">
              Sell this team vehicle? You will receive
              <span class="money"><BngIcon class="cur" :type="icons.beamCurrency" />{{ saleProceeds.toLocaleString() }}</span> for the sale.
            </p>
            <p v-else>
              Are you sure you want to abandon this job? You will be charged a penalty of
              <span class="money"><BngIcon class="cur" :type="icons.beamCurrency" />{{ penaltyCost.toLocaleString() }}</span>.
            </p>
            <div class="actions">
              <HouseButton variant="quiet" bng-scoped-nav-autofocus @click="cancelAbandon">Cancel</HouseButton>
              <HouseButton variant="danger" @click="confirmAbandon">
                {{ isRacingTeamVehicleSell ? 'Yes, sell' : 'Yes, abandon' }}
              </HouseButton>
            </div>
          </div>
        </div>
      </transition>
    </Teleport>

    <Teleport to="body">
      <div
        v-if="vehicleOutOfClassModalOpen"
        class="rls-house modal-overlay"
        @click.self="vehicleOutOfClassModalOpen = false"
      >
        <div
          class="modal confirm-card"
          v-bng-scoped-nav="outOfClassModalScope" v-bc-modal-focus
          v-bng-on-ui-nav:back,menu="closeOutOfClassModal"
          @click.stop
          @mousedown.stop>
          <h3>Vehicle out of class</h3>
          <p>This car's effective HP is above the sanctioned HP class for the selected race. Choose another offer or switch to a car that matches the HP bracket.</p>
          <div class="actions">
            <HouseButton
              variant="primary"
              bng-scoped-nav-autofocus
              @click.stop="vehicleOutOfClassModalOpen = false"
              @mousedown.stop
            >OK</HouseButton>
          </div>
        </div>
      </div>
    </Teleport>
  </div>
</template>

<script setup>
import { computed, ref, Teleport, onMounted, onUnmounted } from "vue"
import { useBridge } from "@/bridge"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import HomeJobsWidget from "./widgets/HomeJobsWidget.vue"
import HomeGarageWidget from "./widgets/HomeGarageWidget.vue"
import HomeScheduledRacesWidget from "./widgets/HomeScheduledRacesWidget.vue"
import HomeTechsWidget from "./widgets/HomeTechsWidget.vue"
import HomeFinancesWidget from "./widgets/HomeFinancesWidget.vue"
import HomeSponsorshipWidget from "./widgets/HomeSponsorshipWidget.vue"
import { HouseButton } from "../house"
import { BngIcon, icons } from "@/common/components/base"
import { vBngScopedNav, vBngOnUiNav } from "@/common/directives"
import { bcModalScope, vBcModalFocus } from "./bcModalNav"

const store = useBusinessComputerStore()
const { events } = useBridge()
const abandonModalScope = bcModalScope("home-abandon")
const outOfClassModalScope = bcModalScope("home-out-of-class")
const closeOutOfClassModal = () => {
  vehicleOutOfClassModalOpen.value = false
  return false
}
const normalizeId = (id) => {
  if (id === undefined || id === null) return null
  const num = Number(id)
  return isNaN(num) ? String(id) : num
}

const showAbandonModal = ref(false)
const jobToAbandon = ref(null)
const vehicleOutOfClassModalOpen = ref(false)

const handleVehicleOutOfClass = () => {
  vehicleOutOfClassModalOpen.value = true
}

onMounted(() => {
  events.on("racingTeam:vehicleOutOfClass", handleVehicleOutOfClass)
})
onUnmounted(() => {
  events.off("racingTeam:vehicleOutOfClass", handleVehicleOutOfClass)
})

const penaltyCost = computed(() => {
  if (!jobToAbandon.value) return 0
  return jobToAbandon.value.penalty || 0
})

const isRacingTeamVehicleSell = computed(() => store.businessType === "racingTeam")

const saleProceeds = computed(() => {
  if (!jobToAbandon.value) return 0
  const r = jobToAbandon.value.reward
  const n = typeof r === "number" ? r : Number(r)
  return Number.isFinite(n) ? n : 0
})

const pullOutDiag = (...args) => {
  try {
    console.debug("[rlsBizPull]", ...args)
  } catch (_) {}
}

const handlePullOut = async (job) => {
  if (job == null) {
    pullOutDiag("Home handlePullOut abort: no job", {})
    return
  }

  if (!Array.isArray(store.vehicles)) {
    pullOutDiag("Home handlePullOut abort: vehicles not array", { jobId: job.jobId ?? job.id })
    return
  }

  const jobId = job.jobId ?? job.id
  if (jobId === undefined || jobId === null) {
    pullOutDiag("Home handlePullOut abort: no job id", { job })
    return
  }

  const normalizedStoredVid = normalizeId(job?.storedVehicleId)
  let vehicle = null
  if (normalizedStoredVid !== null) {
    vehicle = store.vehicles.find(v => normalizeId(v?.vehicleId) === normalizedStoredVid) || null
  }
  if (!vehicle) {
    const normalizedJobId = normalizeId(jobId)
    vehicle = store.vehicles.find(v => {
      if (!v.jobId) return false
      const normalizedVehicleJobId = normalizeId(v.jobId)
      return normalizedVehicleJobId === normalizedJobId
    })
  }

  if (!vehicle) {
    pullOutDiag("Home handlePullOut abort: no matching vehicle (Lua pullOut never called)", {
      jobId,
      storedVehicleId: job?.storedVehicleId,
      fleetCount: store.vehicles.length,
    })
    return
  }

  pullOutDiag("Home handlePullOut calling store.pullOutVehicle", { jobId, vehicleId: vehicle.vehicleId })
  await store.pullOutVehicle(vehicle.vehicleId)
}

const handlePutAway = async () => {
  await store.putAwayVehicle()
}

const handleAbandon = (job) => {
  if (!job) {
    return
  }
  jobToAbandon.value = job
  showAbandonModal.value = true
}

const confirmAbandon = async () => {
  if (jobToAbandon.value) {
    await store.abandonJob(parseInt(jobToAbandon.value.id))
    showAbandonModal.value = false
    jobToAbandon.value = null
  }
}

const cancelAbandon = () => {
  showAbandonModal.value = false
  jobToAbandon.value = null
}

const handleAccept = async (job) => {
  await store.acceptJob(parseInt(job.id))
}

const handleDecline = async (job) => {
  await store.declineJob(parseInt(job.id))
}

const handleComplete = async (job) => {
  const jobId = job.jobId ?? parseInt(job.id)
  await store.completeJob(jobId)
}
</script>

<style scoped lang="scss">
@import "../../styles/rlsHouse.scss";

.home-dashboard {
  /* Grow with content; the shell's .content-body is the scroller (slim translucent bar). */
  min-height: 100%;
  display: flex;
  flex-direction: column;
  padding-bottom: 1em;
  gap: 1em;
}

.top-row {
  flex-shrink: 0;
}

.dashboard-grid {
  display: grid;
  grid-template-columns: 1fr;
  gap: 1em;
  flex: 1 0 auto;
  align-items: stretch;

  @media (min-width: 1280px) {
    grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
  }
}

.dashboard-column {
  display: flex;
  flex-direction: column;
  gap: 1em;
  min-width: 0;

  /* Widgets size to the column instead of a fixed 100% height. */
  :deep(.home-widget) {
    height: auto;
  }

  &.main-column {
    :deep(.jobs-widget),
    :deep(.finances-widget) {
      flex: 1 0 auto;
      min-height: 24em;
      max-height: 40em;
    }
  }
}

.side-stack {
  display: flex;
  flex-direction: column;
  gap: 1em;
  flex: 1 0 auto;

  :deep(.finances-widget),
  :deep(.sponsorship-widget),
  :deep(.techs-widget) {
    flex: 1 0 auto;
    min-height: 15em;
    max-height: 26em;
  }

  &.side-stack--racing-team {
    :deep(.jobs-widget) {
      flex: 0 0 auto;
      min-height: 12em;
      max-height: 22em;
    }

    :deep(.sponsorship-widget) {
      flex: 1 0 auto;
      min-height: 15em;
    }
  }
}

/* Slim translucent scrollbars for widget lists */
.home-dashboard {
  :deep(.widget-content),
  :deep(.tx-scroll) {
  }

  :deep(.widget-content::-webkit-scrollbar),
  :deep(.tx-scroll::-webkit-scrollbar) {
    width: 0.5em;
  }

  :deep(.widget-content::-webkit-scrollbar-track),
  :deep(.tx-scroll::-webkit-scrollbar-track) {
    background: transparent;
  }

  :deep(.widget-content::-webkit-scrollbar-thumb),
  :deep(.tx-scroll::-webkit-scrollbar-thumb) {
    background: rgba(255, 255, 255, 0.22);
    border-radius: 1em;
    border: 0.12em solid transparent;
    background-clip: padding-box;
  }
}

/* house modal (teleported to body, so it carries its own em scale) */
.modal-overlay {
  position: fixed;
  inset: 0;
  z-index: 10000;
  display: grid;
  place-items: center;
  padding: 1em;
  background: rgba(0, 0, 0, 0.6);
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
}

.confirm-card {
  width: min(28em, 92vw);
  padding: 1.1em 1.1em 1em;

  h3 {
    font-size: 1.2em;
    line-height: 1.2;
  }

  .money {
    color: var(--money);
    font-weight: 800;
    font-variant-numeric: tabular-nums;
  }

  .actions {
    margin-top: var(--space-1);

    > :deep(.house-button) {
      min-width: 6.5em;
    }
  }
}

.modal-fade-enter-active,
.modal-fade-leave-active {
  transition: opacity 0.18s ease;

  .confirm-card {
    transition: transform 0.18s ease, opacity 0.18s ease;
  }
}

.modal-fade-enter-from,
.modal-fade-leave-to {
  opacity: 0;

  .confirm-card {
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
