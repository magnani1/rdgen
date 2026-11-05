# Guard: codigo final do runner

## Incidente comunicado

Em 04/11/2026, a tarefa `Facilitador_9e49f6fe21264503942342b587103a3c`
na SEDE153729 terminou com LastTaskResult 1. O script Epson registrou componentes
minimos presentes, mas o guard registrou `Codigo final do runner nao confirmado`.
O marcador de exclusao foi preservado. Os logs foram fornecidos pelo administrador;
nao houve acesso remoto do ambiente de desenvolvimento ao cliente.

## Correcao runner-owned-process-r3

O launcher passa a usar uma instancia propria de System.Diagnostics.Process com
UseShellExecute false, mantendo o handle desde Start ate a leitura do ExitCode.
Um cmd /d /s /c redireciona stdout/stderr para arquivos exclusivos e propaga o
codigo do engine PowerShell. Nao ha callbacks PowerShell em threads de saida.
O objeto so e descartado no finally. A observacao dos filhos/MSI e a exclusao
por computador continuam; nao ha encerramento generico de instaladores.

O resultado numerico tambem e preservado em runner-result.json. ExitCode ausente
continua bloqueando. Uma linha SUCESSO nao substitui essa evidencia nem comprova
digitalizacao. Esta mudanca nao recupera retroativamente o codigo do incidente.

## Validacao e publicacao

1. Na estacao de assinatura, atualizar o Git e copiar a pasta facilitador-agent
   para uma pasta de homologacao fora do checkout, preservando subdiretorios.
2. Assinar tests/test_guard_exit.ps1 e executar em PowerShell 7. O teste extrai
   somente a funcao launcher e usa processos locais inofensivos, cobrindo codigos
   0, 7 e 3010, encerramento rapido/demorado, Refresh e separacao stdout/stderr.
   Tambem foi incluido no CI em PowerShell 7 e Windows PowerShell 5.1.
3. Assinar o guard/worker da copia, copiar o runner institucional assinado e
   repetir testar-fila-guardada.ps1 em um destino livre. Nenhum instalador real.
4. Publicar pelo publicar-worker-serial.ps1 somente apos o aceite e ausencia de
   trabalhos ativos. Continuar com o certificado de producao 828D73E9B099D50DE42443ACEF7E224EE8D52A5D;
   sem troca de Python, reinscricao ou reinicio de agentes.

O ambiente de desenvolvimento nao tem PowerShell/Windows. Testes nativos e
publicacao no compartilhamento institucional precisam de execucao no Windows.

## Incidente anterior: reconciliar separadamente

Ready/LastTaskResult 1 e mensagem SUCESSO nao autorizam remocao automatica do marcador.
Antes de liberar, conferir a tarefa, processos associados e instaladores, ausencia
de MSI ativo e o marcador exato. Preservar a pasta e arquivar o marcador com uma
declaracao administrativa do resultado observado. Registrar resultado desconhecido
ou erro no painel, nunca sucesso retroativo sem evidencia. Nao apagar todos os
marcadores nem matar msiexec/setup para forcar repeticao. O procedimento de
reconciliacao e separado da correcao e nao ocorre automaticamente ao publica-la.

## Teste nativo comunicado pelo administrador

Na SEDE153729, o administrador executou o teste do commit
27db6b7854f59173a631505400265e7dbb96f69a e informou:
`Guard: saidas 0/7/3010, processo rapido/lento, Refresh e logs separados: OK`.
Isso valida o launcher isolado; nao substitui o aceite da fila guardada, a
publicacao assinada nem a reconciliacao do marcador anterior.

No CI, a fixture de manutencao falhou com Runtime configurado invalido antes
 de alterar tarefa/arquivos. TEMP usava o alias RUNNER~1, enquanto caminhos eram
 normalizados no PowerShell 5.1. A fixture agora usa o caminho longo real do TEMP
 e nomes de estado separados do bloco testado. Diagnosticos sao acrescentados
 apenas ao bloco sintetico; o helper de producao e suas validacoes permanecem
 inalterados. Verificacoes de apply/rollback, repeticao e preservacao nao foram
 relaxadas.
