# Manutenção permanente — TJPB

O APP4 hospeda uma tarefa separada do executor: `Magbel-Manutencao-manutencao-tjpb-app4`. Ela inicia com o Windows, usa uma conta de domínio no Agendador e mantém o conector ativo sem sessão interativa ou MFA de um usuário humano. O painel continua exigindo administrador original para solicitar atualizações. Não é um serviço SCM; a supervisão usa o Agendador, como nos agentes existentes.

Credencial de API exclusiva do serviço, independente do token dos agentes, do proprietário e do CortenDesk. O backend guarda somente hash; a inscrição é de uso único e vence em 10 minutos. No APP4, a credencial é protegida com DPAPI LocalMachine e ACL privada. A proteção não impede um administrador local autorizado de acessar os dados; a ACL é necessária porque DPAPI LocalMachine permite descriptografia por processos que obtenham o blob na mesma máquina. Nenhuma senha Windows é enviada ao backend ou gravada pelo instalador em arquivos. A senha da tarefa é gerenciada pelo Agendador do Windows.

## 1. Backend no DietPi

Atualize facilitador-core pelo Git, prepare a imagem e recrie as duas réplicas na stack existente. Preserve todas as variáveis. Não há variável nova para o serviço permanente. Recarregue nginx e execute os validadores de deploy e suporte. Frontend desta entrega: 20261022c. A inscrição do serviço fica no painel Agentes → Atualizações dos agentes → Cadastrar serviço permanente.

## 2. Pré-requisitos no APP4

PowerShell 7 e Python existente em `C:\Program Files\Python315\python.exe`. O instalador não baixa nem troca a versão do Python. A conta `tj-pb\facilitador-servico` precisa dos direitos já aprovados para execução em lote no APP4 e manutenção via WinRM nos APPs autorizados. Não são concedidos grupos, direitos de domínio, TrustedHosts ou CredSSP automaticamente. A conexão remota usa Microsoft.PowerShell/Kerberos; não habilite outro endpoint.

O runtime de manutenção e seu ambiente virtual são separados do runtime do agente. Instalar o conector não para nem reinscreve o executor APP4 e não muda sua configuração.

## 3. Cadastrar no painel

Use:

- Identidade: `manutencao-tjpb-app4`
- Máquina: `facilitadorapp4.tjpb.jus.br`
- Destinos: os hostnames exatos de APP1–4 cadastrados no painel, separados por vírgula.

Guarde o código somente até a instalação. O serviço pode reservar e informar progresso de atualizações previamente solicitadas por um administrador e consultar o estado dos destinos autorizados. Não pode cadastrar agentes, criar atualizações, editar contratos, acessar credenciais ou executar ações comuns da fila.

## 4. Preparar e instalar da SEDE153729

Execute o bloco inteiro no PowerShell 7 da estação com a função `Sign-File` e a chave privada. A cópia do preparador é assinada fora do checkout. O pacote assinado contém hashes fixados dentro do instalador; o transporte remoto é conferido no APP4 antes de usar os arquivos.

```powershell
$ErrorActionPreference = 'Stop'
$Repo = '\\facilitadorapp1\c$\Magbel\rdgen'
git -C $Repo pull --ff-only
if ($LASTEXITCODE -ne 0) { throw 'Git interrompido; preservar alterações locais antes de continuar.' }
$Source = Join-Path $Repo 'facilitador-agent'
$Stamp = (Get-Date -Format yyyyMMdd-HHmmss) + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
$Preparador = Join-Path $env:TEMP ('magbel-preparar-permanente-' + $Stamp + '.ps1')
$Pacote = Join-Path 'C:\Magbel\pacotes' ('manutencao-permanente-' + $Stamp)
Copy-Item -LiteralPath (Join-Path $Source 'preparar-manutencao-permanente.ps1') -Destination $Preparador
Sign-File $Preparador
$Assinatura = Get-AuthenticodeSignature -LiteralPath $Preparador
if ($Assinatura.Status -ne 'Valid') { throw 'Assinatura do preparador não validada.' }
& $Preparador -SourceRoot $Source -Destination $Pacote -CertificateThumbprint $Assinatura.SignerCertificate.Thumbprint
& (Join-Path $Pacote 'instalar-manutencao-remota.ps1') `
    -ComputerName 'facilitadorapp4.tjpb.jus.br' `
    -ServiceId 'manutencao-tjpb-app4' `
    -HomeUrl 'https://facilitador-tjpb.magbel.com.br' `
    -ClientId 'TJPB' `
    -PythonExe 'C:\Program Files\Python315\python.exe'
```

Informe o código de inscrição do serviço e a credencial Windows `tj-pb\facilitador-servico` quando solicitados. A credencial trafega pelo WinRM/Kerberos e por pipe privado no host, sem senha na linha de comando. O instalador verifica assinatura e hashes, cria pasta privada, ambiente isolado, inscrição DPAPI e tarefa; recusa sobrescrever uma instalação existente. Falhas preservam o runtime para conferência.

## 5. Conferir

```powershell
Invoke-Command -ComputerName facilitadorapp4.tjpb.jus.br -Authentication Kerberos -ScriptBlock {
    Get-ScheduledTask -TaskName 'Magbel-Manutencao-manutencao-tjpb-app4' |
        Select-Object TaskName,State,@{Name='Conta';Expression={$_.Principal.UserId}}
    Get-ScheduledTaskInfo -TaskName 'Magbel-Manutencao-manutencao-tjpb-app4' |
        Select-Object LastRunTime,LastTaskResult
    Get-Content 'C:\ProgramData\Magbel\Maintenance\manutencao-tjpb-app4\logs\maintenance.log' -Encoding UTF8 -Tail 20 -ErrorAction SilentlyContinue
}
```

O painel deve mostrar `facilitadorapp4.tjpb.jus.br (permanente)`. Aguarde concluir qualquer manutenção do conector interativo e encerre-o com Ctrl+C. Confirme que o contato permanente continua e execute um piloto em um APP ainda 2.0.3. Não reinstale código 2.0.4 só para testar: agentes já atualizados não precisam de nova inscrição. Se todos estão 2.0.4, a prova inicial é permanência do contato sem o console interativo; o próximo upgrade usará pacote homologado correspondente.

A nova rotina não atualiza o próprio serviço nem homologa versões externas automaticamente. Esta entrega mantém a referência 2.0.4 e o helper de atualização de 2.0.3 para 2.0.4. Versões futuras exigem publicação e instalação de pacote institucional assinado correspondente, sem chave privada nos APPs.

## Operação e recuperação

- Logs: 5 MiB por arquivo, três cópias. Runtime: `C:\ProgramData\Magbel\Maintenance\manutencao-tjpb-app4`.
- Uma manutenção por vez, drenagem, zero trabalhos, novo processo confirmado e rollback continuam iguais. A tarefa de manutenção não é encerrada pela atualização do executor APP4.
- Falha HTTPS transitória tenta restabelecer o conector, sem reivindicar novamente operações abandonadas. Operação sem atualização por 180 s fica desconhecida/drenada e exige conferência administrativa. Credencial revogada encerra o processo; não faz login administrativo automático.
- Revogar serviço no painel bloqueia a API imediatamente e marca operação em andamento para conferência. Desative a tarefa no Windows separadamente; revogar não apaga runtime/backup.
- Para reparar somente o registro da tarefa/credencial após falha, use o mesmo pacote assinado e instalador remoto com `-RepairTask`. Não pede outro código e preserva identity.json. Exige runtime completo, exatamente o mesmo pacote e tarefa parada. Não repare enquanto houver atualização em andamento.
- Conta de execução precisa confiar no certificado do helper. `Valid` sob seu usuário não comprova confiança sob outra conta; confira o log após a instalação. Distribua confiança pelo canal institucional aprovado.
- Ao voltar ao conector interativo, aguarde operações terminarem, desative a tarefa permanente e inicie o conector anterior. Nenhuma credencial de agente precisa ser rotacionada por isso.

Teste real de Windows/DPAPI, assinatura, Agendador e WinRM deve ser concluído no APP4. GitHub Actions bloqueado por cobrança não equivale a teste aprovado.
