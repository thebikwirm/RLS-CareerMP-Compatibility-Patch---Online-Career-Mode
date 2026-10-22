"""Offline source tests for the RLS 2.8 / CareerMP 0.40 staged integration.

Run from repository root: python scripts/verify_rls_280_integration.py
Requires no BeamNG installation and does not assert runtime compatibility.
"""
from __future__ import annotations
from pathlib import Path
from rls_280_careermp import patch_rls_280_multiplayer, SHELL, SAVE, CAREER, INVENTORY
from rls_280_vehicle_safety import patch_overhaul_mp_vehicle_safety, TRANSITIONS, GAME_MODE
from careermp_040 import verify_rls_280_mode, RLS280_CONTEXT

ROOT = Path(__file__).resolve().parent.parent / "upstream" / "rls_2.8.0_slim"
INPUTS = (SHELL, SAVE, CAREER, INVENTORY, TRANSITIONS, GAME_MODE, RLS280_CONTEXT)

def main():
    entries = {path: (ROOT / path).read_bytes() for path in INPUTS}
    originals = dict(entries)
    verify_rls_280_mode(entries)
    patch_rls_280_multiplayer(entries)
    patch_overhaul_mp_vehicle_safety(entries)
    assert entries[SHELL] != originals[SHELL]
    assert entries[TRANSITIONS] != originals[TRANSITIONS]
    assert entries[GAME_MODE] != originals[GAME_MODE]
    assert b"M.careerMPVehicleSafety = true" in entries[GAME_MODE]
    assert b"Skipping career activation vehicle purge" in entries[TRANSITIONS]
    assert b"CareerMP040: only waive the BeamMP block" in entries[SHELL]
    once = dict(entries)
    patch_rls_280_multiplayer(entries)
    patch_overhaul_mp_vehicle_safety(entries)
    assert entries == once, "RLS patch not idempotent"
    for path in (SAVE, CAREER, INVENTORY, RLS280_CONTEXT):
        assert entries[path] == originals[path], path + " unexpectedly overwritten"
    print("PASS: Overhaul game-mode contract, source-preserving RLS startup and vehicle protection")
    print("NOT TESTED: BeamNG 0.40 in-game/BeamMP remote vehicles.")

if __name__ == "__main__":
    main()
