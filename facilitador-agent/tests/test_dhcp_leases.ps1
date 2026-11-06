#Requires -Version 5.1
$ErrorActionPreference='Stop'
$Source=Join-Path $env:TEMP ('magbel-leases-'+[guid]::NewGuid().ToString('N')+'.ps1')
try {
    $Export="import ast,pathlib,sys; t=ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')); v=next(ast.literal_eval(n.value) for n in t.body if isinstance(n,ast.Assign) and any(isinstance(x,ast.Name) and x.id=='DHCP_LEASE_SCRIPT' for x in n.targets)); pathlib.Path(sys.argv[2]).write_text(v,encoding='utf-8-sig')"
    & python -c $Export (Join-Path $PSScriptRoot '..\facilitador-agent.py') $Source
    if($LASTEXITCODE){throw 'ExtractionFailed'}
    $Tokens=$null;$Errors=$null
    $Ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$Tokens,[ref]$Errors)
    if($Errors.Count){throw ($Errors|Out-String)}
    $Allowed=@('Get-MagbelLeaseIdentity','Test-MagbelLeaseMatch','Import-Module','Get-DhcpServerv4Scope','Get-DhcpServerv4Lease','Receive-Job','ForEach-Object','Where-Object','Sort-Object','Select-Object','Stop-Job','Remove-Job')
    foreach($Node in $Ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true)){
        if($Allowed -notcontains $Node.GetCommandName()){throw ('UnexpectedCommand '+$Node.GetCommandName())}
    }
    . $Source
    function Get-MagbelLeaseIdentity {'TJ-PB\facilitador-servico'}
    function Import-Module {param($Name,$ErrorAction)}
    $script:Called=@()
    function Get-DhcpServerv4Scope {param($ComputerName,[ipaddress[]]$ScopeId,$ErrorAction)
        $All=@(
            [pscustomobject]@{ScopeId='10.6.96.0';Name='JPA Sede';Description='Rede corporativa';SubnetMask='255.255.252.0';State='Active'},
            [pscustomobject]@{ScopeId='10.0.8.0';Name='Homologacao';Description='Teste';SubnetMask='255.255.255.0';State='Active'},
            [pscustomobject]@{ScopeId='10.0.9.0';Name='Inativo';Description='Nao consultar';SubnetMask='255.255.255.0';State='Inactive'})
        if($ScopeId){$All|Where-Object {$ScopeId -contains [ipaddress]$_.ScopeId}}else{$All}
    }
    function Get-DhcpServerv4Lease {
        [CmdletBinding()]param([Parameter(ValueFromPipelineByPropertyName=$true)][ipaddress]$ScopeId,[string]$ComputerName,[switch]$AsJob,[int]$ThrottleLimit)
        process {
            if(-not $AsJob -or $ThrottleLimit -ne 8){throw 'QueryMustBeThrottled'}
            $script:Called+=[string]$ScopeId
            $Base=@{ScopeId=[string]$ScopeId;ClientId='01-00-1A-E8-D8-BC-D5';LeaseExpiryTime=[datetime]::UtcNow.AddHours(1);Description='Terminal';AddressState='Active'}
            if([string]$ScopeId -eq '10.6.96.0'){
                [pscustomobject](@{}+$Base+@{IPAddress='10.6.98.186';HostName='SEDE153729.tjpb.jus.br'})
                foreach($State in @('Expired','Offered','Inactive','ActiveReservation')){$Other=@{}+$Base;$Other.AddressState=$State;[pscustomobject]($Other+@{IPAddress='10.6.98.187';HostName='Nao incluir'})}
                $Other=@{}+$Base;$Other.LeaseExpiryTime=[datetime]::UtcNow.AddHours(-1);[pscustomobject]($Other+@{IPAddress='10.6.98.188';HostName='Expirada'})
            }else{[pscustomobject](@{}+$Base+@{IPAddress='10.0.8.40';HostName='TESTE'})}
        }
    }
    function Receive-Job {
        [CmdletBinding()]param([Parameter(ValueFromPipeline=$true)]$Job,[switch]$Wait,[switch]$AutoRemoveJob)
        process {if(-not $Wait -or -not $AutoRemoveJob){throw 'JobMustBeReceived'};$Job}
    }
    $Request=[pscustomobject]@{execution_account='TJ-PB\facilitador-servico';server='srv02.tjpb.jus.br';discover_scopes=$true;scopes=@();scope='';term='';offset=0;limit=25}
    $Result=Invoke-MagbelActiveLeases $Request
    if($Result.total -ne 2 -or $Result.scope_count -ne 2 -or $Result.rows[0].ip -ne '10.0.8.40' -or $script:Called -contains '10.0.9.0'){throw 'ActiveOnlyOrSortingFailed'}
    $script:Called=@();$Request.term='10.6.98.186';$Result=Invoke-MagbelActiveLeases $Request
    if($Result.total -ne 1 -or $script:Called.Count -ne 1 -or $script:Called[0] -ne '10.6.96.0' -or $Result.rows[0].scope_name -ne 'JPA Sede' -or $Result.rows[0].scope_description -ne 'Rede corporativa'){throw 'ScopeDetectionFailed'}
    foreach($Term in @('00:1A:E8:D8:BC:D5','SEDE153729','corporativa','JPA Sede')){
        $Request.term=$Term;$Result=Invoke-MagbelActiveLeases $Request
        if($Result.total -lt 1 -or $Result.rows[-1].client_id -ne '001AE8D8BCD5'){throw 'LiteralSearchFailed'}
    }
    $Request.term='';$Request.offset=1;$Request.limit=1;$Result=Invoke-MagbelActiveLeases $Request
    if($Result.total -ne 2 -or $Result.has_more -or $Result.rows[0].ip -ne '10.6.98.186'){throw 'PaginationFailed'}
    $Request.offset=0;$Request.term='inexistente';$Result=Invoke-MagbelActiveLeases $Request
    if($Result.total -ne 0 -or $Result.rows.Count -ne 0){throw 'EmptyResultFailed'}
    $Request.term='';$Request.discover_scopes=$false;$Request.scopes=@('10.6.96.0');$Result=Invoke-MagbelActiveLeases $Request
    if($Result.total -ne 1 -or $Result.scope_count -ne 1){throw 'ScopePolicyFailed'}
    $Request.kind='scopes';$Request.discover_scopes=$true;$Request.scopes=@();$Request.scope='';$Request.term='';$Request.limit=2048;$script:Called=@()
    $Result=Invoke-MagbelActiveLeases $Request
    if($Result.total -ne 2 -or $script:Called.Count -ne 0 -or $Result.rows[1].description -ne 'Rede corporativa'){throw 'ScopeListQueriedLeasesOrLostDescription'}
    $Request.term='JPA Sede';$Result=Invoke-MagbelActiveLeases $Request
    if($Result.total -ne 1 -or $Result.rows[0].id -ne '10.6.96.0'){throw 'ScopeFilterFailed'}
    $Request.kind='leases';$Request.scope='10.6.96.0';$Request.term='';$Request.limit=25;$script:Called=@()
    $Result=Invoke-MagbelActiveLeases $Request
    if($Result.total -ne 1 -or $script:Called.Count -ne 1 -or $script:Called[0] -ne '10.6.96.0'){throw 'SelectedScopeNotEnforced'}
    function Get-DhcpServerv4Lease {throw 'AccessDenied'}
    $Failed=$false;try{Invoke-MagbelActiveLeases $Request|Out-Null}catch{$Failed=$true}
    if(-not $Failed){throw 'AccessErrorWasHidden'}
    $Request.execution_account='TJ-PB\outra'
    $Failed=$false;try{Invoke-MagbelActiveLeases $Request|Out-Null}catch{$Failed=$_.Exception.Message -eq 'execution_identity_mismatch'}
    if(-not $Failed){throw 'IdentityNotEnforced'}
    Write-Host 'DHCP: somente leitura, identidade, concessoes dinamicas ativas, escopo automatico, descricao, busca e pagina: OK'
}finally{Remove-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue}
