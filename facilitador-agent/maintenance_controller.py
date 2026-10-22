"""Conector interativo: sessão MFA em memória, Kerberos do Windows, destinos explícitos."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import uuid
from urllib.parse import urlsplit

from fleet_manager import FleetError, Portal, targets

VERSION = '2.0.6'
SOURCE_HASH = 'bcde24d4c8f6a7413de8c062bd4140168954640bff8dfa62952cb77d6d9cb047'


def source_hash(path):
    text = Path(path).read_text(encoding='utf-8-sig').replace('\r\n', '\n').rstrip('\r\n')+'\n'
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


class Controller:
    def __init__(self, portal, hosts, package, remote=None, clock=time.monotonic, pause=time.sleep):
        self.portal, self.hosts, self.package = portal, hosts, Path(package)
        self.id = uuid.uuid4().hex
        self.clock, self.pause = clock, pause
        self.remote = remote or self.invoke

    def announce(self):
        return self.portal.call('POST', '/admin/maintenance/controller', {
            'id': self.id, 'hostname': socket.gethostname(), 'hosts': self.hosts, 'versions': [VERSION]})

    def progress(self, op, state):
        self.announce()
        return self.portal.call('POST', '/admin/maintenance/'+op['id']+'/progress', {
            'controller_id': self.id, 'state': state})

    def agent(self, op):
        data = self.portal.agents()
        return next((a for a in data['agents'] if a['id'] == op['agent_id']), None)

    def wait(self, op, state, predicate, seconds):
        deadline = self.clock()+seconds
        while self.clock() < deadline:
            self.progress(op, state)
            a = self.agent(op)
            if a and predicate(a):
                return True
            self.pause(5)
        return False

    def invoke(self, op, action, state):
        # argv nunca contém senha, sessão web nem token do agente.
        command = ['pwsh', '-NoProfile', '-NonInteractive', '-File', str(self.package/'manutencao-agente.ps1'),
                   '-ComputerName', op['hostname'], '-OperationId', op['id'], '-Action', action,
                   '-AgentSourcePath', str(self.package/'facilitador-agent.py')]
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, encoding='utf-8', errors='replace')
        deadline = self.clock()+120
        try:
            while process.poll() is None:
                if self.clock() >= deadline:
                    raise FleetError('Timeout do WinRM; conferir a máquina antes de repetir.')
                self.progress(op, state)
                self.pause(5)
            output, _ = process.communicate()
            if process.returncode:
                raise FleetError('Helper/WinRM falhou; conferir estado no destino. Saída privada omitida.')
            try:
                result = json.loads(output.lstrip('\ufeff').strip())
            except (ValueError, TypeError) as error:
                raise FleetError('Resposta do helper não reconhecida; conferir no destino.') from error
            if result.get('Operation') != op['id'] or result.get('Agent') != op['agent_id'] or result.get('Action') != action:
                raise FleetError('Identidade da resposta remota divergente.')
            return result
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.communicate(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate()

    def run_operation(self, op):
        if op['hostname'].lower() not in self.hosts or op['target_version'] != VERSION or not __import__('re').fullmatch(r'[a-f0-9]{32}', op['id']):
            raise FleetError('Plano fora dos destinos/versão autorizados nesta estação.')
        print(op['agent_id']+': aguardando drenagem e zero trabalhos.', flush=True)
        if not self.wait(op, 'draining', lambda a: a['running'] == 0 and a['desired'] == 'drain', 600):
            self.progress(op, 'failed')
            return
        self.progress(op, 'applying')  # Servidor revalida zero trabalhos numa transação.
        result = self.remote(op, 'Apply', 'applying')
        if not result.get('Ok'):
            if not result.get('RollbackAvailable'):
                # Não houve troca; permanece drenado para conferência do operador.
                self.progress(op, 'failed')
                return
            self.rollback(op)
            return
        self.progress(op, 'validating')
        if self.wait(op, 'validating', lambda a: a['version'] == VERSION and a.get('boot_id') and a['ready'], 150):
            self.progress(op, 'completed')
            print(op['agent_id']+': código atualizado, novo processo e prontidão confirmados.', flush=True)
        else:
            self.rollback(op)

    def rollback(self, op):
        self.progress(op, 'rolling_back')
        result = self.remote(op, 'Rollback', 'rolling_back')
        if result.get('Ok') and self.wait(op, 'rolling_back', lambda a: a['version'] == op['previous_version'] and a['ready'], 150):
            self.progress(op, 'rolled_back')
            print(op['agent_id']+': código anterior restaurado; mantido drenado para conferência.', flush=True)
        else:
            self.progress(op, 'unknown')
            raise FleetError('Rollback não confirmado; conferir tarefa e backup no Windows.')

    def loop(self, once=False):
        while True:
            self.announce()
            op = self.portal.call('POST', '/admin/maintenance/claim', {'controller_id': self.id}).get('operation')
            if op:
                # Uma falha de transporte não é prova de que o comando remoto não executou.
                # Não reivindicar novamente: o backend marca resultado desconhecido após 180 s.
                self.run_operation(op)
            if once:
                return
            self.pause(5)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--home-url', default='https://facilitador-tjpb.magbel.com.br')
    parser.add_argument('--hosts', nargs='+', required=True)
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--once', action='store_true')
    args = parser.parse_args(argv)
    url = urlsplit(args.home_url)
    if os.name != 'nt' or url.scheme != 'https' or not url.hostname or url.username or url.password or url.path not in ('', '/') or url.query or url.fragment:
        raise FleetError('Execute no Windows com a origem HTTPS do Facilitador.')
    hosts = [host for host, _ in targets(args.hosts)]
    package = args.package.resolve()
    if source_hash(package/'facilitador-agent.py') != SOURCE_HASH:
        raise FleetError('Pacote de código fora da referência 2.0.6.')
    helper = package/'manutencao-agente.ps1'
    # Validação da confiança Authenticode no próprio Windows; sem bypass de política.
    encoded_path = base64.b64encode(str(helper).encode('utf-8')).decode('ascii')
    verification = "$p=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"+encoded_path+"')); if ((Get-AuthenticodeSignature -LiteralPath $p).Status -ne 'Valid') { exit 1 }"
    encoded_check = base64.b64encode(verification.encode('utf-16-le')).decode('ascii')
    check = subprocess.run(['pwsh', '-NoProfile', '-NonInteractive', '-EncodedCommand', encoded_check],
        capture_output=True, timeout=30)
    if check.returncode:
        raise FleetError('Helper precisa estar assinado e confiável nesta estação.')
    portal = Portal(args.home_url)
    try:
        portal.login()
        print('Conector ativo. Solicite as atualizações no painel; Ctrl+C encerra esta sessão.', flush=True)
        Controller(portal, hosts, package).loop(args.once)
    finally:
        portal.close()


if __name__ == '__main__':
    try:
        main()
    except (FleetError, OSError, subprocess.SubprocessError) as error:
        print('Interrompido: '+str(error))
        raise SystemExit(1)
    except KeyboardInterrupt:
        print('Conector encerrado; operações interrompidas exigem conferência antes de repetir.')
