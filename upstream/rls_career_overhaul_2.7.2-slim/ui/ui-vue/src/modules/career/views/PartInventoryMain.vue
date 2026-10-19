<template>
  <ComputerWrapper ref="wrapper" :path="[$translate.instant('ui.career.shared.pathPartInventory')]" :title="$translate.instant('ui.career.shared.pathPartInventory')" back @back="close">
    <PartList class="part-inventory" @partSold="updateCareerStatus" />

    <!-- Tabs are shown in infobar because they are tracked events by crossfire.
     This is a hack to prevent them from displaying in the infobar -->
    <BngBinding v-show="false" ui-event="tab_l" controller />
    <BngBinding v-show="false" ui-event="tab_r" controller />
  </ComputerWrapper>
</template>

<script setup>
import { computed, onUnmounted, ref, watch, markRaw, nextTick } from "vue"
import { BngBinding } from "@/common/components/base"

import { $translate } from "@/services/translation"
import { lua } from "@/bridge"
import { useRoute } from "vue-router"
import { activateRouteTargetScope } from "@/services/scopedNav/api"
import { usePartInventoryStore } from "../stores/partInventoryStore"

import ComputerWrapper from "./ComputerWrapper.vue"
import PartList from "../components/partInventory/PartList.vue"
import PartInventoryAddedParts from "../components/partInventory/PartInventoryAddedParts.vue"
import { openHouseMessage } from "../components/house"

const wrapper = ref()

const partInventoryStore = usePartInventoryStore()

const route = useRoute()

// display repair popup when required
watch(
  () => partInventoryStore.newPartsPopupOpen,
  (newVal, oldVal) => newVal && confirmAddedParts()
)

const confirmAddedParts = async vehicle => {
  await openHouseMessage("", { component: markRaw(PartInventoryAddedParts), props: { parts: partInventoryStore.newParts } })
  closeNewPartsPopup()
}

const updateCareerStatus = () => {
  wrapper.value.statusUpdate()
}

// Inventory data arrives from Lua via the `partInventoryData` guihook, but that
// only happens after Lua's `onRouteMount` runs, which itself only fires once we
// ack the rendered shell with `routeMounted`. Gating the ack on the data would
// deadlock (no ack -> no onRouteMount -> no data -> no ack), so the ack runs as
// soon as the shell renders, and scope activation waits for the data to render.
const isInventoryReady = computed(() => !!partInventoryStore.partInventoryData?.partList)

const lastMountedAckRouteName = ref("")
let mountedAckRequestId = 0

// Phase 1: acknowledge the rendered shell so Lua `onRouteMount` runs and emits
// the initial `partInventoryData`. Must not wait for the data.
async function notifyRouteMounted() {
  const routeName = route.name
  if (!routeName || routeName === "unknown" || routeName === "__legacyAngular") return

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
  lastMountedAckRouteName.value = canonicalRoute
  if (!result?.success) return
  if (window.__luaRouter__) window.__luaRouter__._pendingCanonicalRoute = null

  // Data may already be present on fast re-entry; try activating right away.
  activateInventoryScopeWhenReady()
}

// Phase 2: once the list data is present and rendered, activate the route's
// target scope so autofocus lands on a real list entry. Only runs after the
// shell has been acknowledged.
let scopeActivationRequestId = 0
async function activateInventoryScopeWhenReady() {
  if (!isInventoryReady.value) return
  if (!lastMountedAckRouteName.value) return

  const requestId = ++scopeActivationRequestId
  const routeName = route.name
  await nextTick()

  if (typeof window !== "undefined" && typeof window.requestAnimationFrame === "function") {
    await new Promise(resolve => window.requestAnimationFrame(() => resolve()))
  }

  if (requestId !== scopeActivationRequestId) return
  if (route.name !== routeName) return

  activateRouteTargetScope()
}

watch(
  () => route.fullPath,
  () => {
    lastMountedAckRouteName.value = ""
    notifyRouteMounted()
  },
  { immediate: true }
)

watch(isInventoryReady, ready => {
  if (ready) activateInventoryScopeWhenReady()
})

const kill = () => {
  partInventoryStore.partInventoryClosed()
  partInventoryStore.$dispose()
}

onUnmounted(kill)

const close = () => {
  partInventoryStore.closeMenu()
}

const closeNewPartsPopup = () => {
  partInventoryStore.closeNewPartsPopup()
}
</script>

<style scoped lang="scss">
.partListCard {
  width: 50%;
  overflow-y: hidden;
  height: 100vh;
  padding: 10px;
  color: white;
  background-color: rgba(0, 0, 0, 0.9);
  & :deep(.card-cnt) {
    background-color: rgba(0, 0, 0, 0.2);
  }
}

.innerList {
  height: 95vh;
  overflow-y: scroll;
  padding: 20px;
}

// RLS override: same as vanilla apart from sizing. The list card (PartList, also overridden) carries
// the house look and an em font-size that follows the viewport, so the minimum width scales with it.
.part-inventory {
  width: 60%;
  min-width: min(40em, 100%);
  max-width: 100%;
  height: 100%;
  min-height: 0;
  :deep(.list-content) {
    min-height: 40vh;
  }
}
</style>
