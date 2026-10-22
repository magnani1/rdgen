# Resultado desconhecido no conector permanente

A mensagem FleetError do log anterior não distingue HTTP, assinatura ou WinRM. Não prova a causa da interrupção. Quando a tarefa do destino não reiniciou e seu código continua 2.0.3, não repetir a instalação nem registrar conclusão sem conferir o contexto da conta de execução.

A sonda abaixo executa sob a mesma conta da tarefa permanente no APP4. Consulta a assinatura/publisher do helper, política efetiva, existência de processo do helper e acesso Kerberos ao APP1, incluindo token administrativo, tarefa e versão. Não executa o helper de atualização, scripts do catálogo, nem para/reinicia o agente. Não lê ou imprime senhas/tokens. Um comando PowerShell somente de leitura inspeciona a política; ela não é alterada e a assinatura obrigatória do helper de atualização não é contornada.

O wrapper é assinado na SEDE, fixa o hash da sonda Python e verifica o transporte. Cria uma tarefa diagnóstica temporária na mesma conta Windows, com saída privada, e remove somente essa tarefa ao terminar. A senha é informada no Get-Credential, transportada por WinRM/Kerberos e passada ao Agendador em memória. O arquivo de resultado não inclui credenciais, ambiente, stderr ou configurações completas. Não há reinscrição ou alteração do conector permanente.

## Executar na SEDE153729 — PowerShell 7

```powershell
$ErrorActionPreference = 'Stop'
$Repo = '\\facilitadorapp1\c$\Magbel\rdgen'
git -C $Repo pull --ff-only
if ($LASTEXITCODE -ne 0) { throw 'Git interrompido; preserve alterações locais antes de continuar.' }
$Fonte = Join-Path $Repo 'facilitador-agent'
$Diagnostico = Join-Path $env:TEMP ('magbel-diagnostico-' + [guid]::NewGuid().ToString('N') + '.ps1')
Copy-Item -LiteralPath (Join-Path $Fonte 'diagnosticar-manutencao-remota.ps1') -Destination $Diagnostico
Sign-File $Diagnostico
if ((Get-AuthenticodeSignature -LiteralPath $Diagnostico).Status -ne 'Valid') { throw 'Assinatura não validada.' }
& $Diagnostico `
    -ProbeSource (Join-Path $Fonte 'diagnosticar-manutencao.py') `
    -ComputerName 'facilitadorapp4.tjpb.jus.br' `
    -Target 'facilitadorapp1.tjpb.jus.br' `
    -ServiceId 'manutencao-tjpb-app4'
```

Informe a senha da conta Windows da tarefa permanente quando solicitado, nunca o token de inscrição ou senha do proprietário. O SID informado precisa corresponder à conta da tarefa permanente. A sonda usa o Python já instalado no runtime de manutenção; não instala dependências ou outra versão do Python.

## Interpretar

- HelperSignature diferente de Valid: conferir assinatura, integridade e cadeia de confiança na conta do serviço.
- PublisherTrusted false com política AllSigned: a confiança no publisher pode impedir execução não interativa; Valid sozinho comprova assinatura/cadeia, não a aprovação do publisher para essa conta. Conferir distribuição institucional de confiança antes de alterar política.
- Remote.Ok false e ErrorId de AccessDenied: conferir permissão da conta do serviço do APP4 no APP1. O acesso do seu usuário pessoal não comprova o acesso dessa conta.
- Remote.Ok true e AdminToken false: o acesso WinRM foi autorizado, mas conferir os direitos necessários à manutenção da tarefa e arquivos.
- HelperProcesses não vazio: há processo do helper; não repetir nem reconciliar enquanto o estado real não for conferido.
- Assinatura/WinRM aprovados não comprovam sucesso da API de progresso. O teste não envia callbacks, não muda estado no painel e não confirma atualizações.

Mantenha APP1 drenado. Cancele entradas de APP2/3 ainda na fila durante o diagnóstico. Registre a conferência de resultado desconhecido somente depois de identificar a falha e confirmar ausência de atualização em andamento; reative ou repita de forma controlada após corrigir a causa.
