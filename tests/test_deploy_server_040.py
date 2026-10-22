"""Regression tests for safe 0.40 server deployment (no BeamNG needed)."""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "deploy_server_040.py"


def make_zip(path: Path, entries: dict[str, str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w") as z:
        for key, value in entries.items():
            z.writestr(key, value)


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.server = root / "server"
        self.build = root / "build"
        for base in (self.server, self.build):
            (base / "Resources" / "Client").mkdir(parents=True)
            (base / "Resources" / "Server" / "CareerMP").mkdir(parents=True)
        self.old_lua = self.server / "Resources" / "Server" / "CareerMP" / "careerMP.lua"
        self.new_lua = self.build / "Resources" / "Server" / "CareerMP" / "careerMP.lua"
        self.old_lua.write_text("old-server")
        self.new_lua.write_text("careerModeHello careerModeReady")
        self.client = self.server / "Resources" / "Client" / "CareerMP.zip"
        make_zip(self.client, {"old.txt": "old"})
        make_zip(self.build / "Resources" / "Client" / "CareerMP.zip", {"new.txt": "new"})
        self.config = self.server / "Resources" / "Server" / "CareerMP" / "config.json"
        self.config.write_text('{"keep":true}')

    def run_deploy(self, *extra):
        return subprocess.run([sys.executable, str(SCRIPT), "--server-root", str(self.server),
                               "--build-root", str(self.build), *extra],
                              capture_output=True, text=True)

    def test_dry_run_does_not_modify_server(self):
        result = self.run_deploy("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.old_lua.read_text(), "old-server")
        self.assertFalse((self.build / "deployment-backups").exists())

    def test_deploy_preserves_config_and_records_backups(self):
        result = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("careerModeHello", self.old_lua.read_text())
        self.assertEqual(self.config.read_text(), '{"keep":true}')
        runs = list((self.build / "deployment-backups").iterdir())
        self.assertEqual(len(runs), 1)
        self.assertEqual(json.loads((runs[0] / "manifest.json").read_text())["status"], "installed")
        self.assertEqual((runs[0] / "Resources" / "Server" / "CareerMP" / "careerMP.lua").read_text(), "old-server")

    def test_missing_full_rls_fails_before_any_install(self):
        (self.build / "RLS-OVERLAY-ONLY").mkdir()
        (self.build / "RLS-OVERLAY-ONLY" / "patched.lua").write_text("new")
        result = self.run_deploy("--patch-rls")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.old_lua.read_text(), "old-server")

    def test_rls_overlay_replaces_only_matching_entry(self):
        full = self.server / "Resources" / "Client" / "rls_career_overhaul_v2.8.0_beta.zip"
        entries = {f"other/file-{i}.txt": f"value{i}" for i in range(12)}
        entries["patched.lua"] = "old"
        make_zip(full, entries)
        overlay = self.build / "RLS-OVERLAY-ONLY"
        overlay.mkdir()
        (overlay / "patched.lua").write_text("new")
        result = self.run_deploy("--patch-rls")
        self.assertEqual(result.returncode, 0, result.stderr)
        with zipfile.ZipFile(full) as z:
            self.assertEqual(z.read("patched.lua"), b"new")
            self.assertEqual(z.read("other/file-1.txt"), b"value1")

    def test_slim_rls_target_rejected(self):
        full = self.server / "Resources" / "Client" / "rls_career_overhaul_v2.8.0_beta.zip"
        make_zip(full, {"patched.lua": "old"})
        overlay = self.build / "RLS-OVERLAY-ONLY"
        overlay.mkdir()
        (overlay / "patched.lua").write_text("new")
        result = self.run_deploy("--patch-rls")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.old_lua.read_text(), "old-server")


if __name__ == "__main__":
    unittest.main()
