"""Stage an isolated CareerMP phone entry for RLS 2.8.

This first slice tests RLS phone discovery and Vue component loading only.
It intentionally does not replace the existing CareerMP tablet or alter MP data.
"""
from __future__ import annotations
import json

MANIFEST = "gameplay/overhaul/phone/apps/careermp-online.json"
COMPONENT = "ui/ui-vue/mods/careermp/phone/CareerMPHome.vue"
MARKER = "CareerMP phone integration (experimental)"

APP = {
    "id": "careermp-online",
    "name": "CareerMP",
    "icon": "people",
    "component": "/" + COMPONENT,
    "defaultHome": {"slot": 15, "required": True},
}

VUE = """<template>
  <section class="careermp-home">
    <header class="careermp-heading">
      <h2>CareerMP</h2>
      <p>Multiplayer career tools</p>
    </header>

    <div class="careermp-panel">
      <h3>Career save</h3>
      <p>Save your current RLS career profile on this computer.</p>
      <BngButton @click="saveCareer">Save Career</BngButton>
      <p v-if="saveRequested" class="careermp-notice">
        Save requested. Verify completion in the game log.
      </p>
    </div>

    <div class="careermp-panel">
      <h3>Multiplayer features</h3>
      <p>Banking, parties and shared vehicles currently use their existing
         CareerMP interfaces while phone migration is in progress.</p>
    </div>
  </section>
</template>

<script setup>
import { ref } from "vue"
import { BngButton } from "@/common/components/base"
import { useBridge } from "@/bridge"

const { api } = useBridge()
const saveRequested = ref(false)

function saveCareer() {
  saveRequested.value = false
  // The RLS game mode owns the active profile and save queue. Never send
  // arbitrary client money or save data to the multiplayer server.
  api.engineLua('if overhaul_shell_gameMode and overhaul_shell_gameMode.isActive() then overhaul_shell_gameMode.save() else guihooks.trigger("toastrMsg", {type="warning", title="Career save", msg="RLS career is not active"}) end')
  saveRequested.value = true
}
</script>

<style scoped>
.careermp-home { padding: 1rem; display: flex; flex-direction: column; gap: 1rem; }
.careermp-heading h2 { font-size: 1.4rem; font-weight: 700; }
.careermp-panel { padding: .8rem; border-radius: .5rem; background: rgba(128,128,128,.12); }
.careermp-panel h3 { margin: 0 0 .4rem; font-size: 1.05rem; font-weight: 650; }
.careermp-panel p { margin: .5rem 0; }
.careermp-notice { font-size: .85rem; opacity: .85; }
</style>
"""

def patch_careermp_phone(entries: dict[str, bytes]) -> None:
    if MANIFEST in entries or COMPONENT in entries:
        if entries.get(MANIFEST) == (json.dumps(APP, indent=2) + "\n").encode() and entries.get(COMPONENT) == VUE.encode():
            return
        raise RuntimeError("CareerMP phone integration collides with existing files")
    entries[MANIFEST] = (json.dumps(APP, indent=2) + "\n").encode("utf-8")
    entries[COMPONENT] = VUE.encode("utf-8")
