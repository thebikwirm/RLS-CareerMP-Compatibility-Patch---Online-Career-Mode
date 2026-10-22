// Runtime loading: module graph requests, component wrappers, then phone route preparation.
// The graph owns resolved modules; recovery retires requests at both cache owners.
import { defineAsyncComponent, markRaw, defineComponent, shallowRef, h, onUnmounted } from 'vue'
import { useRoute } from 'vue-router'
import { loadModule } from '@/services/uiMods'
import { reportUiFailure } from './safeLua'

// The Vue debug overlay unloads this mod's directory before re-evaluating its
// entry point, so module-local wrappers are replaced when the mod reloads.
const components = new Map()
const pendingModules = new Map()
const latestModules = new Map()
const routeComponents = new Map()
const hostComponents = new Map()
const COMMIT_WAIT_MS = 300
const LOAD_TIMEOUT_MS = 20000

function retireRejectedRuntimeModules() {
  // BeamNG 0.40's graph retains rejected Loading records, including children
  // of a failed root. Retire only those failures; a directory unload would
  // remove styles from healthy mounted siblings. Do not await unrelated work.
  const cache = window.__rtModules
  if (!cache) return
  for (const [id, entry] of Object.entries(cache)) {
    // The shipped bundle minifies Loading's class name. Its record shape is
    // stable: a class instance containing only promise and optional partial.
    if (!entry || Object.getPrototypeOf(entry) === Object.prototype ||
        typeof entry.promise?.catch !== 'function' ||
        Object.keys(entry).some(key => key !== 'promise' && key !== 'partial')) continue
    entry.promise.catch(() => {
      // A retry/reload can already have replaced this exact request.
      if (cache[id] === entry) window.__bngRuntime.invalidate(id)
    })
  }
}

function invalidateModule(file) {
  // Invalidating one record preserves styles owned by mounted sibling screens.
  const runtime = window.__bngRuntime
  runtime.invalidate(runtime.resolve(undefined, file))
}

export function resetRuntimeComponent(file, pending) {
  const entry = pendingModules.get(file)
  if (!entry || entry.promise !== pending) return
  entry.retired = true
  pendingModules.delete(file)
  invalidateModule(file)
}

export function loadRuntimeComponent(file) {
  if (!pendingModules.has(file)) {
    const entry = { promise: null, retired: false, resolved: false }
    latestModules.set(file, entry)
    entry.promise = Promise.resolve().then(() => loadModule(file)).then(module => {
      // The graph can publish a retired request after recovery. Invalidating it
      // also removes this file's styles, including those of a successful retry.
      if (entry.retired && !latestModules.get(file)?.resolved) invalidateModule(file)
      const component = module?.default
      if (!component || (typeof component !== 'object' && typeof component !== 'function')) {
        throw new Error('missing default component export')
      }
      entry.resolved = !entry.retired
      return markRaw(component)
    }).catch(error => {
      retireRejectedRuntimeModules()
      resetRuntimeComponent(file, entry.promise)
      throw new Error(`Could not load ${file}: ${error?.message || error}`, { cause: error })
    }).finally(() => {
      // An old completion must not retire a newer recovery attempt.
      if (pendingModules.get(file) === entry) pendingModules.delete(file)
    })
    pendingModules.set(file, entry)
  }
  return pendingModules.get(file).promise
}

// Routes and host pages share the graph loader without fetching mod metadata.
export function runtimeComponent(file) {
  if (!components.has(file)) components.set(file, defineAsyncComponent(() => loadRuntimeComponent(file)))
  return components.get(file)
}

function boundedLoad(file) {
  const pending = loadRuntimeComponent(file)
  let timer
  const deadline = new Promise((_, reject) => {
    timer = setTimeout(() => {
      resetRuntimeComponent(file, pending)
      reject(new Error(`Could not load ${file}: timed out`))
    }, LOAD_TIMEOUT_MS)
  })
  return Promise.race([pending, deadline]).finally(() => clearTimeout(timer))
}

function pendingScreen(file, firstLoad, repairRecord = true) {
  const PendingScreen = defineComponent({
    name: 'PhonePendingScreen',
    inheritAttrs: false,
    setup(_, { attrs }) {
      const records = [...useRoute().matched]
      const component = shallowRef(null)
      const failed = shallowRef(false)
      let generation = 0
      async function retry(pending = boundedLoad(file)) {
        const token = ++generation
        failed.value = false
        try {
          const loaded = await pending
          if (token !== generation) return
          component.value = loaded
        } catch (error) {
          if (token !== generation) return
          failed.value = true
          reportUiFailure(error, `Load phone screen '${file}'`)
        }
      }
      const initial = firstLoad
      firstLoad = null
      retry(initial || boundedLoad(file))
      onUnmounted(() => {
        generation++
        // Keep the active wrapper's identity across parameter updates. Once it
        // leaves, a repaired record can mount the real component directly.
        if (repairRecord && component.value) for (const record of records) {
          if (record.components?.default === PendingScreen) record.components.default = component.value
        }
      })
      return () => component.value ? h(component.value, attrs) : h('div', {
        class: 'phone-screen-loading', role: 'status',
        style: 'height:100%;background:#15171d;color:white;display:grid;place-content:center;text-align:center;padding:2em;box-sizing:border-box',
      }, failed.value ? [h('p', 'This screen could not be loaded.'),
        h('button', { onClick: () => retry() }, 'Try again')] : [h('span', { 'aria-hidden': 'true' }, '◌'), h('p', 'Loading…')])
    },
  })
  return markRaw(PendingScreen)
}

// Parent routes await their full deadline. Only a terminal failure commits a
// retry page; its identity then stays stable through recovery and tree rebuilds.
export function runtimeHostComponent(file) {
  if (!hostComponents.has(file)) {
    let resolved
    hostComponents.set(file, () => {
      if (!resolved) resolved = boundedLoad(file).catch(error => {
        const failed = Promise.reject(error)
        failed.catch(() => {}) // A cancelled navigation may never mount the error page.
        return pendingScreen(file, failed, false)
      })
      return resolved
    })
  }
  return hostComponents.get(file)
}

// Only phone route records use a bare lazy function. Vue Router awaits it before
// committing, within the Lua route deadline; slower files render a pending page.
export function runtimeRouteComponent(file) {
  if (!routeComponents.has(file)) {
    routeComponents.set(file, async () => {
      const pending = boundedLoad(file)
      let timer
      const outcome = await Promise.race([
        pending.then(component => ({ component }), () => ({})),
        new Promise(resolve => { timer = setTimeout(() => resolve({}), COMMIT_WAIT_MS) }),
      ])
      clearTimeout(timer)
      return outcome.component || pendingScreen(file, pending)
    })
  }
  return routeComponents.get(file)
}
