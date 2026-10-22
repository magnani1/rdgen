# Atualização de código pelo Facilitador

Esta entrega atualiza o agente homologado 2.0.3 para 2.0.4. A mudança no agente é um identificador aleatório de processo por inicialização, enviado no heartbeat. O backend consegue distinguir contato antigo do processo recém-iniciado. Não é inscrição, senha nem token.

Python e requests existentes são preservados; não há atualização automática para uma versão não homologada. A conta de serviço, tarefa, configuração e identity.json não são recriadas. O publicador não bloqueia a atualização nesta etapa de testes. Uma operação por vez e outro executor ativo/pronto são exigidos.

## Preparar na SEDE153729

PowerShell 7, sob a identidade administrativa autorizada via Kerberos. Atualize o checkout do APP1 e copie os três arquivos para uma pasta fora do checkout. O Python administrativo e requests já utilizados pelo gerenciador de frota continuam válidos.

```powershell
$ErrorActionPreference = 'Stop'
$Repo = '\\facilitadorapp1\c$\Magbel\rdgen'
git -C $Repo pull --ff-only
if ($LASTEXITCODE -ne 0) { throw 'Git interrompido; preserve alterações locais antes de continuar.' }
$Pacote = Join-Path $env:LOCALAPPDATA ('Magbel\manutencao-' + (Get-Date -Format yyyyMMdd-HHmmss))
New-Item -ItemType Directory -Path $Pacote -Force | Out-Null
foreach ($Nome in @('facilitador-agent.py','manutencao-agente.ps1','maintenance_controller.py','fleet_manager.py','setup_assistant.py')) {
    Copy-Item -LiteralPath (Join-Path $Repo "facilitador-agent\$Nome") -Destination $Pacote
}
Sign-File (Join-Path $Pacote 'manutencao-agente.ps1')
if ((Get-AuthenticodeSignature (Join-Path $Pacote 'manutencao-agente.ps1')).Status -ne 'Valid') { throw 'Assinatura não validada.' }
$PythonFrota = 'C:\Magbel\frota-venv\Scripts\python.exe'
& $PythonFrota (Join-Path $Pacote 'maintenance_controller.py') `
    --home-url 'https://facilitador-tjpb.magbel.com.br' `
    --hosts facilitadorapp1.tjpb.jus.br facilitadorapp2.tjpb.jus.br facilitadorapp3.tjpb.jus.br facilitadorapp4.tjpb.jus.br `
    --package $Pacote
```

A chave privada permanece na SEDE. O login solicitado é o administrador original do Facilitador com MFA, e não a conta de execução facilitador-servico. A sessão web existe somente na memória do conector. WinRM usa a identidade Windows atual; não pede nem armazena senha da conta de serviço. Não habilite endpoint PowerShell.7 nem altere TrustedHosts/CredSSP: usa Microsoft.PowerShell/Kerberos e PowerShell 7 local.

## Executar no painel

1. Implante primeiro o backend com a API /admin/maintenance e frontend 20261022b.
2. Mantenha o console do conector aberto. Em Agentes, confira o hostname do conector.
3. Abra Planejar atualização de um agente 2.0.3 e clique Atualizar código para 2.0.4. Comece por um piloto; depois enfileire os outros. Não precisa parar manualmente a tarefa.
4. Acompanhe Na fila → Drenando → Aplicando → Conferindo → Concluída.
5. O backend só autoriza troca após zero trabalhos, inclusive reservas desconhecidas. O helper para apenas a tarefa daquele agente e recusa processo remanescente. A cópia é compilada no Python configurado e substituída atomicamente.
6. Novo heartbeat 2.0.4, novo identificador e sondas aprovadas concluem a operação. Se estava ativo, volta a ativo conforme o contrato. Se estava drenado, permanece drenado. Execute teste real WinRM e login no piloto.

Para a referência de versão do painel, use AGENT_APPROVED_VERSION=2.0.4 nas duas réplicas. A comparação continua indicando a referência configurada; não consulta automaticamente releases externos. Nenhum token novo é necessário.

## Falhas e rollback

O backup fica em C:\ProgramData\Magbel\AgentCodeBackups\ID_DO_AGENTE\ID_DA_OPERACAO, protegido para SYSTEM e Administradores locais. Contém código anterior e hashes/XML da tarefa; não copia identity.json nem config.json. O helper valida o código novo com hash fixo dentro do script assinado e recusa alterações na inscrição, configuração ou tarefa.

Falha confirmada pelo helper após preparar o backup ou ausência de prontidão da nova versão aciona rollback do código. A versão anterior precisa comunicar e estar pronta; fica drenada para conferência. Se o WinRM/conector perder comunicação, a instalação não é repetida: após 180 segundos a operação vira resultado desconhecido, mantém drenagem e bloqueia novas trocas. Fechar a estação, expirar a sessão MFA ou interromper o conector não garante que o comando remoto não executou.

Nesse caso, confira tarefa, processos, agent.log, código instalado e backup no destino. Não reutilize o ID da operação para Apply. Se necessário, execute o mesmo helper assinado com -Action Rollback e o ID registrado na API; exige a inscrição/config/tarefa originais. Registre a conferência no painel para liberar a fila. Não remova backups enquanto não concluir o aceite.

Scheduler e ponte CortenDesk são independentes desta rotina. Nada aqui altera permissões de domínio, dependências Python, clientes RustDesk ou contratos.
