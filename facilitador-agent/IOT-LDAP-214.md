# Correção da conferência IoT — 2.0.14

A conferência IoT deixa de chamar Get-ADAccountAuthorizationGroup. No ambiente
TJPB esse comando falhou com a conta facilitador-servico mesmo após a delegação
de leitura de tokenGroupsGlobalAndUniversal. A consulta LDAP recursiva, com as
mesmas credenciais, encontrou Senha_Simples e Impressoras_IoT.

A nova consulta usa Get-ADGroup e LDAP_MATCHING_RULE_IN_CHAIN, limitada à OU de
grupos configurada e ao servidor AD fixo. O DN é escapado como valor de filtro
LDAP. O grupo primário é resolvido pelo SID e incluído, junto aos seus grupos
ancestrais, para não perder vínculos que MemberOf não apresenta.

As regras de criar/reparar/editar/migrar/remover/excluir permanecem as descritas
em ESCOPOS-IOT-213.md. Migração e remoção continuam bloqueadas para vínculos
indiretos ou primários conflitantes. O fingerprint agora inclui os perfis
efetivos ordenados: uma alteração em grupo aninhado exige nova conferência.
Falha de consulta nunca equivale a ausência de grupos nem autoriza escrita.

## Atualização

1. Publicar o backend com IOT_ACTION_VERSION e MAINTENANCE_VERSION 2.0.14.
   DHCP e consultas antigas continuam compatíveis com executores 2.0.13.
   O planejamento e a aplicação IoT exigem 2.0.14.
2. Atualizar o checkout rdgen e, na estação institucional de assinatura, assinar
   a cópia de preparar-iot-ldap-214.ps1 com o certificado institucional vigente.
   Executá-la com -CertificateThumbprint e -ConfirmarSemManutencaoAberta após
   conferir que não há operação de manutenção aberta no painel.
   A chave privada permanece na estação; o helper prepara e assina o conector.
3. Conferir contato do conector com pacote 2.0.14 e atualizar apenas um executor
   pelo painel. As origens 2.0.9 a 2.0.13 têm backup e rollback para o código exato;
   a referência de origem 2.0.13 é preservada no helper.
4. Após heartbeat e prontidão 2.0.14, abrir um resumo novo de REPARAR para o MAC
   de teste. A conferência deve mostrar a conta e Impressoras_IoT; Senha_Simples
   é uma política protegida, não um perfil apresentado para migração.
   Confirmar a aplicação e conferir o resultado antes dos outros executores.

O teste LDAP realizado no ambiente confirmou leitura; ele não prova permissão
para redefinir senha, habilitar/desbloquear ou alterar grupos. Uma eventual falha
de escrita precisa de diagnóstico da operação e delegação específica, sem
ampliar permissões apenas por causa do antigo comando de grupos.

Os testes de diretório usam cmdlets simulados em PowerShell 5.1 e 7. A leitura
do grupo primário e as operações de escrita ainda precisam de homologação no AD
real sob a identidade efetiva do executor.
