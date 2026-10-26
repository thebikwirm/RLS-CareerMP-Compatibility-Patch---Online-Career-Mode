"""Regression checks for the narrowly scoped vanilla delivery POI guard."""
import unittest
from pathlib import Path
from scripts.rls_280_delivery_poi import patch_delivery_poi, VANILLA_SERVICES


class DeliveryPoiTests(unittest.TestCase):
    def test_only_delivery_poi_is_guarded(self):
        original = (Path("upstream/rls_2.8.0_slim") / VANILLA_SERVICES).read_bytes()
        entries = {VANILLA_SERVICES: original}
        patch_delivery_poi(entries)
        patched = entries[VANILLA_SERVICES].decode("utf-8")
        self.assertIn('listen("career_modules_delivery_general"', patched)
        self.assertIn('onGetRawPoiListForLevel = function(original, _, ...)', patched)
        self.assertIn('onActivityAcceptGatherData = function(original, _, ...)', patched)
        self.assertIn('pcall(original, ...)', patched)
        self.assertIn('result:find("dParcelManager", 1, true)', patched)
        self.assertIn('error(result)', patched)
        self.assertIn('listen("gameplay_crawl_saveSystem"', patched)
        before = dict(entries)
        patch_delivery_poi(entries)
        self.assertEqual(entries, before)

    def test_missing_or_changed_source_fails(self):
        with self.assertRaises(RuntimeError):
            patch_delivery_poi({})
        with self.assertRaises(RuntimeError):
            patch_delivery_poi({VANILLA_SERVICES: b"changed"})

if __name__ == "__main__":
    unittest.main()
