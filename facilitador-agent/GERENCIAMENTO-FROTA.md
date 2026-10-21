# Gerenciamento central de novos agentes

O computador administrador pode ser `facilitador.tjpb.jus.br`, autenticado no domínio com acesso administrativo WinRM aos APPs. O servidor de arquivos continua servindo Scripts. APP1 permanece responsável pelo catálogo; a frota nova não toma essa função.

Comece pelo APP3: APP1 + APP2 + APP3 com duas vagas cada têm até seis slots antes dos limites do contrato/pool e da reserva de autenticação. Isso não comprova seis execuções simultâneas elegíveis. APP4 pode ser adicionado depois conforme fila, duração e disponibilidade. Ter um terceiro worker permite testar a operação com um agente indisponível, mas não torna o backend, o banco ou o compartilhamento redundantes. A capacidade restante precisa ser testada com a carga real.

## Escopo desta versão

O gerenciador Python inspeciona os destinos, autentica no Facilitador com login/MFA, confere cliente/contrato, cadastra agente drenado, gera inscrição individual, instala via WinRM e aguarda heartbeat pronto. Com `--activate`, ativa após nova conferência de prontidão e limite de agentes. Sem `--apply`, somente inspeciona. A ativação não substitui o teste WinRM em um computador de destino.

Instala apenas máquinas sem runtime/tarefa existente. Recusa APP1/APP2 se já instalados; não mata processos, não revoga identidade existente, não atualiza os agentes em uso e não altera slots do contrato. Falha interrompe a sequência: agentes já concluídos mantêm seu estado e o agente que falhou permanece drenado, salvo alteração concorrente de outro administrador. Repetição não é automática. Após timeout, conferir tarefa e painel antes de tentar novamente, pois uma ação remota pode continuar.

## Pré-requisitos

- Administrador: Windows, PowerShell 7 e Python 3.12+ x64 com `requests`; conta de domínio autorizada para WinRM. Não usa token de proprietário ou CortenDesk.
- Destinos: PowerShell 7, endpoint WinRM **PowerShell.7**, Python 3.12+ x64 acessível à conta da tarefa, cadeia de assinatura confiável, acesso HTTPS ao Facilitador/PyPI e permissões UNC/WinRM da conta de execução. Recomenda-se Python 3.14 x64 instalado para todos os usuários.
- O gerenciador não instala pré-requisitos nem altera TrustedHosts, CredSSP, políticas de execução, confiança de certificados, firewall ou permissões do domínio.
- O pacote deve ter sido preparado na estação de assinatura. Não executar o helper não preparado do checkout.

O ISE usa Windows PowerShell 5.1. Use-o para consultas e para abrir um terminal PowerShell 7; execute o gerenciador nesse terminal. Senhas exigem console com entrada oculta e não são aceitas em argumentos. Não usar transcrição, gravação de tela de credenciais ou depurador com captura dos objetos de entrada.

Para conferir o endpoint, do computador administrador:

```powershell
Invoke-Command -ComputerName facilitadorapp3 -Authentication Kerberos {
    Get-PSSessionConfiguration | Select-Object Name
    Get-Command pwsh,python -ErrorAction SilentlyContinue | Select-Object Name,Source
}
```

Se PowerShell 7 estiver instalado e o endpoint não existir, a preparação autorizada no APP é executar **dentro do PowerShell 7**, como administrador:

```powershell
Enable-PSRemoting -Force
```

Isso registra o endpoint da versão que executa o comando e pode configurar regras de firewall. Aplique conforme a política institucional; o gerenciador não faz essa alteração. Consulte a documentação Microsoft de [Enable-PSRemoting](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/enable-psremoting) e [segundo salto](https://learn.microsoft.com/powershell/scripting/security/remoting/ps-remoting-second-hop).

## Preparar pacote na estação que tem a chave privada

Atualizar o checkout pelo Git antes de assinar; não assinar arquivos dentro do checkout. Usar uma pasta nova fora dele:

```powershell
$Repo = '\\facilitadorapp1\c$\Magbel\rdgen'
$Pacote = '\\facilitadorapp1\c$\Magbel\pacotes\frota-' + (Get-Date -Format yyyyMMdd-HHmmss)
$Thumbprint = '828D73E9B099D50DE42443ACEF7E224EE8D52A5D'
$Cert = Get-ChildItem Cert:\CurrentUser\My,Cert:\LocalMachine\My -CodeSigningCert |
    Where-Object { $_.HasPrivateKey -and $_.Thumbprint -eq $Thumbprint } |
    Select-Object -First 1
if (-not $Cert) { throw 'Certificado e chave privada ausentes nesta estação.' }

# Cópia temporária para assinar o preparador sem modificar o checkout.
$Fonte = Join-Path $env:TEMP ('magbel-assinatura-' + [guid]::NewGuid().ToString('N'))
Copy-Item -LiteralPath "$Repo\facilitador-agent" -Destination $Fonte -Recurse
try {
    $Preparador = Join-Path $Fonte 'preparar-pacote-assinado.ps1'
    $Assinatura = Set-AuthenticodeSignature -FilePath $Preparador -Certificate $Cert -HashAlgorithm SHA256
    if ($Assinatura.Status -ne 'Valid') { throw 'Assinatura do preparador não validada.' }
    & $Preparador -CertificateThumbprint $Thumbprint -Destination $Pacote
    Write-Host "Pacote: $Pacote"
} finally {
    Remove-Item -LiteralPath $Fonte -Recurse -Force
}
```

Executar essa preparação em SEDE153729 ou outra estação que possua o certificado e sua chave privada. Se a política exigir assinatura do próprio preparador, assine a cópia usada nessa estação conforme o procedimento institucional. Nunca exportar a chave para os APPs. O EXE de instalação individual continua opcional (`-AssistantExe`).

Além de assinar instalador/launcher, o preparador assina `gerenciar-frota.ps1` incorporando hashes dos arquivos operacionais. O helper valida esses hashes e as assinaturas antes da conexão; no destino, confere os quatro arquivos transferidos novamente. SHA256.json continua sendo apenas conferência de transporte, não a raiz de confiança.

## Executar no computador administrador

Ajustar `$Pacote` para a pasta realmente preparada. Copiar a pasta inteira pelo canal institucional para um caminho local protegido; não editar seus arquivos.

```powershell
$Pacote = 'C:\Magbel\pacotes\frota-AAAAMMDD-HHMMSS'
py -3.14 -m venv C:\Magbel\frota-venv
& 'C:\Magbel\frota-venv\Scripts\python.exe' -m pip install -r "$Pacote\requirements.txt"

# Conferência apenas: não altera cadastro nem destino.
& 'C:\Magbel\frota-venv\Scripts\python.exe' "$Pacote\fleet_manager.py" `
    --hosts facilitadorapp3.tjpb.jus.br `
    --package $Pacote `
    --python-exe 'C:\Program Files\Python314\python.exe'
```

O caminho de Python é do APP, não do computador administrador. Ajustar ao caminho real disponível à conta da tarefa. A consulta exibe a versão e se há runtime/tarefa existente. Problema na etapa `PowerShell.7-Kerberos` exige conferir endpoint, DNS/SPN, WinRM e permissões.

Após conferência aprovada:

```powershell
& 'C:\Magbel\frota-venv\Scripts\python.exe' "$Pacote\fleet_manager.py" `
    --hosts facilitadorapp3.tjpb.jus.br `
    --package $Pacote `
    --python-exe 'C:\Program Files\Python314\python.exe' `
    --slots 2 --apply --activate
```

O gerenciador solicita usuário/senha/MFA do Facilitador e depois a conta/senha para executar a tarefa. A sessão é própria e encerrada ao final. A credencial WinRM é a conta de domínio do processo administrador; a senha solicitada para a tarefa pode ser de outra conta autorizada. O Windows armazena a credencial da tarefa pelo mecanismo do Agendador, como na instalação individual. O gerenciador não cria arquivo de senha, token ou inscrição; usa memória e pipe local e transmite PSCredential/SecureString pela sessão Kerberos.

Para mais destinos, informar nomes explicitamente, por exemplo `--hosts facilitadorapp3.tjpb.jus.br facilitadorapp4.tjpb.jus.br`. Os IDs são os nomes curtos em minúsculas. Não são aceitos IPs, curingas ou duplicatas. A execução é sequencial para não criar pico de instalação ou consumir inscrições antes da hora. Ajustar `--home-url`, `--client-id` e `--scripts-root` para outro cliente somente após provisionar seu portal separado.

## Falhas e recuperação

- Registro drenado que nunca enviou heartbeat pode ter sua inscrição renovada pelo gerenciador se o destino continuar sem runtime/tarefa. Não reutiliza cadastro com contato prévio, publicador ou trabalhos.
- Se houver pasta/runtime parcial, parar e examinar localmente. Esta versão não apaga dados para contornar falha; códigos consumidos e identidade criada exigem conferência.
- Pacote é transferido com Copy-Item -ToSession, evitando que o APP precise ler o UNC do pacote durante a sessão WinRM. A tarefa instalada lê Scripts com sua própria identidade depois; o heartbeat de prontidão confere essa condição.
- Pacote temporário remoto usa ACL restrita e é removido ao final. Não incluir segredos em arquivos do pacote nem nos argumentos.
- Confirmar no painel versão, horário, duas vagas e diagnóstico do APP3; testar uma ação real e uma interrupção controlada de um worker antes de ampliar.

## Verificação desta entrega

Testes automatizados cobrem validação de destinos/contrato, preservação de instalações existentes, transporte sem segredo no argv e recusa de prontidão insuficiente. CI Windows verifica sintaxe PowerShell e preparação/assinatura do pacote. Os testes não acessam as máquinas do domínio; o primeiro aceite real deve ser no APP3. Atualização de agentes existentes e EXE próprio de gerenciamento de frota permanecem etapas futuras.
