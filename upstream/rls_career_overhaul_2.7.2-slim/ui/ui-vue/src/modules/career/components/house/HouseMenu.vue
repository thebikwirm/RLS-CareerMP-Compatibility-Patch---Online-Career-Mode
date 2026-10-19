<!-- Style Guide dropdown (.menu / .menu-btn / .menu-list / .menu-item). Never a native select.
     items: [{ value, label, meta?, disabled? }]  (same shape BngDropdown takes). -->
<template>
  <div ref="root" class="rls-house menu house-menu" :class="{ open, compact, up: openUp, disabled }" @focusout="onFocusOut">
    <button
      ref="btn"
      type="button"
      class="menu-btn"
      :disabled="disabled"
      aria-haspopup="listbox"
      :aria-expanded="open"
      v-bind="navAttrs(disabled)"
      v-bng-sound-class="!disabled && 'bng_click_hover_generic'"
      @click="toggle">
      <span class="menu-value">{{ selected ? selected.label : placeholder }}</span>
      <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 9l6 6 6-6" /></svg>
    </button>
    <!-- controller: the open list is its own scope (d-pad stays inside and wraps top/bottom), B closes it
         and gives focus back to the trigger instead of leaving the screen -->
    <div
      v-if="open"
      class="menu-list"
      :class="{ scrolls: items.length > SCROLL_AFTER }"
      role="listbox"
      v-bng-scoped-nav="listScope"
      v-bng-on-ui-nav:back,menu="onNavBack"
      v-bng-ui-nav-scroll
      @keydown.esc.stop.prevent="close(true)">
      <button
        v-for="(item, idx) in items"
        :key="item.value"
        type="button"
        class="menu-item"
        role="option"
        :data-idx="idx"
        :class="{ selected: item.value === modelValue }"
        :aria-selected="item.value === modelValue"
        :disabled="item.disabled"
        v-bind="navAttrs(item.disabled)"
        @click="pick(item)">
        {{ item.label }}
        <span v-if="item.meta" class="meta">{{ item.meta }}</span>
      </button>
    </div>
  </div>
</template>

<script setup>
import { computed, nextTick, onBeforeUnmount, ref, watch } from "vue"
import { vBngSoundClass, vBngScopedNav, vBngOnUiNav, vBngUiNavScroll } from "@/common/directives"

const props = defineProps({
  modelValue: [String, Number, Boolean],
  items: { type: Array, default: () => [] },
  placeholder: { type: String, default: "Choose…" },
  compact: Boolean,
  disabled: Boolean,
})
const emit = defineEmits(["update:modelValue", "change"])

const root = ref(null)
const btn = ref(null)
// disabled triggers / options leave controller navigation: crossfire would still step onto them and
// strand the d-pad (it never filters `disabled`)
const navAttrs = isDisabled => (isDisabled ? { "bng-nav-item": "", "bng-no-nav": "true" } : { "bng-nav-item": "" })
const open = ref(false)
const openUp = ref(false)

const selected = computed(() => props.items.find(i => i.value === props.modelValue))

// short lists never scroll: the game's focus frame sits just outside the focused item, and in a
// scroll box that overflow alone was enough to show scrollbars under "100 per page"
const SCROLL_AFTER = 8

const onDocDown = e => {
  if (root.value && !root.value.contains(e.target)) close(false)
}

const clipBottom = () => {
  let bottom = window.innerHeight
  for (let el = root.value?.parentElement; el && el !== document.body; el = el.parentElement) {
    if (getComputedStyle(el).overflowY !== "visible") bottom = Math.min(bottom, el.getBoundingClientRect().bottom)
  }
  return bottom
}

const toggle = async () => {
  if (open.value) return close(false)
  if (props.disabled) return
  // nothing pickable: opening would trap the d-pad in a list with no focusable item
  if (!props.items.some(i => !i.disabled)) return
  // open upwards when there isn't room below, measured against the nearest clipping ancestor
  // (a card with overflow hidden/auto), not just the window
  const r = btn.value?.getBoundingClientRect()
  openUp.value = !!r && clipBottom() - r.bottom < Math.min(260, props.items.length * 40 + 20)
  open.value = true
  document.addEventListener("mousedown", onDocDown, true)
  await nextTick()
  // open on the selected option if it can be picked, else the first enabled one
  let idx = props.items.findIndex(i => i.value === props.modelValue && !i.disabled)
  if (idx < 0) idx = props.items.findIndex(i => !i.disabled)
  root.value?.querySelector(`.menu-item[data-idx="${idx}"]`)?.focus()
}

// the list is a container scope: focus cannot leave it, and back/menu never bubble up to the screen
// (which would close the screen or cancel a purchase). Same shape as the game's container escape guard.
// ok stays too: the scope already clicks the focused item, and bubbling made the global handler click it
// a second time.
const listScope = {
  type: "container",
  preventNavigationEscape: ["top", "bottom", "left", "right"],
  canBubbleEvent: event => !["back", "menu", "ok"].includes(event?.detail?.name),
}

const onNavBack = () => {
  close(true)
  return false
}

// focus moved somewhere outside the menu (d-pad elsewhere, a click on the page): close quietly
const onFocusOut = event => {
  if (!open.value) return
  const next = event.relatedTarget
  if (next && root.value?.contains(next)) return
  nextTick(() => {
    if (open.value && !root.value?.contains(document.activeElement)) close(false)
  })
}

const close = (refocus = false) => {
  open.value = false
  document.removeEventListener("mousedown", onDocDown, true)
  if (refocus) btn.value?.focus()
}

const pick = item => {
  if (item.disabled) return
  if (item.value !== props.modelValue) {
    emit("update:modelValue", item.value)
    emit("change", item.value)
  }
  close(true)
}

watch(() => props.disabled, d => d && close(false))
onBeforeUnmount(() => document.removeEventListener("mousedown", onDocDown, true))
</script>

<style scoped lang="scss">
@import "../../styles/rlsHouse.scss";

.house-menu {
  min-width: 0;
  &.disabled {
    opacity: 0.45;
  }
  &.up .menu-list {
    top: auto;
    bottom: calc(100% + 0.45em);
  }
}
.menu-btn {
  font-weight: 700;
  &:disabled {
    cursor: default;
  }
}
.menu-value {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  // room for descenders ("g", "y") inside the clip box without changing the trigger's height
  padding-bottom: 0.15em;
  margin-bottom: -0.15em;
}
.menu-list {
  padding: 0.5em;
  overflow: visible;
}
.menu-list.scrolls {
  max-height: 16em;
  overflow-x: hidden;
  overflow-y: auto;
  // slim house scrollbar; no scrollbar-width / scrollbar-color, which make Chromium 121+ ignore these rules
  &::-webkit-scrollbar { width: 0.45em; }
  &::-webkit-scrollbar-track { background: transparent; }
  &::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.22);
    border-radius: 1em;
  }
}
.menu-item {
  white-space: nowrap;
}
.menu-item:focus-visible,
.menu-item.focus-visible {
  outline: none;
  background: rgba(255, 255, 255, 0.08);
}
.menu-item:disabled {
  opacity: 0.45;
  cursor: default;
}
</style>
