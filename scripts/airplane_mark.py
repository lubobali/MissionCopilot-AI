"""The app's airplane mark (#123): our own drawing, under the code license.

Apple's SF Symbols may not be used, nor anything confusingly like them, in app icons or logos, so
the icon and the home screen's logo lockup use this shape instead of `airplane.circle`. One list of
points is the only source: the asset catalog gets it as a vector (tinted by the app's theme) and the
app icon draws it from the same points.
"""

import json
import math
from pathlib import Path

from PIL import Image, ImageDraw

BOX = 100  # the mark's square, in its own units
MARGIN = 4  # clear space inside the box on every side
HEADING = 45  # degrees clockwise from straight up: it flies up and to the right

# Seen from above, nose up, mirror-symmetric around x = 50: fuselage, swept wings, a small tail.
_RIGHT = [
    (50, 2), (53, 4.5), (55, 11), (55, 38), (95, 59), (95, 66), (55, 55), (55, 80),
    (70, 91), (70, 96), (51.5, 91), (50, 94),
]  # fmt: skip
OUTLINE = _RIGHT + [(100 - x, y) for x, y in reversed(_RIGHT[1:-1])]


def points() -> list[tuple[float, float]]:
    """The outline turned to HEADING and scaled, as one piece, to fill the box inside the margin."""
    turn = math.radians(HEADING)
    cos, sin = math.cos(turn), math.sin(turn)
    # Screen coordinates (y down): a clockwise turn.
    centred = [(x - 50, y - 50) for x, y in OUTLINE]
    turned = [(cos * x - sin * y, sin * x + cos * y) for x, y in centred]
    xs, ys = zip(*turned, strict=True)
    scale = (BOX - 2 * MARGIN) / max(max(xs) - min(xs), max(ys) - min(ys))
    left = (BOX - scale * (max(xs) - min(xs))) / 2 - scale * min(xs)
    top = (BOX - scale * (max(ys) - min(ys))) / 2 - scale * min(ys)
    return [(left + scale * x, top + scale * y) for x, y in turned]


def svg() -> str:
    steps = (f"{'M' if i == 0 else 'L'} {x:.2f} {y:.2f}" for i, (x, y) in enumerate(points()))
    path = " ".join(steps)
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {BOX} {BOX}">'
        f'<path fill="#000000" d="{path} Z"/></svg>\n'
    )


def render(size: int, color: tuple[int, int, int]) -> Image.Image:
    """The mark on a clear square of `size` pixels, drawn four times larger and scaled down for
    smooth edges."""
    big = size * 4
    image = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    ImageDraw.Draw(image).polygon(
        [(x * big / BOX, y * big / BOX) for x, y in points()], fill=(*color, 255)
    )
    return image.resize((size, size), Image.Resampling.LANCZOS)


def write_airplane(catalog: Path) -> None:
    """Airplane.imageset: the SVG, kept as a vector and rendered as a template (the app picks the
    color from its theme)."""
    folder = catalog / "Airplane.imageset"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "Airplane.svg").write_text(svg(), encoding="utf-8")
    body = {
        "images": [{"filename": "Airplane.svg", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {
            "preserves-vector-representation": True,
            "template-rendering-intent": "template",
        },
    }
    (folder / "Contents.json").write_text(json.dumps(body, indent=2) + "\n", encoding="utf-8")
