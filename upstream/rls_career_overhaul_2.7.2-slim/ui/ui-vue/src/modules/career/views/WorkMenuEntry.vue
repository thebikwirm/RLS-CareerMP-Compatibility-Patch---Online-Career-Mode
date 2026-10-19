<!-- Hand-off screen while the Job Broker opens (cargo overview / my cargo). House card; same calls. -->
<template>
  <!-- B / Start leave at any time; when dispatch fails, Back takes focus so A works too -->
  <div class="work-entry rls-house" bng-ui-scope="workMenuEntry" v-bng-on-ui-nav:back,menu="back">
    <main class="entry-card">
      <span class="caption">Job Broker</span>
      <h1>{{ failed ? "Dispatch unavailable" : "Opening work…" }}</h1>
      <p v-if="failed" class="hint">Return and try again.</p>
      <HouseButton ref="backBtn" :variant="failed ? 'primary' : 'quiet'" binding="back" @click="back">Back</HouseButton>
    </main>
  </div>
</template>
<script setup>
import { onMounted, ref, watch } from 'vue'
import { lua } from '@/bridge'
import { vBngOnUiNav } from '@/common/directives'
import { useUINavScope } from '@/services/uiNav'
import { HouseButton } from '../components/house'
import { refocusIfLost } from '../composables/useScreenEntryFocus'
useUINavScope('workMenuEntry')
const props = defineProps({ facilityId: String, parkingSpotPath: String })
const failed = ref(false)
const backBtn = ref(null)
const back = () => lua.guihooks.trigger('ChangeState', { state: 'play' })
watch(failed, isFailed => { if (isFailed) refocusIfLost(() => backBtn.value?.$el) }, { flush: 'post' })
onMounted(async () => {
  try {
    if (props.facilityId) await lua.career_modules_delivery_cargoScreen.enterCargoOverviewScreen(props.facilityId, props.parkingSpotPath || null)
    else await lua.career_modules_delivery_cargoScreen.enterMyCargo()
  } catch (error) {
    failed.value = true
    console.error('[work-entry] dispatch failed', error)
  }
})
</script>
<style scoped lang="scss">
@import "../styles/rlsHouse.scss";

.work-entry {
  position: absolute;
  inset: 0;
  display: grid;
  place-items: center;
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  color: #fff;
  background: rgba(5, 8, 10, 0.55);
}
.entry-card {
  display: grid;
  justify-items: start;
  gap: 0.5em;
  min-width: 20em;
  padding: 1.1em 1.2em 1em;
  border-radius: var(--radius-control);
  background: rgba(21, 21, 23, 0.95);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
  h1 {
    margin: 0;
    font-size: 1.35em;
    font-weight: 800;
  }
  .hint {
    margin: 0;
  }
  .house-button {
    margin-top: 0.4em;
    justify-self: end;
  }
}
</style>
