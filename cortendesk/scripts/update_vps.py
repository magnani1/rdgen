#!/usr/bin/env python3
"""Atualização 1.15.0 no projeto Compose existente, com snapshot e rollback de código."""
import argparse
import copy
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

from brand_v114 import prepare

PACKAGE = Path(__file__).resolve().parents[1]
IMAGE = 'ghcr.io/marcpope/cortendesk:1.15.0'
VERSION = '1.15.0'
MIN_PHP = 80512
ASSETS = {'cortendesk-logo-light.svg':['public/assets/images/cortendesk-logo-light.svg'],
          'cortendesk-logo-dark.svg':['public/assets/images/cortendesk-logo-dark.svg'],
          'cortendesk-sm.svg':['public/assets/images/cortendesk-sm.svg'],
          'icons/favicon.ico':['public/favicon.ico','public/assets/images/favicon.ico'],
          'icons/magbel-remote-256.png':['public/rdclient/logo.png']}
spec = importlib.util.spec_from_file_location('session_bridge_builder', PACKAGE/'scripts/build-session-bridge.py')
bridge = importlib.util.module_from_spec(spec); spec.loader.exec_module(bridge)


class UpdateError(Exception):
    pass


def native_file(path, managers):
    """Resolve caminhos de labels que pertencem ao /data interno do Portainer."""
    candidate=Path(path)
    if candidate.is_file(): return candidate.resolve()
    for manager in managers:
        for mount in sorted(manager.get('Mounts',[]),key=lambda m:len(m['Destination']),reverse=True):
            try: relative=candidate.relative_to(mount['Destination'])
            except ValueError: continue
            mapped=Path(mount['Source'])/relative
            if mapped.is_file(): return mapped.resolve()
    raise UpdateError('Compose ativo não encontrado no host nem nos volumes do Portainer/Dockge. Nada foi parado.')


def bindings(service):
    return {v['target']:(str(Path(v['source']).resolve()),bool(v.get('read_only',False)))
            for v in service.get('volumes',[]) if v.get('type')=='bind'}


def check_live(config, service_name, live):
    service=config['services'][service_name]
    actual={m['Destination']:(str(Path(m['Source']).resolve()),not m['RW'])
            for m in live['Mounts'] if m['Type']=='bind'}
    if bindings(service)!=actual:
        raise UpdateError('Mounts do Compose diferem do contêiner ativo; não será sobrescrita configuração divergente.')
    environment=dict(x.split('=',1) for x in live['Config']['Env'])
    if any(str(value)!=environment.get(key) for key,value in service.get('environment',{}).items()):
        raise UpdateError('Ambiente resolvido difere do contêiner ativo; confira a fonte da stack. Valores não foram exibidos.')
    if service.get('container_name',live['Name'].lstrip('/'))!=live['Name'].lstrip('/'):
        raise UpdateError('Nome do serviço diverge do contêiner.')
    if service['image']!=live['Config']['Image']:
        raise UpdateError('Imagem declarada difere da imagem configurada no contêiner ativo.')
    expected_networks={config['networks'][n].get('name',n) for n in service.get('networks',{})}
    if expected_networks!=set(live['NetworkSettings']['Networks']):
        raise UpdateError('Redes do Compose diferem das redes ativas.')
    expected_ports=set()
    for port in service.get('ports',[]):
        def span(value):
            parts=str(value).split('-'); return list(range(int(parts[0]),int(parts[-1])+1))
        targets,published=span(port['target']),span(port['published'])
        if len(targets)!=len(published): raise UpdateError('Faixa de portas ambígua.')
        ip=port.get('host_ip') or ''; ip='' if ip=='0.0.0.0' else ip
        expected_ports.update((str(t)+'/'+port.get('protocol','tcp'),ip,str(p)) for t,p in zip(targets,published))
    actual_ports={(target,'' if entry.get('HostIp') in ('','0.0.0.0',None) else entry['HostIp'],entry['HostPort'])
                  for target,entries in (live['HostConfig'].get('PortBindings') or {}).items() for entry in entries or []}
    if expected_ports!=actual_ports: raise UpdateError('Portas do Compose diferem das portas ativas.')
    if service.get('restart','no')!=(live['HostConfig'].get('RestartPolicy') or {}).get('Name','no'):
        raise UpdateError('Política de reinício diferente da stack ativa.')
    if bool(service.get('privileged',False))!=bool(live['HostConfig'].get('Privileged',False)):
        raise UpdateError('Privilégios diferentes da stack ativa.')


def patch_sources(texts, old_image, new_image, roots):
    matches=[i for i,text in enumerate(texts) if old_image in text]
    if len(matches)!=1 or texts[matches[0]].count(old_image)!=1:
        raise UpdateError('Imagem precisa estar declarada literalmente em um único Compose; alteração ambígua recusada.')
    result=list(texts); result[matches[0]]=result[matches[0]].replace(old_image,new_image)
    # Um rollback anterior pode ter fixado a imagem em um override privado.
    # Atualizar também a declaração literal principal evita que o gerenciador
    # volte à versão antiga no próximo redeploy sem esse override.
    app_image=r'(?:ghcr\.io/marcpope/cortendesk|marcpope/cortendesk):(?:1\.14\.0|1\.15\.0)(?:@sha256:[a-f0-9]{64})?'
    result=[re.sub(app_image,lambda match:new_image,text) for text in result]
    for old,new in roots.items():
        if not any(str(old)+'/' in text for text in result):
            raise UpdateError('Raiz de personalização não aparece literalmente no Compose. Nada foi parado.')
        result=[text.replace(str(old)+'/',str(new)+'/') for text in result]
    return result


def overlay(brand_root, bridge_root, manifest, bridge_manifest=None):
    result={'/app/'+f['upstream']:brand_root/f['local'] for f in manifest['files']}
    for name,targets in ASSETS.items():
        for target in targets: result['/app/'+target]=brand_root/name
    if bridge_root is not None:
        for name in json.loads(Path(bridge_manifest or bridge_root/'MAGBEL-SESSION-MANIFEST.json').read_text())['sha256']:
            result['/app/'+name]=bridge_root/name
    return result


def atomic_write(path, content):
    path=Path(path); info=path.stat()
    fd,name=tempfile.mkstemp(prefix='.magbel-',dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as out: out.write(content); out.flush(); os.fsync(out.fileno())
        os.chmod(name,info.st_mode & 0o777); os.chown(name,info.st_uid,info.st_gid)
        os.replace(name,path)
    finally:
        if Path(name).exists(): Path(name).unlink()


class Updater:
    def __init__(self, root, container):
        self.root=Path(root).resolve(); self.container=container
        self.log=None; self.env=None; self.files=[]; self.project=None; self.service=None

    def run(self,args,*,env=None,input=None):
        result=subprocess.run(args,env=env,input=input,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        if result.returncode:
            if self.log:
                with self.log.open('ab') as log: log.write(result.stderr+b'\n')
            raise UpdateError('Comando '+args[0]+' falhou. Detalhes somente no log privado do backup, quando disponível.')
        return result.stdout

    def docker(self,*args,input=None): return self.run(['docker',*args],input=input)
    def inspect(self,name): return json.loads(self.docker('inspect',name))[0]
    def php(self,code): return self.docker('exec','-u','www-data','-w','/app',self.container,'php','-r',code).decode()
    def compose(self,files=None,extra=()):
        args=['docker','compose','--project-name',self.project]
        for file in files or self.files: args+=['-f',str(file)]
        return self.run(args+list(extra),env=self.env)

    def info(self):
        return json.loads(self.php('require "vendor/autoload.php"; $app=require "bootstrap/app.php"; $app->make(Illuminate\\Contracts\\Console\\Kernel::class)->bootstrap(); echo json_encode(["version"=>config("cortendesk.api_version"),"php"=>PHP_VERSION_ID,"driver"=>config("database.default"),"database"=>config("database.connections.sqlite.database")]);'))

    def wait_ready(self,timeout=180):
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            try:
                body=json.loads(self.docker('exec',self.container,'wget','-q','-O','-','http://127.0.0.1:8080/health/ready'))
                if body.get('ready') and body.get('database'): return
            except (UpdateError,ValueError): pass
            time.sleep(3)
        raise UpdateError('Saúde não ficou pronta no prazo; consultar o log privado.')

    def validate(self, expected):
        self.wait_ready()
        info=self.info()
        if info['version']!=VERSION or info['php']<MIN_PHP: raise UpdateError('Versão da aplicação/PHP ainda não corrigida.')
        code='''$expected=json_decode(stream_get_contents(STDIN),true); foreach($expected as $path=>$hash){if(!is_file($path)||hash_file("sha256",$path)!==$hash){fwrite(STDERR,"Overlay divergente\\n");exit(1);}}'''
        self.docker('exec','-i','-u','www-data','-w','/app',self.container,'php','-r',code,input=json.dumps(expected).encode())
        for command in [('optimize:clear',),('view:cache',)]:
            self.docker('exec','-u','www-data','-w','/app',self.container,'php','artisan',*command,'--no-ansi')
        routes=self.docker('exec','-u','www-data','-w','/app',self.container,'php','artisan','route:list','--path=facilitador','--except-vendor','--no-ansi')
        if b'api/v1/facilitador/capabilities' not in routes or b'/disconnect' not in routes: raise UpdateError('Rotas da ponte não estão disponíveis.')
        schedule=self.docker('exec','-u','www-data','-w','/app',self.container,'php','artisan','schedule:list','--no-ansi')
        if b'magbel:sessions:sweep' not in schedule: raise UpdateError('Varredura da ponte ausente no agendamento.')
        # Examina somente nomes de processos; não imprime argumentos/ambiente.
        self.docker('exec',self.container,'sh','-c',"ps -eo args | grep -q '[p]hp /app/artisan schedule:work'")
        self.php('require "vendor/autoload.php"; $app=require "bootstrap/app.php"; $app->make(Illuminate\\Contracts\\Console\\Kernel::class)->bootstrap(); if(!Illuminate\\Support\\Facades\\Schema::hasTable("magbel_support_sessions") || !defined(App\\Services\\AppriseNotifications::class."::SCOPED_EVENTS"))exit(1);')

    def rollback(self, backup):
        record=json.loads((backup/'operation.json').read_text())
        self.project=record['project']; self.service=record['service']; self.files=[Path(p) for p in record['files']]
        before=json.loads((backup/'container-before.json').read_text())
        self.env={**os.environ,**dict(v.split('=',1) for v in before['Config']['Env'])}
        try: self.docker('image','inspect',record['rollback_image'])
        except UpdateError: self.docker('image','load','-i',str(backup/'image-before.tar'))
        for i,file in enumerate(self.files): atomic_write(file,(backup/f'compose-before-{i}').read_bytes())
        override=backup/'rollback-image.json'
        inherited=json.loads(self.docker('image','inspect',record['rollback_image']))[0]['Config'].get('Labels') or {}
        labels={k:v for k,v in (before['Config'].get('Labels') or {}).items() if not k.startswith('com.docker.compose.') and inherited.get(k)!=v}
        override.write_text(json.dumps({'services':{self.service:{'image':record['rollback_image'],'labels':labels}}}))
        self.compose(files=self.files+[override],extra=('up','-d','--no-deps','--force-recreate','--pull','never',self.service))
        self.wait_ready()
        print('Rollback de código concluído. /data não foi substituído; o snapshot completo permanece privado.',flush=True)

    def apply(self):
        live=self.inspect(self.container); labels=live['Config'].get('Labels') or {}
        self.project=labels.get('com.docker.compose.project'); self.service=labels.get('com.docker.compose.service')
        paths=labels.get('com.docker.compose.project.config_files','').split(',')
        if not self.project or not self.service or not all(paths): raise UpdateError('Contêiner sem projeto Compose identificado; nada foi parado.')
        managers=[]
        for name in ('portainer','dockge'):
            try: managers.append(self.inspect(name))
            except UpdateError: pass
        self.files=[native_file(path,managers) for path in paths]
        if len(set(self.files))!=len(self.files): raise UpdateError('Compose duplicado nos labels.')
        for file in self.files:
            if any((parent/'.git').exists() for parent in file.parents): raise UpdateError('Compose ativo está em checkout Git. Use uma cópia na stack antes desta manutenção; nenhum arquivo versionado será reescrito.')
        self.env={**os.environ,**dict(v.split('=',1) for v in live['Config']['Env'])}
        before_config=json.loads(self.compose(extra=('config','--format','json')))
        check_live(before_config,self.service,live)
        mounts={m['Destination']:Path(m['Source']) for m in live['Mounts']}
        if mounts.get('/data')!=self.root/'data': raise UpdateError('/data não corresponde ao diretório persistente esperado.')
        identities={path:hashlib.sha256(path.read_bytes()).hexdigest()
                    for name in ('.app_key','.server_secret','rustdesk/id_ed25519','rustdesk/id_ed25519.pub')
                    if (path:=self.root/'data'/name).is_file()}
        info=self.info()
        if info['driver']!='sqlite' or not str(info['database']).startswith('/data/'): raise UpdateError('Banco externo ou fora de /data exige backup próprio; nada foi parado.')
        database=(self.root/'data'/Path(info['database']).relative_to('/data')).resolve()
        if not database.is_file() or not database.is_relative_to((self.root/'data').resolve()): raise UpdateError('Banco persistente não localizado com segurança dentro de /data.')
        manifest=json.loads((PACKAGE/'manifest-1.15.0.json').read_text())
        brand_dest=self.root/'branding-1.15.0'; bridge_dest=self.root/'session-bridge-corten-1.15.0'
        if info['version']==VERSION and brand_dest.is_dir() and bridge_dest.is_dir():
            final=overlay(brand_dest,bridge_dest,manifest)
            if all(mounts.get(target)==path for target,path in final.items()):
                expected={target:hashlib.sha256(path.read_bytes()).hexdigest() for target,path in final.items()}
                self.validate(expected); print('CortenDesk 1.15.0 e ponte já ativos e validados; nenhuma recriação feita.'); return
        if info['version'] not in ('1.14.0','1.15.0'): raise UpdateError('Este procedimento exige base 1.14.0 ou preparação parcial 1.15.0.')
        old_brand=mounts.get('/app/app/Services/AppriseNotifications.php')
        old_bridge=mounts.get('/app/app/Http/Controllers/MagbelSupportController.php')
        if old_brand is None or old_bridge is None: raise UpdateError('Branding/ponte ativos não identificados; nada foi parado.')
        old_brand=old_brand.parents[2]; old_bridge=old_bridge.parents[3]
        # As raízes são inferidas dos destinos conhecidos, não de nomes digitados.
        if not (old_brand/'MAGBEL-MANIFEST.json').is_file() or not (old_bridge/'MAGBEL-SESSION-MANIFEST.json').is_file(): raise UpdateError('Manifestos das personalizações atuais ausentes; preservar ajustes antes de atualizar.')
        known=set(overlay(old_brand,old_bridge,json.loads((PACKAGE/'manifest.json').read_text())))
        if any(target.startswith('/app') and target not in known and target not in ('/app/storage','/app/bootstrap/cache') for target in mounts):
            raise UpdateError('Há código adicional montado em /app fora dos manifestos; é necessário revisar esse ajuste antes de substituir a base.')
        for directory,filename in [(old_brand,'MAGBEL-MANIFEST.json'),(old_bridge,'MAGBEL-SESSION-MANIFEST.json')]:
            for name,checksum in json.loads((directory/filename).read_text())['sha256'].items():
                if hashlib.sha256((directory/name).read_bytes()).hexdigest()!=checksum: raise UpdateError('Personalização local difere do manifesto; nenhum ajuste não versionado será sobrescrito.')
        texts=[file.read_text() for file in self.files]
        stamp=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+os.urandom(4).hex()
        backup=self.root/'backups'/('security-1.15.0-'+stamp); backup.mkdir(parents=True,mode=0o700)
        self.log=backup/'commands-private.log'
        print('Baixando imagem 1.15.0 e verificando PHP corrigido; o suporte continua ativo.',flush=True)
        self.docker('pull',IMAGE)
        image=json.loads(self.docker('image','inspect',IMAGE))[0]
        digest=next((v for v in image.get('RepoDigests',[]) if v.startswith('ghcr.io/marcpope/cortendesk@sha256:')),None)
        if not digest: raise UpdateError('Digest da imagem oficial não identificado.')
        image_ref=IMAGE+'@'+digest.split('@',1)[1]
        self.docker('run','--rm','--network','none','--entrypoint','php',image_ref,'-r',f'exit(PHP_VERSION_ID >= {MIN_PHP} ? 0 : 1);')
        source_container=self.docker('create','--entrypoint','/bin/true',image_ref).decode().strip()
        try:
            upstream=backup/'upstream'; upstream.mkdir()
            for item in manifest['files']+[{'upstream':'bootstrap/providers.php'}]:
                target=upstream/item['upstream']; target.parent.mkdir(parents=True,exist_ok=True)
                self.docker('cp',source_container+':/app/'+item['upstream'],str(target))
        finally: self.docker('rm','-v',source_container)
        prepared=backup/'branding-prepared'; prepared_bridge=backup/'bridge-prepared'
        prepare(upstream,prepared,manifest_path=PACKAGE/'manifest-1.15.0.json')
        bridge.build(upstream/'bootstrap/providers.php',prepared/'views/webclient.blade.php',prepared_bridge)
        self.docker('run','--rm','--network','none','--entrypoint','sh','-v',str(backup)+':/prepare:ro',image_ref,'-c',"find /prepare/branding-prepared /prepare/bridge-prepared -name '*.php' -exec php -l {} \\; >/tmp/lint.log; ! grep -q 'Errors parsing\\|Parse error\\|Fatal error' /tmp/lint.log")
        new_texts=patch_sources(texts,before_config['services'][self.service]['image'],image_ref,{old_brand:brand_dest,old_bridge:bridge_dest})
        # Escreve rascunhos junto ao Compose, preservando resolução de caminhos relativos.
        drafts=[]
        try:
            for file,text in zip(self.files,new_texts):
                fd,name=tempfile.mkstemp(prefix='.magbel-draft-',suffix='.json.yaml',dir=file.parent)
                with os.fdopen(fd,'w') as out: out.write(text)
                drafts.append(Path(name))
            after_config=json.loads(self.compose(files=drafts,extra=('config','--format','json')))
        finally:
            for file in drafts: file.unlink(missing_ok=True)
        after_bindings=bindings(after_config['services'][self.service])
        final_bridge_map=overlay(brand_dest,bridge_dest,manifest,prepared_bridge/'MAGBEL-SESSION-MANIFEST.json')
        if any(after_bindings.get(target)!=(str(path.resolve()),True) for target,path in final_bridge_map.items()): raise UpdateError('Compose não monta todos os destinos do branding/ponte novos como somente leitura.')
        comparable=copy.deepcopy(after_config)
        comparable['services'][self.service]['image']=before_config['services'][self.service]['image']
        reverse={str(brand_dest):str(old_brand),str(bridge_dest):str(old_bridge)}
        for volume in comparable['services'][self.service].get('volumes',[]):
            for new,old in reverse.items():
                if str(volume.get('source','')).startswith(new+'/'): volume['source']=old+volume['source'][len(new):]
        if comparable!=before_config: raise UpdateError('A preparação alteraria configuração além da imagem e dos overlays; operação recusada.')
        (backup/'container-before.json').write_text(json.dumps(live))
        for i,text in enumerate(texts): (backup/f'compose-before-{i}').write_text(text)
        rollback_image='magbel-cortendesk:rollback-'+stamp.lower()
        self.docker('image','inspect',live['Image'])
        self.docker('image','tag',live['Image'],rollback_image)
        with (backup/'image-before.tar').open('wb') as out:
            result=subprocess.run(['docker','image','save',rollback_image],stdout=out,stderr=subprocess.PIPE)
            if result.returncode: raise UpdateError('Falha ao arquivar a imagem anterior; nada foi parado.')
        (backup/'operation.json').write_text(json.dumps({'project':self.project,'service':self.service,'files':[str(p) for p in self.files],'rollback_image':rollback_image,'target_image':image_ref},indent=2))
        for source,dest in [(prepared,brand_dest),(prepared_bridge,bridge_dest)]:
            if dest.exists():
                if sorted((str(p.relative_to(source)),hashlib.sha256(p.read_bytes()).hexdigest()) for p in source.rglob('*') if p.is_file())!=sorted((str(p.relative_to(dest)),hashlib.sha256(p.read_bytes()).hexdigest()) for p in dest.rglob('*') if p.is_file()): raise UpdateError('Preparação anterior diferente: não será sobrescrita.')
            else: shutil.copytree(source,dest)
            for path in [dest,*dest.rglob('*')]: path.chmod(0o755 if path.is_dir() else 0o644)
        # Não perder labels de controle de acesso injetados pelo Portainer fora do YAML.
        image_labels=json.loads(self.docker('image','inspect',live['Image']))[0]['Config'].get('Labels') or {}
        declared=before_config['services'][self.service].get('labels') or {}
        extras={k:v for k,v in labels.items() if not k.startswith('com.docker.compose.') and k not in declared and image_labels.get(k)!=v}
        if extras:
            labels_file=backup/'runtime-labels.json'; labels_file.write_text(json.dumps({'services':{self.service:{'labels':extras}}}))
        else: labels_file=None
        if any(file.read_text()!=text for file,text in zip(self.files,texts)) or self.inspect(self.container)['Id']!=live['Id']:
            raise UpdateError('A stack mudou durante o preparo; nada será parado ou sobrescrito.')
        print('Snapshot consistente: suporte e relay terão uma breve interrupção.',flush=True)
        self.docker('stop','-t','60',self.container)
        changed=False
        try:
            archive_paths={self.root/'data',old_brand,old_bridge}
            self.run(['tar','-C','/','-czf',str(backup/'data-overlays-before.tar.gz'),*sorted(str(p).lstrip('/') for p in archive_paths)])
            changed=True
            for file,text in zip(self.files,new_texts): atomic_write(file,text.encode())
            self.compose(files=self.files+([labels_file] if labels_file else []),extra=('up','-d','--no-deps','--force-recreate','--pull','never',self.service))
            expected={target:hashlib.sha256(path.read_bytes()).hexdigest() for target,path in final_bridge_map.items()}
            self.validate(expected)
            if any(not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest()!=checksum for path,checksum in identities.items()):
                raise UpdateError('Chave persistente da aplicação ou RustDesk mudou; conferir snapshot antes de retomar atendimentos.')
        except BaseException:
            if changed:
                print('Validação falhou; restaurando a configuração e a imagem anteriores.',flush=True)
                self.rollback(backup)
            else: self.docker('start',self.container)
            raise
        (backup/'SUCCESS.json').write_text(json.dumps({'version':VERSION,'image':image_ref,'completed':datetime.now(timezone.utc).isoformat()}))
        print('CortenDesk 1.15.0, PHP corrigido, branding, ponte, rotas e scheduler: OK.',flush=True)
        print('Backup privado: '+str(backup),flush=True)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container',default=os.environ.get('CORTEN_CONTAINER','suporte_remoto'))
    parser.add_argument('--root',default=os.environ.get('CORTEN_ROOT','/opt/cortendesk'))
    mode=parser.add_mutually_exclusive_group()
    mode.add_argument('--rollback',type=Path)
    mode.add_argument('--verify',action='store_true')
    args=parser.parse_args(argv)
    if os.geteuid()!=0: raise UpdateError('Execute com sudo na VPS, para proteger o backup e preservar os volumes.')
    os.umask(0o077)
    def interrupted(signum, frame): raise UpdateError('Interrupção solicitada durante a manutenção.')
    signal.signal(signal.SIGTERM,interrupted)
    root=Path(args.root).resolve()
    if not root.is_dir(): raise UpdateError('Diretório CortenDesk ausente.')
    with (root/'.update-1.15.lock').open('a') as lock:
        try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError: raise UpdateError('Outra manutenção já está em execução.')
        updater=Updater(root,args.container)
        if args.verify:
            manifest=json.loads((PACKAGE/'manifest-1.15.0.json').read_text())
            paths=overlay(root/'branding-1.15.0',root/'session-bridge-corten-1.15.0',manifest)
            updater.validate({target:hashlib.sha256(path.read_bytes()).hexdigest() for target,path in paths.items()})
            print('CortenDesk 1.15.0, PHP corrigido e integração Magbel conferidos.')
        elif args.rollback:
            backup=args.rollback.resolve()
            if not backup.is_relative_to(root/'backups') or not (backup/'operation.json').is_file(): raise UpdateError('Backup de atualização inválido.')
            updater.log=backup/'commands-private.log'; updater.rollback(backup)
        else: updater.apply()


if __name__=='__main__':
    try: main()
    except (UpdateError,ValueError,KeyError,OSError) as error:
        print('Atualização interrompida: '+str(error),file=sys.stderr); sys.exit(1)
