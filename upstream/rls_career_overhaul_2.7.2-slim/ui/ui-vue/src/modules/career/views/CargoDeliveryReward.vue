<template>
  <LayoutSingle
    v-if="data"
    class="layout-content-full flex-column layout-align-center"
    bng-ui-scope="deliveryReward"
    v-bng-blur
    v-bng-on-ui-nav:back,menu,ok="exit">
    <div class="reward-wrapper rls-house">
      <BngCard class="reward-card">
        <CareerStatus class="career-status" />
        <BngCardHeading type="ribbon"> {{ $translate.instant("ui.career.cargoReward.deliveryComplete") }} </BngCardHeading>
        <!-- read-only breakdown: A / B / Start all continue, so the right stick scrolls it without focus -->
        <div class="card-content scroll" v-bng-ui-nav-scroll.force>
          <section class="rewards-breakdown-container">
            <span class="span2-heading"> {{ $translate.instant("ui.career.cargoReward.rewardBreakdown") }} </span>
            <div class="grid-wrapper breakdown">
              <div class="grid-row grid head">
                <div class="label primary">{{ $translate.instant("ui.career.cargoReward.item") }}</div>
                <div class="rewards primary">{{ $translate.instant("ui.career.cargoReward.rewards") }}</div>
              </div>
              <div v-for="result in data.sortedResults" class="grid-row grid">
                <div class="label primary">{{ result.label }}</div>
                <div class="rewards primary">
                  <div class="pills"><RewardsPills v-for="(reward, key) in result.rewards" :key="key" :rewards="[reward]" :data-reward="reward.attributeKey" /></div>
                </div>
                <div class="grid-wrapper wide">
                  <div v-for="breakdown in result.breakdown" class="grid">
                    <div class="label secondary">{{ breakdown.label }}</div>
                    <div class="rewards secondary">
                      <div class="pills"><RewardsPills v-for="(reward, key) in breakdown.rewards" :key="key" :rewards="[reward]" :data-reward="reward.attributeKey" /></div>
                    </div>
                  </div>
                </div>
              </div>
              <div class="grid-row grid summary">
                <div class="label primary">{{ $translate.instant("ui.career.cargoReward.summary") }}</div>
                <div class="rewards primary">
                  <div class="pills"><RewardsPills v-for="(reward, key) in data.summary.rewards" :key="key" :rewards="[reward]" :data-reward="reward.attributeKey" /></div>
                </div>
              </div>
            </div>
          </section>
          <section class="progress-list">
            <div v-for="reward in data.summary.rewards">
              <BngProgressBar
                v-if="reward.branchInfo"
                :class="{ 'stat-progress-bar': true, 'animate-progress': showBarAnimations }"
                :headerLeft="$ctx_t(reward.branchInfo.name)"
                :headerRight="$ctx_t(reward.branchInfo.level)"
                :min="reward.branchInfo.max == -1 ? 0 : reward.branchInfo.min"
                :value="reward.branchInfo.max == -1 ? 1 : reward.branchInfo.animValue"
                :max="reward.branchInfo.max == -1 ? 1 : reward.branchInfo.max"
                :value-label-format="reward.branchInfo.max == -1 ? $translate.instant('ui.career.cargoReward.maxLevelReached') : undefined" />
            </div>
          </section>

          <div v-if="data.summary.unlocks.length" class="unlocks-wrapper">
            <span class="span2-heading"> {{ $translate.instant("ui.career.cargoReward.unlocks") }}</span>
            <UnlockCard v-for="unlock in data.summary.unlocks" class="unlock-item" :data="unlock" />
          </div>
        </div>

        <template #buttons>
          <HouseButton class="continue-btn" variant="primary" @click="exit"><BngBinding ui-event="ok" deviceMask="xinput" /><span>{{ $translate.instant("ui.common.continue") }}</span></HouseButton>
        </template>
      </BngCard>
    </div>
  </LayoutSingle>
</template>

<script setup>
import { LayoutSingle } from "@/common/layouts"
import { BngCard, BngCardHeading, BngDivider, BngProgressBar, BngBinding } from "@/common/components/base"
import { HouseButton } from "../components/house"
import RewardsPills from "../components/progress/RewardsPills.vue"
import UnlockCard from "../components/progress/UnlockCard.vue"
import { CareerStatus } from "@/modules/career/components"
import { onMounted, ref, onUnmounted, onBeforeMount } from "vue"
import { lua } from "@/bridge"
import { vBngBlur, vBngOnUiNav, vBngUiNavScroll } from "@/common/directives"
import { useGameContextStore } from "@/services"
// import UINavEvents from "@/bridge/libs/UINavEvents"
import { useUINavScope, getUINavServiceInstance } from "@/services/uiNav"
import { $translate } from "@/services/translation"

import { storeToRefs } from "pinia"

useUINavScope("deliveryReward")

const emit = defineEmits(["return"])

const ANIMATION_START_DELAY = 1000
const ANIMATION_DURATION = 2000
const ANIM_DURATION_CSS = ANIMATION_DURATION + "ms"

const showBarAnimations = ref(false)

let data = storeToRefs(useGameContextStore()).deliveryRewardData

const exit = () => {
  window.bngVue.gotoGameState("play")
}

function stopAnimations() {
  showBarAnimations.value = false
}

function startProgressBarAnimation() {
  if (!data.value) return
  showBarAnimations.value = true
  for (const [key, value] of Object.entries(data.value.summary.rewards)) {
    if (value.branchInfo) {
      value.branchInfo.animValue = value.branchInfo.value
    }
  }
  setTimeout(stopAnimations, ANIMATION_DURATION)
}

const start = () => {
  // UINavEvents.activate()
  getUINavServiceInstance().activate()
  // UINavEvents.clearFilteredEvents()
  getUINavServiceInstance().clearFilteredEvents()
  showBarAnimations.value = false
  setTimeout(startProgressBarAnimation, ANIMATION_START_DELAY)
}

onBeforeMount(() => {
  lua.simTimeAuthority.pushPauseRequest('cargoDeliveryReward')
})

const kill = () => {
  lua.career_modules_delivery_cargoScreen.unloadCargoPopupClosed()
  lua.simTimeAuthority.popPauseRequest('cargoDeliveryReward')
}

onMounted(start)
onUnmounted(kill)
</script>

<script>
import { popupPosition, popupContainer } from "@/services/popup"
export default {
  wrapper: {
    fade: true, // everything but popup will fade away (become semi-transparent and desaturated)
    blur: true, // fullscreen in-game blur
    style: popupContainer.transparent, // can be multiple in array
  },
  position: [popupPosition.center, popupPosition.center], // can be single w/o array
}
</script>

<style scoped lang="scss">
@use "@/styles/modules/animations" as *;
@import "../styles/rlsHouse.scss";

/* RLS house style. Everything is em off .reward-wrapper, whose font-size follows the viewport height,
   so the card keeps the same share of the screen at 720p..4K and honours the player's UI scale. */

.animate-progress :deep(.progress-fill) {
  @include pulsing-simple;
  transition: cubic-bezier(0.22, 1, 0.36, 1) v-bind(ANIM_DURATION_CSS);
}

.reward-wrapper {
  position: relative;
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  width: min(46em, 100%);
  min-width: 0;
  max-height: 100%;
  min-height: 0;
  margin: auto;
  display: flex;
}

.reward-wrapper > .reward-card {
  --bng-card-height: auto;
  --bg-opacity: 0.9; /* the default 0.6 washes out over bright scenes */
  --bng-icon-color: currentColor;
  font-size: inherit;
  flex: 1 1 auto;
  min-width: 0;
  min-height: 0;
  max-height: 100%;
  border-radius: 0.6em;
  overflow: hidden;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
}
.reward-card :deep(.card-cnt) {
  min-height: 0;
  border-radius: 0.6em 0.6em 0 0;
}
.reward-card :deep(.card-heading) { font-size: 1.45em; }

/* footer: same ground as the card, no dividing line, so Continue sits in the card */
.reward-wrapper.rls-house > .reward-card > :deep(.footer-container) {
  background-color: rgba(var(--bng-off-black-rgb), var(--bg-opacity));
  border-top: 0;
  box-shadow: none;
  padding: 0.2em 1em 0.9em;
  justify-content: flex-end;
}
/* Continue: the house primary button, binding hint beside the label */
.reward-wrapper.rls-house > .reward-card .continue-btn {
  flex: 0 0 auto;
  min-width: 9em;
  :deep(.btn-label) {
    display: inline-flex;
    align-items: center;
    gap: 0.4em;
  }
}

.career-status {
  padding: 0;
  position: absolute;
  margin: 0.5em 0;
  right: 0;
  top: 0;
  zoom: 0.85;
}
/* same treatment as the computer status pill: faint slashes, money (last value) in gold */
.career-status :deep(.career-status-progress .vertical-divider) { background: rgba(255, 255, 255, 0.28); }
.career-status :deep(.career-status-progress > .career-status-value:last-child) {
  color: var(--money);
  --units-icon-color: var(--money);
}

/* long content scrolls inside the card instead of being clipped */
.card-content {
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: auto;
  overscroll-behavior: contain;
  padding: 0.35em 0.6em 1em 1em;
  display: flex;
  flex-direction: column;
  gap: 1.15em;
}
.card-content > * { flex: 0 0 auto; }

/* section captions (were bold 1.3em headings) */
.span2-heading {
  display: block;
  grid-column: 1 / -1;
  font-size: 0.78em;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--faint);
}

/* ---- reward breakdown: one quiet panel, rows separated by hairlines */
.rewards-breakdown-container {
  display: grid;
  gap: 0.5em;
}
.breakdown {
  display: grid;
  border-radius: var(--radius-panel);
  background: var(--panel);
  overflow: hidden;
}
.grid {
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(5em, 1.7fr);
  column-gap: 1em;
  align-items: center;
}
.grid-row {
  row-gap: 0.4em;
  padding: 0.6em 0.85em 0.5em;
  border-bottom: 1px solid var(--line);
}
.grid-row:last-child { border-bottom: 0; }
.label { grid-column: 1 / span 1; min-width: 0; overflow-wrap: anywhere; line-height: 1.25; }
.rewards { grid-column: 2 / span 1; min-width: 0; }
.primary { font-weight: 700; }
.secondary { font-weight: 600; }
.label.secondary { padding-left: 0.85em; color: var(--muted); font-size: 0.88em; }

.grid-row.head { padding-top: 0.55em; padding-bottom: 0.35em; }
.grid-row.head > div {
  font-size: 0.72em;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--faint);
}
.grid-row.summary { background: var(--panel); }
.grid-row.summary .label { font-size: 1.05em; }

/* per-item breakdown sits on the parent's columns */
.wide {
  grid-column: 1 / -1;
  display: grid;
  grid-template-columns: subgrid;
  row-gap: 0.3em;
}
.wide:empty { display: none; }
.wide > .grid { grid-column: 1 / -1; grid-template-columns: subgrid; }
.rewards.secondary .pills { font-size: 0.9em; }

/* ---- reward pills: neutral chips, money in gold, negatives red */
.pills {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.3em;
}
.pills > :deep(.rewards-pills-container) { margin: 0; }
.pills :deep(.reward-pill) { margin: 0; }
.pills :deep(.reward-pill > .pill) {
  display: inline-flex;
  align-items: center;
  margin: 0;
  padding: 0.4em 0.5em 0.1em; /* Overpass caps sit high */
  border-radius: var(--radius-pill);
  background-color: rgba(255, 255, 255, 0.09) !important;
  color: rgba(255, 255, 255, 0.88);
  font-size: 0.86em;
  font-weight: 700;
  line-height: 1;
  white-space: nowrap;
  font-variant-numeric: tabular-nums;
  --units-icon-color: currentColor;
  --paddings: 0;
}
.pills :deep(.reward-pill > .pill .info-item) {
  --icon-size: 1.15em;
  --font-weight-value: 700;
  gap: 0.3em;
  line-height: 1;
  font-family: inherit;
}
.pills :deep(.reward-pill > .pill .info-item > .icon) { transform: translateY(-0.08em); }
.pills > [data-reward="money"] :deep(.reward-pill > .pill) {
  background-color: rgba(253, 230, 138, 0.14) !important;
  color: var(--money);
}
.pills :deep(.reward-pill > .pill[style*="red"]) {
  background-color: rgba(252, 165, 165, 0.18) !important;
  color: var(--bad);
}

/* ---- branch / organisation progress: slim bar, figure as a legend line */
.progress-list {
  display: grid;
  gap: 0.85em;
}
.progress-list:not(:has(.stat-progress-bar)) { display: none; }
.progress-list > div:empty { display: none; }

.reward-wrapper .stat-progress-bar {
  position: relative;
  display: grid;
  gap: 0.45em;
  padding-bottom: 1.35em;
  font-family: inherit;
  font-size: 1em;
  font-weight: 600;
  line-height: 1.25;
}
.reward-wrapper .stat-progress-bar :deep(.header) {
  gap: 1em;
  align-items: baseline;
  font-style: normal;
}
.reward-wrapper .stat-progress-bar :deep(.header-left) {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-weight: 700;
  color: #fff;
}
.reward-wrapper .stat-progress-bar :deep(.header-right) {
  flex: 0 0 auto;
  font-size: 0.85em;
  font-weight: 700;
  color: var(--muted);
}
.reward-wrapper .stat-progress-bar :deep(.progress-bar) {
  height: 0.55em;
  border-radius: 1em;
  background-color: rgba(255, 255, 255, 0.12);
  overflow: visible;
}
.reward-wrapper .stat-progress-bar :deep(.progress-fill),
.reward-wrapper .stat-progress-bar :deep(.second-progress-fill) { border-radius: 1em; }
.reward-wrapper .stat-progress-bar :deep(.info) {
  position: absolute;
  left: 0;
  right: 0;
  top: calc(100% + 0.5em);
  padding: 0;
  font-size: 0.82em;
  font-weight: 600;
  line-height: 1;
  white-space: nowrap;
  color: var(--muted);
  font-variant-numeric: tabular-nums;
}
.reward-wrapper .stat-progress-bar :deep(.info .value-label) {
  padding-right: 0;
  color: #fff;
  font-weight: 800;
}
.reward-wrapper .stat-progress-bar :deep(.info .value-label::after) {
  content: "/";
  position: static;
  display: inline-block;
  width: auto;
  height: auto;
  margin: 0 0.35em;
  background: none;
  transform: none;
  color: var(--faint);
  font-weight: 600;
}

/* ---- unlocks: two-up tiles (unlock beside its task list), plain icon glyph */
.unlocks-wrapper {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 0.5em;
}
.unlocks-wrapper :deep(.wrapper) {
  display: grid;
  grid-template: min-content auto / auto minmax(0, 1fr);
  column-gap: 0.65em;
  row-gap: 0.15em;
  align-items: center;
  padding: 0.65em 0.75em 0.55em;
  border-radius: var(--radius-panel);
  background: var(--panel);
}
.unlocks-wrapper :deep(.wrapper > .icon) {
  grid-row: 1 / -1;
  align-self: center;
  width: 1.2em;
  font-size: 1.6em;
  line-height: 1;
  text-align: center;
  color: #fff;
}
.unlocks-wrapper :deep(.wrapper .heading) {
  min-width: 0;
  font-size: 1em;
  font-weight: 700;
  line-height: 1.2;
}
.unlocks-wrapper :deep(.wrapper .description) {
  min-width: 0;
  font-size: 0.85em;
  font-weight: 600;
  line-height: 1.3;
  color: var(--muted);
}
/* UnlockCard has no single root, so the task list is a direct grid item: keep it in its own column */
.unlocks-wrapper :deep(.wrapper.tasklist) {
  display: flex;
  flex-direction: column;
  justify-content: center;
  align-items: flex-start;
  gap: 0.5em;
}
.unlocks-wrapper :deep(.tasklist .task) { display: flex; align-items: center; gap: 0.6em; }
.unlocks-wrapper :deep(.tasklist .task .icon) { flex: 0 0 auto; font-size: 1.25em; color: var(--muted); }
.unlocks-wrapper :deep(.tasklist .task .heading) { font-size: 0.95em; font-weight: 700; line-height: 1.25; padding-top: 0.1em; }
.unlocks-wrapper :deep(.tasklist .task .description:empty) { display: none; }
</style>
