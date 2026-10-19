<!-- Style Guide number field (.stepper / .field) on top of the game's BngInput, so CEF typing, the
     on-screen keyboard, validation, controller up/down stepping and scoped nav all still work.
     Drop-in for BngInput (defaults to type="number"): props, v-model, events, slots and the exposed
     API pass straight through. -->
<template>
  <BngInput ref="inner" type="number" v-bind="$attrs" class="rls-house house-stepper">
    <template v-for="(_, name) in $slots" #[name]="slotProps">
      <slot :name="name" v-bind="slotProps || {}" />
    </template>
  </BngInput>
</template>

<script setup>
import { ref } from "vue"
import { BngInput } from "@/common/components/base"

defineOptions({ inheritAttrs: false })

// Forward BngInput's exposed API (dirty, markClean, domInput, activateScope, ...).
const inner = ref(null)
defineExpose(
  new Proxy(
    {},
    {
      get: (target, key) => (key in target ? target[key] : inner.value?.[key]),
      has: (target, key) => key in target || (!!inner.value && key in inner.value),
    }
  )
)
</script>

<style scoped lang="scss">
@import "../../styles/rlsHouse.scss";
@import "./houseFieldSkin.scss";

.house-stepper {
  @include house-bng-input-root;
  @include house-bng-input-parts;
}
</style>
