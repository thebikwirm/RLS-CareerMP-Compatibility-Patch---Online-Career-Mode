<!-- Business computer: parts inventory (read-only list), house style. Title + hint, totals as facts,
     one panel per vehicle with a line per part: name, faint mileage, condition pill, gold value, and the
     (disabled) neutral Sell. -->
<template>
  <div class="parts-inventory-tab rls-house">
    <header class="page-head">
      <h2 class="page-title">Parts Inventory</h2>
      <p class="hint">Manage your used car parts collection</p>
    </header>

    <div class="facts totals">
      <div class="fact">
        <span class="fact-key">Total Parts</span>
        <span class="fact-value">{{ Array.isArray(store.parts) ? store.parts.length : 0 }}</span>
      </div>
      <div class="fact money">
        <span class="fact-key">Total Value</span>
        <span class="fact-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(totalValue) }}</span>
      </div>
    </div>

    <div class="parts-groups">
      <section
        v-for="part in groupedParts"
        :key="part.vehicle"
        class="group"
      >
        <div class="group-head">
          <span class="group-title">{{ part.vehicle }}</span>
          <span class="pill">{{ part.parts.length }} {{ part.parts.length === 1 ? 'part' : 'parts' }}</span>
        </div>
        <div class="lines group-lines">
          <div
            v-for="item in part.parts"
            :key="item.partId"
            class="line part-line"
          >
            <div class="part-copy">
              <strong class="part-name">{{ item.name }}</strong>
              <span class="part-meta">
                <span v-if="item.slot">{{ item.slot }}</span>
                <span>{{ partDistance(item) }}</span>
              </span>
            </div>
            <span v-if="item.condition" class="pill" :class="conditionTone(item.condition)">
              {{ item.condition }}
            </span>
            <span v-else></span>
            <span class="part-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(item.price || item.value || 0) }}</span>
            <HouseButton compact disabled title="Selling disabled">Sell</HouseButton>
          </div>
        </div>
      </section>
    </div>

    <div v-if="!Array.isArray(store.parts) || store.parts.length === 0" class="empty">
      <p>No parts in inventory</p>
    </div>
  </div>
</template>

<script setup>
import { computed } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import { HouseButton } from "../house"
import { formatPrice, getConditionClassFromText } from "../../utils/businessUtils"
import { formatOdometer, METERS_PER_MILE } from "../../utils/units"
import { useBridge } from "@/bridge"
import { BngIcon, icons } from "@/common/components/base"

const store = useBusinessComputerStore()
const { units } = useBridge()

// odometer (metres) in the player's distance unit; item.mileage (whole miles) is the fallback
const partDistance = item => formatOdometer(units, item.odometer ?? (item.mileage || 0) * METERS_PER_MILE)

// condition pill tone: green only for Excellent, amber when worn, neutral otherwise
const conditionTone = (text) => {
  if (text === 'Excellent') return 'ok'
  if (text === 'Fair' || text === 'Poor') return 'warn'
  return null
}

const totalValue = computed(() => {
  const parts = Array.isArray(store.parts) ? store.parts : []
  if (parts.length === 0) return 0
  const total = parts.reduce((sum, part) => sum + (part.price || part.value || 0), 0)
  return Math.round(total * 100) / 100
})

const groupedParts = computed(() => {
  const parts = Array.isArray(store.parts) ? store.parts : []
  const groups = {}
  parts.forEach(part => {
    const vehicle = part.compatibleVehicle || "Unknown"
    if (!groups[vehicle]) {
      groups[vehicle] = { vehicle, parts: [] }
    }
    groups[vehicle].parts.push(part)
  })
  return Object.values(groups)
})
</script>

<style scoped lang="scss">
@import "../../styles/rlsHouse.scss";

.parts-inventory-tab {
  display: flex;
  flex-direction: column;
  gap: 1.1em;
}

.page-head {
  display: grid;
  gap: 0.3em;
}
.page-title {
  margin: 0;
  color: #fff;
  font-size: 1.4em;
  font-weight: 800;
  line-height: 1.15;
}
.page-head .hint {
  font-size: 0.9em;
}

.facts.totals {
  grid-template-columns: repeat(2, auto);
  justify-content: start;
  column-gap: 1.8em;
}
.fact-value {
  font-variant-numeric: tabular-nums;
}

.parts-groups {
  display: flex;
  flex-direction: column;
  gap: 0.6em;
}
.group {
  display: grid;
  gap: 0.2em;
  padding: 0.8em var(--inset) 0.5em;
  border-radius: var(--radius-panel);
  background: var(--panel);
}
.group-head {
  display: flex;
  align-items: center;
  gap: 0.6em;
}
.group-title {
  min-width: 0;
  font-size: 1.1em;
  font-weight: 800;
  line-height: 1.2;
  overflow-wrap: anywhere;
}

.part-line {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto 6.5em auto;
  align-items: center;
  gap: 0.9em;
}
.part-copy {
  display: grid;
  gap: 0.2em;
  min-width: 0;
}
.part-name {
  font-weight: 700;
  line-height: 1.2;
  overflow-wrap: anywhere;
}
.part-meta {
  display: flex;
  flex-wrap: wrap;
  gap: 0.2em 0.9em;
  color: var(--faint);
  font-size: 0.8em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}
.part-value {
  justify-self: end;
  color: var(--money);
  font-weight: 800;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}

.empty:not(.bng-button) {
  border-radius: var(--radius-panel);
  background: var(--panel);
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
