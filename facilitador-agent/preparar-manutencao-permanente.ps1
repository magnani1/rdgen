#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$SourceRoot,[Parameter(Mandatory)][string]$Destination,[Parameter(Mandatory)][string]$CertificateThumbprint)
$ErrorActionPreference='Stop'
$SourceRoot=(Resolve-Path -LiteralPath $SourceRoot).ProviderPath
$Destination=[IO.Path]::GetFullPath($Destination)
if ((Test-Path -LiteralPath $Destination) -or $Destination.StartsWith(([IO.Path]::GetFullPath((Join-Path $SourceRoot '..')).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)) {throw 'Use uma pasta nova fora do checkout.'}
$Certificate=$null
foreach ($Store in @('Cert:\CurrentUser\My','Cert:\LocalMachine\My')) {
    $Item=Get-Item "$Store\$CertificateThumbprint" -ErrorAction SilentlyContinue
    if ($Item -and $Item.HasPrivateKey) {$Certificate=$Item;break}
}
if (-not $Certificate) {throw 'Chave privada não encontrada na estação de assinatura; não a exporte.'}
foreach ($Name in @('instalar-manutencao-permanente.ps1','instalar-manutencao-remota.ps1','manutencao-agente.ps1','atualizar-manutencao-permanente.ps1')) {
    $Tokens=$null;$Errors=$null
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot $Name),[ref]$Tokens,[ref]$Errors) | Out-Null
    if ($Errors.Count) {throw "Sintaxe inválida: $Name"}
}
New-Item -ItemType Directory -Path (Split-Path $Destination -Parent) -Force | Out-Null
New-Item -ItemType Directory -Path $Destination | Out-Null
$Names=@('permanent_maintenance.py','maintenance_controller.py','fleet_manager.py','setup_assistant.py','facilitador-agent.py','manutencao-agente.ps1','requirements.txt')
foreach ($Name in $Names) {Copy-Item -LiteralPath (Join-Path $SourceRoot $Name) -Destination $Destination}
$Signature=Set-AuthenticodeSignature -FilePath (Join-Path $Destination 'manutencao-agente.ps1') -Certificate $Certificate -HashAlgorithm SHA256
if ($Signature.Status -ne 'Valid') {throw 'Assinatura do helper não validada.'}
$Hashes=@{}
foreach ($Name in $Names) {$Hashes[$Name]=(Get-FileHash -LiteralPath (Join-Path $Destination $Name) -Algorithm SHA256).Hash}
$Encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Hashes | ConvertTo-Json -Compress)))
$Installer=Get-Content -LiteralPath (Join-Path $SourceRoot 'instalar-manutencao-permanente.ps1') -Raw -Encoding UTF8
$Installer=$Installer.Replace("`$PackageHashesBase64='__MAGBEL_SERVICE_HASHES__'","`$PackageHashesBase64='$Encoded'")
$Target=Join-Path $Destination 'instalar-manutencao-permanente.ps1'
$Installer | Set-Content -LiteralPath $Target -Encoding utf8BOM
$Signature=Set-AuthenticodeSignature -FilePath $Target -Certificate $Certificate -HashAlgorithm SHA256
if ($Signature.Status -ne 'Valid') {throw 'Assinatura do instalador não validada.'}
$Remote=Join-Path $Destination 'instalar-manutencao-remota.ps1'
Copy-Item -LiteralPath (Join-Path $SourceRoot 'instalar-manutencao-remota.ps1') -Destination $Remote
$Signature=Set-AuthenticodeSignature -FilePath $Remote -Certificate $Certificate -HashAlgorithm SHA256
if ($Signature.Status -ne 'Valid') {throw 'Assinatura do instalador remoto não validada.'}
$Updater=Get-Content -LiteralPath (Join-Path $SourceRoot 'atualizar-manutencao-permanente.ps1') -Raw -Encoding UTF8
$Updater=$Updater.Replace("`$PackageHashesBase64='__MAGBEL_SERVICE_HASHES__'","`$PackageHashesBase64='$Encoded'")
$TargetUpdater=Join-Path $Destination 'atualizar-manutencao-permanente.ps1'
$Updater | Set-Content -LiteralPath $TargetUpdater -Encoding utf8BOM
$Signature=Set-AuthenticodeSignature -FilePath $TargetUpdater -Certificate $Certificate -HashAlgorithm SHA256
if ($Signature.Status -ne 'Valid') {throw 'Assinatura do atualizador não validada.'}
Write-Host "Pacote permanente assinado: $Destination"
