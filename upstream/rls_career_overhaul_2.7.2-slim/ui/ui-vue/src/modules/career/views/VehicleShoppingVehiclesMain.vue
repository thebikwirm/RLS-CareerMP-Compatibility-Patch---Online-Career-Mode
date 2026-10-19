<template>
  <ComputerWrapper
    :path="[sellerName]"
    title="Available Vehicles"
    back
    @back="close"
  >
    <template #status>
      <span class="status-note">Free slots <b>{{ store.vehicleShoppingData.numberOfFreeSlots || 0 }}</b></span>
    </template>

    <div
      v-bng-scoped-nav="{ scopeId: 'vehicle-shopping-vehicles', preferAutoFocus: true, canDeactivate: listBack }"
      class="vehicles-screen"
    >
      <VehicleList v-if="loaded" />
      <div v-else class="loading-card rls-house" v-bng-blur="1">
        <span class="hint">Please wait...</span>
      </div>
    </div>
  </ComputerWrapper>
</template>

<script setup>
import { computed, nextTick, onMounted, ref, watch } from "vue"
import { lua } from "@/bridge"
import { useRoute } from "vue-router"
import { activateRouteTargetScope } from "@/services/scopedNav/api"
import { vBngBlur, vBngScopedNav } from "@/common/directives"
import ComputerWrapper from "./ComputerWrapper.vue"
import VehicleList from "../components/vehicleShopping/VehicleList.vue"
import { useVehicleShoppingStore } from "../stores/vehicleShoppingStore"
import { closeShopDetail } from "../components/vehicleShopping/useShopVehicle"

const store = useVehicleShoppingStore()
const route = useRoute()
const loaded = computed(() => Object.keys(store.vehicleShoppingData || {}).length > 0)
const sellerName = computed(() => {
  if (store.vehicleShoppingData.currentSellerNiceName) return store.vehicleShoppingData.currentSellerNiceName
  const id = store.vehicleShoppingData.selectedSellerId || store.selectedSellerId
  const seller = (store.vehicleShoppingData.dealerships || []).find(item => String(item.id) === String(id))
  return seller?.name || "Buy Vehicles"
})

const close = () => {
  // Back on the detail page returns to the list first
  if (closeShopDetail()) return
  lua.extensions.ui_router.back()
}
// B inside the active scope runs the same back (detail page first) instead of only deactivating the
// scope, which skipped closeShopDetail and left the shop from the detail page
const listBack = () => {
  close()
  return false
}

const lastMountedAckRouteName = ref("")
let mountedAckRequestId = 0

async function notifyRouteMountedWhenReady() {
  const routeName = route.name
  if (!routeName || !loaded.value) return
  const requestId = ++mountedAckRequestId
  await nextTick()
  if (requestId !== mountedAckRequestId || route.name !== routeName) return

  const canonicalRoute = window.__luaRouter__?._pendingCanonicalRoute || routeName
  if (lastMountedAckRouteName.value === canonicalRoute) return
  const result = await lua.extensions.ui_router.routeMounted(canonicalRoute)
  lastMountedAckRouteName.value = canonicalRoute
  if (!result?.success) return
  if (window.__luaRouter__) window.__luaRouter__._pendingCanonicalRoute = null
  activateRouteTargetScope()
}

watch(() => route.fullPath, () => {
  lastMountedAckRouteName.value = ""
  notifyRouteMountedWhenReady()
}, { immediate: true })

watch(loaded, ready => {
  if (ready) notifyRouteMountedWhenReady()
})

onMounted(async () => {
  await store.requestVehicleShoppingData()
  const sellerId = store.vehicleShoppingData.currentSeller || store.vehicleShoppingData.selectedSellerId
  store.setSelectedSellerId(sellerId || "")
  await notifyRouteMountedWhenReady()
})
</script>

<style scoped lang="scss">
@import "../styles/rlsHouse.scss";

/* career status chip add-on: short and faint */
.status-note {
  color: rgba(255, 255, 255, 0.55);
  font-size: 0.88em;
  font-weight: 600;
  b {
    margin-left: 0.2em;
    color: rgba(255, 255, 255, 0.85);
    font-weight: 700;
    font-variant-numeric: tabular-nums;
  }
}

.vehicles-screen {
  display: flex;
  flex-direction: column;
  height: 100%;
  min-height: 0;
  max-width: 80rem;
}

.loading-card.rls-house {
  align-self: flex-start;
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  padding: 1.1em 1.3em 0.95em;
  border-radius: var(--radius-control);
  background: rgba(21, 21, 23, 0.92);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
  .hint {
    font-size: 0.95em;
  }
}
</style>
