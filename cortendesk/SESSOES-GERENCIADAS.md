# Sessões gerenciadas do Facilitador — CortenDesk 1.14.0

Extensão aditiva da console. Não troca a versão do RustDesk 1.5.0, não desabilita a máquina e não desconecta sessões de outros atendimentos. Somente as conexões marcadas por um lançamento gerenciado entram no fluxo.

## Funcionamento e evidência

O Facilitador registra um prazo na VPS antes de abrir o webclient. O portal entrega um lançamento de uso único, com segredo no fragmento e hash no banco. Após o login normal do atendente, o lançamento é consumido e fica vinculado à sua conta. A identidade enviada pelo webclient é `facilitador:<id-do-acompanhamento>`, enquanto o ID de origem é o `web-<id-do-usuário>` já usado pelo upstream. O vínculo exige também ID exato da máquina e horário de início. A senha/autorização do RustDesk continua necessária.

Ao encerrar ou expirar, a extensão marca **somente esses registros** de `AuditConnection` com `disconnect_requested_at`. O CortenDesk envia seus `conn_id` em `disconnect` no heartbeat do cliente; o mecanismo nativo repete a instrução não atendida após 60 segundos. Inclui controle remoto e canais auxiliares do mesmo atendimento, sem incluir conexões sem o marcador. O scheduler da VPS processa os prazos mesmo com o Facilitador ou sua aba fechados. O guard da janela gerenciada também aciona o botão nativo de desconexão e navega para uma página sem workers ao expirar, receber o pedido ou perder a validação da console.

Há latência: o scheduler roda por minuto e o cliente normalmente envia heartbeat aproximadamente a cada 15 segundos. Na janela, a verificação ocorre a cada 5 segundos e há um temporizador local para o prazo. Isso depende de os serviços e o cliente estarem operantes; não é uma promessa de corte de rede instantâneo. Um ciclo recente do scheduler é exigido para abrir sessões novas. Alertas/monitoramento do scheduler continuam importantes.

**Solicitado não significa encerrado.** O histórico só registra `closed_reported` após observar uma ou mais sessões correspondentes com `closed_at` e nenhuma ativa. Se não houver auditoria, permanece `not_observed`; em erro de comunicação, o Facilitador mantém o pedido pendente e tenta novamente. O campo `closed_at` é evidência do CortenDesk e pode vir da reconciliação de heartbeat/offline do upstream; não é uma confirmação física independente de todos os sockets do computador. Sessões não gerenciadas continuam exigindo encerramento manual.

## Ordem de implantação

1. Encerrar sessões de teste anteriores pelo webclient. Atualizar o checkout `magnani1/rdgen`, branch `master`, na VPS.
2. Executar `sudo bash /home/ubuntu/rdgen-magbel/cortendesk/scripts/prepare-session-bridge.sh`. Confere a marca ativa, prepara `/opt/cortendesk/session-bridge-1.0.0`, faz lint PHP com a imagem 1.14.0 e cria backup consistente do SQLite e metadados em diretório privado. Não troca a stack.
3. Comparar a stack ativa com `cortendesk/compose-session-bridge.yml` e aplicar na **stack existente**. Mantém os 29 destinos de branding; adiciona arquivos da extensão, troca apenas a fonte da view webclient e registra o provider no bootstrap. Preservar `CORTENDESK_RDGEN_URL`, ambiente local e volumes. A variável nova, sem segredo, é:

```yaml
      MAGBEL_SESSION_TOKEN_GROUPS: '{"facilitador-tjpb-sessoes":"TJPB"}'
```

Esse mapa limita os tokens **por nome** a um grupo na API nova. Não amplia a matriz de recursos do token. Para um futuro TJPE, usar outro nome/token e outro grupo. O token continua capaz de ler os recursos que a API original permite; não publicá-lo nem disponibilizá-lo a usuários.

4. Executar `sudo bash /home/ubuntu/rdgen-magbel/cortendesk/scripts/verify-session-bridge.sh`. A migração cria somente `magbel_support_sessions`. O verificador limpa caches/compila as views e lista rotas e schedule. Confirmar o ciclo automático de `magbel:sessions:sweep`; aguardar pelo menos um minuto para o primeiro ciclo. Não preencher manualmente o marcador de saúde para mascarar scheduler parado.
5. Em API Tokens do portal, criar **outro token**, com nome exato `facilitador-tjpb-sessoes`, Devices **Read**, Audit logs **Read/Write**, demais **None**, validade de 90 dias. O token anterior de inventário permanece com Devices Read. O escopo de auditoria de escrita é exigido pelas novas rotas de desconexão; não usar um token global com todas as permissões.
6. Atualizar/preparar o core no DietPi e repassar `CORTENDESK_SESSION_TOKEN=${CORTENDESK_SESSION_TOKEN:-}` no Compose ativo do Dockge. Guardar o token novo somente no `.env`/segredo do backend. Recriar as duas réplicas e executar os validadores. A configuração vazia mantém o modo manual; não habilitar antes da VPS pronta.

Não cole tokens no chat ou no Git. O segredo de lançamento é mostrado somente ao abrir o atendimento, não vai ao histórico e não deve ser registrado em analytics. O token de automação nunca entra no navegador. A expiração/revogação do token ou remoção de seu mapeamento também solicita o encerramento das sessões vinculadas no próximo ciclo.

## Aceite real

- Abrir uma **nova** conexão pelo Facilitador. O endereço será `/magbel/connect` e depois `/magbel/webclient/<id>`, com login/MFA normal do portal. Não reaproveitar sessões abertas no `/webclient` antigo.
- Autorizar no cliente e conferir **Sessão ativa no cliente** no histórico. Sem auditoria, conferir o cliente e não tratar `not_observed` como sucesso.
- Clicar **Encerrar sessão** no Facilitador; verificar que a janela muda para encerrada e que o cliente recebeu a desconexão. O histórico passa de solicitação a encerramento registrado quando houver evidência.
- Abrir outra sessão e deixar vencer o prazo. Fechar a aba do Facilitador, mantendo o webclient, e conferir a desconexão pelo prazo salvo na VPS. Não alterar horários no banco de produção para acelerar o teste.
- Manter em paralelo uma conexão independente de teste e verificar que ela continua funcionando. Finalizá-la manualmente após o teste.
- Observar estado pendente quando a API estiver indisponível, sem simular falhas de rede em produção. Em caso de falha real, conferir a máquina e encerrar pelo cliente/webclient, sem declarar confirmação automática inexistente.

## Rollback

Desativar a configuração de sessão no Facilitador apenas **depois** de encerrar as sessões gerenciadas e manter a VPS processando os prazos pendentes. Para remover a extensão, restaurar os mounts do Compose 1.14.0 e retirar o provider/arquivos novos da stack, preservando banco e chaves. A tabela aditiva pode permanecer para auditoria. Não fazer rollback de banco como procedimento de rotina: isso apaga eventos posteriores ao backup. O snapshot privado contém segredos/metadados, não deve ser publicado.

Os testes de integração usam uma imagem e SQLite descartáveis e confirmam escopos, isolamento de grupo/token, lançamento único, correlação exata de canais, fila nativa de desconexão e expiração. Eles não substituem o aceite real com o cliente 1.5.0.
