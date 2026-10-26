"""Existing RLS profile selection must never create a numbered sibling."""
import unittest
from scripts.careermp_040_enabler import patch_profile_selector

class ExistingProfileGuardTests(unittest.TestCase):
    def test_exact_folder_required(self):
        source = '''local M = {}
local result = compat.createOrLoadCareerAndStart(profileName, false, compat.defaultStartMode)
'''
        patched = patch_profile_selector(source)
        self.assertIn('FS:directoryExists(exactPath)', patched)
        self.assertIn('Existing RLS profile folder NOT FOUND', patched)
        self.assertIn('return nil', patched)
        self.assertIn('resolveConfiguredCareerMPProfile(profileName)', patched)

if __name__ == "__main__":
    unittest.main()
