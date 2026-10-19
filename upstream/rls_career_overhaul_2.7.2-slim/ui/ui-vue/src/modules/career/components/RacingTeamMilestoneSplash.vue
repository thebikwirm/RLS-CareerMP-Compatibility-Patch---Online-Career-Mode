<template>
  <Teleport to="body">
    <transition name="rt-promo-fade" @after-enter="entered = true">
      <!-- Controller: a trapping scope with focus on Continue, active once the fade-in is done (at opacity 0
           nothing in it counts as focusable); the splash has one action, so A and B / Start all continue
           (the Lua side expects that call to move on) -->
      <div
        v-if="open"
        class="rt-promo-overlay"
        role="dialog"
        aria-modal="true"
        v-bng-scoped-nav="{ activated: entered, trapPolicy: 'always', canDeactivate: () => (onContinue(), false) }"
        v-bng-on-ui-nav:menu="onContinue"
        @click.stop
      >
        <RacingTeamPromoPanel
          :title="title"
          :body="body"
          :image-url="imageUrl"
          @click.stop
        >
          <button
            v-if="continueHandler"
            type="button"
            class="btn btn-primary"
            bng-nav-item
            bng-scoped-nav-autofocus
            @click="onContinue"
          >
            <BngBinding class="btn-glyph" ui-event="ok" controller track-ignore />
            {{ continueLabel }}
          </button>
        </RacingTeamPromoPanel>
      </div>
    </transition>
  </Teleport>
</template>

<script setup>
import { ref, computed, onMounted, onBeforeUnmount } from "vue"
import { useBridge, lua } from "@/bridge"
import { BngBinding } from "@/common/components/base"
import { vBngOnUiNav, vBngScopedNav } from "@/common/directives"
import RacingTeamPromoPanel from "./RacingTeamPromoPanel.vue"

const bridge = useBridge()
const open = ref(false)
const payload = ref(null)

const kind = computed(() => (payload.value && payload.value.kind) || "")
const title = computed(() => (payload.value && payload.value.title) || "")
const body = computed(() => (payload.value && payload.value.body) || "")
const imageUrl = computed(() => (payload.value && payload.value.imageUrl) || "")
const continueLabel = computed(() => (payload.value && payload.value.continueLabel) || "Continue")

const businessIdStr = computed(() => {
  const b = payload.value && payload.value.businessId
  return b != null && b !== "" ? String(b) : null
})

const entered = ref(false)

const close = () => {
  entered.value = false
  open.value = false
  payload.value = null
}

const normalizeMilestonePayload = raw => {
  if (!raw || typeof raw !== "object") return null
  if (Array.isArray(raw) && raw.length > 0) {
    const first = raw[0]
    if (first && typeof first === "object" && !Array.isArray(first)) {
      return first
    }
    return null
  }
  return raw
}

const onMilestone = (...args) => {
  const raw = args.length > 0 ? args[0] : null
  const data = normalizeMilestonePayload(raw)
  if (!data || typeof data !== "object") return
  payload.value = data
  open.value = true
}

const onPurchaseContinue = async () => {
  const bid = businessIdStr.value
  if (!bid) {
    close()
    return
  }
  try {
    await lua.career_modules_business_businessComputer.racingTeamMilestonePurchaseContinue(bid)
  } catch (e) {
    /* ignore */
  }
  close()
}

const onCareerFinaleContinue = async () => {
  const bid = businessIdStr.value
  if (!bid) {
    close()
    return
  }
  try {
    await lua.career_modules_business_businessComputer.racingTeamMilestoneCareerFinaleContinue(bid)
  } catch (e) {
    /* ignore */
  }
  close()
}

const onLeague2WelcomeContinue = async () => {
  const bid = businessIdStr.value
  if (!bid) {
    close()
    return
  }
  try {
    await lua.career_modules_business_businessComputer.racingTeamMilestoneLeague2WelcomeContinue(bid)
  } catch (e) {
    /* ignore */
  }
  close()
}

// the one action per splash kind (unknown kinds show no button, as before)
const continueHandler = computed(() => ({
  purchase: onPurchaseContinue,
  league2_welcome: onLeague2WelcomeContinue,
  race_unlock: close,
  career_finale: onCareerFinaleContinue,
}[kind.value] || null))
let continuing = false
const onContinue = async () => {
  // B, Start and A can all land here; run the Lua continue once. An unknown kind just closes.
  if (continuing || !open.value) return
  continuing = true
  try {
    await (continueHandler.value || close)()
  } finally {
    continuing = false
  }
}

onMounted(() => {
  bridge.events.on("RacingTeamMilestoneSplashShow", onMilestone)
  if (typeof window !== "undefined" && window.vueEventBus && window.vueEventBus !== bridge.events) {
    window.vueEventBus.on("RacingTeamMilestoneSplashShow", onMilestone)
  }
})

onBeforeUnmount(() => {
  bridge.events.off("RacingTeamMilestoneSplashShow", onMilestone)
  if (typeof window !== "undefined" && window.vueEventBus && window.vueEventBus !== bridge.events) {
    window.vueEventBus.off("RacingTeamMilestoneSplashShow", onMilestone)
  }
})
</script>
