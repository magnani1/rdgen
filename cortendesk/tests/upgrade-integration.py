#!/usr/bin/env python3
"""CI descartável: upgrade real 1.14→1.15, idempotência e rollback; sem portas públicas."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sqlite3
import sys
import tempfile
import uuid

PACKAGE=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(PACKAGE/'scripts'))
import update_vps as update
from brand_v114 import prepare


def main():
    if os.geteuid()!=0: raise RuntimeError('CI: executar com sudo para simular permissões da VPS.')
    os.umask(0o077)
    workspace=Path(tempfile.mkdtemp(prefix='magbel-v115-ci-'))
    project='magbel-v115-'+uuid.uuid4().hex[:10]
    name=project+'-support'
    root=workspace/'opt';root.mkdir();(root/'data').mkdir();(root/'data').chmod(0o777)
    # Diretório descartável dentro de workspace 0700; permite o UID da imagem
    # inicializar SQLite/cache sem supor o UID numérico de www-data.
    for relative in ('storage/framework/cache/data','storage/framework/sessions','storage/framework/views','storage/logs'):
        directory=root/'data'/relative;directory.mkdir(parents=True,exist_ok=True)
        for parent in [directory,*directory.parents]:
            if parent==root/'data':break
            parent.chmod(0o777)
    updater=update.Updater(root,name);updater.project=project;updater.service='cortendesk'
    compose=workspace/'compose.yaml';updater.files=[compose];updater.env=dict(os.environ)
    source=None
    try:
        updater.docker('pull','ghcr.io/marcpope/cortendesk:1.14.0')
        source=updater.docker('create','--entrypoint','/bin/true','ghcr.io/marcpope/cortendesk:1.14.0').decode().strip()
        upstream=workspace/'upstream';upstream.mkdir()
        manifest=json.loads((PACKAGE/'manifest.json').read_text())
        for item in manifest['files']+[{'upstream':'bootstrap/providers.php'}]:
            target=upstream/item['upstream'];target.parent.mkdir(parents=True,exist_ok=True)
            updater.docker('cp',source+':/app/'+item['upstream'],str(target))
        brand=root/'branding-1.14.0';ext=root/'session-bridge-1.0.0'
        prepare(upstream,brand)
        update.bridge.build(upstream/'bootstrap/providers.php',brand/'views/webclient.blade.php',ext)
        for directory in (brand,ext):
            for path in [directory,*directory.rglob('*')]:path.chmod(0o755 if path.is_dir() else 0o644)
        key='base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
        (root/'data/.app_key').write_text(key)
        (root/'data/rustdesk').mkdir()
        (root/'data/rustdesk/id_ed25519').write_text('fixture-private-key-preserve')
        volumes=[{'type':'bind','source':str(root/'data'),'target':'/data'}]
        volumes += [{'type':'bind','source':str(path),'target':target,'read_only':True} for target,path in update.overlay(brand,ext,manifest).items()]
        config={'services':{'cortendesk':{'image':'ghcr.io/marcpope/cortendesk:1.14.0','container_name':name,'restart':'unless-stopped',
            'environment':{'APP_NAME':'Magbel Remote CI','APP_URL':'https://support.example.test','APP_KEY':key,
                           'DB_CONNECTION':'sqlite','DB_DATABASE':'/data/test.sqlite','CACHE_STORE':'file','SESSION_DRIVER':'file',
                           'CORTENDESK_EMBEDDED_SERVER':'false','CORTENDESK_RDGEN_URL':'https://rdgen.example.test',
                           'MAGBEL_SESSION_TOKEN_GROUPS':'{"facilitador-tjpb-sessoes":"TJPB"}'},'volumes':volumes}},
            'networks':{'default':{'internal':True}}}
        compose.write_text(json.dumps(config))
        updater.compose(extra=('up','-d','--pull','never'))
        updater.wait_ready();assert updater.info()['version']=='1.14.0'
        db=root/'data/test.sqlite'
        with sqlite3.connect(db) as conn:
            conn.execute('CREATE TABLE magbel_update_fixture(value TEXT)')
            conn.execute("INSERT INTO magbel_update_fixture VALUES ('keep-me')")
        updater.apply()
        assert updater.info()['version']=='1.15.0';assert updater.info()['php']>=80512
        assert (root/'data/.app_key').read_text()==key
        assert (root/'data/rustdesk/id_ed25519').read_text()=='fixture-private-key-preserve'
        assert updater.inspect(name)['Config']['Env'].count('CORTENDESK_RDGEN_URL=https://rdgen.example.test')==1
        container_id=updater.inspect(name)['Id'];updater.apply();assert updater.inspect(name)['Id']==container_id
        updater.docker('cp',str(PACKAGE/'tests/bridge-integration.php'),name+':/bridge-integration.php')
        updater.docker('exec','-u','www-data','-w','/app',name,'php','/bridge-integration.php')
        with sqlite3.connect(db) as conn:
            assert conn.execute('SELECT value FROM magbel_update_fixture').fetchone()[0]=='keep-me'
            count=conn.execute('SELECT COUNT(*) FROM api_tokens').fetchone()[0]
            assert count>=3
        backup=next((root/'backups').glob('security-1.15.0-*'))
        assert (backup/'image-before.tar').stat().st_size>0
        assert (backup/'data-overlays-before.tar.gz').stat().st_size>0
        updater.rollback(backup);assert updater.info()['version']=='1.14.0'
        with sqlite3.connect(db) as conn:assert conn.execute('SELECT COUNT(*) FROM api_tokens').fetchone()[0]==count
        # Reexecuta de verdade e injeta falha de validação apenas neste objeto de CI.
        def fail_validation(expected):raise update.UpdateError('Falha injetada exclusivamente no teste descartável')
        updater.validate=fail_validation
        failed=False
        try:updater.apply()
        except update.UpdateError:failed=True
        assert failed and updater.info()['version']=='1.14.0'
        with sqlite3.connect(db) as conn:assert conn.execute('SELECT value FROM magbel_update_fixture').fetchone()[0]=='keep-me'
        print('CI: PHP corrigido, branding 1.15, ponte, RDGen, chaves, dados, idempotência e rollback real: OK')
    finally:
        if source:
            try:updater.docker('rm','-v',source)
            except update.UpdateError:pass
        try:updater.compose(extra=('down','--remove-orphans'))
        except update.UpdateError:
            try:updater.docker('rm','-f',name)
            except update.UpdateError:pass
        shutil.rmtree(workspace)


if __name__=='__main__':main()
