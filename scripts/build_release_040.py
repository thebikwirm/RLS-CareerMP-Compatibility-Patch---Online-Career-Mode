"""Build **experimental only** BeamNG 0.40 / RLS 2.8 CareerMP artifacts.

Do not replace vanilla RLS/BeamMP files, and do not ship without the explicit
--experimental flag. Not validated against BeamNG 0.40 runtime.
"""
from __future__ import annotations
import argparse
from pathlib import Path
from build_release import read_zip_entries, read_careermp_entries
from zip_utils import write_zip
from rls_280_careermp import patch_rls_280_multiplayer
from rls_280_vehicle_safety import patch_overhaul_mp_vehicle_safety
from careermp_040 import stage_careermp_040, patch_careermp_040_overhaul_adapter, verify_rls_280_mode
from careermp_040_handshake import patch_client_handshake
from careermp_040_profiles import patch_careermp_overhaul_profiles
from careermp_040_enabler import patch_overhaul_activation_flow
from careermp_040_server import patch_server

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rls-original", type=Path, required=True, help="Original RLS v2.8.0 beta ZIP")
    parser.add_argument("--careermp-client", type=Path, required=True, help="CareerMP 0.39 client ZIP (port source)")
    parser.add_argument("--careermp-server", type=Path, required=True, help="CareerMP 0.39 server careerMP.lua")
    parser.add_argument("--output", type=Path, default=Path("built-040-experimental"))
    parser.add_argument("--experimental", action="store_true")
    args = parser.parse_args()
    if not args.experimental:
        parser.error("0.40 integration is untested: --experimental is required; no production build supported")
    for file in (args.rls_original, args.careermp_client, args.careermp_server):
        if not file.is_file():
            parser.error(f"Missing input: {file}")
    rls = read_zip_entries(args.rls_original)
    client = read_careermp_entries(args.careermp_client)
    verify_rls_280_mode(rls)
    patch_rls_280_multiplayer(rls)
    patch_overhaul_mp_vehicle_safety(rls)
    stage_careermp_040(client)
    patch_careermp_040_overhaul_adapter(client)
    patch_careermp_overhaul_profiles(client)
    patch_overhaul_activation_flow(client)
    patch_client_handshake(client)
    server = patch_server(args.careermp_server.read_text(encoding="utf-8-sig"))
    assert "careerModeHello" in server and "careerModeReady" in server
    # A dedicated installer must eventually ensure correct RLS and CareerMP
    # versions and server settings. These outputs are not installed automatically.
    args.output.mkdir(parents=True, exist_ok=True)
    write_zip(args.output / "rls_2.8.0_careermp_040_EXPERIMENTAL.zip", rls, engine="python")
    write_zip(args.output / "careermp_040_rls280_EXPERIMENTAL.zip", client, engine="python")
    (args.output / "careerMP_040_EXPERIMENTAL.lua").write_text(server, encoding="utf-8")
    print("Wrote experimental artifacts. IMPORTANT: not runtime verified.")
    print("RLS Overhaul vehicle safety and all client handlers still require in-game validation.")

if __name__ == "__main__":
    main()
