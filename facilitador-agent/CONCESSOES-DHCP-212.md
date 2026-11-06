# Concessões DHCP 2.0.12

Consulta somente concessões dinâmicas ativas (`AddressState=Active`) dos escopos
ativos autorizados. Reservas ativas/inativas, ofertas e expiradas ficam de fora.
Nenhuma concessão, reserva, conta, firewall ou preferência do cliente é alterada.

O protocolo `interactive_list` com kind `leases` recebe política fixa do backend:
servidor, conta efetiva, lista de escopos ou opção administrativa de descoberta.
A conta do processo deve coincidir exatamente com a configurada. Não há prompt
de credenciais. RSAT DhcpServer e permissões de leitura no servidor são necessários.

O adaptador retorna IP, identificador de cliente, hostname, descrição da concessão,
ID/nome/descrição do escopo e expiração UTC. Busca IP completo otimiza pelas máscaras
reais dos escopos; texto/MAC pesquisa todos os escopos autorizados. Consultas CIM
usam AsJob com throttle 8 e coletam falhas antes de produzir resultado completo.
Só os próprios jobs de consulta são limpos, sem encerrar processos genéricos.

Limites: 2.048 escopos, 200.000 registros examinados, 100.000 correspondências,
50 registros por página e timeout de 180s. Falha ou limite gera erro explícito.
Não retorna ausência bem-sucedida após erro nem lista parcial silenciosa.

`preparar-concessoes-212.ps1` prepara o pacote assinado do conector, com os mesmos
parâmetros do preparador anterior. Manter o certificado institucional atual e a
chave privada na estação administrativa. Atualizar o checkout no próprio APP1,
sem Git via SMB. Executores 2.0.9/2.0.10/2.0.11 atualizam para 2.0.12 com backup,
origem exata e rollback correspondente, sem trocar Python/conta/inscrição.

Aceite automatizado: Python testa transporte, política e prazo; PowerShell 5.1/7
exercita o script literal com cmdlets simulados (somente leitura, identidade,
concessões ativas, /22, escopo/nome/descrição, filtro, paginação e falhas).
A homologação no servidor DHCP institucional permanece necessária após o deploy.
