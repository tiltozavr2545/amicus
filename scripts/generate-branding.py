#!/usr/bin/env python3
"""Generate Android launcher backgrounds and iOS launcher icons.

Requires Pillow. The Android foreground and monochrome layers and the
transparent in-app mark are checked-in artwork.
"""
import json
from pathlib import Path

from PIL import Image, ImageColor

ROOT = Path(__file__).resolve().parents[1] / 'app'
# AmicusTheme: dark onPrimary and light primary.
GRADIENT_START = ImageColor.getrgb('#30234E')
GRADIENT_END = ImageColor.getrgb('#6354A5')


def launcher_background(size):
    width, height = size
    steps = width + height - 2
    channels = tuple(zip(GRADIENT_START, GRADIENT_END))
    diagonal = [
        tuple(round(start + (end - start) * step / steps) for start, end in channels)
        for step in range(steps + 1)
    ]
    background = Image.new('RGB', size)
    background.putdata([diagonal[x + y] for y in range(height) for x in range(width)])
    return background


def main():
    res = ROOT / 'android/app/src/main/res'
    for path in sorted(res.glob('mipmap-*/ic_launcher_foreground.png')):
        with Image.open(path) as layer:
            background = launcher_background(layer.size)
        background.save(path.with_name('ic_launcher_background.png'))

    source = Image.open(ROOT / 'assets/branding/app_icon.png').convert('RGBA')
    icons = ROOT / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
    for entry in json.loads((icons / 'Contents.json').read_text())['images']:
        if 'filename' not in entry:
            continue
        size = round(float(entry['size'].split('x')[0]) * float(entry['scale'][:-1]))
        foreground_size = round(size * 1.5)
        foreground = source.resize((foreground_size, foreground_size), Image.Resampling.LANCZOS)
        background = launcher_background((size, size)).convert('RGBA')
        offset = (size - foreground_size) // 2
        background.alpha_composite(foreground, (offset, offset))
        background.convert('RGB').save(icons / entry['filename'])


if __name__ == '__main__':
    main()
