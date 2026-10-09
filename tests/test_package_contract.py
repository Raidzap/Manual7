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

    def test_launchd_bridge_is_packaged_for_rootless_dopamine(self):
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        plist = (ROOT / "layout/Library/LaunchDaemons/dev.manual7.bridge.plist").read_text(
            encoding="utf-8")
        self.assertIn("TOOL_NAME = manual7bridge", makefile)
        self.assertIn("/var/jb/usr/libexec/manual7bridge", plist)
        self.assertIn("<string>mobile</string>", plist)
        for script in ("postinst", "prerm"):
            path = ROOT / "layout/DEBIAN" / script
            self.assertTrue(path.stat().st_mode & 0o111)

    def test_remote_startup_never_blocks_view_did_load(self):
        source = (ROOT / "iOS/M7CameraController.m").read_text(encoding="utf-8")
        view_did_load = source.split("- (void)viewDidLoad", 1)[1].split(
            "- (void)viewDidLayoutSubviews", 1)[0]
        self.assertIn('[self scheduleRemoteServerStart:@"viewDidLoad"]', view_did_load)
        self.assertNotIn("[self startRemoteServer]", view_did_load)
        self.assertIn('dispatch_queue_create("dev.manual7.remote.lifecycle"', source)
        self.assertIn('@"fallbackSocketsAttempted":@NO', source)

    def test_bridge_connect_has_a_short_bounded_timeout(self):
        for filename in ("M7RemoteServer.m", "M7WebcamServer.m"):
            source = (ROOT / "iOS" / filename).read_text(encoding="utf-8")
            self.assertIn("poll(&descriptor", source)
            self.assertIn("TimeoutMilliseconds = 250", source)


if __name__ == "__main__":
    unittest.main()
