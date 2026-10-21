#!/usr/bin/env python3
"""Export the existing Magbel artwork to the formats used by native runners.
Run locally after changing branding artwork: pip install Pillow cairosvg.
The build consumes the checked-in exports and validates their source hashes.
"""
import base64
import hashlib
import json
from pathlib import Path

import cairosvg
from PIL import Image, ImageChops

branding = Path(__file__).resolve().parents[2] / 'branding'
out = branding / 'compiled'
out.mkdir(exist_ok=True)
icon = Image.open(branding / 'icon.png').convert('RGBA')
icon.save(out / 'icon.ico', sizes=[(s, s) for s in (16, 20, 24, 32, 40, 48, 64, 96, 128, 256)])
icon.resize((32, 32), Image.Resampling.LANCZOS).save(out / 'tray-icon.ico', sizes=[(32, 32)])
for size in (32, 64, 128, 256):
    icon.resize((size, size), Image.Resampling.LANCZOS).save(out / f'{size}x{size}.png')
Image.open(branding / 'logo.png').convert('RGBA').resize((1024, 1024), Image.Resampling.LANCZOS).save(out / 'AppIcon.icns')
# macOS template icons use alpha rather than colour; retain the orange mark.
mask = ImageChops.subtract(icon.getchannel('R'), icon.getchannel('B'))
tray = Image.new('RGBA', icon.size, 'white')
tray.putalpha(mask)
tray.resize((44, 44), Image.Resampling.LANCZOS).save(out / 'mac-tray-dark-x2.png')
for theme in ('light', 'dark'):
    # Artwork names describe the ink colour; Flutter theme names describe the background.
    ink = 'dark' if theme == 'light' else 'light'
    cairosvg.svg2png(url=str(branding / f'logo-{ink}.svg'), write_to=str(out / f'logo-{theme}.png'), scale=2)
encoded = base64.b64encode((branding / 'icon.png').read_bytes()).decode()
(out / 'icon.svg').write_text(f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="256" height="256" viewBox="0 0 256 256"><image width="256" height="256" xlink:href="data:image/png;base64,{encoded}"/></svg>\n')
files = [p for p in branding.iterdir() if p.is_file()] + [p for p in out.iterdir() if p.is_file() and p.name != 'manifest.json']
manifest = {str(p.relative_to(branding)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)}
(out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print('Exported Magbel icons, logos and source/export hashes.')
