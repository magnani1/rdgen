"""Sonda somente leitura sob a identidade real da tarefa permanente."""
import argparse
import base64
import json
from pathlib import Path
import re
import subprocess
import sys


def probe(root, target):
    identity=json.loads((root/'identity.json').read_text(encoding='utf-8'))
    if not re.fullmatch(r'[a-z][a-z0-9-]{0,62}(?:\.[a-z0-9][a-z0-9-]{0,62})*',target) or target not in identity['hosts']:
        raise ValueError('Destino fora do escopo da inscrição permanente.')
    helper=str(root/'package'/'manutencao-agente.ps1')
    def value(text):return base64.b64encode(text.encode()).decode()
    script=r'''
$ErrorActionPreference='Stop'
$Target=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__TARGET__'))
$Helper=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__HELPER__'))
$Signature=Get-AuthenticodeSignature -LiteralPath $Helper
$Thumb=if ($Signature.SignerCertificate) {$Signature.SignerCertificate.Thumbprint} else {''}
$Publishers=@(Get-ChildItem Cert:\CurrentUser\TrustedPublisher,Cert:\LocalMachine\TrustedPublisher -ErrorAction SilentlyContinue)
$Info=[ordered]@{
    Account=[Security.Principal.WindowsIdentity]::GetCurrent().Name
    HelperSignature=[string]$Signature.Status
    PublisherThumbprint=$Thumb
    PublisherTrusted=[bool]($Thumb -and @($Publishers | Where-Object Thumbprint -eq $Thumb).Count)
    EffectivePolicy=[string](Get-ExecutionPolicy)
    Remote=$null
    HelperProcessCheck='unavailable'
    HelperProcesses=@()
}
try {
    $Info.HelperProcesses=@(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($Helper,[StringComparison]::OrdinalIgnoreCase) -ge 0 } | ForEach-Object { $_.ProcessId })
    $Info.HelperProcessCheck='ok'
} catch {}
try {
    $Id=$Target.Split('.')[0]
    $Info.Remote=Invoke-Command -ComputerName $Target -Authentication Kerberos -ConfigurationName Microsoft.PowerShell -ArgumentList $Id -ScriptBlock {
        param($Id)
        $ErrorActionPreference='Stop'
        $TaskName='Magbel-Facilitador-'+$Id
        $Task=Get-ScheduledTask -TaskName $TaskName
        $TaskInfo=Get-ScheduledTaskInfo -TaskName $TaskName
        $Code=Join-Path $env:ProgramData ('Magbel\FacilitadorAgent\'+$Id+'\facilitador-agent.py')
        $Principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
        [pscustomobject]@{
            Ok=$true;Computer=$env:COMPUTERNAME;Account=[Security.Principal.WindowsIdentity]::GetCurrent().Name
            AdminToken=$Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            TaskState=[string]$Task.State;LastTaskResult=$TaskInfo.LastTaskResult
            VersionLine=[string]((Select-String -LiteralPath $Code -Pattern '^VERSION\s*=').Line)
        }
    }
} catch {
    $Info.Remote=@{Ok=$false;ErrorType=$_.Exception.GetType().Name;ErrorId=$_.FullyQualifiedErrorId;Category=[string]$_.CategoryInfo.Category}
}
$Info | ConvertTo-Json -Depth 5 -Compress
'''.replace('__TARGET__',value(target)).replace('__HELPER__',value(helper))
    encoded=base64.b64encode(script.encode('utf-16-le')).decode()
    result=subprocess.run(['pwsh','-NoProfile','-NonInteractive','-EncodedCommand',encoded],capture_output=True,encoding='utf-8',errors='replace',timeout=90)
    if result.returncode:
        return {'Ok':False,'Stage':'readonly_powershell','ExitCode':result.returncode}
    data=json.loads(result.stdout.lstrip('\ufeff').strip())
    # Não coletar ambiente, configurações completas, credenciais, logs remotos ou stderr.
    allowed=('Account','HelperSignature','PublisherThumbprint','PublisherTrusted','EffectivePolicy','HelperProcessCheck','HelperProcesses')
    clean={k:data.get(k) for k in allowed}
    remote=data.get('Remote') or {}
    clean['Remote']={k:remote[k] for k in ('Ok','Computer','Account','AdminToken','TaskState','LastTaskResult','VersionLine','ErrorType','ErrorId','Category') if k in remote}
    return clean


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,required=True);parser.add_argument('--target',required=True);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    try:data=probe(args.root,args.target.lower())
    except Exception as error:data={'Ok':False,'Stage':'readonly_probe','ErrorType':type(error).__name__}
    pending=args.output.with_suffix('.pending')
    pending.write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding='utf-8')
    pending.replace(args.output)


if __name__=='__main__':main()
