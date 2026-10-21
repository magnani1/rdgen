#Requires -Version 7.0
[CmdletBinding()]
param(
 [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z][a-zA-Z0-9.-]{0,252}$')][string]$ComputerName,
 [Parameter(Mandatory)][string]$Account,
 [switch]$ConfirmarDrenadoSemTrabalhos
)
$ErrorActionPreference='Stop'
if (-not $ConfirmarDrenadoSemTrabalhos) {throw 'Confirme agente drenado e sem trabalhos antes de retomar.'}
$Id=$ComputerName.Split('.')[0]
Invoke-Command -ComputerName $ComputerName -Authentication Kerberos -ConfigurationName Microsoft.PowerShell -ArgumentList $Id,$Account -ScriptBlock {
 param($HostId,$Account)
 $ErrorActionPreference='Stop'
 if ($env:COMPUTERNAME -ine $HostId) {throw 'Identidade do destino divergente.'}
 $Id=$HostId.ToLowerInvariant()
 $Root=Join-Path $env:ProgramData "Magbel\FacilitadorAgent\$Id"
 $TaskName="Magbel-Facilitador-$Id"
 $Task=Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
 if ([string]$Task.State -ne 'Ready') {throw 'Tarefa deve estar Ready. Não será parada automaticamente.'}
 $Candidates=@(Get-ChildItem -LiteralPath $Root -Filter 'config-migration-*.tmp' -File)
 if ($Candidates.Count -ne 1) {throw 'É necessário exatamente um config temporário; conferir antes de retomar.'}
 $Candidate=$Candidates[0]
 $Stamp=$Candidate.Name -replace '^config-migration-','' -replace '\.tmp$',''
 if ($Stamp -notmatch '^\d{8}T\d{6}-[a-f0-9]{8}$') {throw 'Nome do temporário não corresponde à migração.'}
 $ConfigTemp=$Candidate.FullName
 $ConfigPath=Join-Path $Root 'config.json'
 $Backup=Join-Path $env:ProgramData "Magbel\AgentMigrationBackups\$Id\$Stamp"
 $Before=Join-Path $Backup 'config-before.json'
 if (-not (Test-Path -LiteralPath $Before)) {throw 'Backup original não encontrado.'}
 if ((Get-FileHash $ConfigPath).Hash -ne (Get-FileHash $Before).Hash) {throw 'Configuração atual mudou desde o backup; não substituir.'}
 if (Test-Path (Join-Path $Backup 'config-at-replace.json')) {throw 'Backup da substituição já existe; conferir o estado antes de repetir.'}
 $Current=Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
 $New=Get-Content $ConfigTemp -Raw -Encoding UTF8 | ConvertFrom-Json
 $Sid=([Security.Principal.NTAccount]::new($Account)).Translate([Security.Principal.SecurityIdentifier]).Value
 [xml]$TaskXml=Export-ScheduledTask -TaskName $TaskName
 $TaskUser=[string]$TaskXml.Task.Principals.Principal.UserId
 $TaskSid=if ($TaskUser -match '^S-\d-') {$TaskUser} else {([Security.Principal.NTAccount]::new($TaskUser)).Translate([Security.Principal.SecurityIdentifier]).Value}
 if ($TaskSid -ne $Sid -or $New.AGENT_RUN_AS_SID -ne $Sid -or [string]$Task.Principal.LogonType -ne 'Password') {throw 'A tarefa e o temporário não correspondem à conta de serviço esperada.'}
 $ExpectedPython=Join-Path $Root "venv-py315-$Stamp\Scripts\python.exe"
 if ($New.AGENT_PYTHON -ine $ExpectedPython -or -not (Test-Path -LiteralPath $ExpectedPython -PathType Leaf)) {throw 'Ambiente Python da migração não corresponde ao temporário.'}
 foreach ($Property in $Current.PSObject.Properties) {
  if ($Property.Name -in @('AGENT_PYTHON','AGENT_RUN_AS_SID')) {continue}
  $Other=$New.PSObject.Properties[$Property.Name]
  if (-not $Other -or (($Property.Value | ConvertTo-Json -Compress -Depth 20) -cne ($Other.Value | ConvertTo-Json -Compress -Depth 20))) {throw 'O temporário alterou outra configuração; não substituir.'}
 }
 foreach ($Property in $New.PSObject.Properties) {
  if ($Property.Name -notin @('AGENT_PYTHON','AGENT_RUN_AS_SID') -and -not $Current.PSObject.Properties[$Property.Name]) {throw 'O temporário contém configuração adicional inesperada.'}
 }
 $Version=& $ExpectedPython -c 'import platform,requests,certifi; print(platform.python_version())'
 if ($LASTEXITCODE -ne 0 -or $Version.Trim() -ne '3.15.1') {throw 'Ambiente não passou na verificação Python/dependências.'}
 $Identity=Join-Path $Root 'identity.json'
 $IdentityHash=(Get-FileHash $Identity).Hash
 if ([string](Get-ScheduledTask -TaskName $TaskName).State -ne 'Ready') {throw 'Tarefa mudou de estado durante a conferência.'}
 [IO.File]::Replace($ConfigTemp,$ConfigPath,(Join-Path $Backup 'config-at-replace.json'))
 if ((Get-FileHash $Identity).Hash -ne $IdentityHash) {throw 'Inscrição mudou; tarefa não iniciada.'}
 Start-ScheduledTask -TaskName $TaskName
 [pscustomobject]@{
  Computer=$env:COMPUTERNAME; Account=$Account; Python=$ExpectedPython
  Version=$Version.Trim(); IdentityPreserved=$true; Backup=$Backup
  Activation='Validar contato, prontidão e WinRM antes de ativar no painel.'
 }
}
