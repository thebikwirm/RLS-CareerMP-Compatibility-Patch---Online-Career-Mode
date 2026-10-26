"""Check that the CareerMP pause save action is limited to negotiated RLS sessions."""
import unittest
from pathlib import Path
from scripts.rls_280_careermp_save import patch_pause_save, PAUSE

class SaveMenuTests(unittest.TestCase):
    def test_pause_save_is_local_and_conditional(self):
        original = (Path("upstream/rls_2.8.0_slim") / PAUSE).read_bytes()
        entries = {PAUSE: original}
        patch_pause_save(entries)
        changed = entries[PAUSE].decode("utf-8")
        self.assertIn("mp.isOverhaulModeNegotiated()", changed)
        self.assertIn('if negotiated then', changed)
        self.assertIn('label = "Save Career"', changed)
        self.assertIn('overhaul_shell_gameMode.save()', changed)
        self.assertNotIn("TriggerServerEvent", changed)
        patch_pause_save(entries)
        self.assertEqual(changed, entries[PAUSE].decode("utf-8"))

    def test_changed_anchor_fails(self):
        with self.assertRaises(RuntimeError):
            patch_pause_save({PAUSE: b"changed"})

if __name__ == "__main__":
    unittest.main()
