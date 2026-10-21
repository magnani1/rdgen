"""Assistente Windows: nenhum segredo passa pela GUI ou linha de comando.

O executável requer pacote institucional assinado ao lado dele. Não incorpora
certificados, tokens, scripts do cliente nem runtime do executor Python.
"""
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
from urllib.parse import urlsplit


VERIFY_SIGNATURES = r'''
$ErrorActionPreference='Stop'
try {
  $Files=@((Join-Path $env:MAGBEL_SETUP_PACKAGE 'instalar-agente.ps1'),(Join-Path $env:MAGBEL_SETUP_PACKAGE 'run-agent.ps1'))
  if ($env:MAGBEL_SETUP_EXE) { $Files += $env:MAGBEL_SETUP_EXE }
  $Signer=$null
  foreach ($File in $Files) {
    $Signature=Get-AuthenticodeSignature -FilePath $File
    if ($Signature.Status -ne 'Valid' -or -not $Signature.SignerCertificate) { throw 'Assinatura inválida ou publicador sem confiança.' }
    if ($Signer -and $Signer -ne $Signature.SignerCertificate.Thumbprint) { throw 'Os arquivos devem usar o mesmo certificado.' }
    $Signer=$Signature.SignerCertificate.Thumbprint
  }
  [Console]::Write('{"valid":true}')
} catch { [Console]::Error.Write('Não foi possível validar as assinaturas do pacote.'); exit 1 }
'''


def installation_args(pwsh, package, home_url, scripts_root, agent_id, client_id,
                      slots, python_exe, user_name=''):
    package = Path(package).resolve()
    for name in ('instalar-agente.ps1', 'run-agent.ps1', 'facilitador-agent.py', 'requirements.txt'):
        if not (package / name).is_file():
            raise ValueError(f'Arquivo ausente no pacote: {name}')
    url = urlsplit(home_url)
    if url.scheme != 'https' or not url.hostname or url.username or url.password or url.query or url.fragment:
        raise ValueError('Informe a URL HTTPS do Facilitador, sem credenciais, query ou fragmento.')
    if not re.fullmatch(r'[A-Za-z0-9_.-]{1,64}', agent_id):
        raise ValueError('Identidade do agente inválida.')
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', client_id):
        raise ValueError('Cliente inválido.')
    if not 1 <= int(slots) <= 16:
        raise ValueError('Escolha de 1 a 16 vagas.')
    if not scripts_root.startswith('\\\\'):
        raise ValueError('Informe o compartilhamento UNC dos scripts.')
    if not Path(python_exe).is_file():
        raise ValueError('Selecione o python.exe 3.12+ x64 acessível à conta da tarefa.')
    args = [str(pwsh), '-NoProfile', '-File', str(package / 'instalar-agente.ps1'),
            '-PackageRoot', str(package), '-SignedLauncherPath', str(package / 'run-agent.ps1'),
            '-HomeUrl', home_url.rstrip('/'), '-ScriptsRoot', scripts_root,
            '-AgentId', agent_id, '-ClientId', client_id.upper(), '-Slots', str(int(slots)),
            '-PythonExe', str(python_exe), '-PromptRunAsCredential']
    if user_name:
        args += ['-RunAsUserName', user_name]
    return args


def verify_package(pwsh, package, executable=None):
    env = os.environ.copy()
    env['MAGBEL_SETUP_PACKAGE'] = str(Path(package).resolve())
    env['MAGBEL_SETUP_EXE'] = str(executable or '')
    result = subprocess.run([pwsh, '-NoProfile', '-NonInteractive', '-Command', '-'],
                            input=VERIFY_SIGNATURES, text=True, capture_output=True,
                            env=env, timeout=30, creationflags=subprocess.CREATE_NO_WINDOW)
    if result.returncode or '"valid":true' not in result.stdout:
        raise ValueError('Assinatura inválida, arquivo modificado ou certificado sem confiança. Confira o pacote institucional.')


def main():
    import ctypes
    import tkinter as tk
    from tkinter import ttk, filedialog, messagebox
    root = tk.Tk()
    root.title('Magbel · Instalar agente Facilitador')
    root.geometry('820x650')
    root.minsize(700, 620)
    if os.name != 'nt' or not ctypes.windll.shell32.IsUserAnAdmin():
        messagebox.showerror('Administrador necessário', 'Abra o assistente como administrador no Windows.')
        root.destroy()
        return
    package = Path(sys.executable).parent if getattr(sys, 'frozen', False) else Path(__file__).parent
    frame = ttk.Frame(root, padding=24)
    frame.pack(fill='both', expand=True)
    ttk.Label(frame, text='Instalar agente Facilitador', font=('Segoe UI', 20, 'bold')).pack(anchor='w')
    ttk.Label(frame, text='Novo agente permanece drenado até a validação no painel.').pack(anchor='w', pady=(4, 14))
    fields = {}
    defaults = [
        ('package', 'Pasta do pacote assinado', str(package)),
        ('home_url', 'Endereço do Facilitador', 'https://facilitador-tjpb.magbel.com.br'),
        ('scripts_root', 'Compartilhamento de scripts', r'\\facilitador.tjpb.jus.br\facilitador_storage$\Scripts'),
        ('agent_id', 'Identidade desta máquina', socket.gethostname().lower()),
        ('client_id', 'Cliente', 'TJPB'), ('slots', 'Vagas', '2'),
        ('python_exe', 'Python do agente (3.12+ x64)', shutil.which('python') or ''),
        ('user_name', 'Conta da tarefa (DOMÍNIO\\usuário)', ''),
    ]
    for name, label, default in defaults:
        row = ttk.Frame(frame)
        row.pack(fill='x', pady=4)
        ttk.Label(row, text=label, width=31).pack(side='left')
        value = tk.StringVar(value=default)
        fields[name] = value
        ttk.Entry(row, textvariable=value).pack(side='left', fill='x', expand=True)
        if name in ('package', 'python_exe'):
            def choose(n=name, v=value):
                selected = filedialog.askdirectory() if n == 'package' else filedialog.askopenfilename(filetypes=[('Python', 'python.exe')])
                if selected:
                    v.set(selected)
            ttk.Button(row, text='Escolher', command=choose).pack(side='right', padx=(6, 0))
    ttk.Label(frame, wraplength=730, text='A senha da conta e o código de inscrição serão solicitados no PowerShell. '
              'O assistente não recebe esses segredos. Git não é necessário no destino. '
              'O executor ainda exige Python e PowerShell instalados, acesso ao compartilhamento e permissões de domínio.').pack(anchor='w', pady=16)
    status = tk.StringVar(value='Confira os dados e use o pacote assinado pela instituição.')
    ttk.Label(frame, textvariable=status, wraplength=730).pack(anchor='w', pady=8)
    process = None

    def poll():
        nonlocal process
        code = process.poll()
        if code is None:
            root.after(500, poll)
            return
        install.configure(state='normal')
        if code == 0:
            status.set('Instalador concluído. Confira a tarefa, o log e a prontidão no painel antes de ativar.')
            messagebox.showinfo('Conferir agente', 'Confira heartbeat, identidade da tarefa, UNC e WinRM. O agente deve permanecer drenado até o aceite.')
        else:
            status.set(f'Instalação interrompida (código {code}). Confira o erro e o estado da tarefa antes de tentar novamente.')
        process = None

    def start():
        nonlocal process
        try:
            pwsh = shutil.which('pwsh')
            if not pwsh:
                raise ValueError('PowerShell 7 não encontrado. Instale Microsoft.PowerShell e reabra o assistente.')
            data = {key: value.get().strip() for key, value in fields.items()}
            if not data['user_name']:
                raise ValueError('Informe a conta de domínio da tarefa.')
            args = installation_args(pwsh, **data)
            verify_package(pwsh, data['package'], sys.executable if getattr(sys, 'frozen', False) else None)
            process = subprocess.Popen(args, creationflags=subprocess.CREATE_NEW_CONSOLE)
            install.configure(state='disabled')
            status.set('Conclua as solicitações na janela PowerShell. Não feche essa janela durante a instalação.')
            root.after(500, poll)
        except (ValueError, OSError, subprocess.SubprocessError) as error:
            messagebox.showerror('Conferir instalação', str(error))

    def close():
        if process and process.poll() is None:
            messagebox.showinfo('Instalação em andamento', 'Aguarde a conclusão ou encerre conscientemente pela janela PowerShell. Fechar o assistente não é rollback.')
            return
        root.destroy()

    install = ttk.Button(frame, text='Conferir assinaturas e instalar', command=start)
    install.pack(anchor='e', pady=10)
    root.protocol('WM_DELETE_WINDOW', close)
    root.mainloop()


if __name__ == '__main__':
    main()
