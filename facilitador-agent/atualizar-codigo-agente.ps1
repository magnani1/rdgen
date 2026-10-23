#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z][a-zA-Z0-9.-]{0,252}$')][string]$ComputerName,
    [Parameter(Mandatory)][string]$AgentSourcePath,
    [switch]$ConfirmarDrenadoSemTrabalhos
)
$ErrorActionPreference = 'Stop'
if (-not $ConfirmarDrenadoSemTrabalhos) { throw 'Drene, confira zero trabalhos e pare a tarefa antes de atualizar.' }
if ((Get-AuthenticodeSignature -FilePath $PSCommandPath).Status -ne 'Valid') { throw 'Assine a cópia deste atualizador na estação administrativa.' }
# Agente 2.0.6 revisado. Canonicalização: UTF-8 sem BOM, LF e uma quebra final.
# A referência não é recebida do painel nem de um arquivo de hash não autenticado.
$ExpectedHash = 'bcde24d4c8f6a7413de8c062bd4140168954640bff8dfa62952cb77d6d9cb047'
$Text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $AgentSourcePath).ProviderPath)
$Text = $Text.Replace("`r`n", "`n").TrimEnd([char[]]"`r`n") + "`n"
$Bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
$Hasher = [Security.Cryptography.SHA256]::Create()
try { $Hash = [BitConverter]::ToString($Hasher.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant() }
finally { $Hasher.Dispose() }
if ($Hash -ne $ExpectedHash) { throw 'Código diferente do agente 2.0.6 revisado. Não será instalado.' }

$HostId = $ComputerName.Split('.')[0]
Invoke-Command -ComputerName $ComputerName -Authentication Kerberos -ConfigurationName Microsoft.PowerShell -ArgumentList $HostId,$Bytes,$ExpectedHash -ScriptBlock {
    param($HostId,[byte[]]$Bytes,$ExpectedHash)
    $ErrorActionPreference = 'Stop'
    if ($env:COMPUTERNAME -ine $HostId) { throw 'Identidade do destino divergente.' }
    $Id = $HostId.ToLowerInvariant()
    $TaskName = "Magbel-Facilitador-$Id"
    $Root = Join-Path $env:ProgramData "Magbel\FacilitadorAgent\$Id"
    $Target = Join-Path $Root 'facilitador-agent.py'
    $ConfigPath = Join-Path $Root 'config.json'
    $Identity = Join-Path $Root 'identity.json'
    if ([string](Get-ScheduledTask -TaskName $TaskName).State -ne 'Ready') { throw 'A tarefa precisa estar Ready. Nenhum processo será parado por este script.' }
    $Processes = Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'"
    if (@($Processes | Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($Target,[StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count) {
        throw 'Ainda existe processo do agente: conferir antes de trocar o arquivo.'
    }
    foreach ($File in @($Target,$ConfigPath,$Identity)) {
        if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw 'Runtime ou inscrição existente ausente; não será criada instalação nova.' }
    }
    $Before = @{}
    foreach ($File in @($Target,$ConfigPath,$Identity)) { $Before[$File] = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash }
    $Hasher = [Security.Cryptography.SHA256]::Create()
    try { $Hash = [BitConverter]::ToString($Hasher.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $Hasher.Dispose() }
    if ($Hash -ne $ExpectedHash) { throw 'Hash divergente no destino.' }
    $Current = [IO.File]::ReadAllText($Target).Replace("`r`n","`n").TrimEnd([char[]]"`r`n") + "`n"
    if ($Current -eq [Text.Encoding]::UTF8.GetString($Bytes)) { throw 'Agente 2.0.6 já instalado. Confira o painel; não repita a atualização.' }
    if ($Current -notmatch '(?m)^VERSION\s*=\s*["''](2\.0\.[45])["'']\s*
    $Config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($Config.AGENT_BASE_DIR -ine $Root -or -not $Config.AGENT_PYTHON) { throw 'Configuração não corresponde ao runtime.' }
    $Python = [IO.Path]::GetFullPath([string]$Config.AGENT_PYTHON)
    if (-not $Python.StartsWith($Root+'\',[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $Python -PathType Leaf)) { throw 'Python configurado fora do runtime ou ausente.' }
    $TaskBefore = Export-ScheduledTask -TaskName $TaskName
    $Stamp = (Get-Date -Format yyyyMMddTHHmmss)+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
    $Backup = Join-Path $env:ProgramData "Magbel\AgentCodeBackups\$Id\$Stamp"
    New-Item -ItemType Directory -Path $Backup -Force | Out-Null
    $null = & icacls.exe $Backup /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F'
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao proteger backup.' }
    $Pending = Join-Path $Root "agent-update-$Stamp.tmp"
    $Previous = Join-Path $Backup 'facilitador-agent-before.py'
    $Replaced = $false
    try {
        [IO.File]::WriteAllBytes($Pending,$Bytes)
        $Compile = 'import pathlib,sys; compile(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"),sys.argv[1],"exec")'
        $Compile | & $Python -I - $Pending
        if ($LASTEXITCODE -ne 0) { throw 'Novo código não compilou; arquivo atual preservado.' }
        if ([string](Get-ScheduledTask -TaskName $TaskName).State -ne 'Ready' -or (Export-ScheduledTask -TaskName $TaskName) -ne $TaskBefore) { throw 'A tarefa mudou durante o preparo.' }
        foreach ($File in @($Target,$ConfigPath,$Identity)) {
            if ((Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash -ne $Before[$File]) { throw 'Runtime/configuração/inscrição mudou durante o preparo.' }
        }
        [IO.File]::Replace($Pending,$Target,$Previous)
        $Replaced = $true
        if ((Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $ExpectedHash) { throw 'Conferência do código instalado falhou.' }
        Start-ScheduledTask -TaskName $TaskName
        [pscustomobject]@{Computer=$env:COMPUTERNAME;AgentVersion='2.0.6';PreviousVersion=$PreviousVersion;Python=$Python;IdentityPreserved=$true;ConfigPreserved=$true;Backup=$Previous;Activation='Aguardar heartbeat 2.0.6, conferir Python e prontidão; testar antes de ativar.'}
    } catch {
        if ($Replaced) { Write-Warning "Código trocado; confira tarefa/painel antes de repetir. Backup anterior: $Previous" }
        throw
    } finally {
        if (Test-Path -LiteralPath $Pending) { Remove-Item -LiteralPath $Pending -Force }
    }
}
) { throw 'Esta entrega atualiza apenas o agente 2.0.4 ou 2.0.5 para 2.0.6.' }
    $PreviousVersion = $Matches[1]
    $Config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($Config.AGENT_BASE_DIR -ine $Root -or -not $Config.AGENT_PYTHON) { throw 'Configuração não corresponde ao runtime.' }
    $Python = [IO.Path]::GetFullPath([string]$Config.AGENT_PYTHON)
    if (-not $Python.StartsWith($Root+'\',[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $Python -PathType Leaf)) { throw 'Python configurado fora do runtime ou ausente.' }
    $TaskBefore = Export-ScheduledTask -TaskName $TaskName
    $Stamp = (Get-Date -Format yyyyMMddTHHmmss)+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
    $Backup = Join-Path $env:ProgramData "Magbel\AgentCodeBackups\$Id\$Stamp"
    New-Item -ItemType Directory -Path $Backup -Force | Out-Null
    $null = & icacls.exe $Backup /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F'
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao proteger backup.' }
    $Pending = Join-Path $Root "agent-update-$Stamp.tmp"
    $Previous = Join-Path $Backup 'facilitador-agent-before.py'
    $Replaced = $false
    try {
        [IO.File]::WriteAllBytes($Pending,$Bytes)
        $Compile = 'import pathlib,sys; compile(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"),sys.argv[1],"exec")'
        $Compile | & $Python -I - $Pending
        if ($LASTEXITCODE -ne 0) { throw 'Novo código não compilou; arquivo atual preservado.' }
        if ([string](Get-ScheduledTask -TaskName $TaskName).State -ne 'Ready' -or (Export-ScheduledTask -TaskName $TaskName) -ne $TaskBefore) { throw 'A tarefa mudou durante o preparo.' }
        foreach ($File in @($Target,$ConfigPath,$Identity)) {
            if ((Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash -ne $Before[$File]) { throw 'Runtime/configuração/inscrição mudou durante o preparo.' }
        }
        [IO.File]::Replace($Pending,$Target,$Previous)
        $Replaced = $true
        if ((Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $ExpectedHash) { throw 'Conferência do código instalado falhou.' }
        Start-ScheduledTask -TaskName $TaskName
        [pscustomobject]@{Computer=$env:COMPUTERNAME;AgentVersion='2.0.6';Python=$Python;IdentityPreserved=$true;ConfigPreserved=$true;Backup=$Previous;Activation='Aguardar heartbeat 2.0.6, conferir Python e prontidão; testar antes de ativar.'}
    } catch {
        if ($Replaced) { Write-Warning "Código trocado; confira tarefa/painel antes de repetir. Backup anterior: $Previous" }
        throw
    } finally {
        if (Test-Path -LiteralPath $Pending) { Remove-Item -LiteralPath $Pending -Force }
    }
}
