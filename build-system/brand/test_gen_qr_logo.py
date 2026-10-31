#!/usr/bin/env python3
"""Fixture test for the QR-centre plane generator. Stdlib only; no network and no clock.

The geometry tests parse the assets that build_assets() produces and compare every pulse vertex with
a literal computed by hand from the mapping in gen_qr_logo's docstring. The literals do not call the
generator's helpers, so a wrong mapping in the generator fails here.
"""

import gzip
import json
import os
import re
import sys
import tempfile
import unittest
from typing import Any, Dict, List, Tuple


# -I drops the script directory from sys.path, so it is added here explicitly.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import gen_qr_logo  # noqa: E402


# Pulse vertices of PlaneLogoPlain.tgs, a centred box of side 0.85 * 512 = 435.2 at (38.4, 38.4).
# Scale 435.2 / 200 = 2.176, so x = 38.4 + 2.176 * ax and y = 38.4 + 2.176 * ay. Stroke 14 * 2.176 = 30.464.
PLAIN_VERTICES: List[List[float]] = [
    [86.272, 256.0],
    [177.664, 256.0],
    [199.424, 256.0],
    [221.184, 190.72],
    [251.648, 356.096],
    [282.112, 134.144],
    [312.576, 256.0],
    [334.336, 256.0],
    [425.728, 256.0],
]
PLAIN_STROKE: float = 30.464

# Pulse vertices of PlaneLogo.tgs, the disc's box: left 256.289 - 207 = 49.289, top 261.051 - 207 = 54.051,
# side 414, scale 414 / 200 = 2.07. Stroke 14 * 2.07 = 28.98.
DISC_VERTICES: List[List[float]] = [
    [94.829, 261.051],
    [181.769, 261.051],
    [202.469, 261.051],
    [223.169, 198.951],
    [252.149, 356.271],
    [281.129, 145.131],
    [310.109, 261.051],
    [330.809, 261.051],
    [417.749, 261.051],
]
DISC_STROKE: float = 28.98

# Pulse path of QrLogo.pdf: box left 36 - 30 = 6, scale 60 / 200 = 0.3, page y = 72 - (6 + 0.3 * ay) = 66 - 0.3 * ay.
# Stroke 14 * 0.3 = 4.2.
QR_LOGO_SEGMENTS: List[Tuple[str, float, float]] = [
    ("m", 12.6, 36.0),
    ("l", 25.2, 36.0),
    ("l", 28.2, 36.0),
    ("l", 31.2, 45.0),
    ("l", 35.4, 22.2),
    ("l", 39.6, 52.8),
    ("l", 43.8, 36.0),
    ("l", 46.8, 36.0),
    ("l", 59.4, 36.0),
]
QR_LOGO_STROKE: str = "4.2 w"

# Pulse path of QrPlaneIcon.pdf: box side 72 * 0.85 = 61.2, left 36 - 30.6 = 5.4, scale 61.2 / 200 = 0.306,
# page y = 72 - (5.4 + 0.306 * ay) = 66.6 - 0.306 * ay. Stroke 14 * 0.306 = 4.284.
PLANE_SEGMENTS: List[Tuple[str, float, float]] = [
    ("m", 12.132, 36.0),
    ("l", 24.984, 36.0),
    ("l", 28.044, 36.0),
    ("l", 31.104, 45.18),
    ("l", 35.388, 21.924),
    ("l", 39.672, 53.136),
    ("l", 43.956, 36.0),
    ("l", 47.016, 36.0),
    ("l", 59.868, 36.0),
]
PLANE_STROKE: str = "4.284 w"

# #2085DF: 32 / 255, 133 / 255 and 223 / 255, rounded to 8 places.
DISC_RGB_LOTTIE: List[float] = [0.12549020, 0.52156863, 0.87450980]
DISC_RGB_PDF: str = "0.1255 0.5216 0.8745 rg"

VERTEX_PLACES: int = 4


def load_tgs(data: bytes) -> Dict[str, Any]:
    return json.loads(gzip.decompress(data).decode("ascii"))


def layer_named(document: Dict[str, Any], name: str) -> Dict[str, Any]:
    matches: List[Dict[str, Any]] = [layer for layer in document["layers"] if layer["nm"] == name]

    if len(matches) != 1:
        raise AssertionError(f"expected one layer named {name}, found {len(matches)}")

    return matches[0]


def pulse_vertices(layer: Dict[str, Any]) -> List[List[float]]:
    shape: Dict[str, Any] = layer["shapes"][0]["it"][0]

    return shape["ks"]["k"]["v"]


def pdf_xref_offsets(data: bytes) -> List[Tuple[int, int]]:
    match: Any = re.search(rb"xref\n0 (\d+)\n0000000000 65535 f \n", data)
    count: int = int(match.group(1))
    body: bytes = data[match.end():match.end() + 20 * (count - 1)]
    entries: List[Tuple[int, int]] = []

    for index in range(count - 1):
        chunk: bytes = body[index * 20:(index + 1) * 20]
        entries.append((index + 1, int(chunk[:10])))

    return entries


def pdf_content_lines(data: bytes) -> List[str]:
    match: Any = re.search(rb"stream\n(.*?)\nendstream", data, re.DOTALL)

    return match.group(1).decode("ascii").split("\n")


def pdf_pulse_segments(data: bytes) -> List[Tuple[str, float, float]]:
    # The pulse is the run of m/l lines directly before its stroke operator.
    lines: List[str] = pdf_content_lines(data)
    index: int = lines.index("S") - 1
    segments: List[Tuple[str, float, float]] = []

    while index >= 0 and re.fullmatch(r"-?[\d.]+ -?[\d.]+ [ml]", lines[index]):
        parts: List[str] = lines[index].split(" ")
        segments.append((parts[2], float(parts[0]), float(parts[1])))
        index -= 1

    segments.reverse()

    return segments


def assert_vertices_equal(test: unittest.TestCase, actual: List[List[float]], expected: List[List[float]]) -> None:
    test.assertEqual(len(actual), len(expected))

    for (ax, ay), (ex, ey) in zip(actual, expected):
        test.assertAlmostEqual(ax, ex, places=VERTEX_PLACES)
        test.assertAlmostEqual(ay, ey, places=VERTEX_PLACES)


def assert_segments_equal(
    test: unittest.TestCase,
    actual: List[Tuple[str, float, float]],
    expected: List[Tuple[str, float, float]]
) -> None:
    test.assertEqual(len(actual), len(expected))

    for (aop, ax, ay), (eop, ex, ey) in zip(actual, expected):
        test.assertEqual(aop, eop)
        test.assertAlmostEqual(ax, ex, places=VERTEX_PLACES)
        test.assertAlmostEqual(ay, ey, places=VERTEX_PLACES)


class AndroidMappingTest(unittest.TestCase):

    def test_android_box_corners_map_onto_the_box(self) -> None:
        points: List[Tuple[float, float]] = gen_qr_logo.android_to_box(10.0, 20.0, 200.0)

        self.assertEqual(points[0], (32.0, 120.0))
        self.assertEqual(points[-1], (188.0, 120.0))

    def test_stroke_scales_with_the_box(self) -> None:
        self.assertAlmostEqual(gen_qr_logo.android_stroke(200.0), 14.0)
        self.assertAlmostEqual(gen_qr_logo.android_stroke(60.0), 4.2)

    def test_pulse_has_the_nine_android_vertices(self) -> None:
        self.assertEqual(len(gen_qr_logo.ANDROID_PULSE), 9)
        self.assertEqual(gen_qr_logo.ANDROID_PULSE[4], (98.0, 146.0))

    def test_disc_colour_is_android_qr_logo_blue(self) -> None:
        self.assertEqual(gen_qr_logo.DISC_COLOUR, (32, 133, 223))


class HostBoxTest(unittest.TestCase):

    def test_host_box_is_a_centred_square_of_085_of_the_canvas(self) -> None:
        # 512 * 0.85 = 435.2 and (512 - 435.2) / 2 = 38.4.
        left: float
        top: float
        size: float
        left, top, size = gen_qr_logo.host_box(512.0)

        self.assertAlmostEqual(left, 38.4, places=9)
        self.assertAlmostEqual(top, 38.4, places=9)
        self.assertAlmostEqual(size, 435.2, places=9)


class TgsDiscGeometryTest(unittest.TestCase):

    def test_disc_centre_matches_the_original_layer(self) -> None:
        # Layer origin 256, ellipse centre offset (2, 6), group shift (-1.711, -0.949).
        # Centre: 256 + 2 - 1.711 = 256.289 and 256 + 6 - 0.949 = 261.051.
        left: float
        top: float
        size: float
        left, top, size = gen_qr_logo.tgs_disc_box()

        self.assertAlmostEqual(left + size / 2.0, 256.289, places=6)
        self.assertAlmostEqual(top + size / 2.0, 261.051, places=6)
        self.assertEqual(size, 414.0)

    def test_disc_layer_is_a_flat_android_blue_fill(self) -> None:
        document: Dict[str, Any] = load_tgs(gen_qr_logo.build_assets()[gen_qr_logo.DISC_TGS_PATH])
        disc: Dict[str, Any] = layer_named(document, "Shape Layer 17")
        items: List[Dict[str, Any]] = disc["shapes"][0]["it"]

        self.assertEqual([item["ty"] for item in items], ["el", "st", "fl", "tr"])
        self.assertEqual(items[2]["c"]["a"], 0)
        self.assertEqual(len(items[2]["c"]["k"]), 4)

        for actual, expected in zip(items[2]["c"]["k"][:3], DISC_RGB_LOTTIE):
            self.assertAlmostEqual(actual, expected, places=7)
        self.assertEqual(items[2]["c"]["k"][3], 1.0)

    def test_disc_layer_geometry_matches_the_original(self) -> None:
        document: Dict[str, Any] = load_tgs(gen_qr_logo.build_assets()[gen_qr_logo.DISC_TGS_PATH])
        disc: Dict[str, Any] = layer_named(document, "Shape Layer 17")
        items: List[Dict[str, Any]] = disc["shapes"][0]["it"]

        self.assertEqual(disc["ks"]["p"]["k"], [256, 256, 0])
        self.assertEqual(items[0]["s"]["k"], [414.0, 414.0])
        self.assertEqual(items[0]["p"]["k"], [2.0, 6.0])
        self.assertEqual(items[3]["p"]["k"], [-1.711, -0.949])


class TgsDocumentTest(unittest.TestCase):

    def test_plain_file_has_one_static_pulse_layer(self) -> None:
        document: Dict[str, Any] = load_tgs(gen_qr_logo.build_assets()[gen_qr_logo.PLAIN_TGS_PATH])

        self.assertEqual(document["w"], 512)
        self.assertEqual(document["h"], 512)
        self.assertEqual(document["fr"], 60)
        self.assertEqual(document["ip"], 20)
        self.assertEqual(document["op"], 74)
        self.assertEqual(len(document["layers"]), 1)

        layer: Dict[str, Any] = document["layers"][0]
        shape_path: Dict[str, Any] = layer["shapes"][0]["it"][0]["ks"]["k"]
        stroke: Dict[str, Any] = layer["shapes"][0]["it"][1]

        self.assertEqual(layer["ty"], 4)
        self.assertEqual(layer["ks"]["p"]["a"], 0)
        self.assertFalse(shape_path["c"])
        self.assertEqual(stroke["lc"], 2)
        self.assertEqual(stroke["lj"], 2)
        self.assertEqual(stroke["c"]["k"], [1, 1, 1, 1])
        self.assertEqual(stroke["w"]["a"], 0)
        self.assertAlmostEqual(stroke["w"]["k"], PLAIN_STROKE, places=VERTEX_PLACES)
        self.assertEqual(len(shape_path["v"]), 9)
        self.assertEqual(shape_path["i"], [[0, 0]] * 9)
        self.assertEqual(shape_path["o"], [[0, 0]] * 9)

    def test_plain_pulse_vertices_are_centred_on_the_canvas(self) -> None:
        document: Dict[str, Any] = load_tgs(gen_qr_logo.build_assets()[gen_qr_logo.PLAIN_TGS_PATH])

        assert_vertices_equal(self, pulse_vertices(document["layers"][0]), PLAIN_VERTICES)

    def test_disc_file_pulse_vertices_follow_the_disc_box(self) -> None:
        document: Dict[str, Any] = load_tgs(gen_qr_logo.build_assets()[gen_qr_logo.DISC_TGS_PATH])
        pulse: Dict[str, Any] = layer_named(document, "Pulse")

        assert_vertices_equal(self, pulse_vertices(pulse), DISC_VERTICES)
        self.assertAlmostEqual(pulse["shapes"][0]["it"][1]["w"]["k"], DISC_STROKE, places=VERTEX_PLACES)

    def test_disc_file_stacks_pulse_above_disc(self) -> None:
        document: Dict[str, Any] = load_tgs(gen_qr_logo.build_assets()[gen_qr_logo.DISC_TGS_PATH])

        self.assertEqual([layer["nm"] for layer in document["layers"]], ["Pulse", "Shape Layer 17"])

    def test_tgs_bytes_are_deterministic_gzip(self) -> None:
        first: bytes = gen_qr_logo.tgs_bytes([gen_qr_logo.tgs_pulse_layer(1, gen_qr_logo.host_box(512.0))])
        second: bytes = gen_qr_logo.tgs_bytes([gen_qr_logo.tgs_pulse_layer(1, gen_qr_logo.host_box(512.0))])

        self.assertEqual(first, second)
        self.assertEqual(first[:2], b"\x1f\x8b")
        self.assertEqual(first[4:8], b"\x00\x00\x00\x00")


class PdfTest(unittest.TestCase):

    def test_qr_logo_pulse_follows_the_disc_box(self) -> None:
        data: bytes = gen_qr_logo.build_assets()[gen_qr_logo.QR_LOGO_PDF_PATH]

        self.assertTrue(data.startswith(b"%PDF-1.4"))
        self.assertIn(b"/MediaBox [0 0 72 72]", data)
        assert_segments_equal(self, pdf_pulse_segments(data), QR_LOGO_SEGMENTS)
        self.assertIn(QR_LOGO_STROKE, pdf_content_lines(data))
        self.assertIn("1 1 1 RG", pdf_content_lines(data))
        self.assertIn("1 J", pdf_content_lines(data))
        self.assertIn("1 j", pdf_content_lines(data))

    def test_qr_logo_disc_is_a_flat_android_blue_fill(self) -> None:
        lines: List[str] = pdf_content_lines(gen_qr_logo.build_assets()[gen_qr_logo.QR_LOGO_PDF_PATH])

        # The circle starts at (36 + 30, 36) = (66, 36); the fill operator closes it.
        self.assertIn(DISC_RGB_PDF, lines)
        self.assertEqual(lines[lines.index(DISC_RGB_PDF) + 1], "66 36 m")
        # Path: m, four c segments, h, then f.
        self.assertEqual(lines[lines.index(DISC_RGB_PDF) + 1 + 5], "h")
        self.assertEqual(lines[lines.index(DISC_RGB_PDF) + 1 + 6], "f")
        self.assertNotIn("sh", lines)

    def test_qr_logo_has_no_shading_resources(self) -> None:
        data: bytes = gen_qr_logo.build_assets()[gen_qr_logo.QR_LOGO_PDF_PATH]

        self.assertNotIn(b"/Shading", data)
        self.assertNotIn(b"/FunctionType", data)

    def test_plane_icon_pulse_is_centred_on_the_page(self) -> None:
        data: bytes = gen_qr_logo.build_assets()[gen_qr_logo.QR_PLANE_PDF_PATH]

        self.assertTrue(data.startswith(b"%PDF-1.4"))
        self.assertIn(b"/MediaBox [0 0 72 72]", data)
        assert_segments_equal(self, pdf_pulse_segments(data), PLANE_SEGMENTS)
        self.assertIn(PLANE_STROKE, pdf_content_lines(data))

    def test_plane_icon_has_no_disc_or_shading(self) -> None:
        data: bytes = gen_qr_logo.build_assets()[gen_qr_logo.QR_PLANE_PDF_PATH]
        lines: List[str] = pdf_content_lines(data)

        self.assertNotIn(DISC_RGB_PDF, lines)
        self.assertNotIn("f", lines)
        self.assertNotIn(b"/Shading", data)
        self.assertIn("1 1 1 RG", lines)

    def test_xref_offsets_point_at_their_objects(self) -> None:
        for data in (gen_qr_logo.qr_logo_pdf(), gen_qr_logo.qr_plane_icon_pdf()):
            for number, offset in pdf_xref_offsets(data):
                self.assertTrue(
                    data[offset:].startswith(f"{number} 0 obj".encode("ascii")),
                    f"object {number} is not at offset {offset}"
                )

    def test_pdf_is_deterministic(self) -> None:
        self.assertEqual(gen_qr_logo.qr_logo_pdf(), gen_qr_logo.qr_logo_pdf())
        self.assertEqual(gen_qr_logo.qr_plane_icon_pdf(), gen_qr_logo.qr_plane_icon_pdf())


class WriteAssetsTest(unittest.TestCase):

    def test_writes_four_assets_and_reruns_are_byte_identical(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            first: Dict[str, bytes] = gen_qr_logo.build_assets()

            for relative in first:
                os.makedirs(os.path.dirname(os.path.join(root, *relative.split("/"))), exist_ok=True)

            gen_qr_logo.write_assets(root, first)

            second: Dict[str, bytes] = gen_qr_logo.build_assets()
            written: List[str] = gen_qr_logo.write_assets(root, second)

            self.assertEqual(len(written), 4)
            self.assertEqual(first, second)

            for relative, data in second.items():
                with open(os.path.join(root, *relative.split("/")), "rb") as handle:
                    self.assertEqual(handle.read(), data)


if __name__ == "__main__":
    unittest.main()
