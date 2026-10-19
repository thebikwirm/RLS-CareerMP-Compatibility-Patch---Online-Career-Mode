"""Offline RLS 2.7.2 startup-port check; does NOT build/deploy a mod.

Run from repository root:
    python scripts/verify_rls_272_startup.py

Tests the staged patch against the exact RLS 2.7.2 source committed under
upstream/. Helps detect changed source before integrating a release build.
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from rls_272_startup import MANAGER, MODSCRIPT, patch_rls_272_startup

SOURCE = ROOT / "upstream" / "rls_career_overhaul_2.7.2-slim"

def main() -> int:
    source_files = (MODSCRIPT, MANAGER)
    entries = {}
    for name in source_files:
        path = SOURCE / name
        if not path.is_file():
            raise SystemExit(f"Missing upstream RLS 2.7.2 source file: {path}")
        entries[name] = path.read_bytes()

    original_script = entries[MODSCRIPT].decode("utf-8")
    original_manager = entries[MANAGER].decode("utf-8")
    patch_rls_272_startup(entries)
    script = entries[MODSCRIPT].decode("utf-8")
    manager = entries[MANAGER].decode("utf-8")

    # The upstream 2.7.2 initialization chain must still be present.
    for name in (
        "overhaul_rlsHubDyno",
        "overhaul_extensionManager",
        "overhaul_repositoryDependencies",
        "overhaul_licensePlates",
        "career_saveMigration",
    ):
        assert f'extensions.load("{name}")' in script, f"Lost upstream startup: {name}"

    assert "worldReadyState ~= 2" in script
    assert "career_career.isActive()" in script
    assert "overhaul_careermp39Compat" in script
    assert "bridge.getCurrentProfile" in script
    assert "job.sleep(0.25)" in script
    assert "ensureInputActionsRegistered()" in manager
    assert "loadTesterMenuIfKeyed()" in manager
    assert "blockUnreloadableExtensionNames()" in manager
    assert "-- deactivateBeamMP() intentionally suppressed" in manager
    assert "deactivateBeamMP()" in original_manager
    assert script != original_script
    assert manager != original_manager

    # Reapplying on already-patched content must be harmless.
    snapshot = dict(entries)
    patch_rls_272_startup(entries)
    assert entries == snapshot, "Startup patch was not idempotent"
    print("PASS: RLS 2.7.2 startup port preserves upstream initialization, "
          "CareerMP readiness checks and input action setup")
    print("NOTE: This is a source-level check, not a BeamNG runtime test.")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
