#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z][a-zA-Z0-9.-]{0,252}$')][string]$Target,
    [Parameter(Mandatory)][string]$AgentSourcePath,
    [string]$AgentComputer='facilitadorapp4.tjpb.jus.br'
)
$ErrorActionPreference='Stop'
if ((Get-AuthenticodeSignature -LiteralPath $PSCommandPath).Status -ne 'Valid') {throw 'Assine esta cópia do diagnóstico.'}
$Text=[IO.File]::ReadAllText((Resolve-Path -LiteralPath $AgentSourcePath).ProviderPath).Replace("`r`n","`n").TrimEnd([char[]]"`r`n")+"`n"
$Hasher=[Security.Cryptography.SHA256]::Create()
try {$Hash=[BitConverter]::ToString($Hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','').ToLowerInvariant()} finally {$Hasher.Dispose()}
if ($Hash -ne '85242894a703ae6d7d57e521b91f4e9d237e51e00055fd918357ba9758a8c128') {throw 'Este diagnóstico requer o código 2.0.5 revisado.'}
$Match=[regex]::Match($Text,"(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@")
if (-not $Match.Success) {throw 'Wrapper WTS não encontrado.'}
$Definition=$Match.Groups[1].Value.Replace('throw new InvalidOperationException("WtsQueryFailed")','{var e=new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());e.Data["SessionId"]=id;throw e;}').Replace('throw new InvalidOperationException("WtsEnumerateFailed")','throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error())').Replace('MagbelWts','MagbelDiagWts')
$Report=[ordered]@{Origin=$env:COMPUTERNAME;AgentComputer=$AgentComputer;Target=$Target;AgentPath=$null;Wts=$null}
# Esta etapa usa a identidade administrativa atual apenas para testar o caminho TCP.
try {
    $Report.AgentPath=Invoke-Command -ComputerName $AgentComputer -Authentication Kerberos -ConfigurationName Microsoft.PowerShell -ArgumentList $Target -ErrorAction Stop -ScriptBlock {
        param($Target)
        $Client=[Net.Sockets.TcpClient]::new()
        try {
            $Pending=$Client.BeginConnect($Target,5985,$null,$null)
            if (-not $Pending.AsyncWaitHandle.WaitOne(5000)) {throw 'TcpTimeout'}
            $Client.EndConnect($Pending)
            [pscustomobject]@{Computer=$env:COMPUTERNAME;Tcp5985=$true}
        } catch {[pscustomobject]@{Computer=$env:COMPUTERNAME;Tcp5985=$false}}
        finally {$Client.Dispose()}
    }
} catch {$Report.AgentPath=[pscustomobject]@{Stage='access_agent';Ok=$false;ErrorType=$_.Exception.GetType().Name}}
$Cred=Get-Credential -UserName 'tj-pb\facilitador-servico' -Message 'Conta de serviço: diagnóstico WTS somente leitura, a partir desta estação'
try {
    $Result=Invoke-Command -ComputerName $Target -Authentication Kerberos -ConfigurationName Microsoft.PowerShell -Credential $Cred -ArgumentList $Definition -ErrorAction Stop -ScriptBlock {
        param($Definition)
        $ErrorActionPreference='Stop'
        $r=[ordered]@{Computer=$env:COMPUTERNAME;Identity=[Security.Principal.WindowsIdentity]::GetCurrent().Name;LanguageMode=[string]$ExecutionContext.SessionState.LanguageMode;Stage='compile';Ok=$false}
        try {
            Add-Type -TypeDefinition $Definition -ErrorAction Stop
            $r.Stage='read_sessions'
            $Rows=@([MagbelDiagWts]::Read())
            $r.SessionCount=$Rows.Count;$r.Ok=$true;$r.Stage='complete'
        } catch {
            $e=$_.Exception;$r.ErrorType=$e.GetType().Name
            $r.ErrorId=($_.FullyQualifiedErrorId -split ',')[0] -replace '[^a-zA-Z0-9_.-]',''
            while ($e) {
                if ($e -is [ComponentModel.Win32Exception]) {$r.NativeCode=$e.NativeErrorCode}
                if ($e.Data.Contains('SessionId')) {$r.SessionId=$e.Data['SessionId']}
                $e=$e.InnerException
            }
        }
        [pscustomobject]$r
    }
    $Report.Wts=$Result | Select-Object Computer,Identity,LanguageMode,Stage,Ok,SessionCount,ErrorType,ErrorId,NativeCode,SessionId
} catch {
    $Report.Wts=[pscustomobject]@{Stage='winrm';Ok=$false;ErrorType=$_.Exception.GetType().Name;ErrorId=(($_.FullyQualifiedErrorId -split ',')[0] -replace '[^a-zA-Z0-9_.-]','')}
} finally {$Cred=$null}
[pscustomobject]$Report | ConvertTo-Json -Depth 5
