"""Regression: Objective-C capture callbacks must match the AVFoundation API.

Set THEOS to run compiler checks with the iOS 15.6 SDK. No device is needed.
The two negative cases reproduce the incorrect Swift-style selector spelling.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CaptureContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not os.environ.get('THEOS'):
            raise unittest.SkipTest('THEOS is required for the iOS callback contract checks')
        theos = Path(os.environ['THEOS'])
        cls.compiler = theos / 'toolchain/linux/iphone/bin/clang'
        sdk = theos / 'sdks/iPhoneOS15.6.sdk'
        if not cls.compiler.is_file() or not sdk.is_dir():
            raise unittest.SkipTest('Linux iOS compiler and iPhoneOS15.6.sdk are required')
        cls.flags = ['-fsyntax-only', '-fobjc-arc', '-Werror=protocol',
                     '-Werror=incomplete-implementation', '-target', 'arm64-apple-ios15.0',
                     '-isysroot', str(sdk), '-I', str(ROOT / 'iOS')]
        cls.source = (ROOT / 'iOS/M7CameraController.m').read_text()

    def compile(self, source):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'Controller.m'
            path.write_text(source)
            return subprocess.run([str(self.compiler), *self.flags, str(path)],
                                  capture_output=True, text=True)

    def test_production_implements_required_callbacks(self):
        result = self.compile(self.source)
        self.assertEqual(result.returncode, 0, result.stderr)

    def check_wrong_spelling(self, callback):
        prefix = 'captureOutput:(__unused AVCapturePhotoOutput *)output ' + callback
        self.assertIn(prefix, self.source)
        broken = self.source.replace(prefix,
            'photoOutput:(__unused AVCapturePhotoOutput *)output ' + callback, 1)
        result = self.compile(broken)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('M7RequiredPhotoCaptureDelegate', result.stderr)
        self.assertIn(callback, result.stderr)

    def test_rejects_wrong_processing_callback(self):
        self.check_wrong_spelling('didFinishProcessingPhoto')

    def test_rejects_wrong_completion_callback(self):
        self.check_wrong_spelling('didFinishCaptureForResolvedSettings')
