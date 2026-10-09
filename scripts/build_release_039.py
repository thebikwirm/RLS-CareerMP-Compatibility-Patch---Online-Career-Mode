from __future__ import annotations

import argparse
import shutil
from pathlib import Path

from build_release import (
    RLS_REMOVE_PREFIXES,
    build_mod,
    read_careermp_entries,
    sha256sum,
)
from zip_utils import add_zip_engine_argument, describe_zip_engine, write_zip


def validate_careermp_039(careermp_zip: Path) -> None:
    entries = read_careermp_entries(careermp_zip)
    compat_path = "lua/ge/extensions/careerMP/compat.lua"
    compat = entries.get(compat_path)
    if not compat:
        raise SystemExit(
            "CareerMP input is not the 0.39 port: "
            f"missing {compat_path}"
        )

    text = compat.decode("utf-8", errors="replace")
    if 'targetGameVersion = "0.39"' not in text:
        raise SystemExit(
            "CareerMP input does not advertise targetGameVersion 0.39. "
            "Use the maintained CareerMP-0.39 client zip."
        )


def patch_careermp_039(entries: dict[str, bytes]) -> None:
    """Apply narrow fixes required by BeamNG 0.39.4/RLS integration."""

    compat_path = "lua/ge/extensions/careerMP/compat.lua"
    compat = entries.get(compat_path)
    if not compat:
        raise SystemExit(f"CareerMP input missing {compat_path}")

    text = compat.decode("utf-8").replace("\r\n", "\n")
    old = """local function callPick(module, names, ...)
\tlocal fn, matched = pick(module, unpack(names))
\tif not fn then
\t\tlog("E", "careerMP.compat", "none of {" .. table.concat(names, ", ") .. "} exist on target module")
\t\treturn nil
\tend
\treturn fn(...), matched
end
"""
    new = """local function callPick(module, names, ...)
\tlocal fn = pick(module, unpack(names))
\tif not fn then
\t\tlog("E", "careerMP.compat", "none of {" .. table.concat(names, ", ") .. "} exist on target module")
\t\treturn nil
\tend
\t-- Keep all return values from the underlying BeamNG API. In Lua, placing
\t-- fn(...) before another return expression collapses it to one value.
\treturn fn(...)
end
"""
    if old not in text:
        if "return fn(...)\nend" not in text:
            raise RuntimeError("Unable to patch CareerMP 0.39 callPick return handling")
    else:
        text = text.replace(old, new, 1)
    entries[compat_path] = text.encode("utf-8")

    patches_path = "lua/ge/extensions/careerMP/careerPatches.lua"
    payload = entries.get(patches_path)
    if not payload:
        raise SystemExit(f"CareerMP input missing {patches_path}")

    text = payload.decode("utf-8").replace("\r\n", "\n")
    old = """local function withRemoteVehiclesProtected(fn, ...)
\tinstallProtection()
\tlocal results = {pcall(fn, ...)}
\tremoveProtection()
\tlocal ok = table.remove(results, 1)
\tif not ok then
\t\tlog("E", logTag, "protected call failed: " .. tostring(results[1]))
\t\treturn nil
\tend
\treturn unpack(results)
end
"""
    new = """local function withRemoteVehiclesProtected(fn, ...)
\tinstallProtection()
\tlocal args = {...}
\tlocal function invoke()
\t\treturn fn(unpack(args))
\tend
\tlocal results = {xpcall(invoke, debug.traceback)}
\tremoveProtection()
\tlocal ok = table.remove(results, 1)
\tif not ok then
\t\tlog("E", logTag, "protected call failed with traceback:\\n" .. tostring(results[1]))
\t\treturn nil
\tend
\treturn unpack(results)
end
"""
    if old not in text:
        if "protected call failed with traceback:" not in text:
            raise RuntimeError("Unable to patch CareerMP protected-call traceback")
    else:
        text = text.replace(old, new, 1)
    entries[patches_path] = text.encode("utf-8")

    print("Patched CareerMP-0.39:")
    print("  - compat.lua preserves native multiple return values")
    print("  - careerPatches.lua logs full protected-call tracebacks")


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent

    parser = argparse.ArgumentParser(
        description="Build the BeamNG 0.39.4 RLS compatibility zip for CareerMP-0.39."
    )
    parser.add_argument("--rls-original", required=True, type=Path)
    parser.add_argument("--careermp-039", required=True, type=Path)
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=repo_root / "built-039",
        help="Directory for build artifacts before optional server installation.",
    )
    parser.add_argument(
        "--server-root",
        type=Path,
        default=None,
        help=(
            "Optional BeamMP server root. When supplied, the finished CareerMP.zip "
            "and RLS compatibility zip are copied to Resources/Client automatically."
        ),
    )
    parser.add_argument(
        "--rls-install-name",
        default=None,
        help=(
            "Optional filename to use for the installed RLS zip in Resources/Client. "
            "Useful for overwriting an existing server resource name."
        ),
    )
    add_zip_engine_argument(parser)
    args = parser.parse_args()

    rls_original = args.rls_original.expanduser().resolve()
    careermp_original = args.careermp_039.expanduser().resolve()
    out_dir = args.out_dir.expanduser().resolve()
    server_root = args.server_root.expanduser().resolve() if args.server_root else None

    if not rls_original.is_file():
        raise SystemExit(f"RLS original zip not found: {rls_original}")
    if not careermp_original.is_file():
        raise SystemExit(f"CareerMP 0.39 zip not found: {careermp_original}")

    validate_careermp_039(careermp_original)

    out_dir.mkdir(parents=True, exist_ok=True)

    rls_patch_dir = repo_root / "patches" / "RLS"
    rls_out = out_dir / f"{rls_original.stem}_careermp039_compatible.zip"
    careermp_out = out_dir / "CareerMP.zip"

    rls_size, rls_hash = build_mod(
        rls_original,
        rls_patch_dir,
        rls_out,
        RLS_REMOVE_PREFIXES,
        args.zip_engine,
        apply_legacy_online_save_timing=False,
        apply_legacy_override_manager_patch=False,
    )

    # Keep CareerMP-0.39's architecture intact, but apply narrow 0.39.4 fixes
    # required by the RLS integration.
    careermp_entries = read_careermp_entries(careermp_original)
    patch_careermp_039(careermp_entries)
    write_zip(careermp_out, careermp_entries, engine=args.zip_engine)
    cmp_size = careermp_out.stat().st_size
    cmp_hash = sha256sum(careermp_out)

    checksums = out_dir / "checksums.txt"
    checksums.write_text(
        "\n".join(
            [
                f"{rls_hash}  {rls_out.name}",
                f"{cmp_hash}  {careermp_out.name}",
                "",
                f"{rls_out.name} size={rls_size}",
                f"{careermp_out.name} size={cmp_size}",
                "CareerMP-0.39 patched: profile return preservation + traceback diagnostics",
                f"zip_engine={describe_zip_engine(args.zip_engine)}",
            ]
        ),
        encoding="utf-8",
    )

    print(f"Built: {rls_out}")
    print(f"Built patched CareerMP: {careermp_out}")
    print(f"Wrote: {checksums}")

    if server_root:
        resources_client = server_root / "Resources" / "Client"
        resources_client.mkdir(parents=True, exist_ok=True)

        install_name = args.rls_install_name or rls_out.name
        installed_rls = resources_client / install_name
        installed_careermp = resources_client / "CareerMP.zip"

        shutil.copy2(rls_out, installed_rls)
        shutil.copy2(careermp_out, installed_careermp)

        installed_rls_hash = sha256sum(installed_rls)
        installed_cmp_hash = sha256sum(installed_careermp)

        if installed_rls_hash != rls_hash:
            raise SystemExit(
                "RLS install verification failed: installed hash does not match built zip"
            )
        if installed_cmp_hash != cmp_hash:
            raise SystemExit(
                "CareerMP install verification failed: installed hash does not match source zip"
            )

        print("")
        print("Installed to BeamMP server:")
        print(f"  {installed_rls}")
        print(f"  {installed_careermp}")
        print("")
        print(f"Verified RLS SHA256:      {installed_rls_hash}")
        print(f"Verified CareerMP SHA256: {installed_cmp_hash}")
        print("")
        print("NOTE: remove any older/original RLS career overhaul zip from Resources/Client")
        print("      so only the generated *_careermp039_compatible.zip is active.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
