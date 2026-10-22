"""Offline verification of the staged BeamNG 0.40 / RLS 2.8.0 patch.

Run in the repository checkout: python scripts/verify_rls_280_careermp.py
"""
from __future__ import annotations

from pathlib import Path
from rls_280_careermp import CAREER, INVENTORY, SAVE, SHELL, patch_rls_280_multiplayer

ROOT = Path(__file__).resolve().parent.parent / "upstream" / "rls_2.8.0_slim"

def main() -> int:
    entries = {p: (ROOT / p).read_bytes() for p in (CAREER, INVENTORY, SAVE, SHELL)}
    original = entries[SHELL]
    patch_rls_280_multiplayer(entries)
    assert entries[SHELL] != original, "No change to BeamMP refusal guard"
    source = entries[SHELL].decode("utf-8")
    assert "CareerMP040: permit BeamMP only after this client's Overhaul-only" in source
    assert "if versionUnsupported then" in source
    assert 'loadScope("careerCore")' in source or 'loadCareerCore()' in source
    assert "ensureInputActionsRegistered()" in source
    assert "loadScope(\"routes\")" in source
    assert "loadScope(\"shell\")" in source
    assert 'type(enabler.isOverhaulModeNegotiated) == "function"' in source
    assert 'BeamMP is active; Career Overhaul cannot start until it is disabled' in source
    snapshot = dict(entries)
    patch_rls_280_multiplayer(entries)
    assert snapshot == entries, "RLS 2.8.0 patch must be idempotent"
    print("PASS: RLS 2.8.0 CareerMP guard and save/inventory contracts checked")
    print("This is an offline source test; multiplayer behaviour remains unverified.")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
