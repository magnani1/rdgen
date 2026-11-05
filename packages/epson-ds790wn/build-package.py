"""Stage a NEW Epson release. Never registers or replaces an existing package."""
from pathlib import Path, PurePosixPath
import argparse
import hashlib
import json
import re
import shutil
import zipfile

VERSION = '2026.11.5.1'
PACKAGE = 'TJPB.Epson.DS790WN'


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def safe_name(name):
    path = PurePosixPath(name.replace('\\', '/'))
    if path.is_absolute() or '..' in path.parts or ':' in name:
        raise ValueError('Unsafe archive member: ' + name)
    return str(path)


def append_zip(output, archive, prefix):
    with zipfile.ZipFile(archive) as source:
        for info in source.infolist():
            name = safe_name(info.filename)
            if not info.is_dir():
                with source.open(info) as src, output.open(prefix + '/' + name, 'w') as dst:
                    shutil.copyfileobj(src, dst, 1024 * 1024)


def build(root, launcher, version=VERSION):
    if version != VERSION:
        raise ValueError('This reviewed source requires version ' + VERSION)
    proof = json.loads((launcher / 'launcher-proof.json').read_text(encoding='utf-8-sig'))
    if proof.get('version') != version or not re.fullmatch(r'[a-fA-F0-9]{40}', proof.get('signer', '')):
        raise ValueError('Missing build/signature evidence from the Windows signing station')
    files = {'exe': 'DS790WNInstall.exe', 'source': 'DS790WNInstall.cs', 'manifest': 'DS790WNInstall.manifest'}
    for key, name in files.items():
        if sha(launcher / name) != proof.get(key + '_sha256'):
            raise ValueError('Build evidence hash mismatch: ' + name)
    for name in ('DS790WNInstall.cs', 'DS790WNInstall.manifest'):
        if (launcher / name).read_text(encoding='utf-8-sig') != Path(__file__).with_name(name).read_text(encoding='utf-8-sig'):
            raise ValueError('Launcher was built from a different source: ' + name)
    scan = root / 'work/scan2'
    ocr = root / 'work/scanocr/OCRComp_v30006_21'
    dcp = root / 'packages/EPSON/TJPB.Epson.DocumentCapturePro/3.3.25/x86/machine.zip'
    net = root / 'incoming/EpsonNetConfig-4.9.11-silent.zip'
    profile = root / 'incoming/arquivo_perfil_digitalizacao.jxz'
    for path in (scan / 'Setup.exe', ocr / 'OCRComponent.msi', dcp, net, profile):
        if not path.is_file():
            raise ValueError('Required input missing: ' + str(path))
    destination = root / 'packages/EPSON' / PACKAGE / version / 'x86'
    if destination.exists():
        raise FileExistsError('Release already exists; preserved: ' + str(destination))
    destination.mkdir(parents=True)
    archive = destination / 'machine.next.zip'
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, allowZip64=True) as output:
        for name in files.values():
            output.write(launcher / name, name)
        for source, prefix in ((scan, 'Scan2'), (ocr, 'ScanOCR')):
            for path in sorted(source.rglob('*')):
                if path.is_file():
                    output.write(path, prefix + '/' + path.relative_to(source).as_posix())
        append_zip(output, dcp, 'DCP')
        append_zip(output, net, 'EpsonNet')
    with zipfile.ZipFile(archive) as check:
        if check.testzip() is not None:
            raise ValueError('Archive integrity failed')
        if 'AllUsers=1' not in check.read('DCP/Setup.ini').decode('utf-8-sig'):
            raise ValueError('DCP AllUsers profile configuration missing')
        if check.read('DCP/arquivo_perfil_digitalizacao.jxz') != profile.read_bytes():
            raise ValueError('DCP profile differs from institutional input')
    archive = archive.rename(destination / 'machine.zip')
    spec = {'id': PACKAGE, 'name': 'Epson-DS-790WN', 'version': version,
            'description': 'Componentes ausentes e cadastro DNS opcional; preserva instalacoes compativeis.',
            'file': 'machine.zip', 'sha256': sha(archive), 'type': 'zip',
            'nested_type': 'exe', 'nested_path': 'DS790WNInstall.exe', 'silent': '/quiet', 'progress': '/quiet'}
    (destination / 'catalog.json').write_text(json.dumps([spec], indent=2) + '\n', encoding='utf-8')
    evidence = {'version': version, 'launcher': proof,
                'inputs': {str(path.relative_to(root)): sha(path) for path in (dcp, net, profile)},
                'archive_sha256': spec['sha256'], 'published': False}
    (destination / 'release-proof.json').write_text(json.dumps(evidence, indent=2) + '\n', encoding='utf-8')
    return archive, spec


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path('/dados/docker/winget'))
    parser.add_argument('--launcher', type=Path, required=True)
    args = parser.parse_args()
    archive, spec = build(args.root, args.launcher)
    print(json.dumps({'archive': str(archive), 'sha256': spec['sha256'], 'published': False}))
