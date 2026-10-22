"""Install staged BeamNG 0.40 CareerMP resources into a local BeamMP server.

Only copy staged client packages and server Lua; never copy source configs or
runtime state. Back up every destination file before changing it. Patch a full
RLS mod archive in place (through an atomic replacement), never deploy a slim
RLS source ZIP as if it were the complete mod.
"""
from __future__ import annotations

import argparse
from datetime import datetime
from pathlib import Path
import shutil
import tempfile
import zipfile

RLS_NAME = "rls_career_overhaul_v2.8.0_beta.zip"
SKIP_CLIENT = {RLS_NAME.lower()}
# Client ZIP packages and server code; do not deploy mutable runtime data,
# private settings or the upstream version updater.
SERVER_SUFFIXES = {".lua"}
CLIENT_SUFFIXES = {".zip"}


def backup_file(path: Path, server: Path, backup: Path) -> None:
    if path.is_file():
        dest = backup / path.relative_to(server)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, dest)


def replace_file(source: Path, dest: Path, server: Path, backup: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    backup_file(dest, server, backup)
    shutil.copy2(source, dest)


def patch_full_rls(archive: Path, patches: Path, server: Path, backup: Path) -> None:
    """Repackage a complete installed RLS ZIP with only explicitly changed files."""
    if not archive.is_file():
        raise RuntimeError(f"Complete RLS archive not found on server: {archive}")
    if not patches.is_dir():
        raise RuntimeError(f"RLS patch overlay missing: {patches}")
    changed = {p.relative_to(patches).as_posix(): p for p in patches.rglob("*") if p.is_file()}
    if not changed:
        raise RuntimeError("RLS overlay has no patched files")
    with zipfile.ZipFile(archive) as original:
        existing = set(original.namelist())
        missing = sorted(set(changed) - existing)
        if missing:
            raise RuntimeError("Server RLS ZIP differs from patched source; missing " + ", ".join(missing[:12]))
    backup_file(archive, server, backup)
    fd, tmp = tempfile.mkstemp(suffix=".zip", prefix=".careerMP040-", dir=archive.parent)
    import os
    os.close(fd)
    try:
        with zipfile.ZipFile(archive, "r") as input_zip, zipfile.ZipFile(tmp, "w") as output_zip:
            for info in input_zip.infolist():
                if info.filename in changed and not info.is_dir():
                    data = changed[info.filename].read_bytes()
                else:
                    data = input_zip.read(info.filename)
                output_zip.writestr(info, data)
        with zipfile.ZipFile(tmp) as test:
            bad = test.testzip()
            if bad:
                raise RuntimeError(f"Patched RLS ZIP failed integrity check: {bad}")
        os.replace(tmp, archive)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server-root", type=Path, required=True)
    parser.add_argument("--build-root", type=Path, required=True)
    parser.add_argument("--patch-rls", action="store_true", help="Patch the existing complete server RLS ZIP")
    args = parser.parse_args()
    server = args.server_root.resolve()
    staged = (args.build_root / "Resources").resolve()
    if not server.is_dir():
        parser.error(f"Server root not found: {server}")
    if not (server / "Resources").is_dir():
        parser.error(f"Server Resources folder not found: {server / 'Resources'}")
    if not (staged / "Client").is_dir() or not (staged / "Server").is_dir():
        parser.error("Build output missing staged Resources/Client or Resources/Server")
    client_files = [p for p in (staged / "Client").rglob("*") if p.is_file() and p.suffix.lower() in CLIENT_SUFFIXES and p.name.lower() not in SKIP_CLIENT]
    server_files = [p for p in (staged / "Server").rglob("*") if p.is_file() and p.suffix.lower() in SERVER_SUFFIXES]
    if not client_files or not server_files:
        parser.error("Missing staged client ZIPs or server Lua; refusing partial deployment")
    critical = staged / "Server" / "CareerMP" / "careerMP.lua"
    if not critical.is_file() or "careerModeHello" not in critical.read_text(encoding="utf-8"):
        parser.error("Patched CareerMP server script not found")
    backup = (args.build_root / "deployment-backups" / datetime.now().strftime("%Y%m%d-%H%M%S-%f")).resolve()
    print(f"Installing {len(client_files)} client ZIP(s), {len(server_files)} server Lua file(s).")
    print(f"Backup directory: {backup}")
    for src in client_files:
        dest = server / "Resources" / "Client" / src.relative_to(staged / "Client")
        replace_file(src, dest, server, backup)
        print("Installed:", dest)
    for src in server_files:
        dest = server / "Resources" / "Server" / src.relative_to(staged / "Server")
        replace_file(src, dest, server, backup)
        print("Installed:", dest)
    if args.patch_rls:
        rls = server / "Resources" / "Client" / RLS_NAME
        patch_full_rls(rls, args.build_root / "RLS-OVERLAY-ONLY", server, backup)
        print("Updated complete RLS ZIP:", rls)
    else:
        print("RLS archive left unchanged (use --patch-rls for full RLS ZIP overlay).")
    print("Deployment complete. BeamMP itself, server config and runtime state were not modified.")
    print("Restart the BeamMP server before testing.")


if __name__ == "__main__":
    main()
