import base64
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock,patch

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
import permanent_maintenance as p


class PermanentWorkerTests(unittest.TestCase):
    def identity(self):return {'id':'maint-app4','hostname':'app4.test','hosts':['app1.test'],'client_id':'TJPB','home_url':'https://test.invalid','protected_token':base64.b64encode(b'ciphertext').decode()}

    def test_scoped_portal_maps_only_maintenance_paths(self):
        with patch.object(p,'dpapi',return_value=b'secret-fixture'):
            portal=p.ServicePortal(self.identity())
        portal.http=Mock();portal.http.request.return_value=Mock(ok=True,is_redirect=False,status_code=200)
        portal.call('POST','/admin/maintenance/controller',{'id':'a'*32})
        call=portal.http.request.call_args
        self.assertEqual(call.args[1],'https://test.invalid/fila/maintenance/controller')
        self.assertEqual(call.kwargs['headers'],{'Authorization':'Bearer secret-fixture'})
        self.assertNotIn('X-Session-Token',call.kwargs['headers'])
        for path in ('/admin/maintenance/services','/admin/agents/rotate','/executar','/owner/clients','/admin/maintenance/../agents'):
            with self.assertRaises(p.FleetError):portal.call('POST',path)
        portal.close();self.assertEqual(portal.credential,'')

    def test_revocation_is_distinguished_from_transient_failure(self):
        with patch.object(p,'dpapi',return_value=b'secret-fixture'):portal=p.ServicePortal(self.identity())
        portal.http=Mock();portal.http.request.return_value=Mock(ok=False,is_redirect=False,status_code=401)
        with self.assertRaises(p.CredentialError):portal.agents()
        portal.http.request.return_value.status_code=503
        with self.assertRaises(p.FleetError) as error:portal.agents()
        self.assertNotIsInstance(error.exception,p.CredentialError)

    def test_enrollment_stores_no_plaintext_secret_and_preserves_existing(self):
        response=Mock(ok=True,is_redirect=False);response.json.return_value={**self.identity(),'maintenance_token':'plaintext-secret-fixture'}
        with tempfile.TemporaryDirectory() as folder,patch.object(p.requests,'post',return_value=response),patch.object(p,'dpapi',return_value=b'encrypted-blob') as crypto,patch.object(p.socket,'gethostname',return_value='app4'):
            root=Path(folder);payload={'id':'maint-app4','client_id':'TJPB','home_url':'https://test.invalid','code':'one-time-fixture'}
            p.enroll(root,payload)
            text=(root/'identity.json').read_text()
            self.assertNotIn('plaintext-secret-fixture',text);self.assertNotIn('one-time-fixture',text)
            crypto.assert_called_once_with(b'plaintext-secret-fixture',protect=True)
            with self.assertRaises(p.FleetError):p.enroll(root,payload)

    def test_host_or_client_mismatch_never_persists_credential(self):
        response=Mock(ok=True,is_redirect=False);response.json.return_value={**self.identity(),'client_id':'TJPE','maintenance_token':'secret'}
        with tempfile.TemporaryDirectory() as folder,patch.object(p.requests,'post',return_value=response),patch.object(p,'dpapi') as crypto:
            root=Path(folder)
            with self.assertRaises(p.FleetError):p.enroll(root,{'id':'maint-app4','home_url':'https://test.invalid','client_id':'TJPB','code':'one-time-fixture'})
            self.assertFalse((root/'identity.json').exists());crypto.assert_not_called()

    def test_manifest_tamper_rejected_before_signature_or_execution(self):
        names={'permanent_maintenance.py','maintenance_controller.py','fleet_manager.py','setup_assistant.py','facilitador-agent.py','manutencao-agente.ps1','requirements.txt'}
        with tempfile.TemporaryDirectory() as folder,patch.object(p.subprocess,'run') as run:
            root=Path(folder);(root/'package').mkdir()
            (root/'service.json').write_text(json.dumps({'hashes':{name:'0'*64 for name in names}}))
            for name in names:(root/'package'/name).write_text('tampered')
            with self.assertRaises(p.FleetError):p.validate_bundle(root)
            run.assert_not_called()

    @unittest.skipUnless(os.name=='nt','DPAPI real exige Windows')
    def test_windows_dpapi_round_trip_and_corruption(self):
        secret=b'maintenance-test-'+os.urandom(32)
        protected=p.dpapi(secret,protect=True)
        self.assertNotEqual(protected,secret);self.assertEqual(p.dpapi(protected),secret)
        with self.assertRaises(p.FleetError):p.dpapi(protected[:8])

    def test_bad_origins_refused(self):
        for url in ('http://test.invalid','https://user:pass@test.invalid','https://test.invalid/path','https://test.invalid?key=secret'):
            with self.assertRaises(p.FleetError):p.origin(url)
