"""Offline check of staged CareerMP 0.40 server-mode protocol.

Usage: python scripts/verify_careermp_040_server.py /path/to/careerMP.lua
No deployment; checks exact upstream server layout and idempotency.
"""
from pathlib import Path
import argparse
from careermp_040_server import patch_server

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("server_file", type=Path)
    args = parser.parse_args()
    source = args.server_file.read_text(encoding="utf-8-sig")
    patched = patch_server(source)
    assert patched != source
    assert patch_server(patched) == patched
    for marker in ("careerModeHello", "careerModeReady", "rxCareerModeConfig",
                   'payload.mode ~= entry.mode', 'if entry.mode ~= "overhaul" or entry.modeProtocol ~= 1 then return end',
                   'entry.careerActive = false', 'local supportedCareerModes = { overhaul = true }',
                   'entry.mode ~= "overhaul"'):
        assert marker in patched, marker
    assert 'MP.RegisterEvent("careerSyncRequested","careerSyncRequested")' in patched
    assert "autoUpdate = false," in patched
    print("PASS: staged Overhaul-only server negotiation verified")
    print("NOT tested with BeamMP; client must negotiate before sync and signal actual mode readiness.")

if __name__ == "__main__":
    main()
