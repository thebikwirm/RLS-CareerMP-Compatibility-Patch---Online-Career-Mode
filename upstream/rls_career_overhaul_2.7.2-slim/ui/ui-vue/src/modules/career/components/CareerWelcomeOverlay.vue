<template>
  <Teleport to="body">
    <Transition name="cw-fade">
      <div
        v-if="visible"
        ref="overlayRoot"
        class="cw-overlay"
        role="dialog"
        aria-modal="true"
        aria-label="Welcome to RLS Career Overhaul"
        tabindex="-1"
        v-bng-scoped-nav="{ activateOnMount: true, trapPolicy: 'always', canDeactivate: () => false }"
        @keydown="onDomKey"
      >
        <!-- Controller: a trapping scope while shown (nothing behind it takes the d-pad); entry focus is
             Set shortcut until the phone is bound, then Continue. No B dismiss: the phone has to be bound
             first, and while binding every button press (B too) is captured as the shortcut. -->
        <div class="cw-content" @click.stop>
          <div class="cw-image-container">
            <img
              v-if="imageOk"
              src="/ui/modModules/guide/overhaul.jpg"
              alt="RLS Career Overhaul"
              class="cw-image"
              @error="imageOk = false"
            />
            <div v-else class="cw-image-fallback">RLS Career Overhaul</div>
          </div>

          <div class="cw-welcome-text">
            <p>
              Welcome to <strong>RLS Career Overhaul</strong>! This mod transforms career mode with
              new work systems, freeroam events, police interactions, and an overhauled economy.
              Earn money your way with multiple job types including deliveries, taxi service, bus
              operations, and more.
            </p>
          </div>

          <div class="cw-binding-section">
            <h3 class="cw-binding-header">Phone shortcut</h3>
            <div class="cw-binding-info">
              <span class="cw-binding-action">Toggle phone</span>
              <span v-if="!capturing" class="cw-binding-current">
                Current: <strong>{{ phoneBinding }}</strong>
              </span>
              <span v-else class="cw-binding-waiting">Press a key or mouse button...</span>
            </div>
            <button
              class="cw-binding-button"
              type="button"
              bng-nav-item
              :disabled="capturing"
              :bng-no-nav="capturing ? 'true' : null"
              @click="startCapture">
              {{ capturing ? "Binding..." : bindButtonLabel }}
            </button>
          </div>

          <button
            class="cw-button"
            type="button"
            bng-nav-item
            :disabled="!isPhoneBound || capturing"
            :bng-no-nav="!isPhoneBound || capturing ? 'true' : null"
            @click="onContinue"
          >
            <BngBinding class="cw-glyph" ui-event="ok" controller track-ignore />
            Continue
          </button>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<script setup>
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from "vue"
import { lua, useBridge } from "@/bridge"
import { BngBinding } from "@/common/components/base"
import { vBngScopedNav } from "@/common/directives"
import { useEvents } from "@/services/events"
import { loadingScreen } from "@/services/screenCover"

const SHOW_EVENT = "GuideShowSplash"
const HIDE_EVENT = "GuideHideSplash"
const UNBOUND = "Not bound"
const CODE_TO_CONTROL = {
  Space: "space",
  Enter: "return",
  NumpadEnter: "numpadenter",
  Tab: "tab",
  Backspace: "backspace",
  Escape: "escape",
  ArrowLeft: "left",
  ArrowRight: "right",
  ArrowUp: "up",
  ArrowDown: "down",
  Minus: "minus",
  Equal: "equals",
  BracketLeft: "leftbracket",
  BracketRight: "rightbracket",
  Backslash: "backslash",
  Semicolon: "semicolon",
  Quote: "apostrophe",
  Backquote: "grave",
  Comma: "comma",
  Period: "period",
  Slash: "slash",
  ShiftLeft: "lshift",
  ShiftRight: "rshift",
  ControlLeft: "lcontrol",
  ControlRight: "rcontrol",
  AltLeft: "lalt",
  AltRight: "ralt",
  CapsLock: "capslock",
  Insert: "insert",
  Delete: "delete",
  Home: "home",
  End: "end",
  PageUp: "pageup",
  PageDown: "pagedown",
}

const bridge = useBridge()
const events = useEvents()
const overlayRoot = ref(null)
const open = ref(false)
const imageOk = ref(true)
const phoneBinding = ref(UNBOUND)
const capturing = ref(false)
const visible = computed(() => open.value && !loadingScreen.active && !loadingScreen.shown)
const isPhoneBound = computed(() => {
  const value = phoneBinding.value
  return !!value && value !== UNBOUND
})
const bindButtonLabel = computed(() =>
  isPhoneBound.value ? `Change (${phoneBinding.value})` : "Set shortcut",
)

let controlCaptured = false
let ignoreUntil = 0
let angularOff = null
let windowListening = false

function engineLua(snippet, cb) {
  const api = window.bngApi || window.beamng
  if (typeof api?.engineLua === "function") {
    if (typeof cb === "function") api.engineLua(snippet, cb)
    else api.engineLua(snippet)
    return true
  }
  return false
}

function luaQuote(value) {
  return String(value || "").replace(/\\/g, "\\\\").replace(/'/g, "\\'")
}

function unwrapResult(result) {
  if (Array.isArray(result) && result[0] && typeof result[0] === "object") return result[0]
  if (result && typeof result === "object" && result.binding) return result
  if (typeof result === "string" && result && result !== UNBOUND) return { binding: result, success: true }
  return result && typeof result === "object" ? result : null
}

function formatBindingLabel(control, device) {
  const c = String(control || "")
  const dev = String(device || "")
  if (dev.startsWith("mouse")) {
    const match = c.match(/^button(\d+)$/i)
    if (match) {
      const n = Number(match[1])
      if (n === 0) return "Mouse Left"
      if (n === 1) return "Mouse Right"
      if (n === 2) return "Mouse Middle"
      return "Mouse Button " + (n + 1)
    }
    return "Mouse " + c
  }
  const symbols = {
    backslash: "\\",
    slash: "/",
    comma: ",",
    period: ".",
    semicolon: ";",
    apostrophe: "'",
    grave: "`",
    minus: "-",
    equals: "=",
    leftbracket: "[",
    rightbracket: "]",
  }
  const lower = c.toLowerCase()
  if (symbols[lower]) return symbols[lower]
  if (/^f\d+$/i.test(c)) return c.toUpperCase()
  if (lower === "space") return "Space"
  if (lower === "enter" || lower === "return") return "Enter"
  if (lower === "tab") return "Tab"
  return c.replace(/_/g, " ").replace(/^\w/, ch => ch.toUpperCase())
}

function applyBindingResult(result) {
  const data = unwrapResult(result)
  if (data && data.success === false) return false
  const binding = data && typeof data.binding === "string" && data.binding ? data.binding : null
  if (binding && binding !== UNBOUND) {
    phoneBinding.value = binding
    return true
  }
  return false
}

function loadPhoneBinding(retryCount = 0) {
  engineLua("(function() if career_modules_guide then return career_modules_guide.getPhoneBinding() end end)()", result => {
    applyBindingResult(result)
    if (phoneBinding.value === UNBOUND && retryCount < 3) {
      setTimeout(() => loadPhoneBinding(retryCount + 1), 150)
    }
  })
}

function setCaptureHardware(enabled) {
  try {
    if (lua?.ActionMap?.enableBindingCapturing) lua.ActionMap.enableBindingCapturing(!!enabled)
  } catch (_) {}
  try {
    if (lua?.setCEFTyping) lua.setCEFTyping(!!enabled)
  } catch (_) {}
  try {
    if (lua?.Input?.setForwardRawEvents) lua.Input.setForwardRawEvents(!!enabled)
  } catch (_) {}
  engineLua(
    enabled
      ? "if career_modules_guide and career_modules_guide.beginPhoneRebind then career_modules_guide.beginPhoneRebind() end"
      : "if career_modules_guide and career_modules_guide.endPhoneRebind then career_modules_guide.endPhoneRebind() end",
  )
}

function rawPayload(eventOrData, dataArg) {
  const data = dataArg !== undefined ? dataArg : eventOrData
  if (Array.isArray(data) && data[0] && typeof data[0] === "object") return data[0]
  return data && typeof data === "object" ? data : null
}

function controlFromKeyboardEvent(e) {
  const code = e.code || ""
  if (code.startsWith("Key") && code.length === 4) return code.slice(3).toLowerCase()
  if (code.startsWith("Digit") && code.length === 6) return code.slice(5)
  if (/^F\d+$/i.test(code)) return code.toLowerCase()
  if (/^Numpad\d$/.test(code)) return "numpad" + code.slice(6)
  if (CODE_TO_CONTROL[code]) return CODE_TO_CONTROL[code]
  const key = String(e.key || "")
  if (key.length === 1) return key.toLowerCase()
  return null
}

function acceptBinding(control, deviceName) {
  if (controlCaptured) return
  const clean = String(control || "")
  const device = String(deviceName || "keyboard0")
  if (!clean) return
  if (clean === "escape" || clean === "esc") {
    stopCapture()
    return
  }
  controlCaptured = true
  capturing.value = false
  phoneBinding.value = formatBindingLabel(clean, device)
  stopWindowListen()
  setCaptureHardware(false)
  engineLua(
    "(function() if career_modules_guide then return career_modules_guide.setPhoneBinding('" +
      luaQuote(clean) +
      "', '" +
      luaQuote(device) +
      "') end end)()",
    result => {
      applyBindingResult(result)
    },
  )
}

function onRawInput(eventOrData, dataArg) {
  if (!capturing.value || controlCaptured) return
  if (Date.now() < ignoreUntil) return
  const data = rawPayload(eventOrData, dataArg)
  if (!data || !data.control) return
  if (data.value === 0) return
  const control = String(data.control)
  const controlType = data.controlType
  const devName = data.devName || "keyboard0"
  if (controlType === "axis") return
  if (String(devName).startsWith("mouse") && (control === "button0" || control === "button1")) return
  acceptBinding(control, devName)
}

function onDomKey(e) {
  if (!capturing.value || controlCaptured || !e) return
  if (e.repeat) return
  if (e.type === "keyup") return
  const control = controlFromKeyboardEvent(e)
  if (!control) return
  e.preventDefault()
  e.stopPropagation()
  acceptBinding(control, "keyboard0")
}

function startWindowListen() {
  if (windowListening) return
  windowListening = true
  window.addEventListener("keydown", onDomKey, true)
}

function stopWindowListen() {
  if (!windowListening) return
  windowListening = false
  window.removeEventListener("keydown", onDomKey, true)
}

function stopCapture() {
  capturing.value = false
  controlCaptured = false
  stopWindowListen()
  setCaptureHardware(false)
}

function startCapture(event) {
  if (event) {
    event.preventDefault()
    event.stopPropagation()
  }
  if (capturing.value) return
  capturing.value = true
  controlCaptured = false
  ignoreUntil = Date.now() + 250
  startWindowListen()
  setCaptureHardware(true)
  nextTick(() => overlayRoot.value?.focus({ preventScroll: true }))
}

function onShow() {
  open.value = true
  imageOk.value = true
  loadPhoneBinding()
}

function onHide() {
  open.value = false
  if (capturing.value) stopCapture()
}

function onContinue() {
  if (capturing.value) stopCapture()
  if (!isPhoneBound.value) return
  open.value = false
  engineLua("if career_modules_guide then career_modules_guide.onContinue() end")
}

// Focus the next step's button (Set shortcut, or Continue once bound) rather than the bare dialog, so
// the d-pad / A work at once; keydown still bubbles to the root's capture handler.
const focusNextStep = () => nextTick(() => {
  const root = overlayRoot.value
  if (!root) return
  const target = root.querySelector(isPhoneBound.value ? ".cw-button:not([disabled])" : ".cw-binding-button:not([disabled])")
  ;(target || root).focus({ preventScroll: true })
})
watch(visible, shown => {
  if (shown) focusNextStep()
})
// capture parks focus on the dialog root; when it ends (bound or cancelled) move on to the next step
watch(capturing, (now, was) => {
  if (was && !now && visible.value) focusNextStep()
})
// the binding is read from Lua after the overlay opens: once known, move from Set shortcut to Continue
watch(isPhoneBound, bound => {
  if (bound && visible.value && !capturing.value && document.activeElement?.classList?.contains("cw-binding-button")) focusNextStep()
})

onMounted(() => {
  events.on(SHOW_EVENT, onShow)
  events.on(HIDE_EVENT, onHide)
  events.on("RawInputChanged", onRawInput)
  bridge.events.on(SHOW_EVENT, onShow)
  bridge.events.on(HIDE_EVENT, onHide)
  if (window.vueEventBus && window.vueEventBus !== bridge.events) {
    window.vueEventBus.on(SHOW_EVENT, onShow)
    window.vueEventBus.on(HIDE_EVENT, onHide)
    window.vueEventBus.on("RawInputChanged", onRawInput)
  }
  const angularRoot = window.globalAngularRootScope
  if (angularRoot && typeof angularRoot.$on === "function") {
    angularOff = angularRoot.$on("RawInputChanged", onRawInput)
  }
  engineLua("if career_modules_guide and career_modules_guide.resyncSplash then career_modules_guide.resyncSplash() end")
})

onBeforeUnmount(() => {
  if (capturing.value) stopCapture()
  else setCaptureHardware(false)
  stopWindowListen()
  events.off(SHOW_EVENT, onShow)
  events.off(HIDE_EVENT, onHide)
  events.off("RawInputChanged", onRawInput)
  bridge.events.off(SHOW_EVENT, onShow)
  bridge.events.off(HIDE_EVENT, onHide)
  if (window.vueEventBus && window.vueEventBus !== bridge.events) {
    window.vueEventBus.off(SHOW_EVENT, onShow)
    window.vueEventBus.off(HIDE_EVENT, onHide)
    window.vueEventBus.off("RawInputChanged", onRawInput)
  }
  if (typeof angularOff === "function") angularOff()
})
</script>

<style scoped lang="scss">
.cw-overlay {
  position: fixed;
  inset: 0;
  z-index: 15000;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(0, 0, 0, 0.7);
  backdrop-filter: blur(10px);
  -webkit-backdrop-filter: blur(10px);
  outline: none;
  pointer-events: auto;
  user-select: none;
}

.cw-content {
  background: rgba(16, 16, 16, 0.96);
  border-radius: 16px;
  padding: 2.5rem 3rem;
  text-align: center;
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.5);
  border: 1px solid rgba(255, 255, 255, 0.1);
  max-width: 900px;
  width: 90%;
  max-height: 80vh;
  min-height: 0;
  overflow-x: hidden;
  overflow-y: auto;
  box-sizing: border-box;
  display: flex;
  flex-direction: column;
  gap: 1.5rem;
}

.cw-content::-webkit-scrollbar {
  width: 10px;
}

.cw-content::-webkit-scrollbar-track {
  background: rgba(255, 255, 255, 0.06);
  border-radius: 8px;
  margin: 6px 0;
}

.cw-content::-webkit-scrollbar-thumb {
  background: linear-gradient(180deg, rgba(255, 140, 0, 0.75), rgba(255, 159, 67, 0.55));
  border-radius: 8px;
  border: 2px solid rgba(16, 16, 16, 0.96);
}

.cw-image-container {
  width: 100%;
  max-height: min(40vh, 22.5rem);
  aspect-ratio: 16 / 9;
  border-radius: 12px;
  overflow: hidden;
  box-shadow: 0 4px 16px rgba(0, 0, 0, 0.3);
  background: rgba(0, 0, 0, 0.3);
  flex-shrink: 0;
}

.cw-image {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}

.cw-image-fallback {
  width: 100%;
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  color: #fff;
  font-size: 1.6rem;
  font-weight: 700;
  letter-spacing: 0.04em;
  background: linear-gradient(145deg, #2a1a0c, #121212);
}

.cw-welcome-text {
  color: #e6e6e6;
  font-size: 1.1rem;
  line-height: 1.6;
  text-align: left;
  padding: 0 0.5rem;
}

.cw-welcome-text p {
  margin: 0;
}

.cw-welcome-text strong {
  color: #fff;
  font-weight: 600;
}

.cw-binding-section {
  background: rgba(255, 255, 255, 0.03);
  border-radius: 10px;
  padding: 1rem 1.25rem;
  border: 1px solid rgba(255, 140, 0, 0.25);
  text-align: left;
}

.cw-binding-header {
  font-size: 1rem;
  font-weight: 600;
  color: #ff9f43;
  margin: 0 0 0.75rem 0;
  text-transform: uppercase;
  letter-spacing: 0.06em;
}

.cw-binding-info {
  display: flex;
  flex-direction: column;
  gap: 0.35rem;
  margin-bottom: 0.75rem;
  align-items: flex-start;
}

.cw-binding-action {
  font-size: 0.95rem;
  color: #d0d0d0;
  font-weight: 600;
}

.cw-binding-current {
  font-size: 0.9rem;
  color: #bdbdbd;
}

.cw-binding-current strong {
  color: #ffffff;
  font-weight: 600;
}

.cw-binding-waiting {
  font-size: 0.95rem;
  color: #ffb347;
  font-weight: 600;
  animation: cw-pulse 1.5s ease-in-out infinite;
}

@keyframes cw-pulse {
  0%,
  100% {
    opacity: 1;
  }
  50% {
    opacity: 0.6;
  }
}

.cw-binding-button {
  width: 100%;
  background: linear-gradient(145deg, #ff8c00, #ffb347);
  border: none;
  color: #1b1b1b;
  padding: 9px 18px;
  font-size: 0.95rem;
  font-weight: 600;
  border-radius: 6px;
  cursor: pointer;
  box-shadow: 0 2px 8px rgba(255, 140, 0, 0.3);
}

.cw-binding-button:hover:not(:disabled) {
  background: linear-gradient(145deg, #ff9f1a, #ffc36b);
}

// Controller (.focus-visible) and keyboard focus: the house ring (rlsHouse --focus values) on a positioned
// button, with the game's ::before frame hidden (this overlay is teleported, outside the game's rule)
.cw-binding-button,
.cw-button {
  position: relative;
  &.focus-visible,
  &:focus-visible {
    outline: none;
    box-shadow: 0 0 0 1.5px rgba(14, 14, 16, 0.95), 0 0 0 3.5px var(--bng-orange-b400, #ff6600),
      0 0 0.9em -0.15em rgba(255, 102, 0, 0.55);
  }
  &.focus-visible::before {
    display: none !important;
  }
}
.cw-glyph {
  margin-right: 0.4em;
  vertical-align: middle;
}

.cw-binding-button:disabled {
  opacity: 0.6;
  cursor: not-allowed;
}

.cw-button {
  background: linear-gradient(145deg, #ff7a00, #ff9f43);
  border: none;
  color: #1b1b1b;
  padding: 14px 32px;
  font-size: 1.1rem;
  font-weight: 700;
  border-radius: 6px;
  cursor: pointer;
  box-shadow: 0 4px 12px rgba(255, 122, 0, 0.35);
  min-width: 150px;
  font-family: "Segoe UI", Tahoma, Geneva, Verdana, sans-serif;
  margin-top: 0.5rem;
}

.cw-button:hover:not(:disabled) {
  background: linear-gradient(145deg, #ff8a1a, #ffb15c);
}

.cw-button:disabled {
  opacity: 0.45;
  cursor: not-allowed;
  filter: grayscale(0.2);
  box-shadow: none;
}

.cw-fade-enter-active,
.cw-fade-leave-active {
  transition: opacity 0.25s ease;
}

.cw-fade-enter-from,
.cw-fade-leave-to {
  opacity: 0;
}

@media (max-height: 900px) {
  .cw-content {
    max-height: 85vh;
    padding: 1.5rem 2rem;
    gap: 1rem;
  }

  .cw-image-container {
    max-height: min(34vh, 18rem);
  }
}

@media (max-width: 768px) {
  .cw-content {
    padding: 2rem;
    width: 95%;
    gap: 1.25rem;
  }

  .cw-welcome-text {
    font-size: 1rem;
  }
}
</style>
