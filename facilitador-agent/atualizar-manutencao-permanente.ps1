#Requires -Version 7.0
[CmdletBinding()]
param(
 [string]$ComputerName='facilitadorapp4.tjpb.jus.br',
 [string]$ServiceId='manutencao-tjpb-app4',
 [switch]$LocalApply
)
$ErrorActionPreference='Stop'
$PackageHashesBase64='__MAGBEL_SERVICE_HASHES__'
if ((Get-AuthenticodeSignature -LiteralPath $PSCommandPath).Status -ne 'Valid') {throw 'Atualizador sem assinatura confiável.'}
if ($ServiceId -notmatch '^[a-z][a-z0-9-]{0,63}$' -or $ComputerName -notmatch '^[a-zA-Z][a-zA-Z0-9.-]{0,252}$') {throw 'Identidade/destino inválido.'}
if ($PackageHashesBase64 -eq '__MAGBEL_SERVICE_HASHES__') {throw 'Prepare e assine um pacote institucional novo.'}
$Hashes=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($PackageHashesBase64)) | ConvertFrom-Json -AsHashtable
$Names=@('permanent_maintenance.py','maintenance_controller.py','fleet_manager.py','setup_assistant.py','facilitador-agent.py','manutencao-agente.ps1','requirements.txt')
if ((($Hashes.Keys | Sort-Object) -join ',') -ne (($Names | Sort-Object) -join ',')) {throw 'Manifesto divergente.'}
foreach ($Name in $Names) {
    if ((Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $Name) -Algorithm SHA256).Hash -ne $Hashes[$Name]) {throw "Pacote alterado: $Name"}
}
if (-not $LocalApply) {
    $Session=New-PSSession -ComputerName $ComputerName -Authentication Kerberos -ConfigurationName Microsoft.PowerShell
    try {
        $Remote=Invoke-Command -Session $Session -ScriptBlock {
            $Folder=Join-Path $env:TEMP ('magbel-maintenance-update-'+[guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $Folder | Out-Null
            $null=& icacls.exe $Folder /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F'
            if ($LASTEXITCODE -ne 0) {throw 'Falha na proteção do pacote temporário.'}
            $Folder
        }
        foreach ($Name in @($Names)+@('atualizar-manutencao-permanente.ps1')) {Copy-Item -LiteralPath (Join-Path $PSScriptRoot $Name) -Destination $Remote -ToSession $Session}
        Invoke-Command -Session $Session -ArgumentList $Remote,$ServiceId -ScriptBlock {
            param($Folder,$Id)
            & 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -NonInteractive -File (Join-Path $Folder 'atualizar-manutencao-permanente.ps1') -LocalApply -ServiceId $Id
            if ($LASTEXITCODE -ne 0) {throw 'Atualização interrompida; conferir mensagem anterior.'}
        }
    } finally {Remove-PSSession $Session}
    return
}
$Principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {throw 'Exige sessão administrativa no destino.'}
$Root=Join-Path $env:ProgramData ('Magbel\Maintenance\'+$ServiceId)
$TaskName='Magbel-Manutencao-'+$ServiceId
$Task=Get-ScheduledTask -TaskName $TaskName
if ([string]$Task.State -ne 'Ready') {throw 'Pare somente a tarefa de manutenção, após conferir que não há atualização aberta. Exige estado Ready.'}
foreach ($Path in @($env:ProgramData,(Join-Path $env:ProgramData 'Magbel'),(Split-Path $Root),$Root)) {
    if ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Runtime atravessa link/junction.'}
}
if (Get-ChildItem -LiteralPath $Root -Recurse -Force | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}) {throw 'Runtime contém link/junction.'}
$Identity=Join-Path $Root 'identity.json'
$IdentityHash=(Get-FileHash -LiteralPath $Identity).Hash
$Registration=Get-Content -LiteralPath $Identity -Raw -Encoding UTF8 | ConvertFrom-Json
if ($Registration.id -ne $ServiceId -or $Registration.hostname.Split('.')[0] -ine $env:COMPUTERNAME) {throw 'Identidade não pertence a esta máquina.'}
$Package=Join-Path $Root 'package'
$Runtime=Join-Path $Root 'venv\Scripts\python.exe'
$Processes=@(Get-CimInstance Win32_Process | Where-Object {
    $_.CommandLine -and ($_.Name -in @('python.exe','pythonw.exe','pwsh.exe')) -and
    ($_.CommandLine.IndexOf((Join-Path $Package 'permanent_maintenance.py'),[StringComparison]::OrdinalIgnoreCase) -ge 0 -or $_.CommandLine.IndexOf((Join-Path $Package 'manutencao-agente.ps1'),[StringComparison]::OrdinalIgnoreCase) -ge 0)
})
if ($Processes.Count) {throw 'Processo do conector/helper ainda ativo; nenhuma troca realizada.'}
$OldConfig=Join-Path $Root 'service.json'
$OldHashes=(Get-Content -LiteralPath $OldConfig -Raw -Encoding UTF8 | ConvertFrom-Json).hashes
foreach ($Name in $Names) {
    if ((Get-FileHash -LiteralPath (Join-Path $Package $Name)).Hash -ne $OldHashes.$Name) {throw 'Pacote instalado divergente; conferir antes de atualizar.'}
}
if ((Get-FileHash -LiteralPath (Join-Path $Package 'requirements.txt')).Hash -ne $Hashes['requirements.txt']) {throw 'Esta atualização não modifica dependências.'}
if ((Get-AuthenticodeSignature -LiteralPath (Join-Path $PSScriptRoot 'manutencao-agente.ps1')).Status -ne 'Valid') {throw 'Helper novo sem assinatura válida.'}
$Stamp=(Get-Date -Format 'yyyyMMddTHHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
$Backup=Join-Path $Root ('backups\'+$Stamp)
New-Item -ItemType Directory -Path $Backup -Force | Out-Null
$Stage=Join-Path $Backup 'package-new'
New-Item -ItemType Directory -Path $Stage | Out-Null
foreach ($Name in $Names) {Copy-Item -LiteralPath (Join-Path $PSScriptRoot $Name) -Destination $Stage}
foreach ($Name in $Names | Where-Object {$_ -like '*.py'}) {
    & $Runtime -m py_compile (Join-Path $Stage $Name)
    if ($LASTEXITCODE -ne 0) {throw "Código Python inválido: $Name"}
}
$TaskXml=Export-ScheduledTask -TaskName $TaskName
$Pending=Join-Path $Backup 'service-new.json'
@{hashes=$Hashes} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Pending -Encoding UTF8
if ((Get-FileHash -LiteralPath $Identity).Hash -ne $IdentityHash -or (Export-ScheduledTask -TaskName $TaskName) -ne $TaskXml -or [string](Get-ScheduledTask -TaskName $TaskName).State -ne 'Ready') {throw 'Estado mudou durante a preparação; nenhuma troca realizada.'}
$OldPackage=Join-Path $Backup 'package-before'
$OldManifest=Join-Path $Backup 'service-before.json'
Move-Item -LiteralPath $Package -Destination $OldPackage
try {
    Move-Item -LiteralPath $Stage -Destination $Package
    [IO.File]::Replace($Pending,$OldConfig,$OldManifest)
} catch {
    if (Test-Path -LiteralPath $Package) {Move-Item -LiteralPath $Package -Destination (Join-Path $Backup 'package-failed')}
    Move-Item -LiteralPath $OldPackage -Destination $Package
    if (Test-Path -LiteralPath $OldManifest) {Copy-Item -LiteralPath $OldManifest -Destination $OldConfig -Force}
    throw
}
Start-ScheduledTask -TaskName $TaskName
[pscustomobject]@{Computer=$env:COMPUTERNAME;Task=$TaskName;Backup=$Backup;IdentityPreserved=((Get-FileHash -LiteralPath $Identity).Hash -eq $IdentityHash);Result='Código do conector atualizado; conferir contato e sondas no painel'}
