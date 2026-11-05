"""Register only the reviewed new Epson version; preserve older DB versions."""
from pathlib import Path
from datetime import datetime
import argparse
import hashlib
import json
import os
import sqlite3
import tempfile
import uuid
import zipfile

PACKAGE = 'TJPB.Epson.DS790WN'
VERSION = '2026.11.5.1'
PREVIOUS = '2026.10.6.2'
EXPECTED_SHA = '23a6771f584d5d88e7a96c51831ab3b8ab445ab47f3576fd93eed3d92c9ec0be'


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def read_spec(root):
    release = root / 'EPSON' / PACKAGE / VERSION / 'x86'
    rows = json.loads((release / 'catalog.json').read_text(encoding='utf-8'))
    if not isinstance(rows, list) or len(rows) != 1:
        raise ValueError('Expected one release specification')
    spec = rows[0]
    required = {'id': PACKAGE, 'version': VERSION, 'file': 'machine.zip', 'sha256': EXPECTED_SHA,
                'type': 'zip', 'nested_type': 'exe', 'nested_path': 'DS790WNInstall.exe',
                'silent': '/quiet', 'progress': '/quiet'}
    for key, value in required.items():
        if spec.get(key) != value:
            raise ValueError('Unexpected specification: ' + key)
    if not isinstance(spec.get('description'), str):
        raise ValueError('Description missing')
    archive = release / 'machine.zip'
    if sha(archive) != EXPECTED_SHA:
        raise ValueError('Reviewed ZIP hash mismatch')
    with zipfile.ZipFile(archive) as check:
        if check.testzip() is not None:
            raise ValueError('ZIP integrity failed')
        if 'DS790WNInstall.exe' not in check.namelist():
            raise ValueError('Launcher missing from ZIP')
    return spec


def installer_state(installer):
    return {'architecture': installer.architecture, 'type': installer.installer_type,
            'scope': installer.scope, 'file': installer.file_name, 'sha256': installer.installer_sha256,
            'nested_type': installer.nested_installer_type,
            'nested_paths': sorted(item.relative_file_path for item in installer.nested_installer_files),
            'switches': sorted((item.parameter, item.value) for item in installer.switches)}


def version_state(version):
    return {'version': version.version_code, 'default_locale': version.default_locale,
            'package_locale': version.package_locale, 'description': version.short_description,
            'installers': sorted((installer_state(i) for i in version.installers), key=lambda x: json.dumps(x, sort_keys=True))}


def expected_state(spec):
    return {'version': VERSION, 'default_locale': 'pt-BR', 'package_locale': 'pt-BR',
            'description': spec['description'], 'installers': [{
                'architecture': 'x86', 'type': 'zip', 'scope': 'machine', 'file': 'machine.zip',
                'sha256': EXPECTED_SHA, 'nested_type': 'exe', 'nested_paths': ['DS790WNInstall.exe'],
                'switches': [('Silent', '/quiet'), ('SilentWithProgress', '/quiet')]}]}


def next_catalog(catalog, spec):
    if not isinstance(catalog, list) or any(not isinstance(row, dict) for row in catalog):
        raise ValueError('Unexpected current catalog format')
    existing = [row for row in catalog if row.get('id') == PACKAGE]
    if len(existing) > 1:
        raise ValueError('Multiple active catalog records; manual review required')
    if existing and existing[0].get('version') not in (PREVIOUS, VERSION):
        raise ValueError('Current catalog version differs from the expected predecessor')
    result = [spec if row.get('id') == PACKAGE else row for row in catalog]
    if not existing:
        result.append(spec)
    return result


def atomic_catalog(path, value):
    permissions = path.stat().st_mode & 0o777
    descriptor, temporary = tempfile.mkstemp(prefix='.epson-catalog-', dir=str(path.parent))
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
            json.dump(value, stream, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, permissions)
        os.replace(temporary, str(path))
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def publish(root, apply=False):
    # Hash and archive validation happen before holding the DB write lock.
    spec = read_spec(root)
    from app import create_app, db
    from app.models import Package, PackageVersion, Installer, InstallerSwitch, NestedInstallerFile
    from sqlalchemy import text
    app = create_app()
    with app.app_context():
        if db.engine.dialect.name != 'sqlite':
            raise ValueError('This procedure requires the existing SQLite deployment')
        if apply:
            db.session.execute(text('BEGIN IMMEDIATE'))
        try:
            package = Package.query.filter_by(identifier=PACKAGE).one()
            versions = list(package.versions)
            if len({v.version_code for v in versions}) != len(versions):
                raise ValueError('Duplicate database versions; manual review required')
            if not any(v.version_code == PREVIOUS for v in versions):
                raise ValueError('Previous database version is missing')
            target = next((v for v in versions if v.version_code == VERSION), None)
            if target is not None and version_state(target) != expected_state(spec):
                raise ValueError('Target version already exists with different metadata; preserved')
            old = {v.version_code: version_state(v) for v in versions if v.version_code != VERSION}
            catalog_path = root / 'catalog.json'
            original = catalog_path.read_bytes()
            current = json.loads(original.decode('utf-8'))
            replacement = next_catalog(current, spec)
            result = {'package': PACKAGE, 'version': VERSION, 'sha256': EXPECTED_SHA,
                      'action': 'add_version' if target is None else 'verify_existing',
                      'previous_versions': sorted(old), 'dry_run': not apply}
            if not apply:
                db.session.rollback()
                return result
            if target is not None and current == replacement:
                db.session.rollback()
                result.update({'registered': True, 'catalog_updated': False, 'unchanged': True})
                return result
            backup = Path(app.instance_path) / ('epson-registration-' + datetime.utcnow().strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8])
            backup.mkdir(mode=0o700)
            db_path = db.engine.url.database
            if not db_path or not Path(db_path).is_file():
                raise ValueError('Database file was not found')
            with sqlite3.connect(db_path) as source, sqlite3.connect(str(backup / 'database.db')) as destination:
                source.backup(destination)
                if destination.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
                    raise ValueError('Database backup integrity check failed')
            (backup / 'catalog.json').write_bytes(original)
            if target is None:
                target = PackageVersion(version_code=VERSION, default_locale='pt-BR', package_locale='pt-BR', short_description=spec['description'])
                installer = Installer(architecture='x86', installer_type='zip', scope='machine', file_name='machine.zip', installer_sha256=EXPECTED_SHA)
                installer.nested_installer_type = 'exe'
                installer.nested_installer_files.append(NestedInstallerFile(relative_file_path='DS790WNInstall.exe'))
                for parameter in ('Silent', 'SilentWithProgress'):
                    installer.switches.append(InstallerSwitch(parameter=parameter, value='/quiet'))
                target.installers.append(installer)
                package.versions.append(target)
            db.session.flush()
            if any(version_state(v) != old[v.version_code] for v in versions if v.version_code != VERSION):
                raise ValueError('Previous database version unexpectedly changed')
            if version_state(target) != expected_state(spec):
                raise ValueError('New version metadata did not match the reviewed specification')
            # Commit DB first. If catalog update fails, a safe retry recognizes the
            # exact DB version and repairs only the catalog; it never overwrites it.
            db.session.commit()
            try:
                atomic_catalog(catalog_path, replacement)
            except Exception as error:
                raise RuntimeError('DB version registered, but catalog update failed. Backup: ' + str(backup) + '. Safe to rerun this same procedure.') from error
            result.update({'registered': True, 'catalog_updated': True, 'backup': str(backup), 'unchanged': False})
            return result
        except Exception:
            db.session.rollback()
            raise


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--packages-root', type=Path, default=Path('/app/app/packages'))
    parser.add_argument('--apply', action='store_true', help='Back up and register the reviewed new version')
    args = parser.parse_args()
    print(json.dumps(publish(args.packages_root, apply=args.apply), ensure_ascii=False))
