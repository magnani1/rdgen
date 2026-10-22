#!/usr/bin/env python3
"""Reaplica os deltas Magbel à base CortenDesk 1.14.0, sem reutilizar código antigo."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

PACKAGE = Path(__file__).resolve().parents[1]

def canonical(data):
    return data.replace(b'\r\n', b'\n').rstrip() + b'\n'

def brand(text, path):
    text = text.replace('Corten<span>Desk</span>', 'Magbel <span>Remote</span>')
    text = text.replace('CortenDesk', 'Magbel Remote')
    if path == 'webclient/app.js':
        text = text.replace('RustDesk Remote Console', 'Acesso Remoto Magbel')
    if path.endswith('.blade.php'):
        for asset in ('cortendesk-sm.svg','cortendesk-logo-light.svg','cortendesk-logo-dark.svg'):
            text = text.replace("asset('assets/images/"+asset+"')", "\\App\\Support\\Asset::url('assets/images/"+asset+"')")
    if path == 'app/Support/Asset.php':
        old = "        return asset($path).'?v='.config('cortendesk.api_version');"
        new = """        $publicPath = public_path(ltrim($path, '/'));
        $version = config('cortendesk.api_version');
        if (is_file($publicPath)) {
            $version .= '-'.filemtime($publicPath);
        }

        return asset($path).'?v='.$version;"""
        if text.count(old) != 1:
            raise ValueError('Método Asset::url diferente da base esperada')
        text = text.replace(old, new)
        text = text.replace('Keyed on the release version rather than filemtime:', 'Keyed on the release version and the mounted asset filemtime:')
    return text

def prepare(source, destination, assets=None, manifest_path=None):
    source, destination = Path(source), Path(destination)
    assets = Path(assets or PACKAGE/'assets')
    manifest = json.loads(Path(manifest_path or PACKAGE/'manifest.json').read_text())
    if destination.exists():
        raise ValueError('Destino já existe; use um diretório novo para preservar rollback')
    outputs = {}
    for item in manifest['files']:
        src = source/item['upstream']
        raw = src.read_bytes()
        if hashlib.sha256(canonical(raw)).hexdigest() != item['source_sha256']:
            raise ValueError('Base diverge de '+manifest['version']+': '+item['upstream'])
        outputs[item['local']] = brand(raw.decode('utf-8'), item['local']).encode('utf-8')
    for name, checksum in manifest['assets'].items():
        raw = (assets/name).read_bytes()
        if hashlib.sha256(raw).hexdigest() != checksum:
            raise ValueError('Asset Magbel diverge do pacote: '+name)
        outputs[name] = raw
    destination.mkdir(parents=True)
    for name, raw in outputs.items():
        target = destination/name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(raw)
    checksums = {name:hashlib.sha256(raw).hexdigest() for name,raw in outputs.items()}
    (destination/'MAGBEL-MANIFEST.json').write_text(json.dumps({'upstream':manifest['version'],'sha256':checksums},indent=2)+'\n')
    return checksums

if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--source',required=True,help='Diretório /app extraído da imagem nova sem inicializá-la')
    parser.add_argument('--destination',required=True)
    parser.add_argument('--manifest',default=str(PACKAGE/'manifest.json'))
    args=parser.parse_args()
    result=prepare(args.source,args.destination,manifest_path=args.manifest)
    print(f'Preparados {len(result)} arquivos de marca conferidos pelo manifesto.')

