#!/usr/bin/env python3
"""Package the original authored foreground; never redraw the Amicus symbol.

Requires Pillow. Android adaptive foreground/monochrome resources are source
artwork and stay untouched. The in-app transparent asset is also source artwork.
"""
import json
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1] / 'app'
ACCENT = '#6354A5'


def main():
    res = ROOT / 'android/app/src/main/res'
    for folder in res.glob('mipmap-*'):
        path = folder / 'ic_launcher_background.png'
        if path.exists():
            with Image.open(path) as previous:
                Image.new('RGB', previous.size, ACCENT).save(path)
    # Native icon packaging: compose the unmodified alpha artwork on a solid
    # background, retaining its stroke opacity and original node proportions.
    source = Image.open(ROOT / 'assets/branding/app_icon.png').convert('RGBA')
    icons = ROOT / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
    for entry in json.loads((icons / 'Contents.json').read_text())['images']:
        if 'filename' not in entry:
            continue
        size = round(float(entry['size'].split('x')[0]) * float(entry['scale'][:-1]))
        foreground_size = round(size * 1.5)
        foreground = source.resize((foreground_size, foreground_size), Image.Resampling.LANCZOS)
        background = Image.new('RGBA', (size, size), ACCENT)
        offset = (size - foreground_size) // 2
        background.alpha_composite(foreground, (offset, offset))
        background.convert('RGB').save(icons / entry['filename'])


if __name__ == '__main__':
    main()
