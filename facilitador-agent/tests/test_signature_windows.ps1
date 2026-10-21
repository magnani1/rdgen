# Somente runner Windows descartável. Não usar em máquinas do domínio.
#Requires -Version 7.0
param([Parameter(Mandatory)][string]$AssistantExe)
$ErrorActionPreference='Stop'
$Root=Join-Path ([IO.Path]::GetTempPath()) ('magbel-signature-ci-'+[guid]::NewGuid().ToString('N'))
$Certificate=$null
New-Item -ItemType Directory -Path $Root | Out-Null
try {
    Write-Host 'CI: criando certificado descartável'
    $Certificate=New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=Magbel CI disposable only' -CertStoreLocation Cert:\CurrentUser\My -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddDays(1)
    $PublicFile=Join-Path $Root 'public.cer'
    Export-Certificate -Cert $Certificate -FilePath $PublicFile | Out-Null
    Write-Host 'CI: confiando na raiz apenas no runner descartável'
    & certutil.exe -addstore -f Root $PublicFile | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao confiar no certificado descartável do runner.' }
    $Package=Join-Path $Root 'pacote com espaços'
    New-Item -ItemType Directory -Path $Package | Out-Null
    foreach ($Name in @('instalar-agente.ps1','run-agent.ps1')) {
        '# fixture, never executed' | Set-Content (Join-Path $Package $Name) -Encoding utf8BOM
    }
    Copy-Item -LiteralPath $AssistantExe -Destination (Join-Path $Package 'Magbel-Facilitador-Setup.exe')
    Write-Host 'CI: assinando cópias descartáveis'
    foreach ($File in Get-ChildItem $Package -File) {
        $Signature=Set-AuthenticodeSignature -FilePath $File.FullName -Certificate $Certificate -HashAlgorithm SHA256
        if ($Signature.Status -ne 'Valid') { throw "CI fixture signature failed: $($Signature.Status)" }
    }
    $env:MAGBEL_SIGNATURE_FIXTURE=$Package
    $env:MAGBEL_SIGNATURE_SOURCE=(Resolve-Path (Join-Path $PSScriptRoot '..\setup_assistant.py')).Path
    $env:PYTHONUTF8='1'
    Write-Host 'CI: executando verificação real pelo Python'
    @'
import importlib.util, os, pathlib, subprocess
spec=importlib.util.spec_from_file_location('setup',os.environ['MAGBEL_SIGNATURE_SOURCE'])
setup=importlib.util.module_from_spec(spec);spec.loader.exec_module(setup)
p=pathlib.Path(os.environ['MAGBEL_SIGNATURE_FIXTURE'])
setup.verify_package('pwsh',p,p/'Magbel-Facilitador-Setup.exe')
print('Real Windows Authenticode + encoded PowerShell transport: valid package accepted')
# Compare old transport without relying on it for the production decision.
env=os.environ.copy();env['MAGBEL_SETUP_PACKAGE']=str(p);env['MAGBEL_SETUP_EXE']=str(p/'Magbel-Facilitador-Setup.exe')
old=subprocess.run(['pwsh','-NoProfile','-NonInteractive','-Command','-'],input=setup.VERIFY_SIGNATURES,text=True,encoding='utf-8',capture_output=True,env=env,timeout=30,creationflags=subprocess.CREATE_NO_WINDOW)
print('Old stdin transport: returncode=',old.returncode,'report_received=', '"valid":true' in old.stdout)
launcher=p/'run-agent.ps1'
launcher.write_bytes(launcher.read_bytes().replace(b'fixture',b'changed',1))
try:
    setup.verify_package('pwsh',p,p/'Magbel-Facilitador-Setup.exe')
except ValueError as error:
    assert 'HashMismatch' in str(error),str(error)
    print('Real Windows Authenticode: modified launcher rejected with HashMismatch')
else:raise AssertionError('Modified launcher accepted')
'@ | python -
    if ($LASTEXITCODE -ne 0) { throw 'Signature integration test failed.' }
    Write-Host 'CI: preparando pacote completo de frota com hashes assinados'
    $FleetPackage=Join-Path $Root 'pacote-frota'
    & (Join-Path $PSScriptRoot '..\preparar-pacote-assinado.ps1') -CertificateThumbprint $Certificate.Thumbprint -Destination $FleetPackage

    $RealHelper=Join-Path $FleetPackage 'gerenciar-frota.ps1'
    $HelperBackup=Join-Path $Root 'helper-original.ps1'
    Copy-Item -LiteralPath $RealHelper -Destination $HelperBackup
    @'
param([string]$Mode)
$ErrorActionPreference='Stop'
$Data=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([Console]::In.ReadToEnd())) | ConvertFrom-Json
if ($Mode -ne 'LocalInstall' -or $Data.password -ne 'ação-测试' -or $Data.code -ne 'fixture-code') { exit 9 }
[Console]::WriteLine('MAGBEL_FLEET:{"ok":true}')
'@ | Set-Content -LiteralPath $RealHelper -Encoding utf8BOM
    $StubSignature=Set-AuthenticodeSignature -FilePath $RealHelper -Certificate $Certificate -HashAlgorithm SHA256
    if ($StubSignature.Status -ne 'Valid') { throw 'Assinatura do stub de teste inválida.' }
    $BridgeTokens=$null; $BridgeErrors=$null
    $Ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\gerenciar-frota.ps1'),[ref]$BridgeTokens,[ref]$BridgeErrors)
    if ($BridgeErrors.Count) { throw 'Sintaxe do helper inválida.' }
    $Bridge=$Ast.Find({param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Invoke-FleetLocalProcess'},$true)
    if (-not $Bridge) { throw 'Função de ponte não encontrada.' }
    $env:MAGBEL_BRIDGE_TEST_FUNCTION=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Bridge.Extent.Text))
    $env:MAGBEL_BRIDGE_TEST_PACKAGE=$FleetPackage
    $env:MAGBEL_BRIDGE_TEST_SIGNER=$Certificate.Thumbprint
    $env:MAGBEL_BRIDGE_TEST_PWSH=(Get-Command pwsh).Source
    $BridgeTest=@'
$ErrorActionPreference='Stop'
. ([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:MAGBEL_BRIDGE_TEST_FUNCTION))))
$Hashes=@{}
foreach ($Name in @('instalar-agente.ps1','run-agent.ps1','facilitador-agent.py','requirements.txt','fleet_manager.py','setup_assistant.py')) { $Hashes[$Name]=(Get-FileHash -LiteralPath (Join-Path $env:MAGBEL_BRIDGE_TEST_PACKAGE $Name)).Hash }
$Payload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{password='ação-测试';code='fixture-code'} | ConvertTo-Json -Compress)))
$Result=Invoke-FleetLocalProcess $env:MAGBEL_BRIDGE_TEST_PACKAGE $Hashes $env:MAGBEL_BRIDGE_TEST_SIGNER $env:MAGBEL_BRIDGE_TEST_PWSH $Payload
if (-not $Result.ok -or $Result.pending) { throw 'Bridge não concluiu.' }
Write-Host 'Windows PowerShell 5.1 -> processo PowerShell 7: pipe Unicode e assinaturas: OK'
'@
    $EncodedBridgeTest=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($BridgeTest))
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -EncodedCommand $EncodedBridgeTest
    if ($LASTEXITCODE -ne 0) { throw 'Bridge Windows PowerShell 5.1 falhou.' }
    Copy-Item -LiteralPath $HelperBackup -Destination $RealHelper -Force
    $env:MAGBEL_FLEET_FIXTURE=$FleetPackage
    @'
import base64, json, os, pathlib, subprocess
from importlib.util import spec_from_file_location, module_from_spec
p=pathlib.Path(os.environ['MAGBEL_FLEET_FIXTURE'])
spec=spec_from_file_location('setup',os.environ['MAGBEL_SIGNATURE_SOURCE'])
setup=module_from_spec(spec);spec.loader.exec_module(setup)
setup.verify_package('pwsh',p,p/'gerenciar-frota.ps1')
# Nunca conecta ao domínio: substitui o único ponto de abertura da sessão.
script="""function New-PSSession { throw 'CI_NO_NETWORK' }
& (Join-Path $env:MAGBEL_FLEET_FIXTURE 'gerenciar-frota.ps1') -Mode Inspect -ComputerName magbel-ci-target -AgentId magbel-ci-target -HomeUrl https://facilitador.example.test -ScriptsRoot '\\\\server\\scripts$' -ClientId TJPB
"""
encoded=base64.b64encode(script.encode('utf-16le')).decode('ascii')
def inspect():
    result=subprocess.run(['pwsh','-NoProfile','-NonInteractive','-EncodedCommand',encoded],text=True,encoding='utf-8',capture_output=True,timeout=30)
    reports=[json.loads(line.split(':',1)[1]) for line in result.stdout.splitlines() if line.startswith('MAGBEL_FLEET:')]
    assert reports,(result.returncode,'missing fleet report')
    return reports[-1]
assert inspect()['phase']=='Microsoft.PowerShell-Kerberos','Pacote válido não passou na conferência local'
with (p/'facilitador-agent.py').open('a',encoding='utf-8') as f:f.write('\n# altered transport\n')
assert inspect()['phase']=='package','Runtime alterado não foi recusado antes da conexão'
print('Pacote completo assinado aceito; runtime alterado bloqueado antes de qualquer conexão WinRM')
'@ | python -
    if ($LASTEXITCODE -ne 0) { throw 'Fleet package integration test failed.' }

} finally {
    Remove-Item Env:\MAGBEL_SIGNATURE_FIXTURE,Env:\MAGBEL_SIGNATURE_SOURCE,Env:\MAGBEL_FLEET_FIXTURE,Env:\MAGBEL_BRIDGE_TEST_FUNCTION,Env:\MAGBEL_BRIDGE_TEST_PACKAGE,Env:\MAGBEL_BRIDGE_TEST_SIGNER,Env:\MAGBEL_BRIDGE_TEST_PWSH -ErrorAction SilentlyContinue
    if ($Certificate) {
        & certutil.exe -delstore Root $Certificate.Thumbprint | Out-Null
        foreach ($Store in @('Cert:\CurrentUser\My')) {
            Remove-Item "$Store\$($Certificate.Thumbprint)" -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -LiteralPath $Root -Recurse -Force
}

