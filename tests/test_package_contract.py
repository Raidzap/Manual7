from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class PackageContractTests(unittest.TestCase):
    def test_openssh_server_is_a_hard_dependency(self):
        fields = {}
        for line in (ROOT / "control").read_text(encoding="utf-8").splitlines():
            if ":" in line:
                key, value = line.split(":", 1)
                fields[key] = value.strip()
        dependencies = {item.strip().split(" ", 1)[0]
                        for item in fields["Depends"].split(",")}
        self.assertIn("openssh-server", dependencies)
        self.assertEqual(fields["Architecture"], "iphoneos-arm64")


if __name__ == "__main__":
    unittest.main()
