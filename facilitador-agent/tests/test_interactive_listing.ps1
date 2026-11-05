#Requires -Version 5.1
$ErrorActionPreference='Stop'
$Source=Join-Path $env:TEMP ('magbel-list-'+[guid]::NewGuid().ToString('N')+'.ps1')
try {
    $Export="import ast,pathlib,sys; t=ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')); v=next(ast.literal_eval(n.value) for n in t.body if isinstance(n,ast.Assign) and any(isinstance(x,ast.Name) and x.id=='INTERACTIVE_LIST_SCRIPT' for x in n.targets)); pathlib.Path(sys.argv[2]).write_text(v,encoding='utf-8-sig')"
    & python -c $Export (Join-Path $PSScriptRoot '..\facilitador-agent.py') $Source
    if ($LASTEXITCODE) {throw 'Falha ao extrair constante.'}
    $Tokens=$null;$Errors=$null
    $Ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$Tokens,[ref]$Errors)
    if ($Errors.Count) {throw ($Errors|Out-String)}
    $Allowed=@('Get-MagbelListIdentity','Test-MagbelListMatch','Import-Module','Get-DhcpServerv4Scope','Get-DhcpServerv4Reservation','Get-ADGroup','Get-ADUser','Where-Object','Sort-Object','Select-Object')
    foreach($Node in $Ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true)) {
        if($Allowed -notcontains $Node.GetCommandName()){throw ('Comando fora da consulta: '+$Node.GetCommandName())}
    }
    . $Source
    function Import-Module {param($Name,$ErrorAction)}
    function Get-MagbelListIdentity {'TJ-PB\facilitador-servico'}
    $script:Scopes=@()
    function Get-DhcpServerv4Scope {param($ComputerName,$ScopeId,$ErrorAction)
        $script:Scopes+=[string]$ScopeId
        [pscustomobject]@{ScopeId=$ScopeId;Name='Escopo';SubnetMask='255.255.255.0';StartRange='10.0.1.10';EndRange='10.0.1.200';State='Active'}
    }
    $Request=[pscustomobject]@{profile='dhcp';kind='scopes';server='srv02.tjpb.jus.br';execution_account='TJ-PB\facilitador-servico';scopes=@('10.0.1.0','10.0.2.0');scope='';term='';offset=1;limit=1}
    $Result=Invoke-MagbelInteractiveList $Request
    if($Result.total -ne 2 -or $Result.rows.Count -ne 1 -or $Result.has_more -or $script:Scopes.Count -ne 1 -or $script:Scopes[0] -ne '10.0.2.0'){throw 'Escopos/pagina divergentes'}
    function Get-DhcpServerv4Reservation {param($ComputerName,$ScopeId,$ErrorAction)
        if([string]$ScopeId -ne '10.0.1.0'){throw 'Escopo fora da politica'}
        [pscustomobject]@{IPAddress='10.0.1.15';ClientId='01-02-11-22-33-44-55';Name='Scanner';Description='Sala 2'}
    }
    $Request.kind='reservations';$Request.scope='10.0.1.0';$Request.offset=0;$Request.term='02:11:22:33:44:55'
    $Result=Invoke-MagbelInteractiveList $Request
    if($Result.total -ne 1 -or $Result.rows[0].client_id -ne '021122334455'){throw 'Filtro MAC divergente'}
    function Get-ADGroup {param($LDAPFilter,$Server,$ErrorAction)
        if($LDAPFilter -eq '(sAMAccountName=wifi-IoT)'){[pscustomobject]@{DistinguishedName='CN=wifi-IoT,DC=tjpb,DC=jus,DC=br'}}
    }
    function Get-ADUser {param($LDAPFilter,$SearchBase,$SearchScope,$Server,$ResultSetSize,$ResultPageSize,$Properties,$ErrorAction)
        if($LDAPFilter -ne '(&(objectCategory=person)(objectClass=user))' -or $SearchBase -ne 'OU=IOTs,DC=tjpb,DC=jus,DC=br' -or $ResultSetSize -ne 2001){throw 'Consulta fora do escopo'}
        [pscustomobject]@{SamAccountName='021122334455';Enabled=$true;Description='Scanner [teste]';MemberOf=@('CN=wifi-IoT,DC=tjpb,DC=jus,DC=br','CN=Outro,DC=tjpb,DC=jus,DC=br')}
        [pscustomobject]@{SamAccountName='conta-humana';Enabled=$true;Description='Nao listar';MemberOf=@()}
    }
    $Request=[pscustomobject]@{profile='iot';kind='devices';server='srv03.tjpb.jus.br';execution_account='TJ-PB\facilitador-servico';base_dn='OU=IOTs,DC=tjpb,DC=jus,DC=br';groups=@('wifi-IoT','ausente');group='wifi-IoT';term='[teste]';offset=0;limit=25}
    $Result=Invoke-MagbelInteractiveList $Request
    if($Result.total -ne 1 -or $Result.rows[0].groups.Count -ne 1){throw 'Lista IoT, grupos ou busca literal divergente'}
    $Request.term='inexistente';$Result=Invoke-MagbelInteractiveList $Request
    if($Result.total -ne 0 -or $Result.rows.Count -ne 0){throw 'Lista vazia divergente'}
    $Request.kind='groups';$Request.term='';$Request.group='';$Result=Invoke-MagbelInteractiveList $Request
    if($Result.total -ne 2 -or @($Result.rows|Where-Object {-not $_.exists}).Count -ne 1){throw 'Grupo ausente mascarado'}
    $Request.kind='devices'
    function Get-ADUser {throw 'AccessDenied'}
    $Failed=$false;try{Invoke-MagbelInteractiveList $Request|Out-Null}catch{$Failed=$true}
    if(-not $Failed){throw 'Erro mascarado como vazio'}
    function Get-ADUser {1..2001|ForEach-Object {[pscustomobject]@{SamAccountName='021122334455'}}}
    $Failed=$false;try{Invoke-MagbelInteractiveList $Request|Out-Null}catch{$Failed=$_.Exception.Message -eq 'query_limit_exceeded'}
    if(-not $Failed){throw 'Limite AD ignorado'}
    $Request.execution_account='TJ-PB\outra'
    $Failed=$false;try{Invoke-MagbelInteractiveList $Request|Out-Null}catch{$Failed=$_.Exception.Message -eq 'execution_identity_mismatch'}
    if(-not $Failed){throw 'Identidade divergente aceita'}
    Write-Host 'Listagens: AST somente leitura, escopos, pagina, MAC, OU, grupos, limites e falhas: OK'
} finally {Remove-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue}
