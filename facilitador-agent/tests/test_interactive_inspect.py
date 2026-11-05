import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
os.environ['HOME_URL'] = 'https://test.invalid'
spec = importlib.util.spec_from_file_location('interactive_agent', ROOT/'facilitador-agent.py')
agent = importlib.util.module_from_spec(spec); spec.loader.exec_module(agent)


class InteractiveInspectTests(unittest.TestCase):
    def payload(self, profile='dhcp'):
        query = {'profile': profile, 'server': 'srv02.tjpb.jus.br',
                 'execution_account': r'TJ-PB\facilitador-servico', 'macs': ['021122334455']}
        query.update({'scope': '10.0.1.0', 'ips': []} if profile == 'dhcp' else {
            'base_dn': 'OU=Usuarios,OU=IOTs,OU=TJPB,DC=tjpb,DC=jus,DC=br', 'groups': ['wifi-IoT']})
        return {'query': query, 'client_id': 'TJPB', 'expires': int(time.time())+120}

    def test_data_are_encoded_and_no_shared_file_or_credential_prompt(self):
        for profile in ('dhcp', 'iot'):
            with self.subTest(profile=profile), patch.object(agent.platform, 'system', return_value='Windows'), patch.object(agent.subprocess, 'run', return_value=Mock(returncode=0, stdout='{"ok":true}')) as run:
                result = agent.consultar_estado_interativo(self.payload(profile))
                self.assertTrue(result['ok'])
                argv = run.call_args.args[0]
                self.assertIn('-NonInteractive', argv)
                self.assertEqual(run.call_args.kwargs['timeout'], 60)
                code = base64.b64decode(argv[-1]).decode('utf-16-le')
                self.assertNotIn('facilitador_parametros.json', code)
                self.assertNotIn('Get-Credential', code)
                self.assertNotIn('TJ-PB\\facilitador-servico', code)
                self.assertIn('FromBase64String', code)

    def test_extra_fields_ldap_filters_bad_server_scope_and_expiry_are_rejected(self):
        samples = []
        for field, value in [('command', 'whoami'), ('server', 'srv;whoami'), ('scope', '::1'), ('execution_account', 'admin')]:
            p = self.payload(); p['query'][field] = value; samples.append(p)
        p = self.payload('iot'); p['query']['groups'] = ['*)(objectClass=*)']; samples.append(p)
        p = self.payload(); p['expires'] = 1; samples.append(p)
        p = self.payload(); p['client_id'] = 'TJPE'; samples.append(p)
        with patch.object(agent.subprocess, 'run') as run:
            for p in samples: self.assertFalse(agent.consultar_estado_interativo(p)['ok'])
            run.assert_not_called()

    def test_timeout_process_error_bad_output_and_unavailable_platform_do_not_mean_absence(self):
        with patch.object(agent.platform, 'system', return_value='Windows'):
            with patch.object(agent.subprocess, 'run', side_effect=subprocess.TimeoutExpired('powershell', 60)):
                self.assertEqual(agent.consultar_estado_interativo(self.payload())['code'], 'query_timeout')
            for output, code in [('[]',0), ('',1), ('not-json',0), ('{"ok":true}'*10000,0)]:
                with patch.object(agent.subprocess, 'run', return_value=Mock(returncode=code, stdout=output)):
                    self.assertFalse(agent.consultar_estado_interativo(self.payload())['ok'])
        with patch.object(agent.platform, 'system', return_value='Linux'):
            self.assertEqual(agent.consultar_estado_interativo(self.payload())['code'], 'windows_required')


if __name__ == '__main__': unittest.main()
