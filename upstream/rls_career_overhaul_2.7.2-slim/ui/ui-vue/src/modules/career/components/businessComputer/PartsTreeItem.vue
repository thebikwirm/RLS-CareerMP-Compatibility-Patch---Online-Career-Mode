<template>
  <!-- cart line (house ShoppingCart look): fold chevron, quiet-danger remove, name over faint slot, gold price -->
  <div class="tree-node rls-house">
    <div class="cart-item" :class="{ 'is-child': level > 0 }" :style="{ paddingLeft: (level * 1.1) + 'em' }">
      <!-- Collapse/Expand button for nodes with children -->
      <button
        v-if="hasChildren"
        class="collapse-button"
        type="button"
        @click="isCollapsed = !isCollapsed"
        :title="isCollapsed ? 'Expand' : 'Collapse'"
        :aria-expanded="!isCollapsed"
      >
        <svg viewBox="0 0 24 24" aria-hidden="true" :class="{ rotated: isCollapsed }">
          <path d="m6 9 6 6 6-6" />
        </svg>
      </button>
      <div v-else class="collapse-button-placeholder"></div>

      <HouseButton
        v-if="node.canRemove !== false"
        class="remove-button"
        variant="quiet-danger"
        compact
        :icon="icons.abandon"
        :aria-label="removeAriaLabel"
        :title="removeAriaLabel"
        @click="$emit('remove', node.id)" />
      <div v-else class="remove-button-placeholder"></div>
      <div class="item-info">
        <div class="item-name">
          <span>{{ node.partNiceName || node.partName }}</span>
          <span v-if="hasChildren && isCollapsed" class="pill children-count">+{{ childrenCount }}</span>
        </div>
        <div class="item-slot">{{ node.slotNiceName || node.slotName }}</div>
      </div>
      <div class="item-price">
        <span v-if="hasChildren && isCollapsed" class="total-price">
          <BngIcon class="cur" :type="icons.beamCurrency" />{{ childrenTotalCost.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) }}
        </span>
        <span v-else>
          <BngIcon class="cur" :type="icons.beamCurrency" />{{ (node.price || 0).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) }}
        </span>
      </div>
    </div>
    <transition name="collapse">
      <div v-if="hasChildren && !isCollapsed" class="children-container">
        <PartsTreeItem
          v-for="child in node.children"
          :key="child.id"
          :node="child"
          :level="level + 1"
          @remove="$emit('remove', $event)"
        />
      </div>
    </transition>
  </div>
</template>

<script setup>
import { ref, computed } from 'vue'
import { BngIcon, icons } from '@/common/components/base'
import { HouseButton } from '../house'

const props = defineProps({
  node: {
    type: Object,
    required: true
  },
  level: {
    type: Number,
    default: 0
  }
})

defineEmits(['remove'])

const isCollapsed = ref(false)

const hasChildren = computed(() => {
  return props.node.children && props.node.children.length > 0
})

const childrenCount = computed(() => {
  if (!hasChildren.value) return 0
  
  const countAllDescendants = (node) => {
    let count = 0
    if (node.children && node.children.length > 0) {
      for (const child of node.children) {
        count += 1 // Count the child itself
        count += countAllDescendants(child) // Recursively count its descendants
      }
    }
    return count
  }
  
  return countAllDescendants(props.node)
})

const removeAriaLabel = computed(() => {
  const partName = props.node.partNiceName || props.node.partName
  const slotName = props.node.slotNiceName || props.node.slotName
  if (partName && slotName) return `Remove ${partName} from ${slotName}`
  if (partName) return `Remove ${partName}`
  if (props.node.id) return `Remove part ${props.node.id}`
  return 'Remove part'
})

const childrenTotalCost = computed(() => {
  if (!hasChildren.value) return 0
  
  const calculateTotal = (node) => {
    let total = node.price || 0
    if (node.children && node.children.length > 0) {
      for (const child of node.children) {
        total += calculateTotal(child)
      }
    }
    return total
  }
  
  return calculateTotal(props.node)
})
</script>

<style scoped lang="scss">
@import "../../styles/rlsHouse.scss";

.tree-node {
  display: flex;
  flex-direction: column;
}

.cart-item {
  display: flex;
  align-items: center;
  gap: var(--space-2);
  min-height: 2.9em;
  padding-top: 0.45em;
  padding-bottom: 0.35em;
  border-top: 1px solid var(--line);
  font-variant-numeric: tabular-nums;
  &.is-child {
    min-height: 2.4em;
    border-top: 0;
  }
}
// top-level entries are divided; the first one sits right under the caption header
.tree-node:first-child > .cart-item:not(.is-child) {
  border-top: 0;
}

.collapse-button {
  appearance: none;
  display: grid;
  place-items: center;
  flex: 0 0 auto;
  width: 1.5em;
  height: 1.5em;
  margin: 0;
  padding: 0;
  border: 0;
  border-radius: var(--radius-thumb);
  background: transparent;
  color: var(--faint);
  cursor: pointer;
  &:hover {
    background: var(--panel);
    color: #fff;
  }
  @include house-focus;
  svg {
    width: 0.9em;
    height: 0.9em;
    fill: none;
    stroke: currentColor;
    stroke-width: 2.4;
    stroke-linecap: round;
    stroke-linejoin: round;
    transition: transform 0.12s;
    &.rotated {
      transform: rotate(-90deg);
    }
  }
}
.collapse-button-placeholder {
  flex: 0 0 auto;
  width: 1.5em;
}

.remove-button.house-button {
  flex: 0 0 auto;
  font-size: 0.85em;
  padding: 0.3em 0.4em 0.25em;
  border-radius: var(--radius-thumb);
}
.remove-button-placeholder {
  flex: 0 0 auto;
  width: 2em;
}

.item-info {
  flex: 1 1 auto;
  min-width: 0;
  display: grid;
  gap: 0.15em;
}
.item-name {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.2em 0.45em;
  color: #fff;
  font-weight: 600;
  line-height: 1.25;
  overflow-wrap: anywhere;
}
.item-slot {
  color: var(--faint);
  font-size: 0.82em;
  font-weight: 600;
  overflow-wrap: anywhere;
}

.item-price {
  flex: 0 0 auto;
  color: var(--money);
  font-weight: 700;
  font-variant-numeric: tabular-nums;
  text-align: right;
  white-space: nowrap;
  .total-price {
    font-weight: 800;
  }
}

// fold: opacity only
.collapse-enter-active,
.collapse-leave-active {
  transition: opacity 0.15s ease;
}
.collapse-enter-from,
.collapse-leave-to {
  opacity: 0;
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
