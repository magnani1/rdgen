#Requires -Version 5.1
# Teste local de processos inofensivos. Nao usa WinRM, tarefas ou instaladores.
$ErrorActionPreference='Stop'
if ($env:OS -ne 'Windows_NT') {throw 'Este teste exige Windows.'}
$File=Join-Path $PSScriptRoot '..\worker\Executar-Guardado.ps1'
$Tokens=$null;$Errors=$null
$Ast=[Management.Automation.Language.Parser]::ParseFile($File,[ref]$Tokens,[ref]$Errors)
if ($Errors.Count) {throw "Parser recusou guard: $($Errors.Message)"}
$Definition=$Ast.Find({param($Node)
    $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $Node.Name -eq 'Start-OwnedRunnerProcess'
},$true)
if (-not $Definition) {throw 'Launcher com handle proprio ausente.'}
. ([scriptblock]::Create($Definition.Extent.Text))
$Engines=@((Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'))
$Pwsh=Get-Command pwsh.exe -ErrorAction SilentlyContinue
if ($Pwsh) {$Engines+=$Pwsh.Source}
$Temp=Join-Path ([IO.Path]::GetTempPath()) ('magbel guard exit '+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Temp | Out-Null
$Passed=$false
try {
    foreach ($Engine in ($Engines | Select-Object -Unique)) {
        foreach ($Code in @(0,7,3010)) {
            foreach ($Delay in @(0,250)) {
                $Directory=Join-Path $Temp ([guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $Directory | Out-Null
                $Arguments='-NoProfile -NonInteractive -Command "Start-Sleep -Milliseconds {0}; [Console]::Out.WriteLine(''OUT''); [Console]::Error.WriteLine(''ERR''); exit {1}"' -f $Delay,$Code
                $Process=$null
                try {
                    $Process=Start-OwnedRunnerProcess -Engine $Engine -Arguments $Arguments -Directory $Directory
                    if (-not $Process.WaitForExit(15000)) {throw "Processo de teste sem termino confirmado; logs: $Directory"}
                    # Reproduz as leituras/Refresh feitas pelo guard apos a saida.
                    $Process.Refresh();$null=$Process.HasExited
                    $Process.WaitForExit();$Process.Refresh()
                    if ($null -eq $Process.ExitCode -or $Process.ExitCode -ne $Code) {
                        throw "Codigo esperado $Code, recebido '$($Process.ExitCode)' em $Engine."
                    }
                    if (([IO.File]::ReadAllText((Join-Path $Directory 'processo.log'))).Trim() -ne 'OUT') {throw 'stdout perdido.'}
                    if (([IO.File]::ReadAllText((Join-Path $Directory 'stderr.log'))).Trim() -ne 'ERR') {throw 'stderr perdido ou misturado.'}
                } finally {if ($Process) {$Process.Dispose()}}
            }
        }
    }
    $Passed=$true
    Write-Host 'Guard: saidas 0/7/3010, processo rapido/lento, Refresh e logs separados: OK'
} finally {
    if ($Passed) {Remove-Item -LiteralPath $Temp -Recurse -Force}
    else {Write-Host "Diagnostico preservado: $Temp"}
}
