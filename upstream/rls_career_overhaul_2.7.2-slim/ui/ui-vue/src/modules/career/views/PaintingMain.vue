<!-- RLS override of the vanilla PaintingMain.vue. Script (route-mounted ack, ready gating, close) is the game's.
     The painting panel sits top-left under the screen heading; its cart moves into the ComputerWrapper side
     column (like Tuning) as the house-styled PaintShoppingCart, fed by the state Painting.vue exposes. -->
<template>
  <ComputerWrapper :path="[$translate.instant('ui.career.shared.pathPainting')]" :title="$translate.instant('ui.career.shared.pathPainting')" back @back="close">
    <Painting ref="paintingRef" no-header @ready="isPaintingReady = true" />

    <template #side>
      <PaintShoppingCart
        v-if="paintingCart"
        :active="paintingCart.active"
        :can-activate="paintingCart.canActivate"
        :changed-paint="paintingCart.changedPaint"
        :rows="paintingCart.rows"
        :total-price="paintingCart.totalPrice"
        :can-pay="paintingCart.canPay"
        @reset-paint="index => paintingRef?.resetPaint(index)"
        @apply="() => paintingRef?.apply()"
        @context-to-painting="() => paintingRef?.onContextToPainting()" />
    </template>
  </ComputerWrapper>
</template>

<script setup>
import { ref, computed, watch, nextTick } from "vue"
import { lua } from "@/bridge"
import { useRoute } from "vue-router"
import { activateRouteTargetScope } from "@/services/scopedNav/api"
import ComputerWrapper from "./ComputerWrapper.vue"
import Painting from "../components/painting/Painting.vue"
import PaintShoppingCart from "../components/painting/PaintShoppingCart.vue"
import { $translate } from "@/services/translation"

const route = useRoute()

const close = () => lua.extensions.ui_router.back()

const isPaintingReady = ref(false)

// cart state exposed by Painting.vue (display wiring only; the cart logic stays in Painting.vue)
const paintingRef = ref(null)
const paintingCart = computed(() => paintingRef.value?.cart || null)

const lastMountedAckRouteName = ref("")
let mountedAckRequestId = 0

async function notifyRouteMountedWhenReady() {
  const routeName = route.name
  if (!routeName || routeName === "unknown" || routeName === "__legacyAngular") return
  if (!isPaintingReady.value) return

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
  if (requestId !== mountedAckRequestId) return
  if (route.name !== routeName) return

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

watch(isPaintingReady, ready => {
  if (ready) notifyRouteMountedWhenReady()
})
</script>

<style scoped lang="scss">
</style>
