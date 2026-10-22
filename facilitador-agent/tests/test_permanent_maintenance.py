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

class ConnectivityTests(unittest.TestCase):
    def test_unreachable_port_does_not_attempt_authentication(self):
        with patch.object(p.socket,'create_connection',side_effect=OSError),patch.object(p.subprocess,'run') as run:
            result=p.probe_connectivity('app1.test')
        self.assertFalse(result['tcp']);self.assertIsNone(result['kerberos']);self.assertIsNone(result['admin']);run.assert_not_called()

    def test_readonly_probe_reports_separate_authentication_and_admin(self):
        from unittest.mock import MagicMock
        with patch.object(p.socket,'create_connection',return_value=MagicMock()),patch.object(p.subprocess,'run',return_value=Mock(returncode=0,stdout='{"kerberos":true,"admin":false,"secret":"must-not-appear"}')) as run:
            result=p.probe_connectivity('app1.test')
        self.assertTrue(result['tcp']);self.assertTrue(result['kerberos']);self.assertFalse(result['admin']);self.assertNotIn('secret',result)
        script=base64.b64decode(run.call_args.args[0][-1]).decode('utf-16-le')
        self.assertIn('-Authentication Kerberos',script)
        for command in ('Enable-PSRemoting','Stop-ScheduledTask','Set-ExecutionPolicy','Get-Content'):
            self.assertNotIn(command,script)

    def test_timeout_is_not_reported_as_success_and_stderr_is_not_exposed(self):
        from unittest.mock import MagicMock
        import subprocess
        with patch.object(p.socket,'create_connection',return_value=MagicMock()),patch.object(p.subprocess,'run',side_effect=subprocess.TimeoutExpired('pwsh',25,stderr='private')):
            result=p.probe_connectivity('app1.test')
        self.assertTrue(result['tcp']);self.assertIsNone(result['kerberos']);self.assertNotIn('private',str(result))

    def test_invalid_host_is_refused_before_network_access(self):
        with patch.object(p.socket,'create_connection') as connect:
            with self.assertRaises(p.FleetError):p.probe_connectivity('app1;whoami')
            connect.assert_not_called()

    def test_failed_preflight_never_invokes_the_update(self):
        controller=p.PermanentController(Mock(),{'hostname':'app4.test','hosts':['app1.test']},Path('.'))
        controller.progress=Mock()
        report={'hostname':'app1.test','checked_at':int(p.time.time()),'tcp':False,'kerberos':None,'admin':None}
        with patch.object(p,'probe_connectivity',return_value=report),patch.object(p.Controller,'run_operation') as update:
            controller.run_operation({'id':'a'*32,'agent_id':'app1','hostname':'app1.test','target_version':p.VERSION})
        update.assert_not_called();controller.progress.assert_called_once()
        self.assertEqual(controller.progress.call_args.args[1],'failed')
        self.assertEqual(controller.diagnostics['app1.test'],report)

class RuntimeInventoryTests(unittest.TestCase):
    def sample(self):return {'python_version':'3.15.1','python_bits':64,'implementation':'CPython','packages':[{'name':'requests','version':'2.34.2'}]}

    def test_runtime_probe_filters_fields_and_uses_only_managed_interpreter(self):
        data={**self.sample(),'identity':'must-not-appear','PSComputerName':'fixture'}
        with patch.object(p.subprocess,'run',return_value=Mock(returncode=0,stdout=json.dumps(data))) as run:
            result=p.probe_runtime('app1.test')
        self.assertEqual(result,self.sample())
        script=base64.b64decode(run.call_args.args[0][-1]).decode('utf-16-le')
        self.assertIn('AGENT_PYTHON',script);self.assertIn('ReparsePoint',script);self.assertIn('RuntimeOutsideRoot',script)
        self.assertIn('& $Python -I -c $Query',script)
        for command in ('pip install','Start-ScheduledTask','Stop-ScheduledTask','Set-ExecutionPolicy'):
            self.assertNotIn(command,script)

    def test_runtime_query_failure_or_duplicate_metadata_never_becomes_complete(self):
        duplicate=self.sample();duplicate['packages']*=2
        for output in ('null',json.dumps(duplicate),'invalid',json.dumps({**self.sample(),'python_bits':True})):
            with patch.object(p.subprocess,'run',return_value=Mock(returncode=0,stdout=output)):
                self.assertIsNone(p.probe_runtime('app1.test'))
        with patch.object(p.subprocess,'run',side_effect=p.subprocess.TimeoutExpired('pwsh',40,stderr='private')):
            self.assertIsNone(p.probe_runtime('app1.test'))

    @unittest.skipUnless(os.name=='nt','Parser PowerShell nativo exige Windows nesta suíte')
    def test_generated_inventory_script_parses_without_executing_remoting(self):
        with patch.object(p.subprocess,'run',return_value=Mock(returncode=0,stdout='null')) as run:p.probe_runtime('app1.test')
        encoded=run.call_args.args[0][-1]
        parser="$Text=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('"+encoded+"'));$Tokens=$null;$Errors=$null;[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$Tokens,[ref]$Errors)|Out-Null;if($Errors.Count){exit 1}"
        result=p.subprocess.run(['pwsh','-NoProfile','-NonInteractive','-EncodedCommand',base64.b64encode(parser.encode('utf-16-le')).decode()],capture_output=True,timeout=30)
        self.assertEqual(result.returncode,0)
