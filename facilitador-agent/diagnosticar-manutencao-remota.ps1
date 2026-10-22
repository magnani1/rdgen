#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ProbeSource,[string]$ComputerName='facilitadorapp4.tjpb.jus.br',[string]$Target='facilitadorapp1.tjpb.jus.br',[string]$ServiceId='manutencao-tjpb-app4')
$ErrorActionPreference='Stop'
if ($ComputerName -notmatch '^[a-zA-Z][a-zA-Z0-9.-]{0,252}$' -or $Target -notmatch '^[a-zA-Z][a-zA-Z0-9.-]{0,252}$' -or $ServiceId -notmatch '^[a-z][a-z0-9-]{0,63}$') {throw 'Destino ou serviço inválido.'}
if ((Get-AuthenticodeSignature -LiteralPath $PSCommandPath).Status -ne 'Valid') {throw 'Assine a cópia do diagnóstico na estação administrativa.'}
$Text=[IO.File]::ReadAllText((Resolve-Path -LiteralPath $ProbeSource).ProviderPath).Replace("`r`n","`n").TrimEnd([char[]]"`r`n")+"`n"
$Bytes=[Text.UTF8Encoding]::new($false).GetBytes($Text)
$Hasher=[Security.Cryptography.SHA256]::Create()
try {$Hash=[BitConverter]::ToString($Hasher.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant()} finally {$Hasher.Dispose()}
$Expected='3561bcbef4e0a908b4c9d30acdada87622106f1b7d06851e65dd56f83ebcf20a'
if ($Hash -ne $Expected) {throw 'Código da sonda divergente; nenhuma tarefa criada.'}
$Cred=Get-Credential -UserName 'tj-pb\facilitador-servico' -Message 'Diagnóstico somente leitura na mesma conta do serviço permanente'
$Session=$null
try {
    $Session=New-PSSession -ComputerName $ComputerName -Authentication Kerberos -ConfigurationName Microsoft.PowerShell
    Invoke-Command -Session $Session -ArgumentList $Bytes,$Expected,$Target,$ServiceId,$Cred -ScriptBlock {
        param([byte[]]$Bytes,$Expected,$Target,$ServiceId,$Cred)
        $ErrorActionPreference='Stop'
        $Hasher=[Security.Cryptography.SHA256]::Create()
        try {$Hash=[BitConverter]::ToString($Hasher.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant()} finally {$Hasher.Dispose()}
        if ($Hash -ne $Expected) {throw 'Hash divergente após transporte.'}
        $Root=Join-Path $env:ProgramData ('Magbel\Maintenance\'+$ServiceId)
        $Permanent=Get-ScheduledTask -TaskName ('Magbel-Manutencao-'+$ServiceId)
        function Sid-For([string]$Name) {
            if ($Name -match '^S-1-') {return $Name}
            ([Security.Principal.NTAccount]::new($Name)).Translate([Security.Principal.SecurityIdentifier]).Value
        }
        $Sid=Sid-For $Cred.UserName
        if ($Sid -ne (Sid-For $Permanent.Principal.UserId)) {throw 'Informe a mesma conta da tarefa permanente.'}
        $Identity=Get-Content -LiteralPath (Join-Path $Root 'identity.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($Target.ToLowerInvariant() -notin $Identity.hosts) {throw 'Destino fora do escopo do serviço.'}
        $Stamp=[guid]::NewGuid().ToString('N')
        $Work=Join-Path $Root ('diagnostic-'+$Stamp)
        $OutputFolder=Join-Path $Work 'output'
        $Probe=Join-Path $Work 'probe.py'
        $Output=Join-Path $OutputFolder 'result.json'
        New-Item -ItemType Directory -Path $Work | Out-Null
        $null=& icacls.exe $Work /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' "*${Sid}:(OI)(CI)RX"
        if ($LASTEXITCODE -ne 0) {throw 'Falha ao proteger diagnóstico.'}
        New-Item -ItemType Directory -Path $OutputFolder | Out-Null
        $null=& icacls.exe $OutputFolder /grant:r "*${Sid}:(OI)(CI)M"
        if ($LASTEXITCODE -ne 0) {throw 'Falha ao proteger resultado.'}
        [IO.File]::WriteAllBytes($Probe,$Bytes)
        $Python=Join-Path $Root 'venv\Scripts\python.exe'
        $TaskName='Magbel-Diagnostico-'+$Stamp
        try {
            $Arguments='-X utf8 "'+$Probe+'" --root "'+$Root+'" --target "'+$Target+'" --output "'+$Output+'"'
            $Action=New-ScheduledTaskAction -Execute $Python -Argument $Arguments -WorkingDirectory $Work
            $Trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddHours(1)
            $Settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew
            $null=Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -User $Cred.UserName -Password $Cred.GetNetworkCredential().Password -RunLevel Highest
            Start-ScheduledTask -TaskName $TaskName
            $Limit=(Get-Date).AddSeconds(120)
            do {
                if (Test-Path -LiteralPath $Output) {break}
                Start-Sleep -Seconds 2
            } while ((Get-Date) -lt $Limit)
            if (-not (Test-Path -LiteralPath $Output)) {
                $Result=(Get-ScheduledTaskInfo -TaskName $TaskName).LastTaskResult
                throw "Sonda não produziu resultado. Código da tarefa diagnóstica: $Result"
            }
            Get-Content -LiteralPath $Output -Raw -Encoding UTF8
        } finally {
            $Cred=$null
            $Diagnostic=Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            if ($Diagnostic) {
                if ([string]$Diagnostic.State -eq 'Running') {Stop-ScheduledTask -TaskName $TaskName}
                Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            }
        }
    }
} finally {$Cred=$null;if ($Session) {Remove-PSSession $Session}}
