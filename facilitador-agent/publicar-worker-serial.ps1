#Requires -Version 7.0
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$Repo='\\facilitadorapp1\c$\Magbel\rdgen',
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{40}$')][string]$CertificateThumbprint,
    [string]$Directory='\\facilitador.tjpb.jus.br\facilitador_storage$\Scripts\Variaveis',
    [switch]$ConfirmarSemTrabalhos
)
$ErrorActionPreference='Stop'
if ((Get-AuthenticodeSignature -LiteralPath $PSCommandPath).Status -ne 'Valid') {throw 'Assine esta copia do publicador na estacao institucional.'}
if (-not $ConfirmarSemTrabalhos) {throw 'Drene os agentes, aguarde tarefas/instaladores terminarem e confira zero trabalhos antes de publicar.'}
$Certificate=$null
foreach ($Store in @('Cert:\CurrentUser\My','Cert:\LocalMachine\My')) {
    $Item=Get-Item "$Store\$CertificateThumbprint" -ErrorAction SilentlyContinue
    if ($Item -and $Item.HasPrivateKey) {$Certificate=$Item;break}
}
if (-not $Certificate) {throw 'Certificado com chave privada nao encontrado nesta estacao.'}
if (-not (Test-Path -LiteralPath (Join-Path $Directory 'Executar-TarefaLocal.ps1'))) {throw 'Runner institucional ausente.'}
$Stamp=(Get-Date -Format yyyyMMddTHHmmss)+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
$Work=Join-Path $env:ProgramData ('Magbel\Pacotes\worker-serial-'+$Stamp)
New-Item -ItemType Directory -Path $Work -Force | Out-Null
# Publicar guard antes do worker: o worker anterior ignora o novo arquivo.
foreach ($Name in @('Executar-Guardado.ps1','Executar-WinRM.ps1')) {
    $Source=Join-Path $Repo ('facilitador-agent\worker\'+$Name)
    $Copy=Join-Path $Work $Name
    Copy-Item -LiteralPath $Source -Destination $Copy
    $Tokens=$null; $Errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($Copy,[ref]$Tokens,[ref]$Errors)
    if ($Errors.Count) {throw "Parser recusou $Name; nenhum arquivo desse passo foi publicado."}
    $Signature=Set-AuthenticodeSignature -FilePath $Copy -Certificate $Certificate -HashAlgorithm SHA256
    if ($Signature.Status -ne 'Valid') {throw "Assinatura nao validada: $Name"}
    $Target=Join-Path $Directory $Name
    $Before=if (Test-Path -LiteralPath $Target) {(Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash} else {$null}
    if ($Before) {Copy-Item -LiteralPath $Target -Destination (Join-Path $Work ($Name+'.before'))}
    $Pending=$Target+'.'+$Stamp+'.pending.ps1'
    try {
        Copy-Item -LiteralPath $Copy -Destination $Pending
        $Sig=Get-AuthenticodeSignature -LiteralPath $Pending
        if ($Sig.Status -ne 'Valid' -or $Sig.SignerCertificate.Thumbprint -ne $CertificateThumbprint) {throw 'Assinatura divergente apos transporte.'}
        $Hash=(Get-FileHash -LiteralPath $Copy -Algorithm SHA256).Hash
        if ((Get-FileHash -LiteralPath $Pending -Algorithm SHA256).Hash -ne $Hash) {throw 'Hash divergente apos transporte.'}
        $Current=if (Test-Path -LiteralPath $Target) {(Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash} else {$null}
        if ($Current -ne $Before) {throw 'Destino mudou durante a publicacao; interrompido.'}
        Move-Item -LiteralPath $Pending -Destination $Target -Force
        if ((Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash -ne $Hash) {throw 'Hash publicado divergente; confira backup antes de continuar.'}
    } finally {if (Test-Path -LiteralPath $Pending) {Remove-Item -LiteralPath $Pending -Force}}
    Write-Host "Publicado: $Target"
}
Write-Host "Pacote assinado e backups: $Work"
Write-Host 'Agente permanece 2.0.8; nao e necessario reiniciar tarefa, trocar Python ou reinscrever. Teste dois scripts inofensivos no mesmo destino antes de usar instaladores.'
