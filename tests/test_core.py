"""Run with python3 -m unittest discover -s tests -v (requires cc)."""
import ctypes as C
import math
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        lib = Path(cls.temp.name) / 'libm7.so'
        subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                        '-shared', '-fPIC', str(ROOT / 'Core/M7Math.c'),
                        '-o', str(lib), '-lm'], check=True)
        cls.api = C.CDLL(str(lib))
        cls.api.m7_shutter_range.argtypes = [C.c_double, C.c_double,
                                            C.POINTER(C.c_int), C.POINTER(C.c_int)]
        cls.api.m7_shutter_range.restype = C.c_bool
        cls.api.m7_shutter_seconds.argtypes = [C.c_int]
        cls.api.m7_shutter_seconds.restype = C.c_double
        cls.api.m7_shutter_nearest.argtypes = [C.c_double] * 3 + [C.POINTER(C.c_int)]
        cls.api.m7_shutter_nearest.restype = C.c_bool
        cls.api.m7_iso_from_slider.argtypes = [C.c_double] * 3
        cls.api.m7_iso_from_slider.restype = C.c_double
        cls.api.m7_peaking.argtypes = [C.POINTER(C.c_uint8), C.c_size_t,
            C.c_size_t, C.c_size_t, C.POINTER(C.c_uint8), C.c_size_t, C.c_double]
        cls.api.m7_peaking.restype = C.c_bool

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_third_stops_and_hardware_limits(self):
        a, b = C.c_int(), C.c_int()
        self.assertTrue(self.api.m7_shutter_range(1 / 8000, 1 / 3, C.byref(a), C.byref(b)))
        values = [self.api.m7_shutter_seconds(i) for i in range(a.value, b.value + 1)]
        self.assertTrue(all(1 / 8000 <= t <= 1 / 3 for t in values))
        for x, y in zip(values, values[1:]):
            self.assertAlmostEqual(math.log2(y / x), 1 / 3, places=12)
        self.assertLess(self.api.m7_shutter_seconds(a.value - 1), 1 / 8000)
        self.assertGreater(self.api.m7_shutter_seconds(b.value + 1), 1 / 3)

    def test_exact_grid_endpoints(self):
        for k in range(-60, 20):
            value = self.api.m7_shutter_seconds(k)
            a, b = C.c_int(), C.c_int()
            self.assertTrue(self.api.m7_shutter_range(value, value, C.byref(a), C.byref(b)))
            self.assertEqual((a.value, b.value), (k, k))

    def test_invalid_and_empty_ranges(self):
        a, b = C.c_int(), C.c_int()
        for lo, hi in [(0, 1), (2, 1), (math.nan, 1), (1, math.inf), (0.90, 0.95)]:
            self.assertFalse(self.api.m7_shutter_range(lo, hi, C.byref(a), C.byref(b)))

    def test_nearest_uses_log_distance(self):
        index = C.c_int()
        self.assertTrue(self.api.m7_shutter_nearest(1 / 125, 1 / 8000, 1 / 3, C.byref(index)))
        self.assertAlmostEqual(self.api.m7_shutter_seconds(index.value), 1 / 128)
        self.assertFalse(self.api.m7_shutter_nearest(math.nan, .001, 1, C.byref(index)))

    def test_iso_logarithmic_and_clamped(self):
        self.assertAlmostEqual(self.api.m7_iso_from_slider(.5, 25, 1600), 200)
        self.assertAlmostEqual(self.api.m7_iso_from_slider(-1, 25, 1600), 25)
        self.assertAlmostEqual(self.api.m7_iso_from_slider(2, 25, 1600), 1600)
        self.assertTrue(math.isnan(self.api.m7_iso_from_slider(.5, 0, 1600)))

    def overlay(self, pixels, width=9, height=7, threshold=.3):
        stride = width + 5
        out_stride = width * 4 + 8
        source = (C.c_uint8 * (stride * height))()
        target = (C.c_uint8 * (out_stride * height))(*([99] * (out_stride * height)))
        for y in range(height):
            for x in range(width):
                source[y * stride + x] = pixels[y][x]
        self.assertTrue(self.api.m7_peaking(source, width, height, stride,
                                          target, out_stride, threshold))
        for y in range(height):
            self.assertEqual(list(target[y*out_stride+width*4:(y+1)*out_stride]), [99]*8)
        return [[target[y*out_stride+x*4+3] for x in range(width)] for y in range(height)]

    def test_flat_field_has_no_peaking(self):
        self.assertFalse(any(map(any, self.overlay([[127]*9 for _ in range(7)]))))

    def test_sharp_edge_exceeds_blurred_edge(self):
        sharp = self.overlay([[0]*4+[255]*5 for _ in range(7)])
        blurred = self.overlay([[0, 20, 50, 80, 110, 140, 170, 200, 230] for _ in range(7)])
        self.assertGreater(sum(map(sum, sharp)), sum(map(sum, blurred)))
        self.assertTrue(all(sharp[y][3] and sharp[y][4] for y in range(1, 6)))
        self.assertFalse(any(sharp[0]) or any(sharp[-1]))

    def test_invalid_peaking_does_not_write(self):
        source = (C.c_uint8 * 9)()
        target = (C.c_uint8 * 36)(*([99]*36))
        self.assertFalse(self.api.m7_peaking(source, 3, 3, 2, target, 12, .3))
        self.assertEqual(list(target), [99]*36)


if __name__ == '__main__':
    unittest.main()
