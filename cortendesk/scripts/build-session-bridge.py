#!/usr/bin/env python3
"""Gera a extensão sobre os arquivos 1.14.0 já verificados, sem copiar PHP antigo."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

PACKAGE = Path(__file__).resolve().parents[1]
PROVIDERS_SHA256 = 'c47d27ea8d040208089a4bf24bef635277df94dccb4a3c8d4df918a1031fb1b9'


def build(providers, webclient, destination):
    destination = Path(destination)
    if destination.exists():
        raise ValueError('Destino existente: preserve a versão instalada')
    source = Path(providers).read_text(encoding='utf-8').replace('\r\n', '\n').rstrip()+'\n'
    if hashlib.sha256(source.encode()).hexdigest() != PROVIDERS_SHA256:
        raise ValueError('bootstrap/providers.php diverge da base 1.14.0')
    source = source.replace('    ClientCliRouteServiceProvider::class,',
        '    ClientCliRouteServiceProvider::class,\n    \\App\\Providers\\MagbelSessionProvider::class,')
    view = Path(webclient).read_text(encoding='utf-8')
    if view.count('</body>') != 1 or 'magbel-session-guard' in view:
        raise ValueError('View webclient inesperada ou já modificada')
    view = view.replace('</body>', '''@isset($magbelLease)
    <script defer id="magbel-session-guard" src="/magbel-support/guard.js?v=1"
        data-session="{{ $magbelLease['id'] }}" data-expires="{{ $magbelLease['expires'] }}"></script>
@endisset
</body>''')
    shutil.copytree(PACKAGE/'session-bridge', destination)
    for name, text in [('bootstrap/providers.php', source), ('resources/views/webclient.blade.php', view)]:
        path = destination/name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding='utf-8')
    checksums = {str(path.relative_to(destination)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(destination.rglob('*')) if path.is_file()}
    (destination/'MAGBEL-SESSION-MANIFEST.json').write_text(json.dumps({'version':1, 'sha256':checksums}, indent=2)+'\n', encoding='utf-8')
    return checksums


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--providers', required=True)
    parser.add_argument('--webclient', required=True)
    parser.add_argument('--destination', required=True)
    args = parser.parse_args()
    print('Arquivos preparados:', len(build(args.providers, args.webclient, args.destination)))
