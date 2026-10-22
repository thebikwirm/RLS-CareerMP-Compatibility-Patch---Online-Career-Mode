<template>
  <section class="rls-house rls-house-card overhaul-career-card" aria-label="Overhaul career overview"
    v-bng-scoped-nav="{ scopeId: 'overhaul-pause-skills', type: 'container' }">
    <template v-for="section in data.sections" :key="section.id">
      <header v-if="section.kind === 'profile'">
        <h2 class="profile-name">{{ section.value }}</h2>
      </header>
      <div v-else-if="section.kind === 'value'" class="card-value">
        <span class="caption">{{ section.label }}</span>
        <BngUnit v-if="section.format === 'money' && section.value != null" class="balance" :money="section.value" :icon-type="icons.beamCurrency" />
        <div v-else class="value-content">
          <img v-if="section.thumbnail && !failedImages.has(section.thumbnail)" class="vehicle-thumbnail"
            :src="section.thumbnail" alt="" @error="failedImages.add(section.thumbnail)" />
          <BngIcon v-else-if="icons[section.icon]" class="value-icon" :type="icons[section.icon]" aria-hidden="true" />
          <strong>{{ section.value ?? 'Unavailable' }}</strong>
        </div>
      </div>
      <div v-else-if="section.kind === 'skills'" class="skill-section">
        <h3>{{ section.label }}</h3>
        <div class="skills-window" :class="edges[section.id]">
          <div ref="skillGrids" class="skills" :data-section-id="section.id" role="group" :aria-label="section.label" bng-nav-scroll
            @scroll.passive="updateEdges($event.target)" @focusin="revealSkill" @keydown="navigateSkills" @ui_nav="navigateSkillController">
            <div v-for="skill in section.rows" :key="skill.skillKey" class="skill" tabindex="0" bng-nav-item
              :aria-label="`${skill.label}, level ${skill.level}, ${skill.maxLevel ? 'maximum level' : `${percent(skill)}% to next level`}`">
              <div class="skill-heading"><BngIcon v-if="icons[skill.icon]" class="skill-icon" :type="icons[skill.icon]" aria-hidden="true" /><strong>{{ skill.label }}</strong><span>Level {{ skill.level }}</span></div>
              <div class="skill-track" role="progressbar" :aria-label="`${skill.label} progress to next level`"
                :aria-valuenow="percent(skill)" aria-valuemin="0" aria-valuemax="100"
                :aria-valuetext="skill.maxLevel ? 'Maximum level' : `${percent(skill)}% to next level`">
                <div class="skill-fill" :style="{ transform: `scaleX(${fraction(skill)})` }" />
              </div>
              <span class="progress-label">{{ skill.maxLevel ? 'Maximum level' : `Next level: ${percent(skill)}%` }}</span>
            </div>
          </div>
        </div>
      </div>
    </template>
  </section>
</template>

<script setup>
import { ref, reactive, onMounted, onBeforeUnmount } from 'vue'
import { BngUnit, BngIcon, icons } from '@/common/components/base'
import { vBngScopedNav } from '@/common/directives'
import { scrollEdges, revealSkill, navigateSkills, navigateSkillController } from '../profiles/careerCardScroll.js'
defineProps({ data: { type: Object, required: true } })
const failedImages = reactive(new Set())
const skillGrids = ref([])
const edges = reactive({})
const updateEdges = grid => { edges[grid.dataset.sectionId] = scrollEdges(grid) }
let resizeObserver
onMounted(() => {
  resizeObserver = new ResizeObserver(entries => entries.forEach(({ target }) => updateEdges(target)))
  for (const grid of skillGrids.value) { updateEdges(grid); resizeObserver.observe(grid) }
})
onBeforeUnmount(() => resizeObserver?.disconnect())
function fraction(skill) {
  if (skill.maxLevel) return 1
  const needed = Number(skill.neededForNext)
  const progress = Number(skill.curLvlProgress)
  return needed > 0 && Number.isFinite(progress) ? Math.min(1, Math.max(0, progress / needed)) : 0
}
const percent = skill => Math.floor(fraction(skill) * 100)
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;
.overhaul-career-card {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: var(--space-4);
  padding: 1.1em;
  background: #1a1a1c;
  border-radius: var(--radius-control);
  box-shadow: inset 0 0 0 1px var(--line);
  font-variant-numeric: tabular-nums;
  header, .skill-section { grid-column: 1 / -1; }
  .caption { display: block; font-size: 0.8em; color: var(--muted); margin-bottom: 0.25em; }
  .profile-name { margin: 0; font-size: 1.4em; line-height: 1.2; overflow-wrap: anywhere; }
  .card-value { min-width: 0; overflow-wrap: anywhere; }
  .value-content { display: flex; align-items: center; gap: var(--space-2); }
  .vehicle-thumbnail { width: 4.2em; height: 2.4em; object-fit: cover; border-radius: var(--radius-control); flex: 0 0 auto; }
  .value-icon { font-size: 1.4em; color: var(--muted); flex: 0 0 auto; }
  .balance { color: var(--money); font-weight: 800; }
  .balance :deep(.info-item) { padding: 0; gap: 0.2em; font-size: 1.25em; }
  h3 { font-size: 1em; margin: 0 0 var(--space-3); }
  .skill-section { min-width: 0; }
  .skills-window {
    --fade-top: 0em;
    --fade-bottom: 0em;
    &.above { --fade-top: 1.2em; }
    &.below { --fade-bottom: 1.8em; }
    mask-image: linear-gradient(to bottom, transparent, #000 var(--fade-top), #000 calc(100% - var(--fade-bottom)), transparent);
  }
  .skills {
    display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: var(--space-3) var(--space-4);
    max-height: min(13em, 32vh); overflow-y: auto; overscroll-behavior: contain; scroll-behavior: auto;
    padding: 0.2em; scrollbar-width: thin; scrollbar-color: var(--line) transparent;
    &::-webkit-scrollbar { width: 0.25em; }
    &::-webkit-scrollbar-thumb { background: var(--line); border-radius: var(--radius-pill); }
  }
  .skill { min-width: 0; border-radius: var(--radius-control); outline-offset: 0.1em; }
  .skill.focus-visible { outline: 1px solid var(--muted); }
  .skill-heading { display: flex; align-items: center; gap: var(--space-2); font-size: 0.85em; }
  .skill-heading strong { overflow-wrap: anywhere; flex: 1; }
  .skill-icon { font-size: 1.3em; flex: 0 0 auto; color: var(--muted); }
  .skill-heading span { flex: 0 0 auto; font-size: 0.9em; color: var(--muted); }
  .skill-track { height: 0.25em; border-radius: var(--radius-pill); overflow: hidden; background: var(--panel-2); margin-top: var(--space-1); }
  .skill-fill { height: 100%; background: #ddd; transform-origin: left; }
  .progress-label { display: block; font-size: 0.75em; color: var(--muted); margin-top: 0.2em; }
}
</style>
