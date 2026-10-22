<template>
  <teleport to="body">
    <div
      v-bng-scoped-nav="{ activateOnMount: true, trapPolicy: 'always', autoFocusDelay: 0, canDeactivate: () => (emit('close'), false) }"
      class="ccm-multiselect-overlay" data-focus-host
      @click.stop="emit('close')"
      @mousedown.stop>
      <div class="ccm-multiselect-modal" @click.stop @mousedown.stop>
        <div class="ccm-multiselect-header">
          <div class="ccm-multiselect-title">{{ variableLabel || 'Select Items' }}</div>
          <button class="ccm-multiselect-close" @click.stop="emit('close')" @mousedown.stop>×</button>
        </div>
        <div class="ccm-multiselect-body">
          <div v-if="selectedIds.length > 0" class="ccm-multiselect-selected-section">
            <div class="ccm-multiselect-selected-title">
              Selected {{ variableLabel || 'Items' }} ({{ selectedIds.length }})
            </div>
            <div class="ccm-multiselect-selected-list">
              <div v-for="itemId in selectedIds" :key="itemId" class="ccm-multiselect-selected-item">
                <span>{{ itemName(itemId) }}</span>
                <button
                  class="ccm-multiselect-remove"
                  type="button"
                  @click.stop="emit('remove', itemId)"
                  @mousedown.stop
                >
                  ×
                </button>
              </div>
            </div>
          </div>

          <div class="ccm-multiselect-field">
            <input v-bng-text-input
              v-model="queryModel"
              class="ccm-multiselect-input"
              :placeholder="`Search ${variableLabel?.toLowerCase() || 'items'}...`"
            />
          </div>

          <div class="ccm-multiselect-list">
            <div v-for="item in options" :key="item.id" class="ccm-multiselect-row">
              <label class="ccm-multiselect-label">
                <input
                  v-model="selectedModel"
                  :value="item.id"
                  type="checkbox"
                  class="ccm-multiselect-checkbox"
                />
                <div class="ccm-multiselect-info">
                  <div class="ccm-multiselect-name">{{ item.name }}</div>
                  <div class="ccm-multiselect-details">
                    <span v-if="item.price" class="ccm-multiselect-price"><BngIcon class="cur" :type="icons.beamCurrency" />{{ item.price?.toLocaleString() || '0' }}</span>
                    <span v-if="item.capacity" class="ccm-multiselect-capacity">{{ item.capacity || 0 }} slots</span>
                    <span v-if="item.category" class="ccm-multiselect-category">{{ item.category }}</span>
                    <span v-if="item.starterGarage" class="ccm-multiselect-starter">Starter</span>
                  </div>
                </div>
              </label>
            </div>
          </div>
        </div>
        <div class="ccm-multiselect-footer">
          <button class="ccm-multiselect-save" @click.stop="emit('close')" @mousedown.stop>Done</button>
        </div>
      </div>
    </div>
  </teleport>
</template>

<script setup>
// The multiselect picker, teleported to body. The parent decides which variable is open and owns its values.
// The checkbox list writes the whole selection back through update:selected. The selection stays raw (it may
// be undefined before the first edit), because the checkbox's v-model needs that exact value.
import { computed } from 'vue'
import { BngIcon, icons } from '@/common/components/base'
import { vBngScopedNav, vBngTextInput } from '@/common/directives'

const props = defineProps({
  variableLabel: { default: undefined },
  selected: { default: undefined },
  query: { default: undefined },
  options: { type: Array, default: () => [] },
  itemName: { type: Function, required: true },
})
const emit = defineEmits(['update:selected', 'update:query', 'remove', 'close'])

const selectedIds = computed(() => props.selected || [])
const selectedModel = computed({ get: () => props.selected, set: value => emit('update:selected', value) })
const queryModel = computed({ get: () => props.query, set: value => emit('update:query', value) })
</script>

<style scoped lang="scss">
.ccm-multiselect-overlay {
  position: fixed;
  inset: 0;
  background: radial-gradient(ellipse at center, rgba(2, 8, 23, 0.6), rgba(2, 8, 23, 0.75));
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 3001;
}

.ccm-multiselect-modal {
  width: min(42em, 90vw);
  max-width: calc(100vw - 2em);
  background: rgba(15, 23, 42, 0.98);
  border: 1px solid rgba(71, 85, 105, 0.6);
  border-radius: 14px;
  box-shadow: 0 30px 80px rgba(0, 0, 0, 0.6);
  color: #fff;
  font-size: calc-ui-rem();
  max-height: 90vh;
  display: flex;
  flex-direction: column;
}

.ccm-multiselect-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 1em 1.5em;
  border-bottom: 1px solid rgba(71, 85, 105, 0.6);
}

.ccm-multiselect-title {
  font-weight: 600;
  font-size: 1.05em;
}

.ccm-multiselect-close {
  background: transparent;
  border: 0;
  color: #94a3b8;
  font-size: 1.25em;
  cursor: pointer;
  padding: 0;
  width: 1.5em;
  height: 1.5em;
  display: flex;
  align-items: center;
  justify-content: center;
  line-height: 1;
}

.ccm-multiselect-close:hover {
  color: #e2e8f0;
}

.ccm-multiselect-body {
  padding: 1em 1.5em;
  overflow-y: auto;
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 1em;
}

.ccm-multiselect-selected-section {
  background: rgba(59, 130, 246, 0.08);
  border: 1px solid rgba(59, 130, 246, 0.25);
  border-radius: 8px;
  padding: 0.75em;
}

.ccm-multiselect-selected-title {
  font-weight: 600;
  margin-bottom: 0.5em;
  color: #3b82f6;
}

.ccm-multiselect-selected-list {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5em;
}

.ccm-multiselect-selected-item {
  background: rgba(59, 130, 246, 0.15);
  border: 1px solid rgba(59, 130, 246, 0.3);
  border-radius: 6px;
  padding: 0.25em 0.5em;
  display: flex;
  align-items: center;
  gap: 0.5em;
  font-size: 0.85em;
}

.ccm-multiselect-remove {
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

.ccm-multiselect-remove:hover {
  background: rgba(239, 68, 68, 0.2);
}

.ccm-multiselect-field {
  display: flex;
  flex-direction: column;
  gap: 0.25em;
}

.ccm-multiselect-input {
  background: rgba(30, 41, 59, 0.6);
  border: 1px solid rgba(100, 116, 139, 0.35);
  color: #fff;
  border-radius: 8px;
  padding: 0.5em;
  font-size: inherit;
}

.ccm-multiselect-list {
  display: grid;
  grid-template-columns: 1fr;
  gap: 0.5em;
  max-height: 20em;
  overflow: auto;
  padding-right: 0.25em;
  scrollbar-width: thin;
  scrollbar-color: rgba(100, 116, 139, 0.5) transparent;
}

.ccm-multiselect-list::-webkit-scrollbar {
  width: 8px;
}

.ccm-multiselect-list::-webkit-scrollbar-track {
  background: transparent;
  border-radius: 4px;
}

.ccm-multiselect-list::-webkit-scrollbar-thumb {
  background: rgba(100, 116, 139, 0.5);
  border-radius: 4px;
}

.ccm-multiselect-list::-webkit-scrollbar-thumb:hover {
  background: rgba(100, 116, 139, 0.7);
}

.ccm-multiselect-row {
  display: flex;
  align-items: center;
}

.ccm-multiselect-label {
  display: flex;
  align-items: center;
  gap: 0.75em;
  cursor: pointer;
  padding: 0.5em;
  border-radius: 6px;
  transition: background 0.2s ease;
  width: 100%;
}

.ccm-multiselect-label:hover {
  background: rgba(100, 116, 139, 0.1);
}

.ccm-multiselect-checkbox {
  width: 1.125em;
  height: 1.125em;
  cursor: pointer;
  accent-color: #3b82f6;
}

.ccm-multiselect-info {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 0.25em;
}

.ccm-multiselect-name {
  font-weight: 500;
  color: #e2e8f0;
}

.ccm-multiselect-details {
  display: flex;
  gap: 0.75em;
  font-size: 0.8em;
  color: #94a3b8;
}

.ccm-multiselect-price {
  color: #22c55e;
  font-weight: 500;
}

.ccm-multiselect-capacity {
  color: #8b5cf6;
}

.ccm-multiselect-category {
  color: #f59e0b;
}

.ccm-multiselect-starter {
  background: rgba(34, 197, 94, 0.2);
  color: #22c55e;
  padding: 0.1em 0.4em;
  border-radius: 4px;
  font-size: 0.75em;
  font-weight: 500;
}

.ccm-multiselect-footer {
  display: flex;
  gap: 0.5em;
  padding: 1em 1.5em;
  border-top: 1px solid rgba(71, 85, 105, 0.6);
  justify-content: flex-end;
}

.ccm-multiselect-save {
  background: linear-gradient(90deg, #2563eb, #1d4ed8);
  border: 0;
  color: #fff;
  padding: 0.6em 1em;
  border-radius: 8px;
  cursor: pointer;
  font-size: inherit;
}

.ccm-multiselect-save:hover {
  opacity: 0.9;
}

/* Game currency glyph before amounts; inherits colour/size. */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
