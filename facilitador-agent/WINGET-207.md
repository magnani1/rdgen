# Agente 2.0.7 — execução WinGet e preparação do conector

Esta entrega adiciona o adaptador `winget.v1` no executor e atualiza o pacote do conector para **2.0.7**. Não instala Python/dependências nem muda conta, tarefa ou inscrição dos executores. A instalação ocorre no cliente via WinRM padrão/Kerberos; o APP Server 2022 não recebe WinGet. O backend correspondente está no `facilitador-core`, marcador **20261023b**.

## Na SEDE153729

Usar PowerShell 7 **elevado**, com Git e acesso ao checkout APP1/WinRM APP4. A chave privada de assinatura continua somente na estação de assinatura. Primeiro implantar o backend correspondente e `AGENT_APPROVED_VERSION=2.0.7`. Conferir no painel que não há atualização aberta; não parar o conector durante uma aplicação cujo resultado ainda não foi conferido.

O bloco abaixo define todas as variáveis; não depende das sessões anteriores. A função institucional `Sign-File` deve estar disponível nessa sessão.

```powershell
$ErrorActionPreference = 'Stop'
$Repo = '\\facilitadorapp1\c$\Magbel\rdgen'
git -C $Repo pull --ff-only
if ($LASTEXITCODE -ne 0) { throw 'Git interrompido; preserve alterações locais.' }

$Work = Join-Path $env:TEMP ('magbel-winget-bootstrap-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Work | Out-Null
$Script = Join-Path $Work 'preparar-winget-207.ps1'
Copy-Item -LiteralPath (Join-Path $Repo 'facilitador-agent\preparar-winget-207.ps1') -Destination $Script
Sign-File $Script
if ((Get-AuthenticodeSignature $Script).Status -ne 'Valid') { throw 'Assinatura não validada.' }

& $Script `
    -Repo $Repo `
    -CertificateThumbprint '828D73E9B099D50DE42443ACEF7E224EE8D52A5D' `
    -ComputerName 'facilitadorapp4.tjpb.jus.br' `
    -ServiceId 'manutencao-tjpb-app4' `
    -ConfirmarSemManutencaoAberta
```

O preparador faz pull ff-only, recusa código diferente da referência, copia a fonte para uma pasta de trabalho, assina o preparador e gera um pacote institucional assinado fora do checkout. Para somente a tarefa de manutenção, aguarda Ready e chama o atualizador existente com backup. Em sucesso, o atualizador inicia a tarefa. Não cadastrar outro serviço, não rotacionar token e não encerrar executores manualmente. Uma falha após parar o serviço exige conferir estado/backup; não considerar apenas a ausência de saída como sucesso.

Depois, no painel: conferir pacote/conector 2.0.7 e atualizar **primeiro um executor** 2.0.6 → 2.0.7. O helper aceita somente a origem 2.0.6 homologada, preserva ambiente/identidade/configuração, drena/aguarda zero trabalhos e permite rollback para 2.0.6. Validar contato e WinRM antes de expandir para os demais; enfileirar todos não significa aplicação simultânea. O atualizador manual `atualizar-codigo-agente.ps1` desta entrega também exige origem 2.0.6; guias históricos 2.0.4/2.0.5 não descrevem este novo caminho.

Hash canônico UTF-8/LF do agente 2.0.7: `0ed87034b19c0a525915dd0baf08b709acdefeefc624e8902a0be8503b9ee22c`.

## No cliente do piloto

WinGet/App Installer precisa estar registrado na identidade WinRM da conta de serviço, e a fonte nome/URL/tipo deve corresponder ao catálogo. A CLI **não suporta SYSTEM**; não copiar executáveis de WindowsApps, mudar ACLs ou ignorar assinatura para forçar funcionamento. Fonte da sessão interativa não equivale à fonte da conta de serviço. Não há bootstrap/reparo silencioso ou fallback nesta implementação.

No Facilitador, cadastrar pacote de máquina com versão fixa e detecção exata em HKLM, aprovar e usar **Conferir cliente** antes de **Instalar no cliente**. Aceites de contratos são explícitos e auditados. Pacotes de usuário/MSIX e configuração de equipamentos exigem adaptadores/ações próprios. Fonte TJPB, instalador/versão e o cliente real ainda precisam ser selecionados e homologados.

Uma instalação só é confirmada com retorno zero e detecção exata. Falha após iniciar, timeout ou transporte inconclusivo não libera repetição; conferir pacote e processos no Windows e reconciliar no painel. Não há reinício automático. Saída nativa privada no cliente: `C:\ProgramData\Magbel\WingetJobs\<job_id>`; logs web recebem somente etapas/códigos controlados.

Guia completo: [OPERACAO-WINGET.md](https://github.com/magnani1/facilitador-core/blob/main/OPERACAO-WINGET.md). Validação nativa Windows/WinRM, assinatura do novo pacote e instalação real precisam ser executadas no ambiente institucional; testes Python com subprocessos simulados não substituem esse aceite.
