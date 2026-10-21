import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0,str(Path(__file__).parents[1]))
spec=importlib.util.spec_from_file_location('fleet',Path(__file__).parents[1]/'fleet_manager.py')
fleet=importlib.util.module_from_spec(spec);spec.loader.exec_module(fleet)


def agent(**values):
    return dict(id='app3',desired='drain',heartbeat=None,running=0,inventory_writer=False,ready=False,**values)


class FleetTests(unittest.TestCase):
    def config(self,**values):
        data=dict(home_url='https://facilitador.test',scripts_root=r'\\server\scripts$',client_id='TJPB',slots=2,
                  hosts=['app3.example.test'],apply=False,activate=False,python_exe=r'C:\Program Files\Python314\python.exe')
        return argparse.Namespace(**{**data,**values})

    def test_targets_and_validation(self):
        self.assertEqual(fleet.validate(self.config()),[('app3.example.test','app3')])
        for hosts in (['app3;whoami'],['192.168.1.3'],['app3','app3.example.test'],['*.example.test'],['-command']):
            with self.assertRaises(fleet.FleetError):fleet.targets(hosts)
        for values in ({'home_url':'http://plain.test'},{'home_url':'https://user:pass@host.test'},
                       {'home_url':'https://host.test/subpath'},{'slots':0},{'activate':True},{'scripts_root':'C:\\scripts'}):
            with self.assertRaises(fleet.FleetError):fleet.validate(self.config(**values))

    def test_contract_limits_and_existing_identity_are_preserved(self):
        contract=dict(client_id='TJPB',configured=True,accepting_jobs=True,contract={'max_agents':3,'modules':'["execucao","suporte"]'})
        current=dict(client_id='TJPB',agents=[{**agent(),'id':'app1','desired':'active'},{**agent(),'id':'app2','desired':'active'}])
        hosts=[('app3.example.test','app3')]
        fleet.check_contract(contract,current,'TJPB',hosts,True)
        with self.assertRaises(fleet.FleetError):fleet.check_contract(contract,current,'TJPB',hosts+[('app4','app4')],True)
        for changes in ({'desired':'active'},{'heartbeat':1},{'running':1},{'inventory_writer':True}):
            existing={'client_id':'TJPB','agents':[{**agent(),**changes}]}
            with self.assertRaises(fleet.FleetError):fleet.check_contract(contract,existing,'TJPB',hosts,False)
        for change in ({'client_id':'TJPE'},{'accepting_jobs':False},{'configured':False},{'contract':None}):
            with self.assertRaises(fleet.FleetError):fleet.check_contract({**contract,**change},current,'TJPB',hosts,False)

    def test_credentials_only_in_stdin_and_no_shell_execution(self):
        response=subprocess.CompletedProcess([],0,'MAGBEL_FLEET:{"ok":true,"installed":true}\n','')
        with patch.object(fleet.subprocess,'run',return_value=response) as run:
            fleet.remote('pwsh',Path('signed package'),'app3','app3',self.config(), 'CODE-PRIVATE','DOMAIN\\executor','PASSWORD-PRIVATE')
        args=run.call_args.args[0];kwargs=run.call_args.kwargs
        self.assertNotIn('CODE-PRIVATE',' '.join(args));self.assertNotIn('PASSWORD-PRIVATE',' '.join(args))
        self.assertNotIn('-Command',args);self.assertNotIn('Bypass',args);self.assertFalse(kwargs.get('shell',False))
        self.assertEqual(json.loads(kwargs['input'])['code'],'CODE-PRIVATE')
        self.assertEqual(json.loads(kwargs['input'])['password'],'PASSWORD-PRIVATE')

    def test_raw_remote_errors_do_not_leak(self):
        response=subprocess.CompletedProcess([],1,'','SECRET-RAW-ERROR')
        with patch.object(fleet.subprocess,'run',return_value=response):
            with self.assertRaises(fleet.FleetError) as error:
                fleet.remote('pwsh',Path('package'),'app3','app3',self.config())
        self.assertNotIn('SECRET',str(error.exception))

    def test_readiness_cannot_be_old_degraded_or_changed_policy(self):
        good={**agent(),'ready':True,'heartbeat':100,'running':0}
        portal=Mock();portal.agents.return_value={'agents':[good]}
        with patch.object(fleet.time,'time',return_value=100),patch.object(fleet.time,'monotonic',side_effect=[0,1]):
            self.assertEqual(fleet.wait_ready(portal,'app3',90),good)
        for change in ({'ready':False},{'heartbeat':10},{'desired':'revoked'},{'running':1}):
            portal.agents.return_value={'agents':[{**good,**change}]}
            with patch.object(fleet.time,'time',return_value=100),patch.object(fleet.time,'sleep'),patch.object(fleet.time,'monotonic',side_effect=[0,1,121]):
                with self.assertRaises(fleet.FleetError):fleet.wait_ready(portal,'app3',90)

    def test_login_uses_mfa_and_closes_own_session(self):
        portal=fleet.Portal('https://facilitador.test')
        portal.job=Mock(side_effect=[{'status':'concluido','resultado':{'otp_necessario':True,'transaction_id':'tx'}},
                                    {'status':'concluido','token':'session-private','tem_admin':True}])
        portal.call=Mock(return_value={})
        with patch('builtins.input',return_value='admin'),patch.object(fleet,'secret',side_effect=['password','123456']):portal.login()
        self.assertEqual(portal.job.call_args_list[1].args[1]['transaction_id'],'tx')
        portal.close();self.assertEqual(portal.token,'')
        portal.call.assert_called_with('POST','/session/logout')

    def test_inspect_never_creates_portal_session_or_registration(self):
        with patch.object(fleet.sys,'platform','win32'),patch.object(fleet.shutil,'which',return_value='pwsh'),patch.object(fleet,'verify_package'),patch.object(fleet,'remote',return_value={'ok':True,'python':'3.14','existing_task':False,'existing_runtime':False}),patch.object(fleet,'Portal') as portal:
            self.assertEqual(fleet.main(['--hosts','app3','--package','.']),0)
        portal.assert_not_called()

    def test_installation_failure_never_activates_and_closes_session(self):
        contract=dict(client_id='TJPB',configured=True,accepting_jobs=True,contract={'max_agents':3,'modules':['execucao']})
        portal=Mock();portal.agents.return_value={'client_id':'TJPB','agents':[]}
        portal.call.side_effect=lambda method,path,body=None: contract if path=='/admin/contract' else {'enrollment_code':'private-code'}
        report={'ok':True,'python':'3.14','existing_task':False,'existing_runtime':False}
        with patch.object(fleet.sys,'platform','win32'),patch.object(fleet.shutil,'which',return_value='pwsh'),patch.object(fleet,'verify_package'),patch.object(fleet,'Portal',return_value=portal),patch.object(fleet,'remote',side_effect=[report,fleet.FleetError('install failed')]),patch('builtins.input',return_value='DOMAIN\\executor'),patch.object(fleet,'secret',return_value='private-password'):
            with self.assertRaises(fleet.FleetError):fleet.main(['--hosts','app3','--package','.','--apply','--activate'])
        self.assertFalse(any(c.args[0]=='PATCH' for c in portal.call.call_args_list))
        portal.close.assert_called_once()

    def test_activation_rechecks_contract_and_freshness_without_changing_capabilities(self):
        contract=dict(client_id='TJPB',configured=True,accepting_jobs=True,contract={'max_agents':3,'modules':['execucao']})
        ready={**agent(),'heartbeat':100,'ready':True,'slots':2,'pool':'default','capabilities':['auth','ad','winrm']}
        current={'client_id':'TJPB','agents':[ready]}
        policy=fleet.activation_policy(contract,current,'TJPB','app3',100)
        self.assertEqual(policy,{'desired':'active','slots':2,'pool':'default','capabilities':['auth','ad','winrm'],'inventory_writer':False})
        for changed in ({**contract,'accepting_jobs':False},{**contract,'contract':{'max_agents':0,'modules':['execucao']}},{**contract,'contract':{'max_agents':3,'modules':['suporte']}}):
            with self.assertRaises(fleet.FleetError):fleet.activation_policy(changed,current,'TJPB','app3',100)
        for changes in ({'heartbeat':10},{'desired':'revoked'},{'running':1},{'ready':False}):
            with self.assertRaises(fleet.FleetError):fleet.activation_policy(contract,{'client_id':'TJPB','agents':[{**ready,**changes}]},'TJPB','app3',100)
