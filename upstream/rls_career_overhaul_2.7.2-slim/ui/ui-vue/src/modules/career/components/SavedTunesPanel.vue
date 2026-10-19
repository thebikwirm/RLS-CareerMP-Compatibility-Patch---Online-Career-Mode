<template>
  <!-- house .fold: header toggles the list, Save sits beside it; each tune is a .line -->
  <section class="rls-house fold saved-tunes" :class="{ open: !collapsed }" aria-labelledby="saved-tunes-heading">
    <div class="saved-tunes-header">
      <button
        id="saved-tunes-heading"
        type="button"
        class="fold-summary saved-tunes-toggle"
        :aria-expanded="!collapsed"
        @click="collapsed = !collapsed">
        <svg class="fold-chevron" viewBox="0 0 24 24" aria-hidden="true"><path d="M9 6l6 6-6 6" /></svg>
        <strong class="saved-tunes-title">Saved tunes</strong>
        <span class="pill saved-tunes-count">{{ tunes.length }}</span>
      </button>
      <HouseButton class="save-btn" compact :icon="icons.floppyDisk" :disabled="busy || readOnly" title="Save the current settings as a tune" @click="$emit('save')">Save</HouseButton>
    </div>

    <div v-if="!collapsed" class="fold-body">
      <p v-if="error" class="notice bad">{{ error }}</p>
      <p v-else-if="tunes.length === 0" class="muted saved-tunes-none">No tunes saved for this vehicle model.</p>
      <div v-else class="lines saved-tunes-list">
        <div v-for="tune in tunes" :key="tune.id" class="line saved-tune">
          <span class="row-copy">
            <strong>{{ tune.name }}</strong>
            <span>{{ tune.variableCount }} {{ tune.variableCount === 1 ? "setting" : "settings" }}</span>
          </span>
          <span class="saved-tune-actions">
            <HouseButton compact :disabled="busy" @click="$emit('apply', tune)">Apply</HouseButton>
            <HouseButton compact variant="quiet-danger" :disabled="busy || readOnly" @click="$emit('delete', tune)">Delete</HouseButton>
          </span>
        </div>
      </div>
      <p v-if="busy" class="muted saved-tunes-busy">Loading tune preview…</p>
    </div>
  </section>
</template>

<script setup>
import { ref } from "vue"
import { HouseButton } from "./house"
import { icons } from "@/common/components/base"

defineProps({
  tunes: { type: Array, default: () => [] },
  readOnly: Boolean,
  error: { type: String, default: "" },
  busy: Boolean,
})

defineEmits(["save", "apply", "delete"])

const collapsed = ref(false)
</script>

<style scoped lang="scss">
@import "../styles/rlsHouse.scss";

.saved-tunes {
  margin: 0.35em 0 0.5em;
}

.saved-tunes-header {
  display: flex;
  align-items: center;
  gap: 0.5em;
  padding-right: 0.6em;
}

.saved-tunes-toggle {
  flex: 1 1 auto;
  min-width: 0;
}

// never squeezed into "Save ..."
.save-btn {
  flex: 0 0 auto;
}

// header: chevron (turns down when open) · title · count pill
.saved-tunes-toggle {
  gap: 0.55em;
  .fold-chevron {
    width: 0.8em;
    height: 0.8em;
    color: var(--faint);
    transition: transform 0.15s ease-out, color 0.12s;
  }
  &:hover .fold-chevron {
    color: #fff;
  }
}
.saved-tunes.open .saved-tunes-toggle .fold-chevron {
  transform: rotate(90deg);
}
.saved-tunes-title {
  line-height: 1.2;
  padding-top: 0.1em; // Overpass sits high
}
.saved-tunes-count {
  font-variant-numeric: tabular-nums;
}

.fold-body {
  gap: 0.45em;
}

.saved-tunes-none,
.saved-tunes-busy {
  font-size: 0.85em;
}

.saved-tune {
  align-items: center;
  padding-top: 0.5em;
  padding-bottom: 0.4em;
}

.saved-tune-actions {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
  gap: 0.35em;
}
</style>
