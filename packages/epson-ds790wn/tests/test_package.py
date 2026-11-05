import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('builder', ROOT / 'build-package.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class PackageTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.launcher = self.root / 'signed'
        self.launcher.mkdir()
        # Synthetic EXE for archive tests only, not a signature validation test.
        (self.launcher / 'DS790WNInstall.exe').write_bytes(b'fixture-not-executable')
        for name in ('DS790WNInstall.cs', 'DS790WNInstall.manifest'):
            (self.launcher / name).write_bytes((ROOT / name).read_bytes())
        self.proof = {'version': builder.VERSION, 'signer': 'A' * 40}
        for key, name in {'exe': 'DS790WNInstall.exe', 'source': 'DS790WNInstall.cs', 'manifest': 'DS790WNInstall.manifest'}.items():
            self.proof[key + '_sha256'] = builder.sha(self.launcher / name)
        self.write_proof()
        for relative in ('work/scan2/Setup.exe', 'work/scanocr/OCRComp_v30006_21/OCRComponent.msi', 'incoming/arquivo_perfil_digitalizacao.jxz'):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'fixture')
        self.dcp = self.root / 'packages/EPSON/TJPB.Epson.DocumentCapturePro/3.3.25/x86/machine.zip'
        self.dcp.parent.mkdir(parents=True)
        with zipfile.ZipFile(self.dcp, 'w') as output:
            output.writestr('Setup.ini', '[JobSettings]\nAllUsers=1\n')
            output.writestr('arquivo_perfil_digitalizacao.jxz', b'fixture')
        with zipfile.ZipFile(self.root / 'incoming/EpsonNetConfig-4.9.11-silent.zip', 'w') as output:
            output.writestr('TjpbInstall.exe', b'fixture')
        self.old = self.root / 'packages/EPSON/TJPB.Epson.DS790WN/2026.10.6.2/x86/machine.zip'
        self.old.parent.mkdir(parents=True)
        self.old.write_bytes(b'published-release-preserve')

    def write_proof(self):
        (self.launcher / 'launcher-proof.json').write_text(json.dumps(self.proof), encoding='utf-8-sig')

    def test_new_version_preserves_old_and_is_not_published(self):
        archive, spec = builder.build(self.root, self.launcher)
        self.assertEqual(spec['sha256'], builder.sha(archive))
        self.assertEqual(self.old.read_bytes(), b'published-release-preserve')
        self.assertFalse(json.loads((archive.parent / 'release-proof.json').read_text())['published'])
        with self.assertRaises(FileExistsError):
            builder.build(self.root, self.launcher)

    def test_modified_launcher_rejected_before_release(self):
        (self.launcher / 'DS790WNInstall.exe').write_bytes(b'tampered')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            builder.build(self.root, self.launcher)

    def test_wrong_source_rejected_even_with_matching_proof(self):
        source = self.launcher / 'DS790WNInstall.cs'
        source.write_bytes(b'other-source')
        self.proof['source_sha256'] = builder.sha(source)
        self.write_proof()
        with self.assertRaisesRegex(ValueError, 'different source'):
            builder.build(self.root, self.launcher)

    def test_profile_not_silently_replaced(self):
        (self.root / 'incoming/arquivo_perfil_digitalizacao.jxz').write_bytes(b'other')
        with self.assertRaisesRegex(ValueError, 'differs'):
            builder.build(self.root, self.launcher)

    def test_path_traversal_rejected(self):
        with zipfile.ZipFile(self.dcp, 'a') as output:
            output.writestr('../escape.txt', b'bad')
        with self.assertRaisesRegex(ValueError, 'Unsafe archive'):
            builder.build(self.root, self.launcher)

    def test_cannot_target_old_version(self):
        with self.assertRaises(ValueError):
            builder.build(self.root, self.launcher, '2026.10.6.2')


if __name__ == '__main__':
    unittest.main()
