#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z][a-zA-Z0-9.-]{0,252}$')][string]$ComputerName,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$OperationId,
    [Parameter(Mandatory)][ValidateSet('Apply','Rollback')][string]$Action,
    [Parameter(Mandatory)][string]$AgentSourcePath
)
$ErrorActionPreference = 'Stop'
if ((Get-AuthenticodeSignature -LiteralPath $PSCommandPath).Status -ne 'Valid') { throw 'Assine esta cópia do helper na estação administrativa.' }
$Expected = 'bcde24d4c8f6a7413de8c062bd4140168954640bff8dfa62952cb77d6d9cb047'
$PreviousHash = '85242894a703ae6d7d57e521b91f4e9d237e51e00055fd918357ba9758a8c128'
$Text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $AgentSourcePath).ProviderPath).Replace("`r`n","`n").TrimEnd([char[]]"`r`n")+"`n"
$Bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
$Hasher = [Security.Cryptography.SHA256]::Create()
try { $Hash = [BitConverter]::ToString($Hasher.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant() } finally { $Hasher.Dispose() }
if ($Hash -ne $Expected) { throw 'Código fora da referência homologada 2.0.6.' }
$HostId = $ComputerName.Split('.')[0].ToLowerInvariant()
Invoke-Command -ComputerName $ComputerName -Authentication Kerberos -ConfigurationName Microsoft.PowerShell -ArgumentList $HostId,$OperationId,$Action,$Bytes,$Expected,$PreviousHash -ScriptBlock {
    param($Id,$OperationId,$Action,[byte[]]$Bytes,$Expected,$PreviousHash)
    $ErrorActionPreference = 'Stop'
    $BackupReady = $false
    try {
    if ($env:COMPUTERNAME -ine $Id) { throw 'Identidade do destino divergente.' }
    $Hasher = [Security.Cryptography.SHA256]::Create()
    try { $Incoming = [BitConverter]::ToString($Hasher.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant() } finally { $Hasher.Dispose() }
    if ($Incoming -ne $Expected) { throw 'Hash de transporte divergente.' }
    $Root = Join-Path $env:ProgramData "Magbel\FacilitadorAgent\$Id"
    $Target = Join-Path $Root 'facilitador-agent.py'
    $ConfigPath = Join-Path $Root 'config.json'
    $Identity = Join-Path $Root 'identity.json'
    $TaskName = "Magbel-Facilitador-$Id"
    $Backup = Join-Path $env:ProgramData "Magbel\AgentCodeBackups\$Id\$OperationId"
    $MetaFile = Join-Path $Backup 'operation.json'
    $BeforeFile = Join-Path $Backup 'before.py'
    $Pending = Join-Path $Root "maintenance-$OperationId.tmp"
    function Hash-File([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
    function Canonical-Hash([string]$Path) {
        $Value = [IO.File]::ReadAllText($Path).Replace("`r`n","`n").TrimEnd([char[]]"`r`n")+"`n"
        $Hasher = [Security.Cryptography.SHA256]::Create()
        try { [BitConverter]::ToString($Hasher.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($Value))).Replace('-','').ToLowerInvariant() } finally { $Hasher.Dispose() }
    }
    foreach ($File in @($Target,$ConfigPath,$Identity)) { if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw 'Runtime ou identidade ausente; não será inscrito um agente novo.' } }
    $Task = Get-ScheduledTask -TaskName $TaskName
    $TaskXml = Export-ScheduledTask -TaskName $TaskName
    $Config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $Python = [IO.Path]::GetFullPath([string]$Config.AGENT_PYTHON)
    if ($Config.AGENT_BASE_DIR -ine $Root -or -not $Python.StartsWith($Root+'\',[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $Python -PathType Leaf)) { throw 'Runtime configurado inválido.' }
    if ($Task.Principal.LogonType -ne 'Password') { throw 'Esta entrega preserva tarefas existentes com LogonType Password.' }
    if ($Action -eq 'Apply') {
        if (Test-Path -LiteralPath $Backup) { throw 'Operação já iniciada; não repetir a instalação.' }
        if ((Canonical-Hash $Target) -ne $PreviousHash) { throw 'Esta entrega atualiza somente o código 2.0.5 homologado.' }
        New-Item -ItemType Directory -Path $Backup | Out-Null
        $null = & icacls.exe $Backup /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F'
        if ($LASTEXITCODE -ne 0) { throw 'Não foi possível proteger o backup.' }
        Copy-Item -LiteralPath $Target -Destination $BeforeFile
        $Meta = @{ConfigHash=(Hash-File $ConfigPath); IdentityHash=(Hash-File $Identity); CodeHash=(Hash-File $Target); TaskXml=$TaskXml}
        $Meta | ConvertTo-Json | Set-Content -LiteralPath $MetaFile -Encoding UTF8
    } else {
        if (-not (Test-Path -LiteralPath $MetaFile -PathType Leaf) -or -not (Test-Path -LiteralPath $BeforeFile -PathType Leaf)) { throw 'Backup completo desta operação não encontrado.' }
        $Meta = Get-Content -LiteralPath $MetaFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ((Hash-File $BeforeFile) -ne $Meta.CodeHash -or (Canonical-Hash $BeforeFile) -ne $PreviousHash) { throw 'Backup divergente.' }
        if ((Canonical-Hash $Target) -notin @($Expected,$PreviousHash)) { throw 'Código atual mudou; não sobrescrever.' }
    }
    $BackupReady = $true
    if ((Hash-File $ConfigPath) -ne $Meta.ConfigHash -or (Hash-File $Identity) -ne $Meta.IdentityHash -or $TaskXml -ne $Meta.TaskXml) { throw 'Configuração, inscrição ou tarefa mudou.' }
    # O backend só libera esta etapa após drenagem e zero trabalhos. Nunca mata outros Pythons.
    if ([string]$Task.State -eq 'Running') { Stop-ScheduledTask -TaskName $TaskName }
    $Limit = (Get-Date).AddSeconds(30)
    do {
        $State = [string](Get-ScheduledTask -TaskName $TaskName).State
        $Processes = @(Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($Target,[StringComparison]::OrdinalIgnoreCase) -ge 0 })
        if ($State -eq 'Ready' -and $Processes.Count -eq 0) { break }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $Limit)
    if ($State -ne 'Ready' -or $Processes.Count) { throw 'Tarefa ou processo ainda em execução; arquivo não foi trocado.' }
    try {
        if ($Action -eq 'Apply') { [IO.File]::WriteAllBytes($Pending,$Bytes) } else { Copy-Item -LiteralPath $BeforeFile -Destination $Pending }
        $Compile = 'import pathlib,sys; compile(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8-sig"),sys.argv[1],"exec")'
        $Compile | & $Python -I - $Pending
        if ($LASTEXITCODE -ne 0) { throw 'Código não compilou no Python configurado.' }
        if ((Export-ScheduledTask -TaskName $TaskName) -ne $Meta.TaskXml -or (Hash-File $ConfigPath) -ne $Meta.ConfigHash -or (Hash-File $Identity) -ne $Meta.IdentityHash) { throw 'Runtime mudou durante a conferência.' }
        [IO.File]::Replace($Pending,$Target,(Join-Path $Backup ("swap-"+$Action+".py")))
        $Installed = Canonical-Hash $Target
        if (($Action -eq 'Apply' -and $Installed -ne $Expected) -or ($Action -eq 'Rollback' -and $Installed -ne $PreviousHash)) { throw 'Hash instalado divergente.' }
        Start-ScheduledTask -TaskName $TaskName
        # Saída sem configurações, credenciais ou logs do agente.
        [pscustomobject]@{Operation=$OperationId; Action=$Action; Agent=$Id; Ok=$true; IdentityPreserved=$true; Backup=$Backup} | ConvertTo-Json -Compress
    } finally { if (Test-Path -LiteralPath $Pending) { Remove-Item -LiteralPath $Pending -Force } }
    } catch {
        [pscustomobject]@{Operation=$OperationId; Action=$Action; Agent=$Id; Ok=$false; RollbackAvailable=$BackupReady; ErrorCode='remote_step_failed'} | ConvertTo-Json -Compress
    }
}
