import importlib.util, os, tempfile, unittest, json
from pathlib import Path
from unittest.mock import Mock, patch

ROOT=Path(__file__).resolve().parents[1]
os.environ['HOME_URL']='https://test.invalid'
spec=importlib.util.spec_from_file_location('managed_agent',ROOT/'facilitador-agent.py');agent=importlib.util.module_from_spec(spec);spec.loader.exec_module(agent)

class AgentTests(unittest.TestCase):
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

if __name__=='__main__':unittest.main()
