#!/usr/bin/env python3
"""Resize the original site's launcher art. Requires Pillow for regeneration."""
import json
from pathlib import Path

from PIL import Image

root = Path(__file__).resolve().parents[1]
source = Image.open(root / 'assets/branding/app-icon.png').convert('RGB')
assert source.size == (512, 512)
for platform in ('ios', 'macos'):
    folder = root / platform / 'Runner/Assets.xcassets/AppIcon.appiconset'
    for entry in json.loads((folder / 'Contents.json').read_text())['images']:
        size = round(float(entry['size'].split('x')[0]) * float(entry['scale'].rstrip('x')))
        source.resize((size, size), Image.Resampling.LANCZOS).save(folder / entry['filename'])
for density, size in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]:
    source.resize((size, size), Image.Resampling.LANCZOS).save(
        root / f'android/app/src/main/res/mipmap-{density}/ic_launcher.png')
for name, size in [('Icon-192.png', 192), ('Icon-512.png', 512),
                   ('Icon-maskable-192.png', 192), ('Icon-maskable-512.png', 512)]:
    image = source
    if 'maskable' in name:
        image = Image.new('RGB', (512, 512), source.getpixel((0, 0)))
        image.paste(source.resize((360, 360), Image.Resampling.LANCZOS), (76, 76))
    image.resize((size, size), Image.Resampling.LANCZOS).save(root / 'web/icons' / name)
source.resize((32, 32), Image.Resampling.LANCZOS).save(root / 'web/favicon.png')
source.save(root / 'windows/runner/resources/app_icon.ico', format='ICO',
            sizes=[(size, size) for size in (16, 24, 32, 48, 64, 128, 256)])
print('Generated original-site icons for Android, iOS, macOS, Windows and Web; Linux uses the source PNG.')
