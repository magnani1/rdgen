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
    # A API documentada opera em listeners. Console não é tratado como listener RDP.
    foreach ($Terminal in @('RDP-Tcp')) {
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
        $Stage='compile_listener_api'
        if (-not ('MagbelListenerSecurity' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class MagbelListenerSecurity {
 [StructLayout(LayoutKind.Sequential)] struct Luid { public uint Low; public int High; }
 [StructLayout(LayoutKind.Sequential)] struct Privileges { public uint Count; public Luid Luid; public uint Attributes; }
 [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool LookupPrivilegeValue(string system,string name,out Luid luid);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr token,bool disableAll,ref Privileges state,int length,out Privileges previous,out int needed);
 [DllImport("wtsapi32.dll",EntryPoint="WTSGetListenerSecurityW",CharSet=CharSet.Unicode,ExactSpelling=true,SetLastError=true)] static extern bool Get(IntPtr server,IntPtr reserved,uint flags,string listener,uint info,[Out] byte[] data,uint length,out uint needed);
 [DllImport("wtsapi32.dll",EntryPoint="WTSSetListenerSecurityW",CharSet=CharSet.Unicode,ExactSpelling=true,SetLastError=true)] static extern bool Set(IntPtr server,IntPtr reserved,uint flags,string listener,uint info,byte[] data);
 // Habilita SeSecurityPrivilege temporariamente para preservar a SACL; restaura o estado anterior.
 static T WithPrivilege<T>(Func<T> action) {
  IntPtr token=IntPtr.Zero; Privileges previous=new Privileges(); bool restore=false;
  try {
   if(!OpenProcessToken(GetCurrentProcess(),0x28,out token)) throw new Win32Exception(Marshal.GetLastWin32Error());
   Luid luid; if(!LookupPrivilegeValue(null,"SeSecurityPrivilege",out luid)) throw new Win32Exception(Marshal.GetLastWin32Error());
   var state=new Privileges {Count=1,Luid=luid,Attributes=2}; int needed;
   bool ok=AdjustTokenPrivileges(token,false,ref state,Marshal.SizeOf(typeof(Privileges)),out previous,out needed);
   int error=Marshal.GetLastWin32Error(); restore=ok;
   if(!ok || error!=0) throw new Win32Exception(error);
   return action();
  } finally {
   if(token!=IntPtr.Zero) {
    if(restore) {Privileges ignored;int needed;AdjustTokenPrivileges(token,false,ref previous,Marshal.SizeOf(typeof(Privileges)),out ignored,out needed);}
    CloseHandle(token);
   }
  }
 }
 public static byte[] Read(string listener) {
  return WithPrivilege<byte[]>(delegate {
   uint needed; bool ok=Get(IntPtr.Zero,IntPtr.Zero,0,listener,12,null,0,out needed);
   int error=Marshal.GetLastWin32Error();
   if(!ok && error!=122) throw new Win32Exception(error);
   if(needed==0 || needed>65536) throw new InvalidOperationException("ListenerDescriptorSize");
   byte[] data=new byte[needed];
   if(!Get(IntPtr.Zero,IntPtr.Zero,0,listener,12,data,(uint)data.Length,out needed)) throw new Win32Exception(Marshal.GetLastWin32Error());
   return data;
  });
 }
 public static void Write(string listener,byte[] data) {
  WithPrivilege<bool>(delegate {
   if(!Set(IntPtr.Zero,IntPtr.Zero,0,listener,12,data)) throw new Win32Exception(Marshal.GetLastWin32Error());
   return true;
  });
 }
}
'@ -ErrorAction Stop
        }
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
            $Stage='read_listener_api'
            $NativeBefore=[MagbelListenerSecurity]::Read($Terminal)
            $NativeSd=[Security.AccessControl.RawSecurityDescriptor]::new($NativeBefore,0)
            $OriginalSd=[Security.AccessControl.RawSecurityDescriptor]::new($Plan.Before)
            $Sections=[Security.AccessControl.AccessControlSections]::Access -bor [Security.AccessControl.AccessControlSections]::Audit
            if ($NativeSd.GetSddlForm($Sections) -cne $OriginalSd.GetSddlForm($Sections)) {throw "ACL nativa diverge da prévia. Backup: $Backup"}
            [IO.File]::WriteAllBytes((Join-Path $Folder 'listener-before.bin'),$NativeBefore)
            $DesiredSd=[Security.AccessControl.RawSecurityDescriptor]::new($Plan.After)
            $NativeSd.DiscretionaryAcl=$DesiredSd.DiscretionaryAcl
            $NativeAfter=[byte[]]::new($NativeSd.BinaryLength)
            $NativeSd.GetBinaryForm($NativeAfter,0)
            $Stage='write_descriptor'
            $WriteAttempts+= $Terminal
            [MagbelListenerSecurity]::Write($Terminal,$NativeAfter)
            $Stage='verify_descriptor'
            $ActualBytes=[MagbelListenerSecurity]::Read($Terminal)
            $ActualSd=[Security.AccessControl.RawSecurityDescriptor]::new($ActualBytes,0)
            if ($ActualSd.GetSddlForm($Sections) -cne $NativeSd.GetSddlForm($Sections)) {
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
