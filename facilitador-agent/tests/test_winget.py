"""Despacho, argumentos, etapas, detecção e timeout sem tocar máquinas reais."""
import base64
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import Mock, patch

ROOT=Path(__file__).resolve().parents[1]
os.environ.setdefault('HOME_URL','https://test.invalid')
spec=importlib.util.spec_from_file_location('winget_agent',ROOT/'facilitador-agent.py')
agent=importlib.util.module_from_spec(spec);spec.loader.exec_module(agent)

class WingetAgentTests(unittest.TestCase):
    def setUp(self):
        self.job='a'*8+'-'+'b'*4+'-'+'c'*4+'-'+'d'*4+'-'+'e'*12
        self.payload={'engine':'winget.v1','client_id':'TJPB','alvos':['pc-a.test'],'winget':{'action':'install','agreements':True,'revision':'f'*64,
          'source':{'name':'TJPB','type':'Microsoft.Rest','url':'https://packages.invalid/v1'},
          'package':{'package_id':'TJPB.Test','version':'1.2.3','scope':'machine','architecture':'x64','detection_name':'Test App','detection_version':'1.2.3'}}}
    def run_remote(self,result=None,extra=''):
        if result is None: result={'ok':True,'uncertain':False,'job_id':self.job,'client_id':'TJPB','hostname':'pc-a.test','code':'installed_verified','detected':True}
        output=extra+'MAGBEL_WINGET_EVENT:'+json.dumps({'stage':'installing'})+'\nMAGBEL_WINGET_RESULT:'+json.dumps(result)+'\n'
        process=Mock(stdout=io.StringIO(output));process.poll.return_value=0
        with patch.object(agent.subprocess,'Popen',return_value=process) as run,patch.object(agent,'enviar_log') as log:
            value=agent.executar_winget(self.job,self.payload)
        self.sent=json.loads(process.stdin.write.call_args.args[0])
        return value,base64.b64decode(run.call_args.args[0][-1]).decode('utf-16-le'),log
    def test_typed_payload_and_progress_do_not_reuse_old_script_executor(self):
        value,script,log=self.run_remote(extra='private native text must not reach web\n')
        self.assertTrue(value['ok']);self.assertIn('[WinGet] installing',str(log.call_args_list))
        self.assertNotIn('private native text',str(log.call_args_list))
        self.assertLess(len(base64.b64encode(script.encode('utf-16-le'))),30000)
        self.assertIn('[Console]::In.ReadToEnd()',script)
        self.assertIn('-Authentication Kerberos',script);self.assertIn('-ConfigurationName Microsoft.PowerShell',script)
        for denied in ('--force','--ignore-security-hash','source add','source reset','-ExecutionPolicy','Restart-Computer'):
            self.assertNotIn(denied,script)
        self.assertIn('Get-AppxPackage -Name Microsoft.DesktopAppInstaller',script)
        self.assertIn('source_mismatch',script);self.assertIn('system_cli_unsupported',script)
        with patch.object(agent,'executar_winget',return_value={'ok':True}) as native,patch.object(agent,'resolver_script') as old:
            agent.executar(self.job,self.payload);native.assert_called_once();old.assert_not_called()
    def test_long_unicode_plan_uses_stdin_not_windows_command_line(self):
        self.payload['winget']['package']['notes']='Á'*1000
        self.payload['winget']['package']['detection_name']='É'*160
        result,script,_=self.run_remote()
        self.assertTrue(result['ok'])
        self.assertNotIn('notes',self.sent['package'])
        self.assertEqual(self.sent['package']['detection_name'],'É'*160)
        self.assertNotIn('É'*160,script)
        self.assertLess(len(base64.b64encode(script.encode('utf-16-le'))),30000)

    def test_invalid_or_cross_client_plan_never_launches_process(self):
        for changes in ({'client_id':'TJPE'},{'alvos':['pc-a;whoami']},{'alvos':['pc-a','pc-b']}):
            with patch.object(agent.subprocess,'Popen') as run:
                result=agent.executar_winget(self.job,{**self.payload,**changes})
                self.assertFalse(result['ok']);run.assert_not_called()
        self.payload['winget']['agreements']=False
        with patch.object(agent.subprocess,'Popen') as run:
            self.assertFalse(agent.executar_winget(self.job,self.payload)['ok']);run.assert_not_called()
    def test_transport_loss_and_wrong_response_are_unknown_not_safe_to_repeat(self):
        result,_,_=self.run_remote({'ok':True,'uncertain':False,'job_id':'wrong','hostname':'pc-a.test','client_id':'TJPB'})
        self.assertTrue(result['uncertain'])
        with patch.object(agent.subprocess,'Popen',side_effect=OSError('private')):
            result=agent.executar_winget(self.job,self.payload)
        self.assertTrue(result['uncertain']);self.assertNotIn('private',str(result))
    def test_install_failure_after_start_preserves_uncertainty(self):
        result,script,_=self.run_remote({'ok':False,'uncertain':True,'job_id':self.job,'client_id':'TJPB','hostname':'pc-a.test','code':'installation_not_confirmed'})
        self.assertTrue(result['uncertain']);self.assertIn('WinGet:',result['erro'])
        self.assertIn('$Attempted=$true',script)
        self.assertIn('$Install.exit_code -eq 0 -and $Result.detected',script)
        self.assertIn('HKLM:\\SOFTWARE\\WOW6432Node',script)
        self.assertIn("throw 'operation_already_seen'",script)
    @unittest.skipUnless(os.name=='nt','Parser PowerShell nativo exige Windows')
    def test_native_powershell_parser(self):
        _,script,_=self.run_remote()
        encoded=base64.b64encode(script.encode('utf-8')).decode('ascii')
        code="$s=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"+encoded+"'));$t=$null;$e=$null;[System.Management.Automation.Language.Parser]::ParseInput($s,[ref]$t,[ref]$e)|Out-Null;if($e.Count){$e|Out-String|Write-Error;exit 1}"
        process=subprocess.run(['pwsh','-NoProfile','-NonInteractive','-EncodedCommand',base64.b64encode(code.encode('utf-16-le')).decode('ascii')],capture_output=True,text=True,timeout=30)
        self.assertEqual(process.returncode,0,process.stderr)

if __name__=='__main__':unittest.main()
