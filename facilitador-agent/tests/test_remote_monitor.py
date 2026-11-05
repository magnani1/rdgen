"""O prazo do watcher não deve interromper acompanhamento aos dez minutos."""
import tempfile
import unittest
from unittest.mock import Mock, patch
from test_agent import agent


class Watcher:
    def __init__(self, running_checks=0, code=0):
        self.running_checks = running_checks
        self.code = code
        self.kill = Mock(side_effect=self._kill)

    def _kill(self):
        self.running_checks = 0
        self.code = -9

    def poll(self):
        if self.running_checks:
            self.running_checks -= 1
            return None
        return self.code


class RemoteMonitorTests(unittest.TestCase):
    def run_remote(self, process, clock, logs=None, parametros=None):
        with tempfile.TemporaryDirectory() as root, \
             patch.object(agent, 'LOG_DIR', root), \
             patch.object(agent, 'REMOTE_TIMEOUT_SECONDS', 7200), \
             patch.object(agent, 'enviar_log') as send, \
             patch.object(agent, 'consultar_display_name', return_value='Teste'), \
             patch.object(agent.subprocess, 'Popen', return_value=process) as popen, \
             patch.object(agent.time, 'sleep'), \
             patch.object(agent.time, 'monotonic', side_effect=clock), \
             patch.object(agent, '_ler_novo_e_enviar', side_effect=logs or [(0, '')]*5):
            payload = {'alvos':['pc.tjpb.jus.br']}
            if parametros is not None:
                payload['parametros'] = parametros
            result = agent.executar_remota('teste', payload, 'KODAK.ps1')
            return result, popen.call_args.args[0], [c.args[1] for c in send.call_args_list]

    def test_runs_past_ten_minutes_and_success_text_does_not_finish_watcher(self):
        process = Watcher(running_checks=2)
        result, args, messages = self.run_remote(process, [0,700,750], [(1,'CONCLUIDO COM SUCESSO'),(1,''),(1,'')])
        self.assertTrue(result['ok'])
        process.kill.assert_not_called()
        self.assertEqual(args[-2:], ['-TimeoutSeconds','7200'])
        self.assertTrue(any('ACOMPANHAMENTO' in line for line in messages))

    def test_deadline_keeps_unknown_result_and_only_kills_local_watcher(self):
        process = Watcher(running_checks=2)
        result, _, messages = self.run_remote(process, [0,7261])
        self.assertFalse(result['ok'])
        self.assertTrue(result['uncertain'])
        process.kill.assert_called_once()
        self.assertTrue(any('somente o watcher' in line for line in messages))

    def test_failed_watcher_cannot_confirm_remote_completion(self):
        result, _, _ = self.run_remote(Watcher(code=124), [0])
        self.assertFalse(result['ok'])
        self.assertTrue(result['uncertain'])

    def test_scanner_uses_private_worker_argument_without_global_parameter_write(self):
        with patch.object(agent.subprocess, 'run') as legacy:
            result, args, _ = self.run_remote(Watcher(), [0], parametros={'NomeScanner':'EPSON-TOMBO.TJPB.JUS.BR'})
        self.assertTrue(result['ok'])
        self.assertEqual(args[-2:], ['-NomeScanner','EPSON-TOMBO.TJPB.JUS.BR'])
        legacy.assert_not_called()

    def test_empty_scanner_preserves_install_only_command(self):
        with patch.object(agent.subprocess, 'run') as legacy:
            result, args, _ = self.run_remote(Watcher(), [0], parametros={'NomeScanner':''})
        self.assertTrue(result['ok'])
        self.assertNotIn('-NomeScanner',args)
        legacy.assert_not_called()

    def test_invalid_scanner_never_starts_worker_or_legacy_write(self):
        with tempfile.TemporaryDirectory() as root, patch.object(agent, 'LOG_DIR',root), \
             patch.object(agent.subprocess,'Popen') as process, patch.object(agent.subprocess,'run') as legacy:
            for name in ('bad;whoami','bad name','http://scanner','a..b',None, ['scanner']):
                with self.subTest(name=name):
                    result=agent.executar_remota('teste',{'alvos':['pc.test'],'parametros':{'NomeScanner':name}},'DS-790WN.ps1')
                    self.assertFalse(result['ok'])
            process.assert_not_called();legacy.assert_not_called()


if __name__ == '__main__':
    unittest.main()

