#Requires -Version 7.0
$ErrorActionPreference='Stop'
$File=Join-Path $PSScriptRoot '..\worker\Executar-WinRM.ps1'
$Tokens=$null; $Errors=$null
$Ast=[Management.Automation.Language.Parser]::ParseFile($File,[ref]$Tokens,[ref]$Errors)
if ($Errors.Count) {throw 'Worker não passou no parser.'}
$Function=$Ast.Find({param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Mostrar-LinhaAnalista'},$true)
if (-not $Function) {throw 'Função de encaminhamento ausente.'}
# Só a função é carregada. Não abre sessão, copia scripts ou cria tarefas.
. ([scriptblock]::Create($Function.Extent.Text))
$Lines=[Collections.Generic.List[string]]::new()
function Write-Log([string]$Mensagem) {$Lines.Add($Mensagem)}
$Programa='KODAK1XX_LOCAL'
Mostrar-LinhaAnalista '[2026-10-29 09:47:41] Instalando o SmartTouch...'
Mostrar-LinhaAnalista 'SUCESSO: teste de outro fabricante'
Mostrar-LinhaAnalista '[ERRO] instalação recusada'
Mostrar-LinhaAnalista ''
if ($Lines.Count -ne 3 -or $Lines[0] -ne 'Instalando o SmartTouch...' -or $Lines[1] -ne 'SUCESSO: teste de outro fabricante' -or $Lines[2] -notlike '*instalação recusada*') {throw 'Mensagens genéricas foram descartadas ou rotuladas incorretamente.'}
Write-Host 'Worker: mensagens Kodak/genéricas e erros preservados, sem WinRM: OK'
