import base64
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import unittest
from unittest.mock import Mock,patch

ROOT=Path(__file__).resolve().parents[1]
os.environ.setdefault('HOME_URL','https://test.invalid')
spec=importlib.util.spec_from_file_location('session_agent',ROOT/'facilitador-agent.py')
agent=importlib.util.module_from_spec(spec);spec.loader.exec_module(agent)


class WindowsSessionsTests(unittest.TestCase):
    def setUp(self):
        self.names=patch.object(agent,'consultar_nomes_sessoes',return_value={}).start()
        self.addCleanup(patch.stopall)
    def response(self,**extra):return {'computer':'PC-A','sessions':[{'id':1,'account':'TEST\\alice','state':'active'},{'id':2,'account':'TEST\\bob','state':'disconnected'}],**extra}
    def test_sessions_preserve_multiple_accounts_and_strip_unknown_fields(self):
        data=self.response();data['sessions'][0]['password']='private-fixture'
        with patch.object(agent.subprocess,'run',return_value=Mock(returncode=0,stdout=json.dumps(data))) as run:
            result=agent.consultar_sessoes_windows('pc-a.test')
        self.assertTrue(result['ok']);self.assertEqual(len(result['sessions']),2)
        self.assertNotIn('private-fixture',json.dumps(result))
        command=base64.b64decode(run.call_args.args[0][-1]).decode('utf-16-le')
        self.assertIn('-Authentication Kerberos',command);self.assertIn('WTSFreeMemory',command)
        self.assertNotIn('Stop-Computer',command);self.assertNotIn('WTSLogoffSession',command)

    def test_display_name_is_added_without_replacing_windows_account(self):
        self.names.return_value={'test\\alice':'Álice de Souza'}
        with patch.object(agent.subprocess,'run',return_value=Mock(returncode=0,stdout=json.dumps(self.response()))):
            result=agent.consultar_sessoes_windows('pc-a.test')
        self.assertEqual(result['sessions'][0]['display_name'],'Álice de Souza')
        self.assertEqual(result['sessions'][0]['account'],'TEST\\alice')
        self.assertNotIn('display_name',result['sessions'][1])

    def test_errors_wrong_host_duplicates_and_invalid_accounts_are_not_empty_success(self):
        for data in (None,self.response(computer='other'),self.response(sessions=[{'id':1,'account':'bad\nname','state':'active'}]),self.response(sessions=self.response()['sessions']*2)):
            with patch.object(agent.subprocess,'run',return_value=Mock(returncode=0,stdout=json.dumps(data))):
                result=agent.consultar_sessoes_windows('pc-a.test')
            self.assertFalse(result['ok']);self.assertNotIn('sessions',result)
        with patch.object(agent.subprocess,'run',side_effect=subprocess.TimeoutExpired('pwsh',40)):
            self.assertFalse(agent.consultar_sessoes_windows('pc-a.test')['ok'])
        with patch.object(agent.subprocess,'run') as run:
            self.assertFalse(agent.consultar_sessoes_windows('pc-a;Stop-Computer')['ok']);run.assert_not_called()

    def test_successful_empty_enumeration_is_distinct_from_failure(self):
        with patch.object(agent.subprocess,'run',return_value=Mock(returncode=0,stdout=json.dumps(self.response(sessions=[])))):
            result=agent.consultar_sessoes_windows('pc-a.test')
        self.assertTrue(result['ok']);self.assertEqual(result['sessions'],[])

    @unittest.skipUnless(os.name=='nt','Parser PowerShell e compilador C# nativos do Windows')
    def test_native_powershell_parser_and_wts_wrapper_compile_without_remote_execution(self):
        original=subprocess.run
        with patch.object(agent.subprocess,'run',return_value=Mock(returncode=0,stdout='null')) as run:
            agent.consultar_sessoes_windows('pc-a.test')
        command=base64.b64decode(run.call_args.args[0][-1]).decode('utf-16-le')
        definition=re.search("Add-Type -TypeDefinition @'\n(.*?)\n'@",command,re.S).group(1)
        script="$s=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"+base64.b64encode(command.encode()).decode()+"'));$t=$null;$e=$null;[System.Management.Automation.Language.Parser]::ParseInput($s,[ref]$t,[ref]$e)|Out-Null;if($e.Count){exit 2};Add-Type -TypeDefinition ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"+base64.b64encode(definition.encode()).decode()+"'))) -ErrorAction Stop"
        result=original(['powershell.exe','-NoProfile','-NonInteractive','-EncodedCommand',base64.b64encode(script.encode('utf-16-le')).decode()],capture_output=True,timeout=40)
        self.assertEqual(result.returncode,0)


class SessionNamesTests(unittest.TestCase):
    def test_lookup_is_batched_scoped_and_names_are_bound_to_returned_accounts(self):
        rows=[{'account':'TEST\\alice','display_name':'Álice de Souza'},
              {'account':'TEST\\other','display_name':'Pessoa alheia'},
              {'account':'TEST\\bob','display_name':'bad\nname'}]
        with patch.object(agent.subprocess,'run',return_value=Mock(returncode=0,stdout=json.dumps(rows))) as run:
            names=agent.consultar_nomes_sessoes([{'account':'TEST\\alice'},{'account':'TEST\\bob'}])
        self.assertEqual(names,{'test\\alice':'Álice de Souza'})
        command=base64.b64decode(run.call_args.args[0][-1]).decode('utf-16-le')
        self.assertIn('Get-ADDomain',command);self.assertIn('$Domain.NetBIOSName',command)
        self.assertIn('-SearchBase $Domain.DistinguishedName',command);self.assertIn('Escape-Ldap',command)
        self.assertEqual(run.call_count,1)

    def test_directory_failures_do_not_invent_names(self):
        for response in (Mock(returncode=1,stdout=''),Mock(returncode=0,stdout='null'),Mock(returncode=0,stdout='[]')):
            with patch.object(agent.subprocess,'run',return_value=response):
                self.assertEqual(agent.consultar_nomes_sessoes([{'account':'TEST\\alice'}]),{})
        with patch.object(agent.subprocess,'run',side_effect=subprocess.TimeoutExpired('pwsh',15)):
            self.assertEqual(agent.consultar_nomes_sessoes([{'account':'TEST\\alice'}]),{})

if __name__=='__main__':unittest.main()
