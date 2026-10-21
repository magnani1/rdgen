# APP1–7: instalação do zero e base do futuro EXE

Procedimento para Windows x64 em domínio, PowerShell 7 elevado. Repositório: magnani1/rdgen, branch master. O aplicativo necessário para clonar é Git (Git.Git); GitHub Desktop e GitHub CLI não são obrigatórios. Não copiar identidade de outro APP.

## 1. Limpar somente o checkout copiado

No APP1, sair da pasta antiga antes de removê-la. Se existir tarefa do agente, drenar no painel e aguardar zero trabalhos antes de parar. Não interromper agente que esteja executando ação. Não apagar ProgramData: contém a identidade individual e eventuais evidências. A falha de certificado ocorreu antes da inscrição nesta tentativa, mas uma instalação anterior pode existir.

```powershell
Set-Location C:\
$Repo = 'C:\Magbel\rdgen'
Get-ScheduledTask -TaskName 'Magbel-Facilitador-facilitadorapp1' -ErrorAction SilentlyContinue |
    Select-Object TaskName,State
if (Test-Path "$Repo\.git") {
    git -C $Repo status --short
    if ($LASTEXITCODE -ne 0) { throw 'Não foi possível conferir o checkout.' }
}
```

Revisar a saída. Se houver alterações, preservar a pasta inteira em backup local privado antes de excluir: assinatura local e arquivos não rastreados também contam. Esse checkout copiado não deve conter identity.json/token do APP2; se contiver, não distribuir seus arquivos nem reenviar como anexo. O procedimento remove apenas o caminho literal abaixo:

```powershell
if (Test-Path -LiteralPath 'C:\Magbel\rdgen') {
    Remove-Item -LiteralPath 'C:\Magbel\rdgen' -Recurse -Force -Confirm
}
```

## 2. Instalar ferramentas

```powershell
winget install --id Git.Git --exact --source winget
winget install --id Microsoft.PowerShell --exact --source winget
```

Conferir resultado de cada instalação; pacote já instalado não precisa ser reinstalado. Fechar o terminal e abrir PowerShell 7 como administrador para atualizar PATH.

```powershell
$PSVersionTable.PSVersion
git --version
py -3.14 --version
py -3.14 -c 'import struct,sys; print(sys.executable); print(struct.calcsize("P")*8)'
```

Python 3.14 x64 já instalado no APP1 pode ser reutilizado. Em máquina nova, consultar `winget search --id Python.Python.3.14 --exact --source winget` e instalar o ID se listado. Confirmar 64 bits; não substituir por Python 3.9. A identidade da tarefa precisa acessar o runtime base, além do venv: para conta diferente do instalador, preferir instalação para todas as contas conforme a política local. Não assumir que um Python na pasta privada de outro usuário estará acessível.

## 3. Clonar origem limpa

```powershell
New-Item -ItemType Directory -Path C:\Magbel -Force | Out-Null
git clone --branch master --single-branch https://github.com/magnani1/rdgen.git C:\Magbel\rdgen
if ($LASTEXITCODE -ne 0) { throw 'Clone falhou; não continuar.' }
git -C C:\Magbel\rdgen status --short
git -C C:\Magbel\rdgen rev-parse HEAD
```

Assinaturas são aplicadas à cópia de distribuição, fora do checkout. Um clone contém fonte, não um pacote automaticamente assinado pela instituição. Não mudar ExecutionPolicy nem importar certificados de confiança automaticamente.

## 4. Preparar pacote na estação de assinatura (uma vez por versão)

Executar no computador autorizado que já possui o certificado de code signing e a chave privada. Não exportar a chave privada para APP1–7. Atualizar/clonar master nessa estação. Se a política exige assinatura para executar o preparador, assiná-lo pelo processo institucional habitual antes de chamar. O preparador não altera o checkout e recusa sobrescrever destino existente.

```powershell
$CertThumbprint = 'THUMBPRINT_DO_CERTIFICADO_INSTITUCIONAL'
& 'C:\Magbel\rdgen\facilitador-agent\preparar-pacote-assinado.ps1' `
    -CertificateThumbprint $CertThumbprint `
    -Destination 'C:\Magbel\pacotes\facilitador-agent-assinado-001'
```

O pacote inclui instalar-agente.ps1 e run-agent.ps1 assinados com o mesmo certificado, Python do agente, requirements e documentação. Não inclui senha, identidade ou token. Distribuir a pasta inteira pelo canal institucional, por exemplo para C:\Magbel\pacotes\facilitador-agent-assinado-001 no APP1. A cadeia/publicador devem ser confiáveis conforme GPO/PKI no contexto do instalador e da tarefa. O SHA256.json é conferência de transporte, não uma assinatura do conjunto de arquivos Python.

## 5. Instalar no APP1 sem chave privada

No APP1, dentro do PowerShell 7 elevado:

```powershell
$Pacote = 'C:\Magbel\pacotes\facilitador-agent-assinado-001'
Get-AuthenticodeSignature "$Pacote\instalar-agente.ps1","$Pacote\run-agent.ps1" |
    Select-Object Path,Status,@{Name='Publicador';Expression={$_.SignerCertificate.Subject}}
```

Ambos devem estar Valid; caso contrário corrigir assinatura/cadeia pelo processo institucional. Depois cadastrar facilitadorapp1 no painel, duas vagas, cliente TJPB, capacidades comprovadas. O agente começa drenado. Gerar código próprio imediatamente antes da inscrição (10 min). Selecionar apenas um publicador de inventário na frota.

```powershell
$Python314 = (& py -3.14 -c 'import sys; print(sys.executable)').Trim()
if ($LASTEXITCODE -ne 0) { throw 'Python 3.14 não encontrado.' }
$Cred = Get-Credential -UserName 'tj-pb\01440538450' -Message 'Conta de execução do agente APP1'
try {
    & "$Pacote\instalar-agente.ps1" `
        -PackageRoot $Pacote `
        -SignedLauncherPath "$Pacote\run-agent.ps1" `
        -HomeUrl 'https://facilitador-tjpb.magbel.com.br' `
        -ScriptsRoot '\\facilitador.tjpb.jus.br\facilitador_storage$\Scripts' `
        -AgentId 'facilitadorapp1' -ClientId TJPB -Slots 2 `
        -PythonExe $Python314 -RunAsCredential $Cred
}
finally { $Cred = $null }
```

A senha é solicitada pela credencial uma vez; o código de inscrição é outro segredo e será solicitado pelo instalador. Usar `&`, não `pwsh $Instalador -RunAsCredential $Cred`: um novo processo transforma o objeto em texto e gera o erro de identidade System.Management.Automation.PSCredential. Nunca colocar senha ou código em argumento de linha de comando.

Se houver identidade anterior válida em ProgramData, ela será preservada e não será solicitado novo código. Se a identidade foi copiada do APP2 ou revogada, manter drenado e tratar a reinscrição individual; não apagar automaticamente a pasta e não reaproveitar token de outro host.

## 6. Aceite antes de ativar

```powershell
(Get-ScheduledTask 'Magbel-Facilitador-facilitadorapp1').Principal |
    Format-List UserId,LogonType
Get-Content 'C:\ProgramData\Magbel\FacilitadorAgent\facilitadorapp1\agent.log' -Encoding UTF8 -Tail 40
```

Esperado: conta escolhida, LogonType Password, heartbeat e prontidão no painel. Validar UNC, RSAT/AD e WinRM pela identidade da tarefa; a conta interativa funcionar não basta. Usar máquina de teste aprovada. Ativar, testar login/MFA e uma ação; com APP1 e APP2 testar destinos distintos e mesmo destino. Não retirar legado antes desses testes. Para APP3–7 mudar ID, código e nome da tarefa; nunca copiar ProgramData.

## 7. Especificação do futuro assistente Python/EXE

Ainda não há EXE produzido nesta entrega. Reutilizar o instalador testado e introduzir uma interface que:

- detecta hostname, Windows x64, PowerShell, domínio e runtime acessível à conta definitiva;
- seleciona perfil TJPB/TJPE com endereço HTTPS e origem aprovados, vagas e capacidades;
- solicita inscrição e credencial sem log, arquivo temporário ou argumento visível de processo;
- usa diálogo de credencial do próprio processo PowerShell ou IPC protegido: não serializar PSCredential na linha de comando;
- distribui launcher previamente assinado e verifica publicador, integridade e versão dos arquivos do pacote;
- preserva identidade/configuração existente e impede atualização com trabalhos/tarefa ativos;
- incorpora runtime Python ou o instala por mecanismo verificável, dispensando Git no destino;
- recebe assinatura Authenticode do EXE e processo de release/rollback sem segredos embutidos;
- registra apenas etapas e diagnósticos sem senhas/tokens e mantém novo agente drenado até aceite.

Antes da distribuição ampla, testar também instalação limpa com AllSigned, pacote adulterado, certificado sem confiança, conta sem UNC/WinRM, atualização interrompida e identidade existente. Os testes de CI não substituem GPO/PKI e tarefas reais do domínio.
