"""Build **experimental only** BeamNG 0.40 / RLS 2.8 CareerMP artifacts.

Do not replace vanilla RLS/BeamMP files, and do not ship without the explicit
--experimental flag. Not validated against BeamNG 0.40 runtime.
"""
from __future__ import annotations
import argparse
import shutil
from pathlib import Path
from build_release import read_zip_entries, read_careermp_entries
from zip_utils import write_zip
from rls_280_careermp import patch_rls_280_multiplayer
from rls_280_vehicle_safety import patch_overhaul_mp_vehicle_safety
from rls_280_start_diagnostics import patch_start_diagnostics
from careermp_040 import stage_careermp_040, patch_careermp_040_overhaul_adapter, verify_rls_280_mode
from careermp_040_handshake import patch_client_handshake
from careermp_040_profiles import patch_careermp_overhaul_profiles
from careermp_040_enabler import patch_overhaul_activation_flow
from careermp_040_payments import patch_overhaul_payments
from careermp_040_runtime import patch_overhaul_only_runtime
from careermp_040_server import patch_server

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rls-original", type=Path, required=True, help="Original RLS v2.8.0 beta ZIP")
    parser.add_argument("--careermp-client", type=Path, required=True, help="CareerMP 0.39 client ZIP (port source)")
    parser.add_argument("--careermp-server", type=Path, required=True, help="CareerMP 0.39 server careerMP.lua")
    parser.add_argument("--output", type=Path, default=Path("built-040-experimental"))
    parser.add_argument("--resources-root", type=Path, help="Original Resources folder, staged without modifying originals")
    parser.add_argument("--experimental", action="store_true")
    args = parser.parse_args()
    if not args.experimental:
        parser.error("0.40 integration is untested: --experimental is required; no production build supported")
    for file in (args.rls_original, args.careermp_client, args.careermp_server):
        if not file.is_file():
            parser.error(f"Missing input: {file}")
    rls = read_zip_entries(args.rls_original)
    original_rls = dict(rls)
    client = read_careermp_entries(args.careermp_client)
    verify_rls_280_mode(rls)
    patch_rls_280_multiplayer(rls)
    patch_overhaul_mp_vehicle_safety(rls)
    patch_start_diagnostics(rls)
    stage_careermp_040(client)
    patch_careermp_040_overhaul_adapter(client)
    patch_careermp_overhaul_profiles(client)
    patch_overhaul_activation_flow(client)
    patch_overhaul_payments(client, rls)
    patch_overhaul_only_runtime(client)
    patch_client_handshake(client)
    server = patch_server(args.careermp_server.read_text(encoding="utf-8-sig"))
    assert "careerModeHello" in server and "careerModeReady" in server
    args.output.mkdir(parents=True, exist_ok=True)
    if args.resources_root:
        if not (args.resources_root / "Client").is_dir() or not (args.resources_root / "Server").is_dir():
            parser.error("--resources-root must contain Client and Server")
        staged = args.output / "Resources"
        if staged.resolve() == args.resources_root.resolve() or args.resources_root.resolve() in staged.resolve().parents:
            parser.error("Output must not be inside original Resources")
        shutil.copytree(args.resources_root, staged, dirs_exist_ok=True)
        write_zip(staged / "Client" / "CareerMP.zip", client, engine="python")
        target = staged / "Server" / "CareerMP" / "careerMP.lua"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(server, encoding="utf-8")
        # RLS input is a slim source archive, not a distributable full mod.
        (staged / "Client" / "rls_career_overhaul_v2.8.0_beta.zip").unlink(missing_ok=True)
    changed_rls = {name: data for name, data in rls.items() if original_rls.get(name) != data}
    if not changed_rls:
        raise RuntimeError("No RLS source changes found; patch output would be empty")
    for name, data in changed_rls.items():
        target = args.output / "RLS-OVERLAY-ONLY" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    write_zip(args.output / "rls_2.8.0_careermp_040_PATCH_ONLY.zip", changed_rls, engine="python")
    write_zip(args.output / "careermp_040_rls280_EXPERIMENTAL.zip", client, engine="python")
    (args.output / "careerMP_040_EXPERIMENTAL.lua").write_text(server, encoding="utf-8")
    print("Created staged Resources and RLS patch-only overlay; no originals were modified.")
    print("DO NOT install RLS patch-only ZIP as if it were a complete RLS mod.")

if __name__ == "__main__":
    main()
