#!/usr/bin/env python3
"""Verify branding and configuration in the actual bundle/portable payload."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import struct

p = argparse.ArgumentParser()
p.add_argument('--bundle', type=Path, required=True)
p.add_argument('--platform', choices=['windows', 'linux', 'macos'], required=True)
p.add_argument('--portable-data', type=Path)
p.add_argument('--portable-exe', type=Path)
a = p.parse_args()
branding = Path(__file__).resolve().parents[2] / 'branding'
exports = json.loads((branding / 'compiled/manifest.json').read_text(encoding='utf-8'))
expected = {
 'custom-rendezvous-server': f'{os.environ["SERVER"]}:{os.environ["SERVER_PORT"]}',
 'relay-server': f'{os.environ["SERVER"]}:{int(os.environ["SERVER_PORT"])+1}',
 'key': os.environ['PUBLIC_KEY'], 'api-server': os.environ['API_SERVER'],
}
product = os.environ['PRODUCT_NAME']

def check(condition, message):
    if not condition:
        raise RuntimeError(message)

def one(pattern):
    files = list(a.bundle.rglob(pattern))
    check(len(files) == 1, f'Esperado um arquivo {pattern}, encontrados {len(files)}')
    return files[0]

manifest_file = one('magbel-build.json')
manifest = json.loads(manifest_file.read_text(encoding='utf-8'))
check(manifest['product'] == product and manifest['settings'] == expected, 'Manifesto com produto ou servidor incorreto')
if os.environ.get('GITHUB_SHA'):
    check(manifest['build_commit'] == os.environ['GITHUB_SHA'], 'Pacote de outro commit')
assets = manifest_file.parent
for name, source in {'icon.png':'icon.png', 'logo.png':'logo.png',
                     'logo_light.png':'compiled/logo-light.png', 'logo_dark.png':'compiled/logo-dark.png',
                     'icon.ico':'compiled/icon.ico'}.items():
    check(hashlib.sha256((assets / name).read_bytes()).hexdigest() == exports[source], f'Branding antigo/ausente no pacote: {name}')

library_patterns = {'windows':'librustdesk.dll', 'linux':'librustdesk.so', 'macos':'*rustdesk.dylib'}
# Production Config getters are tested on each target before this verification.
# Native strings can be optimized into instructions, so do not search binary text.
one(library_patterns[a.platform])

ico = (branding / 'compiled/icon.ico').read_bytes()
count = struct.unpack_from('<H', ico, 4)[0]
frames = []
for i in range(count):
    w, h, _, _, _, _, size, offset = struct.unpack_from('<BBBBHHII', ico, 6 + 16*i)
    frames.append(((w or 256)*(h or 256), ico[offset:offset+size]))
icon_frame = max(frames, key=lambda pair: pair[0])[1]
if a.platform == 'windows':
    inner_name = f'{product}.exe'
    inner = one(inner_name).read_bytes()
    check(icon_frame in inner, 'Icone Magbel ausente no EXE Flutter compilado')
    check(product.encode('utf-16-le') in inner, 'Nome Magbel ausente nos metadados Windows')
    check(a.portable_data is not None and a.portable_exe is not None, 'Verificacao Windows requer o pacote portatil')
    payload = a.portable_data.read_bytes()
    exe = a.portable_exe.read_bytes()
    check(payload in exe, 'O EXE publicado nao incorpora o pacote completo')
    check(icon_frame in exe, 'O EXE portatil ainda usa o icone antigo')
    check(product.encode('utf-16-le') in exe, 'Nome Magbel ausente nos metadados do portatil')
    import brotli
    check(payload[:8] == b'rustdesk', 'Cabecalho do pacote invalido')
    position = 8
    packed_hashes = {}
    def take(length):
        global position
        check(0 <= length <= len(payload) - position, 'Pacote portatil truncado')
        value = payload[position:position+length]
        position += length
        return value
    while payload[position:position+8] != b'rustdesk':
        path_len = int.from_bytes(take(4), 'big')
        check(path_len > 0, 'Caminho vazio no pacote portatil')
        path = take(path_len).decode().replace('\\', '/').removeprefix('./')
        data_len = int.from_bytes(take(4), 'big')
        compressed = take(data_len)
        md5 = take(32).decode()
        if path in ('librustdesk.dll', inner_name) or path.endswith('/assets/magbel-build.json') or path.endswith('/assets/icon.png') or path.endswith('/assets/logo_light.png') or path.endswith('/assets/logo_dark.png'):
            content = brotli.decompress(compressed)
            check(hashlib.md5(content).hexdigest() == md5, f'Conteudo portatil corrompido: {path}')
            original = a.bundle / Path(path)
            check(hashlib.sha256(content).digest() == hashlib.sha256(original.read_bytes()).digest(), f'Conteudo portatil diferente do bundle: {path}')
            packed_hashes[path] = True
    check(take(8) == b'rustdesk', 'Final do pacote invalido')
    executable = take(len(payload)-position).decode().replace('\\', '/').removeprefix('./')
    check(executable == inner_name, 'Portatil inicia outro nome de aplicativo')
    check(len(packed_hashes) == 6, 'EXE, biblioteca, manifesto ou imagens ausentes no portatil')
elif a.platform == 'macos':
    native = a.bundle / 'Contents/Resources/AppIcon.icns'
    check(hashlib.sha256(native.read_bytes()).hexdigest() == exports['compiled/AppIcon.icns'], 'Icone macOS antigo')
    info = plistlib.loads((a.bundle / 'Contents/Info.plist').read_bytes())
    check(info['CFBundleName'] == product and info['CFBundleDisplayName'] == product, 'Nome macOS antigo')
else:
    native = a.bundle / 'usr/share/icons/hicolor/256x256/apps/rustdesk.png'
    check(hashlib.sha256(native.read_bytes()).hexdigest() == exports['compiled/256x256.png'], 'Icone Linux antigo')
    desktops = list(a.bundle.glob('*.desktop'))
    check(len(desktops) == 1, 'Desktop AppImage ausente/ambiguo')
    desktop = desktops[0]
    check(f'Name={product}' in desktop.read_text(encoding='utf-8'), 'Nome AppImage antigo')
print(f'OK: {product}, imagens, icones e manifesto de ID/relay/chave/API verificados no pacote {a.platform}.')
