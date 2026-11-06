"""Uma sessão MFA: publicar backend, preparar conector e atualizar agentes em sequência."""
import argparse
import os
from pathlib import Path
import re
import shlex
import subprocess
import time
from urllib.parse import urlsplit
from fleet_manager import FleetError, Portal
from maintenance_controller import VERSION, SOURCE_HASH, source_hash

OPEN = {'queued','claimed','draining','stopping','applying','validating','rolling_back','validating_rollback','unknown'}


def no_open(data):
    if any(op['state'] in OPEN for op in data['operations']):
        raise FleetError('Há manutenção aberta ou desconhecida; conferir antes de iniciar outra entrega.')


def snapshot(portal, ids, version):
    data = portal.agents()
    if data['client_id'] != 'TJPB':
        raise FleetError('Este aplicador é destinado ao cliente TJPB.')
    if any(j.get('agent_id') in ids for j in data.get('unknown_jobs', [])):
        raise FleetError('Há execução com resultado desconhecido em um dos destinos; conferir antes de atualizar.')
    selected = {a['id']: a for a in data['agents'] if a['id'] in ids}
    if len(selected) != len(ids):
        raise FleetError('Um dos executores solicitados não está cadastrado.')
    for a in selected.values():
        if a['id'] == 'legado' or a['desired'] not in ('active','drain') or not a['ready'] or time.time()-(a.get('heartbeat') or 0) > 90:
            raise FleetError(a['id']+': executor sem prontidão/contato ou estado incompatível.')
    return selected


def rollout(portal, ids, version=VERSION, pause=time.sleep, clock=time.monotonic, timeout=1200):
    data = portal.call('GET','/admin/maintenance')
    no_open(data)
    if data['version'] != version:
        raise FleetError('O backend não oferece a versão esperada: '+version)
    selected = snapshot(portal, ids, version)
    # Todos os destinos precisam ter conector compatível antes do primeiro agendamento.
    hosts = {h for c in data['controllers'] if c['versions'] == [version] and
             time.time()-c['heartbeat'] <= 60 for h in c['hosts']}
    if any(a['version'] != version and a['hostname'].lower() not in hosts for a in selected.values()):
        raise FleetError('Conector assinado compatível indisponível para um dos destinos.')
    for agent_id in ids:
        current = dict(snapshot(portal, [agent_id], version)[agent_id])
        if current['version'] == version:
            print(agent_id+': já está pronto na versão '+version+'; preservado.', flush=True)
            continue
        # Nova conferência junto ao agendamento; o backend também aplica seus locks.
        no_open(portal.call('GET','/admin/maintenance'))
        operation = portal.call('POST','/admin/maintenance/agents/'+agent_id)['id']
        print(agent_id+': atualização solicitada; aguardando drenagem e validação.', flush=True)
        deadline = clock()+timeout
        while True:
            data = portal.call('GET','/admin/maintenance')
            op = next((o for o in data['operations'] if o['id'] == operation), None)
            if not op:
                raise FleetError('Operação não encontrada; conferir painel antes de repetir.')
            if op['state'] == 'completed':
                a = snapshot(portal, [agent_id], version)[agent_id]
                if a['version'] != version or not a.get('boot_id') or a['boot_id'] == current.get('boot_id'):
                    raise FleetError(agent_id+': processo/versão não confirmados; sequência interrompida.')
                print(agent_id+': '+version+' confirmado e pronto.', flush=True)
                break
            if op['state'] not in OPEN or op['state'] == 'unknown' or clock() >= deadline:
                raise FleetError(agent_id+': '+op['state']+'; conferir a operação '+operation+' antes de continuar.')
            pause(3)
    return selected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--home-url', default='https://facilitador-tjpb.magbel.com.br')
    parser.add_argument('--agents', nargs='+', required=True)
    parser.add_argument('--backend-ssh', default='')
    parser.add_argument('--backend-dir', default='/dados_servidor/facilitador-core')
    parser.add_argument('--certificate', default='')
    parser.add_argument('--repo', default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument('--connector-host', default='facilitadorapp4.tjpb.jus.br')
    parser.add_argument('--service-id', default='manutencao-tjpb-app4')
    parser.add_argument('--check-only', action='store_true')
    args = parser.parse_args()
    if len(set(args.agents)) != len(args.agents) or any(not re.fullmatch(r'[a-z][a-z0-9-]{0,63}', v) for v in args.agents):
        raise FleetError('Informe IDs explícitos de executores, sem repetição.')
    root = Path(__file__).resolve().parent
    if source_hash(root/'facilitador-agent.py') != SOURCE_HASH:
        raise FleetError('Checkout fora do código homologado.')
    url=urlsplit(args.home_url)
    if url.scheme!='https' or not url.hostname or url.username or url.password or url.query or url.fragment or url.path not in ('','/'):
        raise FleetError('Use a origem HTTPS do Facilitador, sem credenciais ou caminhos.')
    if args.backend_ssh and not re.fullmatch(r'[a-zA-Z0-9_][a-zA-Z0-9_.-]*@[a-zA-Z0-9][a-zA-Z0-9_.-]*', args.backend_ssh):
        raise FleetError('Destino SSH inválido.')
    if args.certificate and not re.fullmatch(r'[0-9a-fA-F]{40}', args.certificate):
        raise FleetError('Thumbprint inválido.')
    portal = Portal(args.home_url)
    try:
        portal.login()
        no_open(portal.call('GET','/admin/maintenance'))
        snapshot(portal, args.agents, VERSION)
        if args.check_only:
            print('Conferência concluída. Backend, conector e agentes preservados.')
            return
        if args.backend_ssh:
            remote = 'cd '+shlex.quote(args.backend_dir)+' && git switch main && git pull --ff-only && python3 scripts/aplicar-deploy-dietpi.py --apply'
            subprocess.run(['ssh','-t',args.backend_ssh,remote],check=True)
        if args.certificate:
            if os.name != 'nt':
                raise FleetError('Preparação assinada exige a estação Windows.')
            # A operação anterior pode ter sido criada durante o deploy do backend.
            no_open(portal.call('GET','/admin/maintenance'))
            subprocess.run(['pwsh','-NoProfile','-File',str(root/'preparar-iot-ldap-214.ps1'),
                '-Repo',args.repo,'-CertificateThumbprint',args.certificate,
                '-ComputerName',args.connector_host,'-ServiceId',args.service_id,
                '-ConfirmarSemManutencaoAberta'],check=True)
            deadline=time.monotonic()+90
            while True:
                data=portal.call('GET','/admin/maintenance')
                if any(c['versions']==[VERSION] and
                       all(a['hostname'].lower() in c['hosts'] for a in snapshot(portal,args.agents,VERSION).values())
                       for c in data['controllers']):
                    break
                if time.monotonic() >= deadline:
                    raise FleetError('Pacote novo do conector ainda não confirmado; nenhum agente agendado.')
                time.sleep(3)
        rollout(portal,args.agents)
        print('Entrega concluída: backend validado quando solicitado; executores selecionados prontos em '+VERSION+'.')
    finally:
        portal.close()


if __name__ == '__main__':
    try:
        main()
    except (FleetError, OSError, subprocess.SubprocessError) as error:
        print('Interrompido: '+str(error))
        raise SystemExit(1)
