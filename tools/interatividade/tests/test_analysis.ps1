#Requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\analisar-scripts.ps1')
$Folder=Join-Path $env:TEMP ('magbel-analysis-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Folder|Out-Null
function Check($Condition,$Message){if(-not $Condition){throw $Message}}
function Analyze([string]$Text) {
    $File=Join-Path $Folder 'sample.ps1'
    [IO.File]::WriteAllText($File,$Text,[Text.UTF8Encoding]::new($false))
    Get-PS1Analysis -Path $File
}
try {
    $Simple=Analyze @'
param([Parameter(Mandatory)][ValidateSet('consultar','criar')][string]$Acao,[string]$Nome)
'@
    Check ($Simple.classification -eq 'parameterized_candidate') 'Parameterized script not recognized'
    Check ($Simple.parameters[0].mandatory) 'Mandatory flag lost'
    Check ($Simple.parameters[0].suggested_field.opcoes.Count -eq 2) 'ValidateSet lost'
    Check (-not $Simple.execution_enabled -and $Simple.requires_review) 'Analysis enabled execution'
    $Comment=Analyze @'
param([string]$Nome)
# Read-Host 'ignored'
$x='Get-Credential; Read-Host'
'@
    Check ($Comment.interaction_signals.Count -eq 0) 'Comment/string false positive'
    $Prompt=Analyze "param([string]`$Nome)`nRead-Host 'Pergunta'"
    Check ($Prompt.review_reasons -contains 'runtime_prompts_require_explicit_parameters_or_workflow') 'Prompt not recognized'
    $Gui=Analyze "param([string]`$Nome)`n`$form.ShowDialog()"
    Check ($Gui.review_reasons -contains 'gui_requires_headless_backend') 'GUI not recognized'
    $Marker=Join-Path $Folder 'MUST-NOT-EXIST'
    $Malicious=Analyze ("param([string]`$Nome = (Set-Content -LiteralPath '"+$Marker+"' -Value executed))`nSet-Content -LiteralPath '"+$Marker+"' -Value executed")
    Check (-not (Test-Path -LiteralPath $Marker)) 'Analysis executed script/default'
    $Secret=Analyze @'
param([string]$Password='DO-NOT-EXPORT',[string]$Payload,[switch]$Confirmar)
'@
    Check ($Secret.parameters[0].sensitive -and $Secret.parameters[0].requires_adapter) 'Secret not recognized'
    Check ($Secret.parameters[1].opaque -and $Secret.parameters[2].requires_adapter) 'Opaque/switch adapter missing'
    Check (($Secret|ConvertTo-Json -Depth 12) -notmatch 'DO-NOT-EXPORT') 'Secret default leaked'
    $Dynamic=Analyze 'param([string]$Nome); & $command; Invoke-Expression $code'
    Check ($Dynamic.review_reasons -contains 'dynamic_code_requires_review') 'Dynamic code not recognized'
    $Invalid=Analyze 'param([string]$Nome'
    Check (-not $Invalid.syntax_valid) 'Syntax error not recognized'
    $File=Join-Path $Folder 'sample.ps1'
    $Menu='{"Modulo_N2":[["Usuarios","",[["","Rotulo","","ps1","<BASE>\\N3\\sample.ps1"]]]],"Modulo_N3":[["Usuarios","",[["","Rotulo","","ps1","<BASE>\\N3\\sample.ps1"]]]]}'|ConvertFrom-Json
    $Found=Get-PS1Analysis -Path $File -Menu $Menu
    Check ($Found.menu_references.Count -eq 2) 'Shared menu references lost'
    Check (-not $Found.permission_inferred) 'Menu incorrectly inferred permission'
    Write-Host 'AST: params, Mandatory, ValidateSet, prompts, GUI, dynamic calls, syntax, no execution, no secret export and menu references: OK'
}
finally {Remove-Item -LiteralPath $Folder -Recurse -Force}
