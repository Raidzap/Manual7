import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class WebcamContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.controller = (ROOT / "iOS/M7CameraController.m").read_text()
        cls.server = (ROOT / "iOS/M7WebcamServer.m").read_text()
        cls.desktop = (ROOT / "desktop/src/main.js").read_text()

    def test_webcam_forces_video_mode_and_blocks_photo_switch(self):
        self.assertIn('webcamVideoModeRequested', self.controller)
        self.assertIn('[self configureSessionForVideo:YES]', self.controller)
        self.assertIn('captureModeChangeBlocked', self.controller)
        self.assertIn('!self.webcamRequested && !self.webcamEnabled', self.controller)

    def test_stream_uses_camera_cadence_without_unbounded_queue(self):
        self.assertIn('const NSUInteger M7WebcamTargetFPS = 30',
                      (ROOT / "iOS/M7WebcamEncoder.m").read_text())
        self.assertNotIn('now - self.lastWebcamTime < .1', self.controller)
        self.assertIn('self.pendingJPEG = jpeg', self.server)
        self.assertIn('@"maxPendingFrames":@1', self.server)

    def test_desktop_waits_for_video_and_converts_full_range_explicitly(self):
        self.assertIn('state.captureMode === "video"', self.desktop)
        self.assertIn('in_range=full:out_range=limited', self.desktop)
        self.assertIn('"-fps_mode", "passthrough"', self.desktop)


if __name__ == "__main__":
    unittest.main()
