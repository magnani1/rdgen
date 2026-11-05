import base64
import importlib.util
import json
import os
from pathlib import Path
import time
import unittest
from unittest.mock import Mock, patch

ROOT=Path(__file__).resolve().parents[1]
os.environ['HOME_URL']='https://test.invalid'
spec=importlib.util.spec_from_file_location('listing_agent',ROOT/'facilitador-agent.py')
agent=importlib.util.module_from_spec(spec);spec.loader.exec_module(agent)

class ListingTests(unittest.TestCase):
    def payload(self,profile='iot',kind=None):
        q={'profile':profile,'kind':kind or ('devices' if profile=='iot' else 'scopes'),
           'server':'srv03.tjpb.jus.br','execution_account':r'TJ-PB\facilitador-servico',
           'term':'','offset':0,'limit':25}
        q.update({'base_dn':'OU=Usuarios,OU=IOTs,DC=tjpb,DC=jus,DC=br','groups':['wifi-IoT'],'group':''}
                 if profile=='iot' else {'scopes':['10.0.1.0'],'scope':''})
        return {'client_id':'TJPB','expires':int(time.time())+120,'query':q}

    def test_only_fixed_function_and_encoded_stdin_are_used(self):
        for profile in ('iot','dhcp'):
            p=self.payload(profile)
            with patch.object(agent.platform,'system',return_value='Windows'),patch.object(agent.subprocess,'run',return_value=Mock(returncode=0,stdout='{"ok":true}')) as run:
                self.assertTrue(agent.consultar_listagem_interativa(p)['ok'])
                code=base64.b64decode(run.call_args.args[0][-1]).decode('utf-16-le')
                self.assertIn('Invoke-MagbelInteractiveList $Request',code)
                self.assertIn('[Console]::In.ReadToEnd()',code)
                self.assertNotIn('facilitador_parametros.json',code)
                self.assertEqual(json.loads(base64.b64decode(run.call_args.kwargs['input'])),p['query'])
                self.assertLess(len(run.call_args.args[0][-1]),25000)
                self.assertEqual(run.call_args.kwargs['timeout'],60)

    def test_invalid_fields_scope_group_pagination_and_profile_never_start_process(self):
        samples=[]
        for key,value in [('command','whoami'),('offset',-1),('limit',101),('term','x\n'),('kind','change'),('group','Domain Admins'),('server','srv;whoami')]:
            p=self.payload();p['query'][key]=value;samples.append(p)
        p=self.payload('dhcp','reservations');p['query']['scope']='10.1.1.0';samples.append(p)
        p=self.payload();p['query']['base_dn']='DC=tjpb,DC=jus,DC=br';samples.append(p)
        p=self.payload();p['expires']=1;samples.append(p)
        with patch.object(agent.subprocess,'run') as run:
            for p in samples:
                with self.subTest(query=p['query']):self.assertFalse(agent.consultar_listagem_interativa(p)['ok'])
            run.assert_not_called()

if __name__=='__main__':unittest.main()
