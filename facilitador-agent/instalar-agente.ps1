#Requires -RunAsAdministrator
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$HomeUrl,
    [Parameter(Mandatory)][string]$ScriptsRoot,
    [string]$ClientId = 'TJPB',
    [string]$AgentId = $env:COMPUTERNAME.ToLowerInvariant(),
    [ValidateRange(1,16)][int]$Slots = 2,
    [string]$PythonExe = 'python',
    [string]$PrivacyIdeaUrl = 'https://auth.tjpb.jus.br/validate/check',
    [string]$AdRealm = 'tjpb.jus.br',
    [string]$CaBundle = '',
    [System.Management.Automation.PSCredential]$RunAsCredential,
    [switch]$RecreateVenv,
    [System.Security.SecureString]$EnrollmentCode,
    [switch]$PromptRunAsCredential,
    [string]$RunAsUserName = '',
    [string]$SigningCertificateThumbprint = '',
    [string]$SignedLauncherPath = '',
    [string]$PackageRoot = $PSScriptRoot
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding

function Assert-AgentPython {
    param($Info)
    if ([int]$Info.major -ne 3 -or [int]$Info.minor -lt 12 -or [int]$Info.bits -ne 64) {
        throw 'O agente exige Python 3.12+ x64. Para Windows, use Python 3.14 x64; recrie o venv antigo com -RecreateVenv.'
    }
}

function Get-AgentPython {
    param([string]$Executable)
    $Result = & $Executable -c 'import json,sys,struct; print(json.dumps(dict(major=sys.version_info.major,minor=sys.version_info.minor,bits=struct.calcsize("P")*8,executable=sys.executable)))'
    if ($LASTEXITCODE -ne 0) { throw 'Não foi possível verificar o interpretador Python.' }
    $Info = $Result | ConvertFrom-Json
    Assert-AgentPython $Info
    return $Info
}

function Register-AgentTask {
    param([hashtable]$Registration, [System.Management.Automation.PSCredential]$Credential)
    if ($Credential) {
        # Logon com senha permite autenticação de rede. Não usar S4U.
        $TaskPassword = $Credential.GetNetworkCredential().Password
        try { Register-ScheduledTask @Registration -User $Credential.UserName -Password $TaskPassword -RunLevel Highest | Out-Null }
        finally { $TaskPassword = $null }
    } else {
        $Principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask @Registration -Principal $Principal | Out-Null
    }
}

function Assert-SignedAgentLauncher {
    param([string]$Path, [string]$ExpectedThumbprint)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Launcher assinado não encontrado.' }
    $Signature = Get-AuthenticodeSignature -FilePath $Path
    if ($Signature.Status -ne 'Valid' -or -not $Signature.SignerCertificate) { throw 'Launcher sem assinatura válida e confiável.' }
    if ($ExpectedThumbprint -and $Signature.SignerCertificate.Thumbprint -ne $ExpectedThumbprint) {
        throw 'O launcher deve usar o mesmo certificado de assinatura do instalador.'
    }
}

function Get-AgentLauncher {
    return @'
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
$Root = $PSScriptRoot
$Config = Get-Content "$Root\config.json" -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($Entry in $Config.PSObject.Properties) { [Environment]::SetEnvironmentVariable($Entry.Name, [string]$Entry.Value, 'Process') }
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
$Log = Join-Path $Root 'agent.log'
if ((Test-Path $Log) -and (Get-Item $Log).Length -gt 10MB) {
    Copy-Item $Log (Join-Path $Root 'Logs\agent.log.1') -Force
    '' | Out-File $Log -Encoding utf8BOM
}
& $Config.AGENT_PYTHON "$Root\facilitador-agent.py" 2>&1 | Out-File $Log -Encoding utf8BOM -Append
exit $LASTEXITCODE
'@
}

if (-not $HomeUrl.StartsWith('https://')) { throw 'HomeUrl exige HTTPS.' }
if ($AgentId -notmatch '^[a-zA-Z0-9_.-]{1,64}$') { throw 'AgentId inválido.' }
$TaskName = "Magbel-Facilitador-$AgentId"
$Existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($Existing -and $Existing.State -eq 'Running') { throw 'Drene o agente, aguarde zerar os trabalhos e pare a tarefa antes de atualizar.' }
$InstallerSignature = Get-AuthenticodeSignature -FilePath $PSCommandPath
$ExpectedSigner = $InstallerSignature.SignerCertificate.Thumbprint
if ($SignedLauncherPath) {
    $SignedLauncherPath = (Resolve-Path -LiteralPath $SignedLauncherPath).Path
    Assert-SignedAgentLauncher $SignedLauncherPath $ExpectedSigner
}
$Root = Join-Path $env:ProgramData "Magbel\FacilitadorAgent\$AgentId"
New-Item -ItemType Directory -Path $Root -Force | Out-Null
# Proteção inicial; acesso de leitura da identidade selecionada é aplicado antes de iniciar a tarefa.
& icacls.exe $Root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Não foi possível proteger o diretório.' }
if ($PromptRunAsCredential) {
    if ($RunAsCredential) { throw 'Escolha credencial fornecida ou solicitação interativa, não ambas.' }
    if ($RunAsUserName) { $RunAsCredential = Get-Credential -UserName $RunAsUserName -Message 'Conta de execução do agente' }
    else { $RunAsCredential = Get-Credential -Message 'Conta de execução do agente' }
    if (-not $RunAsCredential) { throw 'Credencial cancelada; instalação interrompida.' }
}
$RunAsSid = if ($RunAsCredential) {
    ([System.Security.Principal.NTAccount]::new($RunAsCredential.UserName)).Translate([System.Security.Principal.SecurityIdentifier]).Value
} else { 'S-1-5-18' }
# Resolve o certificado antes de alterar runtime/tarefa. Reutiliza a assinatura do instalador quando possível.
if (-not $SignedLauncherPath -and -not $SigningCertificateThumbprint) {
    $SigningCertificateThumbprint = (Get-AuthenticodeSignature -FilePath $PSCommandPath).SignerCertificate.Thumbprint
}
$SigningCertificate = $null
if (-not $SignedLauncherPath -and $SigningCertificateThumbprint) {
    foreach ($Store in @('Cert:\CurrentUser\My', 'Cert:\LocalMachine\My')) {
        $Candidate = Get-Item "$Store\$SigningCertificateThumbprint" -ErrorAction SilentlyContinue
        if ($Candidate -and $Candidate.HasPrivateKey) { $SigningCertificate = $Candidate; break }
    }
    if (-not $SigningCertificate) { throw 'Chave privada ausente. Use o pacote preparado na estação de assinatura e -SignedLauncherPath; não copie a chave privada para o APP.' }
}
$ConfigPath = Join-Path $Root 'config.json'
$PreviousSid = if (Test-Path $ConfigPath) { (Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json).AGENT_RUN_AS_SID } else { $null }
$Venv = Join-Path $Root 'venv'
$VenvBackup = $null
if ($RecreateVenv -or -not (Test-Path "$Venv\Scripts\python.exe")) {
    $SelectedPython = Get-AgentPython $PythonExe
    if (Test-Path $Venv) {
        $VenvBackup = "$Venv-before-$(Get-Date -Format yyyyMMddTHHmmss)-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        Move-Item $Venv $VenvBackup
    }
    try {
        & $SelectedPython.executable -m venv $Venv
        if ($LASTEXITCODE -ne 0) { throw 'Falha ao criar ambiente Python.' }
        $Python = Join-Path $Venv 'Scripts\python.exe'
        $null = Get-AgentPython $Python
        & $Python -m pip install --disable-pip-version-check -r "$PackageRoot\requirements.txt"
        if ($LASTEXITCODE -ne 0) { throw 'Falha nas dependências.' }
    } catch {
        if ($VenvBackup) {
            if (Test-Path $Venv) { Move-Item $Venv "$Venv-failed-$([guid]::NewGuid().ToString('N'))" }
            Move-Item $VenvBackup $Venv
        }
        throw
    }
} else {
    $Python = Join-Path $Venv 'Scripts\python.exe'
    $null = Get-AgentPython $Python
    & $Python -m pip install --disable-pip-version-check -r "$PackageRoot\requirements.txt"
    if ($LASTEXITCODE -ne 0) { throw 'Falha nas dependências.' }
}
Copy-Item "$PackageRoot\facilitador-agent.py" "$Root\facilitador-agent.py" -Force
$Config = @{
    HOME_URL = $HomeUrl.TrimEnd('/'); CLIENT_ID = $ClientId.ToUpperInvariant()
    AGENT_BASE_DIR = $Root; AGENT_STATE_DIR = $Root; SCRIPTS_ROOT = $ScriptsRoot
    AGENT_SLOTS = "$Slots"
    PRIVACYIDEA_URL = $PrivacyIdeaUrl; AD_REALM = $AdRealm
    PYTHONUTF8 = '1'; PYTHONUNBUFFERED = '1'; PYTHONIOENCODING = 'utf-8'
    AGENT_PYTHON = $Python; AGENT_RUN_AS_SID = $RunAsSid
}
if ($CaBundle) {
    $DefaultCa = & $Python -c "import certifi; print(certifi.where())"
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao localizar CAs públicas.' }
    $Bundle = [IO.File]::ReadAllText($DefaultCa.Trim()) + "`n" + [IO.File]::ReadAllText((Resolve-Path $CaBundle).Path)
    [IO.File]::WriteAllText("$Root\ca.pem", $Bundle, (New-Object System.Text.UTF8Encoding $false))
    $Config['REQUESTS_CA_BUNDLE'] = "$Root\ca.pem"
}
$Config | ConvertTo-Json | Set-Content "$Root\config.json" -Encoding UTF8
foreach ($Entry in $Config.GetEnumerator()) { [Environment]::SetEnvironmentVariable($Entry.Key, $Entry.Value, 'Process') }
if (-not (Test-Path "$Root\identity.json")) {
    $Code = if ($EnrollmentCode) { $EnrollmentCode } else { Read-Host 'Código de inscrição do painel (válido 10 min)' -AsSecureString }
    $Ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Code)
    try {
        $env:AGENT_ENROLLMENT_CODE = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Ptr)
        & $Python "$Root\facilitador-agent.py" --enroll-only
        if ($LASTEXITCODE -ne 0) { throw 'Inscrição falhou; não foi registrada a tarefa.' }
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Ptr)
        Remove-Item Env:\AGENT_ENROLLMENT_CODE -ErrorAction SilentlyContinue
    }
}
if ($SignedLauncherPath) {
    Copy-Item -LiteralPath $SignedLauncherPath -Destination "$Root\run-agent.ps1" -Force
    Assert-SignedAgentLauncher "$Root\run-agent.ps1" $ExpectedSigner
} else {
    Get-AgentLauncher | Set-Content "$Root\run-agent.ps1" -Encoding utf8BOM
}
if ($SigningCertificate) {
    $Signature = Set-AuthenticodeSignature -FilePath "$Root\run-agent.ps1" -Certificate $SigningCertificate -HashAlgorithm SHA256
    if ($Signature.Status -ne 'Valid') { throw "Assinatura do launcher inválida: $($Signature.Status). A tarefa não foi atualizada." }
}
# Remove apenas grants da identidade anterior atribuídos por este instalador.
if ($PreviousSid -and $PreviousSid -notin @($RunAsSid,'S-1-5-18','S-1-5-32-544')) {
    & icacls.exe $Root /remove:g "*$PreviousSid" /T /C | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao remover ACL da conta anterior.' }
}
foreach ($Directory in @('Logs','Uploads')) { New-Item -ItemType Directory -Path (Join-Path $Root $Directory) -Force | Out-Null }
$Stamp = Get-Date -Format yyyyMMddTHHmmss
if (Test-Path "$Root\agent.log") { Move-Item "$Root\agent.log" "$Root\Logs\agent-before-$Stamp-$([guid]::NewGuid().ToString('N').Substring(0,8)).log" }
'' | Out-File "$Root\agent.log" -Encoding utf8BOM
if ($RunAsSid -notin @('S-1-5-18','S-1-5-32-544')) {
    & icacls.exe $Root /grant:r "*${RunAsSid}:(OI)(CI)RX" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao conceder leitura/execução à identidade da tarefa.' }
    foreach ($Directory in @('Logs','Uploads')) {
        & icacls.exe (Join-Path $Root $Directory) /grant:r "*${RunAsSid}:(OI)(CI)M" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Falha ao conceder escrita nas pastas de trabalho.' }
    }
    & icacls.exe "$Root\agent.log" /grant:r "*${RunAsSid}:M" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao conceder escrita no log.' }
}
$Pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$Action = New-ScheduledTaskAction -Execute $Pwsh -Argument "-NoProfile -File `"$Root\run-agent.ps1`"" -WorkingDirectory $Root
$Trigger = New-ScheduledTaskTrigger -AtStartup
$Settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable -MultipleInstances IgnoreNew
$Registration = @{ TaskName=$TaskName; Action=$Action; Trigger=$Trigger; Settings=$Settings; Force=$true }
Register-AgentTask -Registration $Registration -Credential $RunAsCredential
$Registered = Get-ScheduledTask -TaskName $TaskName
if ($RunAsCredential -and [string]$Registered.Principal.LogonType -ne 'Password') { throw 'Logon de rede não foi registrado como Password; tarefa não iniciada.' }
Start-ScheduledTask -TaskName $TaskName
Write-Host "Agente inscrito e supervisionado por $TaskName. Consulte $Root\agent.log."
Write-Host "Identidade da tarefa: $($Registered.Principal.UserId). Valide UNC e WinRM nessa identidade; mantenha drenado até o teste."
if ($VenvBackup) { Write-Host "Venv anterior preservado em $VenvBackup. identity.json foi mantido." }
