import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
import maintenance_controller as m


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.portal=Mock()
        self.op={'id':'a'*32,'agent_id':'app1','hostname':'app1.test','previous_version':'2.0.6','target_version':'2.0.7'}
        self.remote=Mock(return_value={'Ok':True})
        self.controller=m.Controller(self.portal,['app1.test'],ROOT,remote=self.remote,pause=lambda _:None)
        self.states=[]
        self.controller.progress=lambda op,state:self.states.append(state)

    def test_source_is_pinned_and_unsigned_code_change_refused(self):
        self.assertEqual(m.source_hash(ROOT/'facilitador-agent.py'),m.SOURCE_HASH)

    def test_drain_then_apply_and_confirm(self):
        self.controller.wait=Mock(return_value=True)
        self.controller.run_operation(self.op)
        self.assertEqual(self.states,['applying','validating','completed'])
        self.remote.assert_called_once_with(self.op,'Apply','applying')

    def test_drain_timeout_never_changes_file(self):
        self.controller.wait=Mock(return_value=False)
        self.controller.run_operation(self.op)
        self.assertEqual(self.states,['failed']);self.remote.assert_not_called()

    def test_no_readiness_restores_and_leaves_drained(self):
        self.controller.wait=Mock(side_effect=[True,False,True])
        self.controller.run_operation(self.op)
        self.assertEqual(self.states,['applying','validating','rolling_back','rolled_back'])
        self.assertEqual(self.remote.call_count,2)

    def test_transport_failure_is_not_retried_or_rolled_back_blindly(self):
        self.controller.wait=Mock(return_value=True)
        self.remote.side_effect=m.FleetError('transport')
        with self.assertRaises(m.FleetError):self.controller.run_operation(self.op)
        self.assertEqual(self.states,['applying']);self.assertEqual(self.remote.call_count,1)

    def test_other_host_never_reaches_winrm(self):
        self.op['hostname']='different.test'
        with self.assertRaises(m.FleetError):self.controller.run_operation(self.op)
        self.remote.assert_not_called()

    def test_explicit_helper_failure_with_backup_rolls_back(self):
        self.controller.wait=Mock(return_value=True)
        self.remote.side_effect=[{'Ok':False,'RollbackAvailable':True},{'Ok':True}]
        self.controller.run_operation(self.op)
        self.assertEqual(self.states,['applying','rolling_back','rolled_back'])
