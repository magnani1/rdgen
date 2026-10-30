#Requires -Version 7.0
$ErrorActionPreference='Stop'
$File=Join-Path $PSScriptRoot '..\testar-fila-guardada.ps1'
$Tokens=$null;$Errors=$null
$Ast=[Management.Automation.Language.Parser]::ParseFile($File,[ref]$Tokens,[ref]$Errors)
if ($Errors.Count) {throw 'Parser recusou o teste de aceite.'}
$Definition=$Ast.Find({param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Save-HmlDiagnostics'},$true)
if (-not $Definition) {throw 'Coletor de diagnostico ausente.'}
. ([scriptblock]::Create($Definition.Extent.Text))
$Root=Join-Path ([IO.Path]::GetTempPath()) ('magbel-diag-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Root | Out-Null
$Jobs=@()
try {
    $Jobs+=Start-Job -ScriptBlock {throw 'falha-terminante-fixture'}
    $Jobs+=Start-Job -ScriptBlock {'saida-fixture';Write-Error 'falha-nao-terminante-fixture'}
    $Jobs+=Start-Job -ScriptBlock {'sucesso-fixture'}
    $Jobs | Wait-Job -Timeout 20 | Out-Null
    $Report=@(Save-HmlDiagnostics -Jobs $Jobs -Root $Root)
    if ($Report.Count -ne 3) {throw 'Quantidade de jobs incorreta.'}
    if (-not @($Report | Where-Object {$_.State -eq 'Failed' -and ($_.Reason -match 'fixture' -or $_.ErrorCount -gt 0)}).Count) {throw 'Falha terminante nao persistida.'}
    if (-not @($Report | Where-Object {$_.State -eq 'Completed' -and $_.ErrorCount -gt 0}).Count) {throw 'Erro nao terminante foi apresentado como sucesso.'}
    $Text=Get-Content -LiteralPath (Join-Path $Root 'job-status.json') -Raw -Encoding UTF8
    if ($Text -notmatch 'falha-nao-terminante-fixture') {throw 'Erro ausente no JSON.'}
    foreach ($Item in $Report) {if (-not (Test-Path -LiteralPath $Item.StreamFile)) {throw 'Arquivo de stream ausente.'}}
    if (@(Get-Job | Where-Object {$_.Id -in $Jobs.Id}).Count -ne 3) {throw 'Coleta removeu jobs.'}
    Write-Host 'Diagnostico preserva estados, falhas terminantes/nao terminantes e streams: OK'
} finally {
    # Apenas os jobs de fixture criados por este teste, sem WinRM nem tarefas remotas.
    foreach ($Job in $Jobs) {if ($Job.State -eq 'Running') {Stop-Job -Job $Job};Remove-Job -Job $Job -Force}
    Remove-Item -LiteralPath $Root -Recurse -Force
}
