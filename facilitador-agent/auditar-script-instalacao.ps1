#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Path)
$ErrorActionPreference='Stop'
$File=Get-Item -LiteralPath $Path
if ($File.Extension -ine '.ps1') {throw 'Informe o arquivo PowerShell de instalacao, sem executa-lo.'}
$Tokens=$null;$Errors=$null
$Ast=[Management.Automation.Language.Parser]::ParseFile($File.FullName,[ref]$Tokens,[ref]$Errors)
$Findings=@()
foreach ($Command in $Ast.FindAll({param($Node) $Node -is [Management.Automation.Language.CommandAst]},$true)) {
    $Name=$Command.GetCommandName()
    if ($Name -match '^(Stop-Process|taskkill(?:\.exe)?|kill|spps|Stop-ScheduledTask)$') {
        $Findings+=[pscustomobject]@{Line=$Command.Extent.StartLineNumber;Kind='process_termination';Command=$Name;Review='Conferir alvo e propriedade; nao encerrar instaladores de outras acoes.'}
    }
    if ($Name -eq 'Start-Process') {
        $Names=@($Command.CommandElements | Where-Object {$_ -is [Management.Automation.Language.CommandParameterAst]} | ForEach-Object ParameterName)
        if ($Names -notcontains 'Wait') {$Findings+=[pscustomobject]@{Line=$Command.Extent.StartLineNumber;Kind='asynchronous_process';Command=$Name;Review='Conferir espera, timeout e codigo de saida; pode haver WaitForExit separado.'}}
    }
}
[pscustomobject]@{File=$File.FullName;Sha256=(Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash;ParserErrors=$Errors.Count;Findings=$Findings;Executed=$false;Scope='Analise estatica parcial; nao detecta comandos construidos dinamicamente nem comprova seguranca.'} | ConvertTo-Json -Depth 5
