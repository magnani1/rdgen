import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('setup_assistant', Path(__file__).parents[1] / 'setup_assistant.py')
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class SetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.package = Path(self.temp.name) / 'pacote com espaços'
        self.package.mkdir()
        for name in ('instalar-agente.ps1','run-agent.ps1','facilitador-agent.py','requirements.txt','python.exe'):
            (self.package / name).touch()
        self.data = dict(pwsh='pwsh', package=self.package, home_url='https://facilitador.example.test',
                         scripts_root=r'\\server\scripts$', agent_id='app1', client_id='TJPB', slots=2,
                         python_exe=self.package/'python.exe', user_name='DOMAIN\\executor')

    def test_command_requests_credential_in_child_without_secrets(self):
        args = setup.installation_args(**self.data)
        self.assertIn('-PromptRunAsCredential', args)
        self.assertNotIn('-RunAsCredential', args)
        self.assertIn(str(self.package.resolve()/'instalar-agente.ps1'),args)
        self.assertNotIn('-Command',args)
        self.assertNotIn('Bypass',args)

    def test_rejects_invalid_inputs_and_missing_package(self):
        for change in ({'home_url':'http://plain.test'}, {'home_url':'https://user:pass@host.test'},
                       {'agent_id':'app;whoami'}, {'slots':17}, {'scripts_root':'C:\\scripts'}):
            with self.assertRaises(ValueError):
                setup.installation_args(**{**self.data, **change})
        (self.package/'run-agent.ps1').unlink()
        with self.assertRaises(ValueError):
            setup.installation_args(**self.data)

    def test_signature_validation_is_required(self):
        with patch.object(subprocess,'CREATE_NO_WINDOW',0,create=True), patch.object(subprocess,'run') as run:
            run.return_value = subprocess.CompletedProcess([],0,'{"valid":true}','')
            setup.verify_package('pwsh',self.package)
            self.assertEqual(run.call_args.kwargs['env']['MAGBEL_SETUP_PACKAGE'],str(self.package.resolve()))
            self.assertFalse(run.call_args.kwargs.get('shell',False))
            run.return_value = subprocess.CompletedProcess([],1,'','bad signature')
            with self.assertRaises(ValueError):
                setup.verify_package('pwsh',self.package)


if __name__ == '__main__':
    unittest.main()
