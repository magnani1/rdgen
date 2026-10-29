#Requires -Version 7.0
#Requires -RunAsAdministrator
<# Executar na estação de assinatura. Publica worker assinado e atualiza o pacote do conector.
Os executores são atualizados pelo painel, um por vez, com drenagem e backup.
#>
[CmdletBinding()]
param(
    [string]$Repo='\\facilitadorapp1\c$\Magbel\rdgen',
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{40}$')][string]$CertificateThumbprint,
    [string]$ComputerName='facilitadorapp4.tjpb.jus.br',
    [string]$ServiceId='manutencao-tjpb-app4',
    [string]$WorkerTarget='\\facilitador.tjpb.jus.br\facilitador_storage$\Scripts\Variaveis\Executar-WinRM.ps1',
    [switch]$ConfirmarSemManutencaoAberta,
    [switch]$ConfirmarSemTrabalhos
)
$ErrorActionPreference='Stop'
if ((Get-AuthenticodeSignature -LiteralPath $PSCommandPath).Status -ne 'Valid') {throw 'Assine esta cópia na estação institucional antes de executar.'}
if (-not $ConfirmarSemManutencaoAberta) {throw 'Confira no painel que não há atualização aberta e informe -ConfirmarSemManutencaoAberta.'}
if (-not $ConfirmarSemTrabalhos) {throw 'Drene os executores e confira zero trabalhos; o worker é compartilhado. Informe -ConfirmarSemTrabalhos somente após conferir.'}
if ($ComputerName -notmatch '^[a-zA-Z][a-zA-Z0-9.-]{0,252}$' -or $ServiceId -notmatch '^[a-z][a-z0-9-]{0,63}$') {throw 'Destino/serviço inválido.'}
$Certificate=$null
foreach ($Store in @('Cert:\CurrentUser\My','Cert:\LocalMachine\My')) {
    $Item=Get-Item "$Store\$CertificateThumbprint" -ErrorAction SilentlyContinue
    if ($Item -and $Item.HasPrivateKey) {$Certificate=$Item;break}
}
if (-not $Certificate) {throw 'Chave privada não encontrada nesta estação; não exportar para os APPs.'}
if (-not (Test-Path -LiteralPath (Join-Path $Repo '.git'))) {throw 'Checkout Git não encontrado.'}
& git -C $Repo pull --ff-only
if ($LASTEXITCODE -ne 0) {throw 'Git interrompido; alterações locais não serão descartadas.'}
$Stamp=(Get-Date -Format 'yyyyMMddTHHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
$Work=Join-Path $env:LOCALAPPDATA ('Temp\magbel-monitoramento-208-'+$Stamp)
$Source=Join-Path $Work 'source'
$Package=Join-Path $env:ProgramData ('Magbel\Pacotes\manutencao-monitoramento-208-'+$Stamp)
New-Item -ItemType Directory -Path $Work | Out-Null
Copy-Item -LiteralPath (Join-Path $Repo 'facilitador-agent') -Destination $Source -Recurse
$Text=[IO.File]::ReadAllText((Join-Path $Source 'facilitador-agent.py')).Replace("`r`n","`n").TrimEnd([char[]]"`r`n")+"`n"
$Hasher=[Security.Cryptography.SHA256]::Create()
try {$Hash=[BitConverter]::ToString($Hasher.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($Text))).Replace('-','').ToLowerInvariant()} finally {$Hasher.Dispose()}
if ($Hash -ne 'e981aedb4db1a6cbfbcfc1e0c64f049d24d9591142ea4fae08f80be947d884ab') {throw 'Esta preparação exige o agente 2.0.8 revisado; confira o commit do checkout.'}
$Prepare=Join-Path $Source 'preparar-manutencao-permanente.ps1'
$Signature=Set-AuthenticodeSignature -FilePath $Prepare -Certificate $Certificate -HashAlgorithm SHA256
if ($Signature.Status -ne 'Valid') {throw 'Assinatura do preparador não validada.'}
& $Prepare -SourceRoot $Source -Destination $Package -CertificateThumbprint $CertificateThumbprint
if (-not (Test-Path -LiteralPath (Join-Path $Package 'atualizar-manutencao-permanente.ps1'))) {throw 'Pacote não foi concluído.'}
# Publica a cópia assinada fora do checkout e preserva o worker institucional.
# Executar-TarefaLocal.ps1 continua junto ao worker no compartilhamento.
$Worker=Join-Path $Source 'worker\Executar-WinRM.ps1'
$Tokens=$null; $ParseErrors=$null
$null=[Management.Automation.Language.Parser]::ParseFile($Worker,[ref]$Tokens,[ref]$ParseErrors)
if ($ParseErrors.Count) {throw 'Worker não passou no parser PowerShell; publicação interrompida.'}
if (-not (Test-Path -LiteralPath $WorkerTarget -PathType Leaf)) {throw 'Worker institucional existente não encontrado.'}
if (-not (Test-Path -LiteralPath (Join-Path (Split-Path $WorkerTarget) 'Executar-TarefaLocal.ps1'))) {throw 'Runner institucional não encontrado junto ao worker.'}
$Signature=Set-AuthenticodeSignature -FilePath $Worker -Certificate $Certificate -HashAlgorithm SHA256
if ($Signature.Status -ne 'Valid') {throw 'Assinatura do worker não validada.'}
$WorkerBackup=Join-Path (Split-Path $WorkerTarget) ('Executar-WinRM-before-208-'+$Stamp+'.ps1.bak')
$Pending=$WorkerTarget+'.'+$Stamp+'.pending.ps1'
try {
    $BeforeWorker=(Get-FileHash -LiteralPath $WorkerTarget -Algorithm SHA256).Hash
    Copy-Item -LiteralPath $WorkerTarget -Destination $WorkerBackup
    Copy-Item -LiteralPath $Worker -Destination $Pending
    $Copied=Get-AuthenticodeSignature -LiteralPath $Pending
    if ($Copied.Status -ne 'Valid' -or $Copied.SignerCertificate.Thumbprint -ne $CertificateThumbprint) {throw 'Assinatura divergente após transporte.'}
    if ((Get-FileHash -LiteralPath $Worker -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $Pending -Algorithm SHA256).Hash) {throw 'Hash do worker divergente após transporte.'}
    if ((Get-FileHash -LiteralPath $WorkerTarget -Algorithm SHA256).Hash -ne $BeforeWorker) {throw 'Worker institucional mudou durante o preparo; publicação cancelada.'}
    Move-Item -LiteralPath $Pending -Destination $WorkerTarget -Force
    if ((Get-FileHash -LiteralPath $Worker -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $WorkerTarget -Algorithm SHA256).Hash) {throw 'Worker publicado divergente; confira o backup antes de continuar.'}
} finally {
    if (Test-Path -LiteralPath $Pending) {Remove-Item -LiteralPath $Pending -Force}
}
Write-Host "Worker publicado. Backup: $WorkerBackup"
# Só a tarefa de manutenção é parada. Nenhum executor ou processo Python genérico.
Invoke-Command -ComputerName $ComputerName -Authentication Kerberos -ConfigurationName Microsoft.PowerShell -ArgumentList $ServiceId -ScriptBlock {
    param($Id)
    $ErrorActionPreference='Stop'
    $TaskName='Magbel-Manutencao-'+$Id
    Stop-ScheduledTask -TaskName $TaskName
    $Limit=(Get-Date).AddSeconds(30)
    do {
        $State=[string](Get-ScheduledTask -TaskName $TaskName).State
        if ($State -eq 'Ready') {break}
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $Limit)
    if ($State -ne 'Ready') {throw 'Tarefa de manutenção não ficou Ready; nenhuma troca autorizada.'}
}
& (Join-Path $Package 'atualizar-manutencao-permanente.ps1') -ComputerName $ComputerName -ServiceId $ServiceId
Write-Host "Pacote preservado: $Package"
Write-Host 'Confira contato e pacote 2.0.8 no painel. Atualize primeiro um executor e valide no cliente de teste.'
