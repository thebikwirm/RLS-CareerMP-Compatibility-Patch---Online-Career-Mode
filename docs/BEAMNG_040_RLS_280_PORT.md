# BeamNG 0.40 / BeamMP / CareerMP / RLS 2.8.0 beta port

Target: BeamNG.drive 0.40 with current BeamMP, an updated CareerMP client, and user-provided `rls_career_overhaul_v2.8.0_beta.zip`.

Base branch: `beamng-0.39.4-careermp`. **Do not change the 0.39.4 branch.**

## Status

- [x] Create dedicated `beamng-0.40-careermp` branch from the 0.39.4 work.
- [ ] Inspect full RLS 2.8.0 beta ZIP file tree and its startup, career, inventory, saving and Vue phone files.
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
