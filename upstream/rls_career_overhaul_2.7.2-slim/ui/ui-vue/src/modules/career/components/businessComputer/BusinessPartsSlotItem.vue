<template>
  <AccordionItem
    :static="isStatic"
    :expanded="expanded"
    :primary-action="openSlot"
    :expand-on-context="false"
    navigable
    expand-hint-inline
    primary-hint-inline
    @expanded="value => emit('set-expanded', path, value)"
    @selected="openSlot"
  >
    <template #caption>
      <span class="slot-path" v-if="nicePath">{{ nicePath }}</span>
      <span class="slot-name">{{ slotNiceName }}</span>
    </template>
    <template #controls>
      <HouseButton
        bng-no-nav="true"
        class="buy-button"
        compact
        @click="openSlot"
        v-bng-tooltip:top="partNiceName"
      >
        <span class="buy-button-label">{{ partNiceName || "-" }}</span>
      </HouseButton>
    </template>
    <slot />
  </AccordionItem>
</template>

<script setup>
import { computed } from "vue"
import { vBngTooltip } from "@/common/directives"
import { HouseButton } from "../house"
import { AccordionItem } from "@/common/components/utility"

const props = defineProps({
  static: Boolean,
  expanded: Boolean,
  path: String,
  nicePath: String,
  slotNiceName: String,
  partNiceName: String,
})

const emit = defineEmits(["open-slot", "set-expanded"])
const isStatic = computed(() => props.static)
const openSlot = () => emit("open-slot", props.path)
</script>

<style lang="scss" scoped>
// Same as the career Part Shop SlotItem; house tokens come from the .rls-house parts panel.
.bng-accitem .buy-button.house-button {
  max-width: 13em !important;
  min-height: unset;
  margin: 0 0 0 0.35em;
  padding: 0.45em 0.7em 0.32em;
  border-radius: var(--radius-tile, 0.4em);
  color: var(--muted, rgba(255, 255, 255, 0.72));
  font-size: 0.9em;
  font-weight: 600;
  line-height: 1.2;
  &:hover:not(:disabled),
  &:focus-visible,
  &.focus-visible {
    color: #fff;
  }
  .buy-button-label {
    display: inline-block;
    max-width: 100%;
    white-space: normal;
    overflow-wrap: anywhere;
    text-align: right;
  }
}
.slot-name,
.slot-path {
  display: block;
  max-width: 100%;
  white-space: nowrap;
  text-overflow: ellipsis;
  overflow: hidden;
}
.slot-name {
  font-weight: 600;
}
.slot-path {
  color: var(--faint, rgba(255, 255, 255, 0.55));
  font-size: 0.8em;
}
:deep() {
  .bng-accitem-caption-content {
    overflow: hidden !important;
    z-index: 0;
  }
  .bng-accitem-caption-controls {
    overflow: visible !important;
    z-index: 1;
  }
  .bng-accitem-caption-expander {
    z-index: 1;
  }
}
// Expanded / selected rows: slightly brighter panel + accent-soft text, no grey-blue fill or orange gradient.
.bng-accitem.bng-accitem.bng-accitem-expanded > :deep(.bng-accitem-caption) {
  background-color: var(--panel-2, rgba(255, 255, 255, 0.1));
}
.bng-accitem.bng-accitem.bng-accitem-selected > :deep(.bng-accitem-caption) {
  background-image: none !important;
  background-color: var(--panel-2, rgba(255, 255, 255, 0.1));
  .slot-name {
    color: var(--accent-soft, #ffb27a);
  }
}
</style>
