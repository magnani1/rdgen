#Requires -Version 7.0
#Requires -RunAsAdministrator
[CmdletBinding()]
param([switch]$BootstrapFromStdin)
$ErrorActionPreference='Stop'
$PackageHashesBase64='__MAGBEL_SERVICE_HASHES__'
if (-not $BootstrapFromStdin) {throw 'Use o instalador remoto assinado; parâmetros sensíveis entram somente pelo pipe.'}
if ((Get-AuthenticodeSignature -LiteralPath $PSCommandPath).Status -ne 'Valid') {throw 'Instalador sem assinatura confiável.'}
if ($PackageHashesBase64 -eq '__MAGBEL_SERVICE_HASHES__') {throw 'Prepare o pacote institucional na estação de assinatura.'}
$InputData=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([Console]::In.ReadToEnd().Trim())) | ConvertFrom-Json
if ($InputData.id -notmatch '^[a-z][a-z0-9-]{0,63}$' -or $InputData.client_id -notmatch '^[A-Z0-9_-]{1,32}$') {throw 'Identidade/cliente inválido.'}
if ($InputData.hostname.Split('.')[0] -ine $env:COMPUTERNAME) {throw 'Máquina de instalação divergente.'}
$Uri=[Uri]$InputData.home_url
if ($Uri.Scheme -ne 'https' -or $Uri.UserInfo -or $Uri.Query -or $Uri.Fragment -or $Uri.AbsolutePath -ne '/') {throw 'Origem HTTPS inválida.'}
$Python=[IO.Path]::GetFullPath([string]$InputData.python)
if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {throw 'Python informado não encontrado; não será instalada outra versão.'}
$Account=[Security.Principal.NTAccount]::new([string]$InputData.username)
$Sid=$Account.Translate([Security.Principal.SecurityIdentifier]).Value
$TaskName='Magbel-Manutencao-'+$InputData.id
$Root=Join-Path $env:ProgramData ('Magbel\Maintenance\'+$InputData.id)
$Parent=Split-Path $Root -Parent
foreach ($Path in @($env:ProgramData,(Join-Path $env:ProgramData 'Magbel'),$Parent,$Root)) {
    if ((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'Runtime de manutenção não pode atravessar junction/link.'}
}
$Existing=Test-Path -LiteralPath $Root
$CurrentTask=Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (($Existing -or $CurrentTask) -and -not $InputData.repair) {throw 'Instalação já existe; use reparo da tarefa, sem reinscrever.'}
if ($InputData.repair -and (-not $Existing -or [string]$CurrentTask.State -eq 'Running')) {throw 'Reparo exige runtime existente e tarefa parada após concluir as operações.'}
$Hashes=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($PackageHashesBase64)) | ConvertFrom-Json -AsHashtable
$Names=@('permanent_maintenance.py','maintenance_controller.py','fleet_manager.py','setup_assistant.py','facilitador-agent.py','manutencao-agente.ps1','requirements.txt')
if ((($Hashes.Keys | Sort-Object) -join ',') -ne (($Names | Sort-Object) -join ',')) {throw 'Lista do pacote divergente.'}
foreach ($Name in $Names) {
    if ((Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $Name) -Algorithm SHA256).Hash -ne $Hashes[$Name]) {throw "Arquivo do pacote alterado: $Name"}
}
if ((Get-AuthenticodeSignature -LiteralPath (Join-Path $PSScriptRoot 'manutencao-agente.ps1')).Status -ne 'Valid') {throw 'Helper sem assinatura confiável.'}
if (-not $Existing) {
New-Item -ItemType Directory -Path $Parent -Force | Out-Null
$null=& icacls.exe $Parent /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' "*${Sid}:(OI)(CI)RX"
if ($LASTEXITCODE -ne 0) {throw 'Não foi possível proteger a pasta de manutenção.'}
New-Item -ItemType Directory -Path $Root | Out-Null
$null=& icacls.exe $Root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' "*${Sid}:(OI)(CI)RX"
if ($LASTEXITCODE -ne 0) {throw 'Não foi possível proteger o runtime.'}
$Package=Join-Path $Root 'package';$Logs=Join-Path $Root 'logs'
New-Item -ItemType Directory -Path $Package,$Logs | Out-Null
$null=& icacls.exe $Logs /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' "*${Sid}:(OI)(CI)M"
if ($LASTEXITCODE -ne 0) {throw 'Não foi possível proteger os logs.'}
foreach ($Name in $Names) {Copy-Item -LiteralPath (Join-Path $PSScriptRoot $Name) -Destination $Package}
@{hashes=$Hashes} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Root 'service.json') -Encoding UTF8
$Venv=Join-Path $Root 'venv'
& $Python -m venv $Venv
if ($LASTEXITCODE -ne 0) {throw 'Falha no ambiente isolado do serviço.'}
$Runtime=Join-Path $Venv 'Scripts\python.exe'
& $Runtime -m pip install -r (Join-Path $Package 'requirements.txt')
if ($LASTEXITCODE -ne 0) {throw 'Falha nas dependências do serviço.'}
$Worker=Join-Path $Package 'permanent_maintenance.py'
$Registration=@{id=$InputData.id;client_id=$InputData.client_id;home_url=$InputData.home_url;code=$InputData.code} | ConvertTo-Json -Compress
$Registration | & $Runtime -X utf8 $Worker --enroll --root $Root
if ($LASTEXITCODE -ne 0) {throw 'Inscrição não concluída; nenhuma tarefa foi criada.'}
} else {
    $Package=Join-Path $Root 'package';$Logs=Join-Path $Root 'logs';$Runtime=Join-Path $Root 'venv\Scripts\python.exe';$Worker=Join-Path $Package 'permanent_maintenance.py'
    foreach ($Name in $Names) {
        if ((Get-FileHash -LiteralPath (Join-Path $Package $Name) -Algorithm SHA256).Hash -ne $Hashes[$Name]) {throw 'Reparo exige exatamente o pacote instalado; não troca código.'}
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'identity.json')) -or -not (Test-Path -LiteralPath $Runtime)) {throw 'Inscrição/runtime incompletos; conferir antes de reparar.'}
}
try {
    $Action=New-ScheduledTaskAction -Execute $Runtime -Argument ('-X utf8 -u "'+$Worker+'" --run --root "'+$Root+'"') -WorkingDirectory $Root
    $Trigger=New-ScheduledTaskTrigger -AtStartup
    $Settings=New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable -MultipleInstances IgnoreNew
    $ForceRegistration=[bool]$InputData.repair
    $null=Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -User $InputData.username -Password $InputData.password -RunLevel Highest -Force:$ForceRegistration
    Start-ScheduledTask -TaskName $TaskName
} finally {$InputData.password=$null;$InputData.code=$null;$Registration=$null}
[pscustomobject]@{Computer=$env:COMPUTERNAME;Task=$TaskName;Root=$Root;Log=(Join-Path $Logs 'maintenance.log');Identity='DPAPI LocalMachine + ACL; senha Windows somente no Agendador'}
