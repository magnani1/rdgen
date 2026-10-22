"""Conector permanente supervisionado pelo Agendador do Windows; credencial DPAPI/ACL."""
import argparse
import base64
import contextlib
import ctypes
import hashlib
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import time
import threading
from urllib.parse import urlsplit

import requests
from fleet_manager import FleetError
from maintenance_controller import Controller, SOURCE_HASH, VERSION, source_hash


class CredentialError(FleetError):
    pass


def origin(value):
    parsed=urlsplit(value)
    if parsed.scheme!='https' or not parsed.hostname or parsed.username or parsed.password or parsed.path not in ('','/') or parsed.query or parsed.fragment:
        raise FleetError('Origem HTTPS inválida.')
    return value.rstrip('/')


def dpapi(data, protect=False):
    """LocalMachine exige ACL privada: qualquer processo que leia o blob pode pedi-lo ao SO."""
    if os.name!='nt': raise FleetError('DPAPI requer Windows.')
    class Blob(ctypes.Structure):
        _fields_=[('size',ctypes.c_uint32),('data',ctypes.POINTER(ctypes.c_ubyte))]
    buffer=(ctypes.c_ubyte*len(data)).from_buffer_copy(data)
    source=Blob(len(data),buffer); target=Blob()
    crypto=ctypes.WinDLL('crypt32',use_last_error=True)
    kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    kernel.LocalFree.argtypes=[ctypes.c_void_p];kernel.LocalFree.restype=ctypes.c_void_p
    function=crypto.CryptProtectData if protect else crypto.CryptUnprotectData
    function.argtypes=[ctypes.POINTER(Blob),ctypes.c_void_p,ctypes.c_void_p,ctypes.c_void_p,ctypes.c_void_p,ctypes.c_uint32,ctypes.POINTER(Blob)]
    function.restype=ctypes.c_int
    if not function(ctypes.byref(source),None,None,None,None,5 if protect else 1,ctypes.byref(target)):
        raise FleetError('Proteção DPAPI indisponível nesta máquina.')
    try:return ctypes.string_at(target.data,target.size)
    finally:kernel.LocalFree(ctypes.cast(target.data,ctypes.c_void_p))


class ServicePortal:
    def __init__(self, identity):
        self.url=origin(identity['home_url']);self.http=requests.Session()
        self.credential=dpapi(base64.b64decode(identity['protected_token'],validate=True)).decode('utf-8')

    def call(self, method, path, body=None):
        if path=='/admin/agents': path='/fila/maintenance/agents'
        elif path.startswith('/admin/maintenance/'): path=path.replace('/admin/maintenance/','/fila/maintenance/',1)
        else: raise FleetError('Rota fora do escopo do conector permanente.')
        if not re.fullmatch(r'/fila/maintenance/(?:agents|controller|claim|[a-f0-9]{32}/progress)',path):
            raise FleetError('Rota de manutenção desconhecida.')
        try:
            r=self.http.request(method,self.url+path,json=body,headers={'Authorization':'Bearer '+self.credential},timeout=30,allow_redirects=False)
        except requests.RequestException as error: raise FleetError('Comunicação HTTPS indisponível.') from error
        if r.status_code in (401,403): raise CredentialError('Credencial revogada ou escopo recusado; conferir no painel.')
        if not r.ok or r.is_redirect:raise FleetError('API de manutenção HTTP '+str(r.status_code))
        return r.json()

    def agents(self):return self.call('GET','/admin/agents')
    def close(self):self.credential='';self.http.close()


def probe_connectivity(host):
    """Somente TCP e token remoto; nunca lê credenciais/configuração do agente."""
    report={'hostname':host,'checked_at':int(time.time()),'tcp':None,'kerberos':None,'admin':None}
    if not re.fullmatch(r'[a-z][a-z0-9-]{0,62}(?:\.[a-z0-9][a-z0-9-]{0,62})*',host):
        raise FleetError('Destino de sonda inválido.')
    try:
        with socket.create_connection((host,5985),timeout=3):pass
        report['tcp']=True
    except OSError:
        report['tcp']=False
        return report
    encoded_host=base64.b64encode(host.encode()).decode()
    script=r"""
$ErrorActionPreference='Stop'
$HostName=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__HOST__'))
try {
    $Options=New-PSSessionOption -OpenTimeout 8000 -OperationTimeout 8000
    $Admin=Invoke-Command -ComputerName $HostName -Authentication Kerberos -ConfigurationName Microsoft.PowerShell -SessionOption $Options -ScriptBlock {
        $Principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
        $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    @{kerberos=$true;admin=[bool]$Admin} | ConvertTo-Json -Compress
} catch { @{kerberos=$false;admin=$null} | ConvertTo-Json -Compress }
""".replace('__HOST__',encoded_host)
    encoded=base64.b64encode(script.encode('utf-16-le')).decode()
    try:
        result=subprocess.run(['pwsh','-NoProfile','-NonInteractive','-EncodedCommand',encoded],capture_output=True,encoding='utf-8',errors='replace',timeout=25)
        if result.returncode:return report
        data=json.loads(result.stdout.lstrip('\ufeff').strip())
        if not isinstance(data,dict):return report
        if type(data.get('kerberos')) is bool:report['kerberos']=data['kerberos']
        if report['kerberos'] is True and type(data.get('admin')) is bool:report['admin']=data['admin']
    except (OSError,ValueError,subprocess.SubprocessError):pass
    return report


class PermanentController(Controller):
    def __init__(self, portal, identity, package, **kwargs):
        self.hostname=identity['hostname']
        self.diagnostics={};self.probe_lock=threading.Lock();self.probe_thread=None
        self.next_probe=0;self.probe_index=0
        super().__init__(portal,identity['hosts'],package,**kwargs)

    def run_operation(self, op):
        if op['hostname'] not in self.hosts or op['target_version']!=VERSION:
            raise FleetError('Plano fora do escopo do serviço.')
        report=probe_connectivity(op['hostname'])
        with self.probe_lock:self.diagnostics[op['hostname']]=report
        if not all(report[k] is True for k in ('tcp','kerberos','admin')):
            self.progress(op,'failed')
            print(op['agent_id']+': conferência WinRM recusada antes da troca; tarefa e código preservados. Confira as sondas no painel.',flush=True)
            return
        return super().run_operation(op)

    def announce(self):
        # Uma sonda por vez, em segundo plano: não bloqueia o heartbeat/manutenção.
        if (self.probe_thread is None or not self.probe_thread.is_alive()) and self.clock()>=self.next_probe:
            host=self.hosts[self.probe_index % len(self.hosts)];self.probe_index+=1
            self.next_probe=self.clock()+max(5,120/len(self.hosts))
            def collect():
                try:report=probe_connectivity(host)
                except Exception:return  # Sem stderr, tokens ou mensagens do WinRM no relatório.
                with self.probe_lock:self.diagnostics[host]=report
            self.probe_thread=threading.Thread(target=collect,daemon=True);self.probe_thread.start()
        with self.probe_lock:reports=[dict(r) for r in self.diagnostics.values() if int(time.time())-r['checked_at']<=86400]
        return self.portal.call('POST','/admin/maintenance/controller',{'id':self.id,'hostname':self.hostname,'hosts':self.hosts,'versions':[VERSION],'diagnostics':reports})


def enroll(root, payload):
    url=origin(payload['home_url'])
    if not re.fullmatch(r'[a-z][a-z0-9-]{0,63}',payload['id']):raise FleetError('Identidade inválida.')
    if (root/'identity.json').exists():raise FleetError('Inscrição já existe; não sobrescrever.')
    try:
        r=requests.post(url+'/fila/maintenance/enroll',json={'code':payload['code']},timeout=30,allow_redirects=False)
    except requests.RequestException as error:raise FleetError('Inscrição HTTPS indisponível.') from error
    if not r.ok or r.is_redirect:raise FleetError('Inscrição recusada; conferir código no painel.')
    data=r.json()
    if data.get('id')!=payload['id'] or data.get('client_id')!=payload['client_id'] or data.get('hostname','').split('.')[0].lower()!=socket.gethostname().split('.')[0].lower():
        raise FleetError('Identidade, cliente ou máquina divergente; credencial não instalada.')
    identity={k:data[k] for k in ('id','hostname','hosts','client_id')}
    identity.update(home_url=url,protected_token=base64.b64encode(dpapi(data['maintenance_token'].encode(),protect=True)).decode())
    pending=root/'identity.pending'
    pending.write_text(json.dumps(identity,ensure_ascii=False),encoding='utf-8')
    pending.replace(root/'identity.json')
    print('Inscrição de manutenção concluída; credencial protegida nesta máquina.')


def validate_bundle(root):
    config=json.loads((root/'service.json').read_text(encoding='utf-8-sig'))
    expected={'permanent_maintenance.py','maintenance_controller.py','fleet_manager.py','setup_assistant.py','facilitador-agent.py','manutencao-agente.ps1','requirements.txt'}
    if set(config['hashes'])!=expected:raise FleetError('Manifesto do pacote divergente.')
    package=root/'package'
    for name,value in config['hashes'].items():
        if hashlib.sha256((package/name).read_bytes()).hexdigest().lower()!=value.lower():raise FleetError('Arquivo do pacote alterado: '+name)
    if source_hash(package/'facilitador-agent.py')!=SOURCE_HASH:raise FleetError('Código não homologado.')
    path=base64.b64encode(str(package/'manutencao-agente.ps1').encode()).decode()
    script="$p=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"+path+"')); if ((Get-AuthenticodeSignature -LiteralPath $p).Status -ne 'Valid') { exit 1 }"
    encoded=base64.b64encode(script.encode('utf-16-le')).decode()
    check=subprocess.run(['pwsh','-NoProfile','-NonInteractive','-EncodedCommand',encoded],capture_output=True,timeout=30)
    if check.returncode:raise FleetError('Helper sem assinatura confiável para a conta de execução.')
    return package


class LogStream:
    def __init__(self,logger):self.logger=logger
    def write(self,value):
        if value.strip():self.logger.info(value.strip())
        return len(value)
    def flush(self):pass


def serve(root):
    identity=json.loads((root/'identity.json').read_text(encoding='utf-8'))
    if identity['hostname'].split('.')[0].lower()!=socket.gethostname().split('.')[0].lower():raise FleetError('Credencial pertence a outra máquina.')
    package=validate_bundle(root)
    portal=ServicePortal(identity)
    try:
        while True:
            try:
                print('Conector permanente ativo: '+identity['id'],flush=True)
                PermanentController(portal,identity,package).loop()
            except CredentialError:
                print('Credencial revogada/escopo recusado; execução encerrada.',flush=True)
                return
            except (FleetError,OSError,ValueError,subprocess.SubprocessError) as error:
                # Não imprimir corpos HTTP, argumentos, credenciais ou stderr do helper.
                print('Comunicação/operação interrompida ('+type(error).__name__+'); repetição da instalação não será feita.',flush=True)
                time.sleep(60)
    finally:portal.close()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    mode=parser.add_mutually_exclusive_group(required=True);mode.add_argument('--enroll',action='store_true');mode.add_argument('--run',action='store_true')
    parser.add_argument('--root',type=Path,required=True);args=parser.parse_args()
    if os.name!='nt':raise FleetError('Execute no Windows.')
    if args.enroll:
        enroll(args.root,json.load(sys.stdin));return
    log=logging.getLogger('maintenance');log.setLevel(logging.INFO)
    handler=RotatingFileHandler(args.root/'logs'/'maintenance.log',maxBytes=5*1024*1024,backupCount=3,encoding='utf-8')
    handler.setFormatter(logging.Formatter('%(asctime)s %(message)s'));log.addHandler(handler)
    stream=LogStream(log)
    with contextlib.redirect_stdout(stream),contextlib.redirect_stderr(stream):
        try:serve(args.root)
        except Exception as error:
            print('Conector interrompido: '+type(error).__name__+'. Conferir pacote, identidade e permissões.',flush=True)
            raise SystemExit(1)


if __name__=='__main__':
    try:main()
    except (FleetError,OSError,ValueError) as error:
        print('Conector: '+str(error));raise SystemExit(1)
