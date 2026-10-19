<template>
  <div class="auction-overlay-layout">
    <template v-if="isEntryPrompt">
      <div class="entry-modal-backdrop">
        <!-- Controller: a trapping scope while the prompt is up (focus on Pay when it can be paid, else
             Cancel); B / Start cancel -->
        <div
          class="entry-modal"
          v-bng-scoped-nav="{ activateOnMount: true, trapPolicy: 'always', canDeactivate: () => (cancelEntryPrompt(), false) }"
          v-bng-on-ui-nav:menu="cancelEntryPrompt">
          <div class="entry-modal-text">
            <template v-if="entryPromptStatus">{{ entryPromptStatus }}</template>
            <template v-else>Do you want to pay <BngIcon class="cur" :type="icons.beamCurrency" />{{ Math.round(entryFee).toLocaleString() }} to enter The Vault?</template>
          </div>
          <div class="entry-modal-actions">
            <BngButton
              :accent="ACCENTS.main"
              :disabled="!canPayEntry"
              :bng-no-nav="!canPayEntry ? 'true' : null"
              :bng-scoped-nav-autofocus="canPayEntry ? '' : null"
              @click="startAuctionFromPrompt"
            >
              Pay
            </BngButton>
            <BngButton
              :accent="ACCENTS.secondary"
              :bng-scoped-nav-autofocus="canPayEntry ? null : ''"
              @click="cancelEntryPrompt">
              Cancel
            </BngButton>
          </div>
        </div>
      </div>
    </template>
    <div v-else class="auction-overlay">
      <div class="overlay-header">
        <div class="title">Used Car Auction</div>
        <div class="phase">{{ state.phase || 'idle' }}</div>
      </div>

      <div class="status">{{ state.statusMessage || 'Auction service unavailable.' }}</div>

      <div class="music-toggle">
        <BngSwitch v-model="musicEnabled">Synthwave Music</BngSwitch>
      </div>

      <div class="summary">
        <div class="summary-row">
          <span class="k">Wins</span>
          <span class="v">{{ state.purchasedCount || 0 }}</span>
        </div>
        <div class="summary-row">
          <span class="k">Live Lot</span>
          <span class="v">Lot {{ activeLot?.lotIndex || '-' }}</span>
        </div>
      </div>

      <div class="lots-table" v-bng-ui-nav-scroll.force>
        <div class="table-row table-head">
          <div class="col-lot">Lot</div>
          <div class="col-vehicle">Vehicle</div>
          <div class="col-mileage">Mileage</div>
        </div>

        <div
          v-for="lot in (state.lots || [])"
          :key="lot.lotIndex"
          class="table-row lot-row"
          :class="{ active: isActiveLot(lot) }"
        >
          <div class="col-lot">Lot {{ lot.lotIndex }}</div>
          <div class="col-vehicle" :title="lot.title || '-'">{{ lot.title || '-' }}</div>
          <div class="col-mileage">{{ formatMileage(lot.mileage) }}</div>
        </div>

        <div v-if="!(state.lots || []).length" class="empty-lots">
          No active lots.
        </div>
      </div>

      <div class="active-details" v-if="activeLot">
        <div class="detail-row">
          <span class="k">Bid</span>
          <span class="v"><BngIcon class="cur" :type="icons.beamCurrency" />{{ activeLot.currentBid || 0 }}</span>
        </div>
        <div class="detail-row">
          <span class="k">Leader</span>
          <span class="v">{{ formatBidder(activeLot) }}</span>
        </div>
        <div class="detail-row">
          <span class="k">Time Left</span>
          <span class="v">{{ activeLot.timeLeft || 0 }}s</span>
        </div>
      </div>

      <!-- bidding opens for a few seconds per lot: a pad is put straight on the smallest raise -->
      <div class="actions" v-if="canBid">
        <BngButton :accent="ACCENTS.main" @click="bid(250)">+<BngIcon class="cur" :type="icons.beamCurrency" />250</BngButton>
        <BngButton :accent="ACCENTS.main" @click="bid(500)">+<BngIcon class="cur" :type="icons.beamCurrency" />500</BngButton>
        <BngButton :accent="ACCENTS.main" @click="bid(1000)">+<BngIcon class="cur" :type="icons.beamCurrency" />1000</BngButton>
        <BngButton :accent="ACCENTS.main" @click="bid(5000)">+<BngIcon class="cur" :type="icons.beamCurrency" />5000</BngButton>
      </div>
      <div v-if="state.bidMessage" class="bid-hint">{{ state.bidMessage }}</div>
    </div>
  </div>
</template>

<script setup>
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import { lua, useBridge } from '@/bridge'
import { BngButton, ACCENTS, BngSwitch, BngIcon, icons } from '@/common/components/base'
import { vBngOnUiNav, vBngScopedNav, vBngUiNavScroll } from '@/common/directives'
import { refocusIfLost } from '../composables/useScreenEntryFocus'
import { formatOdometer, METERS_PER_MILE } from '../utils/units'

const { units } = useBridge()

const defaultState = () => ({
  phase: 'idle',
  musicEnabled: true,
  entryPromptActive: false,
  entryFee: 1000,
  canPayEntryFee: false,
  hasFreeGarageSlot: true,
  activeLotIndex: 1,
  currentLotIndex: null,
  statusMessage: '',
  purchasedCount: 0,
  bidMessage: '',
  lots: [],
})

const state = ref(defaultState())

let intervalId = null

const getAuctionApi = () => lua?.career_modules_usedCarAuction

const isAuctionLotState = lotState => {
  return lotState === 'queued' || lotState === 'approaching' || lotState === 'active' || lotState === 'exiting'
}

const isEntryPrompt = computed(() => {
  return state.value?.phase === 'entryPrompt' || state.value?.entryPromptActive === true
})

const entryFee = computed(() => {
  const fee = Number(state.value?.entryFee)
  return Number.isFinite(fee) && fee >= 0 ? fee : 1000
})

// Lua's status line when it sent one; otherwise the template's own prompt (with the currency glyph).
const entryPromptStatus = computed(() => {
  if (isEntryPrompt.value) {
    const st = (state.value?.statusMessage || '').trim()
    if (st) {
      return st
    }
  }
  return ''
})

const activeLot = computed(() => {
  const lots = state.value?.lots || []
  if (!lots.length) return null

  const currentLotIndex = Number(state.value.currentLotIndex || state.value.activeLotIndex || 0)
  if (currentLotIndex > 0) {
    const direct = lots.find(lot => Number(lot?.lotIndex || 0) === currentLotIndex)
    if (direct) return direct
  }

  const activeByState = lots.find(lot => isAuctionLotState(lot?.state))
  if (activeByState) return activeByState
  return lots[0]
})

const canBid = computed(() => {
  const lot = activeLot.value
  if (!lot || lot.state !== 'active' || state.value?.phase !== 'bidding') return false
  if (lot.highestBidder === 'player') return false
  return true
})

const canPayEntry = computed(() => !!state.value?.canPayEntryFee && state.value?.hasFreeGarageSlot !== false)

// Controller: the bid buttons only exist while bidding is open; when they appear, move a pad onto the
// first one (unless it is already on a bid button)
watch(canBid, open => {
  if (!open) return
  refocusIfLost(() => document.querySelector('.auction-overlay .actions button:not([disabled])'), {
    force: !document.activeElement?.closest?.('.auction-overlay .actions'),
  })
}, { flush: 'post' })

const musicEnabled = computed({
  get: () => state.value?.musicEnabled !== false,
  set: enabled => {
    void setAuctionMusicEnabled(enabled)
  }
})

const refresh = async () => {
  const api = getAuctionApi()
  if (!api?.requestAuctionState) {
    state.value = { ...defaultState(), statusMessage: 'Auction service unavailable right now.' }
    return
  }

  const nextState = await api.requestAuctionState()
  if (!nextState || typeof nextState !== 'object') return
  state.value = nextState
}

const setAuctionMusicEnabled = async enabled => {
  const boolEnabled = enabled === true
  state.value = { ...state.value, musicEnabled: boolEnabled }

  const api = getAuctionApi()
  if (!api?.setAuctionMusicEnabled) return
  await api.setAuctionMusicEnabled(boolEnabled)
}

const bid = async amount => {
  const api = getAuctionApi()
  if (!api?.placeBid) return
  await api.placeBid(amount)
  await refresh()
}

const startAuctionFromPrompt = async () => {
  const api = getAuctionApi()
  if (!api?.startAuction) return
  await api.startAuction()
  await refresh()
}

const cancelEntryPrompt = async () => {
  const api = getAuctionApi()
  if (!api?.cancelTravelPrompt) return
  await api.cancelTravelPrompt()
}

const isActiveLot = lot => {
  if (!lot || !activeLot.value) return false
  return Number(lot.lotIndex) === Number(activeLot.value.lotIndex)
}

const formatBidder = lot => {
  if (!lot) return '-'
  const bidderName = `${lot?.highestBidderName || ''}`.trim()
  if (bidderName) return bidderName
  if (lot?.highestBidder === 'player') return 'You'
  if (lot?.highestBidder === 'npc') return 'NPC'
  return '-'
}

const formatMileage = mileage => {
  const n = Number(mileage)
  if (!Number.isFinite(n) || n <= 0) return 'Unknown'
  // Lot mileage arrives in whole miles (usedCarAuction.lua); show it in the player's unit.
  return formatOdometer(units, n * METERS_PER_MILE)
}

const formatCurrency = amount => {
  const n = Number(amount)
  if (!Number.isFinite(n) || n < 0) return '0'
  return n.toLocaleString()
}

onMounted(async () => {
  await refresh()
  intervalId = setInterval(refresh, 500)
})

onUnmounted(() => {
  if (intervalId) {
    clearInterval(intervalId)
    intervalId = null
  }
})
</script>

<style scoped lang="scss">
.auction-overlay-layout {
  // scaled unit (rem-sized, the panel shrank to a corner sliver at 1440p): same share of the screen at any
  // resolution, still following the player's UI scale
  --rls-u: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  position: fixed;
  inset: 0;
  pointer-events: none;
}

.entry-modal-backdrop {
  position: fixed;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(0, 0, 0, 0.35);
  pointer-events: auto;
}

.entry-modal {
  width: min(calc(34 * var(--rls-u, 1rem)), calc(100vw - calc(2 * var(--rls-u, 1rem))));
  border-radius: calc(0.6 * var(--rls-u, 1rem));
  border: 1px solid rgba(255, 255, 255, 0.16);
  background: rgba(8, 10, 14, 0.95);
  color: #f5f7fa;
  box-shadow: 0 calc(0.8 * var(--rls-u, 1rem)) calc(1.8 * var(--rls-u, 1rem)) rgba(0, 0, 0, 0.45);
  padding: var(--rls-u, 1rem);
  display: flex;
  flex-direction: column;
  gap: calc(0.7 * var(--rls-u, 1rem));
}

.entry-modal-text {
  font-size: calc(0.95 * var(--rls-u, 1rem));
  font-weight: 700;
}

.entry-modal-actions {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: calc(0.4 * var(--rls-u, 1rem));
}

.auction-overlay {
  position: fixed;
  top: calc(1.2 * var(--rls-u, 1rem));
  left: calc(1.2 * var(--rls-u, 1rem));
  width: min(calc(30 * var(--rls-u, 1rem)), calc(100vw - calc(2 * var(--rls-u, 1rem))));
  max-height: calc(100vh - calc(2.4 * var(--rls-u, 1rem)));
  overflow: hidden;
  display: flex;
  flex-direction: column;
  gap: calc(0.6 * var(--rls-u, 1rem));
  padding: calc(0.8 * var(--rls-u, 1rem));
  border-radius: calc(0.55 * var(--rls-u, 1rem));
  border: 1px solid rgba(255, 255, 255, 0.16);
  background: rgba(8, 10, 14, 0.88);
  color: #f5f7fa;
  box-shadow: 0 calc(0.8 * var(--rls-u, 1rem)) calc(1.8 * var(--rls-u, 1rem)) rgba(0, 0, 0, 0.45);
  pointer-events: auto;
}

.overlay-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: calc(0.7 * var(--rls-u, 1rem));
}

.title {
  font-size: calc(0.92 * var(--rls-u, 1rem));
  font-weight: 800;
  letter-spacing: calc(0.03 * var(--rls-u, 1rem));
  text-transform: uppercase;
}

.phase {
  font-size: calc(0.72 * var(--rls-u, 1rem));
  font-weight: 700;
  text-transform: uppercase;
  color: rgba(255, 255, 255, 0.72);
}

.status {
  font-size: calc(0.82 * var(--rls-u, 1rem));
  color: rgba(255, 255, 255, 0.88);
}

.music-toggle {
  display: flex;
  align-items: center;
  justify-content: flex-start;
}

.summary {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: calc(0.35 * var(--rls-u, 1rem));
}

.summary-row,
.detail-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: calc(0.6 * var(--rls-u, 1rem));
  border-radius: calc(0.38 * var(--rls-u, 1rem));
  padding: calc(0.32 * var(--rls-u, 1rem)) calc(0.46 * var(--rls-u, 1rem));
  background: rgba(255, 255, 255, 0.05);
}

.k {
  font-size: calc(0.72 * var(--rls-u, 1rem));
  text-transform: uppercase;
  letter-spacing: calc(0.02 * var(--rls-u, 1rem));
  color: rgba(255, 255, 255, 0.68);
}

.v {
  font-size: calc(0.8 * var(--rls-u, 1rem));
  font-weight: 700;
  text-align: right;
}

.lots-table {
  display: flex;
  flex-direction: column;
  gap: calc(0.16 * var(--rls-u, 1rem));
  max-height: calc(11.5 * var(--rls-u, 1rem));
  overflow-y: auto;
  padding-right: calc(0.1 * var(--rls-u, 1rem));
  // slim house scrollbar instead of the game's chunky orange one
  &::-webkit-scrollbar { width: calc(0.45 * var(--rls-u, 1rem)); }
  &::-webkit-scrollbar-track { background: transparent; }
  &::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.22); border-radius: 1em; border: 0.12em solid transparent; background-clip: padding-box; }
}

.table-row {
  display: grid;
  grid-template-columns: calc(4.6 * var(--rls-u, 1rem)) minmax(0, 1fr) calc(5.6 * var(--rls-u, 1rem));
  align-items: center;
  gap: calc(0.55 * var(--rls-u, 1rem));
}

.table-head {
  padding: calc(0.1 * var(--rls-u, 1rem)) calc(0.4 * var(--rls-u, 1rem)) calc(0.2 * var(--rls-u, 1rem));
}

.table-head .col-lot,
.table-head .col-vehicle,
.table-head .col-mileage {
  font-size: calc(0.72 * var(--rls-u, 1rem));
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: calc(0.02 * var(--rls-u, 1rem));
  color: rgba(255, 255, 255, 0.76);
}

.lot-row {
  border-radius: calc(0.42 * var(--rls-u, 1rem));
  padding: calc(0.36 * var(--rls-u, 1rem)) calc(0.4 * var(--rls-u, 1rem));
  background: rgba(255, 255, 255, 0.04);
  border: 1px solid rgba(255, 255, 255, 0.08);
}

.lot-row.active {
  border-color: rgba(249, 115, 22, 0.82);
  background: rgba(249, 115, 22, 0.14);
}

.col-lot,
.col-vehicle,
.col-mileage {
  font-size: calc(0.82 * var(--rls-u, 1rem));
}

.col-lot {
  color: rgba(255, 255, 255, 0.9);
}

.col-vehicle {
  font-weight: 700;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.col-mileage {
  font-size: calc(0.76 * var(--rls-u, 1rem));
  text-align: right;
  color: rgba(255, 255, 255, 0.88);
  white-space: nowrap;
}

.empty-lots {
  font-size: calc(0.78 * var(--rls-u, 1rem));
  color: rgba(255, 255, 255, 0.66);
  padding: calc(0.22 * var(--rls-u, 1rem)) calc(0.08 * var(--rls-u, 1rem));
}

.active-details {
  display: flex;
  flex-direction: column;
  gap: calc(0.34 * var(--rls-u, 1rem));
}

.actions {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: calc(0.36 * var(--rls-u, 1rem));
}

.actions :deep(.bng-button) {
  min-height: calc(1.85 * var(--rls-u, 1rem));
  font-size: calc(0.76 * var(--rls-u, 1rem));
  font-weight: 800;
}

.bid-hint {
  font-size: calc(0.78 * var(--rls-u, 1rem));
  color: rgba(255, 185, 120, 0.95);
  margin-top: calc(0.2 * var(--rls-u, 1rem));
}

/* Game currency glyph before amounts; inherits colour/size. */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
