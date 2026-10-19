<template>
  <div class="rls-house home-widget scheduled-races-widget" :class="{ 'home-widget--compact': compact }">
    <div class="widget-header">
      <h3>Scheduled Races</h3>
      <span v-if="scheduledRows.length" class="count-badge">{{ scheduledRows.length }}</span>
    </div>

    <div v-if="scheduledRows.length" class="widget-content">
      <ul v-if="compact" class="race-list">
        <li v-for="row in scheduledRows" :key="row.key" class="race-row">
          <div class="race-row__text">
            <span class="race-row__title">{{ row.raceTitle }}</span>
            <span class="race-row__driver">{{ row.driverName }}</span>
            <span
              v-if="row.scheduledRaceReady"
              class="race-row__meta race-row__meta--ready"
            >Ready to spectate</span>
            <span v-else-if="!row.scheduledRaceReady" class="race-row__meta">
              {{ formatWaitText(row.secondsUntilScheduledRace, row.useWallClock) }}
            </span>
          </div>
        </li>
      </ul>
      <ul v-else class="scheduled-offers-list">
        <li v-for="row in scheduledRows" :key="row.key" class="scheduled-offers-list__item">
          <RaceOfferBoardCard
            :offer="row.offer"
            :driver-name="row.driverName"
            :declining="spectateBusyId === row.driverId || dropScheduledBusyId === row.driverId"
            :primary-disabled="!row.scheduledRaceReady"
            :status-text="row.scheduledRaceReady ? '' : formatWaitText(row.secondsUntilScheduledRace, row.useWallClock)"
            primary-label="Spectate"
            secondary-label="Drop out"
            @accept="onSpectate(row.driverId)"
            @decline="onDropScheduled(row.driverId)"
          />
        </li>
      </ul>
    </div>

    <div v-else class="widget-content empty">
      <p>No races currently scheduled.</p>
      <HouseButton
        variant="primary"
        class="btn-schedule-pill"
        :class="{ 'btn-schedule-pill--compact': compact }"
        :compact="compact"
        @click="goToRaceTab"
        @mousedown.stop
      >
        Schedule a race
      </HouseButton>
    </div>
  </div>
</template>

<script setup>
import { computed, ref, onMounted, onUnmounted } from "vue"
import { lua, useBridge } from "@/bridge"
import { useBusinessComputerStore } from "../../../stores/businessComputerStore"
import RaceOfferBoardCard from "../RaceOfferBoardCard.vue"
import { HouseButton } from "../../house"

const props = defineProps({
  compact: { type: Boolean, default: false },
})

const emit = defineEmits(["open-tab"])

const store = useBusinessComputerStore()
const { events } = useBridge()

const isOutOfSpecErr = (err) => {
  const e = String(err || "")
  return e === "fleet_hp_over_class_max" || e === "fleet_hp_under_class_min" || e === "fleet_hp_bracket_mismatch"
}

const spectateBusyId = ref(null)

const dropScheduledBusyId = ref(null)

/** Wall epoch ticks in real time while menus are open; sim clock may be paused. */
const scheduleUiSecondTick = ref(0)
let scheduleUiTimer = null
onMounted(() => {
  scheduleUiTimer = setInterval(() => {
    scheduleUiSecondTick.value++
  }, 1000)
})
onUnmounted(() => {
  if (scheduleUiTimer) {
    clearInterval(scheduleUiTimer)
    scheduleUiTimer = null
  }
})

const remainingSecondsForScheduledDriver = (t) => {
  const pr = t?.pendingRaceOffer
  const wallDue = Number(pr?.scheduledRaceReadyWallEpoch ?? t?.scheduledRaceReadyWallEpoch)
  void scheduleUiSecondTick.value
  if (Number.isFinite(wallDue)) {
    return Math.max(0, wallDue - Math.floor(Date.now() / 1000))
  }
  const due = Number(t.scheduledRaceSimTime)
  const now = Number(store.racingTeamCareerSimTime)
  if (Number.isFinite(due) && Number.isFinite(now)) {
    return Math.max(0, Math.floor(due - now))
  }
  const fallback = Number(t.secondsUntilScheduledRace)
  if (Number.isFinite(fallback)) {
    return Math.max(0, Math.floor(fallback))
  }
  return null
}

const scheduledRows = computed(() => {
  void store.racingTeamCareerSimTime
  void scheduleUiSecondTick.value
  const list = store.techs
  if (!Array.isArray(list)) return []
  const rows = []
  for (const t of list) {
    if (!t || t.fired || !t.pendingRaceOffer) continue
    const pr = t.pendingRaceOffer
    const useWallClock = Number.isFinite(Number(pr.scheduledRaceReadyWallEpoch ?? t.scheduledRaceReadyWallEpoch))
    const remaining = remainingSecondsForScheduledDriver(t)
    rows.push({
      key: `d-${t.id}-${pr.id ?? ""}`,
      driverId: t.id,
      driverName: t.name || `Driver #${t.id}`,
      raceTitle: pr.raceLabel || pr.raceName || "Race",
      offer: pr,
      scheduledRaceReady: remaining !== null ? remaining <= 0 : t.scheduledRaceReady === true,
      secondsUntilScheduledRace: remaining ?? 0,
      useWallClock,
    })
  }
  return rows
})

const formatWaitText = (seconds, useWallClock) => {
  if (!useWallClock && (store.racingTeamCareerSimTime === null || store.racingTeamCareerSimTime === undefined)) {
    if (Number.isFinite(seconds) && seconds > 0) {
      const s = Math.max(0, Math.floor(seconds))
      const minutes = Math.floor(s / 60)
      const secs = s % 60
      return minutes > 0 ? `Ready in ~${minutes}m ${secs}s (syncing…)` : `Ready in ~${secs}s (syncing…)`
    }
    return "Syncing countdown…"
  }
  if (!Number.isFinite(seconds) || seconds <= 0) return "Not ready yet"
  const s = Math.max(0, Math.floor(seconds))
  const minutes = Math.floor(s / 60)
  const secs = s % 60
  if (minutes > 0) {
    return `Ready in ${minutes}m ${secs}s`
  }
  return `Ready in ${secs}s`
}

const goToRaceTab = () => {
  emit("open-tab")
  if (!props.compact) {
    store.switchView("race")
  }
}

const spectateErr = (err) => {
  const m = {
    no_pending_race_offer: "No scheduled race on that driver.",
    race_not_scheduled_yet: "Race time not reached yet.",
    invalid_driver: "Invalid driver.",
    no_valid_fleet_vehicle: "Driver needs a fleet vehicle.",
    missing_business_or_driver: "Missing business or driver.",
    no_business: "No business selected.",
    fleet_hp_over_class_max: "Fleet car is too powerful for this race class.",
    fleet_hp_under_class_min: "Fleet car is below the minimum HP for this race class.",
    fleet_hp_bracket_mismatch: "Fleet car does not match the race HP class.",
    lua_error: "Something went wrong.",
    no_proxy_flow: "Race flow extension is not ready. Restart the game or verify the mod install.",
    no_staging_spot: "No track staging spot (player_stage_track) on this map.",
    no_inventory: "Business inventory is not available.",
    teleport_failed: "Could not place the team car at staging.",
    enter_vehicle_failed: "Could not switch you into the team car.",
    begin_failed: "Staging did not complete. Check the log.",
    unknown_error: "Could not spectate (no error detail from the game).",
  }
  return m[err] || (err ? String(err) : "Could not spectate.")
}

const dropScheduledErr = (err) => {
  const m = {
    no_pending_race_offer: "No scheduled race on that driver.",
    missing_business_or_driver: "Missing business or driver.",
    no_business: "No business selected.",
    no_racing_team: "Racing team module is not available.",
    lua_error: "Something went wrong.",
  }
  return m[err] || (err ? String(err) : "Could not drop out.")
}

const onDropScheduled = async (driverId) => {
  if (driverId === undefined || driverId === null) return
  dropScheduledBusyId.value = driverId
  try {
    const res = await store.cancelRacingTeamProxyScheduledRace(driverId)
    if (res && res.ok) {
      await store.loadBusinessData(store.businessType, store.businessId)
      try {
        lua.ui_message("Scheduled team race withdrawn. Entry fee refunded when applicable.", 7, "Racing Team", "info")
      } catch (e) {
      }
    } else if (res && res.err) {
      try {
        lua.ui_message(dropScheduledErr(res.err), 5, "Racing Team", "error")
      } catch (e) {
      }
    }
  } finally {
    dropScheduledBusyId.value = null
  }
}

const onSpectate = async (driverId) => {
  if (driverId === undefined || driverId === null) return
  spectateBusyId.value = driverId
  try {
    const res = await store.simulateRacingTeamProxyRace({ driverId })
    if (res && res.ok === true) {
      await store.loadBusinessData(store.businessType, store.businessId)
      try {
        lua.ui_message(
          "Team race spectate starting from the grid. Returning to gameplay.",
          8,
          "Racing Team",
          "info"
        )
      } catch (e) {
      }
      if (store.exitBusinessComputerToPlay) {
        store.exitBusinessComputerToPlay()
      }
      return
    }
    const err = res && res.err ? res.err : "unknown_error"
    let showOos = isOutOfSpecErr(err)
    if (!showOos) {
      try {
        const chk = await store.isProxyScheduledDriverFleetOverpowered(driverId)
        showOos = !!(chk && chk.overpowered)
      } catch (e) {
      }
    }
    if (showOos) {
      events.emit("racingTeam:vehicleOutOfClass")
      return
    }
    try {
      lua.ui_message(spectateErr(err), 5, "Racing Team", "error")
    } catch (e) {
    }
  } finally {
    spectateBusyId.value = null
  }
}
</script>

<style scoped lang="scss">
@import "../../../styles/rlsHouse.scss";

.home-widget {
  display: flex;
  flex-direction: column;
  min-height: 8em;
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

.count-badge {
  color: var(--faint);
  font-size: 0.85em;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
}

.widget-content {
  flex: 1;
  padding: 0.15em var(--inset) var(--inset);

  &.empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 0.7em;
    min-height: 6em;
    text-align: center;
    color: var(--muted);

    p {
      margin: 0;
      font-weight: 600;
    }
  }
}

.scheduled-offers-list {
  list-style: none;
  margin: 0;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: 0.6em;
}

.scheduled-offers-list__item {
  min-width: 0;
}

.race-list {
  list-style: none;
  margin: 0;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: 0.35em;
}

.race-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.65em;
  padding: 0.55em 0.7em 0.45em;
  border-radius: var(--radius-panel);
  background: var(--panel);
}

.race-row__text {
  display: grid;
  gap: 0.15em;
  min-width: 0;
  flex: 1;
}

.race-row__title {
  font-weight: 700;
  color: #fff;
  line-height: 1.2;
}

.race-row__driver {
  font-size: 0.85em;
  font-weight: 600;
  color: var(--muted);
}

.race-row__meta {
  font-size: 0.78em;
  font-weight: 600;
  color: var(--faint);
  font-variant-numeric: tabular-nums;
}

.race-row__meta--ready {
  color: var(--ok);
  font-weight: 700;
}

.home-widget--compact {
  min-height: 0;
  flex-shrink: 0;
  height: auto;

  .widget-header {
    padding: 0.42em 0.55em;
  }

  .count-badge {
    font-size: 0.72em;
  }

  .widget-content {
    padding: 0.2em 0.55em 0.5em;

    &.empty {
      min-height: 0;
      gap: 0.4em;
      font-size: 0.8em;
    }
  }

  .race-list {
    gap: 0.3em;
  }

  .race-row {
    padding: 0.35em 0.45em 0.3em;
  }

  .race-row__title {
    font-size: 0.82em;
  }

  .race-row__driver,
  .race-row__meta {
    font-size: 0.72em;
  }
}
</style>
