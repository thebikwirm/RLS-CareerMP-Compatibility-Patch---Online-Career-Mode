<!-- One labelled group inside the Filters panel, house style: caption title on the left, an optional
     header control or unit on the right, then the controls. No card behind it (the panel is the card);
     "active" (something set in this group) brightens the caption instead of an orange ring. -->
<template>
  <section class="filter-group" :class="{ active }">
    <div class="group-head">
      <span class="group-title"><slot name="title">{{ title }}</slot></span>
      <span v-if="$slots['header-right']" class="group-right"><slot name="header-right" /></span>
    </div>
    <div class="group-body">
      <slot />
    </div>
    <div v-if="$slots.action" class="group-action">
      <slot name="action" />
    </div>
  </section>
</template>

<script setup>
defineProps({
  title: { type: String, default: "" },
  active: { type: Boolean, default: false },
})
</script>

<style scoped>
.filter-group {
  display: grid;
  gap: 0.5em;
  min-width: 0;
}
.group-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.6em;
  min-height: 1.7em;
}
.group-title {
  flex: 1 1 auto;
  min-width: 0;
  padding-top: 0.15em;
  font-size: 0.78em;
  font-weight: 700;
  letter-spacing: 0.06em;
  line-height: 1;
  text-transform: uppercase;
  color: rgba(255, 255, 255, 0.55);
  transition: color 0.12s;
}
.filter-group.active .group-title {
  color: #fff;
}
.group-right {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
}
.group-body {
  display: flex;
  flex-direction: column;
  gap: 0.35em;
  min-width: 0;
}
.group-action {
  display: flex;
  justify-content: flex-end;
}
</style>
