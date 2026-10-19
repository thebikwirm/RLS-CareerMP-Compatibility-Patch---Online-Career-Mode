<!-- RLS override of the vanilla class/PI sticker (also used by mission settings, mission details and the
     big map). House pill: dark translucent ground, class in the warm accent, index in white tabular
     figures, a hairline instead of the "|" separator. The vanilla red-to-green class colour still comes in
     through :style on the root, but every visible part sets its own colour so it never shows. -->
<template>
  <span class="rls-house performance-index-sticker"
    :class="[
      `size-${size}`,
      { 'is-na': !hasData, 'high-contrast': highContrast }
    ]"
    :style="stickerStyle">
    <template v-if="hasData">
      <span v-if="showClass" class="class-name">
        <template v-if="longText">{{ $t(classKey) }}</template>
        <template v-else>{{ className }}</template>
      </span>
      <span v-if="showClass && showIndex" class="separator" aria-hidden="true"></span>
      <span v-if="showIndex && longText" class="index-prefix">{{ $t("ui.career.performance.indexLabelLong") }}</span>
      <span v-if="showIndex" class="index-value">{{ indexValue }}</span>
    </template>
    <span v-else class="na-text">{{ $t("ui.common.unknown") }}</span>
  </span>
</template>

<script setup>
import { computed } from "vue"

const props = defineProps({
  vehicleClass: {
    type: Object,
    default: null,
  },
  size: {
    type: String,
    default: "md",
    validator: v => ["sm", "md", "lg"].includes(v),
  },
  showClass: {
    type: Boolean,
    default: true,
  },
  showIndex: {
    type: Boolean,
    default: true,
  },
  longText: {
    type: Boolean,
    default: true,
  },
  highContrast: {
    type: Boolean,
    default: false,
  },
})

const hasData = computed(() =>
  !!(props.vehicleClass && props.vehicleClass.class && typeof props.vehicleClass.performanceIndex === "number")
)

const className = computed(() => props.vehicleClass?.class?.name ?? "")

const indexValue = computed(() =>
  hasData.value ? props.vehicleClass.performanceIndex.toFixed(0) : ""
)

const classKey = computed(() => `ui.career.performance.class${className.value}`)

const classIndexMap = { D: 0, C: 1, B: 2, A: 3, S: 4, X: 5 }
const classCount = 5

const getRgbForValue = (value, min = 0, max = 1) => {
  const normalized = (value - min) / (max - min)
  const adjusted = Math.max(0, normalized - 0.1) * (1 / 0.9)
  let red, green
  if (adjusted < 0.5) {
    red = 200
    green = Math.round(200 * (adjusted * 2))
  } else {
    red = Math.max(0, Math.round(200 * (2 - adjusted * 2)))
    green = 200
  }
  return [red, green, 0]
}

const classColor = computed(() => {
  const idx = classIndexMap[className.value]
  if (idx === undefined) return null
  const [r, g, b] = getRgbForValue(idx, 0, classCount)
  return `rgb(${r}, ${g}, ${b})`
})

const stickerStyle = computed(() => {
  if (!hasData.value || !classColor.value) return null
  return {
    color: classColor.value,
    borderColor: classColor.value,
  }
})
</script>

<style lang="scss" scoped>
@import "../../styles/rlsHouse.scss";

.performance-index-sticker {
  display: inline-flex;
  align-items: center;
  gap: 0.45em;
  width: fit-content;
  border: 0 !important; /* the vanilla class colour arrives as an inline border colour */
  border-radius: var(--radius-pill);
  background-color: rgba(21, 21, 23, 0.72);
  box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.08);
  font-weight: 700;
  line-height: 1;
  white-space: nowrap;
}

.class-name {
  color: var(--accent-soft);
  font-weight: 800;
}

.separator {
  align-self: stretch;
  width: 1px;
  margin: 0.05em 0 0.15em;
  background: rgba(255, 255, 255, 0.22);
}

.index-prefix {
  color: var(--faint);
  font-weight: 600;
}

.index-value {
  color: #fff;
  font-weight: 800;
  font-variant-numeric: tabular-nums;
}

.is-na .na-text {
  color: var(--faint);
  font-weight: 600;
}

/* Overpass sits high in a line-height:1 box: more padding on top than below */
.size-sm {
  font-size: 0.85em;
  padding: 0.45em 0.6em 0.2em;
}

.size-md {
  font-size: 1em;
  padding: 0.5em 0.7em 0.25em;
}

.size-lg {
  font-size: 1.1em;
  padding: 0.55em 0.8em 0.3em;
}

.high-contrast {
  background-color: rgba(10, 10, 12, 0.88);
}
</style>
