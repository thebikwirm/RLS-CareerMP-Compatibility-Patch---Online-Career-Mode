<template>
  <Accordion>
    <BusinessPartsSlotItem
      v-for="childSlot in sortedChildren"
      :key="childSlot.path"
      :static="!childSlot.chosenPartName || !childSlot.children || Object.keys(childSlot.children).length === 0"
      :expanded="!!expandedSlots[childSlot.path]"
      :path="childSlot.path"
      :slot-nice-name="childSlot.slotNiceName"
      :part-nice-name="childSlot.chosenPartNiceName"
      @open-slot="openSlot"
      @set-expanded="setExpanded"
    >
      <BusinessPartsSlotTree
        v-if="childSlot.children && Object.keys(childSlot.children).length > 0"
        :children="childSlot.children"
        :expanded-slots="expandedSlots"
        @open-slot="openSlot"
        @set-expanded="setExpanded"
      />
    </BusinessPartsSlotItem>
  </Accordion>
</template>

<script setup>
import { computed } from "vue"
import { Accordion } from "@/common/components/utility"
import BusinessPartsSlotItem from "./BusinessPartsSlotItem.vue"
import BusinessPartsSlotTree from "./BusinessPartsSlotTree.vue"

const props = defineProps({
  children: {
    type: [Array, Object],
    default: () => [],
  },
  expandedSlots: {
    type: Object,
    default: () => ({}),
  },
})

const emit = defineEmits(["open-slot", "set-expanded"])

const sortedChildren = computed(() => Object.values(props.children || {})
  .filter(Boolean)
  .sort((a, b) => (a.slotNiceName || a.slotName || "").localeCompare(b.slotNiceName || b.slotName || "")))

const openSlot = path => emit("open-slot", path)
const setExpanded = (path, expanded) => emit("set-expanded", path, expanded)
</script>
