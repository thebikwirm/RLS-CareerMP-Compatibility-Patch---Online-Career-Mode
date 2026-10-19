<template>
  <Teleport to="body">
    <Transition name="journal-prompt" @after-enter="entered = true">
      <!-- Controller: shown while driving, so the prompt is its own trapping nav scope once it has faded in
           (nothing at opacity 0 counts as focusable), focus on Enter Photo Scene, B / Start = Continue
           Driving. The old back,menu.asMouse turned the handler into a synthetic click, so B did nothing. -->
      <div
        v-if="prompt.visible"
        class="prompt-backdrop"
        v-bng-scoped-nav="{ ...navScope, activated: entered }"
        v-bng-on-ui-nav:menu="dismiss"
      >
      <section class="prompt-card" aria-modal="true" role="dialog" aria-labelledby="travel-journal-prompt-title">
        <span class="eyebrow">Travel Journal</span>
        <h1 id="travel-journal-prompt-title">Ready for Photo Mode</h1>
        <p class="location-name">{{ prompt.locationName }}</p>
        <p class="description">{{ prompt.firstDiscovery ? 'Location discovered. ' : '' }}Park here to enter the curated photography scene.</p>
        <p v-if="error" class="error">{{ error }}</p>
        <div class="prompt-actions">
          <BngButton :accent="ACCENTS.main" :disabled="busy" :bng-no-nav="busy ? 'true' : null" bng-scoped-nav-autofocus @click="enterScene">
            <BngBinding :action="prompt.action || 'gameplay_interact'" show-unassigned />
            {{ busy ? 'Opening...' : 'Enter Photo Scene' }}
          </BngButton>
          <BngButton :accent="ACCENTS.secondary" :disabled="busy" :bng-no-nav="busy ? 'true' : null" @click="dismiss">
            <BngBinding ui-event="back" controller track-ignore />
            Continue Driving
          </BngButton>
        </div>
      </section>
      </div>
    </Transition>
  </Teleport>
</template>

<script setup>
import { onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import { BngBinding, BngButton, ACCENTS } from '@/common/components/base'
import { vBngOnUiNav, vBngScopedNav } from '@/common/directives'
import { useBridge } from '@/bridge'
import { runRaw, serialize } from '@/bridge/libs/Lua'

const bridge = useBridge()
const prompt = reactive({
  visible: false,
  mapId: '',
  locationId: '',
  locationName: '',
  action: 'gameplay_interact',
  firstDiscovery: false,
})
const busy = ref(false)
const error = ref('')
const entered = ref(false)
let enterFallbackTimer = 0
watch(() => prompt.visible, visible => {
  clearTimeout(enterFallbackTimer)
  if (!visible) {
    entered.value = false
    return
  }
  // after-enter needs animation frames; if the fade never runs (UI hidden, frames throttled) the scope
  // would never activate, so arm it once the 0.16 s fade is surely over
  enterFallbackTimer = setTimeout(() => { if (prompt.visible) entered.value = true }, 300)
})
onBeforeUnmount(() => clearTimeout(enterFallbackTimer))
// trapPolicy always: while it is up, presses never fall through to the game behind it. B (scope
// deactivation) dismisses instead and keeps the scope until the prompt is gone.
const navScope = {
  trapPolicy: 'always',
  canDeactivate: () => {
    dismiss()
    return false
  },
}

function updatePrompt(payload = {}) {
  if (Array.isArray(payload)) payload = payload.find(entry => entry && typeof entry === 'object') || payload[0] || {}
  prompt.visible = payload.visible === true
  prompt.mapId = payload.mapId || ''
  prompt.locationId = payload.locationId || ''
  prompt.locationName = payload.locationName || 'Scenic location'
  prompt.action = payload.action || 'gameplay_interact'
  prompt.firstDiscovery = payload.firstDiscovery === true
  busy.value = false
  error.value = ''
}

function sceneFailureMessage(reason) {
  const messages = {
    scene_active: 'A Travel Journal photography scene is already active.',
    app_not_installed: 'Install Travel Journal before entering this scene.',
    wrong_map: 'This Travel Journal location is no longer on the current map.',
    activity_blocked: 'Finish the current activity before entering this scene.',
    content_missing: 'This location is missing its parking spot or scenic zone.',
    outside_zone: 'Park inside the scenic area before entering this scene.',
    trailer_attached: 'Detach the trailer before entering this scene.',
    location_changed: 'The selected Travel Journal location changed.',
    not_ready: 'Reopen this location from its parking marker.',
  }
  return messages[reason] || 'The photography scene could not be opened.'
}

async function enterScene() {
  if (busy.value || !prompt.mapId || !prompt.locationId) return
  busy.value = true
  error.value = ''
  try {
    const result = await runRaw(`gameplay_travelJournal.enterPromptedScene(${serialize(prompt.mapId)}, ${serialize(prompt.locationId)})`)
    if (!result?.success) {
      error.value = sceneFailureMessage(result?.reason)
      busy.value = false
    }
  } catch (_) {
    error.value = 'The photography scene could not be opened.'
    busy.value = false
  }
}

async function dismiss() {
  if (busy.value) return
  prompt.visible = false
  try {
    await runRaw('gameplay_travelJournal.dismissScenePrompt()')
  } catch (_) {
    // It is already hidden locally; the parking marker can reopen it immediately.
  }
}

onMounted(() => {
  bridge.events.on('TravelJournalScenePrompt', updatePrompt)
  if (typeof window !== 'undefined' && window.vueEventBus && window.vueEventBus !== bridge.events) {
    window.vueEventBus.on('TravelJournalScenePrompt', updatePrompt)
  }
})
onBeforeUnmount(() => {
  bridge.events.off('TravelJournalScenePrompt', updatePrompt)
  if (typeof window !== 'undefined' && window.vueEventBus && window.vueEventBus !== bridge.events) {
    window.vueEventBus.off('TravelJournalScenePrompt', updatePrompt)
  }
})
</script>

<style scoped lang="scss">
.prompt-backdrop {
  // scaled unit: same share of the screen at 720p..4K (rem/px-sized it shrank at 1440p), still following
  // the player's UI scale
  --rls-u: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  font-size: var(--rls-u, 1rem);
  position: fixed;
  inset: 0;
  z-index: 1500;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: calc(2 * var(--rls-u, 1rem));
  pointer-events: auto;
  background: rgba(10, 9, 8, 0.42);
  backdrop-filter: blur(2px);
}

.prompt-card {
  width: min(calc(36 * var(--rls-u, 1rem)), calc(100vw - calc(3 * var(--rls-u, 1rem))));
  box-sizing: border-box;
  padding: calc(1.45 * var(--rls-u, 1rem));
  color: #342a25;
  border: 1px solid rgba(92, 65, 46, 0.35);
  border-radius: calc(0.45 * var(--rls-u, 1rem));
  background:
    radial-gradient(circle at 15% 18%, rgba(121, 84, 54, 0.09) 0 1px, transparent 1.6px),
    linear-gradient(145deg, #f8f1e5, #e8dcc8);
  background-size: calc(1.5625 * var(--rls-u, 1rem)) calc(1.75 * var(--rls-u, 1rem)), auto;
  box-shadow: 0 calc(1.25 * var(--rls-u, 1rem)) calc(3 * var(--rls-u, 1rem)) rgba(0, 0, 0, 0.55);
  text-align: center;
  font-family: Georgia, 'Times New Roman', serif;
}

.eyebrow {
  color: #a95e62;
  font: 700 calc(0.72 * var(--rls-u, 1rem))/1.1 Arial, sans-serif;
  letter-spacing: 0.15em;
  text-transform: uppercase;
}

h1 {
  margin: calc(0.35 * var(--rls-u, 1rem)) 0 calc(0.2 * var(--rls-u, 1rem));
  font-size: calc(2 * var(--rls-u, 1rem));
  line-height: 1.05;
}

.location-name {
  margin: 0;
  color: #55735b;
  font-size: calc(1.15 * var(--rls-u, 1rem));
  font-weight: 700;
}

.description {
  margin: calc(0.8 * var(--rls-u, 1rem)) auto calc(1.2 * var(--rls-u, 1rem));
  color: #786a61;
  font: calc(0.9 * var(--rls-u, 1rem))/1.4 Arial, sans-serif;
}

.error {
  margin: -0.5rem 0 calc(0.8 * var(--rls-u, 1rem));
  color: #9f4c4c;
  font: 700 calc(0.8 * var(--rls-u, 1rem)) Arial, sans-serif;
}

.prompt-actions {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: calc(0.65 * var(--rls-u, 1rem));
}

.prompt-actions :deep(.bng-binding) { margin-right: calc(0.35 * var(--rls-u, 1rem)); }

/* Controller focus: the house ring (same values as rlsHouse.scss --focus). Teleported to <body>, the
   prompt sits outside the app root, so the game's own [data-v-app] .focus-visible::before frame never
   reaches it; without this the focused button shows nothing. */
.prompt-actions :deep(.bng-button) {
  position: relative;
  &.focus-visible,
  &:focus-visible {
    outline: none;
    box-shadow: 0 0 0 1.5px rgba(14, 14, 16, 0.95), 0 0 0 calc(0.2188 * var(--rls-u, 1rem)) var(--bng-orange-b400, #ff6600), 0 0 0.9em -0.15em rgba(255, 102, 0, 0.55);
  }
  &.focus-visible::before {
    display: none !important;
  }
}

.journal-prompt-enter-active,
.journal-prompt-leave-active { transition: opacity 0.16s ease; }
.journal-prompt-enter-from,
.journal-prompt-leave-to { opacity: 0; }

@media (max-width: 42rem) {
  .prompt-actions { grid-template-columns: 1fr; }
}
</style>
