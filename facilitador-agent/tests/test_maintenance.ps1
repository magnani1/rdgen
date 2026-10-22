#Requires -Version 7.0
# Runner descartável: mocks de WinRM/tarefas; troca real de arquivo com Python real no PS 5.1.
$ErrorActionPreference='Stop'
$Root=Join-Path $PSScriptRoot '..'
$Helper=Join-Path $Root 'manutencao-agente.ps1'
$Agent=Join-Path $Root 'facilitador-agent.py'
$Temp=Join-Path $env:TEMP ('maintenance-fixture-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Temp | Out-Null
$Capture=@{}
function Get-AuthenticodeSignature {param($LiteralPath) [pscustomobject]@{Status='Valid'}}
function Invoke-Command {
    param($ComputerName,$Authentication,$ConfigurationName,$ArgumentList,$ScriptBlock)
    if ($Authentication -ne 'Kerberos' -or $ConfigurationName -ne 'Microsoft.PowerShell') {throw 'WrongEndpoint'}
    $Capture.Block=$ScriptBlock;$Capture.Arguments=$ArgumentList
}
try {
    & $Helper -ComputerName $env:COMPUTERNAME -OperationId ('a'*32) -Action Apply -AgentSourcePath $Agent
    if ($Capture.Arguments.Count -ne 6) {throw 'UnexpectedTransport'}
    $Current=[Text.Encoding]::UTF8.GetString($Capture.Arguments[3])
    $Old=$Current.Replace("import uuid`n",'').Replace('VERSION = "2.0.4"'+"`n"+'BOOT_ID = uuid.uuid4().hex','VERSION = "2.0.3"').Replace('"version": VERSION, "boot_id": BOOT_ID,','"version": VERSION,')
    $env:MAGBEL_MAINT_BLOCK=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Capture.Block.ToString()))
    $env:MAGBEL_MAINT_NEW=[Convert]::ToBase64String($Capture.Arguments[3])
    $env:MAGBEL_MAINT_OLD=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Old))
    $env:MAGBEL_MAINT_HASH=$Capture.Arguments[4]
    $env:MAGBEL_MAINT_PREVIOUS=$Capture.Arguments[5]
    $env:MAGBEL_MAINT_TEMP=$Temp
    $Fixture=@'
$ErrorActionPreference='Stop'
$env:ProgramData=Join-Path $env:MAGBEL_MAINT_TEMP 'ProgramData'
$State=@{Status='Running';Starts=0;Stops=0}
function Get-ScheduledTask {param($TaskName) [pscustomobject]@{State=$State.Status;Principal=[pscustomobject]@{LogonType='Password'}}}
function Get-CimInstance {param($ClassName,$Filter) return @()}
function Export-ScheduledTask {param($TaskName) '<Task>fixture</Task>'}
function Stop-ScheduledTask {param($TaskName) $State.Status='Ready';$State.Stops++}
function Start-ScheduledTask {param($TaskName) $State.Status='Running';$State.Starts++}
function icacls.exe {$global:LASTEXITCODE=0}
$Block=[scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:MAGBEL_MAINT_BLOCK)))
$Bytes=[Convert]::FromBase64String($env:MAGBEL_MAINT_NEW)
$Old=[Convert]::FromBase64String($env:MAGBEL_MAINT_OLD)
$Id=$env:COMPUTERNAME.ToLowerInvariant()
$Root=Join-Path $env:ProgramData ('Magbel\FacilitadorAgent\'+$Id)
New-Item -ItemType Directory -Path $Root -Force | Out-Null
$Venv=Join-Path $Root 'venv'
& python -m venv $Venv
if ($LASTEXITCODE -ne 0) {throw 'FixtureVenvFailed'}
$Target=Join-Path $Root 'facilitador-agent.py'
$Config=Join-Path $Root 'config.json'
$Identity=Join-Path $Root 'identity.json'
[IO.File]::WriteAllBytes($Target,$Old)
@{AGENT_BASE_DIR=$Root;AGENT_PYTHON=(Join-Path $Venv 'Scripts\python.exe')} | ConvertTo-Json | Set-Content $Config -Encoding UTF8
'preserved-fixture' | Set-Content $Identity -Encoding UTF8
$BeforeConfig=(Get-FileHash $Config).Hash
$BeforeIdentity=(Get-FileHash $Identity).Hash
$Operation='a'*32
$Result=(& $Block $Id $Operation Apply $Bytes $env:MAGBEL_MAINT_HASH $env:MAGBEL_MAINT_PREVIOUS) | ConvertFrom-Json
if (-not $Result.Ok -or $State.Stops -ne 1 -or $State.Starts -ne 1) {throw 'ApplyFailed'}
if ((Get-FileHash $Target).Hash.ToLowerInvariant() -ne $env:MAGBEL_MAINT_HASH) {throw 'NewCodeMismatch'}
$Repeated=(& $Block $Id $Operation Apply $Bytes $env:MAGBEL_MAINT_HASH $env:MAGBEL_MAINT_PREVIOUS) | ConvertFrom-Json
if ($Repeated.Ok -or $Repeated.RollbackAvailable -or $State.Starts -ne 1) {throw 'RepeatedUpdateChangedState'}
$Rollback=(& $Block $Id $Operation Rollback $Bytes $env:MAGBEL_MAINT_HASH $env:MAGBEL_MAINT_PREVIOUS) | ConvertFrom-Json
if (-not $Rollback.Ok -or $State.Starts -ne 2 -or (Get-FileHash $Target).Hash.ToLowerInvariant() -ne $env:MAGBEL_MAINT_PREVIOUS) {throw 'RollbackFailed'}
if ((Get-FileHash $Config).Hash -ne $BeforeConfig -or (Get-FileHash $Identity).Hash -ne $BeforeIdentity) {throw 'IdentityChanged'}
# Um backup adulterado nunca pode ser executado.
$BackupFile=Join-Path $env:ProgramData ('Magbel\AgentCodeBackups\'+$Id+'\'+$Operation+'\before.py')
Add-Content $BackupFile '# transport-corruption'
$Bad=(& $Block $Id $Operation Rollback $Bytes $env:MAGBEL_MAINT_HASH $env:MAGBEL_MAINT_PREVIOUS) | ConvertFrom-Json
if ($Bad.Ok -or $State.Starts -ne 2) {throw 'CorruptRollbackAccepted'}
Write-Host 'PS5.1: apply/rollback reais, identidade/tarefa preservadas, repetição e corrupção recusadas: OK'
'@
    $Encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Fixture))
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -EncodedCommand $Encoded
    if ($LASTEXITCODE -ne 0) {throw 'NativeMaintenanceFailed'}
} finally {
    Get-ChildItem Env:MAGBEL_MAINT_* | Remove-Item
    Remove-Item $Temp -Recurse -Force
}
