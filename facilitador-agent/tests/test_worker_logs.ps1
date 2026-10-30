#Requires -Version 7.0
$ErrorActionPreference='Stop'
$File=Join-Path $PSScriptRoot '..\worker\Executar-WinRM.ps1'
$Tokens=$null; $Errors=$null
$Ast=[Management.Automation.Language.Parser]::ParseFile($File,[ref]$Tokens,[ref]$Errors)
if ($Errors.Count) {throw 'Worker não passou no parser.'}
$Function=$Ast.Find({param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Mostrar-LinhaAnalista'},$true)
if (-not $Function) {throw 'Função de encaminhamento ausente.'}
# Só a função é carregada. Não abre sessão, copia scripts ou cria tarefas.
. ([scriptblock]::Create($Function.Extent.Text))
$Lines=[Collections.Generic.List[string]]::new()
function Write-Log([string]$Mensagem) {$Lines.Add($Mensagem)}
$Programa='KODAK1XX_LOCAL'
Mostrar-LinhaAnalista '[2026-10-29 09:47:41] Instalando o SmartTouch...'
Mostrar-LinhaAnalista 'SUCESSO: teste de outro fabricante'
Mostrar-LinhaAnalista '[ERRO] instalação recusada'
Mostrar-LinhaAnalista ''
if ($Lines.Count -ne 3 -or $Lines[0] -ne 'Instalando o SmartTouch...' -or $Lines[1] -ne 'SUCESSO: teste de outro fabricante' -or $Lines[2] -notlike '*instalação recusada*') {throw 'Mensagens genéricas foram descartadas ou rotuladas incorretamente.'}
Write-Host 'Worker: mensagens Kodak/genéricas e erros preservados, sem WinRM: OK'
$Reader=$Ast.Find({param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Get-CompleteLogLines'},$true)
. ([scriptblock]::Create($Reader.Extent.Text))
$First=Get-CompleteLogLines -Text "linha 1`nparte"
if ($First.Offset -ne 8 -or $First.Lines.Count -ne 1) {throw 'Linha parcial foi emitida.'}
$Second=Get-CompleteLogLines -Text "linha 1`nparte completa`n" -Offset $First.Offset
if ($Second.Lines.Count -ne 1 -or $Second.Lines[0] -ne 'parte completa') {throw 'Linha incremental duplicada/cortada.'}
$Final=Get-CompleteLogLines -Text 'sem quebra final' -Final
if ($Final.Lines[0] -ne 'sem quebra final') {throw 'Ultima linha perdida.'}
$Reset=Get-CompleteLogLines -Text "novo`n" -Offset 100
if ($Reset.Lines[0] -ne 'novo') {throw 'Truncamento nao tratado.'}
foreach ($Name in @('Executar-Guardado.ps1','..\publicar-worker-serial.ps1')) {
    $Tokens=$null;$Errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $File) $Name),[ref]$Tokens,[ref]$Errors)
    if ($Errors.Count) {throw "Parser recusou $Name : $($Errors.Message)"}
}
# Exclusao real de handles: o segundo dono nao pode abrir o mesmo gate enquanto o primeiro vive.
$Temp=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N')+'.lock')
$One=$null;$Two=$null
try {
    $One=[IO.File]::Open($Temp,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $Blocked=$false
    try {$Two=[IO.File]::Open($Temp,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
    catch [IO.IOException] {$Blocked=$true}
    if (-not $Blocked) {throw 'Segundo dono conseguiu abrir o gate.'}
    $One.Dispose();$One=$null
    $Two=[IO.File]::Open($Temp,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
} finally {if ($One) {$One.Dispose()};if ($Two) {$Two.Dispose()};Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue}
Write-Host 'Linhas incompletas, truncamento, parser e exclusao de handles: OK'
# Regressao: o watcher deve ler com o gravador aberto ou adiar uma disputa exclusiva.
# As duas copias do leitor sao exercitadas sem carregar/executar o worker/guard inteiro.
foreach ($ReaderFile in @($File,(Join-Path (Split-Path $File) 'Executar-Guardado.ps1'))) {
    $Tokens=$null;$Errors=$null
    $ReaderAst=[Management.Automation.Language.Parser]::ParseFile($ReaderFile,[ref]$Tokens,[ref]$Errors)
    if ($Errors.Count) {throw "Parser recusou $ReaderFile"}
    $Definition=$ReaderAst.Find({param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Read-SharedLog'},$true)
    if (-not $Definition) {throw 'Leitor compartilhado ausente.'}
    . ([scriptblock]::Create($Definition.Extent.Text))
    $Temp=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N')+'.log')
    $Handle=$null
    try {
        $Handle=[IO.File]::Open($Temp,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
        $Bytes=[Text.Encoding]::UTF8.GetBytes("primeira`nsegunda parcial")
        $Handle.Write($Bytes,0,$Bytes.Length);$Handle.Flush()
        $Read=Read-SharedLog -Path $Temp
        if ($Read.State -ne 'read' -or $Read.Text -ne "primeira`nsegunda parcial") {throw 'Leitura falhou com gravador compartilhado aberto.'}
        $First=Get-CompleteLogLines -Text $Read.Text
        if ($First.Lines.Count -ne 1 -or $First.Lines[0] -ne 'primeira') {throw 'Leitura antecipou linha parcial.'}
        $Bytes=[Text.Encoding]::UTF8.GetBytes(" completa`n")
        $Handle.Write($Bytes,0,$Bytes.Length);$Handle.Flush()
        $Next=Get-CompleteLogLines -Text (Read-SharedLog -Path $Temp).Text -Offset $First.Offset
        if ($Next.Lines.Count -ne 1 -or $Next.Lines[0] -ne 'segunda parcial completa') {throw 'Cursor duplicou/cortou linha.'}
        $Handle.Dispose();$Handle=$null
        $Handle=[IO.File]::Open($Temp,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $Read=Read-SharedLog -Path $Temp
        if ($Read.State -ne 'busy' -or $null -ne $Read.Text) {throw 'Arquivo exclusivo deveria adiar leitura sem simular arquivo vazio.'}
        $Handle.Dispose();$Handle=$null
        if ((Read-SharedLog -Path $Temp).State -ne 'read') {throw 'Leitura nao retomou apos liberar o arquivo.'}
        if ((Read-SharedLog -Path ($Temp+'.missing')).State -ne 'missing') {throw 'Arquivo ainda ausente nao tratado.'}
        $Directory=$Temp+'.directory'
        New-Item -ItemType Directory -Path $Directory | Out-Null
        try {
            $Propagated=$false
            try {Read-SharedLog -Path $Directory | Out-Null} catch {$Propagated=$true}
            if (-not $Propagated) {throw 'Erro real de acesso foi indevidamente tratado como disputa temporaria.'}
        } finally {Remove-Item -LiteralPath $Directory -Force}

    } finally {if ($Handle) {$Handle.Dispose()};Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue}
}
Write-Host 'Leitura com gravador aberto, disputa exclusiva, retomada e cursor incremental: OK'
