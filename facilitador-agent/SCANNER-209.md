# Agente 2.0.9: parametro do scanner

O agente encaminha NomeScanner ao Executar-WinRM.ps1 por argumento separado,
sem interpolacao em comando PowerShell e sem gravar este campo no arquivo
global de parametros legado. O worker institucional ja aceita o argumento e
usa params.json privado. DNS vazio mantem a instalacao sem nova associacao.
Nome invalido e recusado antes de iniciar o worker. O backend parceiro valida
e normaliza o campo e nao entrega solicitacoes com DNS a agentes antigos.

## Atualizar o conector existente

Na estacao de assinatura, copiar preparar-scanner-209.ps1 fora do checkout,
assinar com o certificado institucional e executar com:

```powershell
& $Preparador -Repo $Repo `
    -CertificateThumbprint '828D73E9B099D50DE42443ACEF7E224EE8D52A5D' `
    -ComputerName 'facilitadorapp4.tjpb.jus.br' `
    -ServiceId 'manutencao-tjpb-app4' `
    -ConfirmarSemManutencaoAberta
```

Os nomes $Preparador/$Repo acima representam caminhos definidos pela estacao;
o comando exige primeiro copiar/assinar o preparador e conferir manutencoes abertas.
Ele monta pacote assinado novo, preserva backup/identidade do conector e para
somente sua tarefa durante a troca. Nao republica workers nem altera Python,
credencial de execucao, inscricao ou tarefa dos agentes.

Implantar antes o backend parceiro com MAINTENANCE_VERSION=2.0.9 e
AGENT_APPROVED_VERSION=2.0.9. Atualizar um agente por vez pelo painel a partir
da versao 2.0.8 homologada. O helper usa hashes exatos para apply e rollback.
Comecar pelo APP4 e validar contato/sondas/WinRM antes de expandir.

O guard runner-owned-process-r3 anteriormente publicado permanece necessario
para confirmar encerramento. A versao 2.0.9 nao corrige extracao WinGet em SYSTEM,
detecao do bundle Epson ou janelas de instaladores internos. O script institucional
DS-790WN.ps1 e seu pacote WinGet nao sao modificados nesta entrega.

Aceite: pelo formulario do Facilitador, escolher instalar/configurar, informar
DNS real, confirmar o resumo e conferir NomeScanner no log da execucao em
SEDE153729. Conferir codigo final, estado terminal e digitalizacao na sessao
do usuario. Testes automatizados nao executam instaladores reais.
