#Requires -Version 7.0
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{40}$')][string]$CertificateThumbprint,
    [string]$BackendSSH='dietpi@lenovo',
    [string]$BackendDir='/dados_servidor/facilitador-core',
    [string[]]$Agents=@('facilitadorapp1','facilitadorapp2','facilitadorapp3','facilitadorapp4'),
    [string]$Python='python',
    [switch]$CheckOnly
)
$ErrorActionPreference='Stop'
$Repo=Split-Path $PSScriptRoot -Parent
if ($Repo.StartsWith('\\')) {throw 'Execute pelo checkout local na estação institucional; não execute Git pelo SMB.'}
$Branch=(& git -C $Repo branch --show-current)
if ($LASTEXITCODE -or $Branch -ne 'master') {throw 'Use o checkout master revisado do rdgen.'}
$Changes=& git -C $Repo status --porcelain --untracked-files=no
if ($LASTEXITCODE -or $Changes) {throw 'Há alterações rastreadas locais; preserve-as antes de atualizar.'}
# CheckOnly não modifica nem o checkout.
if (-not $CheckOnly) {
    & git -C $Repo pull --ff-only
    if ($LASTEXITCODE) {throw 'Git pull falhou; nenhum deploy iniciado.'}
}
$Certificate=$null
foreach ($Store in @('Cert:\CurrentUser\My','Cert:\LocalMachine\My')) {
    $Found=Get-Item "$Store\$CertificateThumbprint" -ErrorAction SilentlyContinue
    if ($Found -and $Found.HasPrivateKey -and $Found.NotAfter -gt (Get-Date)) {$Certificate=$Found;break}
}
if (-not $Certificate) {throw 'Certificado válido com chave privada não encontrado nesta estação.'}
$RunRoot=$PSScriptRoot
if (-not $CheckOnly) {
    $Work=Join-Path $env:LOCALAPPDATA ('Temp\facilitador-release-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $Work | Out-Null
    $RunRoot=Join-Path $Work 'facilitador-agent'
    Copy-Item -LiteralPath $PSScriptRoot -Destination $RunRoot -Recurse
    $Signed=Set-AuthenticodeSignature -FilePath (Join-Path $RunRoot 'preparar-iot-ldap-214.ps1') -Certificate $Certificate -HashAlgorithm SHA256
    if ($Signed.Status -ne 'Valid') {throw 'A assinatura do preparador não foi validada.'}
}
$Arguments=@((Join-Path $RunRoot 'atualizar-frota.py'),'--repo',$Repo,'--backend-ssh',$BackendSSH,'--backend-dir',$BackendDir,'--certificate',$CertificateThumbprint,'--agents')+$Agents
if ($CheckOnly) {$Arguments+='--check-only'}
& $Python @Arguments
if ($LASTEXITCODE) {throw 'Entrega interrompida. Confira o último resultado antes de repetir.'}
