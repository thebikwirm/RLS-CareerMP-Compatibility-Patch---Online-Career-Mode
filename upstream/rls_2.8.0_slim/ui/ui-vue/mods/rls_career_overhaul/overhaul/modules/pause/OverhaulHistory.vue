<!-- Pause menu > History > Rewards History: the stock digest fed from Overhaul's player attributes.
     Financial History has its own card (OverhaulFinancialHistory.vue). -->
<template>
  <CareerHistoryDigest history-type="gameplay" :entries="entries" full />
</template>

<script setup>
import { onMounted, ref } from "vue"
import { lua } from "@/bridge"
import "../career/utils/installLuaBridgeFallbacks.js"
import CareerHistoryDigest from "@/modules/pause/views/content/CareerHistoryDigest.vue"

defineOptions({ name: "OverhaulHistory" })

const entries = ref([])

onMounted(async () => {
  const result = await lua.overhaul_career_economy_playerAttributes.getGameplayHistory()
  entries.value = Array.isArray(result) ? result : []
})
</script>
