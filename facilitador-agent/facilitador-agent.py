import time, os, subprocess, requests, urllib3, json, base64, unicodedata, re
import uuid
import concurrent.futures
import threading, shutil, sys, queue, platform
from pathlib import Path
from contextvars import ContextVar
from datetime import datetime


# Pool de 4 workers para execução paralela de jobs
MAX_WORKERS = max(1, min(16, int(os.environ.get("AGENT_SLOTS", "2"))))
EXEC_POOL = concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS)

HOME_URL = os.environ["HOME_URL"].rstrip("/")
if not HOME_URL.startswith("https://"):
    raise RuntimeError("HOME_URL exige HTTPS")
STATE_DIR = Path(os.environ.get("AGENT_STATE_DIR", r"C:\ProgramData\Magbel\FacilitadorAgent"))
TOKEN_FILE = STATE_DIR / "identity.json"
VERSION = "2.0.8"
BOOT_ID = uuid.uuid4().hex
CLIENT_ID = os.environ.get("CLIENT_ID", "TJPB").upper()
IDENTITY = {}
AGENT_TOKEN = ""
CURRENT_JOB = ContextVar("agent_job", default=None)
RUNNING = {}
RUNNING_LOCK = threading.RLock()
DESIRED = "drain"
SERVER_SLOTS = MAX_WORKERS
CAPABILITIES = ["auth", "ad", "winrm"]
INVENTORY_WRITER = False
PROBE = {"ready": False, "diagnostic": "sonda inicial pendente", "at": 0}
PROBE_LOCK = threading.RLock()
PRIVACYIDEA_URL = os.environ.get("PRIVACYIDEA_URL", "https://auth.tjpb.jus.br/validate/check")
REALM = os.environ.get("AD_REALM", "tjpb.jus.br")
if not PRIVACYIDEA_URL.startswith("https://"):
    raise RuntimeError("PRIVACYIDEA_URL exige HTTPS")

BASE_DIR = os.environ.get("AGENT_BASE_DIR", r"C:\ProgramData\Magbel\FacilitadorAgent")
SCRIPTS_DIR = os.environ.get("SCRIPTS_ROOT", os.path.join(BASE_DIR, "Scripts"))
EXECUTAR_WINRM = os.path.join(SCRIPTS_DIR, "Variaveis", "Executar-WinRM.ps1")
LOCAL_DIR = os.path.join(SCRIPTS_DIR, "N1", "local")
LOG_DIR = os.path.join(BASE_DIR, "Logs")

PASTAS_NIVEL = {"N1": 1, "N2": 2, "N3": 3, "ADMIN": 4}
INTERATIVOS_DIR = os.path.join(SCRIPTS_DIR, "Interativos")
CANDIDATOS_DIRS = [INTERATIVOS_DIR] + [os.path.join(SCRIPTS_DIR, p, "local") for p in ("N1", "N2", "N3", "ADMIN")]

HEADERS = {}

def api(method, url, **kwargs):
    headers = {**kwargs.pop("headers", {}), "Authorization": "Bearer " + AGENT_TOKEN}
    job_id = CURRENT_JOB.get()
    if job_id:
        with RUNNING_LOCK:
            token = RUNNING[job_id]
        headers["X-Execution-Token"] = token
        if "/download/" in url:
            kwargs["params"] = {"job_id": job_id}
    response = requests.request(method, url, headers=headers, **kwargs)
    if response.status_code != 204:
        response.raise_for_status()
    return response

TIMEOUT_EXECUCAO = 600
# Prazo remoto separado do executor local e alinhado ao worker. O agente
# aguarda ainda 60s para o worker devolver o resultado/diagnóstico final.
REMOTE_TIMEOUT_SECONDS = max(30, min(14400, int(os.environ.get('AGENT_REMOTE_TIMEOUT_SECONDS', '7200'))))


def consultar_sessoes_windows(host):
    """Consulta WTS no destino por Kerberos; não conecta nem encerra sessões."""
    host=str(host).lower()
    if not re.fullmatch(r'[a-z][a-z0-9-]{0,62}(?:\.[a-z0-9][a-z0-9-]{0,62})*',host):
        return {'ok':False,'code':'invalid_hostname'}
    script=r'''
$ErrorActionPreference='Stop'
$HostName=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__HOST__'))
try {
    $Options=New-PSSessionOption -OpenTimeout 8000 -OperationTimeout 25000
    $Data=Invoke-Command -ComputerName $HostName -Authentication Kerberos -ConfigurationName Microsoft.PowerShell -SessionOption $Options -ArgumentList $HostName -ScriptBlock {
        param($ExpectedHost)
        $ErrorActionPreference='Stop'
        if ($env:COMPUTERNAME -ine $ExpectedHost.Split('.')[0]) {throw 'ComputerMismatch'}
        if (-not ('MagbelWts' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class MagbelWtsRow { public int id; public string account; public string state; }
public static class MagbelWts {
 [StructLayout(LayoutKind.Sequential)] struct Session { public int id; public IntPtr name; public int state; }
 [DllImport("wtsapi32.dll",EntryPoint="WTSEnumerateSessionsW",SetLastError=true)] static extern bool Enumerate(IntPtr server,int reserved,int version,out IntPtr buffer,out int count);
 [DllImport("wtsapi32.dll",EntryPoint="WTSQuerySessionInformationW",SetLastError=true)] static extern bool Query(IntPtr server,int id,int kind,out IntPtr buffer,out int bytes);
 [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr buffer);
 static string Text(int id,int kind) {
  IntPtr buffer=IntPtr.Zero; int bytes;
  try { if(!Query(IntPtr.Zero,id,kind,out buffer,out bytes)) throw new InvalidOperationException("WtsQueryFailed");
    return buffer==IntPtr.Zero ? "" : Marshal.PtrToStringUni(buffer); }
  finally { if(buffer!=IntPtr.Zero) WTSFreeMemory(buffer); }
 }
 public static MagbelWtsRow[] Read() {
  IntPtr buffer=IntPtr.Zero; int count;
  var rows=new List<MagbelWtsRow>();
  try {
   if(!Enumerate(IntPtr.Zero,0,1,out buffer,out count)) throw new InvalidOperationException("WtsEnumerateFailed");
   if(count<0 || count>128) throw new InvalidOperationException("WtsSessionLimit");
   int size=Marshal.SizeOf(typeof(Session));
   for(int i=0;i<count;i++) {
    Session s=(Session)Marshal.PtrToStructure(IntPtr.Add(buffer,i*size),typeof(Session));
    string user=Text(s.id,5); if(String.IsNullOrEmpty(user)) continue;
    string domain=Text(s.id,7);
    rows.Add(new MagbelWtsRow {id=s.id,account=String.IsNullOrEmpty(domain)?user:domain+"\\"+user,state=s.state==0?"active":s.state==4?"disconnected":"other"});
   }
   return rows.ToArray();
  } finally { if(buffer!=IntPtr.Zero) WTSFreeMemory(buffer); }
 }
}
'@
        }
        $Rows=@([MagbelWts]::Read())
        [pscustomobject]@{computer=$env:COMPUTERNAME;sessions=$Rows}
    }
    $Data | ConvertTo-Json -Depth 5 -Compress
} catch { 'null' }
'''.replace('__HOST__',base64.b64encode(host.encode('utf-8')).decode('ascii'))
    try:
        command=base64.b64encode(script.encode('utf-16-le')).decode('ascii')
        result=subprocess.run(['pwsh','-NoProfile','-NonInteractive','-EncodedCommand',command],capture_output=True,encoding='utf-8',errors='replace',timeout=40)
        if result.returncode:return {'ok':False,'code':'windows_query_failed'}
        data=json.loads(result.stdout.lstrip('\ufeff').strip())
        if not isinstance(data,dict) or str(data.get('computer','')).lower()!=host.split('.')[0]:raise ValueError('identity')
        rows=data.get('sessions')
        if not isinstance(rows,list) or len(rows)>128:raise ValueError('sessions')
        clean=[]
        for row in rows:
            account=row.get('account')
            if type(row.get('id')) is not int or not 0<=row['id']<=2147483647 or row.get('state') not in ('active','disconnected','other') or not isinstance(account,str) or not 1<=len(account)<=256 or any(ord(c)<32 for c in account):raise ValueError('session')
            clean.append({k:row[k] for k in ('id','account','state')})
        if len({r['id'] for r in clean})!=len(clean):raise ValueError('duplicate_session')
        names=consultar_nomes_sessoes(clean)
        for row in clean:
            name=names.get(row['account'].casefold())
            if name:row['display_name']=name
        return {'ok':True,'source':'windows_wts_winrm','hostname':host,'checked_at':int(time.time()),'sessions':clean}
    except (OSError,ValueError,TypeError,AttributeError,subprocess.SubprocessError):
        return {'ok':False,'code':'windows_query_failed'}

def consultar_nomes_sessoes(sessions):
    """Enriquece somente contas WTS do domínio do agente; falha de AD não invalida WTS."""
    accounts=list(dict.fromkeys(r['account'] for r in sessions if '\\' in r['account']))
    if not accounts:return {}
    encoded=base64.b64encode(json.dumps(accounts,ensure_ascii=False).encode('utf-8')).decode('ascii')
    script=r'''
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.Encoding]::UTF8
try {
    $Accounts=@([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__ACCOUNTS__')) | ConvertFrom-Json)
    $Domain=Get-ADDomain -ErrorAction Stop
    $Selected=@($Accounts | Where-Object {
        $Parts=$_ -split '\\',2
        $Parts.Count -eq 2 -and $Parts[0] -in @($Domain.NetBIOSName,$Domain.DNSRoot) -and $Parts[1]
    })
    if (-not $Selected.Count) {'[]';return}
    function Escape-Ldap([string]$Value) {
        $Value.Replace('\','\5c').Replace('*','\2a').Replace('(','\28').Replace(')','\29').Replace([string][char]0,'\00')
    }
    $Filters=@($Selected | ForEach-Object {'(sAMAccountName='+(Escape-Ldap (($_ -split '\\',2)[1]))+')'})
    $Users=@(Get-ADUser -LDAPFilter ('(|'+($Filters -join '')+')') -SearchBase $Domain.DistinguishedName -Server $Domain.DNSRoot -Properties DisplayName -ResultSetSize 256 -ErrorAction Stop)
    $Rows=@(foreach ($Account in $Selected) {
        $Sam=($Account -split '\\',2)[1]
        $Matches=@($Users | Where-Object {$_.SamAccountName -ieq $Sam})
        if ($Matches.Count -eq 1 -and $Matches[0].DisplayName) {
            [pscustomobject]@{account=$Account;display_name=[string]$Matches[0].DisplayName}
        }
    })
    ConvertTo-Json -InputObject $Rows -Compress
} catch {'[]'}
'''.replace('__ACCOUNTS__',encoded)
    try:
        command=base64.b64encode(script.encode('utf-16-le')).decode('ascii')
        result=subprocess.run(['pwsh','-NoProfile','-NonInteractive','-EncodedCommand',command],capture_output=True,encoding='utf-8',errors='replace',timeout=15)
        if result.returncode:return {}
        rows=json.loads(result.stdout.lstrip('\ufeff').strip())
        if not isinstance(rows,list) or len(rows)>128:return {}
        allowed={a.casefold() for a in accounts};names={}
        for row in rows:
            if not isinstance(row,dict):continue
            account=row.get('account');name=row.get('display_name')
            if isinstance(account,str) and account.casefold() in allowed and isinstance(name,str) and name.strip() and len(name)<=256 and not any(ord(c)<32 or ord(c)==127 for c in name):
                names[account.casefold()]=name.strip()
        return names
    except (OSError,ValueError,TypeError,subprocess.SubprocessError):return {}

UPLOADS_DIR = os.path.join(BASE_DIR, "Uploads")

def _norm(s):
    s = unicodedata.normalize('NFKD', s or '')
    return re.sub(r'[^A-Z0-9 ]+', '', s.upper())

SUCCESS_MARKERS = (
    "FIM DA IMPLANTACAO",          # sem acento: casa mesmo com mojibake
    "INSTALADO CORRETAMENTE",
    "SUCESSO VERIFICADO",
    "OPERACAO CONCLUIDA COM SUCESSO",
    "CONCLUIDO COM SUCESSO",
)

def baixar_upload(remote_path, local_name):
    """Baixa um arquivo do backend para uma pasta local conhecida."""
    os.makedirs(UPLOADS_DIR, exist_ok=True)
    local_path = os.path.join(UPLOADS_DIR, local_name)
    try:
        r = api("GET", f"{HOME_URL}/download/{os.path.basename(remote_path)}",
                         headers=HEADERS, stream=True, timeout=60)
        r.raise_for_status()
        with open(local_path, "wb") as f:
            for chunk in r.iter_content(chunk_size=65536):
                f.write(chunk)
        return local_path
    except Exception as e:
        print(f"[agent] erro baixando upload: {e}")
        return None

# ================= AD (COM UTF-8) =================
def consultar_grupos_ad(user):
    user = str(user).replace("\'", "\'\'")
    ps = f"""
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
try {{
    $user = Get-ADUser '{user}' -Properties MemberOf -ErrorAction Stop
    $sids = $user.MemberOf | Get-ADGroup | Select-Object -ExpandProperty SID | Select-Object -ExpandProperty Value
    Write-Output ($sids -join "`n")
}} catch {{ Write-Error "Falhou: $_" }}
"""
    try:
        r = subprocess.run(["pwsh", "-NoProfile", "-Command", ps],
                           capture_output=True, text=True, timeout=30,
                           encoding="utf-8", errors="replace")
        sids = [s.strip() for s in r.stdout.splitlines()
                if s.strip() and s.strip().startswith("S-1-5")]
        if sids:
            print(f"[agent] {len(sids)} grupos para {user}")
            return sids
    except Exception as e:
        print(f"[agent] erro AD: {e}")
    return []

def consultar_display_name(user):
    if not user:
        return "desconhecido"
    user = str(user).replace("\'", "\'\'")
    ps = ("[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; "
          f"try {{ (Get-ADUser '{user}' -Properties DisplayName -ErrorAction Stop).DisplayName }} catch {{ '{user}' }}")
    try:
        r = subprocess.run(["pwsh", "-NoProfile", "-Command", ps],
                           capture_output=True, text=True, timeout=15,
                           encoding="utf-8", errors="replace")
        name = r.stdout.strip()
        return name if name else user
    except Exception:
        return user
        
def _ler_novo_e_enviar(job_id, log_path, offset):
    """Lê o trecho novo do log, envia as linhas ao backend e retorna (novo_offset, conteudo)."""
    if not os.path.exists(log_path):
        return offset, ""
    try:
        with open(log_path, "r", encoding="utf-8", errors="ignore") as f:
            f.seek(offset)
            novo = f.read()
        if novo:
            for linha in novo.splitlines():
                enviar_log(job_id, linha)
            return offset + len(novo.encode("utf-8")), novo
    except Exception:
        pass
    return offset, ""        
        
def buscar_ad(termo, tipo):
    """Busca usuários ou grupos no AD — devolve lista de candidatos."""
    termo = (termo or "").strip().replace("'", "")
    if not termo:
        return {"candidatos": []}
    if tipo == "grupo":
        ps = f"""
$t = '{termo}'
$limpo = $t -replace '\\D',''
if ($limpo -match '^\\d+$' -and $limpo.Length -ge 6) {{
    $r = @(Get-ADGroup -Filter "SamAccountName -eq '$limpo'" -Properties DisplayName,mail -ErrorAction SilentlyContinue)
}} else {{
    $r = @(Get-ADGroup -Filter "DisplayName -like '*$t*' -or SamAccountName -like '*$t*' -or mail -like '*$t*'" -Properties DisplayName,mail -ErrorAction SilentlyContinue)
}}
$r | Select-Object -First 10 | ForEach-Object {{
    $em = if ($_.mail) {{ $_.mail }} else {{ '' }}
    ($_.SamAccountName + '|' + $_.DisplayName + '|' + $em)
}}
"""
    else:
        ps = f"""
$t = '{termo}'
$limpo = $t -replace '\\D',''
if ($t -match '@') {{
    $r = @(Get-ADUser -Filter "mail -like '*$t*'" -Properties DisplayName,mail,Enabled -ErrorAction SilentlyContinue)
}} elseif ($limpo -match '^\\d+$' -and $limpo.Length -ge 6) {{
    $r = @(Get-ADUser -Filter "SamAccountName -eq '$limpo'" -Properties DisplayName,mail,Enabled -ErrorAction SilentlyContinue)
}} else {{
    $palavras = $t.Trim() -split '\\s+'
    if ($palavras.Count -eq 1) {{ $f = "DisplayName -like '*$t*' -or mail -like '*$t*' -or SamAccountName -like '*$t*'" }}
    else {{ $f = (($palavras | ForEach-Object {{ "(DisplayName -like '*$_*' -or mail -like '*$_*' -or SamAccountName -like '*$_*')" }}) -join ' -and ') }}
    $r = @(Get-ADUser -Filter $f -Properties DisplayName,mail,Enabled -ErrorAction SilentlyContinue)
}}
$r | Select-Object -First 10 | ForEach-Object {{
    $em = if ($_.mail) {{ $_.mail }} else {{ '' }}
    $en = if ($_.Enabled) {{ 'sim' }} else {{ 'nao' }}
    ($_.SamAccountName + '|' + $_.DisplayName + '|' + $em + '|' + $en)
}}
"""
    try:
        r = subprocess.run(["pwsh", "-NoProfile", "-Command", ps],
                           capture_output=True, text=True, timeout=30,
                           encoding="utf-8", errors="replace")
        cands = []
        for line in r.stdout.splitlines():
            parts = [p.strip() for p in line.split('|')]
            if len(parts) >= 3 and parts[0]:
                cands.append({
                    "sam": parts[0],
                    "display": parts[1],
                    "mail": parts[2],
                    "enabled": parts[3] if len(parts) > 3 else "sim"
                })
        return {"candidatos": cands}
    except Exception as e:
        return {"candidatos": [], "erro": str(e)}        

# ================= PRIVACYIDEA =================
def step1_privacyidea(user, password):
    try:
        r = requests.post(PRIVACYIDEA_URL,
                          json={"user": user, "realm": REALM, "pass": password},
                          verify=True, timeout=20)
        data = r.json()
        if data.get("result", {}).get("value") is True:
            return {"ok": True, "sids": consultar_grupos_ad(user)}
        tid = (data.get("detail") or {}).get("transaction_id")
        if tid:
            return {"otp_necessario": True, "transaction_id": tid}
        return {"erro": "Credenciais inválidas."}
    except Exception as e:
        return {"erro": f"Erro conexão: {e}"}

def step2_privacyidea(user, otp, transaction_id):
    try:
        r = requests.post(PRIVACYIDEA_URL,
                          json={"user": user, "realm": REALM, "pass": otp,
                                "transaction_id": transaction_id},
                          verify=True, timeout=20)
        data = r.json()
        if data.get("result", {}).get("value") is True:
            return {"ok": True, "sids": consultar_grupos_ad(user)}
        return {"erro": "OTP incorreto."}
    except Exception as e:
        return {"erro": f"Erro conexão: {e}"}

# ================= LOGS =================
def enviar_log(job_id, linha):
    try:
        api("POST", f"{HOME_URL}/fila/log/{job_id}",
                      json={"linha": linha}, headers=HEADERS, timeout=10)
    except Exception:
        pass

def enviar_log_novo(job_id, log_path, offset):
    if not os.path.exists(log_path):
        return offset
    try:
        with open(log_path, "r", encoding="utf-8", errors="ignore") as f:
            f.seek(offset)
            novo = f.read()
        for linha in novo.splitlines():
            enviar_log(job_id, linha)
        return offset + len(novo.encode("utf-8"))
    except Exception:
        return offset

def gravar_log_json(job_id, payload, status, linhas_log):
    try:
        now = datetime.now()
        display = consultar_display_name(payload.get("usuario", ""))
        safe_display = "".join(c for c in display if c.isalnum() or c in " _-").strip() or "desconhecido"
        safe_programa = payload.get("programa", "acao")
        dir_path = os.path.join(LOG_DIR, str(now.year), f"{now.month:02d}",
                                f"{now.day:02d}", safe_display)
        os.makedirs(dir_path, exist_ok=True)
        record = {
            "job_id": job_id,
            "usuario": payload.get("usuario"),
            "display_name": display,
            "programa": payload.get("programa"),
            "script": payload.get("script"),
            "alvos": payload.get("alvos", []),
            "parametros": payload.get("parametros", {}),
            "status": status,
            "iniciado_em": payload.get("_iniciado_em"),
            "concluido_em": now.isoformat(),
            "linhas_log": linhas_log,
        }
        fname = f"{now.strftime('%H%M%S')}_{safe_programa}_{job_id[:8]}.json"
        with open(os.path.join(dir_path, fname), "w", encoding="utf-8") as f:
            json.dump(record, f, ensure_ascii=False, indent=2)
    except Exception as e:
        print(f"[agent] erro gravando JSON: {e}")

# ================= RESOLVER SCRIPT =================
def resolver_script(script_name):
    """Busca o arquivo do script em Interativos e depois nas pastas de nível."""
    for d in CANDIDATOS_DIRS:
        if not os.path.isdir(d):
            continue
        for ext in (".ps1", ".cmd"):
            p = os.path.join(d, script_name + ext)
            if os.path.exists(p):
                return p
    return None

# ================= EXECUÇÃO LOCAL (GAM/RSAT no agent) =================
def executar_local(job_id, payload, script_path):
    log_path = os.path.join(LOG_DIR, f"info_{job_id}.txt")
    os.makedirs(LOG_DIR, exist_ok=True)
    open(log_path, "w", encoding="utf-8").close()

    parametros = {**(payload.get("fixos") or {}), **(payload.get("parametros") or {})}
    params_path = r"C:\Windows\Temp\facilitador_parametros.json"
    with open(params_path, "w", encoding="utf-8") as f:
        json.dump(parametros, f, ensure_ascii=False)

    enviar_log(job_id, f"[INFO] Execução LOCAL: {os.path.basename(script_path)} (op={parametros.get('operacao','')})")

    p = subprocess.Popen(
        ["pwsh", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script_path],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, bufsize=1, encoding="utf-8", errors="replace")

    start = time.time()
    timeout_hit = False
    lines = queue.Queue()
    def read_output():
        try:
            for line in p.stdout:
                lines.put(line)
        finally:
            lines.put(None)
    threading.Thread(target=read_output, daemon=True).start()
    with open(log_path, "a", encoding="utf-8") as lf:
        while True:
            if time.time() - start > TIMEOUT_EXECUCAO:
                p.kill(); timeout_hit = True
                enviar_log(job_id, f"[AVISO] Timeout {TIMEOUT_EXECUCAO}s; conferir processos filhos antes de repetir")
                break
            try: line = lines.get(timeout=0.5)
            except queue.Empty: continue
            if line is None: break
            line = line.rstrip("\r\n")
            lf.write(line + "\n"); lf.flush()
            enviar_log(job_id, line)
    try:
        p.wait(timeout=10)
    except Exception:
        p.kill()

    ok = (p.returncode == 0) and not timeout_hit
    resultado = {"ok": ok}
    if timeout_hit: resultado["uncertain"] = True
    if not ok:
        resultado["erro"] = f"exit={p.returncode}" + (" (timeout)" if timeout_hit else "")
    resultado["display_name"] = consultar_display_name(payload.get("usuario", ""))
    return resultado

# ================= EXECUÇÃO REMOTA (WinRM COM UTF-8) =================
def executar_remota(job_id, payload, script_path):
    if any(not re.fullmatch(r'[A-Za-z0-9_.:-]{1,253}',str(a)) for a in payload.get("alvos",[])):
        return {"ok":False,"erro":"Destino inválido","linhas":[]}
    script_name = os.path.splitext(os.path.basename(script_path))[0].upper()
    log_path = os.path.join(LOG_DIR, f"info_{job_id}.txt")
    remote_log_path = payload.get("remote_log_path", r"C:\windows\isakdoik1288cxzi21938\pc.txt")
    os.makedirs(LOG_DIR, exist_ok=True)
    open(log_path, "w", encoding="utf-8").close()

    parametros = {**(payload.get("fixos") or {}), **(payload.get("parametros") or {})}
    if parametros:
        b64 = base64.b64encode(json.dumps(parametros, ensure_ascii=False).encode("utf-8")).decode()
        for alvo in payload["alvos"]:
            ps = (f'$j=[System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("{b64}"));'
                  f'$s=New-PSSession -ComputerName "{alvo}" -ErrorAction Stop;'
                  f'Invoke-Command -Session $s -ScriptBlock {{ param($x) Set-Content -Path "C:\\Windows\\Temp\\facilitador_parametros.json" -Value $x -Encoding UTF8 -Force }} -ArgumentList $j;'
                  f'Remove-PSSession $s; "OK"')
            r = subprocess.run(["pwsh", "-NoProfile", "-Command", ps],
                               capture_output=True, text=True, timeout=30,
                               encoding="utf-8", errors="replace")  # ← UTF-8
            enviar_log(job_id, f"[INFO] Parâmetros em {alvo}: " + ("OK" if "OK" in r.stdout else f"FALHA {r.stderr.strip()}"))

    procs = []
    for alvo in payload["alvos"]:
        try:
            cmd = ["pwsh", "-WindowStyle", "Hidden", "-NoProfile", "-ExecutionPolicy", "RemoteSigned",
                   "-File", EXECUTAR_WINRM, "-ComputerName", alvo, "-FilePath", script_path,
                   "-RemoteLogPath", remote_log_path, "-LogFile", log_path, "-Programa", script_name,
                   "-TimeoutSeconds", str(REMOTE_TIMEOUT_SECONDS)]
            with open(os.path.join(LOG_DIR, f"watcher_{job_id}.txt"), "a", encoding="utf-8") as watcher_log:
                procs.append((subprocess.Popen(cmd, stdout=watcher_log, stderr=subprocess.STDOUT,
                                              text=True, encoding="utf-8", errors="replace"), alvo))  # ← UTF-8
        except Exception as e:
            enviar_log(job_id, f"[ERRO] Falha iniciando {alvo}: {e}")

    offset = 0; start_time = time.monotonic(); timeout_hit = False; next_notice = 30
    while any(p.poll() is None for p, _ in procs):
        elapsed = time.monotonic() - start_time
        if elapsed > REMOTE_TIMEOUT_SECONDS + 60:
            enviar_log(job_id, "[RESULTADO DESCONHECIDO] Prazo do acompanhamento excedido; encerrando somente o watcher no agente. O instalador remoto pode continuar; conferir antes de repetir.")
            for p, _ in procs:
                if p.poll() is None:
                    try: p.kill()
                    except Exception: pass
            timeout_hit = True; break

        offset, novo = _ler_novo_e_enviar(job_id, log_path, offset)
        if novo:
            next_notice = elapsed + 30
        elif elapsed >= next_notice:
            enviar_log(job_id, f"[ACOMPANHAMENTO] Watcher ativo há {int(elapsed)}s; aguardando novas linhas e resultado da tarefa remota. Isso não confirma progresso do instalador.")
            next_notice = elapsed + 30
        time.sleep(2)
    offset, _ = _ler_novo_e_enviar(job_id, log_path, offset)

    linhas = []
    try:
        with open(log_path, "r", encoding="utf-8", errors="ignore") as f:
            linhas = [l for l in f.read().splitlines() if l.strip()]
    except Exception:
        pass

    if timeout_hit:
        resultado = {"ok": False, "uncertain": True, "linhas": linhas, "erro": "Timeout: conferir execução remota antes de repetir"}
    elif len(procs) != len(payload["alvos"]) or any(p.poll() != 0 for p,_ in procs):
        resultado = {"ok": False, "uncertain": True, "linhas": linhas, "erro": "Watcher sem conclusão confirmada; conferir tarefa e log no cliente antes de repetir"}
    else:
        resultado = {"ok": True, "linhas": linhas}
    resultado["display_name"] = consultar_display_name(payload.get("usuario", ""))
    return resultado
    
# ================= META DO JOB =================
def registrar_display_name(job_id, usuario):
    """Envia o display_name resolvido para o backend anexar ao job."""
    name = consultar_display_name(usuario)
    try:
        api("PATCH", f"{HOME_URL}/fila/meta/{job_id}",
                       json={"display_name": name},
                       headers=HEADERS, timeout=10)
    except Exception as e:
        print(f"[agent] falha meta {job_id}: {e}")    

def executar_winget(job_id, payload):
    """Executa somente o snapshot aprovado, no cliente Windows e na identidade WinRM."""
    plan = payload.get('winget') or {}
    host = (payload.get('alvos') or [''])[0]
    source = plan.get('source') or {}
    package = plan.get('package') or {}
    if (not re.fullmatch(r'[a-f0-9-]{36}', str(job_id)) or payload.get('client_id') != CLIENT_ID
            or payload.get('engine') != 'winget.v1' or len(payload.get('alvos', [])) != 1
            or not re.fullmatch(r'[a-z][a-z0-9-]{0,62}(?:\.[a-z0-9][a-z0-9-]{0,62})*', str(host))
            or plan.get('action') not in ('check', 'install') or package.get('scope') != 'machine'
            or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._+-]{2,149}', str(package.get('package_id', '')))
            or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._+-]{0,59}', str(package.get('version', '')))
            or package.get('architecture') not in ('x64', 'x86', 'arm64')
            or not re.fullmatch(r'[A-Za-z][A-Za-z0-9_-]{1,39}', str(source.get('name', '')))
            or source.get('type') not in ('Microsoft.Rest', 'Microsoft.PreIndexed.Package')
            or not str(source.get('url', '')).startswith('https://')
            or (plan['action'] == 'install' and (plan.get('agreements') is not True
                or not package.get('detection_name') or not package.get('detection_version')))):
        return {'ok': False, 'code': 'invalid_winget_plan', 'erro': 'Plano WinGet inválido; nada executado'}
    data = {'job_id': job_id, 'client_id': CLIENT_ID, 'hostname': host,
            'action': plan['action'], 'agreements': plan.get('agreements', False), 'revision': plan.get('revision', ''),
            'source': {k: source[k] for k in ('name', 'type', 'url')},
            'package': {k: package.get(k, '') for k in ('package_id', 'version', 'architecture', 'scope',
                        'detection_name', 'detection_version', 'detection_product_code')}}
    script = r'''
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.Encoding]::UTF8
[Console]::InputEncoding=[Text.Encoding]::UTF8
$Plan=[Console]::In.ReadToEnd() | ConvertFrom-Json
$Options=New-PSSessionOption -OpenTimeout 10000 -OperationTimeout 30000
try {
 Invoke-Command -ComputerName $Plan.hostname -Authentication Kerberos -ConfigurationName Microsoft.PowerShell -SessionOption $Options -ArgumentList $Plan -ScriptBlock {
  param($Plan)
  $ErrorActionPreference='Stop'
  $Stage='preflight';$Attempted=$false;$Root=$null
  $Result=@{ok=$false;job_id=$Plan.job_id;client_id=$Plan.client_id;hostname=$Plan.hostname;code='preflight_failed';stage=$Stage;uncertain=$false}
  function Event([string]$Phase) {'MAGBEL_WINGET_EVENT:'+(@{stage=$Phase} | ConvertTo-Json -Compress)}
  try {
   Event 'preflight'
   if ($env:COMPUTERNAME -ine $Plan.hostname.Split('.')[0]) {throw 'hostname_mismatch'}
   $Identity=[Security.Principal.WindowsIdentity]::GetCurrent()
   $Result.identity=$Identity.Name
   if ($Identity.User.Value -eq 'S-1-5-18') {throw 'system_cli_unsupported'}
   if (-not ([Security.Principal.WindowsPrincipal]::new($Identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {throw 'admin_required'}
   $OS=Get-CimInstance Win32_OperatingSystem
   if (-not (([int]$OS.ProductType -eq 1 -and [int]$OS.BuildNumber -ge 17763) -or [int]$OS.BuildNumber -ge 26100)) {throw 'os_unsupported'}
   $Winget=$null
   $App=Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue | Select-Object -First 1
   if ($App -and $App.InstallLocation) {$Winget=Join-Path $App.InstallLocation 'winget.exe'}
   if (-not $Winget -or -not (Test-Path -LiteralPath $Winget -PathType Leaf)) {throw 'winget_not_registered'}
   $Signature=Get-AuthenticodeSignature -LiteralPath $Winget
   if ($Signature.Status -ne 'Valid' -or $Signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') {throw 'winget_signature_invalid'}
   $Root=Join-Path $env:ProgramData ('Magbel\WingetJobs\'+$Plan.job_id)
   if (Test-Path -LiteralPath $Root) {throw 'operation_already_seen'}
   New-Item -Path $Root -ItemType Directory -ErrorAction Stop | Out-Null
   $null=& icacls.exe $Root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F'
   if ($LASTEXITCODE -ne 0) {throw 'log_acl_failed'}
   function Native([string[]]$Arguments,[string]$Name,[int]$Seconds=30) {
    $Out=Join-Path $Root ($Name+'.out.txt');$Err=Join-Path $Root ($Name+'.err.txt')
    $Process=Start-Process -FilePath $Winget -ArgumentList $Arguments -NoNewWindow -PassThru -RedirectStandardOutput $Out -RedirectStandardError $Err
    try {
     if (-not $Process.WaitForExit($Seconds*1000)) {Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue;throw 'native_timeout'}
     $Process.WaitForExit();$Process.Refresh()
     [pscustomobject]@{exit_code=$Process.ExitCode;output=$Out}
    } finally {$Process.Dispose()}
   }
   $Version=Native @('--version') 'version'
   if ($Version.exit_code -ne 0) {throw 'winget_unavailable'}
   $Export=Native @('source','export','--name',$Plan.source.name) 'source'
   if ($Export.exit_code -ne 0 -or (Get-Item $Export.output).Length -gt 65536) {throw 'source_unavailable'}
   $Sources=@(Get-Content -LiteralPath $Export.output -Raw -Encoding UTF8 | ConvertFrom-Json)
   $Found=@($Sources | Where-Object {$_.Name -ceq $Plan.source.name})
   if ($Found.Count -ne 1 -or $Found[0].Type -ine $Plan.source.type -or ([string]$Found[0].Arg).TrimEnd('/') -cne ([string]$Plan.source.url).TrimEnd('/')) {throw 'source_mismatch'}
   $Stage='source_checked';Event $Stage
   function Detect {
    if (-not $Plan.package.detection_name -or -not $Plan.package.detection_version) {return $false}
    $Rows=@(foreach ($Base in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
     if (Test-Path $Base) {Get-ChildItem -LiteralPath $Base -ErrorAction Stop | ForEach-Object {Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop}}
    })
    $Matches=@($Rows | Where-Object {[string]$_.DisplayName -ceq $Plan.package.detection_name -and [string]$_.DisplayVersion -ceq $Plan.package.detection_version -and (-not $Plan.package.detection_product_code -or $_.PSChildName -ieq $Plan.package.detection_product_code)})
    return ($Matches.Count -eq 1)
   }
   if (Detect) {$Result.ok=$true;$Result.code='already_installed';$Result.detected=$true}
   else {
    $ShowArguments=@('show','--id',$Plan.package.package_id,'--exact','--version',$Plan.package.version,'--source',$Plan.source.name,'--disable-interactivity')
    if ($Plan.agreements) {$ShowArguments+='--accept-source-agreements'}
    $Show=Native $ShowArguments 'show' 40
    if ($Show.exit_code -ne 0) {$Result.exit_code=$Show.exit_code;throw 'package_check_failed'}
    $Stage='package_checked';Event $Stage
    if ($Plan.action -eq 'check') {$Result.ok=$true;$Result.code='preflight_ready';$Result.detected=$false}
    else {
     $Stage='installing';Event $Stage
     # Marcador privado antes de iniciar; esta operação nunca é repetida automaticamente.
     @{job_id=$Plan.job_id;revision=$Plan.revision;stage='installing'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Root 'operation.json') -Encoding UTF8
     $Attempted=$true
     $Install=Native @('install','--id',$Plan.package.package_id,'--exact','--version',$Plan.package.version,'--source',$Plan.source.name,'--architecture',$Plan.package.architecture,'--scope','machine','--silent','--disable-interactivity','--accept-source-agreements','--accept-package-agreements') 'install' 420
     $Result.exit_code=$Install.exit_code
     $Stage='verifying';Event $Stage
     $Result.detected=Detect
     if ($Install.exit_code -eq 0 -and $Result.detected) {$Result.ok=$true;$Result.code='installed_verified'}
     else {throw 'installation_not_confirmed'}
    }
   }
  } catch {
   $Known=@('hostname_mismatch','system_cli_unsupported','admin_required','os_unsupported','winget_not_registered','winget_signature_invalid','operation_already_seen','log_acl_failed','native_timeout','winget_unavailable','source_unavailable','source_mismatch','package_check_failed','installation_not_confirmed')
   $Code=$_.Exception.Message
   $Result.code=if ($Code -in $Known) {$Code} else {'windows_operation_failed'}
   $Result.uncertain=$Attempted -or $Code -eq 'operation_already_seen'
  }
  $Result.stage=$Stage
  if ($Root) {$Result.log_path=$Root}
  'MAGBEL_WINGET_RESULT:'+($Result | ConvertTo-Json -Depth 5 -Compress)
 } | ForEach-Object {[Console]::WriteLine($_)}
} catch { [Console]::WriteLine('MAGBEL_WINGET_TRANSPORT_FAILED') }
'''
    command = base64.b64encode(script.encode('utf-16-le')).decode('ascii')
    events = {'preflight', 'source_checked', 'package_checked', 'installing', 'verifying'}
    process = None
    try:
        process = subprocess.Popen(['pwsh', '-NoProfile', '-NonInteractive', '-EncodedCommand', command],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, encoding='utf-8', errors='replace')
        output = queue.Queue()
        def read():
            try:
                for line in process.stdout:
                    line = line.lstrip('\ufeff')
                    if line.startswith('MAGBEL_WINGET_'):
                        output.put(line[:16000])
            finally: output.put(None)
        threading.Thread(target=read, daemon=True).start()
        process.stdin.write(json.dumps(data, ensure_ascii=False))
        process.stdin.close()
        start = time.monotonic(); result = None
        while time.monotonic() - start < 540:
            try: line = output.get(timeout=0.5)
            except queue.Empty: continue
            if line is None: break
            if line.startswith('MAGBEL_WINGET_EVENT:'):
                event = json.loads(line.split(':', 1)[1])
                if event.get('stage') in events: enviar_log(job_id, '[WinGet] ' + event['stage'])
            elif line.startswith('MAGBEL_WINGET_RESULT:'):
                result = json.loads(line.split(':', 1)[1])
        if not isinstance(result, dict) or result.get('job_id') != job_id or result.get('hostname') != host or result.get('client_id') != CLIENT_ID:
            raise ValueError('unconfirmed_transport')
        if type(result.get('ok')) is not bool or type(result.get('uncertain')) is not bool:
            raise ValueError('invalid_result')
        enviar_log(job_id, '[WinGet] ' + str(result.get('code', 'unconfirmed')))
        if not result['ok']: result['erro'] = 'WinGet: ' + str(result.get('code', 'unconfirmed'))
        return result
    except (OSError, ValueError, TypeError, subprocess.SubprocessError):
        return {'ok': False, 'uncertain': True, 'code': 'transport_unconfirmed', 'erro': 'WinGet sem resultado confirmado; conferir cliente antes de repetir'}
    finally:
        if process is not None and process.poll() is None:
            process.kill()
            try: process.wait(timeout=5)
            except subprocess.SubprocessError: pass


# ================= DISPATCHER =================
def executar(job_id, payload):
    if payload.get('engine') == 'winget.v1':
        return executar_winget(job_id, payload)
    script_name = payload.get("script", payload["programa"]).upper()
    script_path = resolver_script(script_name)
    if not script_path:
        return {"ok": False, "erro": f"Script não encontrado: {script_name}", "linhas": []}

    if payload.get("upload_path"):
        if payload.get("execucao") != "local":
            return {"ok": False, "erro": "Upload remoto exige adaptador de cópia específico; não foi executado"}
        local = baixar_upload(payload["upload_path"], job_id + os.path.splitext(payload["upload_path"])[1])
        if not local:
            return {"ok": False, "erro": "Upload não pôde ser obtido"}
        payload.setdefault("parametros", {})["arquivo"] = local
    if payload.get("execucao") == "local":
        return executar_local(job_id, payload, script_path)
    return executar_remota(job_id, payload, script_path)

# ================= INVENTÁRIO =================
def inventariar_scripts():
    itens = []

    for pasta, nivel in PASTAS_NIVEL.items():
        d = os.path.join(SCRIPTS_DIR, pasta, "local")
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d)):
            ext = os.path.splitext(f)[1].lower()
            if ext not in (".ps1", ".cmd"):
                continue
            itens.append({
                "pasta": pasta, "nivel_min": nivel,
                "nome": os.path.splitext(f)[0], "ext": ext,
                "interativo": False, "manifest": None,
            })

    if os.path.isdir(INTERATIVOS_DIR):
        vistos = set()

        for f in sorted(os.listdir(INTERATIVOS_DIR)):
            if not f.lower().endswith(".manifest.json"):
                continue
            nome = f[: -len(".manifest.json")]
            man = None
            try:
                man = json.load(open(os.path.join(INTERATIVOS_DIR, f), encoding="utf-8"))
            except Exception as e:
                man = {"erro_manifest": str(e)}
            vistos.add(nome.lower())
            itens.append({
                "pasta": "INTERATIVOS",
                "nivel_min": (man or {}).get("nivel", 4),
                "nome": nome, "ext": ".ps1",
                "interativo": True, "manifest": man,
            })

        for f in sorted(os.listdir(INTERATIVOS_DIR)):
            if not f.lower().endswith(".ps1"):
                continue
            nome = os.path.splitext(f)[0]
            if nome.lower() in vistos:
                continue
            man = None
            mp = os.path.join(INTERATIVOS_DIR, nome + ".manifest.json")
            if os.path.exists(mp):
                try: man = json.load(open(mp, encoding="utf-8"))
                except Exception as e: man = {"erro_manifest": str(e)}
            itens.append({
                "pasta": "INTERATIVOS",
                "nivel_min": (man or {}).get("nivel", 4),
                "nome": nome, "ext": ".ps1",
                "interativo": True, "manifest": man,
            })

    return itens

def enviar_inventario():
    try:
        itens = inventariar_scripts()
        r = api("POST", f"{HOME_URL}/fila/inventario",
                          json={"cliente": CLIENT_ID, "itens": itens},
                          headers=HEADERS, timeout=20)
        print(f"[agent] inventário enviado: {len(itens)} itens (http {r.status_code})")
    except Exception as e:
        print(f"[agent] erro inventário: {e}")

# ================= PROCESSAMENTO DE JOB (CHAMADO PELO POOL) =================
def processar_job(job):
    context = CURRENT_JOB.set(job["id"])
    """Processa um job individualmente - chamado pelo EXEC_POOL"""
    job_id, tipo, payload = job["id"], job["tipo"], job["payload"]
    print(f"[agent] job {job_id[:8]} tipo={tipo} exec={payload.get('execucao','-')}")

    try:
        # Notifica o backend com o nome resolvido, sem interferir no dispatcher abaixo
        if tipo == "executar" and payload.get("usuario"):
            registrar_display_name(job_id, payload["usuario"])

        if tipo == "auth_step1":
            resultado = step1_privacyidea(payload["user"], payload["password"])
            status = "concluido" if resultado.get("ok") or resultado.get("otp_necessario") else "erro"
        elif tipo == "auth_step2":
            resultado = step2_privacyidea(payload["user"], payload["otp"], payload["transaction_id"])
            status = "concluido" if resultado.get("ok") else "erro"
        elif tipo == "executar":
            payload["_iniciado_em"] = datetime.now().isoformat()
            resultado = executar(job_id, payload)
            status = "concluido" if resultado.get("ok") else "erro"
            gravar_log_json(job_id, payload, status, resultado.get("linhas", []))
            resultado.pop("linhas", None)
        elif tipo == "ad_buscar":
            resultado = buscar_ad(payload.get("termo", ""), payload.get("tipo", "usuario"))
            status = "concluido"
        elif tipo == "windows_sessions":
            resultado = consultar_sessoes_windows(payload.get('hostname',''))
            status = "concluido" if resultado.get('ok') else "erro"
        else:
            resultado = {"erro": f"Tipo desconhecido: {tipo}"}
            status = "erro"
    except Exception as e:
        print(f"[agent] exceção job {job_id}: {e}")
        resultado = {"erro": f"Erro interno: {e}"}
        status = "erro"

    try:
        api("POST", f"{HOME_URL}/fila/resultado/{job_id}",
                      json={"status": status, "resultado": resultado},
                      headers=HEADERS, timeout=15)
        print(f"[agent] {job_id[:8]} → {status}")
    except Exception as e:
        # Não repetir ação: o backend manterá resultado desconhecido para reconciliação.
        print(f"[agent] FALHA ao enviar resultado {job_id}: {e}")
    finally:
        with RUNNING_LOCK:
            RUNNING.pop(job_id, None)
        CURRENT_JOB.reset(context)
        
     

# ================= IDENTIDADE / PRONTIDÃO / SUPERVISÃO =================
def carregar_identidade():
    global AGENT_TOKEN, IDENTITY
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    if TOKEN_FILE.exists():
        IDENTITY = json.loads(TOKEN_FILE.read_text(encoding="utf-8"))
    else:
        code = os.environ.get("AGENT_ENROLLMENT_CODE", "")
        if not code:
            raise RuntimeError("Primeira execução exige AGENT_ENROLLMENT_CODE de uso único")
        r = requests.post(HOME_URL + "/fila/enroll", json={"code": code}, timeout=20)
        r.raise_for_status()
        IDENTITY = {**r.json(), "home_url": HOME_URL}
        with open(TOKEN_FILE, "x", encoding="utf-8") as f:
            json.dump(IDENTITY, f, ensure_ascii=False)
        if os.name != "nt": TOKEN_FILE.chmod(0o600)
        os.environ.pop("AGENT_ENROLLMENT_CODE", None)
    if IDENTITY.get("home_url") != HOME_URL or IDENTITY["client_id"] != CLIENT_ID:
        raise RuntimeError("Identidade pertence a outro backend/cliente")
    AGENT_TOKEN = IDENTITY["agent_token"]


def prontidao():
    problems = []
    if not shutil.which("pwsh"): problems.append("pwsh ausente")
    if not os.path.isdir(SCRIPTS_DIR): problems.append("repositório inacessível")
    if "winrm" in CAPABILITIES:
        try:
            with open(EXECUTAR_WINRM,"rb") as script: script.read(1)
            os.listdir(LOCAL_DIR)
        except OSError: problems.append("Executar-WinRM/N1 sem acesso de leitura")
    if "local" in CAPABILITIES:
        try: os.listdir(INTERATIVOS_DIR)
        except OSError: problems.append("Interativos inacessível")
    if not problems and set(CAPABILITIES) & {"auth", "ad"}:
        try:
            r = subprocess.run(["pwsh", "-NoProfile", "-Command", "Get-Command Get-ADUser -ErrorAction Stop | Out-Null"], capture_output=True, timeout=15)
            if r.returncode: problems.append("RSAT/Get-ADUser indisponível")
        except Exception: problems.append("sonda PowerShell falhou")
    for capability, executable, variable in [("gam", "gam", "GAM_PATH"),("gcds", "sync-cmd", "GCDS_PATH"),("winget", "winget", "WINGET_PATH")]:
        if capability in CAPABILITIES and not (shutil.which(executable) or os.path.isfile(os.environ.get(variable,""))):
            problems.append(capability + " indisponível na conta do serviço")
    return not problems, "; ".join(problems) or "sondas das capacidades aprovadas; validar permissões na máquina de teste"


def probe_loop():
    while True:
        try: ready, diagnostic = prontidao()
        except Exception: ready, diagnostic = False, "sonda falhou"
        with PROBE_LOCK: PROBE.update(ready=ready, diagnostic=diagnostic, at=time.time())
        time.sleep(20)


def runtime_versions():
    return {"python_version": platform.python_version(),
            "python_bits": sys.maxsize.bit_length() + 1,
            "requests_version": requests.__version__}


def heartbeat_loop():
    global DESIRED, SERVER_SLOTS, CAPABILITIES, INVENTORY_WRITER
    while True:
        try:
            with PROBE_LOCK: probe = dict(PROBE)
            ready = probe["ready"] and time.time()-probe["at"] < 45
            diagnostic = probe["diagnostic"] if time.time()-probe["at"]<45 else "sonda não concluiu; novas entregas suspensas"
            with RUNNING_LOCK: running = dict(RUNNING)
            data = api("POST", HOME_URL + "/fila/heartbeat", json={"ready": ready, "diagnostic": diagnostic, "version": VERSION, "boot_id": BOOT_ID, "capacity": MAX_WORKERS, "running": running, "control_protocol": 1, **runtime_versions()}, timeout=20).json()
            DESIRED = data["desired"] if ready or data["desired"] == "stop" else "drain"
            SERVER_SLOTS = data["slots"]
            CAPABILITIES = data["capabilities"]
            INVENTORY_WRITER = data["inventory_writer"]
            missing = set(running) - set(data["renewed"])
            if missing: print("[agent] reserva não renovada; NÃO repetir ações; confira reconciliação no painel")
        except Exception as e:
            if DESIRED != "stop": DESIRED = "drain"
            print(f"[agent] heartbeat indisponível: {type(e).__name__}")
        time.sleep(20)


def comunicar_saida():
    with RUNNING_LOCK:
        if RUNNING: return False
    result = api("POST", HOME_URL + "/fila/stopped", timeout=20).json()
    return result.get("ok") is True and result.get("desired") == "stop"


def loop():
    carregar_identidade()
    print(f"[agent] {IDENTITY['agent_id']} · {CLIENT_ID} · versão {VERSION}")
    print(f"[agent] Repositório: {SCRIPTS_DIR}")
    threading.Thread(target=probe_loop, daemon=True).start()
    threading.Thread(target=heartbeat_loop, daemon=True).start()
    last_inv = 0
    while True:
        try:
            if DESIRED == "stop":
                if comunicar_saida():
                    EXEC_POOL.shutdown(wait=True)
                    print("[agent] saída solicitada pelo painel; retomada exige iniciar a tarefa no Windows")
                    return
                time.sleep(2); continue
            if INVENTORY_WRITER and time.time() - last_inv > 60:
                enviar_inventario(); last_inv = time.time()
            with RUNNING_LOCK: free = len(RUNNING) < min(MAX_WORKERS, SERVER_SLOTS)
            if DESIRED != "active" or not free:
                time.sleep(2); continue
            r = api("GET", HOME_URL + "/fila/proximo", timeout=15)
            if r.status_code == 204:
                time.sleep(2); continue
            job = r.json()
            with RUNNING_LOCK: RUNNING[job["id"]] = job["execution_token"]
            EXEC_POOL.submit(processar_job, job)
        except Exception as e:
            print(f"[agent] polling indisponível: {type(e).__name__}"); time.sleep(5)


if __name__ == "__main__":
    if "--enroll-only" in sys.argv:
        carregar_identidade()
        print("Identidade inscrita; token salvo na pasta protegida.")
    else:
        loop()
