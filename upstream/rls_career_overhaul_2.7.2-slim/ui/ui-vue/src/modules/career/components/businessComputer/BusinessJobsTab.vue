<template>
  <div class="rls-house jobs-tab">
    <header class="tab-head">
      <div class="tab-copy">
        <h2 class="block-title">{{ store.businessType === 'racingTeam' ? 'Goals' : 'Jobs' }}</h2>
        <p class="hint">{{ store.businessType === 'racingTeam' ? 'Track goals and milestones for your racing program.' : 'Manage active work and available opportunities in one place.' }}</p>
      </div>
      <HouseButton
        v-if="store.businessType === 'tuningShop'"
        class="filters-button"
        :icon="icons.filter"
        @click.stop="openFiltersModal"
        @mousedown.stop="openFiltersModal"
        title="Manage filters, notifications, and blacklists"
      >
        Filters<span v-if="filtersActiveCount" class="pill accent count-pill">{{ filtersActiveCount }}</span>
      </HouseButton>
    </header>

    <RacingTeamPromoPanel
      v-if="store.businessType === 'racingTeam' && league2Invite.visible"
      variant="card"
      :title="league2Invite.popupTitle"
      :body="league2Invite.popupBody"
      :image-url="league2Invite.popupImageUrl"
      :fee="league2Invite.fee"
    >
      <HouseButton variant="quiet" @click.stop="onLeague2InviteLaterJobs" @mousedown.stop>
        {{ league2Invite.laterLabel }}
      </HouseButton>
      <HouseButton variant="primary" @click.stop="onLeague2InviteAcceptJobs" @mousedown.stop>
        {{ league2Invite.acceptLabel }}
      </HouseButton>
    </RacingTeamPromoPanel>

    <section
      v-if="store.businessType === 'racingTeam' && racingTeamCurrentGoal"
      class="panel current-goal"
    >
      <div class="goal-head">
        <span class="caption">Current goal</span>
        <span v-if="racingTeamCurrentGoal.tier != null" class="pill">Tier {{ racingTeamCurrentGoal.tier }}</span>
        <span v-else-if="racingTeamLeagueLabel" class="pill">{{ racingTeamLeagueLabel }}</span>
      </div>
      <strong class="goal-title">{{ racingTeamCurrentGoal.title || 'Current goal' }}</strong>
      <p v-if="racingTeamCurrentGoal.description" class="goal-description">{{ racingTeamCurrentGoal.description }}</p>
      <div class="facts goal-facts">
        <div class="fact">
          <span class="fact-key">Target</span>
          <span class="fact-value">{{ racingTeamCurrentGoal.targetLabel || '—' }}</span>
        </div>
        <div class="fact">
          <span class="fact-key">Progress</span>
          <span class="fact-value">{{ racingTeamCurrentGoal.progressLabel || '—' }}</span>
        </div>
      </div>
    </section>

    <section
      v-if="store.businessType === 'racingTeam' && racingTeamCompletedGoals.length"
      class="job-section"
    >
      <div class="section-head">
        <span class="caption">Completed goals</span>
        <span class="pill count">{{ racingTeamCompletedGoals.length }}</span>
      </div>
      <div class="panel completed-goals">
        <div class="lines">
          <div v-for="cg in displayedCompletedGoals" :key="cg.id" class="line completed-goal">
            <span class="completed-copy">
              <strong>{{ cg.title || cg.id }}</strong>
              <span v-if="cg.description" class="hint">{{ cg.description }}</span>
              <span v-if="cg.completedBestTimesSummary" class="hint">{{ cg.completedBestTimesSummary }}</span>
            </span>
            <span v-if="formatLeagueLabel(cg.league)" class="pill">{{ formatLeagueLabel(cg.league) }}</span>
          </div>
        </div>
        <HouseButton
          v-if="hasHiddenCompletedGoals"
          variant="quiet"
          compact
          class="completed-toggle"
          @click.stop="completedGoalsExpanded = !completedGoalsExpanded"
          @mousedown.stop
        >
          {{ completedGoalsExpanded ? "Show less" : "Show more" }}
        </HouseButton>
      </div>
    </section>

    <!-- recognition picks: open a chooser -->
    <div v-if="showRecognitionBanner" class="panel recognition">
      <div class="facts recognition-facts">
        <button
          v-if="store.brandRecognitionUnlocked"
          type="button"
          class="fact recognition-fact"
          @click.stop="openBrandModal"
          @mousedown.stop="openBrandModal"
        >
          <span class="fact-key">Brand recognition</span>
          <span class="fact-value" :class="{ unset: brandSelectionDisplay === 'Not Selected' }">{{ brandSelectionDisplay }}</span>
        </button>
        <button
          v-if="store.raceRecognitionUnlocked"
          type="button"
          class="fact recognition-fact"
          @click.stop="openRaceModal"
          @mousedown.stop="openRaceModal"
        >
          <span class="fact-key">Race recognition</span>
          <span class="fact-value" :class="{ unset: raceSelectionDisplay === 'Not Selected' }">{{ raceSelectionDisplay }}</span>
        </button>
      </div>
    </div>

    <div v-if="store.businessType !== 'racingTeam' && (store.activeJobs.length || store.newJobs.length)" class="jobs-content">
      <!-- Active Jobs Section -->
      <section v-if="store.activeJobs.length > 0" class="job-section">
        <div class="section-head">
          <span class="caption">Active jobs</span>
          <span class="pill count">{{ store.activeJobs.length }}</span>
        </div>
        <div class="jobs-grid">
          <template v-for="job in store.activeJobs" :key="`active-${job.id}`">
            <div class="job-card-wrapper" @click.stop="interceptEvent" @mousedown.stop="interceptEvent">
              <BusinessJobCard :job="job" :is-active="true" :business-id="store.businessId" layout="full"
                @pull-out="handlePullOut(job)" @put-away="handlePutAway(job)" @abandon="handleAbandon(job)"
                @complete="handleComplete(job)" />
            </div>
          </template>
        </div>
      </section>

      <!-- New Jobs Section -->
      <section v-if="store.newJobs.length > 0" class="job-section">
        <div class="section-head">
          <span class="caption">New jobs</span>
          <span class="pill count">{{ store.newJobs.length }}</span>
        </div>
        <div class="jobs-grid">
          <template v-for="job in store.newJobs" :key="`new-${job.id}`">
            <div class="job-card-wrapper" @click.stop="interceptEvent" @mousedown.stop="interceptEvent">
              <BusinessJobCard :job="job" :is-active="false" layout="full" @accept="handleAccept"
                @decline="handleDecline" />
            </div>
          </template>
        </div>
      </section>
    </div>

    <div v-else-if="store.businessType !== 'racingTeam'" class="empty">
      <h3>No jobs right now</h3>
      <p>New work shows up here as customers bring their cars in.</p>
    </div>

    <Teleport to="body">
      <transition name="modal-fade">
        <div v-if="showAbandonModal && store.businessType !== 'racingTeam'" class="rls-house rls-house-card house-overlay" @click.self.stop="cancelAbandon"
          @mousedown.self.stop="cancelAbandon">
          <div class="modal house-modal" v-bng-scoped-nav="abandonModalScope" v-bc-modal-focus v-bng-on-ui-nav:back,menu="cancelAbandon">
            <h3>Abandon job?</h3>
            <p>
              You will be charged a penalty of
              <strong class="money"><BngIcon class="cur" :type="icons.beamCurrency" />{{ penaltyCost.toLocaleString() }}</strong>.
            </p>
            <div class="modal-actions">
              <HouseButton variant="quiet" bng-scoped-nav-autofocus @click.stop="cancelAbandon"
                @mousedown.stop="cancelAbandon">Cancel</HouseButton>
              <HouseButton variant="danger" @click.stop="confirmAbandon" @mousedown.stop="confirmAbandon">
                Abandon
              </HouseButton>
            </div>
          </div>
        </div>
      </transition>
    </Teleport>

    <Teleport to="body">
      <transition name="modal-fade">
        <div v-if="showBrandModal" class="rls-house rls-house-card house-overlay" @click.self.stop="closeBrandModal"
          @mousedown.self.stop="closeBrandModal">
          <div class="modal house-modal selection-modal" v-bng-scoped-nav="brandModalScope" v-bc-modal-focus v-bng-on-ui-nav:back,menu="closeBrandModal" @click.stop @mousedown.stop>
            <h3>Brand recognition</h3>
            <div v-if="isLoadingBrands" class="selection-empty">
              <p>Loading brands</p>
            </div>
            <div v-else-if="store.availableBrands.length === 0" class="selection-empty">
              <p>No brands available</p>
              <span class="hint">Try refreshing or check if vehicles are loaded.</span>
            </div>
            <div v-else class="selection-list scroll" v-bng-ui-nav-scroll>
              <button type="button" class="menu-item selection-item" :class="{ 'selected': !store.brandSelection }"
                :bng-scoped-nav-autofocus="!store.brandSelection ? true : null"
                @click.stop="selectBrand(null)" @mousedown.stop="selectBrand(null)">
                <span>No brand</span>
                <svg v-if="!store.brandSelection" viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5" /></svg>
              </button>
              <button v-for="brand in store.availableBrands" :key="brand" type="button" class="menu-item selection-item"
                :class="{ 'selected': store.brandSelection === brand }"
                :bng-scoped-nav-autofocus="store.brandSelection === brand ? true : null" @click.stop="selectBrand(brand)"
                @mousedown.stop="selectBrand(brand)">
                <span>{{ brand }}</span>
                <svg v-if="store.brandSelection === brand" viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5" /></svg>
              </button>
            </div>
            <div class="modal-actions">
              <HouseButton variant="quiet" @click.stop="closeBrandModal" @mousedown.stop="closeBrandModal">Close</HouseButton>
            </div>
          </div>
        </div>
      </transition>
    </Teleport>

    <Teleport to="body">
      <transition name="modal-fade">
        <div v-if="showRaceModal" class="rls-house rls-house-card house-overlay" @click.self.stop="closeRaceModal"
          @mousedown.self.stop="closeRaceModal">
          <div class="modal house-modal selection-modal" v-bng-scoped-nav="raceModalScope" v-bc-modal-focus v-bng-on-ui-nav:back,menu="closeRaceModal" @click.stop @mousedown.stop>
            <h3>Race recognition</h3>
            <div v-if="isLoadingRaceTypes" class="selection-empty">
              <p>Loading race types</p>
            </div>
            <div v-else-if="store.availableRaceTypes.length === 0" class="selection-empty">
              <p>No race types available</p>
              <span class="hint">Check if race data is loaded.</span>
            </div>
            <div v-else class="selection-list scroll" v-bng-ui-nav-scroll>
              <button type="button" class="menu-item selection-item" :class="{ 'selected': !store.raceSelection }"
                :bng-scoped-nav-autofocus="!store.raceSelection ? true : null"
                @click.stop="selectRace(null)" @mousedown.stop="selectRace(null)">
                <span>No race type</span>
                <svg v-if="!store.raceSelection" viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5" /></svg>
              </button>
              <button v-for="raceType in store.availableRaceTypes" :key="raceType.id" type="button" class="menu-item selection-item"
                :class="{ 'selected': store.raceSelection === raceType.id }"
                :bng-scoped-nav-autofocus="store.raceSelection === raceType.id ? true : null" @click.stop="selectRace(raceType.id)"
                @mousedown.stop="selectRace(raceType.id)">
                <span>{{ raceType.label }}</span>
                <svg v-if="store.raceSelection === raceType.id" viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5" /></svg>
              </button>
            </div>
            <div class="modal-actions">
              <HouseButton variant="quiet" @click.stop="closeRaceModal" @mousedown.stop="closeRaceModal">Close</HouseButton>
            </div>
          </div>
        </div>
      </transition>
    </Teleport>

    <FiltersModal :show="showFiltersModal" @close="closeFiltersModal" />
  </div>
</template>

<script setup>
import { computed, ref, Teleport, onMounted, onUnmounted, watch, nextTick } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import { useBridge } from "@/bridge"
import BusinessJobCard from "./BusinessJobCard.vue"
import FiltersModal from "./FiltersModal.vue"
import RacingTeamPromoPanel from "../RacingTeamPromoPanel.vue"
import { normalizeId } from "../../utils/businessUtils"
import { BngIcon, icons } from "@/common/components/base"
import { HouseButton } from "../house"
import { vBngScopedNav, vBngOnUiNav, vBngUiNavScroll } from "@/common/directives"
import { bcModalScope, vBcModalFocus } from "./bcModalNav"

const store = useBusinessComputerStore()
// pickers open on the current choice; the abandon confirm opens on Cancel
const abandonModalScope = bcModalScope("job-abandon")
const brandModalScope = bcModalScope("brand-recognition")
const raceModalScope = bcModalScope("race-recognition")
const { events } = useBridge()

const showAbandonModal = ref(false)
const jobToAbandon = ref(null)
const interceptEvent = () => { }

function formatLeagueLabel (league) {
  if (!league || typeof league !== "string") return ""
  const map = store.racingTeamLeagueDisplayNames
  if (map && typeof map === "object" && map[league]) {
    return String(map[league])
  }
  const m = /^league(\d+)$/i.exec(league.trim())
  if (m) return `League ${m[1]}`
  return league
}

const showBrandModal = ref(false)
const showRaceModal = ref(false)
const showFiltersModal = ref(false)
const isLoadingBrands = ref(false)
const isLoadingRaceTypes = ref(false)

// Count pill on the Filters button: vehicles currently on the blacklist, notification list and
// manager blacklist (display only; the lists themselves are managed in FiltersModal).
const filtersActiveCount = computed(() => {
  const len = (data, key) => (Array.isArray(data?.[key]) ? data[key].length : 0)
  return len(store.blacklistData, "blacklist")
    + len(store.notificationListData, "notificationList")
    + len(store.managerBlacklistData, "managerBlacklist")
})

const showRecognitionBanner = computed(() => {
  return store.brandRecognitionUnlocked || store.raceRecognitionUnlocked
})

const racingTeamCurrentGoal = computed(() => {
  const g = store.businessData?.currentGoal
  if (!g || typeof g !== "object") return null
  return g
})

const racingTeamLeagueLabel = computed(() => {
  const g = store.businessData?.currentGoal
  if (g?.league) return formatLeagueLabel(g.league)
  const cl = store.businessData?.currentLeague
  if (cl) return formatLeagueLabel(cl)
  return ""
})

const COMPLETED_GOALS_COLLAPSED_COUNT = 1

const completedGoalsExpanded = ref(false)

const racingTeamCompletedGoals = computed(() => {
  const c = store.businessData?.completedGoals
  return Array.isArray(c) ? c : []
})

const racingTeamCompletedGoalsNewestFirst = computed(() => {
  const all = racingTeamCompletedGoals.value
  return all.length ? [...all].reverse() : []
})

const hasHiddenCompletedGoals = computed(
  () => racingTeamCompletedGoalsNewestFirst.value.length > COMPLETED_GOALS_COLLAPSED_COUNT
)

const displayedCompletedGoals = computed(() => {
  const all = racingTeamCompletedGoalsNewestFirst.value
  if (completedGoalsExpanded.value || all.length <= COMPLETED_GOALS_COLLAPSED_COUNT) {
    return all
  }
  return all.slice(0, COMPLETED_GOALS_COLLAPSED_COUNT)
})

const league2Invite = computed(() => store.league2Invite ?? {})

const onLeague2InviteLaterJobs = async () => {
  await store.racingTeamLeague2InviteLater()
}

const onLeague2InviteAcceptJobs = async () => {
  await store.acceptLeague2Invite()
}

const brandSelectionDisplay = computed(() => {
  const selection = store.brandSelection
  if (selection === null || selection === undefined || selection === "null" || selection === "") {
    return "Not Selected"
  }
  return selection
})

const raceSelectionDisplay = computed(() => {
  if (!store.raceSelection) return "Not Selected"
  const raceType = store.availableRaceTypes.find(rt => rt.id === store.raceSelection)
  return raceType ? raceType.label : "Not Selected"
})

const handleBrandsReceived = (data) => {
  if (data && Array.isArray(data.brands)) {
    store.availableBrands = data.brands
  } else {
    store.availableBrands = []
  }
  isLoadingBrands.value = false
}

const openBrandModal = async () => {
  showBrandModal.value = true
  if (store.availableBrands.length === 0) {
    isLoadingBrands.value = true
    store.getAvailableBrands()
  }
}

const closeBrandModal = () => {
  showBrandModal.value = false
}

const selectBrand = async (brand) => {
  await store.setBrandSelection(brand)
  closeBrandModal()
}

const handleRaceTypesReceived = (data) => {
  if (data && Array.isArray(data.raceTypes)) {
    store.availableRaceTypes = data.raceTypes
  } else {
    store.availableRaceTypes = []
  }
  isLoadingRaceTypes.value = false
}

const openRaceModal = async () => {
  showRaceModal.value = true
  if (store.availableRaceTypes.length === 0) {
    isLoadingRaceTypes.value = true
    store.getAvailableRaceTypes()
  }
}

const closeRaceModal = () => {
  showRaceModal.value = false
}

const openFiltersModal = () => {
  showFiltersModal.value = true
}

const closeFiltersModal = () => {
  showFiltersModal.value = false
}

const selectRace = async (raceType) => {
  await store.setRaceSelection(raceType)
  closeRaceModal()
}

onMounted(async () => {
  events.on('businessComputer:onAvailableBrandsReceived', handleBrandsReceived)
  events.on('businessComputer:onAvailableRaceTypesReceived', handleRaceTypesReceived)

  // read-only: load the filter lists once so the Filters button can show its count
  if (store.businessType === 'tuningShop' && store.businessId) {
    if (!store.blacklistData) store.fetchBlacklistData?.()
    if (!store.notificationListData) store.fetchNotificationListData?.()
    if (!store.managerBlacklistData) store.fetchManagerBlacklistData?.()
  }

  const needsBrandStatus = store.brandRecognitionUnlocked === undefined || store.brandRecognitionUnlocked === null
  const needsRaceStatus = store.raceRecognitionUnlocked === undefined || store.raceRecognitionUnlocked === null
  
  if (needsBrandStatus || needsRaceStatus) {
    await Promise.all([
      needsBrandStatus ? store.updateBrandRecognitionStatus() : Promise.resolve(),
      needsRaceStatus ? store.updateRaceRecognitionStatus() : Promise.resolve()
    ])
  }
  
  const needsBrandSelection = store.brandRecognitionUnlocked && store.brandSelection === null
  const needsRaceSelection = store.raceRecognitionUnlocked && store.raceSelection === null
  
  if (needsBrandSelection || needsRaceSelection) {
    await Promise.all([
      needsBrandSelection ? store.getBrandSelection() : Promise.resolve(),
      needsRaceSelection ? store.getRaceSelection() : Promise.resolve()
    ])
  }
})

onUnmounted(() => {
  events.off('businessComputer:onAvailableBrandsReceived', handleBrandsReceived)
  events.off('businessComputer:onAvailableRaceTypesReceived', handleRaceTypesReceived)
})

watch(() => store.brandRecognitionUnlocked, async (unlocked) => {
  if (unlocked && store.brandSelection === null) {
    await store.getBrandSelection()
  }
})

watch(() => store.raceRecognitionUnlocked, async (unlocked) => {
  if (unlocked && store.raceSelection === null) {
    await store.getRaceSelection()
  }
})

const penaltyCost = computed(() => {
  if (!jobToAbandon.value) return 0
  return jobToAbandon.value.penalty || 0
})

const pullOutDiag = (...args) => {
  try {
    console.debug("[rlsBizPull]", ...args)
  } catch (_) {}
}

const findVehicleForJob = (job) => {
  if (!Array.isArray(store.vehicles)) {
    pullOutDiag("Jobs findVehicleForJob: vehicles not array", { jobId: job?.jobId ?? job?.id })
    return null
  }
  const sv = normalizeId(job?.storedVehicleId)
  if (sv !== null) {
    const byStored = store.vehicles.find(vehicle => normalizeId(vehicle?.vehicleId) === sv)
    if (byStored) return byStored
  }
  const jobId = normalizeId(job?.jobId ?? job?.id)
  if (jobId === null) {
    pullOutDiag("Jobs findVehicleForJob: no job id", { job })
    return null
  }
  return store.vehicles.find(vehicle => {
    if (!vehicle.jobId) return false
    return normalizeId(vehicle.jobId) === jobId
  }) || null
}

const handlePullOut = async (job) => {
  const vehicle = findVehicleForJob(job)
  if (!vehicle) {
    pullOutDiag("Jobs handlePullOut abort: no vehicle (Lua pullOut never called)", {
      jobId: job?.jobId ?? job?.id,
      storedVehicleId: job?.storedVehicleId,
      fleetCount: Array.isArray(store.vehicles) ? store.vehicles.length : -1,
    })
    return
  }
  pullOutDiag("Jobs handlePullOut calling store.pullOutVehicle", { jobId: job?.jobId ?? job?.id, vehicleId: vehicle.vehicleId })
  await store.pullOutVehicle(vehicle.vehicleId)
}

const handlePutAway = async (job) => {
  const vehicle = findVehicleForJob(job)
  await store.putAwayVehicle(vehicle?.vehicleId)
}

const handleAbandon = (job) => {
  if (!job) return
  jobToAbandon.value = job
  showAbandonModal.value = true
}

const jobIdForAction = (job) => {
  const raw = job?.jobId ?? job?.id ?? job?.job_id
  if (raw === undefined || raw === null || raw === '') return undefined
  // Prefer numbers for Lua bridge: string job ids are received as 0 in GE Lua
  if (typeof raw === 'number' && Number.isFinite(raw)) return raw
  if (typeof raw === 'string' && /^\d+$/.test(raw.trim())) return Number(raw.trim())
  return String(raw)
}

const confirmAbandon = async () => {
  if (jobToAbandon.value) {
    await store.abandonJob(jobIdForAction(jobToAbandon.value))
    showAbandonModal.value = false
    jobToAbandon.value = null
  }
}

const cancelAbandon = () => {
  showAbandonModal.value = false
  jobToAbandon.value = null
}

const handleComplete = async (job) => {
  const jobId = job.jobId ?? parseInt(job.id)
  await store.completeJob(jobId)
}

const handleAccept = async (job) => {
  await store.acceptJob(jobIdForAction(job))
}

const handleDecline = async (job) => {
  await store.declineJob(jobIdForAction(job))
}

</script>

<style scoped lang="scss">
@import "../../styles/rlsHouse.scss";

.jobs-tab {
  display: flex;
  flex-direction: column;
  gap: 1.4em;
}

/* ---- header ---- */
.tab-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 0.75em 1em;
}

.tab-copy {
  flex: 1 1 18em;
  min-width: 0;
  display: grid;
  gap: 0.3em;

  .block-title {
    font-size: 1.45em;
    font-weight: 800;
    letter-spacing: -0.01em;
  }

  .hint {
    font-size: 0.9em;
  }
}

.count-pill {
  margin-left: 0.45em;
  font-variant-numeric: tabular-nums;
}

/* ---- section captions ---- */
.job-section {
  display: grid;
  gap: 0.7em;
}

.section-head {
  display: flex;
  align-items: center;
  gap: 0.5em;

  .caption {
    padding-top: 0.12em; // Overpass caps sit high
  }

  .pill.count {
    font-variant-numeric: tabular-nums;
  }
}

/* ---- racing team goals ---- */
.current-goal {
  gap: var(--space-3);

  .goal-head {
    display: flex;
    align-items: center;
    gap: 0.5em;

    .caption {
      padding-top: 0.12em;
    }
  }

  .goal-title {
    font-size: 1.2em;
    font-weight: 800;
    line-height: 1.2;
  }

  .goal-description {
    margin: 0;
    color: var(--muted);
    font-size: 0.92em;
    font-weight: 600;
    line-height: 1.4;
  }
}

.facts .fact-value {
  white-space: normal;
  overflow: visible;
  text-overflow: clip;
  font-variant-numeric: tabular-nums;
}

.completed-goals {
  padding-top: 0.2em;
  padding-bottom: 0.6em;

  .completed-goal {
    align-items: flex-start;
  }

  .completed-copy {
    flex: 1 1 auto;
    min-width: 0;
    display: grid;
    gap: 0.2em;

    strong {
      font-weight: 700;
      line-height: 1.25;
    }
  }

  .completed-toggle {
    justify-self: start;
  }
}

/* ---- recognition strip ---- */
.recognition {
  padding: 0.35em;
}

.recognition-facts {
  grid-template-columns: repeat(auto-fill, minmax(13em, 1fr));
  column-gap: 0.35em;
}

.recognition-fact {
  appearance: none;
  margin: 0;
  padding: 0.6em 0.75em 0.5em;
  border: 0;
  border-radius: var(--radius-thumb);
  background: transparent;
  color: inherit;
  font: inherit;
  text-align: left;
  cursor: pointer;
  transition: background-color 0.12s;

  &:hover {
    background: var(--panel-2);
  }

  @include house-focus;

  .fact-value.unset {
    color: var(--faint);
    font-weight: 600;
  }
}

/* ---- jobs ---- */
.jobs-content {
  display: flex;
  flex-direction: column;
  gap: 1.8em;
}

.jobs-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(19em, 1fr));
  gap: 1em;
}

.job-card-wrapper {
  height: 100%;
  min-width: 0;
}

/* ---- modals (teleported to body, so they carry .rls-house themselves) ---- */
.house-overlay {
  position: fixed;
  inset: 0;
  z-index: 10000;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 1em;
  background: rgba(0, 0, 0, 0.6);
}

.house-modal {
  width: min(26em, 100%);

  .money {
    font-variant-numeric: tabular-nums;
  }
}

.modal-actions {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--space-2);
  margin-top: 0.2em;

  > :only-child {
    margin-left: auto;
  }
}

.selection-modal {
  width: min(24em, 100%);
}

.selection-list {
  display: grid;
  gap: 0.1em;
  max-height: 22em;
  margin: 0 -0.35em;
  padding: 0 0.35em;
}

.selection-item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.6em;

  &:focus-visible,
  &.focus-visible {
    outline: none;
    background: rgba(255, 255, 255, 0.08);
  }

  svg {
    width: 0.9em;
    height: 0.9em;
    flex: 0 0 auto;
    fill: none;
    stroke: currentColor;
    stroke-width: 2.6;
    stroke-linecap: round;
    stroke-linejoin: round;
  }
}

.selection-empty {
  display: grid;
  gap: 0.3em;
  padding: 1em 0;
  text-align: center;
}

.modal-fade-enter-active,
.modal-fade-leave-active {
  transition: opacity 0.18s ease;

  .house-modal {
    transition: transform 0.18s ease-out;
  }
}

.modal-fade-enter-from,
.modal-fade-leave-to {
  opacity: 0;

  .house-modal {
    transform: translateY(0.6em) scale(0.98);
  }
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
