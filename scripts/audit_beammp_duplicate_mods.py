"""Read-only audit of local BeamNG ZIPs against BeamMP server ZIPs.

No mod is activated, disabled, moved, removed or modified. Identically named
ZIPs are compared by size then SHA-256. Large collections can take time.
"""
from __future__ import annotations
import argparse
import csv
import hashlib
from pathlib import Path

def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(4 * 1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--server-root", type=Path, default=Path(r"D:\beamng_server"))
    ap.add_argument("--client-mods", type=Path, default=Path(r"D:\beamng stuff\current\mods"))
    ap.add_argument("--output", type=Path, default=Path("beammp_duplicate_mod_report.csv"))
    args = ap.parse_args()
    server = args.server_root / "Resources" / "Client"
    local = args.client_mods
    if not server.is_dir() or not local.is_dir():
        ap.error(f"Folders missing: server={server} client={local}")
    # Only ordinary local ZIP mods. Multiplayer copies are deliberately excluded.
    local_files = [p for p in local.rglob("*.zip")
                   if "multiplayer" not in (x.lower() for x in p.relative_to(local).parts[:-1])]
    by_name: dict[str, list[Path]] = {}
    for p in local_files:
        by_name.setdefault(p.name.lower(), []).append(p)
    rows = []
    stats: dict[str, int] = {}
    for n, server_zip in enumerate(sorted(server.glob("*.zip")), 1):
        candidates = by_name.get(server_zip.name.lower(), [])
        result = "NO_LOCAL_NAME_MATCH"
        matched_path = ""
        size_server = server_zip.stat().st_size
        if candidates:
            same_size = [p for p in candidates if p.stat().st_size == size_server]
            if not same_size:
                result = "NAME_MATCH_SIZE_DIFFERS"
            else:
                server_hash = digest(server_zip)
                same_hash = [p for p in same_size if digest(p) == server_hash]
                if same_hash:
                    result = "IDENTICAL_SHA256"
                    matched_path = str(same_hash[0])
                else:
                    result = "NAME_SIZE_MATCH_HASH_DIFFERS"
                    matched_path = str(same_size[0])
        stats[result] = stats.get(result, 0) + 1
        print(f"[{n:>3}] {result:<30} {server_zip.name}", flush=True)
        rows.append({"status": result, "server_zip": str(server_zip),
                     "local_zip": matched_path or ("; ".join(map(str, candidates)) if candidates else ""),
                     "server_bytes": size_server})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8-sig", newline="") as fp:
        writer = csv.DictWriter(fp, fieldnames=["status", "server_zip", "local_zip", "server_bytes"])
        writer.writeheader()
        writer.writerows(rows)
    print("\nAUDIT COMPLETE (no files changed)")
    for status, count in sorted(stats.items()):
        print(f"  {status}: {count}")
    print(f"CSV report: {args.output.resolve()}")
    print("NOTE: Identical ZIPs alone do not prove it is safe to bypass BeamMP activation.")

if __name__ == "__main__":
    main()
