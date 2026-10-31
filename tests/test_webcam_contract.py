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
        self.assertIn('#define M7_WEBCAM_TARGET_FPS 30', (ROOT / "iOS/M7WebcamCodec.h").read_text())
        self.assertIn('const NSUInteger M7WebcamTargetFPS = M7_WEBCAM_TARGET_FPS',
                      (ROOT / "iOS/M7WebcamEncoder.m").read_text())
        self.assertIn('M7WebcamTargetFPS = M7_WEBCAM_TARGET_FPS', self.server)
        self.assertNotIn('now - self.lastWebcamTime < .1', self.controller)
        self.assertIn('return pending.codec == M7WebcamCodecMJPEG; }];', self.server)
        self.assertIn('@"maxPendingFrames":@1', self.server)
        self.assertIn('M7WebcamMaxPendingH264Bytes', self.server)

    def test_desktop_waits_for_video_and_converts_full_range_explicitly(self):
        self.assertIn('state.captureMode === "video"', self.desktop)
        self.assertIn('in_range=full:out_range=limited', self.desktop)
        self.assertIn('"-fps_mode", "passthrough"', self.desktop)

    def test_h264_is_low_latency_and_recoverable(self):
        encoder = (ROOT / "iOS/M7WebcamEncoder.m").read_text()
        self.assertIn('kVTCompressionPropertyKey_AllowFrameReordering:@NO', encoder)
        self.assertIn('kVTCompressionPropertyKey_RealTime:@YES', encoder)
        self.assertIn('kVTEncodeFrameOptionKey_ForceKeyFrame', encoder)
        self.assertIn('GET /v1/webcam.h264 ', self.server)
        self.assertIn('entry.waitingKeyframe = h264', self.server)
        self.assertIn('closeClientsForCodec:M7WebcamCodecH264', self.controller)
        self.assertIn('return CGSizeMake(1080, 1920)', encoder)

    def test_camera_mount_defaults_to_landscape_and_persists(self):
        encoder = (ROOT / "iOS/M7WebcamEncoder.m").read_text()
        self.assertIn('savedMount.integerValue : M7CameraMountLandscape', self.controller)
        self.assertIn('setInteger:mount forKey:M7CameraMountDefaultsKey', self.controller)
        self.assertIn('AVCaptureVideoOrientationLandscapeRight', self.controller)
        # Photos stay portrait; only the data output follows the mount.
        self.assertIn('M7VideoOrientationForMount(self.cameraMount) : AVCaptureVideoOrientationPortrait',
                      self.controller)
        self.assertIn('return CGSizeMake(1920, 1080)', encoder)
        self.assertIn('M7WebcamDevicePointForMount(mount, source, target, center, framePoint)',
                      self.controller)
        self.assertIn('orientation:M7PreviewImageOrientation(self.cameraMount)', self.controller)
        self.assertIn('[control isEqual:@"cameraMount"]', self.controller)

    def test_frame_rate_is_fixed_24_or_30_and_persists(self):
        controls = (ROOT / "iOS/M7DeviceControls.m").read_text()
        recorder = (ROOT / "iOS/M7VideoRecorder.m").read_text()
        reframe = (ROOT / "iOS/M7VideoReframe.m").read_text()
        encoder = (ROOT / "iOS/M7WebcamEncoder.m").read_text()
        self.assertIn('self.frameRate = savedRate == 24 ? 24 : 30;', self.controller)
        self.assertIn('setInteger:fps forKey:M7FrameRateDefaultsKey', self.controller)
        self.assertIn('[control isEqual:@"frameRate"]', self.controller)
        self.assertIn('@"frameRate aceita 24 ou 30."', self.controller)
        # Video mode, recording and the webcam all use the chosen rate.
        self.assertIn('configureVideoFormatAtFPS:self.frameRate', self.controller)
        self.assertNotIn('configureVideoFormatAtFPS:30', self.controller)
        self.assertIn('recorder.frameRate = self.frameRate;', self.controller)
        self.assertIn('AVVideoExpectedSourceFrameRateKey:@(self.frameRate)', recorder)
        self.assertIn('track.nominalFrameRate', reframe)
        self.assertNotIn('CMTimeMake(1, 30);', reframe)
        self.assertIn('ExpectedFrameRate:@(fps)', encoder)
        # A live change keeps the format (and so manual exposure); a fixed
        # rate means equal minimum and maximum frame durations.
        self.assertIn('[self.controls applyFrameRate:fps error:&error]', self.controller)
        self.assertIn('device.activeVideoMinFrameDuration = frameDuration;\n'
                      '    device.activeVideoMaxFrameDuration = frameDuration;', controls)
        self.assertIn('if (self.videoRecording || self.videoProcessing) {\n'
                      '        self.frameRateControl.selectedSegmentIndex', self.controller)

    def test_webcam_slows_down_when_the_iphone_is_hot(self):
        self.assertIn('NSProcessInfoThermalStateDidChangeNotification', self.controller)
        self.assertIn('state >= NSProcessInfoThermalStateCritical ? 15', self.controller)
        self.assertIn('++self.webcamThermalDrops; return;', self.controller)
        self.assertIn('state[@"now"] = @(NSDate.date.timeIntervalSince1970)', self.controller)

    def test_screen_stays_awake_only_while_webcam_streams(self):
        # Auto-lock resigns Camera, and resigning stops the webcam.
        self.assertIn('application.idleTimerDisabled = awake || self.idleTimerWasDisabled',
                      self.controller)
        self.assertEqual(self.controller.count('[self keepScreenAwakeForWebcam:NO]'), 3)
        self.assertIn('[self keepScreenAwakeForWebcam:ready]', self.controller)
        self.assertIn('@"screenKeptAwake"', self.controller)

    def test_attached_bridge_workers_time_out_waiting_for_a_request(self):
        remote = (ROOT / "iOS/M7RemoteServer.m").read_text()
        for source in (self.server, remote):
            activated = source.index('BridgeActivation, sizeof(activation)) == 0) {')
            handled = source.index('[owner handleClient:client', activated)
            self.assertIn('SO_RCVTIMEO', source[activated:handled])

    def test_desktop_shares_one_upstream_and_detects_dead_ssh(self):
        self.assertIn('this.previewFanout.subscribe(httpSink(response', self.desktop)
        self.assertEqual(self.desktop.count('/v1/webcam.mjpg'), 1)
        self.assertEqual(self.desktop.count('/v1/webcam.h264'), 1)
        self.assertIn('keepaliveInterval: 5_000', self.desktop)

    def test_desktop_prefers_usb_and_h264_with_fallbacks(self):
        self.assertIn('await openUsbConnection(port)', self.desktop)
        self.assertIn('client = await this.sshHandshake({ host, port }', self.desktop)
        self.assertIn('state.webcam?.h264?.available === true', self.desktop)
        self.assertIn('"-f", "h264", "-i", this.previewURL("h264")', self.desktop)


if __name__ == "__main__":
    unittest.main()
