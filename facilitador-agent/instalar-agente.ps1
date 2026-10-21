#Requires -RunAsAdministrator
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
    [string]$CaBundle = ''
)
$ErrorActionPreference = 'Stop'
if (-not $HomeUrl.StartsWith('https://')) { throw 'HomeUrl exige HTTPS.' }
if ($AgentId -notmatch '^[a-zA-Z0-9_.-]{1,64}$') { throw 'AgentId inválido.' }
$TaskName = "Magbel-Facilitador-$AgentId"
$Existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($Existing -and $Existing.State -eq 'Running') { throw 'Drene o agente, aguarde zerar os trabalhos e pare a tarefa antes de atualizar.' }
$Root = Join-Path $env:ProgramData "Magbel\FacilitadorAgent\$AgentId"
New-Item -ItemType Directory -Path $Root -Force | Out-Null
# Segredos/configuração acessíveis somente por SYSTEM e Administradores locais.
& icacls.exe $Root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Não foi possível proteger o diretório.' }
$Venv = Join-Path $Root 'venv'
if (-not (Test-Path "$Venv\Scripts\python.exe")) {
    & $PythonExe -m venv $Venv
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao criar ambiente Python. Instale Python 3.10+ para todas as contas.' }
}
$Python = Join-Path $Venv 'Scripts\python.exe'
& $Python -m pip install --disable-pip-version-check -r "$PSScriptRoot\requirements.txt"
if ($LASTEXITCODE -ne 0) { throw 'Falha nas dependências.' }
Copy-Item "$PSScriptRoot\facilitador-agent.py" "$Root\facilitador-agent.py" -Force
$Config = @{
    HOME_URL = $HomeUrl.TrimEnd('/'); CLIENT_ID = $ClientId.ToUpperInvariant()
    AGENT_BASE_DIR = $Root; AGENT_STATE_DIR = $Root; SCRIPTS_ROOT = $ScriptsRoot
    AGENT_SLOTS = "$Slots"
    PRIVACYIDEA_URL = $PrivacyIdeaUrl; AD_REALM = $AdRealm
    PYTHONUTF8 = '1'; PYTHONUNBUFFERED = '1'
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
    $Code = Read-Host 'Código de inscrição do painel (válido 10 min)' -AsSecureString
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
@'
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Config = Get-Content "$Root\config.json" -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($Entry in $Config.PSObject.Properties) { [Environment]::SetEnvironmentVariable($Entry.Name, [string]$Entry.Value, 'Process') }
$Log = Join-Path $Root 'agent.log'
if ((Test-Path $Log) -and (Get-Item $Log).Length -gt 10MB) { Move-Item $Log "$Log.1" -Force }
& "$Root\venv\Scripts\python.exe" "$Root\facilitador-agent.py" 2>&1 | Out-File $Log -Encoding UTF8 -Append
exit $LASTEXITCODE
'@ | Set-Content "$Root\run-agent.ps1" -Encoding UTF8
$Pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$Action = New-ScheduledTaskAction -Execute $Pwsh -Argument "-NoProfile -File `"$Root\run-agent.ps1`"" -WorkingDirectory $Root
$Trigger = New-ScheduledTaskTrigger -AtStartup
$Principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$Settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Write-Host "Agente inscrito e supervisionado por $TaskName. Consulte $Root\agent.log."
Write-Host 'Executa como SYSTEM: valide leitura do compartilhamento e direitos WinRM dessa identidade. O painel manterá o agente drenado até a ativação.'
