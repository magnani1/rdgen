# Magbel Facilitador Setup — assistente EXE inicial

Fonte: setup_assistant.py (Tkinter da biblioteca padrão). O executável abre um formulário, confere assinaturas e chama o instalador existente em console PowerShell 7. Solicita elevação pelo manifesto UAC; não altera ExecutionPolicy, direitos de domínio, certificados confiáveis nem regras WinRM.

## O que muda

- Preenche endereço HTTPS, origem UNC, identidade, cliente, vagas, Python e conta da tarefa.
- Exige instalar-agente.ps1 e run-agent.ps1 com assinatura Valid e mesmo certificado; em modo EXE exige também a assinatura do próprio EXE com esse certificado.
- Antes da instalação, usa Get-AuthenticodeSignature no Windows para validar cadeia/publicador. O teste de assinatura é executado sem receber nenhum segredo.
- Usa subprocess com lista de argumentos, sem shell, e abre o instalador com -File. O novo -PromptRunAsCredential faz o Get-Credential dentro do processo PowerShell, resolvendo a falha de PSCredential convertido em texto entre processos.
- Senha e código de inscrição são solicitados apenas no PowerShell; não são armazenados pelo assistente nem passados em argumentos.
- Preserva a identidade conforme as regras do instalador, bloqueia atualização de tarefa em execução e mantém agente novo drenado no servidor.

## Limites desta versão

É um assistente para o instalador, não um executor autossuficiente. Python 3.12+ x64 e PowerShell 7 continuam necessários para o agente; preferir Python acessível à conta definitiva. Não instala RSAT, não garante acesso UNC/WinRM, não provisiona cliente/contrato/stack, não assina arquivos no APP e não habilita gMSA. Não é atualizador automático nem licença offline. O pacote precisa vir pelo canal institucional: a assinatura dos scripts não assina automaticamente o Python e requirements externos. SHA256.json é conferência de transporte, não raiz de confiança. Pacote integral assinado e runtime incorporado são evolução posterior.

## 1. Produzir o EXE sem assinatura

A CI Windows validar-facilitador-agent.yml gera o artefato Magbel-Facilitador-Setup-nao-assinado após os testes. Conferir que o workflow do commit correto terminou e baixar o artefato pelo GitHub Actions. O artefato é temporário (14 dias), não release de produção.

Também é possível compilar localmente, em Windows, com fonte revisado, usando ambiente separado:

```powershell
$Repo = 'C:\Magbel\rdgen'
py -3.12 -m venv C:\Magbel\build-setup-venv
if ($LASTEXITCODE -ne 0) { throw 'Falha ao criar ambiente de build.' }
$BuildPython = 'C:\Magbel\build-setup-venv\Scripts\python.exe'
& $BuildPython -m pip install -r "$Repo\facilitador-agent\requirements-build.txt"
if ($LASTEXITCODE -ne 0) { throw 'Falha nas dependências de build.' }
& $BuildPython -m PyInstaller --clean --noconfirm --onefile --windowed --uac-admin `
    --name Magbel-Facilitador-Setup `
    --distpath C:\Magbel\build-setup\dist `
    --workpath C:\Magbel\build-setup\work `
    --specpath C:\Magbel\build-setup `
    "$Repo\facilitador-agent\setup_assistant.py"
if ($LASTEXITCODE -ne 0) { throw 'Build do EXE falhou.' }
```

O build usa Python 3.12 e PyInstaller 6.16.0 fixado. Esse Python é da interface empacotada; o agente pode usar o Python 3.14 já instalado. Não é necessário instalar outra versão no APP: compilar na estação de build ou baixar o artefato da CI.

## 2. Assinar na estação autorizada

Se você assinou os scripts de uma versão anterior, guarde essa cópia fora do checkout antes de atualizar. A assinatura não vale para fonte alterado. Atualize o fonte limpo; assine o preparador atualizado conforme o procedimento institucional. Não envie chave privada/PFX, senha ou token ao GitHub/chat.

```powershell
$Repo = 'C:\Magbel\rdgen'
$CertThumbprint = 'THUMBPRINT_DO_CERTIFICADO_INSTITUCIONAL'
& "$Repo\facilitador-agent\preparar-pacote-assinado.ps1" `
    -CertificateThumbprint $CertThumbprint `
    -AssistantExe 'C:\Magbel\build-setup\dist\Magbel-Facilitador-Setup.exe' `
    -Destination 'C:\Magbel\pacotes\facilitador-agent-assinado-002'
```

Se baixou o artefato da CI, usar seu caminho real em -AssistantExe. O preparador assina instalador, launcher e EXE na cópia de distribuição. A chave privada permanece na estação autorizada; não é exportada nem colocada no pacote. Não sobrescreve uma pasta de distribuição existente. A assinatura institucional e confiança no contexto da tarefa ainda precisam de validação no domínio.

## 3. Usar no APP1

Copiar a pasta inteira do pacote assinado para o APP1; não só o EXE. Abrir Magbel-Facilitador-Setup.exe, autorizar elevação pelo fluxo normal, selecionar Python 3.14 x64 e preencher a conta de execução. Conferir ID facilitadorapp1, cliente TJPB, URL e origem dos scripts. A conta pessoal pode ser usada no piloto já autorizado; produção deve usar identidade dedicada com direitos delegados.

Cadastrar esse ID no painel e gerar código próprio imediatamente antes de instalar. Clicar Conferir assinaturas e instalar. Na janela PowerShell, informar senha e inscrição. Se houver identidade existente, o instalador a preserva e pode não pedir código. Não copiar identidade do APP2.

Após conclusão: conferir tarefa, LogonType Password, log UTF-8, heartbeat e prontidão. Testar UNC e WinRM pela conta da tarefa antes de ativar. A mensagem de sucesso do instalador não confirma sucesso de uma ação remota real.

## Aceite e continuidade

Testes automatizados cobrem argumentos sem segredos/shell, entradas inválidas, pacote incompleto e falha de validação de assinatura. O teste Windows do instalador cobre versão Python, credencial, publicador do launcher, Unicode e exit code; o build gera o PE Windows. Não substituem abrir o EXE assinado e testar GPO/PKI/UNC/WinRM no APP1. Não declarar o piloto aprovado até esse aceite.

Depois do piloto: incorporar runtime do executor, garantir integridade assinada do pacote inteiro, oferecer diagnóstico acessível após falha, atualização com rollback, pacote WinGet e eventual MSI. Manter source, builds e assinaturas separados; não versionar identidade, venv, logs, códigos de inscrição ou certificado privado.

## Correção da verificação de assinatura

A consulta usa agora PowerShell -EncodedCommand com script estático UTF-16LE e relatório JSON UTF-8. Não transmite segredos nem desabilita ExecutionPolicy. Ausência de relatório, timeout e assinatura recusada têm mensagens distintas; a consulta continua exigindo assinatura Valid e mesmo certificado para os três arquivos. A CI Windows cria certificado descartável somente no runner, assina cópias de scripts e EXE e confirma aceitação do pacote e recusa de launcher alterado. Esse certificado nunca é distribuído nem incluído no artefato.
