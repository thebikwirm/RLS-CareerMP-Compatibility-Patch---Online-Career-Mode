<!-- RLS override of the vanilla "required vehicle class" panel (mission details, big map POI).
     House look: caption title, "yours" and "required" stickers with a plain check / cross glyph between
     them (no coloured circle), and a one-line status that is green when met and red only when not. -->
<template>
  <!-- Renders nothing when there is no requirement to display. -->
  <div v-if="requiredVehicleClass" class="rls-house vehicle-class-panel" :class="[`variant-${variant}`, `state-${effectiveState}`]">
    <span class="caption vehicle-class-panel-title">{{ $t("ui.career.performance.requiredVehicleClassLabel") }}</span>
    <div class="vehicle-class-panel-row">
      <div class="vehicle-class-item">
        <span class="vehicle-class-item-label">{{ $t("ui.career.performance.yoursLabel") }}</span>
        <PerformanceIndexSticker
          :vehicle-class="currentVehicleClass"
          :show-index="false"
          :size="stickerSize" />
      </div>
      <div class="vehicle-class-match-badge" :class="`state-${effectiveState}`" :style="badgeSizeStyle">
        <BngIcon
          v-if="badgeIcon"
          class="vehicle-class-match-icon"
          :style="iconSizeStyle"
          :type="badgeIcon" />
      </div>
      <div class="vehicle-class-item">
        <span class="vehicle-class-item-label">{{ $t("ui.career.performance.requiredLabel") }}</span>
        <PerformanceIndexSticker
          :vehicle-class="requiredVehicleClass"
          :show-index="false"
          :size="stickerSize" />
      </div>
    </div>
    <span class="vehicle-class-panel-status">
      {{ $t(statusKey) }}
    </span>
  </div>
</template>

<script setup>
import { computed } from "vue"
import { BngIcon, icons } from "@/common/components/base"
import PerformanceIndexSticker from "@/modules/career/components/vehiclePerformance/PerformanceIndexSticker.vue"

const props = defineProps({
  requiredVehicleClass: {
    type: Object,
    default: null,
  },
  currentVehicleClass: {
    type: Object,
    default: null,
  },
  // Lua-precomputed match state. "auto" derives it from the two class objects;
  // pass an explicit "met"/"unmet"/"unknown" when the backend already resolved it.
  state: {
    type: String,
    default: "auto",
    validator: v => ["auto", "met", "unmet", "unknown"].includes(v),
  },
  // Visual variant. Avoids hardcoded color literals at call sites.
  // - "panel"   -> translucent light surface for in-page panels (mission details).
  // - "overlay" -> translucent dark surface for image-overlay contexts (big map).
  variant: {
    type: String,
    default: "panel",
    validator: v => ["panel", "overlay"].includes(v),
  },
  stickerSize: {
    type: String,
    default: "lg",
    validator: v => ["sm", "md", "lg"].includes(v),
  },
  badgeSize: {
    type: String,
    default: "2.5rem",
  },
  iconSize: {
    type: String,
    default: "1.6rem",
  },
})

const effectiveState = computed(() => {
  if (props.state !== "auto") return props.state
  const req = props.requiredVehicleClass
  const own = props.currentVehicleClass
  if (!req || !own) return "unknown"
  return req.class?.name === own.class?.name ? "met" : "unmet"
})

const badgeIcon = computed(() => {
  switch (effectiveState.value) {
    case "met": return icons.checkmarkBold
    case "unmet": return icons.xmarkBold
    default: return null
  }
})

const statusKey = computed(() => {
  switch (effectiveState.value) {
    case "met": return "ui.career.performance.requirementSatisfied"
    case "unmet": return "ui.career.performance.requirementNotSatisfied"
    default: return "ui.career.performance.requirementUnknown"
  }
})

const badgeSizeStyle = computed(() => ({ width: props.badgeSize, height: props.badgeSize }))
const iconSizeStyle = computed(() => ({ "--bng-icon-size": props.iconSize }))
</script>

<style lang="scss" scoped>
@import "../../styles/rlsHouse.scss";

.vehicle-class-panel {
  display: grid;
  gap: 0.75em;
  padding: 0.9em 1em 0.85em;
  border-radius: var(--radius-panel);

  &.variant-panel {
    background-color: var(--panel);
  }

  &.variant-overlay {
    background-color: rgba(21, 21, 23, 0.78);
    box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.06);
  }
}

.vehicle-class-panel-title {
  line-height: 1;
}

.vehicle-class-panel-row {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-end;
  justify-content: flex-start;
  gap: 1.1em;
}

.vehicle-class-item {
  display: inline-flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 0.4em;
}

.vehicle-class-item-label {
  color: var(--faint);
  font-size: 0.8em;
  font-weight: 600;
  line-height: 1;
}

/* plain glyph between the two stickers; size still follows the badgeSize / iconSize props */
.vehicle-class-match-badge {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex: 0 0 auto;

  &.state-met { color: var(--ok-ink); }
  &.state-unmet { color: var(--bad); }
  &.state-unknown { color: var(--faint); }

  .vehicle-class-match-icon {
    --bng-icon-color: currentColor;
  }
}

.vehicle-class-panel-status {
  color: var(--muted);
  font-size: 0.88em;
  font-weight: 600;
  line-height: 1.3;
  .state-met & { color: var(--ok-ink); }
  .state-unmet & { color: var(--bad); }
  .state-unknown & { color: var(--faint); }
}
</style>
