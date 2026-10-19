<template>
  <ComputerWrapper
    :title="$translate.instant('ui.career.shared.pathTuning')"
    @back="confirmCancel">
    <ComputerPanel
      v-bng-scoped-nav="{ scopeId: 'career-tuning', canDeactivate: tuningBack }"
      class="tuning-card rls-house"
      ref="elCard"
      v-bng-blur="1"
      v-bng-on-ui-nav:context="switchToCart"
      :active="isTuningActive">
      <!-- no inner heading: the page title already says Tuning (context still switches to the cart) -->
      <div v-if="isTuningTent && activeVehicle" class="tuning-vehicle-selector">
        <HouseButton
          v-if="showVehicleSelectorButtons"
          class="vehicle-selector-button"
          compact
          variant="quiet"
          :icon="icons.arrowLargeLeft"
          :nav-item="false"
          :disabled="switchingVehicle || savedTuneApplyInProgress || exitInProgress"
          bng-no-nav="true"
          v-bng-on-ui-nav:tab_l.asMouse
          @click="cycleVehicle(-1)">
          <BngBinding ui-event="tab_l" deviceMask="xinput" />
        </HouseButton>
        <div class="vehicle-selector-label">
          <span class="vehicle-selector-caption">Tuning vehicle</span>
          <strong>{{ switchingVehicle ? "Switching vehicle…" : activeVehicle.niceName }}</strong>
          <span v-if="switchError" class="vehicle-selector-error">{{ switchError }}</span>
        </div>
        <HouseButton
          v-if="showVehicleSelectorButtons"
          class="vehicle-selector-button"
          compact
          variant="quiet"
          :icon="icons.arrowLargeRight"
          :nav-item="false"
          :disabled="switchingVehicle || savedTuneApplyInProgress || exitInProgress"
          bng-no-nav="true"
          v-bng-on-ui-nav:tab_r.asMouse
          @click="cycleVehicle(1)">
          <BngBinding ui-event="tab_r" deviceMask="xinput" />
        </HouseButton>
      </div>
      <Tuning
        ref="tuningComponentRef"
        :class="{ 'vehicle-switching': switchingVehicle || savedTuneApplyInProgress }"
        :button-target="elCard && elCard.buttonsContainer"
        :close-button="false"
        house
        allow-context-nav>
        <template #before-sliders>
          <SavedTunesPanel
            :tunes="savedTunes"
            :read-only="savedTunesReadOnly"
            :error="savedTunesError"
            :busy="savedTuneApplyInProgress"
            @save="saveCurrentTune"
            @apply="applySavedTune"
            @delete="deleteSavedTune" />
        </template>
      </Tuning>
      <template #footer></template>
    </ComputerPanel>

    <template #side>
      <ShoppingCart
        :class="{ 'saved-tune-busy': savedTuneApplyInProgress }"
        v-bng-scoped-nav="{ scopeId: 'career-tuning-cart' }"
        :active="isCartActive"
        :cart-data="cartData"
        :player-money="tuningStore.shoppingData.playerMoney"
        :confirm-button-text="$translate.instant('ui.career.shared.confirm')"
        v-bng-on-ui-nav:context="switchToTuning"
        @apply="applyShopping"
        @cancel="confirmCancel"
        @remove-item="removeCartItem" />
    </template>
  </ComputerWrapper>
</template>

<script setup>
import { ref, computed, watch, nextTick, onMounted, onUnmounted } from "vue"
import { BngBinding, ACCENTS, icons } from "@/common/components/base"
import { vBngBlur, vBngScopedNav, vBngOnUiNav } from "@/common/directives"
import { lua, useBridge } from "@/bridge"
import { useRoute } from "vue-router"
import { useScopedNav, activateRouteTargetScope } from "@/services/scopedNav/api"
import { $translate } from "@/services/translation"
import { useUINavBlocker } from "@/services/uiNavTracker"

import { useTuningStore } from "@/modules/vehicleConfig/stores/tuningStore"

import ComputerWrapper from "./ComputerWrapper.vue"
import ComputerPanel from "../components/ComputerPanel.vue"
import Tuning from "@/modules/vehicleConfig/components/Tuning.vue"
import ShoppingCart from "../components/ShoppingCart.vue"
import SavedTunesPanel from "../components/SavedTunesPanel.vue"
import { refocusIfLost } from "../composables/useScreenEntryFocus"
import { HouseButton, openHousePrompt, openHouseConfirmation, openHouseMessage, openHouseProgress } from "../components/house"

const tuningStore = useTuningStore()
const route = useRoute()
const { events } = useBridge()

const uiNavBlocker = useUINavBlocker()
uiNavBlocker.ensureNoBlock(["context"])

const { switchScope, current } = useScopedNav()

const isCartActive = computed(() => current.value?.id === "career-tuning-cart")
const isTuningActive = computed(() => current.value?.id === "career-tuning")

const switchToCart = () => switchScope("career-tuning-cart")
const switchToTuning = () => switchScope("career-tuning")

// BACK from the tuning scope must run the cancel/confirm flow instead of letting
// the route back bypass tuning cleanup. Returning false stops scope deactivation.
const tuningBack = () => {
  confirmCancel()
  return false
}

const CANCEL_MESSAGE = $translate.instant("ui.career.shared.cancelShoppingMessage")
const CONFIRM_BUTTONS = [
  { label: $translate.instant("ui.common.yes"), value: true },
  { label: $translate.instant("ui.common.no"), value: false, extras: { accent: ACCENTS.secondary } },
]

const SWITCH_VEHICLE_MESSAGE = "Switch tuning vehicles?<br />Any unpurchased tuning changes on this vehicle will be discarded."
const exitInProgress = ref(false)
const savedTunes = ref([])
const savedTunesReadOnly = ref(false)
const savedTunesError = ref("")
const savedTuneApplyInProgress = ref(false)

const errorMessages = {
  unreadable_file: "The saved tunes file cannot be read. It was left untouched; saving and deleting are disabled.",
  unsupported_version: "This saved tunes file was created by an unsupported version. It was left untouched.",
  invalid_root: "The saved tunes file is invalid. It was left untouched.",
  invalid_models: "The saved tunes file has an invalid model library. It was left untouched.",
  invalid_model_group: "The saved tunes file has an invalid model entry. It was left untouched.",
  write_failed: "BeamNG could not write the saved tunes file.",
  empty_snapshot: "There are no visible tuning settings to save.",
  vehicle_respawn_failed: "The vehicle could not be reloaded for this tune preview.",
  tune_not_found: "That saved tune is no longer available.",
}

function resultError(result, fallback = "Saved tunes are unavailable.") {
  return errorMessages[result?.reason || result?.error] || fallback
}

const confirmCancel = async () => {
  if (exitInProgress.value || switchingVehicle.value || savedTuneApplyInProgress.value) return
  if (!(tuningStore.shoppingData.shoppingCart && tuningStore.shoppingData.shoppingCart.items.length) || await openHouseConfirmation(null, CANCEL_MESSAGE, CONFIRM_BUTTONS)) {
    exitInProgress.value = true
    // The backend closes the route after any applied preview has been restored.
    // Show progress immediately without adding a fixed delay to the exit path.
    openHouseProgress("", $translate.instant("ui.career.shared.pathTuning"), { indeterminate: true, cancellable: false, timeout: 3 })
    cancelShopping()
  }
}

const cartData = computed(() => {
  const cart = tuningStore.shoppingData ? tuningStore.shoppingData.shoppingCart : null
  const res = { total: 0, taxes: 0, items: [] }
  if (cart) {
    res.total = cart.total
    res.taxes = cart.taxes
    if (Array.isArray(cart.items)) {
      res.items = cart.items.map(item => ({
        type: item.type || (item.level === 1 && "item"),
        level: item.level,
        name: item.title,
        price: item.price,
        priceHide: !item.price,
        removeShow: !!item.varName,
        varName: item.varName,
      }))
    }
  }
  return res
})

const elCard = ref()
const tuningComponentRef = ref(null)

const tuningSession = ref({ vehicles: [], activeInventoryId: null, isTuningTent: false })
const switchingVehicle = ref(false)
const switchError = ref("")

const isTuningTent = computed(() => tuningSession.value.isTuningTent === true)
const tuningVehicles = computed(() => Array.isArray(tuningSession.value.vehicles) ? tuningSession.value.vehicles : [])
const activeVehicleIndex = computed(() => tuningVehicles.value.findIndex(vehicle =>
  String(vehicle.inventoryId) === String(tuningSession.value.activeInventoryId)
))
const activeVehicle = computed(() => tuningVehicles.value[activeVehicleIndex.value] || tuningVehicles.value[0] || null)
const showVehicleSelectorButtons = computed(() => tuningVehicles.value.length > 1)

async function refreshSavedTunes() {
  const result = await lua.career_modules_tuning.getSavedTunes()
  if (!result?.success) {
    savedTunes.value = []
    savedTunesReadOnly.value = true
    savedTunesError.value = resultError(result)
    return
  }
  savedTunes.value = Array.isArray(result.tunes) ? result.tunes : []
  savedTunesReadOnly.value = result.readOnly === true
  savedTunesError.value = result.readOnly ? resultError(result) : ""
}

async function saveCurrentTune() {
  if (savedTuneApplyInProgress.value || savedTunesReadOnly.value) return
  const name = await openHousePrompt("Give it a name you'll recognise in the Saved tunes list.", "Save tune", {
    // prefilled so OK works on a pad without an on-screen keyboard
    defaultValue: nextTuneName(),
    placeholder: "e.g. Track day",
    maxLength: 40,
    validate: value => typeof value === "string" && Array.from(value.trim()).length >= 1 && Array.from(value.trim()).length <= 40,
    errorMessage: "Enter a name (up to 40 characters).",
  }).catch(() => false)
  if (typeof name !== "string") return
  const snapshot = tuningComponentRef.value?.getVisibleTuneSnapshot?.()
  if (!snapshot) {
    await openHouseMessage("Saved Tunes", "The visible tuning settings could not be read.")
    return
  }

  let result = await lua.career_modules_tuning.saveTune(name, snapshot, false)
  if (result?.reason === "duplicate_name") {
    const replace = await openHouseConfirmation(
      "Replace Saved Tune?",
      `A tune named <strong>${escapeHtml(result.duplicate?.name || name.trim())}</strong> already exists for this model. Replace it?`,
      CONFIRM_BUTTONS)
    if (!replace) return
    result = await lua.career_modules_tuning.saveTune(name, snapshot, true)
  }

  if (!result?.success) {
    savedTunesError.value = resultError(result, "The tune could not be saved.")
    await openHouseMessage("Saved Tunes", savedTunesError.value)
    return
  }
  savedTunes.value = Array.isArray(result.tunes) ? result.tunes : savedTunes.value
  savedTunesError.value = ""
}

function nextTuneName() {
  const taken = new Set(savedTunes.value.map(item => String(item.name || "").trim().toLowerCase()))
  let n = savedTunes.value.length + 1
  while (taken.has(`tune ${n}`)) n++
  return `Tune ${n}`
}

async function deleteSavedTune(tune) {
  if (!tune || savedTuneApplyInProgress.value || savedTunesReadOnly.value) return
  const deletedIndex = savedTunes.value.findIndex(item => item.id === tune.id)
  const confirmed = await openHouseConfirmation(
    "Delete Saved Tune?",
    `Delete <strong>${escapeHtml(tune.name)}</strong>? This cannot be undone.`,
    [{ ...CONFIRM_BUTTONS[0], extras: { destructive: true } }, CONFIRM_BUTTONS[1]])
  if (!confirmed) return
  const result = await lua.career_modules_tuning.deleteSavedTune(tune.id)
  if (!result?.success) {
    savedTunesError.value = resultError(result, "The tune could not be deleted.")
    await openHouseMessage("Saved Tunes", savedTunesError.value)
    return
  }
  savedTunes.value = Array.isArray(result.tunes) ? result.tunes : savedTunes.value.filter(item => item.id !== tune.id)
  savedTunesError.value = ""
  // the deleted row took the focused Delete button with it: a pad moves to the tune that took its
  // place (or the one above), else to Save
  refocusIfLost(() => {
    const rows = [...document.querySelectorAll(".saved-tunes .saved-tune")]
    const row = rows[Math.min(Math.max(deletedIndex, 0), rows.length - 1)]
    return row?.querySelector("button:not([disabled])") || document.querySelector(".saved-tunes .save-btn:not([disabled]), .saved-tunes .saved-tunes-toggle")
  }, { force: true })
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;")
}

const skippedReasonLabels = {
  corrupt: "saved value is corrupt",
  missing: "setting is not provided by the installed parts",
  hidden: "setting is hidden in career tuning",
  session_blocked: "setting is not permitted in this session",
  out_of_range: "saved value is outside the installed part's range",
}

async function showSavedTuneResult(data) {
  if (!data?.success) {
    await openHouseMessage("Saved Tunes", resultError(data, "The tune preview could not be loaded."))
    return
  }
  const applied = Number(data.appliedCount) || 0
  const skipped = Number(data.skippedCount) || 0
  let message = `<strong>${escapeHtml(data.name || "Saved tune")}</strong>: ${applied} applied, ${skipped} skipped.`
  if (skipped > 0 && Array.isArray(data.skipped)) {
    message += "<ul>" + data.skipped.map(item =>
      `<li>${escapeHtml(item.label || item.name)} — ${escapeHtml(skippedReasonLabels[item.reason] || item.reason)}</li>`
    ).join("") + "</ul>"
  }
  message += "Review and purchase the cart to make this preview permanent."
  await openHouseMessage("Saved Tune Preview", message)
}

async function applySavedTune(tune) {
  if (!tune || savedTuneApplyInProgress.value || switchingVehicle.value || exitInProgress.value) return
  tuningComponentRef.value?.prepareForExternalReload?.()
  savedTuneApplyInProgress.value = true
  const result = await lua.career_modules_tuning.applySavedTune(tune.id)
  if (!result?.success && savedTuneApplyInProgress.value) {
    savedTuneApplyInProgress.value = false
    await openHouseMessage("Saved Tunes", resultError(result, "The tune preview could not be started."))
  }
}

async function onSavedTuneApplyCompleted(data) {
  if (!savedTuneApplyInProgress.value) return
  try {
    await tuningComponentRef.value?.refreshFromBackend?.()
  } catch {
    data = {success: false, reason: "vehicle_tuning_data_unavailable"}
  } finally {
    savedTuneApplyInProgress.value = false
  }
  await showSavedTuneResult(data)
}

function hasUnpurchasedChanges() {
  const cartItems = tuningStore.shoppingData?.shoppingCart?.items
  const exposedDirty = tuningComponentRef.value?.isChanged
  const slidersDirty = typeof exposedDirty === "object" && exposedDirty !== null ? exposedDirty.value : exposedDirty
  return !!(Array.isArray(cartItems) && cartItems.length) || slidersDirty === true
}

async function cycleVehicle(offset) {
  if (!isTuningTent.value || !showVehicleSelectorButtons.value || switchingVehicle.value || savedTuneApplyInProgress.value || exitInProgress.value) return false

  const currentIndex = Math.max(0, activeVehicleIndex.value)
  const nextIndex = (currentIndex + offset + tuningVehicles.value.length) % tuningVehicles.value.length
  const target = tuningVehicles.value[nextIndex]
  if (!target || String(target.inventoryId) === String(tuningSession.value.activeInventoryId)) return false

  if (hasUnpurchasedChanges() && !await openHouseConfirmation(null, SWITCH_VEHICLE_MESSAGE, CONFIRM_BUTTONS)) {
    return false
  }

  switchingVehicle.value = true
  switchError.value = ""
  try {
    const result = await lua.career_modules_tuning.switchVehicle(Number(target.inventoryId))
    if (result?.success) return false
  } catch {
    // The same feedback is appropriate for a stale vehicle and a bridge failure.
  }

  if (switchingVehicle.value) {
    switchingVehicle.value = false
    switchError.value = "That vehicle is no longer available in the tuning area."
  }
  return false
}

async function refreshTuningSession(data = null) {
  const nextSession = data || await lua.career_modules_tuning.getTuningSessionData()
  if (nextSession) tuningSession.value = nextSession
}

async function onTuningVehicleChanged(data) {
  if (!data?.success) {
    switchingVehicle.value = false
    switchError.value = "Unable to load tuning data for that vehicle."
    return
  }

  try {
    await refreshTuningSession(data)
    await tuningComponentRef.value?.refreshFromBackend?.()
    await refreshSavedTunes()
  } catch {
    switchError.value = "Unable to load tuning data for that vehicle."
  } finally {
    switchingVehicle.value = false
    // the sliders were rebuilt for the new vehicle, taking the focused one with them: a pad continues
    // on the panel's first item instead of <body>
    refocusIfLost(() => elCard.value?.$el?.querySelector?.('[bng-nav-item]:not([bng-no-nav="true"]):not([disabled]), button:not([disabled]):not([bng-no-nav="true"])'))
  }
}

const applyShopping = () => !savedTuneApplyInProgress.value && lua.career_modules_tuning.applyShopping()
const cancelShopping = () => lua.career_modules_tuning.cancelShopping()
const removeCartItem = (item) => !savedTuneApplyInProgress.value && lua.career_modules_tuning.removeVarFromShoppingCart(item.varName)

// Tuning buckets arrive from Lua after mount. Delay the manual routeMounted ack
// and scope activation until the data is present and rendered so the tuning
// autofocus target lands on a navigable entry.
const isTuningReady = computed(() => !!tuningStore.buckets && Object.keys(tuningStore.buckets).length > 0)

const lastMountedAckRouteName = ref("")
let mountedAckRequestId = 0

async function notifyRouteMountedWhenReady() {
  const routeName = route.name
  if (!routeName || routeName === "unknown" || routeName === "__legacyAngular") return
  if (!isTuningReady.value) return

  const requestId = ++mountedAckRequestId
  await nextTick()

  if (typeof window !== "undefined" && typeof window.requestAnimationFrame === "function") {
    await new Promise(resolve => window.requestAnimationFrame(() => resolve()))
  }

  if (requestId !== mountedAckRequestId) return
  if (route.name !== routeName) return
  const canonicalRoute = window.__luaRouter__?._pendingCanonicalRoute || routeName
  if (lastMountedAckRouteName.value === canonicalRoute) return

  const result = await lua.extensions.ui_router.routeMounted(canonicalRoute)
  if (requestId !== mountedAckRequestId) return
  if (route.name !== routeName) return
  if (!result?.success) return

  lastMountedAckRouteName.value = canonicalRoute
  if (window.__luaRouter__) window.__luaRouter__._pendingCanonicalRoute = null

  activateRouteTargetScope()
}

watch(
  () => route.fullPath,
  () => {
    lastMountedAckRouteName.value = ""
    notifyRouteMountedWhenReady()
  },
  { immediate: true }
)

watch(isTuningReady, ready => {
  if (ready) notifyRouteMountedWhenReady()
})

onMounted(() => {
  events.on("careerTuningVehicleChanged", onTuningVehicleChanged)
  events.on("careerSavedTuneApplyCompleted", onSavedTuneApplyCompleted)
  events.on("tuningRequestExit", confirmCancel)
  Promise.all([refreshTuningSession(), refreshSavedTunes()]).catch(() => {
    switchError.value = "Unable to load vehicles in the tuning area."
  })
})

onUnmounted(() => {
  events.off("careerTuningVehicleChanged", onTuningVehicleChanged)
  events.off("careerSavedTuneApplyCompleted", onSavedTuneApplyCompleted)
  events.off("tuningRequestExit", confirmCancel)
})
</script>

<style scoped lang="scss">
@import "../styles/rlsHouse.scss";

// Root is ComputerPanel: `.tuning-card.computer-panel` outranks its scoped surface rules.
.tuning-card.computer-panel {
  // ComputerPanel defaults to height: fit-content via --bng-card-height.
  // Without this, Live Wheel Data grows the panel and clips Apply/toggles.
  --bng-card-height: 100%;
  overflow: hidden;
  // resolution-scaled em (like the cart beside it): a 40% width squeezed it to ~285px at 1280x720
  // (tune names cut to "Trai…") and the rem text went tiny at 2560x1440
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  width: min(36em, 100%);
  height: 100%;
  max-height: 100%;
  color: #fff;
  background-color: rgba(21, 21, 23, 0.92);
  border-bottom: 0;
  border-radius: var(--radius-control);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);

  &.panel-inactive-controller {
    background-color: rgba(21, 21, 23, 0.82);
    :deep(.heading::before) {
      background: rgba(255, 255, 255, 0.3);
    }
  }

  &:deep(.panel-content) {
    background-color: rgba(0, 0, 0, 0);
    flex: 1 1 0;
    height: auto;
    min-height: 0;
    max-height: 100%;
    overflow: hidden;
  }

  &:deep(.innerTuningCard) {
    flex: 1 1 0;
    min-height: 0;
    max-height: 100%;
    height: 100%;
    overflow: hidden;
  }
}

// ---- vehicle selector (tuning tent)
.tuning-vehicle-selector {
  flex: 0 0 auto;
  display: flex;
  align-items: stretch;
  min-height: 3.5em;
  margin: 0.35em var(--inset) 0;
  overflow: hidden;
  color: #fff;
  background: var(--panel);
  border-radius: var(--radius-panel);
}

// compact quiet HouseButtons that fill the selector's height
.vehicle-selector-button {
  flex: 0 0 auto;
  min-width: 3em;
  border-radius: 0;
}

.vehicle-selector-label {
  flex: 1 1 auto;
  min-width: 0;
  display: flex;
  flex-direction: column;
  justify-content: center;
  gap: 0.15em;
  padding: 0.5em 0.75em 0.4em;
  text-align: center;

  strong {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-weight: 700;
    line-height: 1.2;
  }
}

.vehicle-selector-caption {
  color: var(--faint);
  font-size: 0.72em;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.08em;
}

.vehicle-selector-error {
  color: var(--bad);
  font-size: 0.8em;
  font-weight: 600;
}

.vehicle-switching {
  opacity: 0.45;
  pointer-events: none;
}

.saved-tune-busy {
  opacity: 0.45;
  pointer-events: none;
}

// Tuning.vue's rows, captions, scrollbar and bottom bar are house-styled by its `house` prop.
</style>
