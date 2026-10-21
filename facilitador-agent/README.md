# Facilitador Agent Windows 2.0.1

Executor Windows do Facilitador, separado do repositório do backend. Adaptado do agente fornecido pelo operador para identidade individual, limite de vagas, heartbeat e prontidão independentes, ownership da tentativa, drain e caminhos configuráveis.

Requer backend com `/fila/enroll` e `/fila/heartbeat` (entrega agentes/contratos/suporte de 21/10/2026), Python 3.12+ x64 (3.14 x64 recomendado para novas instalações), PowerShell 7, RSAT para autenticação/AD e os direitos efetivos das ações executadas. O instalador não concede esses direitos.

## Instalação

Cadastre o agente no painel administrativo do cliente; ele nasce drenado. Use o código de inscrição de 10 minutos. No APP correspondente, PowerShell elevado, a partir do checkout deste repositório:

```powershell
.\facilitador-agent\instalar-agente.ps1 `
  -HomeUrl 'https://facilitador-tjpb.magbel.com.br' `
  -ScriptsRoot '\\facilitador.tjpb.jus.br\facilitador_storage$\Scripts' `
  -AgentId 'facilitadorapp1' -ClientId 'TJPB' -Slots 2
```

Confirme o compartilhamento real e a identidade por host; repetir APP2–7 com IDs correspondentes e códigos próprios. Não copiar identity.json para outro cliente ou host. O agente mantém a identidade após reiniciar.

O instalador cria tarefa `Magbel-Facilitador-<id>` como SYSTEM, ambiente Python e pasta `C:\ProgramData\Magbel\FacilitadorAgent\<id>` protegida para SYSTEM/Administradores e, quando selecionada, leitura/execução pela identidade da tarefa; esta escreve apenas em Logs, Uploads e agent.log. Configuração e token ficam nessa pasta; não publicar nem anexar seus arquivos. Para CA interna em PEM, passar `-CaBundle <arquivo.pem>`; o bundle é combinado com as CAs públicas e usado na validação TLS. Não usar certificado DER nem desativar validação TLS.

SYSTEM acessa recursos da rede conforme os direitos da máquina/ambiente. O sucesso da sessão interativa do instalador não comprova esses direitos. Valide o compartilhamento, RSAT, WinRM e máquina de teste pela tarefa definitiva. Para uma conta de domínio com senha, usar -RunAsCredential (Get-Credential): a senha é entregue ao Agendador do Windows, sem gravá-la no config.json, arquivos do pacote ou Git. O logon Password permite autenticação na rede; S4U não é usado. Para gMSA, ainda é necessária adaptação específica com a equipe de domínio.

Depois da primeira sonda, verificar prontidão no painel e só então ativar. A publicação de inventário é atribuída pelo servidor a um agente; o parâmetro do navegador não altera essa autorização. GAM/GCDS/WinGet precisam existir no contexto da tarefa, podendo usar GAM_PATH/GCDS_PATH/WINGET_PATH no config.json privado.

## Operação

- Heartbeat a cada 20 s, separado da sonda. Sonda atrasada/inconclusiva suspende novas entregas sem bloquear renovação de trabalhos em andamento.
- Vagas locais e backend limitam a execução; o pool não acumula uma fila oculta. O backend atribui cliente, ID, pool e capacidades.
- Todo callback leva token da tentativa. Upload é restrito ao job aceito; o adaptador atual passa o arquivo como parâmetro `arquivo` para execução local. Upload remoto exige adaptador específico e falha explicitamente antes de executar.
- Drain para novas entregas e aguarda atuais. Encerramento abrupto, perda de resposta final ou timeout podem produzir resultado desconhecido; não repetir ação. Conferir destino e reconciliar no painel.
- Scripts antigos e Executar-WinRM continuam com seu dispatcher. Há serialização local no backend para proteger parâmetros globais. Essa proteção não cobre outro cliente em outra stack usando os mesmos arquivos/host.
- O Python não depende de D:. Scripts institucionais ainda podem depender de caminhos/ferramentas locais; validar antes da ativação. Os scripts da origem não são alterados.
- stdout/stderr do watcher vão ao log local por job, evitando bloqueio de pipe. O log remoto continua sendo enviado ao backend. Timeout local também funciona quando o processo não produz stdout.

Logs: agent.log (rotacionado na inicialização ao ultrapassar 10 MB), Logs/info_<job>.txt e Logs/watcher_<job>.txt. Revise a retenção conforme a operação. Não anexar logs sem verificar conteúdo sensível produzido pelos scripts.

## Atualização e rotação

Drenar, aguardar zero trabalhos e parar a tarefa. Atualizar checkout Git, executar novamente o instalador e iniciar/ativar. O instalador recusa atualizar tarefa em execução e preserva identidade existente. O backend emite código novo após rotação; para reinscrever, com a tarefa parada, guardar a identidade antiga em local privado e remover o identity.json ativo, depois executar o instalador com o código novo. Rotação no backend é recusada enquanto houver trabalho ativo.

O pacote ainda não tem assinatura de código, instalador MSI/WinGet ou atualizador automático. Avaliar a política de assinatura antes da distribuição ampla. As sondas de leitura não instalam software nem alteram contas como teste de disponibilidade.

Documentação completa de implantação/retirada do legado: https://github.com/magnani1/facilitador-core/blob/main/OPERACAO-AGENTES.md .

## Testes

```bash
python -m pip install -r facilitador-agent/requirements.txt
python -m unittest discover -s facilitador-agent/tests -v
python -m py_compile facilitador-agent/facilitador-agent.py
```

Os testes não executam scripts reais, WinRM, AD ou privacyIDEA. O workflow Windows também analisa a sintaxe do instalador; a validação funcional deve ocorrer no APP de teste com a conta definitiva.

## Correção 2.0.1 — identidade, Python e UTF-8

O teste do APP2 confirmou WinRM com a conta interativa, enquanto a tarefa padrão executava como SYSTEM. A inscrição e CLIENT_ID=TJPB funcionaram. Esta correção permite selecionar uma conta com direitos já delegados, sem alterar WinRM, grupos de administradores, TrustedHosts ou política de execução no destino.

Novos parâmetros: `-RunAsCredential <PSCredential>`, `-RecreateVenv`, `-SigningCertificateThumbprint <thumbprint>` e `-PackageRoot <pasta do pacote>`. Requer PowerShell 7 elevado. O instalador rejeita Python abaixo de 3.12 e interpretador de 32 bits; também verifica o venv existente. Instalar um Python novo não altera automaticamente o venv criado com 3.9.

`-RecreateVenv` preserva o venv anterior em `venv-before-...`, cria o novo no caminho definitivo e restaura o antigo se criação/dependências falharem. O token/identity.json não é apagado nem exige nova inscrição. A tarefa precisa estar parada após drain e zero trabalhos. Se a instalação falhar depois da preparação, a tarefa não é iniciada automaticamente; conferir a etapa que falhou antes de iniciar.

Python e PowerShell usam UTF-8 explícito; o log novo tem BOM para leitores antigos. O log anterior é arquivado em Logs. A correção não reinterpreta nem reescreve o histórico já corrompido.

Se o instalador estiver assinado, procura a mesma identidade de certificado com chave privada no CurrentUser/My ou LocalMachine/My e assina o launcher gerado. Pode-se informar outro thumbprint explicitamente. A cadeia e o publicador precisam ser confiáveis no contexto da tarefa. Não modifica ExecutionPolicy nem importa certificados de confiança automaticamente.

### Atualizar APP2 com a conta já testada

1. No painel, drenar APP2 e aguardar zero trabalhos. Em **pwsh elevado**, parar a tarefa:

```powershell
Stop-ScheduledTask -TaskName 'Magbel-Facilitador-facilitadorapp2'
```

2. Instalar Python 3.14 x64 (pode coexistir com 3.9 até concluir a migração):

```powershell
winget install --id Python.Python.3.14 --exact --source winget
$Py314 = (& py -3.14 -c 'import sys; print(sys.executable)').Trim()
& $Py314 --version
```

Se o launcher py ainda não reconhecer a instalação, abrir um novo pwsh elevado e repetir a identificação. Para conta dedicada diferente da conta instaladora, usar Python instalado para todas as contas e conferir acesso ao caminho base.

3. Preservar a assinatura local antes do pull. O stash guarda a alteração; não reaplicá-lo sobre o código novo. Manter o instalador assinado fora do checkout para os próximos pulls não conflitarem:

```powershell
$Repo = 'C:\Magbel\rdgen'
$Root = 'C:\ProgramData\Magbel\FacilitadorAgent\facilitadorapp2'
$OldInstaller = Join-Path $Repo 'facilitador-agent\instalar-agente.ps1'
$Thumbprint = (Get-AuthenticodeSignature $OldInstaller).SignerCertificate.Thumbprint
$Cert = $null
foreach ($Store in @('Cert:\CurrentUser\My','Cert:\LocalMachine\My')) {
    if ($Thumbprint) {
        $Candidate = Get-Item "$Store\$Thumbprint" -ErrorAction SilentlyContinue
        if ($Candidate -and $Candidate.HasPrivateKey) { $Cert = $Candidate; break }
    }
}
if (-not $Cert) { throw 'Selecione o certificado de assinatura habitual com chave privada antes de continuar.' }
git -C $Repo stash push -m 'assinatura-local-antes-v201' -- facilitador-agent/instalar-agente.ps1
if ($LASTEXITCODE -ne 0) { throw 'Falha ao preservar alteração local.' }
git -C $Repo pull --ff-only
if ($LASTEXITCODE -ne 0) { throw 'Pull interrompido; confira as alterações locais preservadas.' }
Copy-Item "$Repo\facilitador-agent\instalar-agente.ps1" "$Root\instalar-agente.ps1" -Force
$Signature = Set-AuthenticodeSignature -FilePath "$Root\instalar-agente.ps1" -Certificate $Cert -HashAlgorithm SHA256
if ($Signature.Status -ne 'Valid') { throw "Assinatura inválida: $($Signature.Status)" }
$Cred = Get-Credential -UserName ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -Message 'Conta para executar o agente APP2'
& "$Root\instalar-agente.ps1" `
  -PackageRoot "$Repo\facilitador-agent" `
  -HomeUrl 'https://facilitador-tjpb.magbel.com.br' `
  -ScriptsRoot '\\facilitador.tjpb.jus.br\facilitador_storage$\Scripts' `
  -AgentId 'facilitadorapp2' -ClientId TJPB -Slots 2 `
  -PythonExe $Py314 -RecreateVenv -RunAsCredential $Cred
$Cred = $null
(Get-ScheduledTask -TaskName 'Magbel-Facilitador-facilitadorapp2').Principal |
    Format-List UserId,LogonType
Get-Content "$Root\agent.log" -Encoding UTF8 -Tail 30
```

Esperado: Python 3.14 no venv, versão do agente 2.0.1, usuário selecionado e LogonType Password. Continua com o mesmo CLIENT_ID e identidade. Ativar após prontidão e testar um único destino; o sucesso na sessão interativa não substitui esse teste pela tarefa.

Usar a conta pessoal já validada é uma opção para o piloto. Para operação permanente, escolher uma identidade dedicada com os direitos necessários; se a conta usa senha e ela mudar, atualizar a credencial da tarefa. O instalador não adiciona grupos nem concede permissões nos destinos.

Validação adicional em Windows: Python 3.12/3.14, rejeição de versão/arquitetura incompatíveis, seleção de credencial versus SYSTEM, launcher real com Unicode e propagação de exit code. Não registra tarefas reais nem testa WinRM de produção nos testes automatizados.
