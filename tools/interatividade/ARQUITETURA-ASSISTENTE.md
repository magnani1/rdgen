# Formularios e assistente de operacoes do Facilitador

## Estado desta entrega

Inclui analisador estatico AST, testes Windows PowerShell 5.1/PowerShell 7 e
levantamento dos arquivos recebidos. Nao instala IA, nao publica manifests,
nao altera agentes nem converte automaticamente GUI em backend. Relatorios
.analysis.json sao rascunhos, nao arquivos .manifest.json executaveis.

## Inventario recebido

| Arquivo | Interface constatada | Trabalho necessario |
| --- | --- | --- |
| Gerenciar_DHCP_TJPB.ps1 | 6 parametros de topo; criar/editar/deletar | Validacao condicional de acao, escopo, MAC e IP; consulta do estado antes de alterar; formulario e resumo de diferencas |
| Gerenciar_IoT_TJPB.ps1 | 4 parametros de topo; lote de MACs | Revisar parser, grupo autorizado e acao; mostrar previa do lote; confirmar criacao/edicao/exclusao |
| Gerar-CodigoMFA.ps1 | Usuario_Busca_MFA obrigatorio | Resolver usuario; autorizacao da operacao; proteger codigos e link Yopass, sem envia-los a IA |
| Gerenciar-VPN-SSO.backend.ps1 | Action ValidateSet + Payload JSON | Adaptador por operacao, plano e autorizacao do operador real; nao oferecer Payload como JSON livre |
| Gerenciamento-usuarios-gcds.ps1 | WinForms, dialogs e eventos; cerca de 2130 linhas | Separar pesquisar, criar, grupos, e-mail, MFA e lotes em operacoes com backend e autorizacao proprios |
| Gerenciar_GWS_TJPB.ps1 | GUI sem param de topo | Extrair backend e contratos de operacao antes de montar formulario |
| Modulo_Impressoras.ps1 | WinForms; parametro AdNome; remoting | Formulario e adaptador por operacao; destinos/permissoes e resultados estruturados |
| Password.ps1 | WinForms; reset/ativacao de conta e politicas AD | Backend com verificacao do alvo, plano, confirmacao e transporte protegido de resultados; nao colocar senha na fila ou IA |

O menu tem 62 entradas em Modulo_N1, 26 em N2, 9 em N3, 13 em Gestao e
13 em Admin, incluindo atalhos e navegacao. O mesmo GCDS aparece em N2 e N3
com caminho N3. Ha motor_n2 visivel em N1. Portanto modulo, cor e pasta NAO
sao regras suficientes de autorizacao. A configuracao vigente do backend,
SIDs e permissoes da operacao permanecem a autoridade.

VPN/SSO usa WindowsIdentity.GetCurrent para consultar grupos do operador.
Rodando sob facilitador-servico, isso identifica a conta de servico, nao quem
clicou no painel. Antes de integrar change/authorize-plan, o servidor precisa
validar o operador autenticado e o plano por operacao e grupos permitidos.
Nunca aceitar uma identidade de operador escrita livremente pelo cliente/LLM.

## Deteccao e conversao

1. Parser AST no Windows, sem executar PS1, defaults ou Get-Command no script.
2. Extrair parametros de topo, tipos, Mandatory e ValidateSet literais.
3. Detectar chamadas estaticas a Read-Host, Get-Credential, GUI e codigo dinamico.
   Sinais e linhas nao incluem fonte, defaults nem valores de credenciais.
4. Gerar campos candidatos somente para tipos simples e nao sensiveis. Switch,
   arrays, SecureString/PSCredential e Payload opaco exigem adaptador.
5. Revisao administrativa vincula campos, hash do script e politica da operacao.
   O inventario atual do agente exige manifests explicitos em INTERATIVOS.
6. Perguntas condicionais e GUI precisam virar fluxo estruturado. Um AST nao
   identifica com certeza todos os prompts em EXEs, imports, strings ou codigo
   gerado em runtime. Nao prometer execucao desacompanhada por ausencia de sinal.

## Assistente IA proposto

Fluxo: pedido -> acoes autorizadas -> proposta estruturada -> formulario ->
consulta/previa -> confirmacao vinculada aos dados -> revalidacao -> fila existente.
Alterar alvos/parametros invalida a confirmacao anterior. Revalidar nivel e
permissoes no backend tanto ao criar plano quanto ao confirmar a acao.

A IA escolhe somente IDs de operacoes cadastradas e sugere parametros permitidos.
Nao gera PowerShell para executar, nao faz tool calls no dominio e nao aprova a
propria proposta. Resposta desconhecida ou fora de esquema nao cria trabalho.
Mensagem exemplo: 'Entendi: configurar o scanner DNS informado em SEDE153729.
Vou consultar os componentes; instalar somente os ausentes; preservar outros
scanners e nao reinstalar componentes compativeis.' Isso e uma proposta, nao
um diagnostico. O estado real vem das consultas do agente.

Reaproveitar o provedor Magbel com base configuravel https://llm.magbel.com.br/v1,
API key separada do Facilitador no servidor e modelo selecionado dentre os IDs
reais de /v1/models. /models/chat e uma pagina, nao o contrato da API de execucao.
O contrato /chat/completions, autenticacao e modelo devem ser testados no ambiente
antes de ligar a integracao; os links publicos nao puderam ser consultados aqui.
Nao reaproveitar automaticamente auto:juridico para infraestrutura.

AnythingLLM pode fornecer manuais e procedimentos em workspace TJPB/Facilitador
isolado dos juridicos, com filtro de acesso no backend e documentos aprovados.
Credenciais de AD/GAM/DHCP, senhas, MFA, links Yopass, tokens e blobs de cofre nao
entram no prompt, embeddings ou logs da IA. Segredos ficam no executor/cofre.
A IA e opcional: indisponibilidade mantem formularios e operacoes manuais.

## Ordem de integracao

1. Analisador e inventario de metadados, sem habilitar execucao por inferencia.
2. DHCP/IoT: formularios, validacao e consultas/previa de mudancas.
3. Assistente de proposta com LLM configurado no servidor e confirmacao no painel.
4. MFA/Password/VPN com politica por operacao e operador real, resultados protegidos.
5. GWS/GCDS/Impressoras divididos em backends sem WinForms, aceites por operacao.

## Executar o analisador

Assinar copia institucional de analisar-scripts.ps1 e executar em Windows:

```powershell
& $Analisador -ScriptPath $Arquivos -MenuJson $Menu -OutputDirectory $Destino
```

Essas variaveis representam os arquivos locais escolhidos pelo administrador.
Nao apontar OutputDirectory para INTERATIVOS. Nao renomear relatorios como
.manifest.json. A ferramenta nao altera scripts nem niveis de acesso.
