#Requires -Version 5.1
$ErrorActionPreference='Stop'
if (-not $env:FACILITADOR_LOG_PATH) {throw 'Execute pelo worker protegido, sem instaladores.'}
function Registrar([string]$Evento) {
    [IO.File]::AppendAllText($env:FACILITADOR_LOG_PATH,('TESTE_A_{0} {1:o}' -f $Evento,(Get-Date).ToUniversalTime())+"`n",[Text.UTF8Encoding]::new($false))
}
Registrar 'INICIO'
Start-Sleep -Seconds 20
Registrar 'FIM'
