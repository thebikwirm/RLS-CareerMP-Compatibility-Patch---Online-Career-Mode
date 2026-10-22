"""Inspect an upstream CareerMP ZIP for 0.40 port readiness, without releasing it.

Usage: python scripts/check_careermp_040.py path/to/CareerMP.zip
Checks the version-independent compatibility fix and prints remaining blockers.
"""
from __future__ import annotations
import argparse
import sys
from pathlib import Path
from zipfile import ZipFile
from careermp_040 import COMPAT, ENABLER, PATCHES, stage_careermp_040, patch_careermp_040_overhaul_adapter, report_unported_040

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("zip", type=Path)
    args = parser.parse_args()
    with ZipFile(args.zip) as archive:
        names = archive.namelist()
        entries = {}
        for required in (COMPAT, ENABLER, PATCHES):
            matching = [name for name in names if name == required or name.endswith("/" + required)]
            if len(matching) != 1:
                raise SystemExit(f"Expected exactly one {required}; got {matching}")
            entries[required] = archive.read(matching[0])
    stage_careermp_040(entries)
    patch_careermp_040_overhaul_adapter(entries)
    assert 'overhaul_shell_gameMode' in entries[COMPAT].decode('utf-8')
    print("PASS: CareerMP multi-return fix and staged Overhaul game-mode adapter validated.")
    print("RELEASE BLOCKED: BeamNG 0.40 / RLS 2.8 integration not yet confirmed.")
    for blocker in report_unported_040():
        print(" - " + blocker)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
