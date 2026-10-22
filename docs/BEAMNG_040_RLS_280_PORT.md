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

## CareerMP source port — first staged change (2026-10-22)

Verified from the committed 2.8.0 slim tree: `overhaul/shell/extensionManager.lua` explicitly blocks career startup whenever BeamMP is active (`refuseCareerStart()`), even though its startup targets BeamNG minor version 40. `overhaul/career/saveSystem.lua` exposes `getCurrentProfile()` and the legacy alias, returning profile plus path; inventory lives under `overhaul/career/garage/inventory.lua` and exports vehicle ID lookups and spawn via `parts`.

Added **staged only** `scripts/rls_280_careermp.py` to change the BeamMP career refusal narrowly: if the `careerMP_compat` extension is present and exposes `getCurrentProfile`, allow startup; otherwise preserve RLS's warning and refusal. It asserts the native 2.8.0 profile/inventory API without replacing the new modules. Added `scripts/verify_rls_280_careermp.py` for an offline idempotency and source regression check.

**Not yet included in a ZIP or tested.** In particular, whether `careerMP_compat` has loaded when RLS checks the refusal, and whether CareerMP supports 0.40 at all, need runtime verification. This check does not make CareerMP 0.39 binary/Lua compatible with BeamNG 0.40.

## CareerMP 0.40 preparation — source comparison

Reviewed the public CareerMP 0.39 source in `vladmaksimenko-0/CareerMP-0.39` (the `compat.lua`, `careerPatches.lua`, and `careerMPEnabler.lua` modules). Its `compat.lua` wraps **vanilla** `career_saveSystem` and `career_career`, while the RLS 2.8 source provides distinct `overhaul_career_saveSystem` and `overhaul_career_career` implementations. Calling them interchangeable would be unsafe; we need to establish which module owns career activation, savings and remote vehicle cleanup in multiplayer.

Added `scripts/careermp_040.py` for a narrow in-memory port preparation preserving both returns from the game save-profile API, and `scripts/check_careermp_040.py` to inspect a source ZIP for those hooks and print blockers. It deliberately retains `targetGameVersion = "0.39"` and **does not build** an installable 0.40 mod. Do not run the 0.39 release builder or deploy existing patches as an 0.40 port. Next development needs an actual BeamNG 0.40 CareerMP-enabler runtime path and baseline logs before changing version identifiers.

## Dedicated Overhaul mode confirmed

RLS 2.8 owns `overhaul_shell_gameMode` (`lua/ge/extensions/overhaul/shell/gameMode.lua`). Its `start(saveName, specificAutosave, startingOptions)` establishes `core_gamestate` state/layout `overhaul`, calls `overhaul_career_career.createOrLoadCareerAndStart`, owns start/stop/save and broadcasts `onOverhaulModeStarted`. The context module distinguishes Overhaul mode from vanilla career. Do **not** alias the Overhaul career extension to vanilla `career_career` or start the inner career module directly.

Staged `patch_careermp_040_overhaul_adapter()` in `scripts/careermp_040.py`: CareerMP's current `createOrLoadCareerAndStart` compatibility method delegates to `overhaul_shell_gameMode.start` when loaded, and otherwise leaves native career handling unchanged. The patch is **not** an integrated build and has not been runtime tested. The same CareerMP client still needs Overhaul-specific save/profile operations, remote vehicle preservation, multiplayer ownership and event integration. RLS 2.8 still has a BeamMP-refusal guard that must be modified in conjunction with this adapter.

## CareerMP server-side Overhaul protocol (staged)

Inspected upstream `vladmaksimenko-0/CareerMP-0.39/Resources/Server/CareerMP/careerMP.lua`. It is BeamMP-server Lua (not game Lua). Its `careerSyncRequested` currently sends `rxCareerSync` and immediately marks a player `careerActive=true`. The server's activation timeout uses that flag, so it currently cannot tell whether the RLS-specific Overhaul mode started.

Added `scripts/careermp_040_server.py` with a **staged source patch**, not deployed: `careerModeHello` negotiates `vanilla` versus `overhaul` and replies `rxCareerModeConfig`; `careerModeReady` acknowledges actual activation. For clients which negotiate, `careerSyncRequested` no longer marks career active; older clients keep their old handshake. Per-player mode is held on `pendingActivation[player_id]`, cleaned by existing disconnect handling. Added `scripts/verify_careermp_040_server.py` for source-level tests.

**Required client implementation before testing:** send `careerModeHello` (protocol=1, mode=`overhaul`) BEFORE requesting legacy career sync; consume `rxCareerModeConfig`; launch `overhaul_shell_gameMode.start`; send `careerModeReady` (protocol=1, mode=`overhaul`, active=true) only after actual Overhaul mode and career module report active. Handle server timeout and reconnect; do not treat receipt of a sync request as successful activation.

**Unresolved:** BeamMP 0.40 protocol transport and listener conventions must be confirmed from the updated client. This is a proposed application-level protocol, not an interoperable existing one. Existing legacy CareerMP sync remains fallback pending validation. The new server patch is not yet wired into a builder or deployed.
