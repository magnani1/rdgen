#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CertificateThumbprint,
    [Parameter(Mandatory)][string]$Destination,
    [string]$AssistantExe = ''
)
$ErrorActionPreference = 'Stop'
$PackageSource = $PSScriptRoot
$Destination = [IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $Destination) { throw 'Destino já existe. Escolha uma pasta nova fora do checkout.' }
$SourcePrefix = [IO.Path]::GetFullPath((Join-Path $PackageSource '..')).TrimEnd('\') + '\'
if ($Destination.StartsWith($SourcePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'O pacote assinado deve ficar fora do checkout.' }
$Certificate = $null
foreach ($Store in @('Cert:\CurrentUser\My','Cert:\LocalMachine\My')) {
    $Candidate = Get-Item "$Store\$CertificateThumbprint" -ErrorAction SilentlyContinue
    if ($Candidate -and $Candidate.HasPrivateKey) { $Certificate = $Candidate; break }
}
if (-not $Certificate) { throw 'Execute na estação de assinatura com o certificado e sua chave privada. Não exporte a chave para os APPs.' }
$Tokens=$null; $ParseErrors=$null
$Ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PackageSource 'instalar-agente.ps1'),[ref]$Tokens,[ref]$ParseErrors)
if ($ParseErrors.Count) { throw 'Sintaxe inválida no instalador.' }
$Function=$Ast.Find({param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Get-AgentLauncher'},$true)
if (-not $Function) { throw 'Template do launcher não encontrado.' }
. ([scriptblock]::Create($Function.Extent.Text))
New-Item -ItemType Directory -Path $Destination | Out-Null
# Lista explícita: não copia identidade, configuração, venv ou segredos.
foreach ($File in @('instalar-agente.ps1','facilitador-agent.py','requirements.txt','README.md','INSTALACAO-DO-ZERO.md','ASSISTENTE-EXE.md')) {
    Copy-Item -LiteralPath (Join-Path $PackageSource $File) -Destination $Destination
}
Get-AgentLauncher | Set-Content (Join-Path $Destination 'run-agent.ps1') -Encoding utf8BOM
foreach ($File in @('instalar-agente.ps1','run-agent.ps1')) {
    $Signature=Set-AuthenticodeSignature -FilePath (Join-Path $Destination $File) -Certificate $Certificate -HashAlgorithm SHA256
    if ($Signature.Status -ne 'Valid') { throw "Assinatura inválida de ${File}: $($Signature.Status). Não distribuir este pacote." }
}
if ($AssistantExe) {
    $ExeDestination=Join-Path $Destination 'Magbel-Facilitador-Setup.exe'
    Copy-Item -LiteralPath $AssistantExe -Destination $ExeDestination
    $Signature=Set-AuthenticodeSignature -FilePath $ExeDestination -Certificate $Certificate -HashAlgorithm SHA256
    if ($Signature.Status -ne 'Valid') { throw 'Assinatura inválida do EXE. Não distribuir este pacote.' }
}
$Manifest=Get-ChildItem -LiteralPath $Destination -File | Sort-Object Name | ForEach-Object {
    @{file=$_.Name; sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
}
$Manifest | ConvertTo-Json | Set-Content (Join-Path $Destination 'SHA256.json') -Encoding utf8
Write-Host "Pacote preparado: $Destination"
Write-Host 'Distribua a pasta inteira pelo canal institucional. A chave privada permaneceu na estação de assinatura.'
Write-Host 'SHA256.json detecta alterações de transporte; não substitui a assinatura nem a confiança no canal de distribuição.'
