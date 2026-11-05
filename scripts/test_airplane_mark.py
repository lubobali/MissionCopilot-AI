import json
import math
import re

import pytest
from airplane_mark import (
    BOX,
    HEADING,
    MARGIN,
    OUTLINE,
    points,
    render,
    svg,
    write_airplane,
)

pytestmark = pytest.mark.unit


def test_the_outline_is_mirror_symmetric_nose_up():
    # Drawn nose up around x = 50: every point on the right has its twin on the left.
    pairs = {(round(x, 3), round(y, 3)) for x, y in OUTLINE}
    assert all((round(100 - x, 3), y) in pairs for x, y in pairs)
    assert min(y for _, y in OUTLINE) == next(y for x, y in OUTLINE if x == 50)  # the nose leads


def test_it_flies_up_and_to_the_right():
    assert HEADING == 45
    nose = OUTLINE.index(min(OUTLINE, key=lambda p: p[1]))
    x, y = points()[nose]
    # The nose ends up in the top-right part of the box.
    assert x > BOX * 0.75 and y < BOX * 0.25


def test_the_turned_mark_fits_its_box_and_fills_it():
    xs, ys = zip(*points(), strict=True)
    assert min(xs) >= MARGIN - 1e-6 and min(ys) >= MARGIN - 1e-6
    assert max(xs) <= BOX - MARGIN + 1e-6 and max(ys) <= BOX - MARGIN + 1e-6
    assert max(max(xs) - min(xs), max(ys) - min(ys)) >= BOX - 2 * MARGIN - 1e-6


def test_turning_keeps_its_shape():
    # One turn and one uniform scale: every distance grows by the same factor, nothing is squashed.
    turned, drawn = points(), OUTLINE
    factor = math.dist(turned[0], turned[1]) / math.dist(drawn[0], drawn[1])
    for i in range(len(drawn)):
        for j in range(i + 1, len(drawn)):
            assert math.dist(turned[i], turned[j]) == pytest.approx(
                factor * math.dist(drawn[i], drawn[j])
            )


def test_the_svg_has_exactly_these_points():
    text = svg()

    assert f'viewBox="0 0 {BOX} {BOX}"' in text
    numbers = [float(n) for n in re.findall(r"-?\d+\.\d+", text.split(' d="')[1].split('"')[0])]
    assert list(zip(numbers[::2], numbers[1::2], strict=True)) == [
        (round(x, 2), round(y, 2)) for x, y in points()
    ]
    assert 'fill="#000000"' in text  # template image: the app tints it with a theme color


def test_the_drawn_mark_has_color_on_the_plane_and_clear_corners():
    image = render(300, (255, 255, 255))

    assert image.size == (300, 300) and image.mode == "RGBA"
    assert image.getpixel((150, 150)) == (255, 255, 255, 255)  # the middle of the fuselage
    for corner in ((2, 2), (297, 297)):
        assert image.getpixel(corner)[3] == 0
    assert image.getpixel((297, 2))[3] == 0  # the nose stops short of the corner (the margin)


def test_the_catalog_keeps_it_as_a_tintable_vector(tmp_path):
    write_airplane(tmp_path)

    folder = tmp_path / "Airplane.imageset"
    body = json.loads((folder / "Contents.json").read_text())
    assert body["images"] == [{"filename": "Airplane.svg", "idiom": "universal"}]
    assert body["properties"] == {
        "preserves-vector-representation": True,
        "template-rendering-intent": "template",
    }
    assert (folder / "Airplane.svg").read_text() == svg()
