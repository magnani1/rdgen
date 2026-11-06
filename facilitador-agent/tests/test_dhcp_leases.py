import base64,importlib.util,json,os,time,unittest
from pathlib import Path
from unittest.mock import Mock,patch
ROOT=Path(__file__).resolve().parents[1]
os.environ['HOME_URL']='https://test.invalid'
spec=importlib.util.spec_from_file_location('lease_agent',ROOT/'facilitador-agent.py');agent=importlib.util.module_from_spec(spec);spec.loader.exec_module(agent)
class LeaseTests(unittest.TestCase):
    def payload(self):
        return {'client_id':'TJPB','expires':int(time.time())+300,'query':{'profile':'dhcp','kind':'leases','server':'srv02.tjpb.jus.br',
                'execution_account':r'TJ-PB\facilitador-servico','term':'SEDE153729','offset':0,'limit':25,'scopes':[], 'scope':'','discover_scopes':True}}
    def test_fixed_script_encoded_stdin_and_bounded_timeout(self):
        p=self.payload()
        with patch.object(agent.platform,'system',return_value='Windows'),patch.object(agent.subprocess,'run',return_value=Mock(returncode=0,stdout='{"ok":true}')) as run:
            self.assertTrue(agent.consultar_listagem_interativa(p)['ok']);args=run.call_args
            code=base64.b64decode(args.args[0][-1]).decode('utf-16-le');self.assertIn('Invoke-MagbelActiveLeases $Request',code)
            self.assertNotIn('Get-DhcpServerv4Reservation',code);self.assertLess(len(args.args[0][-1]),30000)
            self.assertEqual(args.kwargs['timeout'],180);self.assertEqual(json.loads(base64.b64decode(args.kwargs['input'])),p['query'])
    def test_invalid_policies_and_input_never_launch(self):
        samples=[]
        for k,v in [('discover_scopes','true'),('scope','10.6.96.0'),('scopes',['10.6.96.0']),('offset',-1),('limit',51),('command','whoami'),('execution_account','admin'),('server','server;whoami')]:
            p=self.payload();p['query'][k]=v;samples.append(p)
        p=self.payload();p['expires']=1;samples.append(p)
        with patch.object(agent.subprocess,'run') as run:
            for p in samples:self.assertFalse(agent.consultar_concessoes_ativas(p)['ok'])
            run.assert_not_called()
    def test_585_explicit_scopes_supported(self):
        p=self.payload();p['query'].update(discover_scopes=False,scopes=[f'10.{i//256}.{i%256}.0' for i in range(585)])
        with patch.object(agent.platform,'system',return_value='Windows'),patch.object(agent.subprocess,'run',return_value=Mock(returncode=0,stdout='{"ok":true}')):
            self.assertTrue(agent.consultar_concessoes_ativas(p)['ok'])
if __name__=='__main__':unittest.main()
