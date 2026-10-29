# Worker Facilitador - execução SYSTEM, parâmetros estruturados e saída sem duplicação.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ComputerName,
    [Parameter(Mandatory)][string]$FilePath,
    [string]$RemoteLogPath = '',
    [string]$LogFile = '',
    [string]$Programa = '',
    [string]$NomeScanner = '',
    [pscredential]$Credential,
    [switch]$UseSSL,
    [ValidateRange(30,14400)][int]$TimeoutSeconds = 7200
)
$ErrorActionPreference = 'Stop'
function Write-Log([string]$Mensagem) {
    $linha = '[{0}] [{1}] {2}' -f (Get-Date -Format HH:mm:ss),$ComputerName,$Mensagem
    if ($LogFile) { Add-Content -LiteralPath $LogFile -Value $linha -Encoding UTF8 }
    else { Write-Host $linha }
}
# IP informado: preferir hostname verificado (Kerberos) a alterar TrustedHosts.
function Resolve-DestinoWinRM([string]$Alvo) {
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($Alvo, [ref]$ip)) {
        return [pscustomobject]@{ Destino=$Alvo; Convertido=$false; IP=$false }
    }
    if ($ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw 'Endereço IPv6 informado: utilize o nome DNS do computador para autenticação Kerberos.'
    }
    $ipCanonico = $ip.ToString()
    $nomes = @()
    try {
        $ptr = [System.Net.Dns]::GetHostEntry($ipCanonico)
        if ($ptr.HostName) { $nomes += $ptr.HostName.TrimEnd('.') }
    } catch {}
    foreach ($nome in ($nomes | Select-Object -Unique)) {
        if (-not $nome -or $nome -eq $ipCanonico) { continue }
        if ($nome -notmatch '^(?=.{1,253}$)[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$') { continue }
        try {
            $enderecos = @([System.Net.Dns]::GetHostAddresses($nome) |
                Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
                ForEach-Object { $_.ToString() })
            if ($enderecos -contains $ipCanonico) {
                return [pscustomobject]@{ Destino=$nome; Convertido=$true; IP=$true }
            }
        } catch {}
    }
    return [pscustomobject]@{ Destino=$ipCanonico; Convertido=$false; IP=$true }
}
$session = $null
$codigoFinal = 1
$expirou = $false
$taskName = 'Facilitador_' + [guid]::NewGuid().ToString('N')
$remoteDir = "C:\Windows\Temp\$taskName"
$finalizado = $false
$avisouFallback = $false
$avisouSucesso = $false
function Get-CompleteLogLines {
    param([string]$Text,[int]$Offset=0,[switch]$Final)
    if ($Offset -gt $Text.Length) {$Offset=0}
    $end=if ($Final) {$Text.Length} else {$Text.LastIndexOf("`n")+1}
    if ($end -le $Offset) {return @{Offset=$Offset;Lines=@()}}
    $part=$Text.Substring($Offset,$end-$Offset)
    return @{Offset=$end;Lines=@($part -split "`r?`n" | Where-Object {$_ -ne ''})}
}
function Mostrar-LinhaAnalista([string]$Bruta) {
    if ([string]::IsNullOrWhiteSpace($Bruta)) { return }
    # Remove prefixos conhecidos, mas nunca descarta mensagens de outros fabricantes.
    $m = $Bruta.Trim()
    $m = $m -replace '^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]\s*', ''
    $m = $m -replace '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} - \[DS-790WN\]\s*', ''
    if ([string]::IsNullOrWhiteSpace($m)) { return }
    if ($m -match '^Scanner solicitado:\s*(.+)$') {
        Write-Log "Scanner informado: $($Matches[1]) (cadastro ainda nao validado)"
    } elseif ($m -match '^Instalacao sem apontar scanner\.') {
        Write-Log 'Instalando sem associar scanner.'
    } elseif ($m -match '^Extracao do winget falhou' -and -not $script:avisouFallback) {
        Write-Log 'Extração alternativa do pacote necessária.'
        $script:avisouFallback = $true
    } elseif ($m -match '^SUCESSO:' -and $Programa -match 'Epson' -and -not $script:avisouSucesso) {
        Write-Log 'Programas Epson: componentes essenciais confirmados.'
        $script:avisouSucesso = $true
    } elseif ($m -match '(?i)(\[ERRO|\[FALHA|\[ERRO CR[IÍ]TICO|^ERRO:|^ERROR:|^FALHA:|^EXCEPTION:)') {
        Write-Log "[ERRO SCRIPT] $m"
    } else {
        # Inclui Kodak e novas integrações sem necessidade de atualizar filtros.
        Write-Log $m
    }
}

try {
    Write-Log "Iniciando processamento: $Programa..."
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { throw "Arquivo inexistente: $FilePath" }
    # Validação de sintaxe PowerShell apenas para .ps1.
    # BAT/CMD e EXE possuem linguagens/formatos próprios.
    $extensao = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()
    if ($extensao -notin @('.ps1', '.bat', '.cmd', '.exe')) {
        throw "Formato não suportado pelo worker: $extensao"
    }
    if ($extensao -eq '.ps1') {
        $tokens = $null
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($FilePath,[ref]$tokens,[ref]$parseErrors)
        if ($parseErrors.Count -gt 0) {
            $primeiro = $parseErrors[0]
            throw "Script PowerShell inválido (linha $($primeiro.Extent.StartLineNumber)): $($primeiro.Message)"
        }
    }
    $guard = Join-Path $PSScriptRoot 'Executar-Guardado.ps1'
    if (-not (Test-Path -LiteralPath $guard)) {throw 'Guard assinado ausente: publique o pacote completo.'}
    if ((Get-AuthenticodeSignature -LiteralPath $guard).Status -ne 'Valid') {throw 'Assinatura do guard nao validada.'}
    $runner = Join-Path $PSScriptRoot 'Executar-TarefaLocal.ps1'
    if (-not (Test-Path -LiteralPath $runner)) { throw "Runner assinado ausente: $runner" }
    $alvo = Resolve-DestinoWinRM $ComputerName
    $destinoWinRM = $alvo.Destino
    if ($alvo.Convertido) {
        Write-Log "IP identificado: $ComputerName -> $destinoWinRM (DNS confirmado)."
    } elseif ($alvo.IP) {
        if ($null -eq $Credential) {
            throw "IP $ComputerName sem DNS reverso validado. Informe o nome do computador ou forneça -Credential e configure HTTPS/TrustedHosts específico para conexão por IP."
        }
        if (-not $UseSSL) {
            # IP sobre HTTP só com credenciais explícitas e TrustedHosts definido pelo administrador.
            $trusted = [string](Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value
            $autorizados = @($trusted -split ',' | ForEach-Object { $_.Trim() })
            if ($autorizados -notcontains $ComputerName) {
                throw "IP ${ComputerName}: adicione somente este IP a TrustedHosts em procedimento administrativo aprovado ou habilite WinRM HTTPS. Não foi alterada a configuração de confiança."
            }
        }
        Write-Log "Conectando por IP: $ComputerName (credenciais explícitas)."
    }
    $parametrosSessao = @{ ComputerName=$destinoWinRM; ErrorAction='Stop' }
    if ($null -ne $Credential) { $parametrosSessao.Credential = $Credential }
    if ($UseSSL) { $parametrosSessao.UseSSL = $true }
    $session = New-PSSession @parametrosSessao
    Write-Log '[OK] Sessao WinRM estabelecida. Executando...' 
    Invoke-Command -Session $session -ScriptBlock {
        param($dir,$log)
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        # O arquivo legado so pode ser tocado pelo guard apos adquirir a exclusao.
    } -ArgumentList $remoteDir,$RemoteLogPath
    $remoteScript = "$remoteDir\$(Split-Path $FilePath -Leaf)"
    Copy-Item -LiteralPath $FilePath -Destination $remoteScript -ToSession $session -Force
    Copy-Item -LiteralPath $guard -Destination "$remoteDir\Executar-Guardado.ps1" -ToSession $session -Force
    Copy-Item -LiteralPath $runner -Destination "$remoteDir\Executar-TarefaLocal.ps1" -ToSession $session -Force
    Invoke-Command -Session $session -ScriptBlock {
        param($dir,$scriptPath,$scanner,$task,$timeout,$legacy)
        @{ Script=$scriptPath; NomeScanner=$scanner } | ConvertTo-Json | Set-Content -LiteralPath "$dir\params.json" -Encoding UTF8
        $engine = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $pwsh = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
        if (Test-Path -LiteralPath $pwsh) { $engine = $pwsh }
        @{Engine=$engine;Task=$task;LegacyLog=$legacy} | ConvertTo-Json | Set-Content -LiteralPath "$dir\guard.json" -Encoding UTF8
        $command = '""{0}" -NoProfile -NonInteractive -File "{1}" -Config "{2}" 1>"{3}" 2>&1"' -f $engine,"$dir\Executar-Guardado.ps1","$dir\guard.json","$dir\guard-process.log"
        $action = New-ScheduledTaskAction -Execute $env:ComSpec -Argument ('/d /s /c ' + $command)
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $task
    } -ArgumentList $remoteDir,$remoteScript,$NomeScanner,$taskName,$TimeoutSeconds,$RemoteLogPath
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $result = $null
    $Offsets=@{}
    do {
        Start-Sleep -Seconds 2
        $result = Invoke-Command -Session $session -ScriptBlock {
            param($task,$dir)
            $t = Get-ScheduledTask -TaskName $task -ErrorAction Stop
            $i = Get-ScheduledTaskInfo -TaskName $task -ErrorAction Stop
            $channels=@{}
            # Preferir o snapshot privado do script; stdout e stderr permanecem preservados.
            $script=Join-Path $dir 'script.log'
            if (-not (Test-Path -LiteralPath $script) -or (Get-Item -LiteralPath $script).Length -eq 0) {$script=Join-Path $dir 'legacy-script.log'}
            $names=if ((Test-Path -LiteralPath $script) -and (Get-Item -LiteralPath $script).Length -gt 0) {@('gate.log',(Split-Path $script -Leaf),'stderr.log','guard-process.log')} else {@('gate.log','processo.log','stderr.log','guard-process.log')}
            foreach ($name in $names) {
                $path=Join-Path $dir $name
                if (Test-Path -LiteralPath $path) {
                    $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
                    $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true)
                    try {$channels[$name]=$reader.ReadToEnd()} finally {$reader.Dispose()}
                }
            }
            [pscustomobject]@{State=[string]$t.State; Code=[long]$i.LastTaskResult; LastRun=$i.LastRunTime; Channels=$channels}
        } -ArgumentList $taskName,$remoteDir
        $done=$result.LastRun.Year -gt 2000 -and $result.State -notin @('Running','Queued') -and $result.Code -ne 267009
        foreach ($entry in $result.Channels.GetEnumerator()) {
            $name=[string]$entry.Key; $text=[string]$entry.Value
            $read=Get-CompleteLogLines -Text $text -Offset ([int]$Offsets[$name]) -Final:$done
            foreach ($line in $read.Lines) {if ($line.Trim()) {Mostrar-LinhaAnalista $line}}
            $Offsets[$name]=$read.Offset
        }
        if ($result.LastRun.Year -gt 2000 -and $result.State -notin @('Running','Queued') -and $result.Code -ne 267009) {
            $finalizado = $true
            break
        }
    } while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    if (-not $finalizado) { $expirou = $true; throw 'Tempo limite de acompanhamento excedido; término da tarefa e dos instaladores filhos precisa ser conferido. Resultado DESCONHECIDO, nao reinstale automaticamente.' }
    # processo.log fica preservado para investigacao em caso de erro.
    # Nao despejar novamente linhas que ja chegaram via RemoteLogPath.
    if ([long]$result.Code -notin @(0,3010,1641,1806)) {
        if (-not $RemoteLogPath -or -not $Offsets.Count) {
            $diagnostico = Invoke-Command -Session $session -ScriptBlock {
                param($dir)
                if (Test-Path -LiteralPath "$dir\processo.log") {
                    Get-Content -LiteralPath "$dir\processo.log" -Tail 12
                }
            } -ArgumentList $remoteDir
            $achouErro = $false
            foreach ($linha in $diagnostico) {
                if ([string]$linha -match '(?i)erro|error|exception|acesso negado|denied|parsererror|unexpectedtoken|token inesperado') {
                    Write-Log "[DIAGNOSTICO] $linha"
                    $achouErro = $true
                }
            }
            if (-not $achouErro) { Write-Log "[DIAGNOSTICO] Consulte $remoteDir\processo.log" }
        }
        throw "Script remoto retornou $($result.Code)."
    }
    if ($result.Code -in @(3010,1641)) { Write-Log '[AVISO] Reinicializacao solicitada pelo instalador.' }
    $codigoFinal = 0
} catch {
    if ($expirou) {
        $codigoFinal = 124
        Write-Log "[RESULTADO DESCONHECIDO] $($_.Exception.Message)"
    } else {
        Write-Log "[ERRO] $($_.Exception.Message)"
    }
} finally {
    if ($session) {
        if ($finalizado -and $codigoFinal -eq 0) {
            try {
                Invoke-Command -Session $session -ScriptBlock {
                    param($task,$dir)
                    Unregister-ScheduledTask -TaskName $task -Confirm:$false
                    # Logs exclusivos preservados para auditoria; limpeza por retencao separada.
                } -ArgumentList $taskName,$remoteDir
            } catch { Write-Log "[AVISO] Limpeza pendente: $taskName" }
        } else {
            Write-Log "[AVISO] Diagnostico preservado: $remoteDir | tarefa: $taskName. Confira antes de repetir."
        }
        Remove-PSSession $session
    }
}
if ($codigoFinal -eq 0) { Write-Log 'Operacao concluida com sucesso! [Modo: WinRM]' }
elseif ($codigoFinal -eq 124) { Write-Log 'Operacao com resultado desconhecido: acompanhamento expirou [Modo: WinRM]' }
else { Write-Log 'Operacao concluida com erro: 1 [Modo: WinRM]' }
exit $codigoFinal
