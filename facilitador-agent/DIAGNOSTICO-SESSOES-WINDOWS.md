# Diagnóstico da consulta de sessões Windows

`diagnosticar-sessoes-windows.ps1` separa duas conferências somente leitura:

- `AgentPath`: acesso TCP 5985 do APP selecionado ao destino, usando a identidade administrativa atual para entrar no APP. Não atesta autenticação da conta de serviço nesse caminho.
- `Wts`: autenticação direta desta estação ao destino com a credencial informada e consulta WTS usando o wrapper revisado do agente 2.0.5. Retorna quantidade de sessões, sem listar usuários.

Copie o diagnóstico para fora do checkout, assine essa cópia na estação de assinatura e execute com PowerShell 7. Informe `-Target`, `-AgentComputer` e `-AgentSourcePath` apontando para o arquivo `facilitador-agent.py` 2.0.5 atualizado pelo Git. O hash canônico do código é conferido antes de extrair o wrapper. A instrumentação de erros existe somente na memória; nenhum agente é alterado.

O JSON distingue falha de acesso ao APP, porta inacessível, autenticação WinRM, compilação e leitura WTS. `NativeCode` é o código Windows quando disponível. Código 5 indica acesso negado na etapa informada; não implica concessão automática de privilégios administrativos. Uma consulta WTS bem-sucedida desta estação ainda exige conferir a execução real pelo agente.

O diagnóstico não altera permissões, firewall, tarefas, inscrição ou configuração. Não registra a senha nem os nomes das contas das sessões. Sem PowerShell/Windows no ambiente de desenvolvimento, a execução nativa deve ser validada na estação institucional.

## Concessão específica de consulta

Quando a conta administrativa enumera sessões e a conta de serviço não consegue, `permitir-consulta-sessoes.ps1` prepara uma ACE direta `AccessAllowed`, máscara `0x1` (WINSTATION_QUERY), para a conta informada nos terminais Console e RDP-Tcp. Não usa presets de usuário RDP, não adiciona grupos e não concede Logon/Shadow/Logoff/Reset. Preserva as demais ACEs, proprietário, grupo e SACL no descritor enviado ao provedor WMI.

Copie para fora do checkout e assine com `Sign-File`. Execute da estação administrativa com `-ComputerName facilitador.tjpb.jus.br`; sem `-Apply`, apenas apresenta o plano. Com `-Apply`, salva os descritores anteriores em `C:\ProgramData\Magbel\SessionQueryBackups\<id>\permissions-before.clixml` no destino antes da primeira alteração, verifica concorrência e relê a DACL após gravar. A operação é idempotente para a ACE direta já presente. Negações não são removidas; uma negação de grupo ainda pode impedir a consulta. Se um terminal falhar após outro ter sido alterado, o backup permite recuperar ambos; não há alegação de transação entre terminais.

Execute novamente o diagnóstico WTS e depois a consulta pelo painel. Permissão no listener não comprova atualização das ACLs de todas as sessões preexistentes. Não reinicie TermService nem encerre sessões automaticamente. A execução nativa deste ajuste precisa ser validada no Windows.

Para reversão administrativa, no próprio destino importe o CLIXML indicado na saída e, após conferir que não houve outras mudanças de ACL desde a aplicação, use os campos `Plans[].Before` em `Set-CimInstance -Property @{StringSecurityDescriptor=$Plan.Before}` para cada terminal registrado. Não use RestoreDefaults: ele descartaria personalizações alheias a este ajuste. O backup guarda ACLs, não credenciais.
