# Aceite Windows — fila protegida e logs por execução

## Resultado comunicado pelo administrador

Origem: FACILITADORAPP1. Destino: facilitadorapp3.tjpb.jus.br.
Correção de referência: commit 351ceb531e7f15ea2e2a0998edc7474876532fe3, PR #40 (live-log-sharing-r2), testada em cópia isolada do worker.

Saída de regressão recebida:

```text
Worker: mensagens Kodak/genéricas e erros preservados, sem WinRM: OK
Linhas incompletas, truncamento, parser e exclusao de handles: OK
Leitura com gravador aberto, disputa exclusiva, retomada e cursor incremental: OK
```

Resultado final recebido:

```text
Computer           : facilitadorapp3.tjpb.jus.br
Serialized         : True
LogsIsolated       : True
InstallersExecuted : False
Logs               : C:\ProgramData\Magbel\HomologacaoFila\0a4527e2cd924be99999d1be72540a99
```

O administrador executou os testes no Windows e forneceu essa saída. Os arquivos completos de evidência permanecem no APP1; não foram acessados diretamente pelo ambiente de desenvolvimento. O registro não contém chave privada, senha ou token.

## Escopo aceito

- Regressão de leitura de logs com gravador aberto, disputa exclusiva, retomada e linhas parciais.
- Execução serial de duas tarefas inofensivas no mesmo destino pelo guard real.
- Logs privados sem mistura entre as duas tarefas.
- Conclusão do acompanhamento com a correção live-log-sharing-r2.
- Nenhum instalador executado pelo teste.

## Pendências antes de ampliar o uso

1. Distribuir apenas o certificado público do novo assinante aos Trusted Publishers de máquina dos executores e clientes do piloto; chave privada fica no APP1. A cadeia da CA precisa continuar válida e revogação ativa.
2. Publicar o worker/guard corrigidos no compartilhamento institucional após conferir ausência de trabalhos em andamento. O aceite acima usou cópia isolada e não comprova publicação global.
3. Validar execução a partir da conta definitiva dos agentes no piloto. A origem do teste acima foi a sessão administrativa do APP1.
4. Testar cancelamento da fila e estados no painel após implantar o frontend 20261029d; teste direto do worker não passa pela fila da API.
5. Revisar o código real do Kodak e homologar manifests/detecções dos pacotes WinGet. Este aceite não valida scanner, instalação, desinstalação ou cancelamento de MSI/EXE.

Não marcar automaticamente os demais aceites como concluídos nem promover toda a frota com base neste teste único.
