import base64,copy,importlib.util,json,os,time,unittest
from pathlib import Path
from unittest.mock import Mock,patch
ROOT=Path(__file__).resolve().parents[1];os.environ['HOME_URL']='https://test.invalid'
spec=importlib.util.spec_from_file_location('iot_action_agent',ROOT/'facilitador-agent.py');agent=importlib.util.module_from_spec(spec);spec.loader.exec_module(agent)
class IotActionsTests(unittest.TestCase):
    def payload(self,phase='plan'):
        return {'client_id':'TJPB','expires':int(time.time())+300,'query':{'profile':'iot','phase':phase,'server':'srv03.test','execution_account':r'TJ-PB\facilitador-servico','base_dn':'OU=Usuarios,OU=IOTs,DC=tjpb,DC=jus,DC=br','group_base_dn':'OU=Grupos,OU=IOTs,DC=tjpb,DC=jus,DC=br','groups':['wifi-IoT','VOIP'],'action':'MIGRAR','records':[{'mac':'021122334455','description':'','group':'VOIP'}],'expected':[] if phase=='plan' else [{'mac':'021122334455','fingerprint':'a'*64}]}}
    def test_fixed_script_stdin_and_windows_command_limit(self):
        p=self.payload()
        with patch.object(agent.platform,'system',return_value='Windows'),patch.object(agent.subprocess,'run',return_value=Mock(returncode=0,stdout='{"ok":true}')) as run:
            self.assertTrue(agent.executar_iot(p,'plan')['ok']);args=run.call_args
            self.assertLess(len(args.args[0][-1]),30000)
            code=base64.b64decode(args.args[0][-1]).decode('utf-16-le');self.assertIn('Invoke-MagbelIotAction $Request',code)
            self.assertNotIn(p['query']['execution_account'],code)
            self.assertEqual(json.loads(base64.b64decode(args.kwargs['input'])),p['query']);self.assertEqual(args.kwargs['timeout'],180)
    def test_invalid_requests_never_launch_powershell(self):
        samples=[]
        for k,v in [('groups',None),('groups',['Senha_Simples']),('action',[]),('action','EXEC'),('base_dn','DC=tjpb'),('group_base_dn','DC=tjpb'),('records',[{'mac':[]}]),('records',[]),('expected',[{}]),('server','srv;whoami')]:
            p=self.payload();p['query'][k]=v;samples.append(p)
        for k,v in [('mac','021122334455;whoami'),('mac','ffffffffffff'),('group','Domain Admins'),('description','a\nb')]:
            p=self.payload();p['query']['records'][0][k]=v;samples.append(p)
        p=self.payload('apply');p['query']['expected']=[{'mac':[],'fingerprint':'a'*64}];samples.append(p)
        with patch.object(agent.subprocess,'run') as run:
            for p in samples:
                with self.subTest(q=p['query']):self.assertFalse(agent.executar_iot(p,p['query']['phase'])['ok'])
            run.assert_not_called()
    def test_apply_timeout_is_unknown_but_transport_rejection_is_not(self):
        p=self.payload('apply')
        with patch.object(agent.platform,'system',return_value='Windows'),patch.object(agent.subprocess,'run',side_effect=agent.subprocess.TimeoutExpired('powershell',180)):
            self.assertTrue(agent.executar_iot(p,'apply')['uncertain'])
        p['query']['expected']=[];self.assertFalse(agent.executar_iot(p,'apply')['uncertain'])
if __name__=='__main__':unittest.main()
