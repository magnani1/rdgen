#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9.-]{0,252}$')]
    [string]$ComputerName
)
$ErrorActionPreference = 'Stop'
# Versão e hash revisados no site oficial. Atualizar juntos por PR, nunca usar latest.
$Version = '3.15.1'
$ExpectedHash = '8b23839c6b2f3076fdff44c78d219a5393c7205f666cd95bd0c9a562bf8ea5db'
$Url = "https://www.python.org/ftp/python/$Version/python-$Version-amd64.exe"
$Target = 'C:\Program Files\Python315'
$Cache = Join-Path $env:LOCALAPPDATA 'Magbel\Cache'
$Installer = Join-Path $Cache "python-$Version-amd64.exe"
$Session = $null
try {
    $Session = New-PSSession -ComputerName $ComputerName -Authentication Kerberos -ConfigurationName Microsoft.PowerShell -SessionOption (New-PSSessionOption -OperationTimeout 900000)
    $Existing = Invoke-Command -Session $Session -ArgumentList ($ComputerName.Split('.')[0]),$Target,$Version -ScriptBlock {
        param($HostId,$Target,$Version)
        $ErrorActionPreference = 'Stop'
        if ($env:COMPUTERNAME -ine $HostId) { throw 'Identidade do destino divergente.' }
        if (-not [Environment]::Is64BitOperatingSystem) { throw 'Destino exige Windows x64.' }
        foreach ($Key in @('HKLM:\SOFTWARE\Python\PythonCore\3.15\InstallPath','HKCU:\SOFTWARE\Python\PythonCore\3.15\InstallPath')) {
            if (Test-Path $Key) {
                $Registered = (Get-Item $Key).GetValue('')
                if (-not $Registered -or $Registered.TrimEnd('\') -ine $Target.TrimEnd('\')) {
                    throw 'Python 3.15 já registrado em outra pasta. Conferir antes de alterar.'
                }
            }
        }
        $Python = Join-Path $Target 'python.exe'
        if (Test-Path -LiteralPath $Python) {
            $InstalledVersion = & $Python -c 'import platform; print(platform.python_version())'
            if ($LASTEXITCODE -ne 0 -or $InstalledVersion.Trim() -ne $Version) {
                throw 'Python315 existente difere da versão esperada; não será atualizado automaticamente.'
            }
            return $true
        }
        return $false
    }
    if ($Existing) {
        Write-Host "$ComputerName : Python $Version já instalado em $Target. Agente não alterado."
        return
    }
    New-Item -ItemType Directory -Path $Cache -Force | Out-Null
    if (-not (Test-Path $Installer) -or (Get-FileHash $Installer -Algorithm SHA256).Hash -ne $ExpectedHash) {
        Invoke-WebRequest -Uri $Url -OutFile $Installer
    }
    if ((Get-FileHash $Installer -Algorithm SHA256).Hash -ne $ExpectedHash -or (Get-AuthenticodeSignature $Installer).Status -ne 'Valid') {
        throw 'Instalador sem hash/assinatura válidos.'
    }
    $RemoteInstaller = Invoke-Command -Session $Session -ScriptBlock {
        $Directory = Join-Path $env:TEMP ('magbel-python315-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Directory | Out-Null
        Join-Path $Directory 'python-installer.exe'
    }
    Copy-Item -LiteralPath $Installer -Destination $RemoteInstaller -ToSession $Session
    Invoke-Command -Session $Session -ArgumentList $RemoteInstaller,$ExpectedHash,$Target,$Version -ScriptBlock {
        param($File,$Hash,$Target,$Version)
        $ErrorActionPreference = 'Stop'
        if ((Get-FileHash $File -Algorithm SHA256).Hash -ne $Hash -or (Get-AuthenticodeSignature $File).Status -ne 'Valid') {
            throw 'Instalador transferido sem hash/assinatura válidos.'
        }
        $Log = Join-Path (Split-Path $File) 'python-install.log'
        $Arguments = @('/quiet','/norestart','InstallAllUsers=1',('TargetDir="' + $Target + '"'),'PrependPath=0','AppendPath=0','Include_launcher=0','AssociateFiles=0','Shortcuts=0','Include_test=0','/log',('"' + $Log + '"'))
        $Process = Start-Process -FilePath $File -ArgumentList $Arguments -Wait -PassThru
        if ($Process.ExitCode -notin @(0,3010)) { throw "Instalação falhou: $($Process.ExitCode). Log: $Log" }
        $Python = Join-Path $Target 'python.exe'
        if (-not (Test-Path -LiteralPath $Python)) { throw "Instalador terminou sem criar $Python. Log: $Log" }
        $Info = & $Python -c 'import json,sys,platform; print(json.dumps(dict(version=platform.python_version(),executable=sys.executable,bits=sys.maxsize.bit_length()+1)))'
        if ($LASTEXITCODE -ne 0) { throw "Python instalado não iniciou. Log: $Log" }
        $Info = $Info | ConvertFrom-Json
        if ($Info.version -ne $Version -or $Info.bits -ne 64) { throw "Versão/arquitetura divergente. Log: $Log" }
        [pscustomobject]@{
            Computer = $env:COMPUTERNAME
            Python = $Info.executable
            Version = $Info.version
            Bits = $Info.bits
            InstallerRestartPending = ($Process.ExitCode -eq 3010)
            Log = $Log
            AgentChanged = $false
        }
    }
} finally {
    if ($Session) { Remove-PSSession $Session }
}
