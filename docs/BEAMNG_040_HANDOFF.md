# HANDOFF — BeamNG 0.40 + CareerMP + RLS 2.8.0 beta

Last updated: 2026-10-22. Branch: `beamng-0.40-careermp`.
Repository: `thebikwirm/RLS-CareerMP-Compatibility-Patch---Online-Career-Mode`.

## Project goal

Make a playable **BeamNG.drive 0.40 + current BeamMP + CareerMP + RLS Career Overhaul 2.8.0 beta** multiplayer career session. **RLS is mandatory**. Do NOT spend time supporting standalone vanilla CareerMP. Preserve the earlier `beamng-0.39.4-careermp` branch. User prefers actual commits to GitHub and a straightforward `build.bat` workflow.

Local source checkout (Windows): `C:\Users\Carl\source\repos\thebikwirm\RLS-CareerMP-Compatibility-Patch---Online-Career-Mode`.
Existing BeamMP server installation: `D:\beamng_server`.
Current build outputs: `built-040-experimental/`.

## Source inputs in GitHub (IMPORTANT)

The user committed a local server resource mirror. **Build from these checked-in files**, not from upstream CareerMP unless missing:

- `Resources/Client/CareerMP.zip` — **CUSTOMIZED** fork; not the same as public CareerMP-0.39!
- `Resources/Client/rls_career_overhaul_v2.8.0_beta.zip` — **slim source archive**, NOT a complete playable RLS mod.
- `Resources/Client/CareerMPBanking.zip`
- `Resources/Client/CareerMPPartySharedVehicles.zip`
- `Resources/Client/CareerMP-Tablet-0.0.5.zip`
- `Resources/Server/CareerMP/careerMP.lua`, `config/config.json`, versions metadata and banking bridge
- `Resources/Server/CareerMPBanking/`, `CareerMPPartySharedVehicles/`, `CareerDebug/`

A separate `upstream/rls_2.8.0_slim/` tree remains in GitHub and is used by old standalone source tests, but **may differ from the committed RLS ZIP**. Avoid blocking the local build on those tests; the builder checks the selected RLS ZIP.

## Current build

`build.bat` reads `Resources/Client` and `Resources/Server`, checks the CareerMP client/server, then calls `scripts/build_release_040.py --experimental --resources-root Resources`. The builder creates:

- `built-040-experimental/Resources/Server/CareerMP/careerMP.lua` (patched)
- `built-040-experimental/Resources/Client/CareerMP.zip` (patched)
- Other supplied resource files staged in the copied `Resources` tree
- `built-040-experimental/RLS-OVERLAY-ONLY/` and `rls_2.8.0_careermp_040_PATCH_ONLY.zip`: **only changed RLS files**, to apply into a COPY of the actual full installed RLS mod; patch ZIP is NOT standalone
- Independent `careermp_040_rls280_EXPERIMENTAL.zip` and `careerMP_040_EXPERIMENTAL.lua`

**Crucial:** The script currently **does not automatically install/copy to `D:\beamng_server`**. User specifically asked about restoring the prior one-click copy-to-server behavior; this is the next immediate requested enhancement. Do a safe staged deployment with backups and only after a successful build; protect existing server configuration, saved game data and updated BeamMP client installation. Do not copy slim RLS ZIP as a full mod. Decide how to inject RLS overlay into the actual full RLS ZIP at its installed location with ZIP integrity checks, backup, and explicit source/target validation.

## Important actual uploaded ZIP differences

The committed `Resources/Client/CareerMP.zip` contains **custom careerMPEnabler.lua** with `requestCareerSync(reason)`, `tryDirectCareerStart(dtReal)`, `processPendingCareerStart(dtReal)`, `isCareerActuallyActive()`, jobsystem recovery, retry logic, and additional BeamMP world-ready guards. Its startup path has multiple vanilla `careerMP_careerPatches` wrappers and uses `career_career` in several places. Do NOT assume upstream 0.39's simple `rxCareerSync` startup implementation. Source inspection was performed through temporary CI diagnostics; the code was amended in `scripts/careermp_040_enabler.py` and `scripts/careermp_040_handshake.py`.

- RLS protection `scripts/rls_280_vehicle_safety.py`: guards `core_vehicles.removeAll()` and `context.removeNonTrafficVehicles()` in Overhaul transitions during multiplayer activation; adds `overhaul_shell_gameMode.careerMPVehicleSafety`.
- `scripts/rls_280_careermp.py`: opt-in BeamMP career-refusal compatibility gate.
- `scripts/careermp_040.py`: Overhaul-only `overhaul_shell_gameMode.start` adapter, no vanilla fallback.
- `scripts/careermp_040_profiles.py`: routes profile access to `overhaul_career_saveSystem`.
- `scripts/careermp_040_payments.py`: RLS money/ledger routing for CareerMP payment callbacks.
- `scripts/careermp_040_enabler.py`: custom-client activation guard adapter; direct-start fallback disabled if not negotiated.
- `scripts/careermp_040_handshake.py`: mode negotiation `careerModeHello`, `rxCareerModeConfig`, `careerSyncRequested`, `careerModeReady`.
- `scripts/careermp_040_server.py`: server accepts `overhaul` mode only and marks a session active only after `careerModeReady`; default server updater disabled in staged Lua but existing config may re-enable it.
- `scripts/careermp_040_runtime.py`: quarantines stale vanilla garage wrappers instead of applying those to unrelated RLS modules. Those features require RLS-native implementations later.

## Validation status

The last reported **passing GitHub Actions run** after adjusting source checks to the actual committed CareerMP ZIP was:
`https://github.com/thebikwirm/RLS-CareerMP-Compatibility-Patch---Online-Career-Mode/actions/runs/39779366273`

Workflow: `.github/workflows/beamng-040-rls-validation.yml`. Validates source patch and experimental packaging but uses a **source-only slim RLS fixture**; it does **NOT** prove the installed complete RLS ZIP works or BeamMP works in-game.

At handoff, user has NOT confirmed that the latest local `build.bat` run succeeds, nor provided a BeamNG log from a live 0.40 test. Never assert the mod is already playable.

Other audit docs:
- `docs/BEAMNG_040_RLS_280_PORT.md`
- `docs/BEAMNG_040_FIRST_TEST.md`

## Immediate next steps

1. Check latest branch and read current `build.bat`, `scripts/build_release_040.py`, CI and source files; keep working on `beamng-0.40-careermp`.
2. Implement **safe automatic copying to `D:\beamng_server\Resources\Server` and `Resources\Client`** similar to old 0.39 one-click build. Back up destination files before replacing; never overwrite the user's save data, working server configs, or updated BeamMP. Consider opt-in switch for install, and an output manifest listing what changed.
3. The deployer now merges changed files into a full installed RLS ZIP, validating entry existence and ZIP integrity. Still verify the actual full RLS installation location and inspect archive/source compatibility; only path/entry matching is enforced, not an upstream-version fingerprint. Exploded RLS installations are not supported yet.
4. Expand port for RLS-native inventory, garage, repair/tuning, insurance, shared vehicles, banking and phone routing. Validate with current BeamMP and BeamNG 0.40 live logs.
5. For first live test use disposable profiles and two players; joining second player must not delete first player's car.

## Expectations for a new chat

User wants actual GitHub commits, not conceptual plans. Use GitHub connector on `beamng-0.40-careermp`. Commit changes, run/check CI against **actual committed inputs**, diagnose CI errors from job logs. Be transparent about experimental status. Do not modify the preserved 0.39.4 branch or install files onto an unverified live server.
