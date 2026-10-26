"""Source checks for the first RLS CareerMP phone entry."""
import json
import unittest
from scripts.rls_280_careermp_phone import patch_careermp_phone, MANIFEST, COMPONENT

class CareerMPPhoneTests(unittest.TestCase):
    def test_phone_manifest_and_vue_are_staged(self):
        entries = {}
        patch_careermp_phone(entries)
        app = json.loads(entries[MANIFEST])
        self.assertEqual(app["id"], "careermp-online")
        self.assertEqual(app["component"], "/" + COMPONENT)
        self.assertIn(b"<template>", entries[COMPONENT])
        self.assertIn(b"CareerMP", entries[COMPONENT])
        self.assertIn(b"overhaul_shell_gameMode.save()", entries[COMPONENT])
        self.assertIn(b"useBridge", entries[COMPONENT])
        self.assertNotIn(b"TriggerServerEvent", entries[COMPONENT])
        prior = dict(entries)
        patch_careermp_phone(entries)
        self.assertEqual(entries, prior)

    def test_collision_refused(self):
        with self.assertRaises(RuntimeError):
            patch_careermp_phone({MANIFEST: b"other"})

if __name__ == "__main__":
    unittest.main()
