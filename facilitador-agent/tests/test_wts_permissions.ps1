#Requires -Version 5.1
# Executar no Windows: testa o bloco remoto real com CIM simulado, sem modificar ACLs.
$ErrorActionPreference='Stop'
$Path=Join-Path (Split-Path $PSScriptRoot) 'permitir-consulta-sessoes.ps1'
$Tokens=$null;$Errors=$null
$Ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$Tokens,[ref]$Errors)
if ($Errors.Count) {throw 'Falha no parser PowerShell.'}
$Command=$Ast.Find({param($Node) $Node -is [Management.Automation.Language.CommandAst] -and $Node.GetCommandName() -eq 'Invoke-Command'},$true)
$Expression=$Command.CommandElements | Where-Object {$_ -is [Management.Automation.Language.ScriptBlockExpressionAst]} | Select-Object -Last 1
$Remote=$Expression.ScriptBlock.GetScriptBlock()
$Sid=[Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
$Account=$Sid.Translate([Security.Principal.NTAccount]).Value
function Get-CimInstance {
    param($Namespace,$ClassName,$Filter)
    if ($Filter -notmatch "TerminalName='(Console|RDP-Tcp)'") {throw 'Filtro inesperado.'}
    [pscustomobject]@{TerminalName=$Matches[1];StringSecurityDescriptor=$script:Descriptor;DenyAdminPermissionForCustomization=0}
}
function Set-CimInstance {throw 'Teste somente leitura tentou gravar.'}
function Export-Clixml {throw 'Teste somente leitura tentou criar backup.'}
# Flags AceFlags sem herança: regressão da conversão enum/bitwise no PowerShell 5.1.
$script:Descriptor='O:SYG:SYD:(A;;0xf03bf;;;SY)(A;;0xf03bf;;;BA)'
$Rows=@(& $Remote $Account $false)
if ($Rows.Count -ne 2 -or @($Rows | Where-Object {-not $_.ChangeNeeded -or $_.Applied}).Count) {throw 'Prévia sem ACE não produziu os dois planos.'}
# ACE de consulta já presente deve dispensar nova concessão (ramo InheritOnly).
$script:Descriptor='O:SYG:SYD:(A;;0xf03bf;;;SY)(A;;0xf03bf;;;BA)(A;;CC;;;BU)'
$Rows=@(& $Remote $Account $false)
if ($Rows.Count -ne 2 -or @($Rows | Where-Object {$_.ChangeNeeded -or $_.Applied}).Count) {throw 'ACE existente não foi reconhecida.'}
'WTS permission preview: OK (sem escrita)'
