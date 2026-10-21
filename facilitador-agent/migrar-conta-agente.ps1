#Requires -Version 7.0
[CmdletBinding()]
param(
 [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z][a-zA-Z0-9.-]{0,252}$')][string]$ComputerName,
 [Parameter(Mandatory)][pscredential]$Credential,
 [Parameter(Mandatory)][string]$RequirementsPath,
 [switch]$ConfirmarDrenadoSemTrabalhos
)
$ErrorActionPreference='Stop'
if (-not $ConfirmarDrenadoSemTrabalhos) { throw 'Drene, aguarde zerar trabalhos e encerre o agente no painel antes de migrar.' }
if ($Credential.UserName -notmatch '^[^\\]+\\[^\\]+$') { throw 'Informe DOMINIO\usuario.' }
$Requirements=@(Get-Content -LiteralPath $RequirementsPath -Encoding UTF8 | ForEach-Object {$_.Trim()} | Where-Object {$_ -and -not $_.StartsWith('#')})
if ($Requirements.Count -ne 1 -or $Requirements[0] -ne 'requests>=2.32.3,<3') { throw 'Manifest diferente do agente 2.0.2: revisar o migrador antes de continuar.' }
$ShortName=$ComputerName.Split('.')[0]
Invoke-Command -ComputerName $ComputerName -Authentication Kerberos -ConfigurationName Microsoft.PowerShell -ArgumentList $ShortName,$Credential,$Requirements[0] -ScriptBlock {
 param($HostId,[pscredential]$RunAs,$Requirement)
 $ErrorActionPreference='Stop'
 if ($env:COMPUTERNAME -ine $HostId) { throw 'Identidade do destino divergente.' }
 $Id=$HostId.ToLowerInvariant()
 $Root=Join-Path $env:ProgramData "Magbel\FacilitadorAgent\$Id"
 $TaskName="Magbel-Facilitador-$Id"
 $Task=Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
 if ([string]$Task.State -ne 'Ready') { throw 'A tarefa deve estar Ready: drene e encerre pelo painel. Este script não para processos.' }
 $ConfigPath=Join-Path $Root 'config.json'
 $Identity=Join-Path $Root 'identity.json'
 if (-not (Test-Path $Identity)) { throw 'Inscrição existente ausente: não será criada outra.' }
 $IdentityHash=(Get-FileHash $Identity -Algorithm SHA256).Hash
 $Config=Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
 if (-not $Config.AGENT_PYTHON -or -not $Config.HOME_URL -or $Config.AGENT_BASE_DIR -ine $Root) { throw 'Configuração não corresponde ao runtime esperado.' }
 $Sid=([Security.Principal.NTAccount]::new($RunAs.UserName)).Translate([Security.Principal.SecurityIdentifier]).Value
 $MachinePython='C:\Program Files\Python315\python.exe'
 $Info=& $MachinePython -c 'import json,sys,platform; print(json.dumps(dict(version=platform.python_version(),bits=sys.maxsize.bit_length()+1)))'
 if ($LASTEXITCODE -ne 0) { throw 'Python315 indisponível.' }
 $Info=$Info | ConvertFrom-Json
 if ($Info.version -ne '3.15.1' -or $Info.bits -ne 64) { throw 'É necessário Python 3.15.1 x64 previamente validado.' }
 if ($Config.AGENT_RUN_AS_SID -eq $Sid -and $Config.AGENT_PYTHON -like "$Root\venv-py315-*\Scripts\python.exe") { throw 'Migração já aplicada. Confira contato e prontidão no painel.' }
 $Stamp=(Get-Date -Format yyyyMMddTHHmmss)+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
 $Backup=Join-Path $env:ProgramData "Magbel\AgentMigrationBackups\$Id\$Stamp"
 New-Item -ItemType Directory -Path $Backup -Force | Out-Null
 $null=& icacls.exe $Backup /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F'
 if ($LASTEXITCODE -ne 0) { throw 'Falha ao proteger o backup.' }
 Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $Backup 'config-before.json')
 Export-ScheduledTask -TaskName $TaskName | Set-Content (Join-Path $Backup 'task-before.xml') -Encoding Unicode
 $null=& icacls.exe $Root /save (Join-Path $Backup 'acl-before.txt') /T /C
 if ($LASTEXITCODE -ne 0) { throw "Falha ao salvar permissões. Backup: $Backup" }
 $Policy=Join-Path $Backup 'rights-before.inf'
 $null=& secedit.exe /export /cfg $Policy /areas USER_RIGHTS /quiet
 if ($LASTEXITCODE -ne 0) { throw "Falha ao exportar direitos. Backup: $Backup" }
 $Lines=Get-Content -LiteralPath $Policy
 $Deny=$Lines | Where-Object {$_ -match '^\s*SeDenyBatchLogonRight\s*='} | Select-Object -First 1
 if ($Deny) {
  $Denied=@(($Deny -split '=',2)[1] -split ',' | ForEach-Object {$_.Trim().TrimStart('*')})
  if ($Denied -contains $Sid) { throw "Conta impedida de logon de lote. Corrija a política. Backup: $Backup" }
 }
 # Outro ambiente: o venv anterior continua no lugar para recuperação.
 $Venv=Join-Path $Root "venv-py315-$Stamp"
 & $MachinePython -m venv $Venv
 if ($LASTEXITCODE -ne 0) { throw "Falha ao criar ambiente. Backup: $Backup" }
 $NewPython=Join-Path $Venv 'Scripts\python.exe'
 & $NewPython -m pip install --disable-pip-version-check $Requirement
 if ($LASTEXITCODE -ne 0) { throw "Falha nas dependências; tarefa/configuração preservadas. Backup: $Backup" }
 & $NewPython -m pip check
 if ($LASTEXITCODE -ne 0) { throw "Dependências inconsistentes. Backup: $Backup" }
 & $NewPython -c 'import requests,certifi,sys; print(sys.version); print(requests.__version__)'
 if ($LASTEXITCODE -ne 0) { throw "Importação falhou. Backup: $Backup" }
 if ([string](Get-ScheduledTask -TaskName $TaskName).State -ne 'Ready') { throw "Tarefa mudou de estado. Backup: $Backup" }
 if ((Get-FileHash $Identity).Hash -ne $IdentityHash) { throw "Inscrição mudou durante o preparo. Backup: $Backup" }
 if ((Get-FileHash $ConfigPath).Hash -ne (Get-FileHash (Join-Path $Backup 'config-before.json')).Hash) { throw "Configuração mudou durante o preparo. Backup: $Backup" }
 $Allow=$Lines | Where-Object {$_ -match '^\s*SeBatchLogonRight\s*='} | Select-Object -First 1
 $Members=@()
 if ($Allow) {$Members=@(($Allow -split '=',2)[1] -split ',' | ForEach-Object {$_.Trim()} | Where-Object {$_})}
 if ($Members -notcontains "*$Sid") {
  $Members+="*$Sid"
  $Inf=Join-Path $Backup 'batch-logon.inf'
  @('[Unicode]','Unicode=yes','[Version]','signature="$CHICAGO$"','Revision=1','[Privilege Rights]',('SeBatchLogonRight = '+($Members -join ','))) | Set-Content $Inf -Encoding Unicode
  $null=& secedit.exe /configure /db (Join-Path $Backup 'batch-logon.sdb') /cfg $Inf /areas USER_RIGHTS /quiet
  if ($LASTEXITCODE -ne 0) { throw "Falha no logon de lote. Backup: $Backup" }
 }
 $null=& icacls.exe $Root /grant:r "*${Sid}:(OI)(CI)RX"
 if ($LASTEXITCODE -ne 0) { throw "Falha na leitura do runtime. Backup: $Backup" }
 foreach ($Name in @('Logs','Uploads')) {
  $Directory=Join-Path $Root $Name
  New-Item -ItemType Directory -Path $Directory -Force | Out-Null
  $null=& icacls.exe $Directory /grant:r "*${Sid}:(OI)(CI)M"
  if ($LASTEXITCODE -ne 0) { throw "Falha na permissão de trabalho. Backup: $Backup" }
 }
 $Log=Join-Path $Root 'agent.log'
 if (-not (Test-Path $Log)) {New-Item -ItemType File -Path $Log | Out-Null}
 $null=& icacls.exe $Log /grant:r "*${Sid}:M"
 if ($LASTEXITCODE -ne 0) {throw "Falha na permissão do log. Backup: $Backup"}
 # Senha somente em memória; não vai para argv, arquivo ou saída.
 $Password=$RunAs.GetNetworkCredential().Password
 try {Set-ScheduledTask -TaskName $TaskName -User $RunAs.UserName -Password $Password | Out-Null}
 finally {$Password=$null; $RunAs=$null}
 $Registered=Get-ScheduledTask -TaskName $TaskName
 if ([string]$Registered.Principal.LogonType -ne 'Password') {throw "Logon de rede não registrado. Mantenha drenado. Backup: $Backup"}
 $Config.AGENT_PYTHON=$NewPython
 if ($Config.PSObject.Properties.Name -contains 'AGENT_RUN_AS_SID') {$Config.AGENT_RUN_AS_SID=$Sid}
 else {$Config | Add-Member -NotePropertyName AGENT_RUN_AS_SID -NotePropertyValue $Sid}
 $ConfigTemp=Join-Path $Root "config-migration-$Stamp.tmp"
 [IO.File]::WriteAllText($ConfigTemp,($Config | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
 [IO.File]::Replace($ConfigTemp,$ConfigPath,(Join-Path $Backup 'config-at-replace.json'))
 if ((Get-FileHash $Identity).Hash -ne $IdentityHash) {throw "Inscrição divergente: não iniciar. Backup: $Backup"}
 Start-ScheduledTask -TaskName $TaskName
 [pscustomobject]@{
  Computer=$env:COMPUTERNAME; Account=$Registered.Principal.UserId
  LogonType=[string]$Registered.Principal.LogonType; Python=$NewPython
  PreviousPython=(Get-Content (Join-Path $Backup 'config-before.json') -Raw | ConvertFrom-Json).AGENT_PYTHON
  Backup=$Backup; IdentityPreserved=$true
  Activation='Validar contato, prontidão e WinRM antes de ativar no painel.'
 }
}
