#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Inspect','Install','LocalInstall')][string]$Mode = 'Inspect',
    [string]$ComputerName,
    [string]$AgentId,
    [string]$HomeUrl,
    [string]$ScriptsRoot,
    [string]$ClientId,
    [ValidateRange(1,16)][int]$Slots = 2,
    [string]$PythonExe = 'python'
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
# Preenchido antes da assinatura, vinculando runtime e dependências ao publicador.
$PackageHashesBase64='__MAGBEL_PACKAGE_HASHES__'

# Corpo compatível com Windows PowerShell 5.1, enviado pelo WinRM padrão.
# Somente o processo local usa PowerShell 7; nenhum endpoint novo é registrado.
function Invoke-FleetLocalProcess {
    param($Package,$Hashes,$Thumbprint,$PwshExe,$Payload64)
    $ErrorActionPreference='Stop'
    foreach ($Entry in $Hashes.GetEnumerator()) {
        if ([IO.Path]::GetFileName($Entry.Key) -ne $Entry.Key -or (Get-FileHash -LiteralPath (Join-Path $Package $Entry.Key) -Algorithm SHA256).Hash -ne $Entry.Value) { throw 'RemoteHashMismatch' }
    }
    foreach ($Name in @('instalar-agente.ps1','run-agent.ps1','gerenciar-frota.ps1')) {
        $Signature=Get-AuthenticodeSignature -LiteralPath (Join-Path $Package $Name)
        if ($Signature.Status -ne 'Valid' -or $Signature.SignerCertificate.Thumbprint -ne $Thumbprint) { throw 'RemoteSignatureUntrusted' }
    }
    $Process=New-Object Diagnostics.Process
    $Info=New-Object Diagnostics.ProcessStartInfo
    $Info.FileName=$PwshExe
    $Info.Arguments='-NoProfile -NonInteractive -File "'+(Join-Path $Package 'gerenciar-frota.ps1')+'" -Mode LocalInstall'
    $Info.UseShellExecute=$false; $Info.CreateNoWindow=$true
    # Cada versão reconstrói seus caminhos padrão; não herdar módulos incompatíveis do host 5.1.
    $Info.EnvironmentVariables.Remove('PSModulePath')
    $Info.RedirectStandardInput=$true; $Info.RedirectStandardOutput=$true; $Info.RedirectStandardError=$true
    $Info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
    $Info.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
    $Process.StartInfo=$Info
    try {
        if (-not $Process.Start()) { throw 'LocalInstallerFailed' }
        $Output=$Process.StandardOutput.ReadToEndAsync()
        $Errors=$Process.StandardError.ReadToEndAsync()
        # Base64 evita dependência da página de código do host 5.1; não é criptografia.
        # O conteúdo sensível permanece apenas no pipe/memória da sessão autenticada.
        $InputBytes=[Text.Encoding]::ASCII.GetBytes($Payload64)
        $Pipe=$Process.StandardInput.BaseStream
        $Pipe.Write($InputBytes,0,$InputBytes.Length); $Pipe.Flush(); $Pipe.Close()
        $InputBytes=$null
        if (-not $Process.WaitForExit(840000)) { return @{ok=$false;pending=$true;error_id='InstallerTimeoutCheckHost'} }
        $Text=$Output.GetAwaiter().GetResult()
        $null=$Errors.GetAwaiter().GetResult() # Nunca retornar stderr que possa incluir argumentos.
        $Reports=@($Text -split '\r?\n' | Where-Object { $_.StartsWith('MAGBEL_FLEET:') })
        if ($Process.ExitCode -ne 0) { throw ('LocalInstallerExit'+$Process.ExitCode) }
        if (-not $Reports.Count) { throw 'LocalInstallerNoReport' }
        $Report=$Reports[-1].Substring(13) | ConvertFrom-Json
        if (-not $Report.ok) { throw 'LocalInstallerFailed' }
        return @{ok=$true;pending=$false}
    } finally { $Process.Dispose() }
}

$Session=$null; $Stage=$null; $KeepStage=$false; $Secrets=$null; $Credential=$null
$Phase='package'
try {
    $Signer=Get-AuthenticodeSignature -LiteralPath $PSCommandPath
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
    if ($Mode -eq 'LocalInstall') {
        $Phase='local-install'
        $InputReader=[IO.StreamReader]::new([Console]::OpenStandardInput(),[Text.UTF8Encoding]::new($false),$true)
        try { $InputText=$InputReader.ReadToEnd() } finally { $InputReader.Dispose() }
        $Secrets=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($InputText)) | ConvertFrom-Json
        $InputText=$null
        if (-not $Secrets.code -or -not $Secrets.user -or -not $Secrets.password -or $Secrets.agent_id -notmatch '^[a-zA-Z0-9-]{1,63}$' -or $env:COMPUTERNAME -ine $Secrets.agent_id) { throw 'InvalidLocalPlan' }
        $AgentId=$Secrets.agent_id
        $Root=Join-Path $env:ProgramData "Magbel\FacilitadorAgent\$AgentId"
        if ((Test-Path -LiteralPath $Root) -or (Get-ScheduledTask -TaskName "Magbel-Facilitador-$AgentId" -ErrorAction SilentlyContinue)) { throw 'ExistingInstallationPreserved' }
        $Credential=[pscredential]::new($Secrets.user,(ConvertTo-SecureString $Secrets.password -AsPlainText -Force))
        $Code=ConvertTo-SecureString $Secrets.code -AsPlainText -Force
        $Secrets.password=$null; $Secrets.code=$null
        & (Join-Path $PSScriptRoot 'instalar-agente.ps1') -PackageRoot $PSScriptRoot -SignedLauncherPath (Join-Path $PSScriptRoot 'run-agent.ps1') -HomeUrl $Secrets.home_url -ScriptsRoot $Secrets.scripts_root -ClientId $Secrets.client_id -AgentId $AgentId -Slots $Secrets.slots -PythonExe $Secrets.python_exe -RunAsCredential $Credential -EnrollmentCode $Code *>&1 | Out-Null
        $Task=Get-ScheduledTask -TaskName "Magbel-Facilitador-$AgentId"
        if ([string]$Task.Principal.LogonType -ne 'Password') { throw 'TaskNetworkLogonRequired' }
        $Report=@{ok=$true;installed=$true;agent_id=$AgentId}
    } else {
        if ($ComputerName -notmatch '^[a-zA-Z][a-zA-Z0-9.-]{0,252}$' -or $AgentId -notmatch '^[a-zA-Z0-9-]{1,63}$' -or $ComputerName.Split('.')[0] -ine $AgentId) { throw 'InvalidTarget' }
        $Phase='Microsoft.PowerShell-Kerberos'
        $Session=New-PSSession -ComputerName $ComputerName -Authentication Kerberos -ConfigurationName Microsoft.PowerShell -SessionOption (New-PSSessionOption -OpenTimeout 20000 -OperationTimeout 900000)
        $Phase='prerequisites'
        $Report=Invoke-Command -Session $Session -ArgumentList $AgentId,$PythonExe -ScriptBlock {
            param($Id,$Python)
            $ErrorActionPreference='Stop'
            if ($env:COMPUTERNAME -ine $Id) { throw 'HostIdentityMismatch' }
            $Admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $Admin) { throw 'AdministratorRequired' }
            $Pwsh=Get-Command pwsh -ErrorAction SilentlyContinue
            $PwshPath=if ($Pwsh) { $Pwsh.Source } else { Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe' }
            if (-not (Test-Path -LiteralPath $PwshPath -PathType Leaf)) { throw 'LocalPowerShell7Required' }
            $Info=(& $Python -c 'import json,sys,struct; print(json.dumps(dict(major=sys.version_info.major,minor=sys.version_info.minor,bits=struct.calcsize("P")*8,executable=sys.executable)))') | ConvertFrom-Json
            if ($LASTEXITCODE -ne 0 -or $Info.major -ne 3 -or $Info.minor -lt 12 -or $Info.bits -ne 64) { throw 'Python312PlusX64Required' }
            $Root=Join-Path $env:ProgramData "Magbel\FacilitadorAgent\$Id"
            @{ok=$true;python="$($Info.major).$($Info.minor) x64";python_exe=$Info.executable;pwsh_exe=$PwshPath;existing_task=[bool](Get-ScheduledTask -TaskName "Magbel-Facilitador-$Id" -ErrorAction SilentlyContinue);existing_runtime=(Test-Path -LiteralPath $Root)}
        }
        if ($Mode -eq 'Install') {
            if ($Report.existing_task -or $Report.existing_runtime) { throw 'ExistingInstallationPreserved' }
            $Phase='credential-pipe'
            $Secrets=[Console]::In.ReadToEnd() | ConvertFrom-Json -AsHashtable
            if (-not $Secrets.code -or -not $Secrets.user -or -not $Secrets.password) { throw 'MissingCredentials' }
            $Secrets.agent_id=$AgentId; $Secrets.home_url=$HomeUrl; $Secrets.scripts_root=$ScriptsRoot
            $Secrets.client_id=$ClientId; $Secrets.slots=$Slots; $Secrets.python_exe=$Report.python_exe
            $Payload64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Secrets | ConvertTo-Json -Compress)))
            $Secrets.Clear(); $Secrets=$null
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
            foreach ($Name in (@($Hashes.Keys)+@('gerenciar-frota.ps1'))) {
                Copy-Item -LiteralPath (Join-Path $PSScriptRoot $Name) -Destination $Stage -ToSession $Session
            }
            $Phase='remote-signatures-local-process'
            $Outcome=Invoke-Command -Session $Session -ScriptBlock ${function:Invoke-FleetLocalProcess} -ArgumentList $Stage,$Hashes,$Thumbprint,$Report.pwsh_exe,$Payload64
            $Payload64=$null
            if ($Outcome.pending) { $KeepStage=$true; throw 'InstallerTimeoutCheckHost' }
            if (-not $Outcome.ok) { throw 'LocalInstallerFailed' }
            $Report=@{ok=$true;installed=$true;agent_id=$AgentId}
        }
    }
    [Console]::WriteLine('MAGBEL_FLEET:'+($Report | ConvertTo-Json -Compress))
} catch {
    $Known=@('InvalidTarget','UnpreparedPackage','InvalidManifest','PackageHashMismatch','InvalidPackageSignature','HostIdentityMismatch','AdministratorRequired','LocalPowerShell7Required','Python312PlusX64Required','ExistingInstallationPreserved','MissingCredentials','StageAclFailed','RemoteHashMismatch','RemoteSignatureUntrusted','TaskNetworkLogonRequired','InvalidLocalPlan','LocalInstallerFailed','LocalInstallerNoReport','InstallerTimeoutCheckHost')
    $Id=if ($_.Exception.Message -in $Known -or $_.Exception.Message -match '^LocalInstallerExit-?\d+$') { $_.Exception.Message } else { $_.Exception.GetType().Name }
    [Console]::WriteLine('MAGBEL_FLEET:'+(@{ok=$false;phase=$Phase;error_id=$Id} | ConvertTo-Json -Compress))
    exit 1
} finally {
    $Credential=$null; $Code=$null; $Secrets=$null; $Payload64=$null
    if ($Session) {
        if ($Stage -and -not $KeepStage) { try { Invoke-Command -Session $Session -ArgumentList $Stage -ScriptBlock { param($Path) Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue } | Out-Null } catch {} }
        Remove-PSSession $Session
    }
}
