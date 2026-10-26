"""Offline regression coverage for targeted RLS profile diagnostics and paint quarantine."""
import unittest
from pathlib import Path
from scripts.rls_280_profile_diagnostics import (
    patch_rls_profile_diagnostics, STARTING, TRANSITIONS
)
from scripts.careermp_040_paint import patch_legacy_paint, PAINT


class PatchTests(unittest.TestCase):
    def test_rls_instrumentation_is_idempotent(self):
        root = Path("upstream/rls_2.8.0_slim")
        entries = {p: (root / p).read_bytes() for p in (STARTING, TRANSITIONS)}
        patch_rls_profile_diagnostics(entries)
        self.assertIn(b"Profile start refused by extensionManager", entries[STARTING])
        self.assertIn(b"Activation has no current profile", entries[TRANSITIONS])
        snapshot = dict(entries)
        patch_rls_profile_diagnostics(entries)
        self.assertEqual(entries, snapshot)

    def test_unknown_rls_layout_fails_closed(self):
        with self.assertRaises(RuntimeError):
            patch_rls_profile_diagnostics({STARTING: b"changed", TRANSITIONS: b"changed"})

    def test_legacy_paint_is_quarantined_without_inventory_alias(self):
        entries = {PAINT: b'local M = {}\nlocal x = career_modules_inventory\nreturn M'}
        patch_legacy_paint(entries)
        content = entries[PAINT].decode()
        self.assertIn("legacy per-part paint disabled", content)
        self.assertIn("function M.onVehicleReady(...) return nil end", content)
        self.assertNotIn("career_modules_inventory", content)
        snapshot = dict(entries)
        patch_legacy_paint(entries)
        self.assertEqual(snapshot, entries)

    def test_changed_paint_implementation_fails_closed(self):
        with self.assertRaises(RuntimeError):
            patch_legacy_paint({PAINT: b"local M={} return M"})


if __name__ == "__main__":
    unittest.main()
