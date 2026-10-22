import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

SCRIPTS=Path(__file__).resolve().parents[1]/'scripts'
sys.path.insert(0,str(SCRIPTS))
import update_vps as update


class UpdateTests(unittest.TestCase):
    def test_portainer_internal_compose_resolves_to_host_volume(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);file=root/'compose/17/docker-compose.yml';file.parent.mkdir(parents=True);file.write_text('services: {}')
            self.assertEqual(update.native_file('/data/compose/17/docker-compose.yml',[{'Mounts':[{'Source':str(root),'Destination':'/data'}]}]),file.resolve())
            with self.assertRaises(update.UpdateError):update.native_file('/data/compose/99/missing.yml',[])

    def test_patch_preserves_interpolation_and_unrelated_settings(self):
        source='services:\n  cortendesk:\n    image: old:1.14.0\n    environment:\n      CORTENDESK_RDGEN_URL: ${CORTENDESK_RDGEN_URL}\n    volumes:\n      - /opt/branding-1.14.0/app/file.php:/app/file.php:ro\n'
        result=update.patch_sources([source],'old:1.14.0','new:1.15.0@sha256:fixed',{Path('/opt/branding-1.14.0'):Path('/opt/branding-1.15.0')})[0]
        self.assertIn('${CORTENDESK_RDGEN_URL}',result)
        self.assertIn('/opt/branding-1.15.0/app/file.php:/app/file.php:ro',result)
        self.assertIn('new:1.15.0@sha256:fixed',result)
        with self.assertRaises(update.UpdateError):update.patch_sources([source,source],'old:1.14.0','new',{})
        with self.assertRaises(update.UpdateError):update.patch_sources(['image: ${IMAGE}'],'old:1.14.0','new',{})

    def test_drift_is_rejected_and_matching_environment_not_exposed(self):
        config={'services':{'cortendesk':{'image':'old','restart':'unless-stopped','container_name':'support','environment':{'RDGEN':'fixture-secret'},'networks':{'net':{}},'volumes':[{'type':'bind','source':'/opt/data','target':'/data'}],'ports':[{'target':21116,'published':'21116','protocol':'udp'}]}},'networks':{'net':{'name':'external'}}}
        live={'Name':'/support','Mounts':[{'Type':'bind','Source':'/opt/data','Destination':'/data','RW':True}],'Config':{'Image':'old','Env':['RDGEN=fixture-secret']},'NetworkSettings':{'Networks':{'external':{}}},'HostConfig':{'RestartPolicy':{'Name':'unless-stopped'},'PortBindings':{'21116/udp':[{'HostIp':'','HostPort':'21116'}]}}}
        update.check_live(config,'cortendesk',live)
        live['Config']['Env']=['RDGEN=changed-secret']
        with self.assertRaises(update.UpdateError) as error:update.check_live(config,'cortendesk',live)
        self.assertNotIn('fixture-secret',str(error.exception));self.assertNotIn('changed-secret',str(error.exception))
        live['Config']['Env']=['RDGEN=fixture-secret'];live['HostConfig']['PortBindings']={}
        with self.assertRaises(update.UpdateError):update.check_live(config,'cortendesk',live)

    def test_atomic_file_replacement_and_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'compose.yml';p.write_bytes(b'old');p.chmod(0o640)
            update.atomic_write(p,b'new')
            self.assertEqual(p.read_bytes(),b'new');self.assertEqual(p.stat().st_mode&0o777,0o640)

    def test_new_manifest_keeps_critical_upstream_changes(self):
        root=SCRIPTS.parent
        manifest=json.loads((root/'manifest-1.15.0.json').read_text())
        self.assertEqual(manifest['version'],'1.15.0')
        self.assertEqual(len(manifest['files']),23)
        old=json.loads((root/'manifest.json').read_text())
        changes={a['upstream'] for a,b in zip(manifest['files'],old['files']) if a['source_sha256']!=b['source_sha256']}
        self.assertEqual(changes,{'app/Services/AppriseNotifications.php','resources/views/livewire/settings-page.blade.php'})


if __name__=='__main__':unittest.main()
