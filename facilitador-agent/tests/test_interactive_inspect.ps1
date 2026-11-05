#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$Source = Join-Path $env:TEMP ('magbel-query-'+[guid]::NewGuid().ToString('N')+'.ps1')
try {
    # Extrai apenas a constante literal, sem importar/executar o agente.
    $Export = "import ast,pathlib,sys; t=ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')); v=next(ast.literal_eval(n.value) for n in t.body if isinstance(n,ast.Assign) and any(isinstance(x,ast.Name) and x.id=='INTERACTIVE_QUERY_SCRIPT' for x in n.targets)); pathlib.Path(sys.argv[2]).write_text(v,encoding='utf-8-sig')"
    & python -c $Export (Join-Path $PSScriptRoot '..\facilitador-agent.py') $Source
    if ($LASTEXITCODE) { throw 'Não foi possível extrair o adaptador.' }
    $Tokens=$null; $Errors=$null
    $Ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$Tokens,[ref]$Errors)
    if ($Errors.Count) { throw ($Errors | Out-String) }
    $Allowed=@('Get-MagbelQueryIdentity','Import-Module','Get-DhcpServerv4Scope','Get-DhcpServerv4Reservation','Select-Object','Get-ADGroup','Get-ADUser','ForEach-Object')
    foreach ($Node in $Ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true)) {
        if ($Allowed -notcontains $Node.GetCommandName()) { throw ('Comando não autorizado: '+$Node.GetCommandName()) }
    }
    $Updater=Join-Path $PSScriptRoot '..\atualizar-consultas-210.ps1'
    [Management.Automation.Language.Parser]::ParseFile($Updater,[ref]$Tokens,[ref]$Errors) | Out-Null
    if ($Errors.Count) { throw 'Sintaxe inválida no atualizador 2.0.10.' }
    $PythonText=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\facilitador-agent.py')).Replace("`r`n","`n").TrimEnd([char[]]"`r`n")+"`n"
    $Hasher=[Security.Cryptography.SHA256]::Create()
    try { $Hash=[BitConverter]::ToString($Hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($PythonText))).Replace('-','').ToLowerInvariant() } finally {$Hasher.Dispose()}
    if ((Get-Content -LiteralPath $Updater -Raw) -notmatch ("ExpectedHash = '"+$Hash+"'")) { throw 'Hash do atualizador não corresponde ao Python revisado.' }
    . $Source
    function Import-Module { param($Name,$ErrorAction) }
    function Get-MagbelQueryIdentity { 'TJ-PB\facilitador-servico' }
    function Get-DhcpServerv4Scope { param($ComputerName,$ScopeId,$ErrorAction)
        [pscustomobject]@{ScopeId='10.0.1.0';SubnetMask='255.255.255.0';StartRange='10.0.1.10';EndRange='10.0.1.200';State='Active'}
    }
    function Get-DhcpServerv4Reservation { param($ComputerName,$ScopeId,$ErrorAction)
        [pscustomobject]@{IPAddress='10.0.1.15';ClientId='01-02-11-22-33-44-55';Name='Scanner';Description='Sala 2'}
    }
    $Request=[pscustomobject]@{profile='dhcp';server='srv02.tjpb.jus.br';scope='10.0.1.0';execution_account='TJ-PB\facilitador-servico';macs=@('021122334455');ips=@()}
    $Result=Invoke-MagbelInteractiveReadOnly $Request
    if (-not $Result.ok -or $Result.data.reservations.Count -ne 1 -or $Result.data.reservations[0].client_id -ne '021122334455') { throw 'Consulta DHCP não corresponde ao MAC.' }
    function Get-ADGroup { param($LDAPFilter,$Server,$ErrorAction)
        [pscustomobject]@{DistinguishedName='CN=wifi-IoT,OU=Grupos,DC=tjpb,DC=jus,DC=br'}
    }
    function Get-ADUser { param($LDAPFilter,$SearchBase,$SearchScope,$Server,$Properties,$ErrorAction)
        if ($SearchBase -notlike 'OU=Usuarios,*' -or $LDAPFilter -ne '(sAMAccountName=021122334455)') { throw 'Busca fora do escopo' }
        [pscustomobject]@{Enabled=$true;Description='Dispositivo teste';MemberOf=@('CN=wifi-IoT,OU=Grupos,DC=tjpb,DC=jus,DC=br')}
    }
    $Request=[pscustomobject]@{profile='iot';server='srv03.tjpb.jus.br';base_dn='OU=Usuarios,OU=IOTs,DC=tjpb,DC=jus,DC=br';execution_account='TJ-PB\facilitador-servico';macs=@('021122334455');groups=@('wifi-IoT')}
    $Result=Invoke-MagbelInteractiveReadOnly $Request
    if (-not $Result.ok -or $Result.data.devices.Count -ne 1 -or $Result.data.devices[0].groups[0] -ne 'wifi-IoT') { throw 'Consulta IoT incompleta.' }
    function Get-ADUser { throw 'AccessDenied' }
    $Failed=$false; try { Invoke-MagbelInteractiveReadOnly $Request | Out-Null } catch { $Failed=$true }
    if (-not $Failed) { throw 'Falha de acesso foi mascarada como ausência.' }
    $Request.execution_account='TJ-PB\outra-conta'
    $Failed=$false; try { Invoke-MagbelInteractiveReadOnly $Request | Out-Null } catch { $Failed=$_.Exception.Message -eq 'execution_identity_mismatch' }
    if (-not $Failed) { throw 'Identidade de execução divergente foi aceita.' }
    Write-Host 'Consulta DHCP/IoT: AST somente leitura, identidade, escopo, MAC e falhas preservadas: OK'
} finally { Remove-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue }
