$ErrorActionPreference = 'Stop'
$Installer = Join-Path $PSScriptRoot '..\instalar-agente.ps1'
$Tokens = $null; $ParseErrors = $null
$Ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $Installer), [ref]$Tokens, [ref]$ParseErrors)
if ($ParseErrors.Count) { throw ($ParseErrors | Out-String) }
# Carrega apenas as funções puras/testáveis, sem instalar tarefa nem alterar ACLs.
$Functions = $Ast.FindAll({param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst]}, $false)
foreach ($Function in $Functions) { . ([scriptblock]::Create($Function.Extent.Text)) }
foreach ($Case in @(@{major=3;minor=9;bits=64}, @{major=3;minor=14;bits=32})) {
    $Rejected = $false
    try { Assert-AgentPython $Case } catch { $Rejected = $true }
    if (-not $Rejected) { throw 'Python incompatível foi aceito.' }
}
$null = Get-AgentPython (Get-Command python).Source
$Password = ConvertTo-SecureString 'unit-test-only' -AsPlainText -Force
$Credential = [pscredential]::new('TEST\executor', $Password)
$script:Registration = $null
function Register-ScheduledTask {
    param($TaskName,$Action,$Trigger,$Settings,$User,$Password,$RunLevel,$Principal,[switch]$Force)
    $script:Registration = $PSBoundParameters
}
function New-ScheduledTaskPrincipal { param($UserId,$LogonType,$RunLevel); return @{UserId=$UserId;LogonType=$LogonType;RunLevel=$RunLevel} }
Register-AgentTask -Registration @{TaskName='test';Action='test';Force=$true} -Credential $Credential
if ($script:Registration.User -ne 'TEST\executor' -or $script:Registration.Password -ne 'unit-test-only' -or $script:Registration.ContainsKey('Principal')) { throw 'Conta de rede registrada incorretamente.' }
Register-AgentTask -Registration @{TaskName='test';Action='test';Force=$true}
if ($script:Registration.Principal.LogonType -ne 'ServiceAccount' -or $script:Registration.ContainsKey('Password')) { throw 'Compatibilidade SYSTEM incorreta.' }
# Executa launcher real em processo pwsh, com Python de teste; valida stdout Unicode e exit code.
$Temp = Join-Path ([IO.Path]::GetTempPath()) ('facilitador-installer-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $Temp | Out-Null
try {
    New-Item -ItemType Directory (Join-Path $Temp 'Logs') | Out-Null
    @{AGENT_PYTHON=(Get-Command python).Source;PYTHONUTF8='1'} | ConvertTo-Json | Set-Content (Join-Path $Temp 'config.json') -Encoding utf8
    "print('ação → versão ·'); raise SystemExit(7)" | Set-Content (Join-Path $Temp 'facilitador-agent.py') -Encoding utf8
    Get-AgentLauncher | Set-Content (Join-Path $Temp 'run-agent.ps1') -Encoding utf8BOM
    & (Get-Command pwsh).Source -NoProfile -File (Join-Path $Temp 'run-agent.ps1')
    if ($LASTEXITCODE -ne 7) { throw 'O launcher não propagou o código de saída do Python.' }
    $Content = Get-Content (Join-Path $Temp 'agent.log') -Raw -Encoding utf8
    if (-not $Content.Contains('ação → versão ·')) { throw 'Codificação dos logs foi corrompida.' }
    $Bytes = [IO.File]::ReadAllBytes((Join-Path $Temp 'agent.log'))
    if ($Bytes[0] -ne 239 -or $Bytes[1] -ne 187 -or $Bytes[2] -ne 191) { throw 'Log não possui BOM UTF-8 para leitores Windows legados.' }
    Write-Host 'Instalador: versão/arquitetura, conta de rede, SYSTEM, Unicode e exit code: OK'
} finally { Remove-Item $Temp -Recurse -Force }
# O processo Python propositalmente retornou 7; o teste terminou corretamente.
exit 0
