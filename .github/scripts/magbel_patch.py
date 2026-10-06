#!/usr/bin/env python3
"""Apply fail-fast Magbel branding and explicit self-hosted connection defaults."""
import argparse
import base64
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shutil
from urllib.parse import urlsplit

p = argparse.ArgumentParser()
for name in ('root', 'product', 'company', 'server', 'key', 'api', 'website'):
    p.add_argument('--' + name, required=True)
p.add_argument('--port', required=True, type=int)
a = p.parse_args()
root = pathlib.Path(a.root)
branding = pathlib.Path(__file__).resolve().parents[2] / 'branding'
if not re.fullmatch(r'[A-Za-z0-9.-]+', a.server) or not 1 <= a.port <= 65532:
    p.error('Servidor deve ser hostname/IP sem URL, e a porta deve permitir o bloco ID/relay/WS.')
if len(base64.b64decode(a.key, validate=True)) != 32:
    p.error('Chave publica RustDesk deve conter 32 bytes em base64.')
api = urlsplit(a.api)
if api.scheme not in ('http', 'https') or not api.netloc or api.path not in ('', '/') or api.query or api.fragment:
    p.error('API deve ser a URL base do painel, sem /devices nem /api.')
a.api = a.api.rstrip('/')

manifest = json.loads((branding / 'compiled/manifest.json').read_text())
for path, expected in manifest.items():
    if hashlib.sha256((branding / path).read_bytes()).hexdigest() != expected:
        raise RuntimeError(f'Branding alterado ou exportacao desatualizada: {path}')

def replace(path, pattern, value):
    f = root / path
    old = f.read_text(encoding='utf-8')
    new, count = re.subn(pattern, lambda _: value, old)
    if count != 1:
        raise RuntimeError(f'Esperado um padrao em {path}; encontrados {count}: {pattern}')
    f.write_text(new, encoding='utf-8')

# JSON string literals are valid Rust string literals for the configured values.
def literal(value):
    return json.dumps(value, ensure_ascii=False)

config = 'libs/hbb_common/src/config.rs'
replace(config, r'pub const RENDEZVOUS_SERVERS: &\[&str\] = &\[[^;]+;',
        f'pub const RENDEZVOUS_SERVERS: &[&str] = &[{literal(a.server)}];')
replace(config, r'pub const RS_PUB_KEY: &str = "[^"\n]+";',
        f'pub const RS_PUB_KEY: &str = {literal(a.key)};')
for name, offset in [('RENDEZVOUS_PORT', 0), ('RELAY_PORT', 1), ('WS_RENDEZVOUS_PORT', 2), ('WS_RELAY_PORT', 3)]:
    replace(config, rf'pub const {name}: i32 = \d+;', f'pub const {name}: i32 = {a.port + offset};')
replace(config, r'pub static ref APP_NAME: RwLock<String> = RwLock::new\("RustDesk"\.to_owned\(\)\);',
        f'pub static ref APP_NAME: RwLock<String> = RwLock::new({literal(a.product)}.to_owned());')
settings = {
    'custom-rendezvous-server': f'{a.server}:{a.port}',
    'relay-server': f'{a.server}:{a.port + 1}',
    'key': a.key,
    'api-server': a.api,
}
entries = ',\n'.join(f'        ({literal(k)}.to_owned(), {literal(v)}.to_owned())' for k, v in settings.items())
replace(config, r'pub static ref DEFAULT_SETTINGS: RwLock<HashMap<String, String>> = Default::default\(\);',
        'pub static ref DEFAULT_SETTINGS: RwLock<HashMap<String, String>> = RwLock::new(HashMap::from([\n' + entries + '\n    ]));')
replace('src/common.rs', r'"https://admin\.rustdesk\.com"\.to_owned\(\)', literal(a.api) + '.to_owned()')

# Exercise the production Config getters, rather than only matching source strings.
# The filter in the Linux job runs this regression test on a fresh runner profile.
f = root / config
test_assertions = '\n'.join(f'        assert_eq!(super::Config::get_option({literal(k)}), {literal(v)});' for k, v in settings.items())
f.write_text(f.read_text() + '\n#[cfg(test)]\nmod magbel_connection_tests {\n    #[test]\n    fn magbel_connection_defaults() {\n' + test_assertions + '\n        assert!(!super::Config::no_register_device());\n    }\n}\n')


for path in ('Cargo.toml', 'libs/portable/Cargo.toml', 'flutter/windows/runner/Runner.rc',
             'flutter/macos/Runner/Configs/AppInfo.xcconfig', 'flutter/lib/desktop/pages/desktop_setting_page.dart'):
    f = root / path
    text = f.read_text(encoding='utf-8')
    text = text.replace('Purslane Tech Pte. Ltd.', a.company).replace('Purslane Ltd.', a.company)
    if path in ('libs/portable/Cargo.toml', 'flutter/windows/runner/Runner.rc'):
        text = text.replace('"RustDesk Remote Desktop"', literal(a.product)).replace('"RustDesk"', literal(a.product))
    f.write_text(text, encoding='utf-8')
replace('res/rustdesk.desktop', r'(?m)^Name=RustDesk$', 'Name=' + a.product)
replace('appimage/AppImageBuilder-x86_64.yml', r'(?m)^    name: rustdesk$', '    name: ' + literal(a.product))
menu = root / 'flutter/macos/Runner/Base.lproj/MainMenu.xib'
menu.write_text(menu.read_text().replace('RustDesk', a.product))
plist = root / 'flutter/macos/Runner/Info.plist'
data = plistlib.loads(plist.read_bytes())
data['CFBundleName'] = a.product
data['CFBundleDisplayName'] = a.product
plist.write_bytes(plistlib.dumps(data, sort_keys=False))

resources = {
    'res/icon.png': 'icon.png', 'res/mac-icon.png': 'logo.png',
    'flutter/assets/icon.png': 'icon.png', 'flutter/assets/logo.png': 'logo.png',
    'flutter/assets/logo_light.png': 'compiled/logo-light.png',
    'flutter/assets/logo_dark.png': 'compiled/logo-dark.png',
    'res/icon.ico': 'compiled/icon.ico',
    'flutter/windows/runner/resources/app_icon.ico': 'compiled/icon.ico',
    'flutter/assets/icon.ico': 'compiled/icon.ico',
    'res/tray-icon.ico': 'compiled/tray-icon.ico',
    'res/mac-tray-dark-x2.png': 'compiled/mac-tray-dark-x2.png',
    'res/scalable.svg': 'compiled/icon.svg', 'flutter/assets/icon.svg': 'compiled/icon.svg',
    'res/32x32.png': 'compiled/32x32.png', 'res/64x64.png': 'compiled/64x64.png',
    'res/128x128.png': 'compiled/128x128.png', 'res/128x128@2x.png': 'compiled/256x256.png',
    'flutter/macos/Runner/AppIcon.icns': 'compiled/AppIcon.icns',
}
for target, source in resources.items():
    dest = root / target
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(branding / source, dest)
    if hashlib.sha256(dest.read_bytes()).hexdigest() != manifest[source]:
        raise RuntimeError(f'Recurso nao aplicado: {target}')

# Include a small build manifest in the Flutter bundle, used to verify final packages.
build_manifest = {'product': a.product, 'company': a.company, 'settings': settings,
                  'build_commit': os.environ.get('GITHUB_SHA', ''),
                  'resources': {target: manifest[source] for target, source in resources.items()}}
(root / 'flutter/assets/magbel-build.json').write_text(json.dumps(build_manifest, indent=2) + '\n')
print(f'Magbel: {a.product}; ID={settings["custom-rendezvous-server"]}; relay={settings["relay-server"]}; API={a.api}')
print(f'Aplicados e verificados {len(resources)} recursos de branding e quatro defaults de conexao.')
