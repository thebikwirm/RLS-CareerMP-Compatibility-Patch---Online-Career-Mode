# BeamNG 0.40 / BeamMP / CareerMP / RLS 2.8.0 beta port

Target: BeamNG.drive 0.40 with current BeamMP, an updated CareerMP client, and user-provided `rls_career_overhaul_v2.8.0_beta.zip`.

Base branch: `beamng-0.39.4-careermp`. **Do not change the 0.39.4 branch.**

## Status

- [x] Create dedicated `beamng-0.40-careermp` branch from the 0.39.4 work.
- [x] Locate and review the slim RLS 2.8.0 source tree (1,463 source files). Full beta ZIP and runtime remain unverified.
- [ ] Obtain/inspect BeamNG 0.40 client logs with stock BeamMP connecting successfully.
- [ ] Audit CareerMP 0.39 compatibility Lua bindings for BeamNG 0.40 APIs.
- [ ] Compare RLS 2.8.0 native startup and overrides against RLS 2.7.2; port narrowly.
- [ ] Reconcile Vue phone routes with the 0.40 router and current BeamMP UI.
- [ ] Add version-targeted builder and explicit test ZIP output name.
- [ ] Run offline checks before first in-game test.

## Important compatibility boundaries

- The old 0.39.4 builder still contains hard-coded 0.39 API assumptions, including `targetGameVersion = "0.39"`. Do not relabel its output as 0.40-compatible.
- The 2.7.2-specific source assertions and route injection MUST be reassessed against 2.8.0 before use.
- The existing 2.6.7 full Lua-file replacements MUST NOT overlay 2.8.0.
- In 0.39 BeamMP was launched with `--no-download` to preserve a patched ZIP. That is now removed and BeamMP can update: identify the current BeamMP revision before deciding whether to patch it.
- Keep any 0.40 build opt-in and local-only until game and connection logs demonstrate an operational baseline.

## Current blocker

The uploaded `rls_career_overhaul_v2.8.0_beta.zip` could not be opened by the current file execution environment. Its contents have NOT been inspected. No compatibility claim or 2.8-specific code rewrite should be based on guessing about its source.

## Confirmed 2.8.0 architectural changes (source audit)

- GitHub branch includes `upstream/rls_2.8.0_slim/` (commit `2606d8a`). The RLS extension manager moved from `lua/ge/extensions/overhaul/extensionManager.lua` to `lua/ge/extensions/overhaul/shell/extensionManager.lua`. It explicitly targets game minor version 40.
- Startup `modScript.lua` defers loading `overhaul_shell_extensionManager`, first registering the input category. The old 2.7.2 deferred-initialization rewrite is **not applicable**.
- Career/save modules moved to `lua/ge/extensions/overhaul/career/{career,saveSystem}.lua`; old `overrides/career/` assumptions require re-audit.
- Phone UI now registers through `ui/ui-vue/mods/rls_career_overhaul/overhaul/registerRoutes.js` and `window.bngRoutes`, not the old `window.vueRouter.addRoute` installer. Its mod entrypoint imports `@/services/uiMods` and calls `registerOverhaulRoutes()`, `startPhoneShellState()`, `loadPhoneApps()`. Do not inject 2.7.2 phone routes.
- Added `scripts/verify_rls_280_source.py` for source contract checks. This is not a runtime test; run it locally to validate. Added guard to `scripts/build_release_039.py` to refuse 2.8.0 input. No RLS 2.8.0 ZIP has been built.

## Next code tasks

1. Compare CareerMP's entrypoint and profile APIs against the new `overhaul/career/` modules and native BeamNG 0.40 interfaces.
2. Implement a dedicated, opt-in 0.40 build path using original 2.8.0 ZIP and only version-specific patches, never the legacy 2.6.7/2.7.2 overlays.
3. Check BeamMP's updated Vue/bootstrap behaviour against the new `bngRoutes` API and test connection/UI before adding further patches.
