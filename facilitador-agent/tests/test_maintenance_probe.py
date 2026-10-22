import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch,Mock
import hashlib

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('maintenance_probe',ROOT/'diagnosticar-manutencao.py');p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)


class ReadonlyProbeTests(unittest.TestCase):
    def test_wrapper_pins_the_reviewed_probe(self):
        canonical=(ROOT/'diagnosticar-manutencao.py').read_text(encoding='utf-8-sig').replace('\r\n','\n').rstrip('\r\n')+'\n'
        self.assertIn(hashlib.sha256(canonical.encode()).hexdigest(),(ROOT/'diagnosticar-manutencao-remota.ps1').read_text())

    def test_only_enrolled_host_is_queried_and_unexpected_fields_are_removed(self):
        with tempfile.TemporaryDirectory() as folder,patch.object(p.subprocess,'run') as run:
            root=Path(folder);(root/'identity.json').write_text(json.dumps({'hosts':['app1.test']}))
            run.return_value=Mock(returncode=0,stdout=json.dumps({'Account':'domain\\service','HelperSignature':'Valid','Secret':'never-return','Remote':{'Ok':False,'ErrorId':'AccessDenied','credential':'never-return'}}))
            result=p.probe(root,'app1.test')
            self.assertEqual(result['Remote'],{'Ok':False,'ErrorId':'AccessDenied'})
            self.assertNotIn('Secret',result)
            args=run.call_args.args[0]
            self.assertNotIn('-ExecutionPolicy',args)
            self.assertTrue(run.call_args.kwargs['capture_output'])
            with self.assertRaises(ValueError):p.probe(root,'other.test')
            self.assertEqual(run.call_count,1)

    def test_stderr_never_appears_in_result(self):
        with tempfile.TemporaryDirectory() as folder,patch.object(p.subprocess,'run') as run:
            root=Path(folder);(root/'identity.json').write_text(json.dumps({'hosts':['app1.test']}))
            run.return_value=Mock(returncode=1,stdout='',stderr='secret-fixture')
            self.assertEqual(p.probe(root,'app1.test'),{'Ok':False,'Stage':'readonly_powershell','ExitCode':1})
