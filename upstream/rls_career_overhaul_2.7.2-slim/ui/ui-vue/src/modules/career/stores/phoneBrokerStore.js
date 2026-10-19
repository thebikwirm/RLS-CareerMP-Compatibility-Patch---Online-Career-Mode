import { computed, reactive, ref } from 'vue'
import { defineStore } from 'pinia'
import { callModLua } from '../utils/installLuaBridgeFallbacks'
export { groupBrokerRows, groupedOfferCount } from '../utils/brokerOfferGrouping'

export const markets = [
  { id: 'parcels', name: 'Parcel Cargo', hint: 'Packages & crates', icon: 'box' },
  { id: 'trailers', name: 'Trailer Loads', hint: 'Supplied trailers', icon: 'trailer' },
  { id: 'liquids', name: 'Liquids', hint: 'Fuel & water', icon: 'drop' },
  { id: 'bulk', name: 'Bulk Materials', hint: 'Sand, gravel & more', icon: 'bulk' },
  { id: 'cars', name: 'Car Hauling', hint: 'Vehicle transport', icon: 'car' },
  { id: 'specialty', name: 'Specialty Cargo', hint: 'Concrete & cash', icon: 'specialty' },
]
export const defaults = () => ({
  search: '',
  sort: 'near',
  radius: 0,
  trailers: [],
  subtype: '',
  arrangement: '',
  markets: [],
  pickupFac: '',
  destFac: '',
})

function cargoSortKey(row) {
  return row.trailerType || `${Number(row.quantity || 0)} ${row.unit || ''}`
}

function compareRows(a, b, sort) {
  if (sort === 'titleAz') return String(a.title || '').localeCompare(String(b.title || ''))
  if (sort === 'titleZa') return String(b.title || '').localeCompare(String(a.title || ''))
  if (sort === 'pickupAz') return String(a.from || '').localeCompare(String(b.from || ''))
  if (sort === 'pickupZa') return String(b.from || '').localeCompare(String(a.from || ''))
  if (sort === 'destAz') return String(a.to || '').localeCompare(String(b.to || ''))
  if (sort === 'destZa') return String(b.to || '').localeCompare(String(a.to || ''))
  if (sort === 'pickupFar') return (b.pickupDistance ?? -Infinity) - (a.pickupDistance ?? -Infinity)
  if (sort === 'payAsc') return (Number(a.estimatedPay ?? a.pay) || 0) - (Number(b.estimatedPay ?? b.pay) || 0)
  if (sort === 'cargoAz') return cargoSortKey(a).localeCompare(cargoSortKey(b))
  if (sort === 'cargoZa') return cargoSortKey(b).localeCompare(cargoSortKey(a))
  const rank = row => sort === 'pay' ? -(row.estimatedPay ?? row.pay) : sort === 'short' ? row.haulDistance ?? Infinity
    : sort === 'long' ? -(row.haulDistance ?? -Infinity) : sort === 'rate'
      ? row.pickupDistance != null && row.haulDistance != null ? -(row.estimatedPay ?? row.pay) / Math.max(1, row.pickupDistance + row.haulDistance) : Infinity
      : row.pickupDistance ?? Infinity
  return rank(a) - rank(b)
}

export function filterOffers(rows, market, filters, scope) {
  const query = filters.search.toLocaleLowerCase()
  const marketTypes = filters.markets?.length ? filters.markets : null
  return rows.filter(row => (market === 'all' || row.market === market)
    && (!marketTypes || marketTypes.includes(row.market))
    && (!scope || row.origin?.facId === scope)
    && (!filters.pickupFac || row.origin?.facId === filters.pickupFac)
    && (!filters.destFac || row.destination?.facId === filters.destFac)
    && (!filters.radius || row.pickupDistance != null && row.pickupDistance <= filters.radius)
    && (!filters.subtype || row.subtype === filters.subtype)
    && (!filters.arrangement || row.arrangement === filters.arrangement)
    && (!filters.trailers.length || filters.trailers.includes(row.trailerType))
    && (!query || [row.title, row.from, row.to, row.trailerType].some(v => String(v || '').toLocaleLowerCase().includes(query))))
    .sort((a, b) => compareRows(a, b, filters.sort) || String(a.id).localeCompare(String(b.id)))
}

export function brokerLocationOptions(rows, market, kind) {
  const map = new Map()
  for (const row of rows) {
    if (market !== 'all' && row.market !== market) continue
    const loc = kind === 'pickup' ? row.origin : row.destination
    const facId = loc?.facId
    const name = kind === 'pickup' ? row.from : row.to
    if (facId && name) map.set(facId, name)
  }
  const empty = kind === 'pickup' ? 'Any pickup location' : 'Any delivery location'
  return [{ value: '', label: empty }, ...[...map.entries()].sort((a, b) => a[1].localeCompare(b[1])).map(([value, label]) => ({ value, label }))]
}

/** Pickup-radius presets from actual offer distances on this board (avoids useless mile buckets). */
export function brokerRadiusOptions(rows, market) {
  const distances = rows
    .filter(row => (market === 'all' || row.market === market) && row.pickupDistance != null && row.pickupDistance > 0)
    .map(row => row.pickupDistance)
    .sort((a, b) => a - b)
  if (!distances.length) return []
  const max = distances[distances.length - 1]
  const at = fraction => distances[Math.min(distances.length - 1, Math.max(0, Math.floor(fraction * (distances.length - 1))))]
  const raw = [...new Set([at(0.25), at(0.5), at(0.75), max].map(v => Math.ceil(v)))]
    .filter(v => v > 0)
    .sort((a, b) => a - b)
  return raw.map(value => ({ value, maxDistance: value }))
}
export const usePhoneBrokerStore = defineStore('phoneBroker', () => {
  const data = ref({ offers: [], jobs: [], plans: {}, stops: [], loaners: [], rentals: [] })
  const view = ref('markets'), market = ref('all'), selected = ref(null), expanded = ref(false)
  const scope = ref(''), message = ref(''), pending = ref(false), loaded = ref(false), containers = ref([])
  const preferences = reactive({ last: null, filters: {} })
  const scrolls = reactive({})
  const filter = computed(() => preferences.filters[market.value] || defaults())
  const rows = computed(() => filterOffers(data.value.offers || [], market.value, filter.value, scope.value))
  const selectedRow = computed(() => [...(data.value.jobs || []), ...(data.value.offers || []), ...Object.values(data.value.plans || {})].find(r => r.id === selected.value))
  let preferencesLoaded = false, profileKey
  function receive(payload) {
    if (!payload) return
    // Lua encodes empty tables as objects; normalize collections at the boundary.
    for (const key of ['offers', 'jobs', 'stops', 'loaners', 'rentals']) payload[key] = Object.values(payload[key] || {})
    for (const job of [...payload.offers, ...payload.jobs]) job.vehicles = Object.values(job.vehicles || {})
    if (profileKey !== payload.profile) { preferencesLoaded = false; profileKey = payload.profile; selected.value = null; scope.value = ''; view.value = 'markets' }
    data.value = payload; loaded.value = true
    if (!preferencesLoaded) {
      preferences.last = payload.preferences?.last || null
      preferences.filters = payload.preferences?.filters || {}
      for (const f of Object.values(preferences.filters)) {
        f.trailers = Object.values(f.trailers || {})
        f.markets = Object.values(f.markets || {})
      }
      preferencesLoaded = true
    }
  }
  async function refresh() {
    try { receive(await callModLua('ui_phone_logistics.requestBrokerState')) }
    catch { message.value = 'Unable to load Job Broker. Try refreshing.' }
  }
  async function action(name, payload = {}) {
    if (pending.value || data.value.busy) return
    pending.value = true
    try {
      const result = await callModLua('ui_phone_logistics.brokerAction', name, payload)
      message.value = result?.message || ''
      if (result?.id) { selected.value = result.id; view.value = 'jobs' }
      return result
    } catch { message.value = 'The action could not finish. Refresh before trying again.' }
    finally { pending.value = false }
  }
  function savePreferences() {
    callModLua('ui_phone_logistics.brokerAction', 'preferences', { value: JSON.parse(JSON.stringify(preferences)) })
      .catch(() => { message.value = 'Preferences could not be saved.' })
  }
  function chooseMarket(id) {
    market.value = id; view.value = 'loads'; selected.value = null
    preferences.last = id; preferences.filters[id] = { ...defaults(), ...preferences.filters[id] }
    savePreferences()
  }
  function updateFilter(key, value) {
    preferences.filters[market.value] = { ...defaults(), ...filter.value, [key]: value }; savePreferences()
  }
  function resetFilters() { preferences.filters[market.value] = defaults(); savePreferences() }
  function receiveResult(result) { message.value = result?.message || '' }
  return { data, view, market, selected, expanded, scope, message, pending, loaded, containers, preferences, scrolls,
    filter, rows, selectedRow, receive, refresh, action, chooseMarket, updateFilter, resetFilters, receiveResult }
})
