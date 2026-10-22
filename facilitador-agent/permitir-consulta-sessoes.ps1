#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z][a-zA-Z0-9.-]{0,252}$')][string]$ComputerName,
    [string]$Account='TJ-PB\facilitador-servico',
    [switch]$Apply
)
$ErrorActionPreference='Stop'
if ((Get-AuthenticodeSignature -LiteralPath $PSCommandPath).Status -ne 'Valid') {
    throw 'Assine uma cópia deste script fora do checkout.'
}
Invoke-Command -ComputerName $ComputerName -Authentication Kerberos -ConfigurationName Microsoft.PowerShell -ArgumentList $Account,$Apply.IsPresent -ScriptBlock {
    param($Account,$Apply)
    $ErrorActionPreference='Stop'
    $Stage='resolve_account'
    $Terminal=''
    $Backup=$null
    $WriteAttempts=@()
    $Verified=@()
    try {
    $Namespace='root\cimv2\TerminalServices'
    $Sid=([Security.Principal.NTAccount]::new($Account)).Translate([Security.Principal.SecurityIdentifier])
    $Plans=@()
    foreach ($Terminal in @('Console','RDP-Tcp')) {
        $Stage='read_descriptor'
        $Item=Get-CimInstance -Namespace $Namespace -ClassName Win32_TSPermissionsSetting -Filter "TerminalName='$Terminal'"
        if (-not $Item -or -not $Item.StringSecurityDescriptor) {throw "Descritor indisponível: $Terminal"}
        if ($Item.DenyAdminPermissionForCustomization -eq 1) {throw "Personalização bloqueada: $Terminal"}
        $Before=[string]$Item.StringSecurityDescriptor
        $Stage='parse_descriptor'
        $Sd=[Security.AccessControl.RawSecurityDescriptor]::new($Before)
        if ($null -eq $Sd.DiscretionaryAcl) {throw "DACL ausente: $Terminal"}
        $Present=$false
        foreach ($Ace in $Sd.DiscretionaryAcl) {
            if ($Ace -is [Security.AccessControl.CommonAce] -and $Ace.SecurityIdentifier -eq $Sid) {
                if ($Ace.AceQualifier -eq [Security.AccessControl.AceQualifier]::AccessDenied -and ($Ace.AccessMask -band 1)) {
                    throw "Negação direta de consulta encontrada: $Terminal. Nenhuma negação será removida."
                }
                if ($Ace.AceQualifier -eq [Security.AccessControl.AceQualifier]::AccessAllowed -and
                    -not ([int]$Ace.AceFlags -band [int][Security.AccessControl.AceFlags]::InheritOnly) -and ($Ace.AccessMask -band 1)) {$Present=$true}
            }
        }
        if (-not $Present) {
            $Stage='build_query_ace'
            # WINSTATION_QUERY = 0x00000001; sem Logon, Shadow, Reset ou Logoff.
            $NewAce=[Security.AccessControl.CommonAce]::new([Security.AccessControl.AceFlags]::None,[Security.AccessControl.AceQualifier]::AccessAllowed,1,$Sid,$false,$null)
            $Index=$Sd.DiscretionaryAcl.Count
            for ($i=0;$i -lt $Sd.DiscretionaryAcl.Count;$i++) {
                if ([int]$Sd.DiscretionaryAcl[$i].AceFlags -band [int][Security.AccessControl.AceFlags]::Inherited) {$Index=$i;break}
            }
            $Sd.DiscretionaryAcl.InsertAce($Index,$NewAce)
        }
        $Stage='serialize_descriptor'
        $Plans+= [pscustomobject]@{Terminal=$Terminal;Before=$Before;After=$Sd.GetSddlForm([Security.AccessControl.AccessControlSections]::All);Change=(-not $Present)}
    }
    $Backup=$null
    if ($Apply -and @($Plans | Where-Object Change).Count) {
        $Stage='save_backup'
        $Folder=Join-Path $env:ProgramData ('Magbel\SessionQueryBackups\'+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Folder -Force | Out-Null
        $Backup=Join-Path $Folder 'permissions-before.clixml'
        [pscustomobject]@{Computer=$env:COMPUTERNAME;Account=$Account;Sid=$Sid.Value;Plans=$Plans} | Export-Clixml -LiteralPath $Backup
        foreach ($Plan in $Plans | Where-Object Change) {
            $Terminal=$Plan.Terminal
            $Stage='check_concurrent_change'
            $Item=Get-CimInstance -Namespace $Namespace -ClassName Win32_TSPermissionsSetting -Filter "TerminalName='$($Plan.Terminal)'"
            if ([string]$Item.StringSecurityDescriptor -cne $Plan.Before) {throw "Regra mudou durante a operação. Backup: $Backup"}
            $Stage='write_descriptor'
            $WriteAttempts+= $Terminal
            $Item | Set-CimInstance -Property @{StringSecurityDescriptor=$Plan.After} | Out-Null
            $Stage='verify_descriptor'
            $Actual=Get-CimInstance -Namespace $Namespace -ClassName Win32_TSPermissionsSetting -Filter "TerminalName='$($Plan.Terminal)'"
            $ActualSd=[Security.AccessControl.RawSecurityDescriptor]::new([string]$Actual.StringSecurityDescriptor)
            $Wanted=[Security.AccessControl.RawSecurityDescriptor]::new($Plan.After)
            if ($ActualSd.GetSddlForm([Security.AccessControl.AccessControlSections]::Access) -cne $Wanted.GetSddlForm([Security.AccessControl.AccessControlSections]::Access)) {
                throw "Conferência da DACL falhou em $($Plan.Terminal). Backup: $Backup"
            }
            $Verified+= $Terminal
        }
    }
    foreach ($Plan in $Plans) {
        [pscustomobject]@{Computer=$env:COMPUTERNAME;Account=$Account;Sid=$Sid.Value;Terminal=$Plan.Terminal;Permission='WINSTATION_QUERY (0x1)';ChangeNeeded=$Plan.Change;Applied=($Apply -and $Plan.Change);Backup=$Backup;Next='Repetir diagnóstico WTS e consulta no painel; sessões existentes podem exigir nova validação.'}
    }
    } catch {
        $Failure=$_
        $Diagnosis=[ordered]@{Computer=$env:COMPUTERNAME;Stage=$Stage;Terminal=$Terminal;Apply=[bool]$Apply;WriteAttempts=@($WriteAttempts);Verified=@($Verified);Backup=$Backup;ErrorType=$Failure.Exception.GetType().FullName;ErrorId=$Failure.FullyQualifiedErrorId;Line=$Failure.InvocationInfo.ScriptLineNumber;Message=$Failure.Exception.Message}
        # Um erro após a chamada de escrita não prova que o provedor não alterou a ACL.
        throw ('Diagnóstico da permissão WTS: '+($Diagnosis | ConvertTo-Json -Depth 4 -Compress))
    }
}
