# RLS 2.7.2 / CareerMP 0.39 port audit (2026-10-19)

Source: `upstream/rls_career_overhaul_2.7.2-slim/`, introduced in commit da0776f4.
Legacy overlay: `patches/RLS/` and `scripts/build_release.py`.
Target branch: `beamng-0.39.4-careermp`. Do not change `feature/careermp-rls-phone`.

## Confirmed differences / compatibility risks

1. **Boot sequence: must rebase (BLOCKER).** Legacy `patches/RLS/scripts/rls_career_overhaul/modScript.lua` immediately loads only `overhaul_extensionManager`. The 2.7.2 source modScript instead schedules a 0.25s deferred job that loads `overhaul_rlsHubDyno`, `overhaul_extensionManager`, `overhaul_repositoryDependencies`, `overhaul_licensePlates`, and `career_saveMigration`. A blind overlay of the old modScript drops these upstream initializations. Reconcile with CareerMP's profile-readiness gate before shipping.

2. **Extension manager: must rebase (BLOCKER).** Legacy `patches/RLS/lua/ge/extensions/overhaul/extensionManager.lua` contains `careerMP39RuntimeStarted`, `careerMP39ReadySince`, a 3.5s settle delay and `worldReadyState` checks. New upstream 2.7.2 `lua/ge/extensions/overhaul/extensionManager.lua` implements `ensureInputActionsRegistered()` for `openPhone` and winch actions, and has evolved startup behavior. The legacy overlay omits this new function. Port the CareerMP delayed-start logic INTO the 2.7.2 implementation rather than overwriting it.

3. **Career entry: retain bridge, verify (HIGH).** Legacy `patches/RLS/lua/ge/extensions/overrides/career/careerMP.lua` aliases `require('lua.ge.extensions.overrides.career.career')`. There is no upstream 2.7.2 `careerMP.lua` file; the upstream `career.lua` has 0.39 live-overlay `publish()` logic. Verify that CareerMP enters through the correct replaced table and that this alias keeps 2.7.2's live-context behavior.

4. **Save bridge: candidate for reuse (HIGH).** `patches/RLS/lua/ge/extensions/overhaul/careermp39Compat.lua` prefers `career_saveSystem.getCurrentProfile()`, otherwise CareerMP's compatibility mapping. Builder `patch_rls_039_save_api` converts legacy `career_saveSystem.getCurrentSaveSlot(` callsites. Scan 2.7.2 for any remaining callsites and confirm the bridge is loaded before use; avoid gratuitous global API monkey-patches.

5. **Inventory/traffic: inspect against new functions (HIGH).** `patches/RLS/lua/ge/extensions/overrides/career/modules/careermpCompat.lua` wraps inventory vehicle IDs, spawning, and traffic synchronization. Compare new 2.7.2 inventory interfaces before applying these wrappers.

6. **Vue phone: intended 2.7+ route installer (HIGH).** `scripts/build_release_039.py` adds route registrations via `ui/ui-vue/mods/rls_career_overhaul/index.js` and `ui/ui-vue/src/modules/career/routes.js`. Both paths exist in 2.7.2, but its 41-route assumption and component-loading behavior still need an in-game test. Do not claim this fixes phone initialization yet.

7. **Legacy build text patches: review per release.** `patch_rls_039_player_attributes`, `patch_rls_039_batch_compat`, `patch_rls_039_final_runtime_guards`, and `patch_rls_039_career_module_order` contain old-source assumptions; some have fail-on-zero assertions. Audit patterns against 2.7.2 before re-enabling.

## Build protection

`scripts/build_release_039.py` explicitly refuses an RLS 2.7.2 input while the above two startup blockers remain. It still permits the older 2.6.7 compatible build. Remove the guard only after integrating the 2.7.2 startup + extension manager behavior and adding a verification check for retained 2.7.2 initialization features.

## Next implementation steps

- Port the CareerMP profile readiness gate into a new 2.7.2-specific extensionManager patch, while retaining `ensureInputActionsRegistered`.
- Rework 2.7.2 modScript to preserve deferred upstream extension loading and avoid premature profile-dependent activation.
- Version-scope/remove old whole-file overrides where new 2.7.2 source has newer code.
- Add builder assertions and offline output checks for retained startup/phone features.
- Test on BeamNG 0.39.4 with patched BeamMP + CareerMP; inspect CEF bootstrap separately.
