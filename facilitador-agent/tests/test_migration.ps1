# Somente runner descartável: nenhuma conexão ou tarefa real.
#Requires -Version 7.0
$ErrorActionPreference='Stop'
$Source=Join-Path $PSScriptRoot '..\migrar-conta-agente.ps1'
$Root=Join-Path $env:TEMP ('magbel-migration-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Root | Out-Null
$Credential=[pscredential]::new('FIXTURE\service',(ConvertTo-SecureString 'fixture-only' -AsPlainText -Force))
$script:RemoteCalls=0
function Invoke-Command {
 param($ComputerName,$Authentication,$ConfigurationName,$ArgumentList,$ScriptBlock)
 $script:RemoteCalls++
 if ($Authentication -ne 'Kerberos' -or $ConfigurationName -ne 'Microsoft.PowerShell') {throw 'IncorrectEndpoint'}
 if ($ArgumentList[1] -isnot [pscredential]) {throw 'CredentialNotInMemory'}
 $script:RemoteBlock=$ScriptBlock
}
try {
 $Requirements=Join-Path $Root 'requirements.txt'
 'requests>=2.32.3,<3' | Set-Content $Requirements
 $Failed=$false
 try {& $Source -ComputerName $env:COMPUTERNAME -Credential $Credential -RequirementsPath $Requirements} catch {$Failed=$true}
 if (-not $Failed -or $script:RemoteCalls) {throw 'MissingDrainConfirmationAccepted'}
 'requests @ https://invalid.example/unsafe.whl' | Set-Content $Requirements
 $Failed=$false
 try {& $Source -ComputerName $env:COMPUTERNAME -Credential $Credential -RequirementsPath $Requirements -ConfirmarDrenadoSemTrabalhos} catch {$Failed=$true}
 if (-not $Failed -or $script:RemoteCalls) {throw 'UnexpectedManifestAccepted'}
 'requests>=2.32.3,<3' | Set-Content $Requirements
 & $Source -ComputerName $env:COMPUTERNAME -Credential $Credential -RequirementsPath $Requirements -ConfirmarDrenadoSemTrabalhos
 if ($script:RemoteCalls -ne 1) {throw 'MissingRemotePlan'}
 $env:MAGBEL_MIGRATION_TEST_BLOCK=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:RemoteBlock.ToString()))
 $Fixture=@'
$ErrorActionPreference='Stop'
function Get-ScheduledTask {param($TaskName) return @{State='Running'}}
function New-Item {throw 'UnexpectedMutation'}
function Start-ScheduledTask {throw 'UnexpectedMutation'}
function Set-ScheduledTask {throw 'UnexpectedMutation'}
$Block=[scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:MAGBEL_MIGRATION_TEST_BLOCK)))
$Credential=New-Object Management.Automation.PSCredential('FIXTURE\service',(ConvertTo-SecureString 'fixture-only' -AsPlainText -Force))
$Refused=$false
try {& $Block $env:COMPUTERNAME $Credential 'requests>=2.32.3,<3'} catch {
 if ($_.Exception.Message -notlike '*Ready*') {throw}
 $Refused=$true
}
if (-not $Refused) {throw 'RunningTaskAccepted'}
Write-Host 'PS5.1: tarefa em execução recusada antes de alterar arquivos, direitos ou tarefa: OK'
'@
 $Encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Fixture))
 & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -EncodedCommand $Encoded
 if ($LASTEXITCODE -ne 0) {throw 'NativeMigrationGuardFailed'}
 Write-Host 'Migração: confirmação, manifest, credencial em memória e bloqueio de tarefa em execução: OK'
} finally {
 Remove-Item Env:\MAGBEL_MIGRATION_TEST_BLOCK -ErrorAction SilentlyContinue
 Remove-Item $Root -Recurse -Force
 $Credential=$null
}
