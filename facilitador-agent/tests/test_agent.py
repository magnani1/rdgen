import importlib.util, os, tempfile, unittest, json
from pathlib import Path
from unittest.mock import Mock, patch

ROOT=Path(__file__).resolve().parents[1]
os.environ['HOME_URL']='https://test.invalid'
spec=importlib.util.spec_from_file_location('managed_agent',ROOT/'facilitador-agent.py');agent=importlib.util.module_from_spec(spec);spec.loader.exec_module(agent)

class AgentTests(unittest.TestCase):
    def test_heartbeat_reports_actual_runtime_without_paths_or_secrets(self):
        response=Mock();response.json.return_value={'desired':'drain','slots':2,'capabilities':['winrm'],'inventory_writer':False,'renewed':[]}
        with patch.object(agent,'api',return_value=response) as request,patch.object(agent.time,'sleep',side_effect=InterruptedError),patch.object(agent,'RUNNING',{}):
            with self.assertRaises(InterruptedError):agent.heartbeat_loop()
        payload=request.call_args.kwargs['json']
        self.assertEqual(payload['python_version'],agent.platform.python_version())
        self.assertEqual(payload['python_bits'],agent.sys.maxsize.bit_length()+1)
        self.assertEqual(payload['requests_version'],agent.requests.__version__)
        self.assertEqual(payload['version'],'2.0.5')
        self.assertRegex(payload['boot_id'],r'^[a-f0-9]{32}$')
        self.assertEqual(payload['boot_id'],agent.BOOT_ID)
        self.assertEqual(set(agent.runtime_versions()),{'python_version','python_bits','requests_version'})

    def test_callback_uses_attempt_token(self):
        agent.AGENT_TOKEN='identity-secret';agent.RUNNING['job']='attempt-secret';context=agent.CURRENT_JOB.set('job')
        try:
            with patch.object(agent.requests,'request',return_value=Mock(status_code=200)) as request:
                agent.api('POST','https://test.invalid/fila/log/job',json={'linha':'ok'})
                self.assertEqual(request.call_args.kwargs['headers']['X-Execution-Token'],'attempt-secret')
                self.assertEqual(request.call_args.kwargs['headers']['Authorization'],'Bearer identity-secret')
        finally:agent.CURRENT_JOB.reset(context);agent.RUNNING.clear()

    def test_download_is_bound_to_job(self):
        agent.RUNNING['job']='attempt-secret';context=agent.CURRENT_JOB.set('job')
        try:
            with patch.object(agent.requests,'request',return_value=Mock(status_code=200)) as request:
                agent.api('GET','https://test.invalid/download/a.csv')
                self.assertEqual(request.call_args.kwargs['params'],{'job_id':'job'})
        finally:agent.CURRENT_JOB.reset(context);agent.RUNNING.clear()

    def test_enrollment_is_saved_and_not_repeated(self):
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(agent,'STATE_DIR',Path(temp)),patch.object(agent,'TOKEN_FILE',Path(temp)/'identity.json'),patch.dict(os.environ,{'AGENT_ENROLLMENT_CODE':'test-once'}):
                response=Mock();response.json.return_value={'agent_id':'app1','client_id':'TJPB','agent_token':'test-token'}
                with patch.object(agent.requests,'post',return_value=response) as post:
                    agent.carregar_identidade();agent.carregar_identidade();self.assertEqual(post.call_count,1)
                    self.assertEqual(agent.AGENT_TOKEN,'test-token');self.assertNotIn('AGENT_ENROLLMENT_CODE',os.environ)

    def test_wrong_client_or_backend_identity_is_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'identity.json';path.write_text(json.dumps({'agent_id':'app1','client_id':'TJPE','agent_token':'a','home_url':agent.HOME_URL}))
            with patch.object(agent,'STATE_DIR',Path(temp)),patch.object(agent,'TOKEN_FILE',path):
                with self.assertRaises(RuntimeError):agent.carregar_identidade()

    def test_readiness_detects_absent_runtime(self):
        with patch.object(agent.shutil,'which',return_value=None),patch.object(agent.os.path,'isdir',return_value=False),patch.object(agent.os.path,'isfile',return_value=False):
            ready,diagnostic=agent.prontidao();self.assertFalse(ready);self.assertIn('pwsh ausente',diagnostic)

    def test_stop_waits_for_local_work_and_server_ack(self):
        try:
            agent.RUNNING['job']='token'
            with patch.object(agent,'api') as api:
                self.assertFalse(agent.comunicar_saida());api.assert_not_called()
            agent.RUNNING.clear()
            with patch.object(agent,'api') as api:
                api.return_value.json.return_value={'ok':True,'desired':'stop'}
                self.assertTrue(agent.comunicar_saida())
                self.assertTrue(api.call_args.args[1].endswith('/fila/stopped'))
                api.return_value.json.return_value={'ok':False}
                self.assertFalse(agent.comunicar_saida())
        finally:agent.RUNNING.clear()

    def test_stop_exits_polling_cleanly_without_new_work(self):
        with patch.object(agent,'carregar_identidade'),patch.object(agent,'IDENTITY',{'agent_id':'app1'}),patch.object(agent,'DESIRED','stop'),patch.object(agent.threading,'Thread'),patch.object(agent,'comunicar_saida',return_value=True),patch.object(agent,'EXEC_POOL') as pool,patch.object(agent,'enviar_inventario') as inventory,patch.object(agent,'api') as api:
            agent.loop();pool.shutdown.assert_called_once_with(wait=True)
            inventory.assert_not_called();api.assert_not_called()

if __name__=='__main__':unittest.main()


