"""Inscrição e instalação central de agentes novos; segredos somente em memória/pipe."""
import argparse
import getpass
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import warnings
from urllib.parse import urlsplit

import requests
from setup_assistant import verify_package


class FleetError(Exception):
    pass


def secret(prompt):
    with warnings.catch_warnings():
        warnings.simplefilter('error', getpass.GetPassWarning)
        try:
            return getpass.getpass(prompt)
        except getpass.GetPassWarning as error:
            raise FleetError('Entrada oculta indisponível. Abra um terminal Windows/PowerShell 7 fora do ISE.') from error


def targets(values):
    hosts = []
    ids = set()
    for value in values:
        host = value.strip().lower()
        if not re.fullmatch(r'[a-z][a-z0-9-]{0,62}(?:\.[a-z0-9][a-z0-9-]{0,62})*', host):
            raise FleetError('Use nomes DNS de máquinas, sem IP, curingas ou comandos.')
        agent_id = host.split('.')[0]
        if agent_id in ids:
            raise FleetError('Há destinos repetidos ou com a mesma identidade curta.')
        ids.add(agent_id)
        hosts.append((host, agent_id))
    return hosts


def validate(args):
    parsed = urlsplit(args.home_url)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in ('', '/'):
        raise FleetError('Use a origem HTTPS do Facilitador, sem credenciais ou caminhos.')
    if not args.scripts_root.startswith('\\\\'):
        raise FleetError('ScriptsRoot deve ser um caminho UNC.')
    if not re.fullmatch(r'[A-Z0-9_-]{1,32}', args.client_id):
        raise FleetError('ClientId inválido.')
    if not 1 <= args.slots <= 16:
        raise FleetError('Slots deve estar entre 1 e 16.')
    if args.activate and not args.apply:
        raise FleetError('Ativação exige --apply.')
    return targets(args.hosts)


class Portal:
    def __init__(self, url):
        self.url = url.rstrip('/')
        self.http = requests.Session()
        self.token = ''

    def call(self, method, path, body=None):
        try:
            response = self.http.request(method, self.url+path, json=body,
                headers={'X-Session-Token': self.token} if self.token else {}, timeout=30, allow_redirects=False)
        except requests.RequestException as error:
            raise FleetError('Falha de comunicação HTTPS com o Facilitador.') from error
        if not response.ok or response.is_redirect:
            raise FleetError(f'Portal HTTP {response.status_code}: {path}')
        return response.json()

    def job(self, path, body):
        job_id = self.call('POST', path, body)['job_id']
        deadline = time.monotonic()+120
        while time.monotonic() < deadline:
            data = self.call('GET', '/jobs/'+job_id)
            if data['status'] in ('concluido', 'erro'):
                if data['status'] == 'erro':
                    raise FleetError('Autenticação recusada; confira o painel.')
                return data
            time.sleep(2)
        raise FleetError('Autenticação excedeu dois minutos; confira os agentes existentes.')

    def login(self):
        user = input('Usuário administrador do Facilitador: ').strip()
        password = secret('Senha do Facilitador: ')
        try:
            data = self.job('/login/step1', {'user': user, 'password': password})
        finally:
            password = None
        result = data.get('resultado') or {}
        if result.get('otp_necessario'):
            otp = secret('MFA: ')
            try:
                data = self.job('/login/step2', {'user': user, 'otp': otp, 'transaction_id': result.get('transaction_id')})
            finally:
                otp = None
        self.token = data.get('token', '')
        if not self.token or not data.get('tem_admin'):
            raise FleetError('É necessária sessão administrativa original, sem simulação de nível.')
        self.call('GET', '/admin/agents')

    def agents(self):
        return self.call('GET', '/admin/agents')

    def close(self):
        try:
            if self.token:
                try:
                    self.call('POST', '/session/logout')
                except FleetError:
                    pass
        finally:
            self.token = ''
            self.http.close()


def check_contract(data, agent_data, client_id, hosts, activate):
    if data['client_id'] != client_id or agent_data['client_id'] != client_id:
        raise FleetError('CLIENT_ID do portal não corresponde ao cliente informado.')
    contract = data.get('contract')
    if not data.get('configured') or not data.get('accepting_jobs') or not contract:
        raise FleetError('Configure um contrato vigente antes de provisionar a frota.')
    modules = contract['modules']
    if isinstance(modules, str):
        modules = json.loads(modules)
    if 'execucao' not in modules:
        raise FleetError('Contrato não habilita execução.')
    existing = {a['id']: a for a in agent_data['agents']}
    for _, agent_id in hosts:
        item = existing.get(agent_id)
        if item and (item['desired'] != 'drain' or item.get('heartbeat') is not None or item['running'] or item['inventory_writer']):
            raise FleetError(f'{agent_id}: já cadastrado/em uso; esta versão instala somente agentes novos.')
    active = sum(a['desired'] == 'active' and a['id'] != 'legado' for a in existing.values())
    if activate and active+len(hosts) > contract['max_agents']:
        raise FleetError('A ativação excederia o máximo de agentes do contrato.')


def activation_policy(contract_data, agent_data, client_id, agent_id, now):
    contract = contract_data.get('contract') or {}
    modules = contract.get('modules', [])
    if isinstance(modules, str):
        modules = json.loads(modules)
    if contract_data['client_id'] != client_id or agent_data['client_id'] != client_id or not contract_data.get('configured') or not contract_data.get('accepting_jobs') or 'execucao' not in modules:
        raise FleetError('Contrato mudou durante a instalação; agente permanece drenado.')
    count = sum(a['desired']=='active' and a['id']!='legado' for a in agent_data['agents'])
    if count >= contract.get('max_agents', 0):
        raise FleetError('Limite de agentes atingido; novo agente permanece drenado.')
    ready = next((a for a in agent_data['agents'] if a['id']==agent_id), None)
    if not ready or ready['desired']!='drain' or not ready['ready'] or (ready['heartbeat'] or 0)<now-45 or ready['running']:
        raise FleetError('Prontidão/política mudou; ativação interrompida.')
    return {**{k:ready[k] for k in ('slots','pool','capabilities','inventory_writer')}, 'desired':'active'}


def remote(pwsh, package, host, agent_id, args, code=None, task_user=None, task_password=None):
    # Somente parâmetros não secretos no argv; credenciais/código no pipe anônimo.
    payload = {'code': code, 'user': task_user, 'password': task_password}
    command = [pwsh, '-NoProfile', '-NonInteractive', '-File', str(package/'gerenciar-frota.ps1'),
        '-Mode', 'Install' if code else 'Inspect', '-ComputerName', host, '-AgentId', agent_id,
        '-HomeUrl', args.home_url, '-ScriptsRoot', args.scripts_root, '-ClientId', args.client_id,
        '-Slots', str(args.slots), '-PythonExe', args.python_exe]
    try:
        result = subprocess.run(command, input=json.dumps(payload), capture_output=True,
            text=True, encoding='utf-8', errors='replace', timeout=900 if code else 90)
    except subprocess.TimeoutExpired as error:
        raise FleetError(f'{host}: tempo remoto excedido. Confira a tarefa antes de repetir; a ação remota pode continuar.') from error
    finally:
        payload.clear()
    lines = [line.removeprefix('MAGBEL_FLEET:') for line in result.stdout.splitlines() if line.startswith('MAGBEL_FLEET:')]
    if not lines:
        raise FleetError(f'{host}: sem relatório. Confira confiança da assinatura e política de execução do gerenciador.')
    data = json.loads(lines[-1])
    if result.returncode or not data.get('ok'):
        raise FleetError(f"{host}: etapa {data.get('phase','?')} recusada ({data.get('error_id','?')}).")
    return data


def wait_ready(portal, agent_id, started, timeout=120):
    deadline = time.monotonic()+timeout
    while time.monotonic() < deadline:
        agent = next((a for a in portal.agents()['agents'] if a['id'] == agent_id), None)
        if agent and agent['desired'] == 'drain' and agent['ready'] and (agent['heartbeat'] or 0) >= max(started, time.time()-45) and agent['running'] == 0:
            return agent
        time.sleep(3)
    raise FleetError(f'{agent_id}: sem prontidão recente. Mantido drenado; confira agent.log e permissões UNC/WinRM da tarefa.')


def main(argv=None):
    parser = argparse.ArgumentParser(description='Conferir e instalar agentes novos pela rede; sem --apply apenas consulta.')
    parser.add_argument('--hosts', nargs='+', required=True)
    parser.add_argument('--package', required=True)
    parser.add_argument('--home-url', default='https://facilitador-tjpb.magbel.com.br')
    parser.add_argument('--scripts-root', default=r'\\facilitador.tjpb.jus.br\facilitador_storage$\Scripts')
    parser.add_argument('--client-id', default='TJPB')
    parser.add_argument('--slots', type=int, default=2)
    parser.add_argument('--python-exe', default='python')
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--activate', action='store_true')
    args = parser.parse_args(argv)
    hosts = validate(args)
    if sys.platform != 'win32':
        raise FleetError('Execute o gerenciador em Windows, sob sua conta de domínio autorizada.')
    pwsh = shutil.which('pwsh')
    if not pwsh:
        raise FleetError('PowerShell 7 não encontrado no computador administrador.')
    package = Path(args.package).resolve()
    verify_package(pwsh, package, executable=package/'gerenciar-frota.ps1')
    for host, agent_id in hosts:
        report = remote(pwsh, package, host, agent_id, args)
        print(f"{host}: conferido; Python {report['python']}; tarefa existente: {report['existing_task']}")
        if report['existing_task'] or report['existing_runtime']:
            raise FleetError(f'{host}: instalação existente preservada. Use atualização com drenagem, não nova inscrição.')
    if not args.apply:
        print('Conferência concluída. Nenhum cadastro, arquivo ou tarefa foi alterado.')
        return 0
    portal = Portal(args.home_url)
    try:
        portal.login()
        check_contract(portal.call('GET', '/admin/contract'), portal.agents(), args.client_id, hosts, args.activate)
        task_user = input('Conta de domínio para a tarefa dos agentes (DOMINIO\\usuario): ').strip()
        if not task_user or '\\' not in task_user:
            raise FleetError('Informe a conta de domínio para a tarefa; SYSTEM não é selecionado por padrão.')
        task_password = secret('Senha da conta de execução (não será gravada pelo gerenciador): ')
        try:
            for host, agent_id in hosts:
                current = portal.agents()
                check_contract(portal.call('GET', '/admin/contract'), current, args.client_id, [(host,agent_id)], args.activate)
                existing = next((a for a in current['agents'] if a['id']==agent_id), None)
                if existing:
                    # Somente cadastro drenado que nunca enviou heartbeat; recuperação explícita da instalação incompleta.
                    print(f'{agent_id}: renovando inscrição do cadastro ainda não utilizado.')
                    enrollment = portal.call('POST', '/admin/agents/'+agent_id+'/rotate')
                else:
                    enrollment = portal.call('POST', '/admin/agents', {'id':agent_id,'hostname':host,'slots':args.slots,'capabilities':['auth','ad','winrm'],'inventory_writer':False})
                started = int(time.time())
                try:
                    remote(pwsh, package, host, agent_id, args, enrollment['enrollment_code'], task_user, task_password)
                finally:
                    enrollment.clear()
                ready = wait_ready(portal, agent_id, started)
                print(f'{agent_id}: tarefa instalada e prontidão comunicada. Isso não substitui o teste real WinRM no destino.')
                if args.activate:
                    contract = portal.call('GET', '/admin/contract')
                    latest = portal.agents()
                    policy = activation_policy(contract, latest, args.client_id, agent_id, time.time())
                    portal.call('PATCH', '/admin/agents/'+agent_id, policy)
                    print(f'{agent_id}: ativado. Publicador do catálogo existente preservado.')
        finally:
            task_password = None
    finally:
        portal.close()
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (FleetError, ValueError, OSError, KeyboardInterrupt) as error:
        print(f'Interrompido: {error}', file=sys.stderr)
        raise SystemExit(1)
