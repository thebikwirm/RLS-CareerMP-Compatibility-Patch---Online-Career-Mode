# First experimental BeamNG 0.40 + RLS 2.8 + CareerMP integration test

**Status: development experiment, NOT production-ready.** The source-only CI
build can pass without proving that RLS / CareerMP works inside BeamNG or BeamMP.
Use a disposable local profile and back up server folders and BeamNG user data.

## Prerequisites

- BeamNG.drive 0.40 installed and able to join a BeamMP server normally.
- The original **full** `rls_career_overhaul_v2.8.0_beta.zip` (not the GitHub slim archive).
- Original CareerMP-0.39 client ZIP and `Resources/Server/CareerMP/careerMP.lua`.
- Python 3.11+ available on Windows.
- The `beamng-0.40-careermp` branch checked out.

## Build on the development machine

Run from the repository root:

```powershell
python scripts/verify_rls_280_source.py
python scripts/verify_rls_280_careermp.py
python scripts/verify_rls_280_integration.py

python scripts/check_careermp_040.py "C:\path\CareerMP.zip"
python scripts/verify_careermp_040_server.py "C:\path\careerMP.lua"

python scripts/build_release_040.py --experimental `
  --rls-original "C:\path\rls_career_overhaul_v2.8.0_beta.zip" `
  --careermp-client "C:\path\CareerMP.zip" `
  --careermp-server "C:\path\careerMP.lua"
```

Expected output under `built-040-experimental/`:

- `rls_2.8.0_careermp_040_EXPERIMENTAL.zip`
- `careermp_040_rls280_EXPERIMENTAL.zip`
- `careerMP_040_EXPERIMENTAL.lua`

**Do not simultaneously load stock RLS or old CareerMP ZIPs alongside these
experimental replacements**; duplicate mod files can silently take priority.

For a private test only, install the two ZIPs in the active BeamNG 0.40 mods
folder (use the launcher to locate the user folder). Replace the server's
`Resources/Server/CareerMP/careerMP.lua` with the experimental Lua after making
a backup. If the CareerMP server already has `config.json`, set
`server.autoUpdate` to `false` and restart the server; generated defaults
alone cannot override an existing configuration.

## First test sequence (one player first)

1. Launch BeamNG 0.40, open a private BeamMP server with the updated server mod.
2. Watch for CareerMP client loading, `careerModeHello`, and Overhaul mode startup.
3. Confirm the RLS 2.8 phone appears and its navigation works.
4. Confirm profile and saved vehicle inventory are isolated to this disposable profile.
5. Switch vehicles, leave/rejoin, and check that progress is retained.
6. Only after single-client startup works, join a **second** player and confirm
   that their vehicle does not disappear during career activation.
7. Test vehicle ownership, garage spawn, repair, money transfers, and reconnect,
   one system at a time. Player payments now target Overhaul's ledger.
8. Stop testing on any vehicle deletion, save corruption, money mismatch, or
   repeated errors; keep the logs from both clients and the server.

## Known incomplete systems

- 0.39 garage/repair/tuning/paint wrappers have been quarantined for RLS-only
  mode. Their full RLS-native equivalents are **not yet implemented**.
- Vue player-list and payment UI integration with the RLS 2.8 phone has not been
  verified. The Overhaul phone router itself is retained from RLS.
- Map transitions, vehicle switching, insurance and multiplayer ownership may
  need additional RLS-specific changes.
- BeamMP network and current game's UI must be verified in a real game session;
  passing CI only proves the source patches/build steps run on test fixtures.

## Diagnostics to bring back

- BeamNG client `beamng.log` from each tested player.
- BeamMP server console log from the same test session.
- Whether UI/phone loaded, career became active, vehicles persisted, money
  changed correctly, and which step first failed.
- The output of the five offline checks above if the build failed.

Avoid manually overwriting updated BeamMP game files; work only with test mod
ZIPs and the server CareerMP Lua.
