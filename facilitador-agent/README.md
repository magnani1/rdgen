# Facilitador Agent Windows 2.0

Executor Windows do Facilitador, separado do repositório do backend. Adaptado do agente fornecido pelo operador para identidade individual, limite de vagas, heartbeat e prontidão independentes, ownership da tentativa, drain e caminhos configuráveis.

Requer backend com `/fila/enroll` e `/fila/heartbeat` (entrega agentes/contratos/suporte de 21/10/2026), Python 3.10+, PowerShell 7, RSAT para autenticação/AD e os direitos efetivos das ações executadas. O instalador não concede esses direitos.

## Instalação

Cadastre o agente no painel administrativo do cliente; ele nasce drenado. Use o código de inscrição de 10 minutos. No APP correspondente, PowerShell elevado, a partir do checkout deste repositório:

```powershell
.\facilitador-agent\instalar-agente.ps1 `
  -HomeUrl 'https://facilitador-tjpb.magbel.com.br' `
  -ScriptsRoot '\\facilitador.tjpb.jus.br\facilitador_storage$\Scripts' `
  -AgentId 'facilitadorapp1' -ClientId 'TJPB' -Slots 2
```

Confirme o compartilhamento real e a identidade por host; repetir APP2–7 com IDs correspondentes e códigos próprios. Não copiar identity.json para outro cliente ou host. O agente mantém a identidade após reiniciar.

O instalador cria tarefa `Magbel-Facilitador-<id>` como SYSTEM, ambiente Python e pasta `C:\ProgramData\Magbel\FacilitadorAgent\<id>` legível apenas por SYSTEM/Administradores. Configuração e token ficam nessa pasta; não publicar nem anexar seus arquivos. Para CA interna em PEM, passar `-CaBundle <arquivo.pem>`; o bundle é combinado com as CAs públicas e usado na validação TLS. Não usar certificado DER nem desativar validação TLS.

SYSTEM acessa recursos da rede conforme os direitos da máquina/ambiente. O sucesso da sessão interativa do instalador não comprova esses direitos. Valide o compartilhamento, RSAT, WinRM e máquina de teste pela tarefa definitiva. Para gMSA/outro usuário, adaptar principal/ACLs com a equipe de domínio; o instalador atual não configura essa variante.

Depois da primeira sonda, verificar prontidão no painel e só então ativar. A publicação de inventário é atribuída pelo servidor a um agente; o parâmetro do navegador não altera essa autorização. GAM/GCDS/WinGet precisam existir no contexto da tarefa, podendo usar GAM_PATH/GCDS_PATH/WINGET_PATH no config.json privado.

## Operação

- Heartbeat a cada 20 s, separado da sonda. Sonda atrasada/inconclusiva suspende novas entregas sem bloquear renovação de trabalhos em andamento.
- Vagas locais e backend limitam a execução; o pool não acumula uma fila oculta. O backend atribui cliente, ID, pool e capacidades.
- Todo callback leva token da tentativa. Upload é restrito ao job aceito; o adaptador atual passa o arquivo como parâmetro `arquivo` para execução local. Upload remoto exige adaptador específico e falha explicitamente antes de executar.
- Drain para novas entregas e aguarda atuais. Encerramento abrupto, perda de resposta final ou timeout podem produzir resultado desconhecido; não repetir ação. Conferir destino e reconciliar no painel.
- Scripts antigos e Executar-WinRM continuam com seu dispatcher. Há serialização local no backend para proteger parâmetros globais. Essa proteção não cobre outro cliente em outra stack usando os mesmos arquivos/host.
- O Python não depende de D:. Scripts institucionais ainda podem depender de caminhos/ferramentas locais; validar antes da ativação. Os scripts da origem não são alterados.
- stdout/stderr do watcher vão ao log local por job, evitando bloqueio de pipe. O log remoto continua sendo enviado ao backend. Timeout local também funciona quando o processo não produz stdout.

Logs: agent.log (rotacionado na inicialização ao ultrapassar 10 MB), Logs/info_<job>.txt e Logs/watcher_<job>.txt. Revise a retenção conforme a operação. Não anexar logs sem verificar conteúdo sensível produzido pelos scripts.

## Atualização e rotação

Drenar, aguardar zero trabalhos e parar a tarefa. Atualizar checkout Git, executar novamente o instalador e iniciar/ativar. O instalador recusa atualizar tarefa em execução e preserva identidade existente. O backend emite código novo após rotação; para reinscrever, com a tarefa parada, guardar a identidade antiga em local privado e remover o identity.json ativo, depois executar o instalador com o código novo. Rotação no backend é recusada enquanto houver trabalho ativo.

O pacote ainda não tem assinatura de código, instalador MSI/WinGet ou atualizador automático. Avaliar a política de assinatura antes da distribuição ampla. As sondas de leitura não instalam software nem alteram contas como teste de disponibilidade.

Documentação completa de implantação/retirada do legado: https://github.com/magnani1/facilitador-core/blob/main/OPERACAO-AGENTES.md .

## Testes

```bash
python -m pip install -r facilitador-agent/requirements.txt
python -m unittest discover -s facilitador-agent/tests -v
python -m py_compile facilitador-agent/facilitador-agent.py
```

Os testes não executam scripts reais, WinRM, AD ou privacyIDEA. O workflow Windows também analisa a sintaxe do instalador; a validação funcional deve ocorrer no APP de teste com a conta definitiva.
