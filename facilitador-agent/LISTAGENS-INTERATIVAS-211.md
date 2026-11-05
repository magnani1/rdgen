# Listagens DHCP/IoT 2.0.11

Esta entrega adiciona consultas paginadas e somente leitura ao agente gerenciado.
Não executa o menu PS1 original, não altera AD/DHCP e não chama modelos de IA.

Requisitos: executor Windows executando sob a conta configurada em
`interativos_piloto.conta_execucao`, capacidade AD, módulo ActiveDirectory para
IoT e DhcpServer para DHCP, com permissões de leitura nos destinos autorizados.
As consultas usam a identidade do processo local e RSAT; não encaminham senha
ou token web ao PowerShell e não precisam de credenciais interativas.

Atualizar o checkout localmente, na máquina que o contém; não rodar Git via SMB.
Na estação de assinatura, preparar uma cópia assinada de
`preparar-listagens-211.ps1` e executá-la com os mesmos parâmetros usados no
preparador 2.0.10: Repo, CertificateThumbprint, ComputerName, ServiceId e
ConfirmarSemManutencaoAberta. O certificado atual pode ser mantido. A chave
privada fica na estação administrativa. Este preparo atualiza o pacote permanente
do conector; não atualiza automaticamente todos os executores.

Depois, no painel, atualizar primeiro um executor 2.0.9 ou 2.0.10 para 2.0.11.
Drenagem, zero trabalhos, hash de origem selecionada e backup continuam obrigatórios.
A origem de cada operação é passada ao helper para que o rollback restaure a
versão exata. Python, conta e inscrição permanecem. Confirmar novo heartbeat,
prontidão, identidade de serviço e leitura real antes de atualizar outro executor.

A listagem aceita somente servidor, OU, grupos e escopos fixados pelo backend.
Busca é literal, não um filtro LDAP. Página até 50; limite global de 2.000 contas
na OU e 4.096 reservas por escopo; exceder retorna falha explícita. Grupos IoT
mostram apenas associação direta aos perfis permitidos. Não confirma IP livre.

Validação automatizada: Python testa transporte/expiração/limites; PowerShell
5.1/7 testa cmdlets somente leitura com mocks, paginação, MAC, OU, grupos,
identidade e falhas. Esses testes não substituem o aceite na rede Windows real.
