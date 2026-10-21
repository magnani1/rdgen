import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import os

PACKAGE=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('brand_v114',PACKAGE/'scripts/brand_v114.py')
brand=importlib.util.module_from_spec(spec);spec.loader.exec_module(brand)

class BrandingTests(unittest.TestCase):
    def test_brand_changes_text_without_removing_code(self):
        source='public static function consumeTotp() {} // CortenDesk\nCorten<span>Desk</span>'
        result=brand.brand(source,'app/Support/TwoFactor.php')
        self.assertIn('public static function consumeTotp() {}',result)
        self.assertIn('Magbel <span>Remote</span>',result)

    def test_asset_version_uses_release_and_mount_timestamp(self):
        result=brand.brand("        return asset($path).'?v='.config('cortendesk.api_version');",'app/Support/Asset.php')
        self.assertIn("config('cortendesk.api_version')",result)
        self.assertIn('filemtime($publicPath)',result)

    def test_other_asset_implementation_is_rejected(self):
        with self.assertRaises(ValueError):brand.brand('outro código','app/Support/Asset.php')

    def test_manifest_has_exactly_23_sources_and_five_assets(self):
        data=json.loads((PACKAGE/'manifest.json').read_text())
        self.assertEqual(len(data['files']),23)
        self.assertEqual(len(data['assets']),5)
        self.assertTrue(all('..' not in x['upstream'] for x in data['files']))

    def test_divergent_source_is_rejected_before_destination_created(self):
        with tempfile.TemporaryDirectory() as tmp:
            source=Path(tmp)/'source';source.mkdir();dest=Path(tmp)/'out'
            item=json.loads((PACKAGE/'manifest.json').read_text())['files'][0]
            target=source/item['upstream'];target.parent.mkdir(parents=True);target.write_text('alterado')
            with self.assertRaises(ValueError):brand.prepare(source,dest)
            self.assertFalse(dest.exists())

    @unittest.skipUnless(os.environ.get('CORTEN_UPSTREAM_FIXTURE'),'Defina CORTEN_UPSTREAM_FIXTURE para testar os arquivos reais da imagem/tag')
    def test_upstream_fixture_preserves_new_methods_and_marks_all_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            out=Path(tmp)/'prepared'
            checks=brand.prepare(os.environ['CORTEN_UPSTREAM_FIXTURE'],out)
            self.assertEqual(len(checks),28)
            self.assertIn('function consumeTotp',(out/'app/Support/TwoFactor.php').read_text())
            notifications=(out/'app/Services/AppriseNotifications.php').read_text()
            self.assertIn('function retryDue',notifications)
            self.assertIn('function forScheduler',notifications)
            self.assertIn('backup.completed',notifications)
            self.assertIn('Magbel Remote',(out/'views/auth/login.blade.php').read_text())
            self.assertNotIn('<<<<<<<',(out/'views/layouts/app.blade.php').read_text())
            with self.assertRaises(ValueError):brand.prepare(os.environ['CORTEN_UPSTREAM_FIXTURE'],out)

if __name__=='__main__':unittest.main()
