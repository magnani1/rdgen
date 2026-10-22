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
VERSION = "2.0.4"
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
                   "-RemoteLogPath", remote_log_path, "-LogFile", log_path, "-Programa", script_name]
            with open(os.path.join(LOG_DIR, f"watcher_{job_id}.txt"), "a", encoding="utf-8") as watcher_log:
                procs.append((subprocess.Popen(cmd, stdout=watcher_log, stderr=subprocess.STDOUT,
                                              text=True, encoding="utf-8", errors="replace"), alvo))  # ← UTF-8
        except Exception as e:
            enviar_log(job_id, f"[ERRO] Falha iniciando {alvo}: {e}")

    offset = 0; start_time = time.time(); timeout_hit = False; marker_at = None
    while any(p.poll() is None for p, _ in procs):
        if time.time() - start_time > TIMEOUT_EXECUCAO:
            enviar_log(job_id, "[AVISO] Timeout. Matando processos.")
            for p, _ in procs:
                if p.poll() is None:
                    try: p.kill()
                    except Exception: pass
            timeout_hit = True; break

        offset, novo = _ler_novo_e_enviar(job_id, log_path, offset)
        if novo and marker_at is None:
            up = novo.upper()
            if any(m in up for m in SUCCESS_MARKERS):
                marker_at = time.time()
                enviar_log(job_id, "[INFO] Marker de conclusão detectado no log.")
        # Conclusão confirmada há 30s e o watcher ainda preso? Encerra por conta própria.
        if marker_at and (time.time() - marker_at > 30):
            enviar_log(job_id, "[INFO] Conclusão confirmada no log; encerrando watcher.")
            for p, _ in procs:
                if p.poll() is None:
                    try: p.kill()
                    except Exception: pass
            break
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
    elif len(procs) != len(payload["alvos"]) or (not marker_at and any(p.poll() not in (0,None) for p,_ in procs)):
        resultado = {"ok": False, "linhas": linhas, "erro": "Executar-WinRM falhou; conferir log do watcher"}
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

# ================= DISPATCHER =================
def executar(job_id, payload):
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
