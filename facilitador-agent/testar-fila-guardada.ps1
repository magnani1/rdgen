#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9.-]{0,252}$')][string]$ComputerName,
    [string]$Repo='\\facilitadorapp1\c$\Magbel\rdgen',
    [string]$Worker='\\facilitador.tjpb.jus.br\facilitador_storage$\Scripts\Variaveis\Executar-WinRM.ps1',
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{40}$')][string]$CertificateThumbprint,
    [switch]$ConfirmarDestinoSemInstalacoes
)
$ErrorActionPreference='Stop'
function Save-HmlDiagnostics {
    param([Parameter(Mandatory)][object[]]$Jobs,[Parameter(Mandatory)][string]$Root)
    $Report=@(foreach ($Job in $Jobs) {
        $ReadErrors=@()
        $Output=@(Receive-Job -Job $Job -Keep -ErrorAction SilentlyContinue -ErrorVariable ReadErrors)
        $Errors=@($Job.Error)+@($ReadErrors)+@(foreach ($Child in $Job.ChildJobs) {$Child.Error})
        $Reason=if ($Job.JobStateInfo.Reason) {$Job.JobStateInfo.Reason.Message} else {''}
        $StreamFile=Join-Path $Root ($Job.Id.ToString()+'-job.txt')
        $Output | Out-String -Width 240 | Set-Content -LiteralPath $StreamFile -Encoding UTF8
        if ($Reason) {Add-Content -LiteralPath $StreamFile -Value ('Reason: '+$Reason) -Encoding UTF8}
        foreach ($ErrorRecord in $Errors) {
            if ($ErrorRecord) {Add-Content -LiteralPath $StreamFile -Value ($ErrorRecord | Out-String -Width 240) -Encoding UTF8}
        }
        [pscustomobject]@{
            Id=$Job.Id;Name=$Job.Name;State=[string]$Job.State;Reason=$Reason
            Errors=@($Errors | Where-Object {$null -ne $_} | ForEach-Object { [string]$_ })
            ErrorCount=@($Errors | Where-Object {$null -ne $_}).Count
            StreamFile=$StreamFile
        }
    })
    ConvertTo-Json -InputObject $Report -Depth 5 | Set-Content -LiteralPath (Join-Path $Root 'job-status.json') -Encoding UTF8
    return $Report
}
if (-not $ConfirmarDestinoSemInstalacoes) {throw 'Confira ausencia de instalacoes/tarefas anteriores no cliente de homologacao.'}
if ((Get-AuthenticodeSignature -LiteralPath $PSCommandPath).Status -ne 'Valid') {throw 'Assine a copia deste teste antes de executar.'}
if ((Get-AuthenticodeSignature -LiteralPath $Worker).Status -ne 'Valid') {throw 'Worker institucional sem assinatura valida.'}
$Certificate=$null
foreach ($Store in @('Cert:\CurrentUser\My','Cert:\LocalMachine\My')) {
    $Candidate=Get-Item "$Store\$CertificateThumbprint" -ErrorAction SilentlyContinue
    if ($Candidate -and $Candidate.HasPrivateKey) {$Certificate=$Candidate;break}
}
if (-not $Certificate) {throw 'Certificado com chave privada nao encontrado nesta estacao.'}
$Root=Join-Path $env:ProgramData ('Magbel\HomologacaoFila\'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Root -Force | Out-Null
Write-Host "Logs do aceite: $Root"
$Jobs=@()
foreach ($Name in @('A','B')) {
    $Script=Join-Path $Root ('Teste-Fila-'+$Name+'.ps1')
    Copy-Item -LiteralPath (Join-Path $Repo ('facilitador-agent\homologacao\Teste-Fila-'+$Name+'.ps1')) -Destination $Script
    if ((Set-AuthenticodeSignature -FilePath $Script -Certificate $Certificate -HashAlgorithm SHA256).Status -ne 'Valid') {throw 'Assinatura da acao inofensiva nao validada.'}
    $Log=Join-Path $Root ($Name+'.log')
    $Jobs+=Start-Job -Name ('Magbel-Aceite-'+$Name+'-'+[IO.Path]::GetFileName($Root)) -ArgumentList $Worker,$ComputerName,$Script,$Log,$Name -ScriptBlock {
        param($Worker,$Target,$Script,$Log,$Name)
        & $Worker -ComputerName $Target -FilePath $Script -LogFile $Log -Programa ('TESTE_FILA_'+$Name) -TimeoutSeconds 120
        if ($LASTEXITCODE -ne 0) {throw "Worker $Name sem sucesso confirmado."}
    }
}
$Watch=[Diagnostics.Stopwatch]::StartNew();$NextNotice=0
while (@($Jobs | Where-Object State -in @('Running','NotStarted')).Count -and $Watch.Elapsed.TotalSeconds -lt 150) {
    if ($Watch.Elapsed.TotalSeconds -ge $NextNotice) {
        Write-Host ('[ACEITE] '+(@($Jobs | ForEach-Object {$_.Name+': '+$_.State}) -join ' | '))
        $NextNotice=$Watch.Elapsed.TotalSeconds+15
    }
    Start-Sleep -Seconds 2
}
$JobReport=@(Save-HmlDiagnostics -Jobs $Jobs -Root $Root)
if (@($JobReport | Where-Object {$_.State -ne 'Completed' -or $_.ErrorCount -gt 0}).Count) {
    $JobReport | Format-List Name,State,Reason,Errors,StreamFile | Out-Host
    Write-Host "Relatorio persistido: $Root\job-status.json"
    throw 'Teste sem confirmacao. Erros dos jobs foram preservados. Nenhuma tarefa/processo remoto foi encerrado; confira logs e o cliente antes de repetir.'
}
$Jobs | Receive-Job -ErrorAction Stop | Out-Host
$Ranges=@{}
foreach ($Name in @('A','B')) {
    $Text=Get-Content -LiteralPath (Join-Path $Root ($Name+'.log')) -Raw -Encoding UTF8
    $Other=if ($Name -eq 'A') {'B'} else {'A'}
    if ($Text -match ('TESTE_'+$Other+'_')) {throw 'Log de uma acao apareceu no acompanhamento da outra.'}
    $Start=[regex]::Match($Text,('TESTE_'+$Name+'_INICIO (\S+)'))
    $End=[regex]::Match($Text,('TESTE_'+$Name+'_FIM (\S+)'))
    if (-not $Start.Success -or -not $End.Success) {throw 'Inicio/fim da acao nao confirmado; confira logs.'}
    $Ranges[$Name]=@([DateTimeOffset]::Parse($Start.Groups[1].Value),[DateTimeOffset]::Parse($End.Groups[1].Value))
}
if (-not ($Ranges.A[1] -le $Ranges.B[0] -or $Ranges.B[1] -le $Ranges.A[0])) {throw 'Intervalos das tarefas se sobrepuseram.'}
$Jobs | Remove-Job
[pscustomobject]@{Computer=$ComputerName;Serialized=$true;LogsIsolated=$true;InstallersExecuted=$false;Logs=$Root}
