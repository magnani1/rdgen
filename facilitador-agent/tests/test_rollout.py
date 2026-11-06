"""Atualização usa os locks existentes e só segue após confirmação do executor."""
import importlib.util
from pathlib import Path
import sys
import time
import unittest
from unittest.mock import Mock
root=Path(__file__).resolve().parents[1];sys.path.insert(0,str(root))
spec=importlib.util.spec_from_file_location('rollout',root/'atualizar-frota.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)


class RolloutTests(unittest.TestCase):
    def setUp(self):
        self.agents=[{'id':v,'hostname':v+'.test','desired':'active','ready':True,'heartbeat':int(time.time()),
            'version':'2.0.13','boot_id':'before'} for v in ('app1','app2')]
        self.operations=[];self.requested=[];self.outcome='completed'
        self.portal=Mock()
        self.portal.agents.side_effect=lambda:{'client_id':'TJPB','agents':self.agents}
        self.portal.call.side_effect=self.call

    def call(self,method,path,body=None):
        if method=='POST':
            name=path.rsplit('/',1)[1];self.requested.append(name)
            op={'id':'operation-'+name,'state':self.outcome};self.operations.append(op)
            if self.outcome=='completed':
                a=next(a for a in self.agents if a['id']==name);a.update(version='2.0.14',boot_id='after')
            return {'id':op['id']}
        return {'version':'2.0.14','operations':self.operations,'controllers':[
            {'versions':['2.0.14'],'heartbeat':int(time.time()),'hosts':['app1.test','app2.test']}]}

    def test_sequential_updates_and_repetition_skips_confirmed_agents(self):
        m.rollout(self.portal,['app1','app2'])
        self.assertEqual(self.requested,['app1','app2'])
        m.rollout(self.portal,['app1','app2'])
        self.assertEqual(self.requested,['app1','app2'])

    def test_unknown_result_blocks_next_agent_and_retry(self):
        self.outcome='unknown'
        with self.assertRaises(m.FleetError):m.rollout(self.portal,['app1','app2'])
        self.assertEqual(self.requested,['app1'])
        with self.assertRaises(m.FleetError):m.rollout(self.portal,['app1','app2'])
        self.assertEqual(self.requested,['app1'])

    def test_rollback_or_failed_update_stops_fleet(self):
        for state in ('rolled_back','failed','cancelled'):
            self.setUp();self.outcome=state
            with self.subTest(state=state),self.assertRaises(m.FleetError):
                m.rollout(self.portal,['app1','app2'])
            self.assertEqual(self.requested,['app1'])

    def test_one_unready_target_blocks_entire_fleet_before_first_write(self):
        self.agents[1]['ready']=False
        with self.assertRaises(m.FleetError):m.rollout(self.portal,['app1','app2'])
        self.assertEqual(self.requested,[])

if __name__=='__main__':unittest.main()
