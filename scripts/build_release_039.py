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
from zip_utils import add_zip_engine_argument, describe_zip_engine


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
    )
    add_zip_engine_argument(parser)
    args = parser.parse_args()

    rls_original = args.rls_original.expanduser().resolve()
    careermp_original = args.careermp_039.expanduser().resolve()
    out_dir = args.out_dir.expanduser().resolve()

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
    )

    # CareerMP-0.39 already contains its own BeamNG 0.39 compatibility layer,
    # runtime career patches and profile handling. Do not overlay the old
    # CareerMP 0.0.37 patch directory onto it.
    shutil.copy2(careermp_original, careermp_out)
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
                "CareerMP-0.39 copied unchanged by design",
                f"zip_engine={describe_zip_engine(args.zip_engine)}",
            ]
        ),
        encoding="utf-8",
    )

    print(f"Built: {rls_out}")
    print(f"Copied unchanged: {careermp_out}")
    print(f"Wrote: {checksums}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
