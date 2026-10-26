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
    "unlock": {"type": "careerActive"},
}

VUE = """<template>
  <section class="careermp-home">
    <h2>CareerMP</h2>
    <p>Multiplayer phone integration (experimental)</p>
    <p>This screen confirms that the RLS phone can load a CareerMP app.</p>
    <p>Banking, parties and shared vehicles still use the existing CareerMP interfaces.</p>
  </section>
</template>

<script setup>
// Intentionally no networking or lifecycle hooks in the initial smoke test.
</script>

<style scoped>
.careermp-home { padding: 1rem; display: flex; flex-direction: column; gap: .75rem; }
.careermp-home h2 { font-size: 1.35rem; font-weight: 700; }
</style>
"""

def patch_careermp_phone(entries: dict[str, bytes]) -> None:
    if MANIFEST in entries or COMPONENT in entries:
        if entries.get(MANIFEST) == (json.dumps(APP, indent=2) + "\n").encode() and entries.get(COMPONENT) == VUE.encode():
            return
        raise RuntimeError("CareerMP phone integration collides with existing files")
    entries[MANIFEST] = (json.dumps(APP, indent=2) + "\n").encode("utf-8")
    entries[COMPONENT] = VUE.encode("utf-8")
