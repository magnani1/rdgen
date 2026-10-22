#Requires -Version 7.0
[CmdletBinding()]
param(
 [string]$ComputerName='facilitadorapp4.tjpb.jus.br',
 [string]$ServiceId='manutencao-tjpb-app4',
 [string]$HomeUrl='https://facilitador-tjpb.magbel.com.br',
 [string]$ClientId='TJPB',
 [string]$PythonExe='C:\Program Files\Python315\python.exe',
 [switch]$RepairTask
)
$ErrorActionPreference='Stop'
if ($ComputerName -notmatch '^[a-zA-Z][a-zA-Z0-9.-]{0,252}$' -or $ServiceId -notmatch '^[a-z][a-z0-9-]{0,63}$') {throw 'Destino ou identidade inválida.'}
if ((Get-AuthenticodeSignature -LiteralPath $PSCommandPath).Status -ne 'Valid') {throw 'Use o pacote remoto assinado.'}
$Installer=Join-Path $PSScriptRoot 'instalar-manutencao-permanente.ps1'
if ((Get-AuthenticodeSignature -LiteralPath $Installer).Status -ne 'Valid') {throw 'Instalador não assinado.'}
$Code=if ($RepairTask) {ConvertTo-SecureString 'unused' -AsPlainText -Force} else {Read-Host 'Código de inscrição do serviço (válido 10 min)' -AsSecureString}
$Cred=Get-Credential -UserName 'tj-pb\facilitador-servico' -Message 'Conta Windows da tarefa permanente (não é a senha do Facilitador)'
$Session=$null
try {
    $Session=New-PSSession -ComputerName $ComputerName -Authentication Kerberos -ConfigurationName Microsoft.PowerShell
    $RemoteRoot=Invoke-Command -Session $Session -ScriptBlock {
        $Path=Join-Path $env:TEMP ('magbel-maintenance-'+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Path | Out-Null
        $null=& icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F'
        if ($LASTEXITCODE -ne 0) {throw 'Falha ao proteger pacote temporário.'}
        $Path
    }
    foreach ($Name in @('permanent_maintenance.py','maintenance_controller.py','fleet_manager.py','setup_assistant.py','facilitador-agent.py','manutencao-agente.ps1','requirements.txt','instalar-manutencao-permanente.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $Name) -Destination $RemoteRoot -ToSession $Session
    }
    # WinRM/Kerberos transporta PSCredential/secure string; nada sensível na linha de comando ou em arquivos.
    Invoke-Command -Session $Session -ArgumentList $RemoteRoot,$ServiceId,$HomeUrl,$ClientId,$PythonExe,$Cred,$Code,$ComputerName,([bool]$RepairTask) -ScriptBlock {
        param($Package,$Id,$Url,$Client,$Python,$Cred,$Code,$HostName,$Repair)
        $ErrorActionPreference='Stop'
        $PlainCode=[Net.NetworkCredential]::new('',$Code).Password
        $Payload=@{id=$Id;home_url=$Url;client_id=$Client;python=$Python;username=$Cred.UserName;password=$Cred.GetNetworkCredential().Password;code=$PlainCode;hostname=$HostName;repair=[bool]$Repair} | ConvertTo-Json -Compress
        $EncodedPayload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Payload))
        try {
            $EncodedPayload | & 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -NonInteractive -File (Join-Path $Package 'instalar-manutencao-permanente.ps1') -BootstrapFromStdin
            if ($LASTEXITCODE -ne 0) {throw 'Instalação permanente interrompida; conferir runtime antes de repetir.'}
        } finally {$Payload=$null;$EncodedPayload=$null;$PlainCode=$null;$Cred=$null;$Code=$null}
    }
} finally {
    $Cred=$null;$Code=$null
    if ($Session) {Remove-PSSession $Session}
}
