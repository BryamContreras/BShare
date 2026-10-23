#!/usr/bin/env python3
"""Detect stretch in PNG captures of screen_share_fixture.html.

Requires Pillow. Measures four known colored circle components and emits JSON.
A phone reference also checks the circle layout, exposing a stale portrait frame
after the phone switches to landscape. Equal layouts do not prove frame freshness.
"""

import argparse
import json
import math
import sys

from PIL import Image, ImageChops


COLORS = {
    "magenta": ((170, 255), (0, 105), (170, 255)),
    "cyan": ((0, 100), (150, 255), (170, 255)),
    "lime": ((0, 140), (170, 255), (0, 120)),
    "orange": ((180, 255), (80, 210), (0, 90)),
}


def largest_component(mask):
    width, height = mask.size
    pixels = bytearray(mask.tobytes())
    largest = None
    for start in range(len(pixels)):
        if not pixels[start]:
            continue
        pixels[start] = 0
        stack = [start]
        count = 0
        min_x = max_x = start % width
        min_y = max_y = start // width
        while stack:
            index = stack.pop()
            x, y = index % width, index // width
            count += 1
            min_x, max_x = min(min_x, x), max(max_x, x)
            min_y, max_y = min(min_y, y), max(max_y, y)
            for neighbor in (
                index - 1 if x else -1,
                index + 1 if x + 1 < width else -1,
                index - width if y else -1,
                index + width if y + 1 < height else -1,
            ):
                if neighbor >= 0 and pixels[neighbor]:
                    pixels[neighbor] = 0
                    stack.append(neighbor)
        if largest is None or count > largest["pixels"]:
            box_width, box_height = max_x - min_x + 1, max_y - min_y + 1
            largest = {
                "pixels": count,
                "bounds": [min_x, min_y, max_x + 1, max_y + 1],
                "width": box_width,
                "height": box_height,
                "ratio": box_width / box_height,
                "center": [(min_x + max_x) / 2, (min_y + max_y) / 2],
                "fillFraction": count / (box_width * box_height),
                "touchesImageEdge": min_x == 0 or min_y == 0
                or max_x + 1 == width or max_y + 1 == height,
            }
    return largest


def measure(path, maximum_size):
    with Image.open(path) as original:
        image = original.convert("RGB")
    original_size = list(image.size)
    image.thumbnail((maximum_size, maximum_size), Image.Resampling.NEAREST)
    channels = image.split()
    circles = {}
    for name, ranges in COLORS.items():
        masks = [
            channel.point([255 if low <= v <= high else 0 for v in range(256)])
            for channel, (low, high) in zip(channels, ranges)
        ]
        mask = ImageChops.multiply(ImageChops.multiply(masks[0], masks[1]), masks[2])
        candidate = largest_component(mask)
        if candidate and (
            candidate["pixels"] < 100
            or min(candidate["width"], candidate["height"]) < 12
            or not 0.55 <= candidate["fillFraction"] <= 0.90
        ):
            candidate = None
        circles[name] = candidate
    return {"image": str(path), "originalSize": original_size,
            "analyzedSize": list(image.size), "circles": circles}


def compare_layout(report, reference, tolerance):
    pairs = {
        "x": [("magenta", "cyan"), ("lime", "orange")],
        "y": [("magenta", "lime"), ("cyan", "orange")],
    }
    samples = {"x": [], "y": []}
    for axis, names in pairs.items():
        index = 0 if axis == "x" else 1
        for first, second in names:
            current = [report["circles"][name] for name in (first, second)]
            original = [reference["circles"][name] for name in (first, second)]
            if any(circle is None for circle in current + original):
                continue
            source_delta = original[1]["center"][index] - original[0]["center"][index]
            target_delta = current[1]["center"][index] - current[0]["center"][index]
            if abs(source_delta) < 5:
                continue
            samples[axis].append({
                "colors": [first, second],
                "referenceDistance": source_delta,
                "imageDistance": target_delta,
                "scale": target_delta / source_delta,
            })
    result = {"axisPairs": samples, "passed": False,
              "temporalFreshnessVerified": False}
    if not samples["x"] or not samples["y"]:
        result["reason"] = "insufficient-circle-pairs"
        return result
    scales = {axis: sum(s["scale"] for s in rows) / len(rows)
              for axis, rows in samples.items()}
    result.update({"scaleX": scales["x"], "scaleY": scales["y"]})
    if any(s["scale"] <= 0 for rows in samples.values() for s in rows):
        result["reason"] = "incompatible-circle-orientation"
        return result
    mismatch = max(scales["x"] / scales["y"], scales["y"] / scales["x"]) - 1
    consistency = max(
        max(sample["scale"] / scales[axis], scales[axis] / sample["scale"]) - 1
        for axis, rows in samples.items() for sample in rows
    )
    cross_axis_error = 0
    for axis, rows in samples.items():
        other = "y" if axis == "x" else "x"
        index = 1 if axis == "x" else 0
        for sample in rows:
            first, second = sample["colors"]
            expected = (reference["circles"][second]["center"][index]
                        - reference["circles"][first]["center"][index]) * scales[other]
            actual = (report["circles"][second]["center"][index]
                      - report["circles"][first]["center"][index])
            cross_axis_error = max(cross_axis_error,
                                   abs(actual - expected) / max(abs(sample["imageDistance"]), 1))
    result.update({
        "scaleMismatchFraction": mismatch,
        "axisConsistencyErrorFraction": consistency,
        "crossAxisErrorFraction": cross_axis_error,
        "passed": max(mismatch, consistency, cross_axis_error) <= tolerance,
        "reason": "matching-layout" if max(mismatch, consistency, cross_axis_error) <= tolerance
        else "incompatible-layout-or-stale-orientation",
    })
    return result


def assess(report, reference=None, tolerance=0.04, minimum_circles=3):
    verified = 0
    valid = True
    for name, circle in report["circles"].items():
        if circle is None:
            continue
        reference_circle = reference["circles"][name] if reference else None
        if reference and reference_circle is None:
            circle["comparison"] = "missing-reference-circle"
            valid = False
            continue
        expected = reference_circle["ratio"] if reference_circle else 1.0
        relative = circle["ratio"] / expected
        # Symmetric tolerance: a 1.25 ratio and its reciprocal are equally bad.
        stretch = math.exp(abs(math.log(relative))) - 1
        circle["relativeRatio"] = relative
        circle["stretchFraction"] = stretch
        circle["passed"] = stretch <= tolerance and not circle["touchesImageEdge"]
        verified += 1
        valid = valid and circle["passed"]
    shapes_passed = valid and verified >= minimum_circles
    layout = compare_layout(report, reference, tolerance) if reference else None
    report.update({"reference": reference, "tolerance": tolerance,
                   "verifiedCircles": verified, "shapesPassed": shapes_passed,
                   "referenceLayout": layout,
                   "passed": shapes_passed and (layout is None or layout["passed"])})
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", help="PNG from phone or desktop viewer")
    parser.add_argument("--reference", help="Phone PNG for relative shape and layout checks")
    parser.add_argument("--tolerance", type=float, default=0.04,
                        help="Allowed proportional stretch (default: 0.04)")
    parser.add_argument("--min-circles", type=int, default=3)
    parser.add_argument("--max-size", type=int, default=1600)
    args = parser.parse_args()
    if not 0 < args.tolerance < 1 or not 1 <= args.min_circles <= 4:
        parser.error("tolerance must be between 0 and 1, min-circles between 1 and 4")
    if args.max_size < 100:
        parser.error("max-size must be at least 100")
    report = measure(args.image, args.max_size)
    reference = measure(args.reference, args.max_size) if args.reference else None
    assess(report, reference, args.tolerance, args.min_circles)
    print(json.dumps(report, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
