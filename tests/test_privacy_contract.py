import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class PrivacyContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.controller = (ROOT / "iOS/M7CameraController.m").read_text(encoding="utf-8")

    def test_ip_pattern_matches_addresses_but_not_versions(self):
        source = re.search(r'regularExpressionWithPattern:\s*@"(.+?)"', self.controller).group(1)
        pattern = re.compile(source.replace("\\\\", "\\"))
        text = "callback 192.168.1.20:43123 · iOS 15.8.3 · 10.0.0.255 · 999.1.1.1"
        self.assertEqual(pattern.findall(text), ["192.168.1.20", "10.0.0.255"])

    def test_status_pin_and_diagnostic_are_masked_until_tapped(self):
        self.assertIn("M7RedactIPv4(self.statusText)", self.controller)
        self.assertIn("self.pinRevealed ? self.remotePIN : M7PINMask", self.controller)
        self.assertIn("revealed ? fullText : M7RedactIPv4(fullText)", self.controller)
        self.assertNotRegex(self.controller, r"remoteLabel\.text = \[NSString stringWithFormat:[^;]*remotePIN")

    def test_state_polls_do_not_flood_the_session_log(self):
        self.assertIn("if (statePoll && statusCode < 400) { response(statusCode, payload); return; }",
                      self.controller)
        snapshot = self.controller.split("- (NSDictionary *)webcamSnapshot {", 1)[1].split("\n}\n", 1)[0]
        self.assertNotIn("dispatch_sync", snapshot)


if __name__ == "__main__":
    unittest.main()
