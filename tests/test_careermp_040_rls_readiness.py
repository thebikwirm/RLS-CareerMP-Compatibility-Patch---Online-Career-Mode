"""Source-level checks for RLS mount-aware CareerMP startup."""
import unittest
from scripts.careermp_040_handshake import patch_client_handshake, CLIENT


class RlsReadinessTests(unittest.TestCase):
    def test_both_enabler_update_paths_wait(self):
        # The customized CareerMP branch uses processPendingCareerStart;
        # the older path has worldReadyState. Both must gate activation.
        from pathlib import Path
        source = Path("scripts/careermp_040_handshake.py").read_text(encoding="utf-8")
        self.assertEqual(source.count("if not careerMP040RlsReady() then return end"), 2)
        self.assertIn('mode.careerMPVehicleSafety == true', source)
        self.assertIn('FS:fileExists("/lua/ge/extensions/overhaul/shell/gameMode.lua")', source)
        self.assertIn("if not modeConfirmed then return false end", source)
        self.assertEqual(source.count("careerMP040ReconnectHello(dtReal)"), 2)
        self.assertIn("reconnect negotiation hello", source)
        self.assertEqual(source.count("and not (rlsCareer and type(rlsCareer.isActive)"), 2)
        self.assertIn("TriggerServerEvent(\"careerModeReady\"", source)
        self.assertIn('modeConfirmed = false', source)


if __name__ == "__main__":
    unittest.main()
