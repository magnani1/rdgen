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
    def run_remote(self, process, clock, logs=None):
        with tempfile.TemporaryDirectory() as root, \
             patch.object(agent, 'LOG_DIR', root), \
             patch.object(agent, 'REMOTE_TIMEOUT_SECONDS', 7200), \
             patch.object(agent, 'enviar_log') as send, \
             patch.object(agent, 'consultar_display_name', return_value='Teste'), \
             patch.object(agent.subprocess, 'Popen', return_value=process) as popen, \
             patch.object(agent.time, 'sleep'), \
             patch.object(agent.time, 'monotonic', side_effect=clock), \
             patch.object(agent, '_ler_novo_e_enviar', side_effect=logs or [(0, '')]*5):
            result = agent.executar_remota('teste', {'alvos':['pc.tjpb.jus.br']}, 'KODAK.ps1')
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


if __name__ == '__main__':
    unittest.main()
