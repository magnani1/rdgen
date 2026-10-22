#Requires -Version 7.0
# Somente runner descartável; nenhuma tarefa, inscrição ou conexão reais.
$ErrorActionPreference='Stop'
$Source=Join-Path $PSScriptRoot '..\atualizar-codigo-agente.ps1'
$Agent=Join-Path $PSScriptRoot '..\facilitador-agent.py'
$Temp=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('Temp\magbel-code-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Temp | Out-Null
$State=@{Calls=0;Block=$null;Args=$null}
function Get-AuthenticodeSignature {param($FilePath) [pscustomobject]@{Status='Valid'}}
# Reproduz Path qualificado pelo provider; ReadAllText deve usar ProviderPath.
function Resolve-Path {
    param($LiteralPath)
    $Native=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LiteralPath)
    [pscustomobject]@{Path=('Microsoft.PowerShell.Core\FileSystem::'+$Native);ProviderPath=$Native}
}
function Invoke-Command {
    param($ComputerName,$Authentication,$ConfigurationName,$ArgumentList,$ScriptBlock)
    if ($Authentication -ne 'Kerberos' -or $ConfigurationName -ne 'Microsoft.PowerShell') {throw 'IncorrectEndpoint'}
    $State.Calls++;$State.Block=$ScriptBlock;$State.Args=$ArgumentList
}
try {
    $Failed=$false
    try {& $Source -ComputerName $env:COMPUTERNAME -AgentSourcePath $Agent} catch {$Failed=$true}
    if (-not $Failed -or $State.Calls) {throw 'ConfirmationRequired'}
    $Wrong=Join-Path $Temp 'wrong.py'
    'VERSION="2.0.5"' | Set-Content $Wrong
    $Failed=$false
    try {& $Source -ComputerName $env:COMPUTERNAME -AgentSourcePath $Wrong -ConfirmarDrenadoSemTrabalhos} catch {$Failed=$true}
    if (-not $Failed -or $State.Calls) {throw 'UnreviewedCodeAccepted'}
    & $Source -ComputerName $env:COMPUTERNAME -AgentSourcePath $Agent -ConfirmarDrenadoSemTrabalhos
    if ($State.Calls -ne 1 -or $State.Args.Count -ne 3 -or $State.Args[1] -isnot [byte[]]) {throw 'UnexpectedTransport'}
    $env:MAGBEL_CODE_TEST_BLOCK=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($State.Block.ToString()))
    $env:MAGBEL_CODE_TEST_BYTES=[Convert]::ToBase64String($State.Args[1])
    $env:MAGBEL_CODE_TEST_HASH=$State.Args[2]
    $env:MAGBEL_CODE_TEST_ROOT=$Temp
    $Fixture=@'
$ErrorActionPreference='Stop'
$env:ProgramData=Join-Path $env:MAGBEL_CODE_TEST_ROOT 'ProgramData'
$State=@{Status='Running';Starts=0}
function Get-ScheduledTask {param($TaskName) [pscustomobject]@{State=$State.Status}}
function Get-CimInstance {param($ClassName,$Filter) return @()}
function Export-ScheduledTask {param($TaskName) return '<Task>fixture</Task>'}
function Start-ScheduledTask {param($TaskName) $State.Starts++}
$Block=[scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:MAGBEL_CODE_TEST_BLOCK)))
$Bytes=[Convert]::FromBase64String($env:MAGBEL_CODE_TEST_BYTES)
$Hash=$env:MAGBEL_CODE_TEST_HASH
$Failed=$false
try {& $Block $env:COMPUTERNAME $Bytes $Hash} catch {
    if ($_.Exception.Message -notlike '*Ready*') {throw}
    $Failed=$true
}
if (-not $Failed -or (Test-Path $env:ProgramData)) {throw 'RunningTaskWasNotRefusedBeforeMutation'}
$State.Status='Ready'
$Root=Join-Path $env:ProgramData ('Magbel\FacilitadorAgent\'+$env:COMPUTERNAME.ToLowerInvariant())
[IO.Directory]::CreateDirectory($Root) | Out-Null
$Venv=Join-Path $Root 'venv'
& python -m venv $Venv
if ($LASTEXITCODE -ne 0) {throw 'FixtureVenvFailed'}
$Python=Join-Path $Venv 'Scripts\python.exe'
$Target=Join-Path $Root 'facilitador-agent.py'
$Config=Join-Path $Root 'config.json'
$Identity=Join-Path $Root 'identity.json'
$Old='VERSION="2.0.5"'+"`r`n"
[IO.File]::WriteAllText($Target,$Old)
@{AGENT_BASE_DIR=$Root;AGENT_PYTHON=$Python;UNCHANGED='fixture'} | ConvertTo-Json | Set-Content $Config -Encoding UTF8
'identity-fixture-preserve' | Set-Content $Identity -Encoding UTF8
$ConfigHash=(Get-FileHash $Config).Hash
$IdentityHash=(Get-FileHash $Identity).Hash
# A alteração de transporte é recusada antes de criar backup/trocar código.
$Bytes[0]=$Bytes[0] -bxor 1
$Failed=$false
try {& $Block $env:COMPUTERNAME $Bytes $Hash} catch {
    if ($_.Exception.Message -notlike '*Hash divergente*') {throw}
    $Failed=$true
}
$Bytes[0]=$Bytes[0] -bxor 1
if (-not $Failed -or [IO.File]::ReadAllText($Target) -ne $Old) {throw 'CorruptTransportAccepted'}
$Result=& $Block $env:COMPUTERNAME $Bytes $Hash
if ($Result.AgentVersion -ne '2.0.6' -or $State.Starts -ne 1) {throw 'UpdateDidNotStartTask'}
if ((Get-FileHash $Target).Hash.ToLowerInvariant() -ne $Hash) {throw 'NewCodeMismatch'}
if ([IO.File]::ReadAllText($Result.Backup) -ne $Old) {throw 'PreviousCodeNotPreserved'}
if ((Get-FileHash $Config).Hash -ne $ConfigHash -or (Get-FileHash $Identity).Hash -ne $IdentityHash) {throw 'ConfigOrIdentityChanged'}
$Failed=$false
try {& $Block $env:COMPUTERNAME $Bytes $Hash} catch {
    if ($_.Exception.Message -notlike '*já instalado*') {throw}
    $Failed=$true
}
if (-not $Failed -or $State.Starts -ne 1) {throw 'RepeatedUpdateAccepted'}
Write-Host 'PS5.1: troca real, backup, inscrição/config preservadas, hash e tarefa em execução: OK'
'@
    $Encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Fixture))
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -EncodedCommand $Encoded
    if ($LASTEXITCODE -ne 0) {throw 'NativeCodeUpdateTestFailed'}
} finally {
    foreach ($Name in @('MAGBEL_CODE_TEST_BLOCK','MAGBEL_CODE_TEST_BYTES','MAGBEL_CODE_TEST_HASH','MAGBEL_CODE_TEST_ROOT')) {Remove-Item "Env:\$Name" -ErrorAction SilentlyContinue}
    Remove-Item $Temp -Recurse -Force
}
