<!--
  ChallengeCreateModal: the create and edit form for a challenge, shown over the profile screen.

  Map, in reading order
    1. Props, emits, and the UI-only refs (tab, searches, seed text, copy status, dropdown and overlay refs).
    2. The form: useChallengeForm owns every form value and the operations that write them. It is destructured
       below into top-level names. The seed codec and the multiselect state are created after it.
    3. Dropdowns: useDropdown owns open state and placement; this component registers their listeners in
       onMounted and removes them in onBeforeUnmount.
    4. Watchers, in creation order: tabs, win condition, props.open, seedPayload (deep), seedInput, editChallengeId.
       Their order decides which encode request goes first, so do not reorder them.
    5. Open and edit session, the edit-data response, lifecycle, save, seed actions, copy.

  Parts (challengeCreate/)
    ChallengeBasicFields    name, ID, description, difficulty and map dropdowns (both teleported menus)
    ChallengeStartingTab    starting capital, win condition select, debt block
    ChallengeMultiselectModal  teleported multiselect picker
  The seed section, the win-condition variable fields, the garages tab and the economy tab are in this template;
  their inputs write the form state with v-model. ChallengeBasicFields and ChallengeStartingTab take values as
  props and report changes as events; neither writes a prop.

  Modules (challengeCreate/)
    useChallengeForm        form state and writes
    useWinConditionSchema, useMultiselectVariables
    seedCodec               Lua encode and decode traffic
    variableSchema, rounding
-->
<template>
  <!-- Text editing needs a keyboard; Cancel and Save remain in the pad path. -->
  <div
    v-show="open"
    ref="overlayRef"
    v-bng-scoped-nav="{ activateOnMount: true, trapPolicy: 'always', autoFocusDelay: 0, canDeactivate: () => (onRequestClose(), false) }"
    class="ccm-overlay"
    tabindex="-1"
    @click.stop
    @mousedown.stop
    @keydown.stop>
    <div class="ccm-content" @click.stop @mousedown.stop @keydown.stop>
      <div class="ccm-header">
        <div class="ccm-header-left">
          <div class="ccm-icon" />
          <div class="ccm-title">{{ editChallengeData ? 'Edit Challenge' : 'Create Challenge' }}</div>
        </div>
      </div>

      <div class="ccm-body" v-bng-ui-nav-scroll>
        <ChallengeBasicFields
          v-model:name="formName"
          v-model:fieldId="formId"
          v-model:description="formDescription"
          :id-locked="!!editChallengeData"
          :difficulty="formDifficulty"
          :difficulty-open="difficultyDropdownOpen"
          :difficulty-style="difficultyDropdownStyle"
          :map-label="formMapLabel"
          :map-id="formMap"
          :map-options="mapOptions"
          :map-open="mapDropdownOpen"
          :map-style="mapDropdownStyle"
          :set-difficulty-container="setDifficultyContainer"
          :set-map-container="setMapContainer"
          @toggleDifficulty="toggleDifficultyDropdown"
          @selectDifficulty="selectDifficulty"
          @closeDifficulty="closeDifficultyDropdown"
          @toggleMap="toggleMapDropdown"
          @selectMap="selectMap"
          @closeMap="closeMapDropdown"
        />

        <div class="ccm-seed-section">
          <div class="ccm-field">
            <label>Challenge Seed</label>
            <input v-bng-text-input
              v-model="seedInput"
              type="text"
              class="ccm-input ccm-seed-input"
              placeholder="Enter seed or leave empty for random"
              @keyup.enter="onSeedEnter()"
              @blur="onSeedBlur()"
            />
          </div>
          <div class="ccm-seed-row">
            <button class="ccm-seed-btn ccm-seed-generate" type="button" @click.stop="onGenerateSeed()" @mousedown.stop>Generate Random Seed</button>
            <button class="ccm-seed-btn ccm-seed-action ccm-seed-copy" type="button" @click.stop="onCopySeed()" @mousedown.stop :disabled="!seedInput">{{ copyStatus || 'Copy Seed' }}</button>
          </div>
          <div v-if="seedError" class="ccm-seed-error">{{ seedError }}</div>
        </div>

        <div class="ccm-tabs">
          <div class="ccm-tab-nav">
            <button
              v-for="tab in tabs"
              :key="tab.id"
              :class="['ccm-tab-btn', { 'ccm-tab-active': activeTab === tab.id }]"
              @click.stop="activeTab = tab.id"
            >
              {{ tab.label }}
            </button>
          </div>

          <div class="ccm-tab-content">
            <ChallengeStartingTab
              v-if="activeTab === 'starting'"
              v-model:startingCapital="formStartingCapital"
              v-model:winCondition="formWinCondition"
              v-model:loanAmount="formLoanAmount"
              v-model:interestPercent="interestPercent"
              v-model:loanPayments="formLoanPayments"
              :win-condition-options="winConditionOptions"
              :loans-required="loansRequired"
              :payments-minutes="paymentsMinutes"
              :per-payment-display="perPaymentDisplay"
              @roundCapital="roundStartingCapital"
              @roundLoanAmount="roundLoanAmount"
            />

            <div v-if="activeTab === 'winCondition'" class="ccm-tab-panel">
              <div class="ccm-variables-section">
                <div class="ccm-section-title">Win Condition Settings</div>
                <div v-for="{ variable, value } in variableRows" :key="variable.id" class="ccm-field">
                  <label :for="'var-' + variable.id">{{ variable.label }}</label>
                  <input v-bng-text-input
                    v-if="variable.type === 'number' || variable.type === 'integer'"
                    :id="'var-' + variable.id"
                    v-model.number="formVariables[variable.id]"
                    type="number"
                    v-bind="variable.props"
                    class="ccm-input"
                    @keyup.enter="onVariableEnter(variable)"
                    @blur="onVariableBlur(variable)"
                  />
                  <input
                    v-else-if="variable.type === 'boolean'"
                    :id="'var-' + variable.id"
                    v-model="formVariables[variable.id]"
                    type="checkbox"
                    class="ccm-checkbox"
                  />
                  <input v-bng-text-input
                    v-else-if="variable.type === 'string'"
                    :id="'var-' + variable.id"
                    v-model="formVariables[variable.id]"
                    type="text"
                    v-bind="variable.props"
                    class="ccm-input"
                    @keyup.enter="onVariableEnter(variable)"
                  />
                  <div
                    v-else-if="variable.type === 'array'"
                    :id="'var-' + variable.id"
                    class="ccm-array-input"
                  >
                    <div class="ccm-hint">{{ variable.hint }}</div>
                    <div class="ccm-hint">This variable is handled by the Target Garages tab</div>
                  </div>
                  <!-- Multiselect variable handling -->
                  <div v-else-if="variable.type === 'multiselect'" class="ccm-multiselect-section">
                    <div v-if="variable.hint" class="ccm-hint">{{ variable.hint }}</div>
                    <button
                      type="button"
                      class="ccm-multiselect-button"
                      @click.stop="openMultiselectModal(variable.id)"
                      @mousedown.stop
                    >
                      <span>Select {{ variable.label }}</span>
                      <span v-if="value?.length > 0" class="ccm-multiselect-count">
                        ({{ value.length }} selected)
                      </span>
                      <span class="ccm-multiselect-arrow">▾</span>
                    </button>
                  </div>
                  <div v-if="variable.hint && variable.type !== 'multiselect'" class="ccm-hint">{{ variable.hint }}</div>
                </div>
              </div>
            </div>

            <div v-if="activeTab === 'garages'" class="ccm-tab-panel">
              <div class="ccm-field">
                <input v-bng-text-input v-model="garageQuery" class="ccm-input" placeholder="Search garages..." />
              </div>

              <div class="ccm-garage-default">
                <button
                  class="ccm-garage-default-btn"
                  type="button"
                  @click.stop="onUseDefaultGarages()"
                  :class="{ 'ccm-garage-default-active': formStartingGarages.length === 0 }"
                >
                  Default
                </button>
                <div class="ccm-hint">Default starter garage (free)</div>
              </div>

              <div v-if="formStartingGarages.length > 0" class="ccm-garage-selection">
                <div class="ccm-garage-selected">
                  <div class="ccm-garage-selected-title">Selected Garages ({{ formStartingGarages.length }})</div>
                  <div class="ccm-garage-selected-list">
                    <div v-for="garage in selectedGarageRows" :key="garage.id" class="ccm-garage-selected-item">
                      <span>{{ garage.name }}</span>
                      <button
                        class="ccm-garage-emove"
                        type="button"
                        @click.stop="removeGarage(garage.id)"
                        @mousedown.stop
                      >
                        ×
                      </button>
                    </div>
                  </div>
                </div>
              </div>

              <div class="ccm-garages">
                <div v-for="garage in filteredGarages" :key="garage.id" class="ccm-garage-row">
                  <label class="ccm-garage-label">
                    <input
                      v-model="formStartingGarages"
                      :value="garage.id"
                      type="checkbox"
                      class="ccm-garage-checkbox"
                    />
                    <div class="ccm-garage-info">
                      <div class="ccm-garage-name">{{ garage.name }}</div>
                      <div class="ccm-garage-details">
                        <span class="ccm-garage-price"><BngIcon class="cur" :type="icons.beamCurrency" />{{ garage.price?.toLocaleString() || '0' }}</span>
                        <span class="ccm-garage-capacity">{{ garage.capacity || 0 }} slots</span>
                        <span v-if="garage.starterGarage" class="ccm-garage-starter">Starter</span>
                      </div>
                    </div>
                  </label>
                </div>
              </div>
            </div>

            <div v-if="activeTab === 'economy'" class="ccm-tab-panel">
              <div class="ccm-econ-section">
                <div class="ccm-section-title">Economy Multipliers (optional)</div>
                <div class="ccm-field">
                  <input v-bng-text-input v-model="econQuery" class="ccm-input" placeholder="Search multipliers..." />
                </div>
                <div class="ccm-econ">
                  <div v-for="row in economyRows" :key="row.id" class="ccm-econ-row">
                    <label>{{ row.name }}</label>
                    <input v-bng-text-input
                      v-model.number="formEconomyAdjuster[row.id]"
                      type="number"
                      step="0.25"
                      min="0.0"
                      max="10.0"
                      class="ccm-input"
                      placeholder="1.0"
                      @keyup.enter="roundEconomyMultiplier(row.id)"
                      @blur="roundEconomyMultiplier(row.id)"
                    />
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      <div class="ccm-footer">
        <button class="ccm-primary" :disabled="!canSave" @click.stop="onSave()" @mousedown.stop>Save</button>
        <button bng-scoped-nav-autofocus class="ccm-outline" @click.stop="onRequestClose()" @mousedown.stop>Cancel</button>
      </div>
      </div>
    </div>
  </div>

  <ChallengeMultiselectModal
    v-if="multiselectModalOpen"
    :variable-label="currentMultiselectVariable?.label"
    :selected="formVariables[currentMultiselectVariableId]"
    :query="multiselectQueries[currentMultiselectVariableId]"
    :options="getFilteredMultiselectOptions(currentMultiselectVariableId)"
    :item-name="itemId => getMultiselectItemName(currentMultiselectVariableId, itemId)"
    @update:selected="value => setMultiselectSelection(currentMultiselectVariableId, value)"
    @update:query="value => setMultiselectQuery(currentMultiselectVariableId, value)"
    @remove="itemId => removeMultiselectItem(currentMultiselectVariableId, itemId)"
    @close="closeMultiselectModal"
  />
</template>

<script setup>
import { computed, ref, watch, onMounted, onBeforeUnmount, nextTick } from 'vue'
import { lua } from '@/bridge'
import { useEvents } from '@/services/events'
import { BngIcon, icons } from '@/common/components/base'
import { vBngScopedNav, vBngTextInput, vBngUiNavScroll } from '@/common/directives'
import { returnFocusToOpener } from '../../composables/useScreenEntryFocus'
import { useDropdown } from '../../composables/useDropdown'
import { safeLua } from '../../utils/safeLua.js'
import ChallengeBasicFields from './challengeCreate/ChallengeBasicFields.vue'
import ChallengeStartingTab from './challengeCreate/ChallengeStartingTab.vue'
import ChallengeMultiselectModal from './challengeCreate/ChallengeMultiselectModal.vue'
import { useChallengeForm } from './challengeCreate/useChallengeForm.js'
import { createSeedCodec } from './challengeCreate/seedCodec.js'
import { useMultiselectVariables } from './challengeCreate/useMultiselectVariables.js'

const props = defineProps({
  open: { type: Boolean, default: false },
  editorData: { type: Object, default: () => ({}) },
  editChallengeData: { type: Object, default: null },
  editChallengeId: { type: String, default: null }
})
const emit = defineEmits(['close', 'saved'])

const seedInput = ref('')
const seedError = ref('')
const econQuery = ref('')
const garageQuery = ref('')
const activeTab = ref('starting')
const copyStatus = ref('')
// How long "Copied!" stays on the copy button.
const COPY_STATUS_RESET_MS = 3000
let copyStatusTimer

const overlayRef = ref(null)
const difficultyDropdownRef = ref(null)
const mapDropdownRef = ref(null)
// ChallengeBasicFields renders both dropdown wrappers and hands each element back here.
const setDifficultyContainer = element => { difficultyDropdownRef.value = element }
const setMapContainer = element => { mapDropdownRef.value = element }
const mapOptions = ref([])

const fullEditorData = ref(null)
const editorDataLoading = ref(false)

const activeEditorData = computed(() => {
  if (fullEditorData.value) return fullEditorData.value
  return props.editorData || {}
})

const {
  formId, formName, formDescription, formDifficulty, formStartingCapital, formWinCondition, formVariables,
  formLoanAmount, formLoanInterest, formLoanPayments, formEconomyAdjuster, formStartingGarages, formMap,
  multiselectQueries, isApplyingSeed, seedPayload, canSave,
  winConditionOptions, variableDefinitions, loansRequired, activeVariables, variableRows,
  paymentsMinutes, perPaymentDisplay, interestPercent,
  markInitialSnapshot, initializeVariables, resetFormDefaults, applySeedDataToForm,
  roundVariableToStep, roundEconomyMultiplier, roundLoanAmount, roundStartingCapital,
  removeGarage, onUseDefaultGarages,
} = useChallengeForm({ activeEditorData, seedError, onSeedApplied: () => updateSeedFromPayload() })

const events = useEvents()
// The two dropdowns are independent: opening one does not close the other.
const difficultyDropdown = useDropdown({
  containerRef: difficultyDropdownRef,
  triggerSelector: '.ccm-difficulty-trigger',
  menuSelector: '.ccm-difficulty-content',
  gapPx: 8,
  zIndex: 3001,
  widthProperty: 'width',
  onClose: () => returnFocusToOpener(difficultyDropdown.trigger),
})
const {
  open: difficultyDropdownOpen, style: difficultyDropdownStyle,
  toggle: toggleDifficultyDropdown, close: closeDifficultyDropdown,
  position: positionDifficultyDropdown, onDocumentClick: onDifficultyDocClick,
} = difficultyDropdown

const mapDropdown = useDropdown({
  containerRef: mapDropdownRef,
  triggerSelector: '.ccm-map-trigger',
  menuSelector: '.ccm-map-content',
  gapPx: 8,
  zIndex: 3001,
  widthProperty: 'width',
  onClose: () => returnFocusToOpener(mapDropdown.trigger),
})
const {
  open: mapDropdownOpen, style: mapDropdownStyle,
  toggle: toggleMapDropdown, close: closeMapDropdown,
  position: positionMapDropdown, onDocumentClick: onMapDocClick,
} = mapDropdown

function selectDifficulty(difficulty) {
  formDifficulty.value = difficulty
  closeDifficultyDropdown()
}

const formMapLabel = computed(() => {
  if (!formMap.value) return 'Any'
  const map = mapOptions.value.find(m => m.id === formMap.value)
  return map ? map.name : 'Any'
})

function selectMap(mapId) {
  formMap.value = mapId
  closeMapDropdown()
}

function onKeyDown(e) {
  if (!props.open) return
  e.stopPropagation()
}

// The seed codec owns the pending request ids and the latest encode id. Decoded data is applied through the form.
const {
  requestEncode, applySeedToForm, handleSeedGenerated, handleSeedEncodeResponse, handleSeedDecodeResponse,
} = createSeedCodec({ lua, seedInput, seedError, onDecoded: applySeedDataToForm })

const {
  multiselectModalOpen, currentMultiselectVariableId, currentMultiselectVariable,
  getFilteredMultiselectOptions, getMultiselectItemName, removeMultiselectItem,
  setMultiselectSelection, setMultiselectQuery, openMultiselectModal, closeMultiselectModal,
} = useMultiselectVariables({ activeVariables, formVariables, multiselectQueries, overlayRef })

// The starting-garages tab's list: the editor's garages filtered by the search box, and the selected ids as
// { id, name } chips. The selection itself stays in the parent.
function useStartingGarages({ activeEditorData, garageQuery, formStartingGarages }) {
  const availableGarages = computed(() => {
    const raw = activeEditorData.value && activeEditorData.value.availableGarages
    return Array.isArray(raw) ? raw : []
  })

  const filteredGarages = computed(() => {
    const q = garageQuery.value.trim().toLowerCase()
    const garages = availableGarages.value
    if (!q) return garages
    return garages.filter(g => ((g.name || g.id || '').toLowerCase().includes(q)))
  })

  function getGarageName(garageId) {
    const garage = availableGarages.value.find(g => g.id === garageId)
    return garage ? garage.name : garageId
  }

  const selectedGarageRows = computed(() => formStartingGarages.value.map(garageId => ({ id: garageId, name: getGarageName(garageId) })))

  return { filteredGarages, selectedGarageRows, getGarageName }
}

// The economy tab's list: activity types filtered by the search box, and one { id, name } row per type.
// Each row's input writes formEconomyAdjuster[id] directly.
function useEconomyMultipliers({ activeEditorData, econQuery }) {
  const filteredActivityTypes = computed(() => {
    const q = econQuery.value.trim().toLowerCase()
    const raw = activeEditorData.value && activeEditorData.value.activityTypes
    const types = Array.isArray(raw) ? raw : []
    if (!q) return types
    return types.filter(t => ((t.name || t.id || '').toLowerCase().includes(q)))
  })

  const economyRows = computed(() => filteredActivityTypes.value.map(t => ({ id: t.id, name: t.name })))

  return { filteredActivityTypes, economyRows }
}

const { filteredGarages, selectedGarageRows, getGarageName } = useStartingGarages({ activeEditorData, garageQuery, formStartingGarages })
const { filteredActivityTypes, economyRows } = useEconomyMultipliers({ activeEditorData, econQuery })

const tabs = computed(() => {
  const tabList = [{ id: 'starting', label: 'Starting Parameters' }]
  if (activeVariables.value.length > 0) {
    tabList.push({ id: 'winCondition', label: 'Win Condition Settings' })
  }
  tabList.push({ id: 'garages', label: 'Starting Garages' })
  tabList.push({ id: 'economy', label: 'Economy Multipliers' })
  return tabList
})

watch(tabs, (tabList) => {
  if (tabList && tabList.length > 0 && !tabList.some(tab => tab.id === activeTab.value)) {
    activeTab.value = tabList[0]?.id || 'starting'
  }
}, { immediate: false })

watch(() => formWinCondition.value, () => {
  initializeVariables()

  if (loansRequired.value && formLoanAmount.value === 0) {
    formLoanAmount.value = activeEditorData.value?.defaults?.loanAmount ?? 50000
    formLoanInterest.value = activeEditorData.value?.defaults?.loanInterest ?? 0.10
    formLoanPayments.value = activeEditorData.value?.defaults?.loanPayments ?? 12
  }

  seedError.value = ''
  updateSeedFromPayload()
})

watch(() => props.open, async (isOpen, oldIsOpen) => {
  if (!isOpen) return

  if (!fullEditorData.value && !editorDataLoading.value) {
    editorDataLoading.value = true
    await safeLua(async () => {
      const ed = await lua.overhaul_career_challengeModes.getChallengeEditorData()
      if (ed && typeof ed === 'object') {
        fullEditorData.value = ed
      }
    }, 'ChallengeCreateModal failed to load editor data')
    editorDataLoading.value = false
  }

  try {
    if (props.editChallengeId) {
      safeLua(() => lua.overhaul_career_challengeModes.requestChallengeDataForEdit(props.editChallengeId), 'ChallengeCreateModal failed to request edit data on open')
    } else if (props.editChallengeData) {
      if (props.editChallengeData.seed) {
        seedInput.value = props.editChallengeData.seed
      }

      applySeedDataToForm(props.editChallengeData, true)
      formName.value = props.editChallengeData.name || ''
      formDescription.value = props.editChallengeData.description || ''
      formId.value = props.editChallengeData.id || ''

      if (props.editChallengeData.map !== undefined) {
        formMap.value = props.editChallengeData.map || null
      } else {
        formMap.value = null
      }
    } else if (seedInput.value && seedInput.value.trim() !== '') {
      applySeedToForm(seedInput.value)
    } else {
      resetFormDefaults()
      updateSeedFromPayload()
    }

    markInitialSnapshot()

    nextTick(() => {
      if (overlayRef.value) {
        overlayRef.value.focus()
      }
      overlayRef.value?.querySelector('[bng-scoped-nav-autofocus]')?.focus({ preventScroll: true })
    })
  } catch (error) {
    safeLua(() => { throw error }, 'ChallengeCreateModal failed in the open handler')
  }
})

function handleChallengeEditDataResponse(payload) {
  if (!payload || payload.challengeId !== props.editChallengeId) {
    return
  }

  if (!payload.success) {
    safeLua(() => { throw payload.error }, 'ChallengeCreateModal edit data fetch failed')
    seedError.value = payload.error || 'Failed to load challenge data'
    return
  }

  const challengeData = payload.data
  if (!challengeData) {
    safeLua(() => { throw new Error('No challenge data in response') }, 'ChallengeCreateModal received no challenge data')
    seedError.value = 'No challenge data received'
    return
  }

  if (challengeData.seed) {
    seedInput.value = challengeData.seed
  }

  applySeedDataToForm(challengeData, true)

  formName.value = challengeData.name || ''
  formDescription.value = challengeData.description || ''
  formId.value = challengeData.id || ''

  if (challengeData.map !== undefined) {
    formMap.value = challengeData.map || null
  } else {
    formMap.value = null
  }

  if (challengeData.difficulty) {
    formDifficulty.value = challengeData.difficulty
  }

  nextTick(() => {
    markInitialSnapshot()
  })
}

onMounted(async () => {
  events.on('challengeSeedGenerated', handleSeedGenerated)
  events.on('challengeSeedEncodeResponse', handleSeedEncodeResponse)
  events.on('challengeSeedDecodeResponse', handleSeedDecodeResponse)
  events.on('challengeEditDataResponse', handleChallengeEditDataResponse)
  document.addEventListener('mousedown', onDifficultyDocClick)
  document.addEventListener('mousedown', onMapDocClick)
  document.addEventListener('keydown', onKeyDown, true)
  window.addEventListener('resize', positionDifficultyDropdown)
  window.addEventListener('scroll', positionDifficultyDropdown, true)
  window.addEventListener('resize', positionMapDropdown)
  window.addEventListener('scroll', positionMapDropdown, true)

  if (props.open && props.editChallengeId) {
    safeLua(() => lua.overhaul_career_challengeModes.requestChallengeDataForEdit(props.editChallengeId), 'ChallengeCreateModal failed to request edit data on mount')
  }

  await safeLua(async () => {
    const maps = await lua.overhaul_world_maps.getCompatibleMaps()
    if (maps && Object.keys(maps).length > 0) {
      mapOptions.value = Object.entries(maps)
        .map(([key, value]) => ({
          id: key,
          name: value
        }))
        .sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: 'base' }))
    }
  }, 'ChallengeCreateModal failed to load maps')
})

onBeforeUnmount(() => {
  events.off('challengeSeedGenerated', handleSeedGenerated)
  events.off('challengeSeedEncodeResponse', handleSeedEncodeResponse)
  events.off('challengeSeedDecodeResponse', handleSeedDecodeResponse)
  events.off('challengeEditDataResponse', handleChallengeEditDataResponse)
  document.removeEventListener('mousedown', onDifficultyDocClick)
  document.removeEventListener('mousedown', onMapDocClick)
  document.removeEventListener('keydown', onKeyDown, true)
  window.removeEventListener('resize', positionDifficultyDropdown)
  window.removeEventListener('scroll', positionDifficultyDropdown, true)
  window.removeEventListener('resize', positionMapDropdown)
  window.removeEventListener('scroll', positionMapDropdown, true)
  if (copyStatusTimer) {
    clearTimeout(copyStatusTimer)
    copyStatusTimer = null
  }
})

function onRequestClose() {
  if (!props.open) {
    return
  }
  emit('close')
}

async function onSave() {
  const payload = {
    id: formId.value,
    name: formName.value,
    description: formDescription.value,
    difficulty: formDifficulty.value,
    startingCapital: formStartingCapital.value,
    winCondition: formWinCondition.value,
    economyAdjuster: Object.keys(formEconomyAdjuster).length > 0 ? formEconomyAdjuster : undefined,
    startingGarages: formStartingGarages.value.length > 0 ? formStartingGarages.value : undefined,
    map: formMap.value || undefined
  }

  const defs = variableDefinitions.value
  for (const [variableId, definition] of Object.entries(defs)) {
    const value = formVariables[variableId]
    if (value !== undefined) {
      payload[variableId] = definition.type === 'boolean' ? (value === true) : value
    }
  }

  if (formLoanAmount.value && formLoanAmount.value > 0) {
    payload.loans = { amount: formLoanAmount.value, interest: formLoanInterest.value, payments: formLoanPayments.value }
  }

  const resp = await lua.overhaul_career_challengeModes.createChallengeFromUI(payload)
  let ok, msg, challengeId
  if (Array.isArray(resp)) {
    ok = resp[0]; msg = resp[1]; challengeId = resp[2]
  } else if (resp && typeof resp === 'object') {
    ok = resp.ok; msg = resp.msg || resp.message; challengeId = resp.challengeId || resp.id
  } else {
    ok = resp
  }
  if (ok !== true) {
    safeLua(() => { throw msg }, 'ChallengeCreateModal create challenge failed')
    seedError.value = msg || 'Failed to save challenge'
    return
  }
  emit('saved', challengeId)
  emit('close')
}

function updateSeedFromPayload() {
  requestEncode(seedPayload.value)
}

function onGenerateSeed() {
  seedError.value = ''
  lua.overhaul_career_challengeModes.requestGenerateRandomSeed()
}

function onSeedEnter() {
  applySeedToForm(seedInput.value)
}

function onSeedBlur() {
  if (seedInput.value && seedInput.value.trim() !== '') {
    applySeedToForm(seedInput.value)
  }
}

async function onCopySeed() {
  if (!seedInput.value) {
    seedError.value = 'No seed to copy'
    return
  }
  if (!navigator.clipboard || !navigator.clipboard.writeText) {
    seedError.value = 'Clipboard not supported'
    return
  }
  try {
    await navigator.clipboard.writeText(seedInput.value)
    copyStatus.value = 'Copied!'
    if (copyStatusTimer) {
      clearTimeout(copyStatusTimer)
    }
    copyStatusTimer = setTimeout(() => {
      copyStatus.value = ''
      copyStatusTimer = null
    }, COPY_STATUS_RESET_MS)
  } catch (err) {
    seedError.value = 'Failed to copy to clipboard'
    safeLua(() => { throw err }, 'ChallengeCreateModal failed to copy the seed')
  }
}

// Enter on a number variable rounds it and then applies the seed. Enter on a string variable only applies the seed.
function onVariableEnter(variable) {
  if (variable.type === 'number' || variable.type === 'integer') {
    roundVariableToStep(variable)
  }
  onSeedEnter()
}

function onVariableBlur(variable) {
  roundVariableToStep(variable)
}

watch(seedPayload, () => {
  if (isApplyingSeed.value) {
    return
  }
  updateSeedFromPayload()
}, { deep: true })

watch(seedInput, (val) => {
  if (!val || val.trim() === '') {
    seedError.value = ''
  }
})

watch(() => props.editChallengeId, (newId, oldId) => {
  if (newId && props.open) {
    safeLua(() => lua.overhaul_career_challengeModes.requestChallengeDataForEdit(newId), 'ChallengeCreateModal failed to request edit data on id change')
  }
}, { immediate: true })
</script>

<style scoped lang="scss">
@use "@/styles/modules/mixins" as *;

// Rules of the sections that used to be separate components come first, so the shared form rules below still win ties.
/* Seed section */
.ccm-seed-section {
  background: rgba(59, 130, 246, 0.08);
  border: 1px solid rgba(59, 130, 246, 0.25);
  border-radius: 10px;
  padding: 0.75em;
  display: flex;
  flex-direction: column;
  gap: 0.5em;
}

.ccm-seed-row {
  display: flex;
  gap: 0.5em;
  align-items: center;
  flex-wrap: wrap;
}
.ccm-seed-btn {
  white-space: nowrap;
  flex: 1 1 0;
  min-width: 0;
  border-radius: 10px;
  padding: 0.6em 1em;
  border: 1px solid transparent;
  cursor: pointer;
  transition: all 0.2s ease;
  font-size: inherit;
  font-weight: 500;
}
.ccm-seed-generate {
  background: rgba(30, 41, 59, 0.6);
  border-color: rgba(100, 116, 139, 0.35);
  color: #e2e8f0;
}
.ccm-seed-generate:hover {
  background: rgba(30, 41, 59, 0.8);
  border-color: rgba(100, 116, 139, 0.5);
  transform: translateY(-1px);
}
.ccm-seed-action {
  font-weight: 600;
}
.ccm-seed-copy {
  background: linear-gradient(90deg, #2563eb, #1d4ed8);
  color: #fff;
  border: 0;
}
.ccm-seed-action:hover {
  transform: translateY(-1px);
  opacity: 0.9;
}
.ccm-seed-action:active {
  transform: translateY(0);
}
.ccm-seed-copy:disabled {
  background: rgba(148, 163, 184, 0.5);
  color: rgba(15, 23, 42, 0.65);
  cursor: not-allowed;
  opacity: 0.6;
}

.ccm-seed-input {
  font-family: 'Courier New', monospace;
  font-size: 0.9em;
  width: 100%;
}

.ccm-seed-error {
  color: #f87171;
  font-size: 0.85em;
  padding-left: 0.25em;
}

/* Win-condition variable fields */
.ccm-checkbox {
  width: 1.25em;
  height: 1.25em;
  cursor: pointer;
  accent-color: #2563eb;
}

.ccm-field:has(.ccm-checkbox) {
  flex-direction: row;
  align-items: center;
  gap: 0.5em;
}

.ccm-field:has(.ccm-checkbox) label {
  order: 2;
  cursor: pointer;
}

.ccm-field:has(.ccm-checkbox) .ccm-checkbox {
  order: 1;
}

.ccm-multiselect-button {
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: space-between;
  background: rgba(30, 41, 59, 0.6);
  border: 1px solid rgba(100, 116, 139, 0.35);
  color: #e2e8f0;
  border-radius: 10px;
  padding: 0.6em 0.75em;
  cursor: pointer;
  transition: all 0.2s ease;
  font-size: inherit;
  font-weight: 500;
}

.ccm-multiselect-button:hover {
  background: rgba(30, 41, 59, 0.8);
  border-color: rgba(100, 116, 139, 0.5);
}

.ccm-multiselect-count {
  color: #60a5fa;
  font-weight: 500;
}

.ccm-multiselect-arrow {
  opacity: 0.8;
  font-size: 0.9em;
}

/* Garages tab */
.ccm-garage-default {
  margin-bottom: 0.75em;
  padding: 0.375em 0.5em;
  background: rgba(34, 197, 94, 0.08);
  border: 1px solid rgba(34, 197, 94, 0.25);
  border-radius: 6px;
  display: flex;
  align-items: center;
  gap: 0.5em;
}

.ccm-garage-default-btn {
  background: rgba(34, 197, 94, 0.15);
  border: 1px solid rgba(34, 197, 94, 0.4);
  color: #22c55e;
  padding: 0.25em 0.5em;
  border-radius: 4px;
  cursor: pointer;
  font-weight: 500;
  font-size: 0.8em;
  transition: all 0.2s ease;
  white-space: nowrap;
}

.ccm-garage-default-btn:hover {
  background: rgba(34, 197, 94, 0.25);
  border-color: rgba(34, 197, 94, 0.6);
}

.ccm-garage-default-btn.ccm-garage-default-active {
  background: rgba(34, 197, 94, 0.3);
  border-color: rgba(34, 197, 94, 0.7);
  box-shadow: 0 0 0 2px rgba(34, 197, 94, 0.2);
}

.ccm-garage-selection {
  margin-bottom: 1em;
}

.ccm-garage-selected {
  background: rgba(59, 130, 246, 0.1);
  border: 1px solid rgba(59, 130, 246, 0.3);
  border-radius: 10px;
  padding: 1em;
}

.ccm-garage-selected-title {
  font-weight: 600;
  margin-bottom: 0.75em;
  color: #60a5fa;
  font-size: 0.95em;
  text-transform: uppercase;
  letter-spacing: 0.05em;
}

.ccm-garage-selected-list {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5em;
}

.ccm-garage-selected-item {
  background: rgba(59, 130, 246, 0.15);
  border: 1px solid rgba(59, 130, 246, 0.3);
  border-radius: 6px;
  padding: 0.25em 0.5em;
  display: flex;
  align-items: center;
  gap: 0.5em;
  font-size: 0.85em;
}

.ccm-garage-remove {
  background: transparent;
  border: 0;
  color: #ef4444;
  cursor: pointer;
  font-size: 1em;
  padding: 0;
  width: 1em;
  height: 1em;
  display: flex;
  align-items: center;
  justify-content: center;
  border-radius: 2px;
}

.ccm-garage-remove:hover {
  background: rgba(239, 68, 68, 0.2);
}

.ccm-garages {
  display: grid;
  grid-template-columns: 1fr;
  gap: 0.5em;
  flex: 1;
  min-height: 0;
  overflow: auto;
  padding-right: 0.5em;
  scrollbar-width: thin;
  scrollbar-color: rgba(100, 116, 139, 0.5) transparent;
  background: rgba(30, 41, 59, 0.3);
  border: 1px solid rgba(100, 116, 139, 0.2);
  border-radius: 10px;
  padding: 0.75em;
}

.ccm-garages::-webkit-scrollbar {
  width: 6px;
}

.ccm-garages::-webkit-scrollbar-track {
  background: rgba(30, 41, 59, 0.5);
  border-radius: 3px;
}

.ccm-garages::-webkit-scrollbar-thumb {
  background: rgba(100, 116, 139, 0.5);
  border-radius: 3px;
}

.ccm-garages::-webkit-scrollbar-thumb:hover {
  background: rgba(100, 116, 139, 0.7);
}

.ccm-garage-row {
  display: flex;
  align-items: center;
}

.ccm-garage-label {
  display: flex;
  align-items: center;
  gap: 0.75em;
  cursor: pointer;
  padding: 0.5em;
  border-radius: 6px;
  transition: background 0.2s ease;
  width: 100%;
}

.ccm-garage-label:hover {
  background: rgba(100, 116, 139, 0.1);
}

.ccm-garage-checkbox {
  width: 1.125em;
  height: 1.125em;
  cursor: pointer;
  accent-color: #3b82f6;
}

.ccm-garage-info {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 0.25em;
}

.ccm-garage-name {
  font-weight: 500;
  color: #e2e8f0;
}

.ccm-garage-details {
  display: flex;
  gap: 0.75em;
  font-size: 0.8em;
  color: #94a3b8;
}

.ccm-garage-price {
  color: #22c55e;
  font-weight: 500;
}

.ccm-garage-capacity {
  color: #8b5cf6;
}

.ccm-garage-category {
  color: #f59e0b;
}

.ccm-garage-starter {
  background: rgba(34, 197, 94, 0.2);
  color: #22c55e;
  padding: 0.1em 0.4em;
  border-radius: 4px;
  font-size: 0.75em;
  font-weight: 500;
}

/* Game currency glyph before amounts; inherits colour/size. */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}

/* Economy tab */
.ccm-econ-section {
  display: flex;
  flex-direction: column;
  gap: 0.5em;
}

.ccm-econ {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.5em 0.75em;
  flex: 1;
  min-height: 0;
  overflow: auto;
  padding-right: 0.5em;
  scrollbar-width: thin;
  scrollbar-color: rgba(100, 116, 139, 0.5) transparent;
  background: rgba(30, 41, 59, 0.3);
  border: 1px solid rgba(100, 116, 139, 0.2);
  border-radius: 10px;
  padding: 0.75em;
}

.ccm-econ::-webkit-scrollbar {
  width: 6px;
}

.ccm-econ::-webkit-scrollbar-track {
  background: rgba(30, 41, 59, 0.5);
  border-radius: 3px;
}

.ccm-econ::-webkit-scrollbar-thumb {
  background: rgba(100, 116, 139, 0.5);
  border-radius: 3px;
}

.ccm-econ::-webkit-scrollbar-thumb:hover {
  background: rgba(100, 116, 139, 0.7);
}

/* Economy multiplier row */
.ccm-econ-row {
  display: grid;
  grid-template-columns: 1fr 7.5em;
  gap: 0.75em;
  align-items: center;
}

.ccm-econ-row label {
  color: #e2e8f0;
  font-weight: 500;
  font-size: 0.9em;
}

.ccm-overlay {
  position: fixed;
  inset: 0;
  background: radial-gradient(ellipse at center, rgba(2, 8, 23, 0.6), rgba(2, 8, 23, 0.75));
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 3000;
}

.ccm-content {
  width: min(60em, 90vw);
  max-width: calc(100vw - 2em);
  height: 85vh;
  background: rgba(15, 23, 42, 0.98);
  border: 1px solid rgba(71, 85, 105, 0.6);
  border-radius: 14px;
  box-shadow: 0 30px 80px rgba(0, 0, 0, 0.6);
  color: #fff;
  padding: 1em 1em 0.75em;
  font-size: calc-ui-em();
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

.ccm-header {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  padding-bottom: 0.75em;
  border-bottom: 1px solid rgba(100, 116, 139, 0.2);
  flex-shrink: 0;
}

.ccm-header-left {
  display: flex;
  gap: 0.875em;
  align-items: center;
  flex: 1;
}

.ccm-icon {
  width: 2.5em;
  height: 2.5em;
  border-radius: 10px;
  background: rgba(59, 130, 246, 0.2);
  border: 1px solid rgba(59, 130, 246, 0.3);
  flex-shrink: 0;
  aspect-ratio: 1;
}

.ccm-title {
  font-weight: 600;
  font-size: 1.25em;
  line-height: 1.3;
}

.ccm-body {
  margin-top: 0.75em;
  display: flex;
  flex-direction: column;
  gap: 0.75em;
  flex: 1;
  min-height: 0;
  overflow-y: auto;
}

:deep(.ccm-grid2) {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.75em;
}

:deep(.ccm-field) {
  display: flex;
  flex-direction: column;
  gap: 0.35em;
}

:deep(.ccm-field .bng-select) {
  font-size: inherit !important;
}

:deep(.ccm-field .bng-select-content),
:deep(.ccm-field .bng-select-content .label),
:deep(.ccm-field .bng-select-content .label *) {
  font-size: inherit !important;
}

:deep(.ccm-field .bng-select-dropdown),
:deep(.ccm-field .bng-select-option),
:deep(.ccm-field .bng-select-option *) {
  font-size: inherit !important;
}

:deep(.ccm-field .bng-button),
:deep(.ccm-field .bng-select .bng-button) {
  font-size: inherit !important;
}

:deep(.ccm-field label) {
  color: #94a3b8;
  font-size: 0.85em;
  font-weight: 500;
  text-transform: uppercase;
  letter-spacing: 0.03em;
}

:deep(.ccm-input),
:deep(.ccm-textarea),
select {
  background: rgba(30, 41, 59, 0.6);
  border: 1px solid rgba(100, 116, 139, 0.35);
  color: #e2e8f0;
  border-radius: 10px;
  padding: 0.6em 0.75em;
  font-size: inherit;
  transition: all 0.2s ease;
}

:deep(.ccm-input:focus),
:deep(.ccm-textarea:focus) {
  outline: none;
  border-color: rgba(59, 130, 246, 0.6);
  background: rgba(30, 41, 59, 0.8);
  box-shadow: 0 0 0 3px rgba(59, 130, 246, 0.1);
}

:deep(.ccm-section-title) {
  margin-top: 0;
  margin-bottom: 0.5em;
  font-weight: 600;
  font-size: 0.9em;
  color: #93c5fd;
  text-transform: uppercase;
  letter-spacing: 0.05em;
}

:deep(.ccm-hint) {
  color: #94a3b8;
  font-size: 0.8em;
  margin-top: 0.25em;
  font-style: italic;
}

:deep(.ccm-section-title:has-text('required')) {
  color: #fca5a5;
}

.ccm-tabs {
  margin-top: 0.25em;
  display: flex;
  flex-direction: column;
  flex: 1;
  min-height: 0;
}

.ccm-tab-content {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
}

:deep(.ccm-tab-panel) {
  display: flex;
  flex-direction: column;
  gap: 0.75em;
}

.ccm-no-settings {
  text-align: center;
  color: #94a3b8;
  padding: 2em;
  font-style: italic;
}

.ccm-footer {
  display: flex;
  gap: 0.75em;
  padding-top: 0.75em;
  border-top: 1px solid rgba(100, 116, 139, 0.2);
  margin-top: 0.5em;
  justify-content: flex-end;
  flex-shrink: 0;
}

.ccm-primary {
  background: linear-gradient(90deg, #2563eb, #1d4ed8);
  border: 0;
  color: #fff;
  padding: 0.6em 1em;
  border-radius: 8px;
  cursor: pointer;
  font-size: inherit;
}

.ccm-outline {
  background: transparent;
  border: 1px solid rgba(100, 116, 139, 0.5);
  color: #cbd5e1;
  padding: 0.6em 1em;
  border-radius: 8px;
  cursor: pointer;
  font-size: inherit;
}

.ccm-tab-nav {
  display: flex;
  border-bottom: 1px solid rgba(100, 116, 139, 0.3);
  margin-bottom: 0.75em;
  gap: 0.5em;
  flex-shrink: 0;
}

.ccm-tab-btn {
  background: transparent;
  border: 0;
  color: #94a3b8;
  padding: 0.6em 1em;
  cursor: pointer;
  border-bottom: 2px solid transparent;
  transition: all 0.2s ease;
  font-size: 0.9em;
  font-weight: 500;
  border-radius: 8px 8px 0 0;
}

.ccm-tab-btn:hover {
  color: #cbd5e1;
  background: rgba(100, 116, 139, 0.1);
}

.ccm-tab-btn.ccm-tab-active {
  color: #60a5fa;
  border-bottom-color: #60a5fa;
  background: rgba(59, 130, 246, 0.08);
}

.ccm-variables-section {
  background: rgba(59, 130, 246, 0.1);
  border: 1px solid rgba(59, 130, 246, 0.3);
  border-radius: 10px;
  padding: 0.75em;
  display: flex;
  flex-direction: column;
  gap: 0.75em;
}
</style>
