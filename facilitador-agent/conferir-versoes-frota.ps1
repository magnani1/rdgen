#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9.-]{0,252}$')]
    [string[]]$ComputerName = @(
        'facilitadorapp1.tjpb.jus.br',
        'facilitadorapp2.tjpb.jus.br',
        'facilitadorapp3.tjpb.jus.br',
        'facilitadorapp4.tjpb.jus.br'
    )
)
$ErrorActionPreference = 'Stop'
# Consulta somente. Não imprime config, identity.json, argumentos ou credenciais.
foreach ($Computer in $ComputerName) {
    try {
        Invoke-Command -ComputerName $Computer -Authentication Kerberos -ConfigurationName Microsoft.PowerShell -ScriptBlock {
            $ErrorActionPreference = 'Stop'
            $Id = $env:COMPUTERNAME.ToLowerInvariant()
            $Root = Join-Path $env:ProgramData "Magbel\FacilitadorAgent\$Id"
            $Task = Get-ScheduledTask -TaskName "Magbel-Facilitador-$Id" -ErrorAction SilentlyContinue
            $ConfigFile = Join-Path $Root 'config.json'
            $Python = $null
            if (Test-Path -LiteralPath $ConfigFile) {
                $Python = (Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json).AGENT_PYTHON
            }
            $AgentVersion = $null
            $AgentFile = Join-Path $Root 'facilitador-agent.py'
            if (Test-Path -LiteralPath $AgentFile) {
                $Match = [regex]::Match([IO.File]::ReadAllText($AgentFile), '(?m)^VERSION\s*=\s*["'']([^"'']+)["'']')
                if ($Match.Success) { $AgentVersion = $Match.Groups[1].Value }
            }
            $Info = $null
            $RuntimeCheck = 'Python configurado ausente'
            if ($Python -and (Test-Path -LiteralPath $Python -PathType Leaf)) {
                # stdin evita os problemas de aspas em python -c no WinRM/PowerShell 5.1.
                $Code = @'
import json, sys, platform
from importlib import metadata
try:
    requests_version = metadata.version('requests')
except metadata.PackageNotFoundError:
    requests_version = None
print(json.dumps(dict(python=platform.python_version(), bits=sys.maxsize.bit_length()+1, requests=requests_version)))
'@
                $Output = $Code | & $Python -
                if ($LASTEXITCODE -eq 0) {
                    $Info = $Output | ConvertFrom-Json
                    $RuntimeCheck = 'Runtime configurado conferido; validar processo pelo heartbeat 2.0.3'
                } else { $RuntimeCheck = 'Falha ao iniciar o Python configurado' }
            }
            [pscustomobject]@{
                Maquina = $env:COMPUTERNAME
                Tarefa = [string]$Task.State
                Conta = $Task.Principal.UserId
                AgenteNoArquivo = $AgentVersion
                PythonConfigurado = $Python
                VersaoPython = $Info.python
                Bits = $Info.bits
                Requests = $Info.requests
                Python315Instalado = Test-Path -LiteralPath 'C:\Program Files\Python315\python.exe'
                Conferencia = $RuntimeCheck
            }
        }
    } catch {
        Write-Error -Message "$Computer : conferência falhou: $($_.Exception.Message)" -ErrorAction Continue
    }
}
