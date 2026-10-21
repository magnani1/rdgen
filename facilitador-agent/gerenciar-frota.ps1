#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Inspect','Install')][string]$Mode = 'Inspect',
    [Parameter(Mandatory)][string]$ComputerName,
    [Parameter(Mandatory)][string]$AgentId,
    [Parameter(Mandatory)][string]$HomeUrl,
    [Parameter(Mandatory)][string]$ScriptsRoot,
    [Parameter(Mandatory)][string]$ClientId,
    [ValidateRange(1,16)][int]$Slots = 2,
    [string]$PythonExe = 'python'
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
# Preenchido antes da assinatura, vinculando runtime e dependências ao publicador.
$PackageHashesBase64='__MAGBEL_PACKAGE_HASHES__'
$Session=$null; $Stage=$null; $Secrets=$null; $Credential=$null
$Phase='package'
try {
    if ($ComputerName -notmatch '^[a-zA-Z][a-zA-Z0-9.-]{0,252}$' -or $AgentId -notmatch '^[a-zA-Z0-9-]{1,63}$' -or $ComputerName.Split('.')[0] -ine $AgentId) { throw 'InvalidTarget' }
    $Signer=(Get-AuthenticodeSignature -LiteralPath $PSCommandPath)
    if ($Signer.Status -ne 'Valid' -or -not $Signer.SignerCertificate -or $PackageHashesBase64 -eq '__MAGBEL_PACKAGE_HASHES__') { throw 'UnpreparedPackage' }
    $Thumbprint=$Signer.SignerCertificate.Thumbprint
    $Hashes=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($PackageHashesBase64)) | ConvertFrom-Json -AsHashtable
    foreach ($Entry in $Hashes.GetEnumerator()) {
        if ([IO.Path]::GetFileName($Entry.Key) -ne $Entry.Key) { throw 'InvalidManifest' }
        if ((Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $Entry.Key) -Algorithm SHA256).Hash -ne $Entry.Value) { throw 'PackageHashMismatch' }
    }
    foreach ($Name in @('instalar-agente.ps1','run-agent.ps1')) {
        $Signature=Get-AuthenticodeSignature -LiteralPath (Join-Path $PSScriptRoot $Name)
        if ($Signature.Status -ne 'Valid' -or $Signature.SignerCertificate.Thumbprint -ne $Thumbprint) { throw 'InvalidPackageSignature' }
    }
    $Phase='PowerShell.7-Kerberos'
    $Session=New-PSSession -ComputerName $ComputerName -Authentication Kerberos -ConfigurationName PowerShell.7 -SessionOption (New-PSSessionOption -OpenTimeout 20000 -OperationTimeout 900000)
    $Phase='prerequisites'
    $Report=Invoke-Command -Session $Session -ArgumentList $AgentId,$PythonExe -ScriptBlock {
        param($Id,$Python)
        $ErrorActionPreference='Stop'
        if ($env:COMPUTERNAME -ine $Id) { throw 'HostIdentityMismatch' }
        $Admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $Admin) { throw 'AdministratorRequired' }
        $Info=(& $Python -c 'import json,sys,struct; print(json.dumps(dict(major=sys.version_info.major,minor=sys.version_info.minor,bits=struct.calcsize("P")*8,executable=sys.executable)))') | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $Info.major -ne 3 -or $Info.minor -lt 12 -or $Info.bits -ne 64) { throw 'Python312PlusX64Required' }
        $Root=Join-Path $env:ProgramData "Magbel\FacilitadorAgent\$Id"
        @{ok=$true;python="$($Info.major).$($Info.minor) x64";python_exe=$Info.executable;existing_task=[bool](Get-ScheduledTask -TaskName "Magbel-Facilitador-$Id" -ErrorAction SilentlyContinue);existing_runtime=(Test-Path -LiteralPath $Root)}
    }
    if ($Mode -eq 'Install') {
        if ($Report.existing_task -or $Report.existing_runtime) { throw 'ExistingInstallationPreserved' }
        $Phase='credential-pipe'
        $Secrets=[Console]::In.ReadToEnd() | ConvertFrom-Json
        if (-not $Secrets.code -or -not $Secrets.user -or -not $Secrets.password) { throw 'MissingCredentials' }
        $Credential=[pscredential]::new($Secrets.user,(ConvertTo-SecureString $Secrets.password -AsPlainText -Force))
        $Code=ConvertTo-SecureString $Secrets.code -AsPlainText -Force
        $Secrets.password=$null; $Secrets.code=$null
        $Phase='stage'
        $Stage=Invoke-Command -Session $Session -ScriptBlock {
            $ErrorActionPreference='Stop'
            $Path=Join-Path $env:ProgramData ('Magbel\FleetStage\'+[guid]::NewGuid().ToString('N'))
            $null=New-Item -ItemType Directory -Path $Path -Force
            $Sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $null=& icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' "*${Sid}:(OI)(CI)F"
            if ($LASTEXITCODE -ne 0) { throw 'StageAclFailed' }
            $Path
        }
        foreach ($Name in @('instalar-agente.ps1','run-agent.ps1','facilitador-agent.py','requirements.txt')) {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot $Name) -Destination $Stage -ToSession $Session
        }
        $Phase='remote-signatures-install'
        $null=Invoke-Command -Session $Session -ArgumentList $Stage,$Hashes,$Thumbprint,$AgentId,$HomeUrl,$ScriptsRoot,$ClientId,$Slots,$Report.python_exe,$Credential,$Code -ScriptBlock {
            param($Package,$Expected,$Signer,$Id,$Url,$Scripts,$Client,$Capacity,$Python,$TaskCredential,$EnrollmentCode)
            $ErrorActionPreference='Stop'
            # Reconfere depois da transferência, antes de executar qualquer arquivo do pacote.
            foreach ($Name in @('instalar-agente.ps1','run-agent.ps1','facilitador-agent.py','requirements.txt')) {
                if ((Get-FileHash -LiteralPath (Join-Path $Package $Name) -Algorithm SHA256).Hash -ne $Expected[$Name]) { throw 'RemoteHashMismatch' }
            }
            foreach ($Name in @('instalar-agente.ps1','run-agent.ps1')) {
                $Signature=Get-AuthenticodeSignature -LiteralPath (Join-Path $Package $Name)
                if ($Signature.Status -ne 'Valid' -or $Signature.SignerCertificate.Thumbprint -ne $Signer) { throw 'RemoteSignatureUntrusted' }
            }
            $Root=Join-Path $env:ProgramData "Magbel\FacilitadorAgent\$Id"
            if ((Test-Path -LiteralPath $Root) -or (Get-ScheduledTask -TaskName "Magbel-Facilitador-$Id" -ErrorAction SilentlyContinue)) { throw 'InstallationAppearedDuringPreflight' }
            & (Join-Path $Package 'instalar-agente.ps1') -PackageRoot $Package -SignedLauncherPath (Join-Path $Package 'run-agent.ps1') -HomeUrl $Url -ScriptsRoot $Scripts -ClientId $Client -AgentId $Id -Slots $Capacity -PythonExe $Python -RunAsCredential $TaskCredential -EnrollmentCode $EnrollmentCode *>&1 | Out-Null
            $Task=Get-ScheduledTask -TaskName "Magbel-Facilitador-$Id"
            if ([string]$Task.Principal.LogonType -ne 'Password') { throw 'TaskNetworkLogonRequired' }
        }
        $Report=@{ok=$true;installed=$true;agent_id=$AgentId}
    }
    [Console]::WriteLine('MAGBEL_FLEET:'+($Report | ConvertTo-Json -Compress))
} catch {
    # Não retornar objetos de invocação: eles podem conter argumentos sensíveis.
    $Known=@('InvalidTarget','UnpreparedPackage','InvalidManifest','PackageHashMismatch','InvalidPackageSignature','HostIdentityMismatch','AdministratorRequired','Python312PlusX64Required','ExistingInstallationPreserved','MissingCredentials','StageAclFailed','RemoteHashMismatch','RemoteSignatureUntrusted','InstallationAppearedDuringPreflight','TaskNetworkLogonRequired')
    $Id=if ($_.Exception.Message -in $Known) { $_.Exception.Message } else { $_.Exception.GetType().Name }
    [Console]::WriteLine('MAGBEL_FLEET:'+(@{ok=$false;phase=$Phase;error_id=$Id} | ConvertTo-Json -Compress))
    exit 1
} finally {
    $Credential=$null; $Code=$null; $Secrets=$null
    if ($Session) {
        if ($Stage) { try { Invoke-Command -Session $Session -ArgumentList $Stage -ScriptBlock { param($Path) Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue } | Out-Null } catch {} }
        Remove-PSSession $Session
    }
}
