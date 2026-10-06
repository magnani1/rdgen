#!/usr/bin/env python3
"""Check the official source/resource contracts before starting native builds."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import struct
import tomllib
import xml.etree.ElementTree as ET

p = argparse.ArgumentParser()
p.add_argument('--root', type=Path, required=True)
root = p.parse_args().root
product = os.environ['PRODUCT_NAME']

def text(path):
    return (root / path).read_text(encoding='utf-8')

def check(condition, message):
    if not condition:
        raise RuntimeError(message)

cargo = tomllib.loads(text('Cargo.toml'))
check(cargo['lib']['name'] == 'librustdesk', 'Nome da biblioteca oficial mudou')
check(cargo['package']['metadata']['winres']['ProductName'] == product, 'Metadados Rust Windows sem branding')
check('set(BINARY_NAME "rustdesk")' in text('flutter/windows/CMakeLists.txt'), 'Nome inicial do Runner Windows mudou')
check('resources\\\\app_icon.ico' in text('flutter/windows/runner/Runner.rc'), 'Runner Windows usa outro recurso de icone')
check(f'VALUE "ProductName", "{product}"' in text('flutter/windows/runner/Runner.rc'), 'Metadados Runner sem branding')
check('res/icon.ico' in text('libs/portable/build.rs'), 'Empacotador Windows usa outro icone')
portable = tomllib.loads(text('libs/portable/Cargo.toml'))
check(portable['package']['metadata']['winres']['ProductName'] == product, 'Metadados portatil sem branding')
check('include_bytes!("../data.bin")' in text('libs/portable/src/bin_reader.rs'), 'Formato do empacotador oficial mudou')
check('AppIcon.icns in Resources' in text('flutter/macos/Runner.xcodeproj/project.pbxproj'), 'Runner macOS usa outro icone')
check('PRODUCT_NAME = RustDesk' in text('flutter/macos/Runner/Configs/AppInfo.xcconfig'), 'Pasta inicial esperada pelo build.py mudou')
info = plistlib.loads((root / 'flutter/macos/Runner/Info.plist').read_bytes())
check(info['CFBundleName'] == product and info['CFBundleDisplayName'] == product, 'Nome macOS incorreto')
ET.parse(root / 'flutter/macos/Runner/Base.lproj/MainMenu.xib')
check((root / '.github/scripts/sign-macos-app.sh').is_file(), 'Script oficial de assinatura macOS ausente')
entitlements = plistlib.loads((root / 'flutter/macos/Runner/Release.entitlements').read_bytes())
check(entitlements.get('com.apple.security.device.audio-input'), 'Entitlement de audio macOS ausente')
check(f'Name={product}' in text('res/rustdesk.desktop'), 'Nome Linux incorreto')
check('res/128x128@2x.png' in text('build.py'), 'DEB Linux usa outro recurso de icone')
check('usr/share/rustdesk/rustdesk' in text('appimage/AppImageBuilder-x86_64.yml'), 'Entrada do AppImage mudou')
check(re.search(r'^\s+- assets/\s*$', text('flutter/pubspec.yaml'), re.M), 'Assets nao incluidos pelo Flutter')
check('assets/icon.png' in text('flutter/lib/common.dart') and "assets/logo_light.png" in text('flutter/lib/common.dart') and "assets/logo_dark.png" in text('flutter/lib/common.dart'), 'Interface usa outros arquivos de branding')
for path in ('flutter/assets/icon.png', 'flutter/assets/logo_light.png', 'flutter/assets/logo_dark.png'):
    data = (root / path).read_bytes()
    check(data[:8] == b'\x89PNG\r\n\x1a\n', f'PNG invalido: {path}')
    check(all(struct.unpack('>II', data[16:24])), f'PNG sem dimensoes: {path}')
manifest = json.loads(text('flutter/assets/magbel-build.json'))
check(manifest['product'] == product and manifest['build_commit'] == os.environ.get('GITHUB_SHA', ''), 'Manifesto incorreto')
print('OK: patch e recursos de Windows, Linux e macOS conferidos contra os consumidores oficiais.')
