#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Destination,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{40}$')][string]$CertificateThumbprint
)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $Destination) { throw 'Use uma pasta de destino nova.' }
$Cert = Get-Item -LiteralPath "Cert:\CurrentUser\My\$CertificateThumbprint"
if (-not $Cert.HasPrivateKey -or $Cert.NotAfter -le (Get-Date) -or
    -not ($Cert.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.3')) {
    throw 'Certificado de assinatura valido com chave privada exigido.'
}
$Compiler = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $Compiler)) {
    $Compiler = Join-Path $env:windir 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
$Source = Join-Path $PSScriptRoot 'DS790WNInstall.cs'
$Manifest = Join-Path $PSScriptRoot 'DS790WNInstall.manifest'
New-Item -ItemType Directory -Path $Destination | Out-Null
$Output = Join-Path (Resolve-Path -LiteralPath $Destination).ProviderPath 'DS790WNInstall.exe'
& $Compiler /nologo /target:winexe /platform:anycpu /reference:System.Web.Extensions.dll "/win32manifest:$Manifest" "/out:$Output" $Source
if ($LASTEXITCODE -ne 0) { throw 'Compilacao falhou.' }
$Signature = Set-AuthenticodeSignature -FilePath $Output -Certificate $Cert -HashAlgorithm SHA256 -TimestampServer 'http://timestamp.digicert.com'
if ($Signature.Status -ne 'Valid') { throw "Assinatura nao validada: $($Signature.StatusMessage)" }
Copy-Item -LiteralPath $Source,$Manifest -Destination $Destination
@{
    version='2026.11.5.1'
    exe_sha256=(Get-FileHash -LiteralPath $Output -Algorithm SHA256).Hash.ToLowerInvariant()
    source_sha256=(Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash.ToLowerInvariant()
    manifest_sha256=(Get-FileHash -LiteralPath $Manifest -Algorithm SHA256).Hash.ToLowerInvariant()
    signer=$Signature.SignerCertificate.Thumbprint
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Destination 'launcher-proof.json') -Encoding UTF8
Write-Host "Compilado e assinado: $Output. Nenhum pacote foi publicado."
