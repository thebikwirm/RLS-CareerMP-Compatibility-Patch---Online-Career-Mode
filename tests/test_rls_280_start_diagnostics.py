"""Verify the 0.40 RLS diagnostic patch is targeted and idempotent."""
import unittest

from scripts.rls_280_start_diagnostics import GAME_MODE, OLD, NEW, patch_start_diagnostics


class StartupDiagnosticsTests(unittest.TestCase):
    def test_replaces_only_targeted_start_call(self):
        original = "-- before\n" + OLD + "\n-- after"
        files = {GAME_MODE: original.encode()}
        patch_start_diagnostics(files)
        self.assertIn(NEW, files[GAME_MODE].decode())
        self.assertIn("-- before", files[GAME_MODE].decode())
        snapshot = files[GAME_MODE]
        patch_start_diagnostics(files)
        self.assertEqual(snapshot, files[GAME_MODE])

    def test_fails_closed_if_source_changes(self):
        with self.assertRaises(RuntimeError):
            patch_start_diagnostics({GAME_MODE: b"unexpected startup implementation"})

    def test_does_not_turn_failure_into_success(self):
        files = {GAME_MODE: OLD.encode()}
        patch_start_diagnostics(files)
        patched = files[GAME_MODE].decode()
        self.assertIn('if loaded == false then', patched)
        self.assertIn('error("career_start_failed: " .. tostring(reason))', patched)


if __name__ == "__main__":
    unittest.main()
