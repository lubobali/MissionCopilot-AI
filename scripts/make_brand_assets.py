"""Build the app icon and the logo images from the developer's logo file (#87).

Usage: uv run --directory backend python ../scripts/make_brand_assets.py <logo.png>
Writes into ios/MissionCopilot/Assets.xcassets. The logo is not under the code license (README).
New PNGs are saved without the source file's metadata.
"""

import json
import re
import sys
from pathlib import Path

from airplane_mark import write_airplane
from PIL import Image, ImageDraw

ICON_SIZE = 1024
ICON_FILL = 0.72  # the logo's longest side, as a share of the icon: room for the rounded corners
LOGO_POINTS = 96  # logo height on the launch and lock screens
TILE_INSET = 14  # white tile around the launch logo, in points (same as LogoMark in the app)
APP = Path(__file__).resolve().parents[1] / "ios" / "MissionCopilot"
CATALOG = APP / "Assets.xcassets"
PALETTE = APP / "Platform" / "Theme" / "Palette.swift"
BACKGROUND = re.compile(r"case \.background: Row\(light: 0x([0-9A-F]{6}), dark: 0x([0-9A-F]{6})")


def make_icon(logo: Image.Image) -> Image.Image:
    logo = logo.convert("RGBA")
    # Scale up or down so the longest side is exactly the fill (thumbnail would only shrink).
    ratio = ICON_SIZE * ICON_FILL / max(logo.size)
    size = (round(logo.width * ratio), round(logo.height * ratio))
    logo = logo.resize(size, Image.Resampling.LANCZOS)
    icon = Image.new("RGB", (ICON_SIZE, ICON_SIZE), (255, 255, 255))
    icon.paste(logo, ((ICON_SIZE - logo.width) // 2, (ICON_SIZE - logo.height) // 2), logo)
    return icon


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
    _save(make_icon(logo), icon_set / "AppIcon.png")
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
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    write_assets(Image.open(sys.argv[1]))
    write_launch_color(PALETTE.read_text(encoding="utf-8"))
    print(f"OK: icon, logo and airplane written to {CATALOG}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
