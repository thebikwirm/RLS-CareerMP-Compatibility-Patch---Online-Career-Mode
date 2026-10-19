/**
 * Dormant until F9. Do not poll or mount anything at UI boot.
 * Lua overhaul_rlsTesterMenu.toggle() emits RlsTesterMenu; we compile the
 * overlay only on the first visible=true payload.
 */
import { getComponent } from "@/services/modManager"

const OVERLAY_FILE = "/ui/ui-vue/src/modules/career/components/RlsTesterMenu.vue"
const HOST_ID = "rls-tester-menu-host"

function payloadObject(payload) {
  if (Array.isArray(payload) && payload[0] && typeof payload[0] === "object") {
    return payload[0]
  }
  return payload && typeof payload === "object" ? payload : null
}

async function mountTester() {
  if (window.__rlsTesterMenuMounted || document.getElementById(HOST_ID)) {
    window.__rlsTesterMenuMounted = true
    return true
  }
  if (!window.Vue || !window.bngVue?.app?._context) return false

  let data = await getComponent(OVERLAY_FILE, false, true)
  if (!data?.compiled && typeof data?.compile === "function") {
    data = await data.compile()
  }
  if (data?.error || !data?.component) {
    console.error("[rls_tester_menu] Overlay compile failed", data && data.error, data && data.errorObj)
    return false
  }

  const hostEl = document.createElement("div")
  hostEl.id = HOST_ID
  document.body.appendChild(hostEl)
  const vnode = window.Vue.createVNode(data.component)
  vnode.appContext = window.bngVue.app._context
  window.Vue.render(vnode, hostEl)
  window.__rlsTesterMenuMounted = true
  return true
}

function onTesterEvent(payload) {
  const data = payloadObject(payload)
  if (data && data.visible === true) {
    mountTester()
  }
}

export function onLoad() {
  if (window.__rlsTesterMenuListening) return
  const bus = window.vueEventBus
  if (!bus || typeof bus.on !== "function") return
  window.__rlsTesterMenuListening = true
  bus.on("RlsTesterMenu", onTesterEvent)
}

export function onUnload() {
  window.__rlsTesterMenuListening = false
  window.__rlsTesterMenuMounted = false
  const bus = window.vueEventBus
  if (bus && typeof bus.off === "function") {
    bus.off("RlsTesterMenu", onTesterEvent)
  }
  const hostEl = document.getElementById(HOST_ID)
  if (hostEl && window.Vue?.render) {
    try {
      window.Vue.render(null, hostEl)
    } catch (_) {}
    hostEl.remove()
  }
}
