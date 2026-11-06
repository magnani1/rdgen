# Escopos DHCP e operações IoT — 2.0.13

DHCP: o painel consulta primeiro os escopos ativos autorizados (ID, nome e descrição),
filtra localmente enquanto o operador digita e exige seleção antes de solicitar
concessões dinâmicas ativas. O agente revalida o escopo selecionado no servidor.
Não busca concessões de todos os escopos ao abrir a tela. Nenhuma reserva é alterada.

IoT: adaptador com comandos fixos RSAT ActiveDirectory, identidade efetiva igual
à conta de serviço configurada, servidor fixo, OU de contas e OU de grupos delimitadas.
Dados são JSON por stdin; nenhum parâmetro vira comando PowerShell. Planos e aplicações
requerem executor 2.0.13. Consultas IoT antigas continuam disponíveis em 2.0.11/12.

A referência funcional foi app_iot.aspx e os blocos IOT_* de api_ad.aspx fornecidos
pelo administrador. Nenhum arquivo original, segredo, cofre ou chave foi incorporado.

| Operação | Regra preservada |
| --- | --- |
| Criar | MAC unicast, minúsculo na conta/UPN e senha; descrição obrigatória. Criar desabilitada com senha provisória aleatória forte; userWorkstations=NPSWIN2K12; adicionar Senha_Simples e perfil opcional; definir senha como MAC, PasswordNeverExpires e ativar. Duplicata é erro. |
| CSV | MAC;Descrição;Grupo, cabeçalho opcional, UTF-8, aspas e ponto e vírgula na descrição; grupo opcional, até 100 MACs distintos. Validação completa antes de escrever. |
| Editar | Alterar somente descrição. Não migrar grupos implicitamente. |
| Reparar | Exigir conta existente; garantir Senha_Simples, redefinir senha como MAC, marcar sem expiração, desbloquear e habilitar. Não criar conta ausente. |
| Migrar | Perfil de destino explícito. Adicionar destino antes de remover outros perfis diretos na OU IoT; preservar Senha_Simples, Senha_TJPB e grupos externos. Bloquear vínculo indireto conflitante. |
| Remover perfil | Remover apenas o perfil escolhido, preservando outros grupos e políticas. |
| Excluir | Conferir e excluir somente a conta IoT observada na OU autorizada. |

N1 consulta; N2, gestão autorizada ou administrador podem solicitar operações,
respeitando o nível mínimo e a simulação da ação no catálogo. A conta de serviço
precisa das delegações reais: a aplicação não concede permissões ao operador.

O resumo é seguido de conferência real, que não escreve no AD. A aplicação exige
confirmação do operador, mesma sessão, política vigente e plano ainda válido (5 min).
Um plano gera no máximo um trabalho de aplicação, inclusive com clique/requisição
repetidos. O agente verifica novamente todos os objetos, grupos e fingerprints de
GUID/uSNChanged/membros antes de começar e junto à escrita; estado diferente exige
novo plano. A validação final relê o AD. O registro do último logon é exibido na lista.

Uma falha após possível escrita preserva o trabalho como resultado desconhecido,
com recursos reservados; não repete nem remove contas automaticamente. Um lote não
é uma transação AD: registros anteriores podem ter sido aplicados. Criação que falha
antes de habilitar deixa a conta desabilitada para conferência. Nenhuma senha é enviada
pelo operador ou persistida no plano/resultado (o identificador MAC continua auditável).

Configuração em interativos_piloto, sem variáveis adicionais na stack:

```yaml
iot_base_dn: OU=Usuarios,OU=IOTs,OU=TJPB,DC=tjpb,DC=jus,DC=br
iot_grupos_base_dn: OU=Grupos,OU=IOTs,OU=TJPB,DC=tjpb,DC=jus,DC=br
grupos_iot_permitidos:
  - Tv-IoT
  - CFTV-IoT
  - wifi-IoT
  - Untrust
  - fort_vpn
  - VOIP
  - Impressoras_IoT
  - PLENO-IoT
```

A lista é administrativa: somente os perfis presentes nela aparecem como destinos.
Descrições e existência são consultadas no AD. Grupos de política de senha não podem
ser destinos. Sem iot_grupos_base_dn, OU=Grupos é derivada apenas quando a OU de contas
começa explicitamente por OU=Usuarios. Para outra estrutura, informar o DN completo.

Preparar o conector com preparar-escopos-iot-213.ps1, certificado institucional atual,
sem exportar chave. Origens: 2.0.9/10/11/12, backup e rollback para a origem exata.
Atualizar um executor e homologar com conta/dispositivo de teste antes dos demais.
Os testes automáticos usam cmdlets simulados em PowerShell 5.1 e 7, sem AD real.
