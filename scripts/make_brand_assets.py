"""Build the app icon and the logo images from the developer's logo file (#87).

Usage: uv run --directory backend python ../scripts/make_brand_assets.py <logo.png>
       [--preview <out.png>]
Writes into ios/MissionCopilot/Assets.xcassets. The logo is not under the code license (README).
New PNGs are saved without the source file's metadata.
"""

import json
import math
import re
import sys
from pathlib import Path

from airplane_mark import render, write_airplane
from PIL import Image, ImageDraw

ICON_SIZE = 1024
ICON_FILL = 0.72  # the logo's longest side, as a share of the icon: room for the rounded corners
LOGO_POINTS = 96  # logo height on the launch and lock screens
TILE_INSET = 14  # white tile around the launch logo, in points (same as LogoMark in the app)
APP = Path(__file__).resolve().parents[1] / "ios" / "MissionCopilot"
CATALOG = APP / "Assets.xcassets"
PALETTE = APP / "Platform" / "Theme" / "Palette.swift"
BACKGROUND = re.compile(r"case \.background: Row\(light: 0x([0-9A-F]{6}), dark: 0x([0-9A-F]{6})")
TEXT = re.compile(r"case \.text: Row\(light: 0x([0-9A-F]{6})")
ICON_GAP = 40  # clear pixels each mark keeps from the diagonal and from the edges (#123)
# App Store, Home Screen, Spotlight, Settings, notifications: where the icon is seen
PREVIEW_SIZES = (1024, 180, 120, 87, 58, 40)


def make_logo_icon(logo: Image.Image) -> Image.Image:
    """The first icon (#87): the logo alone on white. Kept as the fallback (#123, L.4)."""
    logo = logo.convert("RGBA")
    # Scale up or down so the longest side is exactly the fill (thumbnail would only shrink).
    ratio = ICON_SIZE * ICON_FILL / max(logo.size)
    size = (round(logo.width * ratio), round(logo.height * ratio))
    logo = logo.resize(size, Image.Resampling.LANCZOS)
    icon = Image.new("RGB", (ICON_SIZE, ICON_SIZE), (255, 255, 255))
    icon.paste(logo, ((ICON_SIZE - logo.width) // 2, (ICON_SIZE - logo.height) // 2), logo)
    return icon


def make_icon(logo: Image.Image, navy: tuple[int, int, int]) -> Image.Image:
    """The app icon (#123): split on the diagonal from top right to bottom left, the logo on the
    white top-left half and our airplane, white, on the navy bottom-right half. Each mark sits in
    the largest circle that fits its half, less ICON_GAP, so it never touches the diagonal, an edge,
    or the corners iOS rounds off."""
    icon = Image.new("RGB", (ICON_SIZE, ICON_SIZE), (255, 255, 255))
    ImageDraw.Draw(icon).polygon(
        [(ICON_SIZE, 0), (ICON_SIZE, ICON_SIZE), (0, ICON_SIZE)], fill=navy
    )
    radius = ICON_SIZE * (2 - math.sqrt(2)) / 2  # the circle inside each right triangle
    room = radius - ICON_GAP
    logo = logo.convert("RGBA")
    ratio = 2 * room / math.hypot(*logo.size)  # the logo's box fits inside the circle
    logo = logo.resize(
        (round(logo.width * ratio), round(logo.height * ratio)), Image.Resampling.LANCZOS
    )
    icon.paste(logo, (round(radius - logo.width / 2), round(radius - logo.height / 2)), logo)
    side = round(room * math.sqrt(2))  # the airplane's square fits inside the other circle
    plane = render(side, (255, 255, 255))
    corner = round(ICON_SIZE - radius - side / 2)
    icon.paste(plane, (corner, corner), plane)
    return icon


def make_preview(icon: Image.Image) -> Image.Image:
    """The icon at each size it is seen, with iOS's rounded corners, on a mid gray (Lubo's look)."""
    gap = 24
    sheet = Image.new(
        "RGB",
        (sum(PREVIEW_SIZES) + gap * (len(PREVIEW_SIZES) + 1), 1024 + 2 * gap),
        (128, 128, 128),
    )
    left = gap
    for size in PREVIEW_SIZES:
        small = icon.resize((size, size), Image.Resampling.LANCZOS)
        mask = Image.new("L", (size, size), 0)
        ImageDraw.Draw(mask).rounded_rectangle(
            (0, 0, size - 1, size - 1), radius=round(size * 0.2237), fill=255
        )
        sheet.paste(small, (left, gap + (1024 - size) // 2), mask)
        left += size + gap
    return sheet


def navy_color(palette_swift: str) -> tuple[int, int, int]:
    """The icon's navy: the theme's light text color, read from the palette so it cannot drift."""
    match = TEXT.search(palette_swift)
    if not match:
        raise ValueError("no text row in Palette.swift")
    value = match.group(1)
    return (int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16))


def make_logo(logo: Image.Image, scale: int) -> Image.Image:
    logo = logo.convert("RGBA")
    height = LOGO_POINTS * scale
    width = round(logo.width * height / logo.height)
    return logo.resize((width, height), Image.Resampling.LANCZOS)


def make_tile(logo: Image.Image, scale: int) -> Image.Image:
    """The logo on a white rounded tile with clear corners, for the launch screen: the dark blue and
    black of the logo would vanish on the dark background."""
    mark = make_logo(logo, scale)
    inset = TILE_INSET * scale
    tile = Image.new("RGBA", (mark.width + 2 * inset, mark.height + 2 * inset), (0, 0, 0, 0))
    shape = (0, 0, tile.width - 1, tile.height - 1)
    ImageDraw.Draw(tile).rounded_rectangle(
        shape, radius=round(inset * 1.6), fill=(255, 255, 255, 255)
    )
    tile.alpha_composite(mark, (inset, inset))
    return tile


def background_colors(palette_swift: str) -> tuple[str, str]:
    """The light and dark background, read from the palette so the launch screen cannot drift."""
    match = BACKGROUND.search(palette_swift)
    if not match:
        raise ValueError("no background row in Palette.swift")
    return match.group(1), match.group(2)


def _color(hex_rgb: str) -> dict:
    red, green, blue = (f"0x{hex_rgb[i : i + 2]}" for i in (0, 2, 4))
    components = {"alpha": "1.000", "red": red, "green": green, "blue": blue}
    return {"color-space": "srgb", "components": components}


def _save(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.frombytes(image.mode, image.size, image.tobytes()).save(path, optimize=True)


def _contents(path: Path, **parts: list[dict]) -> None:
    """An asset catalog Contents.json: the given parts plus Xcode's info block."""
    body = {**parts, "info": {"author": "xcode", "version": 1}}
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(body, indent=2) + "\n", encoding="utf-8")


def write_launch_color(palette_swift: str, catalog: Path = CATALOG) -> None:
    light, dark = background_colors(palette_swift)
    dark_look = [{"appearance": "luminosity", "value": "dark"}]
    colors = [
        {"idiom": "universal", "color": _color(light)},
        {"idiom": "universal", "color": _color(dark), "appearances": dark_look},
    ]
    _contents(catalog / "LaunchBackground.colorset" / "Contents.json", colors=colors)


def write_assets(logo: Image.Image, catalog: Path = CATALOG) -> None:
    icon_set = catalog / "AppIcon.appiconset"
    navy = navy_color(PALETTE.read_text(encoding="utf-8"))
    _save(make_icon(logo, navy), icon_set / "AppIcon.png")
    icon = {"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}
    _contents(icon_set / "Contents.json", images=[icon])
    for set_name, make in (("Logo", make_logo), ("LaunchLogo", make_tile)):
        folder = catalog / f"{set_name}.imageset"
        images = []
        for scale in (2, 3):
            name = f"{set_name}@{scale}x.png"
            _save(make(logo, scale), folder / name)
            images.append({"filename": name, "idiom": "universal", "scale": f"{scale}x"})
        _contents(folder / "Contents.json", images=images)
    write_airplane(catalog)
    _contents(catalog / "Contents.json")


def main() -> int:
    args = sys.argv[1:]
    if len(args) not in (1, 3) or (len(args) == 3 and args[1] != "--preview"):
        print(__doc__)
        return 2
    logo = Image.open(args[0])
    write_assets(logo)
    write_launch_color(PALETTE.read_text(encoding="utf-8"))
    if len(args) == 3:  # the sheet is for looking at, never committed
        navy = navy_color(PALETTE.read_text(encoding="utf-8"))
        make_preview(make_icon(logo, navy)).save(args[2])
    print(f"OK: icon, logo and airplane written to {CATALOG}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
