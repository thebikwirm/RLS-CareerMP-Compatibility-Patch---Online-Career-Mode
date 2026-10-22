<template>
  <div class="ccm-basic-section">
    <div class="ccm-grid2">
      <div class="ccm-field">
        <label>Name</label>
        <input v-bng-text-input v-model="nameModel" type="text" class="ccm-input" placeholder="My Challenge" />
      </div>
      <div class="ccm-field">
        <label>ID</label>
        <input v-bng-text-input v-model="idModel" type="text" class="ccm-input" placeholder="myChallengeId" :disabled="idLocked" />
      </div>
    </div>

    <div class="ccm-grid2">
      <div class="ccm-field">
        <label>Difficulty</label>
        <div class="ccm-difficulty-dropdown" :ref="setDifficultyContainer">
          <button
            type="button"
            class="ccm-difficulty-trigger"
            @click.stop="emit('toggleDifficulty')"
            @mousedown.stop
          >
            <span>{{ difficulty }}</span>
            <span class="ccm-difficulty-chevron">▾</span>
          </button>
          <teleport to="body">
            <div
              v-if="difficultyOpen"
              v-bng-scoped-nav="{ activateOnMount: true, trapPolicy: 'always', autoFocusDelay: 0, canDeactivate: () => (emit('closeDifficulty'), false) }"
              class="ccm-difficulty-content"
              :style="difficultyStyle"
              @click.stop
              @mousedown.stop
            >
              <div
                v-for="diff in difficultyOptions"
                :key="diff"
                class="ccm-difficulty-option"
                :class="{ 'ccm-difficulty-selected': diff === difficulty }"
                role="button"
                tabindex="0"
                bng-nav-item
                :bng-scoped-nav-autofocus="diff === difficulty ? '' : null"
                @click.stop="emit('selectDifficulty', diff)"
                @mousedown.stop
              >
                {{ diff }}
              </div>
            </div>
          </teleport>
        </div>
      </div>
      <div class="ccm-field">
        <label>Starting Map</label>
        <div class="ccm-map-dropdown" :ref="setMapContainer">
          <button
            type="button"
            class="ccm-map-trigger"
            @click.stop="emit('toggleMap')"
            @mousedown.stop
          >
            <span>{{ mapLabel }}</span>
            <span class="ccm-map-chevron">▾</span>
          </button>
          <teleport to="body">
            <div
              v-if="mapOpen"
              v-bng-scoped-nav="{ activateOnMount: true, trapPolicy: 'always', autoFocusDelay: 0, canDeactivate: () => (emit('closeMap'), false) }"
              class="ccm-map-content"
              :style="mapStyle"
              @click.stop
              @mousedown.stop
            >
              <div
                class="ccm-map-option"
                :class="{ 'ccm-map-selected': mapId === null }"
                role="button"
                tabindex="0"
                bng-nav-item
                :bng-scoped-nav-autofocus="mapId === null ? '' : null"
                @click.stop="emit('selectMap', null)"
                @mousedown.stop
              >
                Any
              </div>
              <div v-if="mapOptions.length > 0" class="ccm-map-sep"></div>
              <div
                v-for="map in mapOptions"
                :key="map.id"
                class="ccm-map-option"
                :class="{ 'ccm-map-selected': map.id === mapId }"
                role="button"
                tabindex="0"
                bng-nav-item
                :bng-scoped-nav-autofocus="map.id === mapId ? '' : null"
                @click.stop="emit('selectMap', map.id)"
                @mousedown.stop
              >
                {{ map.name }}
              </div>
            </div>
          </teleport>
        </div>
      </div>
    </div>

    <div class="ccm-field">
      <label>Description</label>
      <textarea v-bng-text-input v-model="descriptionModel" class="ccm-textarea" rows="2" />
    </div>
  </div>
</template>

<script setup>
// Name, ID, description, and the two dropdown fields. The parent owns the values and both useDropdown
// instances, and registers their listeners. Each dropdown's wrapper element is handed back through a function
// prop, so this component never writes into a ref the parent owns. The dropdown menus are teleported.
import { computed } from 'vue'
import { vBngScopedNav, vBngTextInput } from '@/common/directives'

const difficultyOptions = ['Easy', 'Medium', 'Hard', 'Impossible']

const props = defineProps({
  name: { default: '' },
  fieldId: { default: '' },
  description: { default: '' },
  idLocked: { type: Boolean, default: false },
  difficulty: { default: undefined },
  difficultyOpen: { type: Boolean, default: false },
  difficultyStyle: { default: '' },
  mapLabel: { default: undefined },
  mapId: { default: null },
  mapOptions: { type: Array, default: () => [] },
  mapOpen: { type: Boolean, default: false },
  mapStyle: { default: '' },
  setDifficultyContainer: { type: Function, required: true },
  setMapContainer: { type: Function, required: true },
})
const emit = defineEmits([
  'update:name', 'update:fieldId', 'update:description',
  'toggleDifficulty', 'selectDifficulty', 'closeDifficulty',
  'toggleMap', 'selectMap', 'closeMap',
])

const nameModel = computed({ get: () => props.name, set: value => emit('update:name', value) })
const idModel = computed({ get: () => props.fieldId, set: value => emit('update:fieldId', value) })
const descriptionModel = computed({ get: () => props.description, set: value => emit('update:description', value) })
</script>

<style scoped lang="scss">
.ccm-basic-section {
  background: rgba(30, 41, 59, 0.4);
  border: 1px solid rgba(100, 116, 139, 0.3);
  border-radius: 10px;
  padding: 0.75em;
  display: flex;
  flex-direction: column;
  gap: 0.75em;
}

.ccm-textarea {
  resize: vertical;
}

.ccm-difficulty-dropdown {
  position: relative;
}

.ccm-difficulty-trigger {
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
}

.ccm-difficulty-trigger:hover {
  background: rgba(30, 41, 59, 0.8);
  border-color: rgba(100, 116, 139, 0.5);
}

.ccm-difficulty-chevron {
  opacity: 0.8;
  font-size: 0.9em;
}

.ccm-difficulty-content {
  position: fixed;
  background: rgba(15, 23, 42, 0.98);
  border: 1px solid rgba(71, 85, 105, 0.6);
  border-radius: 8px;
  padding: 0.25em;
  box-shadow: 0 10px 30px rgba(0, 0, 0, 0.5);
  max-height: 12.5em;
  overflow: auto;
  z-index: 3001;
  font-size: inherit;
}

.ccm-difficulty-option {
  padding: 0.5em;
  border-radius: 6px;
  cursor: pointer;
  color: #fff;
  transition: background 0.2s ease;
  font-size: inherit;
}

.ccm-difficulty-option:hover,
.ccm-difficulty-option:focus {
  background: rgba(30, 41, 59, 0.6);
  outline: none;
}

.ccm-difficulty-option.ccm-difficulty-selected {
  background: rgba(59, 130, 246, 0.2);
  color: #60a5fa;
}

.ccm-map-dropdown {
  position: relative;
}

.ccm-map-trigger {
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
}

.ccm-map-trigger:hover {
  background: rgba(30, 41, 59, 0.8);
  border-color: rgba(100, 116, 139, 0.5);
}

.ccm-map-chevron {
  opacity: 0.8;
  font-size: 0.9em;
}

.ccm-map-content {
  position: fixed;
  background: rgba(15, 23, 42, 0.98);
  border: 1px solid rgba(71, 85, 105, 0.6);
  border-radius: 8px;
  padding: 0.25em;
  box-shadow: 0 10px 30px rgba(0, 0, 0, 0.5);
  max-height: 12.5em;
  overflow: auto;
  z-index: 3001;
  font-size: inherit;
}

.ccm-map-option {
  padding: 0.5em;
  border-radius: 6px;
  cursor: pointer;
  color: #fff;
  transition: background 0.2s ease;
  font-size: inherit;
}

.ccm-map-option:hover,
.ccm-map-option:focus {
  background: rgba(30, 41, 59, 0.6);
  outline: none;
}

.ccm-map-option.ccm-map-selected {
  background: rgba(59, 130, 246, 0.2);
  color: #60a5fa;
}

.ccm-map-sep {
  height: 1px;
  background: rgba(71, 85, 105, 0.5);
  margin: 0.25em 0;
}
</style>
