#!/usr/bin/env python3
"""Verify branding and configuration in the actual bundle/portable payload."""
import argparse
import ctypes
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
exports = json.loads((branding / 'compiled/manifest.json').read_text())
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
manifest = json.loads(manifest_file.read_text())
check(manifest['product'] == product and manifest['settings'] == expected, 'Manifesto com produto ou servidor incorreto')
if os.environ.get('GITHUB_SHA'):
    check(manifest['build_commit'] == os.environ['GITHUB_SHA'], 'Pacote de outro commit')
assets = manifest_file.parent
for name, source in {'icon.png':'icon.png', 'logo.png':'logo.png',
                     'logo_light.png':'compiled/logo-light.png', 'logo_dark.png':'compiled/logo-dark.png',
                     'icon.ico':'compiled/icon.ico'}.items():
    check(hashlib.sha256((assets / name).read_bytes()).hexdigest() == exports[source], f'Branding antigo/ausente no pacote: {name}')

library_patterns = {'windows':'librustdesk.dll', 'linux':'librustdesk.so', 'macos':'*rustdesk.dylib'}
library = one(library_patterns[a.platform]).resolve()
dll_directory = os.add_dll_directory(str(library.parent)) if os.name == 'nt' else None
try:
    native_library = ctypes.CDLL(str(library))
    native_library.magbel_get_config_json.restype = ctypes.c_void_p
    native_library.magbel_get_config_json.argtypes = []
    native_library.magbel_free_config_json.argtypes = [ctypes.c_void_p]
    native_library.magbel_free_config_json.restype = None
    pointer = native_library.magbel_get_config_json()
    check(pointer, 'A biblioteca nao retornou a configuracao')
    try:
        runtime = json.loads(ctypes.string_at(pointer).decode('utf-8'))
    finally:
        native_library.magbel_free_config_json(pointer)
finally:
    if dll_directory is not None:
        dll_directory.close()
check(runtime['product'] == product, 'Nome incorreto na biblioteca compilada')
check(runtime['settings'] == expected, 'Conexao incorreta na biblioteca compilada')
check(runtime['effective_api'] == expected['api-server'], 'Resolvedor da API aponta para outro servidor')
check(runtime['register_device'], 'Registro de dispositivos desabilitado')
print('Configuracao consultada na biblioteca compilada:', json.dumps(runtime, sort_keys=True))

ico = (branding / 'compiled/icon.ico').read_bytes()
count = struct.unpack_from('<H', ico, 4)[0]
frames = []
for i in range(count):
    w, h, _, _, _, _, size, offset = struct.unpack_from('<BBBBHHII', ico, 6 + 16*i)
    frames.append(((w or 256)*(h or 256), ico[offset:offset+size]))
icon_frame = max(frames, key=lambda pair: pair[0])[1]
if a.platform == 'windows':
    check(icon_frame in one('rustdesk.exe').read_bytes(), 'Icone Magbel ausente no EXE Flutter compilado')
    check(a.portable_data is not None and a.portable_exe is not None, 'Verificacao Windows requer o pacote portatil')
    payload = a.portable_data.read_bytes()
    exe = a.portable_exe.read_bytes()
    check(payload in exe, 'O EXE publicado nao incorpora o pacote completo')
    check(icon_frame in exe, 'O EXE portatil ainda usa o icone antigo')
    import brotli
    check(payload[:8] == b'rustdesk', 'Cabecalho do pacote invalido')
    position = 8
    packed_hashes = {}
    while payload[position:position+8] != b'rustdesk':
        path_len = int.from_bytes(payload[position:position+4], 'big'); position += 4
        path = payload[position:position+path_len].decode().replace('\\', '/').removeprefix('./'); position += path_len
        data_len = int.from_bytes(payload[position:position+4], 'big'); position += 4
        compressed = payload[position:position+data_len]; position += data_len
        md5 = payload[position:position+32].decode(); position += 32
        if path == 'librustdesk.dll' or path.endswith('/assets/magbel-build.json') or path.endswith('/assets/icon.png') or path.endswith('/assets/logo_light.png') or path.endswith('/assets/logo_dark.png'):
            content = brotli.decompress(compressed)
            check(hashlib.md5(content).hexdigest() == md5, f'Conteudo portatil corrompido: {path}')
            original = a.bundle / Path(path)
            check(hashlib.sha256(content).digest() == hashlib.sha256(original.read_bytes()).digest(), f'Conteudo portatil diferente do bundle: {path}')
            packed_hashes[path] = True
    check(len(packed_hashes) == 5, 'Biblioteca, manifesto ou imagens ausentes no EXE portatil')
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
    check(f'Name={product}' in desktop.read_text(), 'Nome AppImage antigo')
print(f'OK: {product}, ID/relay/chave/API e branding verificados no pacote {a.platform}.')
