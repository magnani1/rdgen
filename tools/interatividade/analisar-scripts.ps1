#Requires -Version 5.1
[CmdletBinding()]
param([string[]]$ScriptPath=@(), [string]$MenuJson, [string]$OutputDirectory)
$ErrorActionPreference='Stop'

function Get-MenuReferences {
    param($Menu,[string]$BaseName)
    $result=New-Object 'System.Collections.Generic.List[object]'
    function Walk-MenuNode($Node,$Module,$Result,$Expected) {
        if($Node -is [array]) {
            if($Node.Count -ge 5 -and $Node[3] -is [string] -and $Node[4] -is [string]) {
                $leaf=($Node[4] -split '[\\/]')[-1]
                $name=[IO.Path]::GetFileNameWithoutExtension($leaf)
                if($name -ieq $Expected) {
                    $Result.Add([pscustomobject]@{module=$Module;label=[string]$Node[1];handler=[string]$Node[3]})
                }
            }
            foreach($Child in $Node){Walk-MenuNode $Child $Module $Result $Expected}
        }
    }
    if($null -ne $Menu) {
        foreach($Property in $Menu.PSObject.Properties) {
            Walk-MenuNode $Property.Value $Property.Name $result $BaseName
        }
    }
    return $result.ToArray()
}

function Get-PS1Analysis {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,$Menu)
    $File=Get-Item -LiteralPath $Path
    if($File.Extension -ine '.ps1' -or $File.Length -gt 5MB){throw 'Informe um PS1 de ate 5 MB.'}
    $Tokens=$null;$ParseErrors=$null
    $Ast=[Management.Automation.Language.Parser]::ParseFile($File.FullName,[ref]$Tokens,[ref]$ParseErrors)
    $Parameters=New-Object 'System.Collections.Generic.List[object]'
    foreach($Parameter in @($Ast.ParamBlock.Parameters)) {
        if($null -eq $Parameter){continue}
        $Name=$Parameter.Name.VariablePath.UserPath
        $Sensitive=$Name -match '(?i)senha|password|secret|token|credential|credencial|otp|codigo.*mfa'
        $Opaque=$Name -match '(?i)^(payload|json|command|comando|scriptblock)$'
        $Type='string';$Mandatory=$false;$Options=@()
        foreach($Attribute in $Parameter.Attributes) {
            if($Attribute -is [Management.Automation.Language.TypeConstraintAst]) {$Type=$Attribute.TypeName.FullName}
            if($Attribute -isnot [Management.Automation.Language.AttributeAst]){continue}
            if($Attribute.TypeName.Name -ieq 'Parameter') {
                foreach($Named in $Attribute.NamedArguments) {
                    if($Named.ArgumentName -ieq 'Mandatory') {
                        $Mandatory=$Named.ExpressionOmitted -or $Named.Argument.Extent.Text -ieq '$true'
                    }
                }
            }
            if($Attribute.TypeName.Name -ieq 'ValidateSet' -and -not $Sensitive) {
                foreach($Argument in $Attribute.PositionalArguments) {
                    if($Argument -is [Management.Automation.Language.StringConstantExpressionAst]) {$Options+= $Argument.Value}
                }
            }
        }
        $Field=[ordered]@{nome=$Name;label=($Name -replace '_',' ');tipo='text';required=[bool]$Mandatory}
        if($Options.Count){$Field.tipo='select';$Field.opcoes=@($Options)}
        $NeedsAdapter=$Sensitive -or $Opaque -or $Type -notin @('string','System.String','int','System.Int32','long','System.Int64','double','System.Double','decimal','System.Decimal')
        $Parameters.Add([pscustomobject]@{
            name=$Name;type=$Type;mandatory=[bool]$Mandatory;sensitive=[bool]$Sensitive;opaque=[bool]$Opaque
            default_present=($null -ne $Parameter.DefaultValue);requires_adapter=[bool]$NeedsAdapter
            suggested_field=$(if($NeedsAdapter){$null}else{[pscustomobject]$Field})
        })
    }
    $Signals=New-Object 'System.Collections.Generic.List[object]'
    $Commands=@($Ast.FindAll({param($Node) $Node -is [Management.Automation.Language.CommandAst]},$true))
    foreach($Command in $Commands) {
        $Name=$Command.GetCommandName()
        $Kind=$null
        if(-not $Name){$Kind='dynamic_invocation'}
        elseif($Name -match '^(?i:Read-Host|Get-Credential)$'){$Kind='runtime_prompt'}
        elseif($Name -match '^(?i:Invoke-Expression|iex)$'){$Kind='dynamic_code'}
        elseif($Name -match '^(?i:Out-GridView|Show-Command)$'){$Kind='gui'}
        if($Kind){$Signals.Add([pscustomobject]@{kind=$Kind;command=$Name;line=$Command.Extent.StartLineNumber})}
    }
    foreach($Node in @($Ast.FindAll({param($Node) $Node -is [Management.Automation.Language.InvokeMemberExpressionAst]},$true))) {
        $Member=$Node.Member.Value
        if($Member -match '^(?i:ShowDialog|InputBox|PromptForChoice|PromptForCredential)$' -or
           ($Member -ieq 'Show' -and $Node.Expression.Extent.Text -match '(?i)MessageBox')) {
            $Signals.Add([pscustomobject]@{kind='gui_or_host_prompt';command=$Member;line=$Node.Extent.StartLineNumber})
        }
    }
    $Reasons=New-Object 'System.Collections.Generic.List[string]'
    if(@($ParseErrors).Count){$Reasons.Add('syntax_errors')}
    if(@($Signals|Where-Object kind -in @('gui','gui_or_host_prompt')).Count){$Reasons.Add('gui_requires_headless_backend')}
    if(@($Signals|Where-Object kind -eq 'runtime_prompt').Count){$Reasons.Add('runtime_prompts_require_explicit_parameters_or_workflow')}
    if(@($Signals|Where-Object kind -in @('dynamic_code','dynamic_invocation')).Count){$Reasons.Add('dynamic_code_requires_review')}
    if(@($Parameters|Where-Object requires_adapter).Count){$Reasons.Add('credential_opaque_or_typed_parameter_requires_adapter')}
    if(-not $Parameters.Count){$Reasons.Add('no_top_level_parameters')}
    $BaseName=$File.BaseName -replace '\(\d+\)$',''
    $References=@(Get-MenuReferences $Menu $BaseName)
    return [pscustomobject][ordered]@{
        format='magbel.facilitador.script-analysis.v1'
        name=$File.Name
        sha256=(Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        syntax_valid=(@($ParseErrors).Count -eq 0)
        syntax_errors=@($ParseErrors|ForEach-Object {[pscustomobject]@{id=$_.ErrorId;line=$_.Extent.StartLineNumber}})
        parameters=@($Parameters.ToArray());interaction_signals=@($Signals.ToArray())
        classification=$(if($Reasons.Count){'requires_adapter_or_review'}else{'parameterized_candidate'})
        review_reasons=@($Reasons.ToArray())
        menu_references=$References
        permission_inferred=$false
        execution_enabled=$false
        requires_review=$true
        limitations=@('Static analysis does not prove absence of prompts or side effects.','Menu placement is not an authorization rule.','No script, default expression or GUI was executed.','No source text, default values or credential values are exported.')
    }
}

$Menu=$null
if($MenuJson){$Menu=Get-Content -LiteralPath $MenuJson -Raw -Encoding UTF8|ConvertFrom-Json}
if($OutputDirectory -and $ScriptPath.Count){New-Item -ItemType Directory -Path $OutputDirectory -Force|Out-Null}
foreach($Path in $ScriptPath) {
    $Analysis=Get-PS1Analysis -Path $Path -Menu $Menu
    $Json=$Analysis|ConvertTo-Json -Depth 12
    if($OutputDirectory) {
        $Name=[IO.Path]::GetFileNameWithoutExtension($Path)+'-'+$Analysis.sha256.Substring(0,12)+'.analysis.json'
        $Json|Set-Content -LiteralPath (Join-Path $OutputDirectory $Name) -Encoding UTF8
    }
    else {$Json}
}
