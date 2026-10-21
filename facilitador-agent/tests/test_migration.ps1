# Somente runner descartável: nenhuma conexão ou tarefa real.
#Requires -Version 7.0
$ErrorActionPreference='Stop'
$Source=Join-Path $PSScriptRoot '..\migrar-conta-agente.ps1'
$Root=Join-Path $env:TEMP ('magbel-migration-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Root | Out-Null
$Credential=[pscredential]::new('FIXTURE\service',(ConvertTo-SecureString 'fixture-only' -AsPlainText -Force))
$MigrationTestState=@{Calls=0;Block=$null}
function Invoke-Command {
 param($ComputerName,$Authentication,$ConfigurationName,$ArgumentList,$ScriptBlock)
 $MigrationTestState.Calls++
 if ($Authentication -ne 'Kerberos' -or $ConfigurationName -ne 'Microsoft.PowerShell') {throw 'IncorrectEndpoint'}
 if ($ArgumentList.Count -eq 3 -and $ArgumentList[1] -isnot [pscredential]) {throw 'CredentialNotInMemory'}
 $MigrationTestState.Block=$ScriptBlock
}
try {
 $Requirements=Join-Path $Root 'requirements.txt'
 'requests>=2.32.3,<3' | Set-Content $Requirements
 $Failed=$false
 try {& $Source -ComputerName $env:COMPUTERNAME -Credential $Credential -RequirementsPath $Requirements} catch {$Failed=$true}
 if (-not $Failed -or $MigrationTestState.Calls) {throw 'MissingDrainConfirmationAccepted'}
 'requests @ https://invalid.example/unsafe.whl' | Set-Content $Requirements
 $Failed=$false
 try {& $Source -ComputerName $env:COMPUTERNAME -Credential $Credential -RequirementsPath $Requirements -ConfirmarDrenadoSemTrabalhos} catch {$Failed=$true}
 if (-not $Failed -or $MigrationTestState.Calls) {throw 'UnexpectedManifestAccepted'}
 'requests>=2.32.3,<3' | Set-Content $Requirements
 & $Source -ComputerName $env:COMPUTERNAME -Credential $Credential -RequirementsPath $Requirements -ConfirmarDrenadoSemTrabalhos
 if ($MigrationTestState.Calls -ne 1) {throw 'MissingRemotePlan'}
 $Blocks=@($MigrationTestState.Block)
 $ResumeSource=Join-Path $PSScriptRoot '..\retomar-config-agente.ps1'
 $Failed=$false
 try {& $ResumeSource -ComputerName $env:COMPUTERNAME -Account 'FIXTURE\service'} catch {$Failed=$true}
 if (-not $Failed -or $MigrationTestState.Calls -ne 1) {throw 'ResumeWithoutConfirmationAccepted'}
 & $ResumeSource -ComputerName $env:COMPUTERNAME -Account 'FIXTURE\service' -ConfirmarDrenadoSemTrabalhos
 if ($MigrationTestState.Calls -ne 2) {throw 'MissingResumePlan'}
 $Blocks+=@($MigrationTestState.Block)
 foreach ($RemoteBlock in $Blocks) {
 $env:MAGBEL_MIGRATION_TEST_BLOCK=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($RemoteBlock.ToString()))
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
# Executa a expressão real de substituição em arquivos descartáveis sob PS5.1.
$Replace=$Block.Ast.Find({param($Node)
 $Node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
 $Node.Member.Extent.Text -eq 'Replace' -and
 $Node.Extent.Text.StartsWith('[IO.File]::Replace(')
},$true)
if (-not $Replace) {throw 'ConfigReplaceNotFound'}
$Backup=Join-Path $env:TEMP ('magbel-replace-test-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($Backup) | Out-Null
try {
 $ConfigTemp=Join-Path $Backup 'config-new.tmp'
 $ConfigPath=Join-Path $Backup 'config.json'
 [IO.File]::WriteAllText($ConfigTemp,'new-config')
 [IO.File]::WriteAllText($ConfigPath,'old-config')
 & ([scriptblock]::Create($Replace.Extent.Text))
 if ([IO.File]::ReadAllText($ConfigPath) -ne 'new-config') {throw 'ConfigNotReplaced'}
 if ([IO.File]::ReadAllText((Join-Path $Backup 'config-at-replace.json')) -ne 'old-config') {throw 'PreviousConfigNotPreserved'}
 if ([IO.File]::Exists($ConfigTemp)) {throw 'TemporaryConfigStillPresent'}
 Write-Host 'PS5.1: substituição real do config preservou backup anterior: OK'
} finally {[IO.Directory]::Delete($Backup,$true)}
Write-Host 'PS5.1: tarefa em execução recusada antes de alterar arquivos, direitos ou tarefa: OK'
'@
 $Encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Fixture))
 & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -EncodedCommand $Encoded
 if ($LASTEXITCODE -ne 0) {throw 'NativeMigrationGuardFailed'}
 }
 Write-Host 'Migração: confirmação, manifest, credencial em memória e bloqueio de tarefa em execução: OK'
} finally {
 Remove-Item Env:\MAGBEL_MIGRATION_TEST_BLOCK -ErrorAction SilentlyContinue
 Remove-Item $Root -Recurse -Force
 $Credential=$null
}
