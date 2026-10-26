"""Confirm server/client readiness diagnostics are present in 0.40 patch sources."""
import unittest
from pathlib import Path

class HandshakeDiagnosticsTests(unittest.TestCase):
    def test_server_ready_logging_and_ack(self):
        s = Path("scripts/careermp_040_server.py").read_text(encoding="utf-8")
        for phrase in ("[CareerMP040-DIAG] hello player=", "[CareerMP040-DIAG] negotiated player=",
                       "[CareerMP040-DIAG] sync requested player=", "[CareerMP040-DIAG] ready received player=",
                       "[CareerMP040-DIAG] ready accepted player=", '"rxCareerModeReadyAck"'):
            self.assertIn(phrase, s)
        self.assertIn("entry.careerActive = true", s)
        self.assertIn("activation timeout player=", s)
        self.assertIn("awaiting_mode_hello", s)
        self.assertIn("awaiting_career_ready", s)

    def test_client_ready_ack_handler_in_both_paths(self):
        s = Path("scripts/careermp_040_handshake.py").read_text(encoding="utf-8")
        self.assertIn("local function rxCareerModeReadyAck(data)", s)
        self.assertEqual(s.count('AddEventHandler("rxCareerModeReadyAck", rxCareerModeReadyAck)'), 2)
        self.assertIn("server acknowledged RLS career activation", s)

if __name__ == "__main__":
    unittest.main()
