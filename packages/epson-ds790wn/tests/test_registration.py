import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import types
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('register_epson', ROOT / 'register-version.py')
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class CatalogTest(unittest.TestCase):
    def test_only_active_record_changes(self):
        other = {'id': 'Other.Package', 'version': '1', 'extra': ['preserve']}
        catalog = [other, {'id': publisher.PACKAGE, 'version': publisher.PREVIOUS}]
        new = {'id': publisher.PACKAGE, 'version': publisher.VERSION}
        result = publisher.next_catalog(catalog, new)
        self.assertEqual(result, [other, new])
        self.assertEqual(catalog[1]['version'], publisher.PREVIOUS)

    def test_unexpected_current_or_duplicate_record_rejected(self):
        for catalog in ([{'id': publisher.PACKAGE, 'version': '2030.1'}],
                        [{'id': publisher.PACKAGE, 'version': publisher.PREVIOUS}] * 2):
            with self.assertRaises(ValueError):
                publisher.next_catalog(catalog, {})

    def test_atomic_catalog(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'catalog.json'
            path.write_text('[]')
            publisher.atomic_catalog(path, [{'id': 'new'}])
            self.assertEqual(json.loads(path.read_text()), [{'id': 'new'}])
            self.assertEqual(list(Path(folder).glob('.epson-catalog-*')), [])


@unittest.skipUnless(os.environ.get('EPSON_ORM_TESTS') == '1', 'Real ORM tests enabled in Linux CI')
class RegistrationTest(unittest.TestCase):
    def setUp(self):
        from flask import Flask
        from flask_sqlalchemy import SQLAlchemy
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        instance = self.root / 'instance'
        instance.mkdir()
        self.app = Flask('epson-test', instance_path=str(instance))
        self.app.config.update(SQLALCHEMY_DATABASE_URI='sqlite:///' + str(instance / 'database.db'), SQLALCHEMY_TRACK_MODIFICATIONS=False)
        db = self.db = SQLAlchemy(self.app)

        class Package(db.Model):
            id = db.Column(db.Integer, primary_key=True)
            identifier = db.Column(db.String, unique=True)
            name = db.Column(db.String)
            versions = db.relationship('PackageVersion', cascade='all, delete-orphan')

        class PackageVersion(db.Model):
            id = db.Column(db.Integer, primary_key=True)
            package_id = db.Column(db.Integer, db.ForeignKey('package.id'))
            version_code = db.Column(db.String)
            default_locale = db.Column(db.String)
            package_locale = db.Column(db.String)
            short_description = db.Column(db.String)
            installers = db.relationship('Installer', cascade='all, delete-orphan')

        class Installer(db.Model):
            id = db.Column(db.Integer, primary_key=True)
            version_id = db.Column(db.Integer, db.ForeignKey('package_version.id'))
            architecture = db.Column(db.String)
            installer_type = db.Column(db.String)
            scope = db.Column(db.String)
            file_name = db.Column(db.String)
            installer_sha256 = db.Column(db.String)
            nested_installer_type = db.Column(db.String)
            switches = db.relationship('InstallerSwitch', cascade='all, delete-orphan')
            nested_installer_files = db.relationship('NestedInstallerFile', cascade='all, delete-orphan')

        class InstallerSwitch(db.Model):
            id = db.Column(db.Integer, primary_key=True)
            installer_id = db.Column(db.Integer, db.ForeignKey('installer.id'))
            parameter = db.Column(db.String)
            value = db.Column(db.String)

        class NestedInstallerFile(db.Model):
            id = db.Column(db.Integer, primary_key=True)
            installer_id = db.Column(db.Integer, db.ForeignKey('installer.id'))
            relative_file_path = db.Column(db.String)

        self.Package, self.Version = Package, PackageVersion
        self.Installer = Installer
        app_module = types.ModuleType('app')
        app_module.create_app = lambda: self.app
        app_module.db = db
        models = types.ModuleType('app.models')
        for cls in (Package, PackageVersion, Installer, InstallerSwitch, NestedInstallerFile):
            setattr(models, cls.__name__, cls)
        patcher = mock.patch.dict(sys.modules, {'app': app_module, 'app.models': models})
        patcher.start()
        self.addCleanup(patcher.stop)
        with self.app.app_context():
            db.create_all()
            package = Package(identifier=publisher.PACKAGE, name='Epson')
            old = PackageVersion(version_code=publisher.PREVIOUS, default_locale='pt-BR', package_locale='pt-BR', short_description='old-preserve')
            old.installers.append(Installer(architecture='x86', installer_type='zip', scope='machine', file_name='machine.zip', installer_sha256='old-sha', nested_installer_type='exe'))
            package.versions.append(old)
            db.session.add(package)
            db.session.commit()
            self.old_state = publisher.version_state(old)
        release = self.root / 'EPSON' / publisher.PACKAGE / publisher.VERSION / 'x86'
        release.mkdir(parents=True)
        archive = release / 'machine.zip'
        with zipfile.ZipFile(archive, 'w') as output:
            output.writestr('DS790WNInstall.exe', b'synthetic-fixture-not-an-executable')
        patcher = mock.patch.object(publisher, 'EXPECTED_SHA', publisher.sha(archive))
        patcher.start()
        self.addCleanup(patcher.stop)
        release_spec = {'id': publisher.PACKAGE, 'version': publisher.VERSION, 'description': 'new-test',
                        'sha256': publisher.EXPECTED_SHA, 'file': 'machine.zip', 'type': 'zip',
                        'nested_type': 'exe', 'nested_path': 'DS790WNInstall.exe', 'silent': '/quiet', 'progress': '/quiet'}
        (release / 'catalog.json').write_text(json.dumps([release_spec]))
        self.catalog = self.root / 'catalog.json'
        self.original = json.dumps([{'id': 'Other.Package', 'version': '1'}, {'id': publisher.PACKAGE, 'version': publisher.PREVIOUS}]).encode()
        self.catalog.write_bytes(self.original)

    def target_count(self):
        with self.app.app_context():
            return self.Version.query.filter_by(version_code=publisher.VERSION).count()

    def test_dry_run_makes_no_changes(self):
        result = publisher.publish(self.root)
        self.assertTrue(result['dry_run'])
        self.assertEqual(self.target_count(), 0)
        self.assertEqual(self.catalog.read_bytes(), self.original)
        self.assertEqual(list((self.root / 'instance').glob('epson-registration-*')), [])

    def test_apply_preserves_previous_and_has_verified_backup(self):
        result = publisher.publish(self.root, apply=True)
        self.assertEqual(self.target_count(), 1)
        with self.app.app_context():
            old = self.Version.query.filter_by(version_code=publisher.PREVIOUS).one()
            self.assertEqual(publisher.version_state(old), self.old_state)
        backup = Path(result['backup'])
        self.assertEqual((backup / 'catalog.json').read_bytes(), self.original)
        with sqlite3.connect(str(backup / 'database.db')) as db:
            self.assertEqual(db.execute('PRAGMA integrity_check').fetchone()[0], 'ok')
            self.assertEqual(db.execute('SELECT count(*) FROM package_version WHERE version_code=?', (publisher.VERSION,)).fetchone()[0], 0)
        self.assertEqual(json.loads(self.catalog.read_text())[0], {'id': 'Other.Package', 'version': '1'})

    def test_repeat_is_unchanged(self):
        publisher.publish(self.root, apply=True)
        result = publisher.publish(self.root, apply=True)
        self.assertTrue(result['unchanged'])
        self.assertEqual(self.target_count(), 1)

    def test_existing_different_version_rejected(self):
        publisher.publish(self.root, apply=True)
        with self.app.app_context():
            target = self.Version.query.filter_by(version_code=publisher.VERSION).one()
            target.installers[0].installer_sha256 = 'different'
            self.db.session.commit()
        before = self.catalog.read_bytes()
        with self.assertRaisesRegex(ValueError, 'different metadata'):
            publisher.publish(self.root, apply=True)
        self.assertEqual(self.catalog.read_bytes(), before)

    def test_commit_failure_leaves_db_and_catalog_unchanged(self):
        with mock.patch.object(self.db.session, 'commit', side_effect=RuntimeError('fixture commit failure')):
            with self.assertRaises(RuntimeError):
                publisher.publish(self.root, apply=True)
        self.assertEqual(self.target_count(), 0)
        self.assertEqual(self.catalog.read_bytes(), self.original)

    def test_catalog_failure_can_resume_without_duplicate_db_version(self):
        with mock.patch.object(publisher, 'atomic_catalog', side_effect=OSError('fixture disk failure')):
            with self.assertRaisesRegex(RuntimeError, 'DB version registered'):
                publisher.publish(self.root, apply=True)
        self.assertEqual(self.target_count(), 1)
        self.assertEqual(self.catalog.read_bytes(), self.original)
        result = publisher.publish(self.root, apply=True)
        self.assertEqual(result['action'], 'verify_existing')
        self.assertTrue(result['catalog_updated'])
        self.assertEqual(self.target_count(), 1)

    def test_archive_hash_failure_does_not_write_database(self):
        archive = self.root / 'EPSON' / publisher.PACKAGE / publisher.VERSION / 'x86/machine.zip'
        archive.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            publisher.publish(self.root, apply=True)
        self.assertEqual(self.target_count(), 0)
