# Monitoramento remoto 2.0.8 — 29/10/2026

O Kodak levou 22m36s. O agente 2.0.7 parava o watcher aos 600s; a tarefa SYSTEM
continuava no cliente. O worker descartava mensagens fora da lista Epson. Esta
entrega aproveita o worker ajustado fornecido em 29/10 e passa a encaminhar linhas
genéricas, com fallback para processo.log quando o log principal está vazio.

O executor 2.0.8 passa `-TimeoutSeconds 7200` ao worker e aguarda até 60s adicionais
pelo resultado. `AGENT_REMOTE_TIMEOUT_SECONDS` permite 30–14400s no ambiente do
processo do agente; o padrão não exige editar config.json. O limite de ações
locais continua 600s; adaptador WinGet continua com seu prazo próprio.

Não encerra watcher por texto SUCESSO de um componente. Só confirma execução pelo
término do worker com código zero. Watcher com falha ou prazo excedido retorna
incerteza e bloqueia repetição, porque o instalador remoto pode continuar. O prazo
da tarefa agendada continua sendo controlado pelo Windows: filhos/resultado
precisam ser conferidos após timeout. Não reinstala automaticamente.

## Primeiro liberar o registro antigo

Em Agentes e disponibilidade → Resultados desconhecidos, localizar o trabalho
Kodak de SOU130648.tjpb.jus.br. Conferir que a tarefa/instaladores terminaram e
validar o aplicativo. Então Registrar resultado verificado → concluido, com
destino, horário e evidência. O log de sucesso informado pelo script não comprova
sozinho uma digitalização. Se não houve aceite funcional, registrar exatamente o
que foi conferido. A reconciliação atualiza a execução e libera seu bloqueio;
não controla processos remotos. Não editar o SQLite nem revogar agente.

## Backend no DietPi

Atualizar facilitador-core pelo Git, preparar imagem, recriar as duas réplicas na
stack existente e executar os validadores. Marcador 20261029b. Manter
WINRM_DNS_SUFFIX=tjpb.jus.br e definir AGENT_APPROVED_VERSION=2.0.8 no ambiente do
backend. Esta variável não atualiza executores por si só. Mantém compatibilidade
de fila WinGet e sessões Windows com 2.0.7 durante o piloto. Ctrl+F5 no painel.

## Publicação assinada na SEDE153729

Conferir zero trabalhos nos executores drenados e nenhuma manutenção aberta.
Não parar um agente enquanto existir um instalador não conferido. O preparador
publica o worker compartilhado com backup, preserva Executar-TarefaLocal.ps1 e
atualiza o pacote do conector APP4. Não troca Python, credencial da tarefa,
configuração ou identidade dos executores. Chave privada permanece na SEDE.

Em PowerShell 7 elevado com a função Sign-File:

```powershell
$ErrorActionPreference = 'Stop'
$Repo = '\\facilitadorapp1\c$\Magbel\rdgen'
git -C $Repo pull --ff-only
if ($LASTEXITCODE -ne 0) { throw 'Git interrompido; preserve alterações locais.' }
$Trabalho = Join-Path $env:TEMP ('magbel-monitor208-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Trabalho | Out-Null
$Script = Join-Path $Trabalho 'preparar-monitoramento-208.ps1'
Copy-Item -LiteralPath (Join-Path $Repo 'facilitador-agent\preparar-monitoramento-208.ps1') -Destination $Script
Sign-File $Script
if ((Get-AuthenticodeSignature $Script).Status -ne 'Valid') { throw 'Assinatura não validada.' }
& $Script -Repo $Repo `
    -CertificateThumbprint '828D73E9B099D50DE42443ACEF7E224EE8D52A5D' `
    -ComputerName 'facilitadorapp4.tjpb.jus.br' `
    -ServiceId 'manutencao-tjpb-app4' `
    -ConfirmarSemManutencaoAberta -ConfirmarSemTrabalhos
```

Conferir pacote/conector 2.0.8 no painel. Após publicar o worker, reativar pelo
menos dois executores prontos, sem solicitar instalações durante o rollout: a
fila de manutenção exige outro executor ativo. Atualizar primeiro um executor 2.0.7 →
2.0.8 pelo painel, validar processo, prontidão e uma ação inofensiva com pausas e
logs; ativar e expandir uma máquina por vez. O helper faz rollback para a cópia
2.0.7 homologada se a validação falhar; isso não reverte instalação em cliente.

Se a preparação parar após publicar worker ou parar manutenção, conferir a saída,
backup e estado da tarefa antes de repetir. O worker novo é compatível com 2.0.7,
mas o timeout antigo só desaparece após atualizar o executor. Não usar o preparador
207 nem pedir downgrade no painel após este rollout.

Hash canônico do agente 2.0.8:
`e981aedb4db1a6cbfbcfc1e0c64f049d24d9591142ea4fae08f80be947d884ab`.

Assinatura, parser PowerShell, WinRM, cópia SMB e instalação real dependem do
aceite nativo Windows. Os testes simulados não comprovam esses itens. Nenhum
segredo está no pacote. Não compartilhar identity.json nem os backups privados.
