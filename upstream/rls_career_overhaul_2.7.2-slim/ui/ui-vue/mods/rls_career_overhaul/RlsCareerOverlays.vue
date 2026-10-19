<template>
  <!--
    .39 boots Vue from ui-vue/dist, so mod App.vue overlays never mount.
    This host is mounted by mods/rls_career_overhaul/index.js into the live app context.
  -->
  <RacingTeamProxyOverlay />
  <RacingTeamProxyTeamLoading />
  <RlsCareerLoadingOverlay />
  <BetaCycleSplash />
  <CareerWelcomeOverlay />
  <RacingTeamMilestoneSplash />
  <SceneToastOverlay />
  <TravelJournalScenePrompt />
  <MapTravelPanel />
  <PhoneLockNotificationOverlay />
  <PhoneTutorialOverlay />
  <RoadsideRepairOverlay />
  <DynoSessionOverlay />
</template>

<script setup>
import RacingTeamProxyOverlay from "@/modules/career/components/RacingTeamProxyOverlay.vue"
import RacingTeamProxyTeamLoading from "@/modules/career/components/RacingTeamProxyTeamLoading.vue"
import RlsCareerLoadingOverlay from "@/modules/career/components/RlsCareerLoadingOverlay.vue"
import BetaCycleSplash from "@/modules/career/components/BetaCycleSplash.vue"
import CareerWelcomeOverlay from "@/modules/career/components/CareerWelcomeOverlay.vue"
import RacingTeamMilestoneSplash from "@/modules/career/components/RacingTeamMilestoneSplash.vue"
import SceneToastOverlay from "@/modules/career/components/SceneToastOverlay.vue"
import TravelJournalScenePrompt from "@/modules/career/components/TravelJournalScenePrompt.vue"
import MapTravelPanel from "@/modules/career/components/MapTravelPanel.vue"
import PhoneLockNotificationOverlay from "@/modules/career/components/PhoneLockNotificationOverlay.vue"
import PhoneTutorialOverlay from "@/modules/career/components/PhoneTutorialOverlay.vue"
import RoadsideRepairOverlay from "@/modules/career/components/RoadsideRepairOverlay.vue"
import DynoSessionOverlay from "@/modules/career/components/DynoSessionOverlay.vue"
import { useNavScrollAcceleration } from "@/modules/career/composables/useNavScrollAcceleration.js"

// This host is always mounted while the mod is loaded, so it owns the global right-stick scroll ramp.
useNavScrollAcceleration()
</script>
