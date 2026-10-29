#Requires -Version 5.1
<# Gate local por computador. A tarefa continua protegida mesmo se o watcher perder contato.
Nao encerra msiexec, setups ou tarefas anteriores. Falha de acompanhamento nao libera o marcador.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Config)
$ErrorActionPreference='Stop'
$Settings=Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
$Dir=Split-Path -LiteralPath $Config
$Root=Join-Path $env:ProgramData 'Magbel\ExecutionGate'
$Marker=Join-Path $Root 'active.json'
$Lock=$null; $Process=$null; $Confirmed=$false; $OwnedMarker=$false; $Code=1; $script:LegacyOffset=0
function Write-Gate([string]$Text) {
    Add-Content -LiteralPath (Join-Path $Dir 'gate.log') -Value ('[{0}] {1}' -f (Get-Date -Format HH:mm:ss),$Text) -Encoding UTF8
}
function Test-InstallerBusy {
    # Nao confundir o servico msiexec /V ocioso com um cliente de instalacao.
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\InProgress') {return $true}
    $Clients=@(Get-CimInstance Win32_Process -Filter "Name='msiexec.exe'" -ErrorAction Stop | Where-Object {
        $_.CommandLine -match '(?i)(?:^|\s)/(?:i|x|p|package|update|uninstall)(?:\s|"|$)'
    })
    return $Clients.Count -gt 0
}
function Copy-OwnedLegacyLog {
    if ($Settings.LegacyLog -and (Test-Path -LiteralPath $Settings.LegacyLog -PathType Leaf)) {
        # Snapshot exclusivo desta tarefa, somente durante a posse do gate.
        $Stream=[IO.File]::Open([string]$Settings.LegacyLog,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        $Reader=[IO.StreamReader]::new($Stream,[Text.Encoding]::UTF8,$true)
        try {$Text=$Reader.ReadToEnd()} finally {$Reader.Dispose()}
        if ($Text.Length -lt $script:LegacyOffset) {$script:LegacyOffset=0}
        # Snapshot append-only: reler a fonte nao regrava o que ja foi encaminhado.
        if ($Text.Length -gt $script:LegacyOffset) {
            [IO.File]::AppendAllText((Join-Path $Dir 'legacy-script.log'),$Text.Substring($script:LegacyOffset),[Text.UTF8Encoding]::new($false))
            $script:LegacyOffset=$Text.Length
        }
    }
}
try {
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    $null=& icacls.exe $Root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F'
    if ($LASTEXITCODE -ne 0) {throw 'Falha ao proteger o gate local.'}
    Write-Gate 'Na fila local: aguardando exclusao por computador; nenhuma instalacao sera encerrada.'
    while (-not $Lock) {
        try {$Lock=[IO.File]::Open((Join-Path $Root 'execution.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
        catch [IO.IOException] {Start-Sleep -Seconds 2}
    }
    if (Test-Path -LiteralPath $Marker) {throw "Execucao anterior sem encerramento confirmado. Conferir $Marker antes de liberar o destino."}
    # Compatibilidade: tarefas antigas nao possuem o gate e devem terminar primeiro.
    while ($true) {
        $Older=@(Get-ScheduledTask -ErrorAction Stop | Where-Object {
            $_.TaskName -like 'Facilitador_*' -and $_.State -in @('Running','Queued') -and
            (($_.Actions.Arguments -join ' ') -notmatch 'Executar-Guardado\.ps1')
        })
        if (-not $Older.Count -and -not (Test-InstallerBusy)) {break}
        Start-Sleep -Seconds 3
    }
    @{task=$Settings.Task;directory=$Dir;started=(Get-Date).ToUniversalTime().ToString('o');guard_pid=$PID} |
        ConvertTo-Json | Set-Content -LiteralPath $Marker -Encoding UTF8
    $OwnedMarker=$true
    if ($Settings.LegacyLog) {
        $Parent=Split-Path ([string]$Settings.LegacyLog)
        New-Item -ItemType Directory -Path $Parent -Force | Out-Null
        if (Test-Path -LiteralPath $Settings.LegacyLog) {
            Copy-Item -LiteralPath $Settings.LegacyLog -Destination (Join-Path $Dir 'legacy-before.log')
        }
        Set-Content -LiteralPath $Settings.LegacyLog -Value '' -Encoding UTF8
    }
    # Caminhos exclusivos para scripts novos; antigos continuam suportados pelo snapshot sob exclusao.
    $env:FACILITADOR_LOG_PATH=Join-Path $Dir 'script.log'
    $env:FACILITADOR_WORK_DIR=$Dir
    Write-Gate 'Exclusao adquirida. Iniciando somente a tarefa atual.'
    $Arguments='-NoProfile -NonInteractive -File "{0}" -Config "{1}"' -f (Join-Path $Dir 'Executar-TarefaLocal.ps1'),(Join-Path $Dir 'params.json')
    $Process=Start-Process -FilePath ([string]$Settings.Engine) -ArgumentList $Arguments -PassThru -NoNewWindow `
        -RedirectStandardOutput (Join-Path $Dir 'processo.log') -RedirectStandardError (Join-Path $Dir 'stderr.log')
    $Tracked=@{}
    $Created=Get-CimInstance Win32_Process -Filter ("ProcessId="+$Process.Id) -ErrorAction Stop
    if ($Created) {$Tracked[$Process.Id]=[datetime]$Created.CreationDate}
    do {
        Copy-OwnedLegacyLog
        # Inclui filhos conhecidos para nao liberar o gate apenas porque o launcher terminou.
        $All=@(Get-CimInstance Win32_Process -ErrorAction Stop)
        do {
            $Added=$false
            foreach ($Item in $All) {
                if ($Tracked.ContainsKey([int]$Item.ParentProcessId) -and -not $Tracked.ContainsKey([int]$Item.ProcessId) -and
                    [datetime]$Item.CreationDate -ge $Tracked[[int]$Item.ParentProcessId]) {
                    $Tracked[[int]$Item.ProcessId]=[datetime]$Item.CreationDate; $Added=$true
                }
            }
        } while ($Added)
        $Live=@($All | Where-Object {$Tracked.ContainsKey([int]$_.ProcessId) -and [datetime]$_.CreationDate -eq $Tracked[[int]$_.ProcessId]})
        $Process.Refresh()
        if ($Process.HasExited -and -not $Live.Count -and -not (Test-InstallerBusy)) {break}
        Start-Sleep -Seconds 2
    } while ($true)
    $Process.WaitForExit(); $Process.Refresh()
    if ($null -eq $Process.ExitCode) {throw 'Codigo final do runner nao confirmado.'}
    $Code=[int]$Process.ExitCode
    Copy-OwnedLegacyLog
    $Confirmed=$true
    Write-Gate "Tarefa e filhos observados encerrados. Codigo: $Code."
} catch {
    Write-Gate ('[RESULTADO DESCONHECIDO/BLOQUEADO] '+$_.Exception.Message)
} finally {
    if ($OwnedMarker -and $Confirmed) {Remove-Item -LiteralPath $Marker -Force}
    if ($Lock) {$Lock.Dispose()}
}
exit $Code
