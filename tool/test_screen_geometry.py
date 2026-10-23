#!/usr/bin/env python3
"""Synthetic regression checks for the screenshot geometry helper."""

import sys
import tempfile
import unittest
from pathlib import Path

from PIL import Image, ImageDraw

sys.dont_write_bytecode = True
from analyze_screen_geometry import assess, measure  # noqa: E402


def fixture(size):
    image = Image.new("RGB", size, "#0b1220")
    draw = ImageDraw.Draw(image)
    width, height = size
    radius = min(size) * 0.145
    for x, y, color in [(.25, .32, "#ff00ff"), (.75, .32, "#00e5ff"),
                         (.25, .70, "#4cff28"), (.75, .70, "#ff9a00")]:
        cx, cy = width * x, height * y
        draw.ellipse((cx - radius, cy - radius, cx + radius, cy + radius), fill=color)
    return image


class ScreenGeometryTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="bshare-geometry-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def measured(self, image, name):
        path = self.root / (name + ".png")
        image.save(path)
        return measure(path, 1600)

    def test_round_shape_and_uniformly_scaled_layout_match(self):
        reference = self.measured(fixture((400, 800)), "reference")
        image = self.measured(fixture((400, 800)).resize((200, 400)), "scaled")
        result = assess(image, reference)
        self.assertTrue(result["passed"])
        self.assertTrue(result["referenceLayout"]["passed"])

    def test_stretch_is_rejected(self):
        result = assess(self.measured(fixture((400, 800)).resize((600, 800)), "stretch"))
        self.assertFalse(result["shapesPassed"])
        self.assertFalse(result["passed"])

    def test_old_portrait_round_frame_fails_new_landscape_reference(self):
        reference = self.measured(fixture((800, 400)), "landscape")
        old_frame = self.measured(fixture((400, 800)), "old-portrait")
        result = assess(old_frame, reference)
        self.assertTrue(result["shapesPassed"])
        self.assertFalse(result["referenceLayout"]["passed"])
        self.assertFalse(result["passed"])
        self.assertGreater(result["referenceLayout"]["scaleMismatchFraction"], 2)

    def test_current_landscape_layout_passes(self):
        reference = self.measured(fixture((800, 400)), "landscape")
        image = self.measured(fixture((800, 400)).resize((600, 300)), "viewer")
        result = assess(image, reference)
        self.assertTrue(result["passed"])
        self.assertFalse(result["referenceLayout"]["temporalFreshnessVerified"])

    def test_missing_fixture_is_rejected(self):
        result = assess(self.measured(Image.new("RGB", (500, 500), "white"), "empty"))
        self.assertEqual(result["verifiedCircles"], 0)
        self.assertFalse(result["passed"])


if __name__ == "__main__":
    unittest.main()
