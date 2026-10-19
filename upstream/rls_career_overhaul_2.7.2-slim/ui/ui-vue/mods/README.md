# `ui/ui-vue/mods/`

BeamNG 0.39 loads the Vue shell from official `ui-vue/dist`. Files under `ui/ui-vue/src/App.vue` do not run.

Career HUD overlays mount from:

- `rls_career_overhaul/index.js` — official 0.39 mod entry (runtime compile via `getComponent`)
- `rls_career_overhaul/RlsCareerOverlays.vue` — the host that actually appears in-game

Add new overlays there. Reload UI. Do not run a UI build.
