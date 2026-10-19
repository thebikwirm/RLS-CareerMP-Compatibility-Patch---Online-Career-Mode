<template>
  <section class="rls-house engine-overview" :class="{ 'purchase-mode': purchaseMode, scroll: purchaseMode }">
    <header class="overview-masthead">
      <div class="masthead-copy">
        <span class="caption">Owner's brief</span>
        <h1 v-if="purchaseMode" class="overview-title">West Coast Engine Works</h1>
        <h2 v-else class="overview-title">Build engines. Build a name.</h2>
        <p class="lead">Turn exact personal engine builds into certified production blueprints, manufacture physical copies, and sell them through a predictable timed queue.</p>
      </div>
      <dl v-if="purchaseMode" class="purchase-terms">
        <div class="fact money"><dt class="fact-key">Purchase price</dt><dd class="fact-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(price) }}</dd></div>
        <div v-if="financingAllowed" class="fact money"><dt class="fact-key">Finance entry</dt><dd class="fact-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(downPayment) }} <small>down</small></dd></div>
      </dl>
    </header>

    <section class="overview-section" aria-labelledby="engine-shop-loop-title">
      <div class="section-heading">
        <span class="caption">Operating loop</span>
        <h3 id="engine-shop-loop-title">From garage build to customer sale</h3>
      </div>
      <ol class="loop">
        <li v-for="(step, index) in loopSteps" :key="step.title" class="panel loop-step">
          <span class="step-number">{{ String(index + 1).padStart(2, '0') }}</span>
          <strong>{{ step.title }}</strong>
          <p>{{ step.body }}</p>
          <span v-if="index < loopSteps.length - 1" class="loop-arrow" aria-hidden="true">
            <BngIcon :type="icons.arrowSmallRight" />
          </span>
        </li>
      </ol>
    </section>

    <section class="overview-section" aria-labelledby="brand-awareness-title">
      <div class="section-heading">
        <span class="caption">Brand and demand</span>
        <h3 id="brand-awareness-title">How to raise awareness</h3>
        <p class="section-copy">Promotion is earned through use and sales. There is no separate advertising purchase.</p>
      </div>
      <div class="awareness-methods">
        <article class="panel method">
          <span class="caption">Product awareness</span>
          <strong>Race the engine you sell</strong>
          <p>List its blueprint, install that exact engine recipe in a personal car, then finish a freeroam race. Repeated finishes keep raising awareness, with smaller gains near 100.</p>
        </article>
        <article class="panel method">
          <span class="caption">Shop brand</span>
          <strong>Complete customer sales</strong>
          <p>Every timed engine sale raises the overall Engine Works brand. Brand applies to every certified product, while product awareness applies only to its matching blueprint.</p>
        </article>
      </div>
      <aside class="notice market-effect">
        <strong>Why it matters</strong>
        <p>Maximum shop brand adds up to 10% to supported price; maximum product awareness adds another 5%. Brand and awareness also raise the maximum asking price. Pricing above the supported price lengthens the sale timer up to 15 minutes.</p>
        <small>Each sale slightly reduces that product's awareness, so keep racing the engines you want to promote.</small>
      </aside>
    </section>

    <footer v-if="purchaseMode" class="overview-footer purchase-actions">
      <div class="footer-copy">
        <span class="caption">Acquire the works</span>
        <strong>Choose how to take ownership</strong>
      </div>
      <!-- navLocked: the finance step is open over this, so these leave controller navigation -->
      <div class="action-buttons">
        <HouseButton variant="quiet" binding="back" :nav-item="!navLocked" @click="$emit('cancel')">Leave</HouseButton>
        <HouseButton v-if="financingAllowed" class="finance-button" :nav-item="!navLocked" @click="$emit('finance')">Finance with <BngIcon class="cur" :type="icons.beamCurrency" />{{ money(downPayment) }} down</HouseButton>
        <HouseButton variant="primary" :disabled="cantPay" :nav-item="!navLocked" @click="$emit('purchase')">Purchase outright for <BngIcon class="cur" :type="icons.beamCurrency" />{{ money(price) }}</HouseButton>
      </div>
    </footer>
    <footer v-else class="overview-footer reference-actions">
      <p class="hint">This overview remains available from the Reference section of the Engine Works menu.</p>
      <HouseButton variant="primary" @click="$emit('manage')">Go to Engine Packages</HouseButton>
    </footer>
  </section>
</template>

<script setup>
import { BngIcon, icons } from '@/common/components/base'
import { HouseButton } from '../house'

defineProps({
  purchaseMode: { type: Boolean, default: false },
  price: { type: Number, default: 0 },
  downPayment: { type: Number, default: 0 },
  cantPay: { type: Boolean, default: false },
  financingAllowed: { type: Boolean, default: true },
  // purchase mode: true while a step (finance) is open over the overview
  navLocked: { type: Boolean, default: false }
})

defineEmits(['purchase', 'finance', 'cancel', 'manage'])

const loopSteps = [
  { title: 'Certify a package', body: 'Store a personal engine package and test its exact parts and tune to create a repeatable blueprint.' },
  { title: 'Bring in material', body: 'Order recipe-specific loads, collect them at Spearleaf Logistics, and deliver them to receiving.' },
  { title: 'Run production', body: 'Assign a blueprint to a line. Each completed cycle consumes one raw load and may produce one physical engine.' },
  { title: 'Set price and sell', body: 'Stock and list an engine to start its visible timer. One physical engine sells when the countdown reaches zero.' }
]

// number only: the template puts the game currency glyph in front
const money = value => Math.max(0, Math.round(Number(value) || 0)).toLocaleString()
</script>

<style scoped lang="scss">
@import "../../styles/rlsHouse.scss";

.engine-overview {
  --loop-gap: 1.6em;
  width: 100%;
  display: grid;
  gap: 1.5em;
  color: #fff;
}

/* Purchase screen: the overview stands alone over the world, so it carries the house modal look
   and the shell's vh-based font size itself. */
.engine-overview.purchase-mode {
  width: min(68em, calc(100vw - 4em));
  max-height: calc(100vh - 3em);
  overflow-y: auto;
  padding: 1.4em 1.6em;
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  border-radius: var(--radius-control);
  background: #1a1a1c;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08), 0 18px 40px rgba(0, 0, 0, 0.55);
}

h1,
h2,
h3,
p,
dl,
dd,
ol {
  margin: 0;
}

/* masthead */
.overview-masthead {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  gap: 2em;
  align-items: end;
}

.masthead-copy {
  display: grid;
  gap: 0.35em;
}

.overview-title {
  font-size: 1.5em;
  font-weight: 800;
  line-height: 1.15;
}

.lead {
  max-width: 44em;
  color: var(--muted);
  font-size: 1em;
  line-height: 1.45;
}

.purchase-terms {
  display: grid;
  grid-auto-flow: column;
  gap: 2em;
}

.purchase-terms .fact-key {
  font-size: 0.75em;
}

.purchase-terms .fact-value {
  font-size: 1.35em;
  font-variant-numeric: tabular-nums;
  overflow: visible;
  text-overflow: clip;

  small {
    color: var(--faint);
    font-size: 0.6em;
    font-weight: 700;
  }
}

/* sections */
.overview-section {
  display: grid;
  gap: 0.85em;
}

.section-heading {
  display: grid;
  gap: 0.25em;
}

.section-heading h3 {
  font-size: 1.3em;
  font-weight: 700;
  line-height: 1.2;
}

.section-copy {
  color: var(--muted);
  font-size: 1em;
  line-height: 1.45;
}

.caption {
  font-size: 0.75em;
}

/* operating loop: four equal panels, a faint arrow in each gap */
.loop {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: var(--loop-gap);
  padding: 0;
  list-style: none;
}

.loop-step {
  position: relative;
  align-content: start;
  gap: 0.35em;
}

.step-number {
  color: var(--faint);
  font-size: 0.85em;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
}

.loop-step strong,
.method strong {
  font-size: 1.1em;
  font-weight: 700;
  line-height: 1.2;
}

.loop-step p,
.method p {
  color: var(--muted);
  font-size: 0.95em;
  line-height: 1.45;
}

.loop-arrow {
  position: absolute;
  top: 50%;
  right: calc(var(--loop-gap) / -2);
  display: flex;
  color: var(--faint);
  font-size: 1.1em;
  transform: translate(50%, -50%);
}

/* brand and demand */
.awareness-methods {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 0.85em;
}

.method {
  align-content: start;
  gap: 0.35em;
}

.market-effect {
  display: grid;
  gap: 0.35em;
  font-size: 1em;

  strong {
    color: #fff;
    font-size: 1.05em;
    font-weight: 700;
  }

  p {
    color: var(--muted);
    font-size: 0.95em;
    line-height: 1.45;
  }

  small {
    color: var(--faint);
    font-size: 0.85em;
    line-height: 1.4;
  }
}

/* footer */
.overview-footer {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 1em;
  padding-top: 1.1em;
  border-top: 1px solid var(--line);
}

.reference-actions .hint {
  font-size: 0.85em;
}

.footer-copy {
  display: grid;
  gap: 0.2em;

  strong {
    font-size: 1.1em;
    font-weight: 700;
  }
}

.action-buttons {
  display: flex;
  flex-wrap: wrap;
  justify-content: flex-end;
  gap: 0.6em;
}

@media (max-width: 900px) {
  .overview-masthead {
    grid-template-columns: 1fr;
  }
  .loop {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
  .loop-step:nth-child(2) .loop-arrow {
    display: none;
  }
  .awareness-methods {
    grid-template-columns: 1fr;
  }
  .overview-footer {
    align-items: flex-start;
    flex-direction: column;
  }
  .action-buttons {
    justify-content: flex-start;
  }
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
