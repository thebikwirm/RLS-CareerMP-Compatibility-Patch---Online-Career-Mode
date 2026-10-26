"""Safely deploy experimental BeamNG 0.40 CareerMP resources to a local server.

Runs a complete preflight before touching the server. Installs only staged ZIPs
and Lua scripts, preserving BeamMP binaries, configuration and save state.
Every existing replaced file is backed up. Roll back file replacements on error.
An RLS overlay must be applied to an installed *full* ZIP, never the slim source.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import zipfile

RLS_NAME = "rls_career_overhaul_v2.8.0_beta.zip"
SERVER_SUFFIXES = {".lua"}
CLIENT_SUFFIXES = {".zip"}


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for data in iter(lambda: f.read(1024 * 1024), b""):
            h.update(data)
    return h.hexdigest()


def zip_entries(path: Path) -> set[str]:
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise RuntimeError(f"Duplicate ZIP entries in {path}")
        for name in names:
            parts = Path(name.replace("\\", "/")).parts
            if name.startswith("/") or ".." in parts or "\\" in name:
                raise RuntimeError(f"Unsafe ZIP entry {name!r} in {path}")
        bad = archive.testzip()
        if bad:
            raise RuntimeError(f"ZIP integrity check failed in {path}: {bad}")
        return {name for name in names if not name.endswith("/")}


def prepare_rls(archive: Path, overlay: Path, tmpdir: Path) -> Path:
    if not archive.is_file():
        raise RuntimeError(f"Full installed RLS ZIP missing: {archive}")
    if not overlay.is_dir():
        raise RuntimeError(f"RLS overlay missing: {overlay}")
    changes = {p.relative_to(overlay).as_posix(): p for p in overlay.rglob("*") if p.is_file()}
    if not changes:
        raise RuntimeError("RLS overlay is empty")
    existing = zip_entries(archive)
    missing = sorted(changes.keys() - existing)
    # New phone files are an intentional addition to the full RLS ZIP. Other
    # unknown overlay paths still indicate a mismatched archive/source.
    allowed_additions = {
        "gameplay/overhaul/phone/apps/careermp-online.json",
        "ui/ui-vue/mods/careermp/phone/CareerMPHome.vue",
    }
    unexpected = sorted(set(missing) - allowed_additions)
    if unexpected:
        raise RuntimeError("RLS target mismatches source; missing: " + ", ".join(unexpected[:12]))
    if len(existing) <= len(changes) + 5:
        raise RuntimeError("Installed RLS ZIP looks like a slim source archive; refusing deployment")
    # Build and integrity-check a complete replacement outside the server tree.
    result = tmpdir / RLS_NAME
    with zipfile.ZipFile(archive) as original, zipfile.ZipFile(result, "w") as patched:
        for info in original.infolist():
            data = changes[info.filename].read_bytes() if info.filename in changes and not info.is_dir() else original.read(info.filename)
            patched.writestr(info, data)
        for name in missing:
            patched.write(changes[name], arcname=name)
    if zip_entries(result) != existing | set(missing):
        raise RuntimeError("Patched RLS entry list differs from expected full source and approved additions")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server-root", type=Path, required=True)
    parser.add_argument("--build-root", type=Path, required=True)
    parser.add_argument("--patch-rls", action="store_true")
    parser.add_argument("--dry-run", action="store_true", help="Validate and list changes without installing")
    args = parser.parse_args()
    server = args.server_root.resolve()
    build = args.build_root.resolve()
    staged = build / "Resources"
    if not (server / "Resources" / "Client").is_dir() or not (server / "Resources" / "Server").is_dir():
        parser.error(f"Server Resources/Client and Resources/Server required under {server}")
    if not (staged / "Client").is_dir() or not (staged / "Server").is_dir():
        parser.error("Built Resources/Client and Resources/Server are required")
    if server == build or server in build.parents or build in server.parents:
        parser.error("Build directory and server directory must be separate")
    critical = staged / "Server" / "CareerMP" / "careerMP.lua"
    if not critical.is_file() or not all(x in critical.read_text(encoding="utf-8") for x in ("careerModeHello", "careerModeReady")):
        parser.error("Expected patched CareerMP handshake missing")

    files: list[tuple[Path, Path]] = []
    for area, extensions in (("Client", CLIENT_SUFFIXES), ("Server", SERVER_SUFFIXES)):
        source = staged / area
        for item in sorted(source.rglob("*")):
            if not item.is_file() or item.suffix.lower() not in extensions:
                continue
            if item.is_symlink():
                parser.error(f"Symlink input refused: {item}")
            if area == "Client":
                if item.name.lower() == RLS_NAME.lower():
                    continue  # Slim RLS source must NEVER be installed.
                zip_entries(item)
            relative = item.relative_to(source)
            target = server / "Resources" / area / relative
            if target.is_symlink() or any(p.is_symlink() for p in target.parents if p != server.parent):
                parser.error(f"Symlink target refused: {target}")
            files.append((item, target))
    if not any(dst == server / "Resources" / "Client" / "CareerMP.zip" for _, dst in files):
        parser.error("Patched CareerMP.zip missing from staged Client")
    if not any(dst == server / "Resources" / "Server" / "CareerMP" / "careerMP.lua" for _, dst in files):
        parser.error("Patched server Lua missing")

    # All validations and ZIP assembly happen before the first destination write.
    with tempfile.TemporaryDirectory(prefix="beamng-040-preflight-") as temp:
        scratch = Path(temp)
        if args.patch_rls:
            target = server / "Resources" / "Client" / RLS_NAME
            if target.is_symlink():
                parser.error("RLS target is a symlink")
            files.append((prepare_rls(target, build / "RLS-OVERLAY-ONLY", scratch), target))
        if len({str(dst).lower() for _, dst in files}) != len(files):
            parser.error("Duplicate destination paths")

        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S-%fZ")
        backup = build / "deployment-backups" / stamp
        changes = [{
            "destination": str(dst),
            "relative": str(dst.relative_to(server)),
            "before_sha256": digest(dst) if dst.is_file() else None,
            "after_sha256": digest(src),
            "existed": dst.is_file(),
        } for src, dst in files]
        print(json.dumps({"dry_run": args.dry_run, "changes": changes}, indent=2))
        if args.dry_run:
            print("Preflight passed; no server files changed.")
            return

        backup.mkdir(parents=True, exist_ok=False)
        manifest = {"status": "in_progress", "server": str(server), "created_utc": stamp,
                    "changes": changes}
        manifest_path = backup / "manifest.json"

        def record(status: str, error: str | None = None) -> None:
            manifest["status"] = status
            if error is not None:
                manifest["error"] = error
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

        # Back up *all* destinations before making *any* replacement.
        for _, dst in files:
            if dst.exists():
                if not dst.is_file():
                    raise RuntimeError(f"Destination is not a regular file: {dst}")
                saved = backup / dst.relative_to(server)
                saved.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(dst, saved)
                if digest(saved) != digest(dst):
                    raise RuntimeError(f"Backup verification failed: {dst}")
        record("backed_up")
        touched: list[Path] = []
        try:
            for src, dst in files:
                dst.parent.mkdir(parents=True, exist_ok=True)
                fd, tmpname = tempfile.mkstemp(prefix=".beamng040-", dir=dst.parent)
                os.close(fd)
                try:
                    shutil.copy2(src, tmpname)
                    if digest(Path(tmpname)) != digest(src):
                        raise RuntimeError(f"Staged copy failed verification: {dst}")
                    os.replace(tmpname, dst)
                    touched.append(dst)
                finally:
                    if os.path.exists(tmpname):
                        os.unlink(tmpname)
            record("installed")
        except Exception as exc:
            rollback_errors = []
            for dst in reversed(touched):
                try:
                    saved = backup / dst.relative_to(server)
                    if saved.is_file():
                        shutil.copy2(saved, dst)
                    else:
                        dst.unlink(missing_ok=True)
                except Exception as rollback_exc:
                    rollback_errors.append(f"{dst}: {rollback_exc}")
            record("rollback_incomplete" if rollback_errors else "rolled_back",
                   f"{exc}; rollback errors: {rollback_errors}")
            raise RuntimeError(f"Deployment failed: {exc}; rollback errors: {rollback_errors}") from exc
        print(f"Installed {len(files)} files. Backup and manifest: {backup}")
        print("BeamMP installation, configs and saves were not copied. Restart server before testing.")


if __name__ == "__main__":
    main()
