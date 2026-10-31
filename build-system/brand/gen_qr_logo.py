#!/usr/bin/env python3
"""Generates the plane artwork drawn at the centre of QR codes in the ImpulseM iOS client.

The centre mark is the ImpulseM pulse, taken from the Android source ic_impulsem_logo_plain.xml: a
white stroke of 14 units with round caps and joins, in a 200 x 200 box. Android qr_logo.svg puts it on
a flat #2085DF disc, and the iOS disc uses the same colour.

The 200 box is mapped by a uniform scale k, and the stroke is scaled by k as well:
- PlaneLogo.tgs and QrLogo.pdf draw their own disc, so the box is the disc's bounding box.
  PlaneLogo.tgs: the disc is 414 px wide, centred at (256.289, 261.051) in the 512 px canvas.
  QrLogo.pdf: the disc has radius 30, centred at (36, 36) on the 72 pt page.
- PlaneLogoPlain.tgs and QrPlaneIcon.pdf are drawn over a disc that the host draws itself. The host
  disc has diameter D inside a canvas of D + 8, so it spans HOST_DISC_FRACTION (0.85) of the canvas.
  The box is therefore a centred square of side 0.85 x canvas, centred on the canvas centre:
  (256, 256) in the 512 px Lottie, and (36, 36) on the 72 pt page.
- The PDF page runs upwards and the Android and Lottie coordinates run downwards, so PDF y is 72 - y.

Stdlib only. Output is byte-identical across runs: gzip uses mtime 0 and the PDFs carry no dates.

Modes:
  gen_qr_logo.py [--root DIR]   write the four assets under DIR (default: the iOS tree)
"""

import argparse
import gzip
import json
import os
import sys
from typing import Any, Dict, List, Optional, Sequence, Tuple


PLAIN_TGS_PATH: str = "Telegram/Telegram-iOS/Resources/PlaneLogoPlain.tgs"
DISC_TGS_PATH: str = "Telegram/Telegram-iOS/Resources/PlaneLogo.tgs"
QR_LOGO_PDF_PATH: str = "submodules/TelegramUI/Images.xcassets/Chat/Links/QrLogo.imageset/ic_qrlogo.pdf"
QR_PLANE_PDF_PATH: str = "submodules/TelegramUI/Images.xcassets/Share/QrPlaneIcon.imageset/ic_qrlogo.pdf"

# Android ic_impulsem_logo_plain.xml, drawn in its 200 x 200 viewport.
ANDROID_BOX: float = 200.0
ANDROID_STROKE: float = 14.0
ANDROID_PULSE: List[Tuple[float, float]] = [
    (22.0, 100.0),
    (64.0, 100.0),
    (74.0, 100.0),
    (84.0, 70.0),
    (98.0, 146.0),
    (112.0, 44.0),
    (126.0, 100.0),
    (136.0, 100.0),
    (178.0, 100.0),
]

# Android qr_logo.svg disc colour #2085DF, used by every disc in the iOS assets.
DISC_COLOUR: Tuple[int, int, int] = (32, 133, 223)

# Hosts draw a disc of diameter D inside a canvas of D + 8, so the disc spans 0.85 of the canvas.
HOST_DISC_FRACTION: float = 0.85

# PlaneLogo.tgs root values, copied from the original file.
TGS_FRAME_RATE: int = 60
TGS_IN_POINT: int = 20
TGS_OUT_POINT: int = 74
TGS_SIZE: int = 512
TGS_VERSION: str = "5.5.2"
TGS_LAYER_BOUNDS: int = 180

# Original "Shape Layer 17" of PlaneLogo.tgs, the disc: a 414 px ellipse centred at (2, 6) inside a
# group moved by (-1.711, -0.949), in a layer placed at (256, 256) of the 512 box. The centre is
# therefore (256 + 2 - 1.711, 256 + 6 - 0.949) = (256.289, 261.051), and the box is 414 px wide.
TGS_DISC_LAYER_ORIGIN: Tuple[float, float] = (256.0, 256.0)
TGS_DISC_ELLIPSE_CENTRE: Tuple[float, float] = (2.0, 6.0)
TGS_DISC_GROUP_SHIFT: Tuple[float, float] = (-1.711, -0.949)
TGS_DISC_DIAMETER: float = 414.0

# QrLogo.pdf and QrPlaneIcon.pdf share a 72 pt page.
PDF_PAGE_SIZE: float = 72.0
# QrLogo.pdf disc: a circle centred at (36, 36) with radius 30 on the 72 pt page.
PDF_DISC_CENTRE: Tuple[float, float] = (36.0, 36.0)
PDF_DISC_RADIUS: float = 30.0
KAPPA: float = 0.5522847498


def fmt(value: float) -> str:
    text: str = f"{value:.4f}".rstrip("0").rstrip(".")

    if text in ("-0", ""):
        return "0"

    return text


def android_to_box(
    box_left: float,
    box_top: float,
    box_size: float
) -> List[Tuple[float, float]]:
    scale: float = box_size / ANDROID_BOX

    return [(box_left + x * scale, box_top + y * scale) for x, y in ANDROID_PULSE]


def android_stroke(box_size: float) -> float:
    return ANDROID_STROKE * box_size / ANDROID_BOX


def circle_box(centre: Tuple[float, float], radius: float) -> Tuple[float, float, float]:
    return centre[0] - radius, centre[1] - radius, radius * 2.0


def host_box(canvas: float) -> Tuple[float, float, float]:
    side: float = canvas * HOST_DISC_FRACTION
    offset: float = (canvas - side) / 2.0

    return offset, offset, side


def tgs_disc_box() -> Tuple[float, float, float]:
    centre_x: float = TGS_DISC_LAYER_ORIGIN[0] + TGS_DISC_ELLIPSE_CENTRE[0] + TGS_DISC_GROUP_SHIFT[0]
    centre_y: float = TGS_DISC_LAYER_ORIGIN[1] + TGS_DISC_ELLIPSE_CENTRE[1] + TGS_DISC_GROUP_SHIFT[1]
    half: float = TGS_DISC_DIAMETER / 2.0

    return centre_x - half, centre_y - half, TGS_DISC_DIAMETER


def lottie_colour(colour: Tuple[int, int, int]) -> List[float]:
    return [channel / 255.0 for channel in colour] + [1.0]


def tgs_pulse_layer(index: int, box: Tuple[float, float, float]) -> Dict[str, Any]:
    left: float
    top: float
    size: float
    left, top, size = box
    vertices: List[List[float]] = [[round(x, 4), round(y, 4)] for x, y in android_to_box(left, top, size)]
    tangents: List[List[int]] = [[0, 0] for _ in vertices]

    return {
        "ddd": 0,
        "ind": index,
        "ty": 4,
        "nm": "Pulse",
        "sr": 1,
        "st": 0,
        "ao": 0,
        "bm": 0,
        "ip": 0,
        "op": TGS_LAYER_BOUNDS,
        "ks": {
            "o": {"a": 0, "k": 100},
            "r": {"a": 0, "k": 0},
            "p": {"a": 0, "k": [0, 0, 0]},
            "a": {"a": 0, "k": [0, 0, 0]},
            "s": {"a": 0, "k": [100, 100, 100]}
        },
        "shapes": [
            {
                "ty": "gr",
                "it": [
                    {
                        "ind": 0,
                        "ty": "sh",
                        "ks": {
                            "a": 0,
                            "k": {"i": tangents, "o": tangents, "v": vertices, "c": False}
                        },
                        "nm": "Pulse Path",
                        "hd": False
                    },
                    {
                        "ty": "st",
                        "c": {"a": 0, "k": [1, 1, 1, 1]},
                        "o": {"a": 0, "k": 100},
                        "w": {"a": 0, "k": round(android_stroke(size), 4)},
                        "lc": 2,
                        "lj": 2,
                        "ml": 4,
                        "bm": 0,
                        "nm": "Pulse Stroke",
                        "hd": False
                    },
                    {
                        "ty": "tr",
                        "p": {"a": 0, "k": [0, 0]},
                        "a": {"a": 0, "k": [0, 0]},
                        "s": {"a": 0, "k": [100, 100]},
                        "r": {"a": 0, "k": 0},
                        "o": {"a": 0, "k": 100},
                        "sk": {"a": 0, "k": 0},
                        "sa": {"a": 0, "k": 0},
                        "nm": "Transform"
                    }
                ],
                "nm": "Pulse",
                "bm": 0,
                "hd": False
            }
        ]
    }


def tgs_disc_layer(index: int) -> Dict[str, Any]:
    centre_x: float = TGS_DISC_ELLIPSE_CENTRE[0]
    centre_y: float = TGS_DISC_ELLIPSE_CENTRE[1]

    return {
        "ddd": 0,
        "ind": index,
        "ty": 4,
        "nm": "Shape Layer 17",
        "sr": 1,
        "st": 0,
        "ao": 0,
        "bm": 0,
        "ip": 0,
        "op": TGS_LAYER_BOUNDS,
        "ks": {
            "p": {"a": 0, "k": [TGS_DISC_LAYER_ORIGIN[0], TGS_DISC_LAYER_ORIGIN[1], 0]}
        },
        "shapes": [
            {
                "ty": "gr",
                "it": [
                    {
                        "d": 1,
                        "ty": "el",
                        "s": {"a": 0, "k": [TGS_DISC_DIAMETER, TGS_DISC_DIAMETER]},
                        "p": {"a": 0, "k": [centre_x, centre_y]},
                        "nm": "Ellipse Path 1",
                        "hd": False
                    },
                    {
                        "ty": "st",
                        "c": {"a": 0, "k": [1, 1, 1, 1]},
                        "o": {"a": 0, "k": 100},
                        "w": {"a": 0, "k": 0},
                        "lc": 1,
                        "lj": 1,
                        "ml": 4,
                        "bm": 0,
                        "nm": "Stroke 1",
                        "hd": False
                    },
                    {
                        "ty": "fl",
                        "o": {"a": 0, "k": 100},
                        "r": 1,
                        "bm": 0,
                        "c": {"a": 0, "k": lottie_colour(DISC_COLOUR)},
                        "nm": "Fill 1",
                        "hd": False
                    },
                    {
                        "ty": "tr",
                        "p": {"a": 0, "k": list(TGS_DISC_GROUP_SHIFT)},
                        "a": {"a": 0, "k": [0, 0]},
                        "s": {"a": 0, "k": [100, 100]},
                        "r": {"a": 0, "k": 0},
                        "o": {"a": 0, "k": 100},
                        "sk": {"a": 0, "k": 0},
                        "sa": {"a": 0, "k": 0},
                        "nm": "Transform"
                    }
                ],
                "nm": "Ellipse 1",
                "bm": 0,
                "hd": False
            }
        ]
    }


def tgs_bytes(layers: Sequence[Dict[str, Any]]) -> bytes:
    document: Dict[str, Any] = {
        "tgs": 1,
        "v": TGS_VERSION,
        "fr": TGS_FRAME_RATE,
        "ip": TGS_IN_POINT,
        "op": TGS_OUT_POINT,
        "w": TGS_SIZE,
        "h": TGS_SIZE,
        "nm": "4",
        "ddd": 0,
        "assets": [],
        "layers": list(layers)
    }
    raw: bytes = json.dumps(document, separators=(",", ":"), ensure_ascii=True).encode("ascii")

    return gzip.compress(raw, compresslevel=9, mtime=0)


def pdf_to_page(points: Sequence[Tuple[float, float]]) -> List[Tuple[float, float]]:
    # The Android and TGS coordinates run downwards; PDF user space runs upwards.
    return [(x, PDF_PAGE_SIZE - y) for x, y in points]


def pdf_path(points: Sequence[Tuple[float, float]]) -> str:
    segments: List[str] = []

    for index, (x, y) in enumerate(points):
        operator: str = "m" if index == 0 else "l"
        segments.append(f"{fmt(x)} {fmt(y)} {operator}")

    return "\n".join(segments)


def pdf_circle(centre: Tuple[float, float], radius: float) -> str:
    cx: float = centre[0]
    cy: float = centre[1]
    k: float = KAPPA * radius

    return "\n".join([
        f"{fmt(cx + radius)} {fmt(cy)} m",
        f"{fmt(cx + radius)} {fmt(cy + k)} {fmt(cx + k)} {fmt(cy + radius)} {fmt(cx)} {fmt(cy + radius)} c",
        f"{fmt(cx - k)} {fmt(cy + radius)} {fmt(cx - radius)} {fmt(cy + k)} {fmt(cx - radius)} {fmt(cy)} c",
        f"{fmt(cx - radius)} {fmt(cy - k)} {fmt(cx - k)} {fmt(cy - radius)} {fmt(cx)} {fmt(cy - radius)} c",
        f"{fmt(cx + k)} {fmt(cy - radius)} {fmt(cx + radius)} {fmt(cy - k)} {fmt(cx + radius)} {fmt(cy)} c",
        "h"
    ])


def pdf_stroke_pulse(box_left: float, box_top: float, box_size: float) -> str:
    points: List[Tuple[float, float]] = pdf_to_page(android_to_box(box_left, box_top, box_size))

    return "\n".join([
        "1 J",
        "1 j",
        "1 1 1 RG",
        f"{fmt(android_stroke(box_size))} w",
        pdf_path(points),
        "S"
    ])


def pdf_colour(colour: Tuple[int, int, int]) -> str:
    return " ".join(fmt(channel / 255.0) for channel in colour)


def pdf_document(content: str) -> bytes:
    bodies: List[str] = []
    stream: str = f"<< /Length {len(content.encode('ascii'))} >>\nstream\n{content}\nendstream"

    bodies.append("<< /Type /Catalog /Pages 2 0 R >>")
    bodies.append("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    bodies.append(
        f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {fmt(PDF_PAGE_SIZE)} {fmt(PDF_PAGE_SIZE)}] "
        "/Resources 4 0 R /Contents 5 0 R >>"
    )
    bodies.append("<< >>")
    bodies.append(stream)

    # The NUL in the binary marker makes git treat the file as binary, so autocrlf never rewrites it.
    out: bytearray = bytearray(b"%PDF-1.4\n%\x00\xe2\xe3\xcf\xd3\n")
    offsets: List[int] = []

    for number, body in enumerate(bodies, start=1):
        offsets.append(len(out))
        out += f"{number} 0 obj\n{body}\nendobj\n".encode("latin-1")

    count: int = len(bodies) + 1
    xref_position: int = len(out)
    out += f"xref\n0 {count}\n".encode("ascii")
    out += b"0000000000 65535 f \n"

    for offset in offsets:
        out += f"{offset:010d} 00000 n \n".encode("ascii")

    out += f"trailer\n<< /Size {count} /Root 1 0 R >>\nstartxref\n{xref_position}\n%%EOF\n".encode("ascii")

    return bytes(out)


def qr_logo_pdf() -> bytes:
    disc: Tuple[float, float, float] = circle_box(PDF_DISC_CENTRE, PDF_DISC_RADIUS)
    disc_left: float
    disc_top: float
    disc_size: float
    disc_left, disc_top, disc_size = disc
    content: str = "\n".join([
        "q",
        f"{pdf_colour(DISC_COLOUR)} rg",
        pdf_circle(PDF_DISC_CENTRE, PDF_DISC_RADIUS),
        "f",
        "Q",
        "q",
        pdf_stroke_pulse(disc_left, disc_top, disc_size),
        "Q",
        ""
    ])

    return pdf_document(content)


def qr_plane_icon_pdf() -> bytes:
    left: float
    top: float
    size: float
    left, top, size = host_box(PDF_PAGE_SIZE)
    content: str = "\n".join([
        "q",
        pdf_stroke_pulse(left, top, size),
        "Q",
        ""
    ])

    return pdf_document(content)


def build_assets() -> Dict[str, bytes]:
    return {
        PLAIN_TGS_PATH: tgs_bytes([tgs_pulse_layer(1, host_box(float(TGS_SIZE)))]),
        DISC_TGS_PATH: tgs_bytes([tgs_pulse_layer(1, tgs_disc_box()), tgs_disc_layer(2)]),
        QR_LOGO_PDF_PATH: qr_logo_pdf(),
        QR_PLANE_PDF_PATH: qr_plane_icon_pdf(),
    }


def default_root() -> str:
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def write_assets(root: str, assets: Dict[str, bytes]) -> List[str]:
    written: List[str] = []

    for relative, data in sorted(assets.items()):
        target: str = os.path.join(root, *relative.split("/"))

        with open(target, "wb") as handle:
            handle.write(data)

        written.append(target)

    return written


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser: argparse.ArgumentParser = argparse.ArgumentParser(description="Generate the QR-centre plane artwork.")
    parser.add_argument("--root", default=default_root(), help="iOS tree root to write into")
    arguments: argparse.Namespace = parser.parse_args(argv)

    for path in write_assets(arguments.root, build_assets()):
        print(path)

    return 0


if __name__ == "__main__":
    sys.exit(main())
