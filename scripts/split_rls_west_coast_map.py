"""Create a tiny BeamMP metadata ZIP for the RLS West Coast map.

The full RLS Overhaul ZIP remains untouched and supplies all the map assets.
The generated ZIP only adds levels/rls_west_coast/info.json.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import tempfile
import zipfile

LEVEL = "levels/rls_west_coast/"
INFO = LEVEL + "info.json"
RLS_NAME = "rls_career_overhaul_v2.8.0_beta.zip"
MAP_NAME = "rls_west_coast_info.zip"
OLD_MAP_NAME = "rls_west_coast.zip"


def checked_names(path: Path) -> list[str]:
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        if len(names) != len(set(names)):
            raise RuntimeError(f"Duplicate ZIP entries: {path}")
        for name in names:
            if name.startswith("/") or "\\" in name or ".." in Path(name).parts:
                raise RuntimeError(f"Unsafe ZIP entry {name!r}")
        bad = z.testzip()
        if bad:
            raise RuntimeError(f"Corrupt ZIP entry {bad!r} in {path}")
        return names


def generate(source: Path, info: Path, output: Path) -> Path:
    names = checked_names(source)
    if not any(name.startswith(LEVEL) and not name.endswith("/") for name in names):
        raise RuntimeError(f"{source} does not contain {LEVEL}")
    if INFO in names:
        raise RuntimeError(f"{INFO} already exists in RLS: metadata-only ZIP not needed")
    obj = json.loads(info.read_text(encoding="utf-8-sig"))
    if not isinstance(obj, dict):
        raise RuntimeError("info.json must contain a JSON object")
    payload = (json.dumps(obj, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    output.mkdir(parents=True, exist_ok=True)
    result = output / MAP_NAME
    with zipfile.ZipFile(result, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(INFO, payload)
    if checked_names(result) != [INFO]:
        raise RuntimeError("Metadata-only ZIP validation failed")
    return result


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--server-root", type=Path, default=Path("D:/beamng_server"))
    p.add_argument("--info-json", type=Path, required=True)
    p.add_argument("--install", action="store_true",
                   help="Install or replace the metadata ZIP; full RLS stays untouched")
    args = p.parse_args()
    client = args.server_root / "Resources" / "Client"
    source = client / RLS_NAME
    target = client / MAP_NAME
    old_target = client / OLD_MAP_NAME
    if not source.is_file() or not args.info_json.is_file():
        p.error("Full server RLS ZIP and --info-json are both required")
    if source.is_symlink() or target.is_symlink() or old_target.is_symlink():
        p.error("Symlink input or destination is not supported")
    if old_target.exists():
        p.error(f"Previous full map export still exists: {old_target}. "
                "Move it out of Resources/Client before installing the metadata-only ZIP.")
    with tempfile.TemporaryDirectory(prefix="rls-map-info-") as temp:
        built = generate(source, args.info_json, Path(temp))
        print(f"Prepared {MAP_NAME}: only {INFO} ({built.stat().st_size} bytes)")
        print(f"Full RLS mod unchanged: {source}")
        if not args.install:
            print("DRY RUN: no server files changed.")
            return
        if target.exists():
            backup = target.with_name(target.name + ".bak")
            if backup.exists():
                p.error(f"Refusing to overwrite previous backup: {backup}")
            shutil.copy2(target, backup)
            print(f"Backed up previous metadata ZIP: {backup}")
        fd, tmp = tempfile.mkstemp(prefix=".rls-info-", suffix=".zip", dir=client)
        os.close(fd)
        try:
            shutil.copy2(built, tmp)
            if checked_names(Path(tmp)) != [INFO]:
                raise RuntimeError("Staged metadata ZIP invalid")
            os.replace(tmp, target)
        finally:
            Path(tmp).unlink(missing_ok=True)
        print(f"Installed {target}")
        print("Map path: /levels/rls_west_coast/info.json")
        print("Restart BeamMP server and test joining.")


if __name__ == "__main__":
    main()
