import json
import math

import pytest
from airplane_mark import svg
from make_brand_assets import (
    APP,
    ICON_GAP,
    ICON_SIZE,
    LOGO_POINTS,
    TILE_INSET,
    background_colors,
    make_icon,
    make_logo,
    make_logo_icon,
    make_preview,
    make_tile,
    navy_color,
    write_assets,
    write_launch_color,
)
from PIL import Image

pytestmark = pytest.mark.unit


def _logo(width=500, height=600, margin=50):
    """A stand-in logo: a blue block on a clear background, taller than wide like the real one."""
    image = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    image.paste((0, 80, 200, 255), (margin, margin, width - margin, height - margin))
    return image


NAVY = (0x00, 0x22, 0x44)


def test_the_icon_is_1024_square_with_no_transparency():
    icon = make_icon(_logo(), NAVY)

    assert icon.size == (ICON_SIZE, ICON_SIZE)
    assert icon.mode == "RGB"  # the App Store refuses an icon with an alpha channel


def test_the_plain_icon_is_the_logo_on_white_with_room_around_it():
    # Kept as the fallback if the diagonal icon does not read well on the phone (#123, L.4).
    icon = make_logo_icon(_logo(margin=0))

    assert icon.getpixel((0, 0)) == (255, 255, 255)
    assert icon.getpixel((ICON_SIZE // 2, ICON_SIZE // 2)) == (0, 80, 200)
    # The logo fills about 72% and stays inside the middle 80%, so the rounded corners never cut it.
    left, top, right, bottom = icon.convert("L").point(lambda v: 255 if v < 250 else 0).getbbox()
    assert min(left, top) >= ICON_SIZE * 0.1 and max(right, bottom) <= ICON_SIZE * 0.9
    assert abs((bottom - top) - ICON_SIZE * 0.72) <= 2


def test_the_logo_keeps_its_shape_and_transparency():
    logo = make_logo(_logo(500, 600), scale=3)

    assert logo.mode == "RGBA"
    assert logo.height == LOGO_POINTS * 3
    assert abs(logo.width / logo.height - 500 / 600) < 0.01
    assert logo.getpixel((0, 0))[3] == 0


def test_no_metadata_is_copied_from_the_source(tmp_path):
    # Pillow carries an embedded color profile (or EXIF) into every resized copy it saves.
    source = _logo()
    source.info["icc_profile"] = b"profile from the designer's machine"
    write_assets(source, tmp_path)

    for png in tmp_path.rglob("*.png"):
        assert Image.open(png).info == {}, png


def test_the_catalog_has_the_icon_and_the_logo_at_2x_and_3x(tmp_path):
    write_assets(_logo(), tmp_path)

    icon = json.loads((tmp_path / "AppIcon.appiconset" / "Contents.json").read_text())
    logo = json.loads((tmp_path / "Logo.imageset" / "Contents.json").read_text())
    assert icon["images"] == [
        {"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}
    ]
    assert [(i["scale"], i["filename"]) for i in logo["images"]] == [
        ("2x", "Logo@2x.png"),
        ("3x", "Logo@3x.png"),
    ]
    assert Image.open(tmp_path / "Logo.imageset" / "Logo@2x.png").height == LOGO_POINTS * 2


PALETTE_ROW = (
    "        case .background: Row(light: 0xF5F7F9, dark: 0x0B1220, lightHigh: 0xFFFFFF)\n"
)


def test_the_launch_background_comes_from_the_palette():
    assert background_colors("enum Palette {\n" + PALETTE_ROW + "}\n") == ("F5F7F9", "0B1220")


def test_a_palette_without_a_background_row_is_an_error():
    with pytest.raises(ValueError, match="background"):
        background_colors("case .surface: Row(light: 0xFFFFFF, dark: 0x121A2B")


def test_the_launch_color_set_has_light_and_dark(tmp_path):
    write_launch_color(PALETTE_ROW, tmp_path)

    body = json.loads((tmp_path / "LaunchBackground.colorset" / "Contents.json").read_text())
    light, dark = body["colors"]
    assert light["color"]["components"] == {
        "alpha": "1.000",
        "red": "0xF5",
        "green": "0xF7",
        "blue": "0xF9",
    }
    assert "appearances" not in light
    assert dark["appearances"] == [{"appearance": "luminosity", "value": "dark"}]
    assert dark["color"]["components"]["red"] == "0x0B"


def test_the_launch_logo_sits_on_a_white_rounded_tile():
    tile = make_tile(_logo(margin=0), scale=2)

    inset = TILE_INSET * 2
    assert tile.height == LOGO_POINTS * 2 + 2 * inset
    assert tile.getpixel((0, 0))[3] == 0  # rounded corner: clear
    assert tile.getpixel((inset // 2, tile.height // 2)) == (255, 255, 255, 255)
    assert tile.getpixel((tile.width // 2, tile.height // 2)) == (0, 80, 200, 255)


def test_the_catalog_has_the_launch_logo_too(tmp_path):
    write_assets(_logo(), tmp_path)

    names = [
        i["filename"]
        for i in json.loads((tmp_path / "LaunchLogo.imageset" / "Contents.json").read_text())[
            "images"
        ]
    ]
    assert names == ["LaunchLogo@2x.png", "LaunchLogo@3x.png"]


def test_the_catalog_has_our_airplane_too(tmp_path):
    write_assets(_logo(), tmp_path)

    assert (tmp_path / "Airplane.imageset" / "Airplane.svg").read_text() == svg()


# The diagonal icon (#123): the logo on the white top-left half, our airplane on the navy one.


def _distance_from_diagonal(x, y):
    return (ICON_SIZE - (x + y)) / math.sqrt(2)  # positive above it (top-left), negative below


def _pixels(icon, keep):
    return [
        (x, y)
        for y in range(0, ICON_SIZE, 2)
        for x in range(0, ICON_SIZE, 2)
        if keep(icon.getpixel((x, y)))
    ]


def test_the_icon_is_split_on_the_diagonal_white_above_navy_below():
    icon = make_icon(_logo(), NAVY)

    assert icon.getpixel((8, 8)) == (255, 255, 255)
    assert icon.getpixel((ICON_SIZE - 8, ICON_SIZE - 8)) == NAVY
    assert icon.getpixel((ICON_SIZE // 2 - 6, ICON_SIZE // 2 - 6)) == (255, 255, 255)
    assert icon.getpixel((ICON_SIZE // 2 + 6, ICON_SIZE // 2 + 6)) == NAVY


def test_the_logo_stays_in_the_top_left_half_clear_of_the_diagonal_and_the_edges():
    logo = _pixels(make_icon(_logo(margin=0), NAVY), lambda p: p == (0, 80, 200))

    assert len(logo) > 1000
    assert min(_distance_from_diagonal(x, y) for x, y in logo) >= ICON_GAP - 2
    assert min(min(x, y) for x, y in logo) >= ICON_GAP - 2


def test_the_airplane_is_white_in_the_bottom_right_half_clear_of_the_diagonal_and_the_edges():
    icon = make_icon(_logo(), NAVY)
    airplane = _pixels(icon, lambda p: p == (255, 255, 255))
    below = [(x, y) for x, y in airplane if _distance_from_diagonal(x, y) < 0]

    assert len(below) > 1000
    assert max(_distance_from_diagonal(x, y) for x, y in below) <= -(ICON_GAP - 2)
    assert max(max(x, y) for x, y in below) <= ICON_SIZE - (ICON_GAP - 2)


def test_the_marks_are_big_enough_to_see():
    # Each fills most of the circle that fits its half: about a third of the icon's side.
    icon = make_icon(_logo(margin=0), NAVY)
    logo = _pixels(icon, lambda p: p == (0, 80, 200))
    plane = [
        p for p in _pixels(icon, lambda p: p == (255, 255, 255)) if _distance_from_diagonal(*p) < 0
    ]
    for marks in (logo, plane):
        xs, ys = zip(*marks, strict=True)
        assert max(max(xs) - min(xs), max(ys) - min(ys)) >= ICON_SIZE * 0.3


def test_the_navy_is_the_themes_text_color():
    row = "        case .text: Row(light: 0x002244, dark: 0xF5F7F9, lightHigh: 0x001126)\n"
    assert navy_color("enum Palette {\n" + row + "}\n") == NAVY


def test_a_palette_without_a_text_row_is_an_error():
    with pytest.raises(ValueError, match="text"):
        navy_color("case .surface: Row(light: 0xFFFFFF, dark: 0x121A2B")


def test_the_preview_shows_the_icon_at_every_size_it_is_seen():
    sheet = make_preview(make_icon(_logo(), NAVY))

    sizes = (1024, 180, 120, 87, 58, 40)
    assert sheet.height >= max(sizes) and sheet.width >= sum(sizes)
    assert sheet.mode == "RGB"


def test_the_catalog_gets_the_diagonal_icon_in_the_themes_navy(tmp_path):
    write_assets(_logo(), tmp_path)

    icon = Image.open(tmp_path / "AppIcon.appiconset" / "AppIcon.png")
    navy = navy_color((APP / "Platform" / "Theme" / "Palette.swift").read_text(encoding="utf-8"))
    assert icon.getpixel((ICON_SIZE - 8, ICON_SIZE - 8)) == navy
    assert icon.getpixel((8, 8)) == (255, 255, 255)


def test_the_preview_has_one_tile_per_size_with_rounded_corners():
    sheet = make_preview(make_icon(_logo(), NAVY))
    gray = (128, 128, 128)
    middle = sheet.height // 2
    row = [sheet.getpixel((x, middle)) != gray for x in range(sheet.width)]
    tiles = sum(1 for x in range(1, len(row)) if row[x] and not row[x - 1])

    assert tiles == 6
    left = row.index(True)  # the big tile's left edge: its top-left corner is cut round, like iOS
    top = next(y for y in range(sheet.height) if sheet.getpixel((left + 512, y)) != gray)
    assert sheet.getpixel((left + 2, top + 2)) == gray
