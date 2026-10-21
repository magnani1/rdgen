# Somente runner Windows descartável. Não usar em máquinas do domínio.
#Requires -Version 7.0
param([Parameter(Mandatory)][string]$AssistantExe)
$ErrorActionPreference='Stop'
$Root=Join-Path ([IO.Path]::GetTempPath()) ('magbel-signature-ci-'+[guid]::NewGuid().ToString('N'))
$Certificate=$null
New-Item -ItemType Directory -Path $Root | Out-Null
try {
    $Certificate=New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=Magbel CI disposable only' -CertStoreLocation Cert:\CurrentUser\My -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddDays(1)
    $PublicFile=Join-Path $Root 'public.cer'
    Export-Certificate -Cert $Certificate -FilePath $PublicFile | Out-Null
    Import-Certificate -FilePath $PublicFile -CertStoreLocation Cert:\CurrentUser\Root | Out-Null
    Import-Certificate -FilePath $PublicFile -CertStoreLocation Cert:\CurrentUser\TrustedPublisher | Out-Null
    $Package=Join-Path $Root 'pacote com espaços'
    New-Item -ItemType Directory -Path $Package | Out-Null
    foreach ($Name in @('instalar-agente.ps1','run-agent.ps1')) {
        '# fixture, never executed' | Set-Content (Join-Path $Package $Name) -Encoding utf8BOM
    }
    Copy-Item -LiteralPath $AssistantExe -Destination (Join-Path $Package 'Magbel-Facilitador-Setup.exe')
    foreach ($File in Get-ChildItem $Package -File) {
        $Signature=Set-AuthenticodeSignature -FilePath $File.FullName -Certificate $Certificate -HashAlgorithm SHA256
        if ($Signature.Status -ne 'Valid') { throw "CI fixture signature failed: $($Signature.Status)" }
    }
    $env:MAGBEL_SIGNATURE_FIXTURE=$Package
    $env:MAGBEL_SIGNATURE_SOURCE=(Resolve-Path (Join-Path $PSScriptRoot '..\setup_assistant.py')).Path
    $env:PYTHONUTF8='1'
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
} finally {
    Remove-Item Env:\MAGBEL_SIGNATURE_FIXTURE,Env:\MAGBEL_SIGNATURE_SOURCE -ErrorAction SilentlyContinue
    if ($Certificate) {
        foreach ($Store in @('Cert:\CurrentUser\My','Cert:\CurrentUser\Root','Cert:\CurrentUser\TrustedPublisher')) {
            Remove-Item "$Store\$($Certificate.Thumbprint)" -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -LiteralPath $Root -Recurse -Force
}
