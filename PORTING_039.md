# BeamNG 0.39.4 / CareerMP-0.39 Port

Branch: `beamng-0.39.4-careermp`

## Current first milestone

Get the existing RLS CareerMP compatibility stack to:

1. join a BeamMP server on BeamNG 0.39.4,
2. keep BeamNG's native `career_career` and `career_saveSystem` loaded,
3. start/load the CareerMP 0.39 profile,
4. avoid legacy `getCurrentSaveSlot()` failures,
5. save and reload the profile successfully.

Feature-by-feature RLS cleanup comes after this baseline works.

## Architecture change

Old compatibility stack:

```
RLS
 -> patched CareerMP 0.0.37
 -> career_careerMP replacement
 -> BeamNG career
```

0.39.4 target:

```
RLS
 -> RLS/CareerMP 0.39 compatibility bridge
 -> CareerMP-0.39 runtime patches + compat.lua
 -> BeamNG 0.39.4 native career/profile system
```

The 0.39 port must not overwrite CareerMP-0.39's `careerMPEnabler.lua` with the old
0.0.37 compatibility copy.

## Implemented so far

- Added `overhaul/careermp39Compat.lua`.
  - Prefers CareerMP-0.39's `careerMP_compat`.
  - Falls back to BeamNG 0.39's native profile API.
  - Does not recreate obsolete save-slot functions globally.
- RLS extension manager now preserves:
  - `core_recoveryPrompt`
  - `career_career`
  - `career_saveSystem`
  when CareerMP-0.39 is detected.
- Build step rewrites legacy:
  - `career_saveSystem.getCurrentSaveSlot(...)`
  to:
  - `overhaul_careermp39Compat.getCurrentProfile(...)`
- Added `scripts/build_release_039.py`.
  - Requires a CareerMP-0.39 input zip.
  - Validates `careerMP/compat.lua`.
  - Builds the RLS compatibility zip.
  - Copies CareerMP-0.39 unchanged rather than overlaying the old CareerMP patch tree.

## Build

### Build only

From the repository root:

```powershell
python .\scripts\build_release_039.py \
  --rls-original "C:\BeamNG-Mod-Build\rls_career_overhaul_2.6.7.zip" \
  --careermp-039 "C:\BeamNG-Mod-Build\CareerMP.zip" \
  --out-dir ".\built-039"
```

This creates:

```text
built-039\
├── CareerMP.zip
├── rls_career_overhaul_2.6.7_careermp039_compatible.zip
└── checksums.txt
```

### Build and install directly into the BeamMP server

Pass the BeamMP server folder with `--server-root`:

```powershell
python .\scripts\build_release_039.py \
  --rls-original "C:\BeamNG-Mod-Build\rls_career_overhaul_2.6.7.zip" \
  --careermp-039 "C:\BeamNG-Mod-Build\CareerMP.zip" \
  --server-root "C:\BeamMP-Server"
```

The builder still keeps a copy in `built-039`, then installs the finished client
mods to:

```text
C:\BeamMP-Server\
└── Resources\
    └── Client\
        ├── CareerMP.zip
        └── rls_career_overhaul_2.6.7_careermp039_compatible.zip
```

`Resources\Client` is created automatically if it does not exist.

Do not leave the original unpatched RLS career overhaul zip, or an older generated
RLS CareerMP compatibility zip, in `Resources\Client` at the same time. The
builder intentionally does not delete unrelated or older server mods automatically.

If `python` is not available on Windows, use `py` instead:

```powershell
py .\scripts\build_release_039.py \
  --rls-original "C:\BeamNG-Mod-Build\rls_career_overhaul_2.6.7.zip" \
  --careermp-039 "C:\BeamNG-Mod-Build\CareerMP.zip" \
  --server-root "C:\BeamMP-Server"
```

## Known next work

- Audit remaining old save-slot/profile symbols.
- Remove or bypass old `career_careerMP` override assumptions.
- Audit RLS override manager mappings against BeamNG 0.39.
- Fix/retire old drag overrides in favor of CareerMP-0.39's drag integration.
- Test credit, property owners and player attributes after profile startup.
- Port workshop/delivery/taxi/repo modules incrementally after the save baseline passes.
