# Epson DS-790WN: instalacao condicional e cadastro separado

Fonte institucional recebido de `/dados/docker/winget/work/DS790WNInstall.cs`.
Nova versao candidata: **2026.11.5.1**. O pacote 2026.10.6.2 nao e alterado.
Esta pasta nao modifica agentes, workers, credenciais ou a stack Wingetty.

## Comportamento

- Consulta driver do modelo ES0246 >=6.7.81.0, Scan OCR >=3.0.6,
  Document Capture Pro >=3.3.25, Event Manager >=3.11.86,
  OCR Pro >=1.1.2 e EpsonNet Config >=4.9.11, nas duas visoes HKLM.
- Com todos presentes: nao executa instaladores nem reaplica perfil, firewall
  ou atalhos. Sem nome, preserva cadastros; com nome, so chama RegisterScanner.
- Cadastro existente do modelo e hostname (sem diferenciar caixa ou ponto final)
  e preservado. Cadastro novo usa es2utility /ADD e confirma ConnectInfo.dat,
  com backup anterior. Nao remove scanners anteriores nem prefere um por usuario.
- `/configure-only --nome DNS`: somente cadastro; exige driver instalado.
- `/reapply-profile`: opt-in explicito que executa novamente o setup oficial DCP.
  Nao e adicionado automaticamente pelo painel ou manifesto WinGet.
- Componentes ausentes: executa a etapa necessaria e confere novamente o inventario.
  O grupo DCP precisa dos tres componentes; somente DCP presente nao e suficiente.
- Logs novos por execucao em `C:\ProgramData\TJPB\WinGet\DS790WN\runs\<id>\`.
- Saidas 0, 3010 e erro preservadas. Nenhum 1603 e transformado em sucesso.

## Limite importante do Visual C++

A falha observada foi vc_redist.x86 14.40 recusando downgrade sobre 14.50.
Pular DCP quando seus tres componentes ja estao compativeis evita repetir essa
etapa no cenario observado. **Esta entrega nao corrige o bootstrapper oficial
quando DCP precisa ser instalado/reaplicado e ja existe VC++ mais novo.**
Nesse caso, o erro continua sendo erro. Precisamos analisar o Setup.ini e o log
DCP para separar/atualizar os pre-requisitos de forma suportada. Nao desinstalar
VC++, nao ignorar 1638/1603 e nao editar configuracoes desconhecidas.

A presenca de componentes e o registro DNS nao comprovam digitalizacao fisica,
preferencias por usuario, ausencia de janelas em instalacao limpa ou identidade
entre aliases DNS. Nomes diferentes nao sao fundidos so por terem o mesmo IP.

## Compilar e assinar no Windows

Na estacao de assinatura, atualizar este checkout Git. Copiar build-launcher.ps1
para uma pasta temporaria e assinar essa copia com o certificado atual antes de
executar sob AllSigned. Executar a copia com:

```powershell
& $Script -Destination $Destino -CertificateThumbprint '828D73E9B099D50DE42443ACEF7E224EE8D52A5D'
```

A copia precisa permanecer ao lado de DS790WNInstall.cs e .manifest: copiar os
3 arquivos para a mesma pasta temporaria. O compilador .NET Framework e usado;
nao requer instalar SDK e nao executa o launcher. A chave privada fica na estacao.
O destino deve ser novo; a assinatura deve retornar Valid. Transferir a pasta
assinada (EXE, CS, manifest, launcher-proof.json) ao ocs-prod.

## Montar release nova no ocs-prod

Copiar esta pasta de fonte Git revisada para uma pasta nova sob work. Nao
substituir work/DS790WNInstall.exe antigo. Exemplo de caminhos convencionados:
fonte em work/epson-idempotente; pasta assinada em work/epson-assinado-2026.11.5.1.

```bash
cd /dados/docker/winget
python3 work/epson-idempotente/build-package.py \
  --root /dados/docker/winget \
  --launcher /dados/docker/winget/work/epson-assinado-2026.11.5.1
```

O builder verifica hashes de EXE/fonte/manifest contra a evidencia gerada na
estacao e exige fonte correspondente. Essa verificacao de hashes **nao substitui
validacao criptografica Authenticode no Windows**. Preserva perfil exato e
AllUsers=1, recusa diretorio de versao existente, produz catalog.json e
release-proof.json dentro de packages/EPSON/TJPB.Epson.DS790WN/2026.11.5.1/x86.
Nao altera o catalogo atual nem chama APIs de publicacao. A publicacao depende
do procedimento real de registro do servidor, ainda nao fornecido nesta entrega.

## Aceite

1. Testes CI compilam launcher e testam todos os 64 estados de inventario,
   cadastro por modelo/hostname e rejeicao de DNS invalido; nao rodam instaladores.
2. No piloto, executar launcher assinado /check; todos os seis componentes devem
   constar. Nao usar Win32_Product para inventario.
3. Repetir /quiet sem nome com inventario completo: nenhum instalador ou alteracao
   de perfil/firewall/atalhos; log informa preservacao.
4. /configure-only --nome DNS_REAL: cadastro verificado; repetir com mesmo nome
   deve informar cadastro existente. Conferir outras entradas preservadas.
5. Testar fluxo normal /quiet --nome DNS_REAL, codigo final, reserva liberada,
   usuario atual, segundo usuario e digitalizacao real.
6. Antes de publicar para frota: testar instalacao limpa e componentes faltantes,
   incluindo VC++ ausente, igual e mais novo. O caso DCP faltante + VC++ mais novo
   permanece pendente ate tratar o bootstrapper oficial.

## Retomar montagem interrompida depois do rename

Algumas versoes antigas de Python retornam None em Path.rename. A montagem
inicial podia terminar machine.zip e falhar antes de produzir catalog.json.
O builder agora separa a renomeacao da atribuicao do caminho.

Se machine.zip ja existe, mas catalog.json e release-proof.json nao existem,
atualizar este fonte pelo Git e acrescentar --finalize-existing ao comando.
A retomada confere todos os membros e seus hashes contra os componentes de
origem e o launcher assinado, antes de produzir metadados novos. Nao recompacta,
nao modifica machine.zip, nao sobrescreve metadados existentes e nao publica.
Se houver arquivo pendente, membro adicional, duplicado, alterado ou origem
diferente, a retomada para sem criar o catalogo. Teste de regressao simula
Path.rename retornando None, alem de verificar preservacao e rejeicoes.

## Cadastrar a versao nova no Wingetty

`register-version.py` roda dentro do container Wingetty existente, em /app,
com seus modelos e sua configuracao. O modo padrao e somente consulta. --apply
valida o ZIP completo contra o SHA256 homologado
23a6771f584d5d88e7a96c51831ab3b8ab445ab47f3576fd93eed3d92c9ec0be,
exige a versao anterior 2026.10.6.2, faz backup consistente do SQLite com
integrity_check e salva o catalogo anterior em pasta privada da instancia.

Adiciona somente 2026.11.5.1. Todas as versoes anteriores e seus instaladores
permanecem no banco. O catalog.json de pacotes passa a apontar o registro ativo
DS790WN para a versao nova, como fazia update-ds790wn.py, preservando outros IDs.
Nao troca ds790wn-catalog.json nem altera os scripts antigos. Executar sem outra
publicacao concorrente. Versao nova existente e divergente bloqueia, sem sobrescrever.
Repetir uma publicacao identica retorna unchanged. Se o banco foi registrado mas
a escrita atomica do catalogo falhou, repetir reconhece o registro e completa
somente o catalogo. O backup indicado no resultado guarda o estado anterior.

Exemplo, a partir do host no diretorio da stack:

```bash
docker compose exec -T -w /app wingetty python - < FONTE_GIT/packages/epson-ds790wn/register-version.py
docker compose exec -T -w /app wingetty python - --apply < FONTE_GIT/packages/epson-ds790wn/register-version.py
```

Nao reinicia a stack nem modifica imagem, volumes, tokens ou certificado. Depois
conferir winget show --id TJPB.Epson.DS790WN --exact --source TJPB --versions,
seguido do piloto pelo Facilitador/SYSTEM. A validacao local ja feita cobre
componentes existentes e cadastro repetido; nao cobre scanner novo, digitalizacao
fisica ou DCP ausente com VC++ mais novo.

Testes de registro usam Flask-SQLAlchemy e SQLite reais em ambiente temporario,
com modelos equivalentes aos campos fornecidos pelo operador. Cobrem dry-run,
backup integro, preservacao da versao antiga, idempotencia, conflito de metadados,
falha no commit e recuperacao apos falha no catalogo. Nao acessam a instancia real.
