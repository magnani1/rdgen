#Requires -Version 5.1
$ErrorActionPreference='Stop'
$Source=Join-Path $env:TEMP ('magbel-iot-'+[guid]::NewGuid().ToString('N')+'.ps1')
try {
    $Export="import ast,pathlib,sys; t=ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')); v=next(ast.literal_eval(n.value) for n in t.body if isinstance(n,ast.Assign) and any(isinstance(x,ast.Name) and x.id=='IOT_ACTION_SCRIPT' for x in n.targets)); pathlib.Path(sys.argv[2]).write_text(v,encoding='utf-8-sig')"
    & python -c $Export (Join-Path $PSScriptRoot '..\facilitador-agent.py') $Source
    if($LASTEXITCODE){throw 'ExtractionFailed'}
    $Tokens=$null;$Errors=$null
    $Ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$Tokens,[ref]$Errors)
    if($Errors.Count){throw ($Errors|Out-String)}
    # Todas as operações de diretório abaixo são substituídas antes da primeira chamada.
    . $Source
    $script:Base='OU=Usuarios,OU=IOTs,OU=TJPB,DC=tjpb,DC=jus,DC=br'
    $script:GB='OU=Grupos,OU=IOTs,OU=TJPB,DC=tjpb,DC=jus,DC=br'
    $script:Users=@{};$script:Calls=@();$script:Nested=@();$script:FailPassword=$false
    function Get-MagbelIotIdentity {'TJ-PB\facilitador-servico'}
    function Import-Module {param($Name,$ErrorAction)}
    function New-FakeUser($Mac,$Members=@()) {
        $U=[pscustomobject]@{SamAccountName=$Mac;ObjectGUID=[guid]::NewGuid();DistinguishedName="CN=$Mac,$script:Base";uSNChanged=1;Enabled=$false;LockedOut=$true;PasswordNeverExpires=$false;Description='Antiga';MemberOf=@($Members);userWorkstations='ORIGINAL'}
        $script:Users[$Mac]=$U;return $U
    }
    function Find-FakeUser($Id) {return @($script:Users.Values|Where-Object {$_.ObjectGUID -eq $Id -or $_.DistinguishedName -eq $Id})[0]}
    function Get-ADUser {param($LDAPFilter,$Server,$Properties,$ErrorAction)
        if($Server -ne 'srv03.test'){throw 'WrongServer'}
        $Mac=([regex]::Match($LDAPFilter,'sAMAccountName=([0-9a-f]{12})')).Groups[1].Value
        if($script:Users.ContainsKey($Mac)){$script:Users[$Mac]}
    }
    function Get-ADGroup {param($LDAPFilter,$SearchBase,$Server,$ErrorAction)
        if($SearchBase -ne $script:GB -or $Server -ne 'srv03.test'){throw 'WrongGroupScope'}
        $Name=([regex]::Match($LDAPFilter,'sAMAccountName=([^\)]+)')).Groups[1].Value
        if($Name -in @('wifi-IoT','VOIP','Senha_Simples','Senha_TJPB')){[pscustomobject]@{Name=$Name;DistinguishedName="CN=$Name,$script:GB"}}
    }
    function Get-ADAccountAuthorizationGroup {param($Identity,$Server,$ErrorAction)
        $U=Find-FakeUser $Identity
        foreach($DN in @($U.MemberOf)+@($script:Nested)){[pscustomobject]@{Name=($DN -split ',')[0].Substring(3);DistinguishedName=$DN}}
    }
    function New-ADUser {param($Name,$SamAccountName,$UserPrincipalName,$Path,$Description,$AccountPassword,$Enabled,$LogonWorkstations,[switch]$PassThru,$Server,$ErrorAction)
        if($Enabled -or $Path -ne $script:Base -or $UserPrincipalName -ne ($Name+'@tjpb.jus.br')){throw 'UnsafeInitialAccount'}
        $script:Calls+='create-disabled';$U=New-FakeUser $Name;$U.Description=$Description;$U.userWorkstations=$LogonWorkstations;$U.LockedOut=$false;return $U
    }
    function Add-ADGroupMember {param($Identity,$Members,$Server,$ErrorAction)
        $script:Calls+='add:'+($Identity -split ',')[0].Substring(3);$U=Find-FakeUser $Members;$U.MemberOf+=@($Identity);$U.uSNChanged++
    }
    function Remove-ADGroupMember {param($Identity,$Members,$Confirm,$Server,$ErrorAction)
        $script:Calls+='remove:'+($Identity -split ',')[0].Substring(3);$U=Find-FakeUser $Members;$U.MemberOf=@($U.MemberOf|Where-Object {$_ -ne $Identity});$U.uSNChanged++
    }
    function Set-ADAccountPassword {param($Identity,[switch]$Reset,$NewPassword,$Server,$ErrorAction)
        $script:Calls+='password';if($script:FailPassword){throw 'SimulatedPasswordFailure'}
        $U=Find-FakeUser $Identity;$Ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($NewPassword)
        try{if([Runtime.InteropServices.Marshal]::PtrToStringBSTR($Ptr) -cne $U.SamAccountName){throw 'WrongMacPassword'}}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Ptr)}
        $U.uSNChanged++
    }
    function Set-ADUser {param($Identity,$PasswordNeverExpires,$Description,$Server,$ErrorAction)
        $U=Find-FakeUser $Identity
        if($PSBoundParameters.ContainsKey('PasswordNeverExpires')){$U.PasswordNeverExpires=$PasswordNeverExpires;$script:Calls+='never-expires'}
        if($PSBoundParameters.ContainsKey('Description')){$U.Description=$Description;$script:Calls+='description'}
        $U.uSNChanged++
    }
    function Unlock-ADAccount {param($Identity,$Server,$ErrorAction)
        $script:Calls+='unlock';$U=Find-FakeUser $Identity;$U.LockedOut=$false;$U.uSNChanged++
    }
    function Enable-ADAccount {param($Identity,$Server,$ErrorAction)
        $script:Calls+='enable';$U=Find-FakeUser $Identity;$U.Enabled=$true;$U.uSNChanged++
    }
    function Remove-ADUser {param($Identity,$Confirm,$Server,$ErrorAction)
        $script:Calls+='delete';$U=Find-FakeUser $Identity;$script:Users.Remove($U.SamAccountName)
    }
    function Request($Action,$Mac='021122334455',$Group='',$Description='') {
        return [pscustomobject]@{phase='plan';action=$Action;execution_account='TJ-PB\facilitador-servico';server='srv03.test';base_dn=$script:Base;group_base_dn=$script:GB;groups=@('wifi-IoT','VOIP');records=@([pscustomobject]@{mac=$Mac;group=$Group;description=$Description});expected=@()}
    }
    function Apply($Q) {
        $Plan=Invoke-MagbelIotAction $Q
        if(-not $Plan.ok){throw ('PlanFailed '+$Plan.code)}
        if($script:Calls.Count){throw 'PlanWroteDirectory'}
        $Q.phase='apply';$Q.expected=@($Plan.rows|ForEach-Object {[pscustomobject]@{mac=$_.mac;fingerprint=$_.fingerprint}})
        return Invoke-MagbelIotAction $Q
    }
    $Simple="CN=Senha_Simples,$script:GB";$Policy="CN=Senha_TJPB,$script:GB";$Wifi="CN=wifi-IoT,$script:GB";$Voip="CN=VOIP,$script:GB";$External='CN=Externo,OU=Outros,DC=tjpb,DC=jus,DC=br'
    $U=New-FakeUser '021122334455' @($Wifi,$Policy,$External)
    $R=Apply (Request 'REPARAR')
    if(-not $R.ok -or -not $U.Enabled -or $U.LockedOut -or -not $U.PasswordNeverExpires -or $U.MemberOf -notcontains $Wifi -or $script:Calls[0] -ne 'add:Senha_Simples' -or $script:Calls[1] -ne 'password'){throw 'RepairRulesFailed'}
    $script:Calls=@();$Q=Request 'CRIAR' '021122334466' 'VOIP' 'Telefone';$R=Apply $Q;$U=$script:Users['021122334466']
    if(-not $R.ok -or $script:Calls[0] -ne 'create-disabled' -or $U.userWorkstations -ne 'NPSWIN2K12' -or $U.MemberOf -notcontains $Voip -or -not $U.Enabled -or -not $U.PasswordNeverExpires){throw 'CreateRulesFailed'}
    $script:Calls=@();$R=Invoke-MagbelIotAction (Request 'CRIAR' '021122334466' '' 'Existente')
    if($R.ok -or $R.code -ne 'iot_already_exists' -or $script:Calls.Count){throw 'DuplicateAccountNotRejected'}
    $R=Invoke-MagbelIotAction (Request 'REPARAR' '021122334477')
    if($R.ok -or $R.code -ne 'iot_not_found' -or $script:Users.ContainsKey('021122334477')){throw 'RepairCreatedMissingAccount'}
    $script:Calls=@();$U=$script:Users['021122334455'];$R=Apply (Request 'MIGRAR' '021122334455' 'VOIP')
    if(-not $R.ok -or $U.MemberOf -contains $Wifi -or $U.MemberOf -notcontains $Simple -or $U.MemberOf -notcontains $Policy -or $U.MemberOf -notcontains $External -or $script:Calls[0] -ne 'add:VOIP' -or $script:Calls[1] -ne 'remove:wifi-IoT'){throw 'MigrationTouchedProtectedOrExternalGroups'}
    $script:Calls=@();$R=Apply (Request 'EDITAR' '021122334455' '' 'Nova descrição')
    if(-not $R.ok -or $script:Calls.Count -ne 1 -or $script:Calls[0] -ne 'description' -or $U.Description -ne 'Nova descrição'){throw 'EditChangedMoreThanDescription'}
    $script:Calls=@();$Q=Request 'EDITAR' '021122334455' '' 'Outra';$Plan=Invoke-MagbelIotAction $Q;$Q.phase='apply';$Q.expected=@($Plan.rows);$U.uSNChanged++
    $R=Invoke-MagbelIotAction $Q;if($R.ok -or $R.code -ne 'iot_state_changed' -or $script:Calls.Count){throw 'StalePlanNotBlocked'}
    $script:Nested=@($Wifi);$R=Invoke-MagbelIotAction (Request 'MIGRAR' '021122334455' 'VOIP');$script:Nested=@()
    if($R.ok -or $R.code -ne 'iot_indirect_membership' -or $script:Calls.Count){throw 'IndirectGroupNotBlocked'}
    $R=Apply (Request 'REMOVER_PERFIL' '021122334455' 'VOIP')
    if(-not $R.ok -or $U.MemberOf -contains $Voip -or $U.MemberOf -notcontains $Policy){throw 'RemoveSpecificGroupFailed'}
    $script:Calls=@();$R=Apply (Request 'DELETAR' '021122334455')
    if(-not $R.ok -or $script:Users.ContainsKey('021122334455')){throw 'DeleteFailed'}
    $script:Calls=@();$script:FailPassword=$true;$R=Apply (Request 'CRIAR' '021122334488' '' 'Parcial')
    if($R.ok -or -not $R.uncertain -or $script:Users['021122334488'].Enabled){throw 'PartialFailureNotPreserved'}
    Write-Host 'IoT simulado: criar em etapas, reparar sem criar, editar, migrar, preservar políticas/externos, remover, excluir, estado vencido e falha parcial: OK'
}finally{Remove-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue}
