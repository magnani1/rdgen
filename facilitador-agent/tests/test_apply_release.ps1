#Requires -Version 7.0
$ErrorActionPreference='Stop'
$Script=Join-Path $PSScriptRoot '..\aplicar-atualizacao.ps1'
$State=@{Pulls=0;Signs=0;Arguments=@();Copy=@()}
$Fixture=Join-Path $env:TEMP ('release-entry-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Fixture | Out-Null
function Get-AuthenticodeSignature {param($LiteralPath) [pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Thumbprint=('B'*40)}}}
function git {
    $Arguments=@($args)
    $global:LASTEXITCODE=0
    if($Arguments -contains 'branch') {'master'}
    elseif($Arguments -contains 'pull') {$State.Pulls++}
}
function Get-Item {param($Path,$ErrorAction) [pscustomobject]@{HasPrivateKey=$true;NotAfter=(Get-Date).AddDays(30)}}
function Set-AuthenticodeSignature {param($FilePath,$Certificate,$HashAlgorithm) $State.Signs++;$State.Copy+=@($FilePath);[pscustomobject]@{Status='Valid'}}
function Invoke-FixturePython {
    $State.Arguments=@($args);$global:LASTEXITCODE=0
}
try {
    & $Script -CertificateThumbprint ('A'*40) -Python Invoke-FixturePython -CheckOnly
    if($State.Pulls -or $State.Signs -or $State.Arguments -notcontains '--check-only') {throw 'CheckOnlyChangedFilesOrSigned'}
    & $Script -CertificateThumbprint ('A'*40) -Python Invoke-FixturePython
    if($State.Pulls -ne 1 -or $State.Signs -ne 1 -or $State.Arguments -contains '--check-only') {throw 'ReleaseStepsMissing'}
    $ActualSource=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\preparar-iot-ldap-214.ps1'))
    if([IO.Path]::GetFullPath($State.Copy[0]) -eq $ActualSource) {throw 'SignedTrackedGitSource'}
    if($State.Arguments -notcontains '--backend-ssh' -or $State.Arguments -notcontains '--repo') {throw 'MissingOrchestrationArguments'}
    $Private=Join-Path $Fixture 'aplicar-atualizacao.ps1'
    Copy-Item -LiteralPath $Script -Destination $Private
    $Repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    & $Private -Repo $Repo -SomenteAgentes -Python Invoke-FixturePython -CheckOnly
    if($State.Arguments -contains '--backend-ssh' -or $State.Pulls -ne 1 -or $State.Signs -ne 1) {throw 'OnlyAgentsStartedBackendOrChangedCheckout'}
    $CertificateIndex=[Array]::IndexOf($State.Arguments,'--certificate')
    if($State.Arguments[$CertificateIndex+1] -ne ('B'*40)) {throw 'WrongEntrySignerCertificate'}
    if(-not (Test-Path -LiteralPath $State.Arguments[0]) -or $State.Arguments[0] -ne (Join-Path (Join-Path $Repo 'facilitador-agent') 'atualizar-frota.py')) {throw 'PrivateEntryDidNotUseExplicitCheckout'}
    & $Private -Repo $Repo -SomenteAgentes -Python Invoke-FixturePython
    if($State.Arguments -contains '--backend-ssh' -or -not (Test-Path -LiteralPath $State.Arguments[0])) {throw 'PrivateEntryDidNotCopyCheckoutSources'}
    & $Private -Repo $Repo -BackendSSH '' -Python Invoke-FixturePython -CheckOnly
    if($State.Arguments -contains '--backend-ssh' -or $State.Arguments -contains '') {throw 'EmptyNativeArgumentNotOmitted'}
    Write-Host 'Aplicador: check-only sem escrita, Git ff-only, assinatura em copia privada e encaminhamento ao orquestrador: OK'
} finally {
    Remove-Item -LiteralPath $Fixture -Recurse -Force
    foreach($File in $State.Copy) {
        $Work=Split-Path (Split-Path $File -Parent) -Parent
        if((Split-Path $Work -Leaf) -like 'facilitador-release-*') {Microsoft.PowerShell.Management\Remove-Item -LiteralPath $Work -Recurse -Force}
    }
}
