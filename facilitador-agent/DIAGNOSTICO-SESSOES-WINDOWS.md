# Diagnóstico da consulta de sessões Windows

`diagnosticar-sessoes-windows.ps1` separa duas conferências somente leitura:

- `AgentPath`: acesso TCP 5985 do APP selecionado ao destino, usando a identidade administrativa atual para entrar no APP. Não atesta autenticação da conta de serviço nesse caminho.
- `Wts`: autenticação direta desta estação ao destino com a credencial informada e consulta WTS usando o wrapper revisado do agente 2.0.5. Retorna quantidade de sessões, sem listar usuários.

Copie o diagnóstico para fora do checkout, assine essa cópia na estação de assinatura e execute com PowerShell 7. Informe `-Target`, `-AgentComputer` e `-AgentSourcePath` apontando para o arquivo `facilitador-agent.py` 2.0.5 atualizado pelo Git. O hash canônico do código é conferido antes de extrair o wrapper. A instrumentação de erros existe somente na memória; nenhum agente é alterado.

O JSON distingue falha de acesso ao APP, porta inacessível, autenticação WinRM, compilação e leitura WTS. `NativeCode` é o código Windows quando disponível. Código 5 indica acesso negado na etapa informada; não implica concessão automática de privilégios administrativos. Uma consulta WTS bem-sucedida desta estação ainda exige conferir a execução real pelo agente.

O diagnóstico não altera permissões, firewall, tarefas, inscrição ou configuração. Não registra a senha nem os nomes das contas das sessões. Sem PowerShell/Windows no ambiente de desenvolvimento, a execução nativa deve ser validada na estação institucional.

## Concessão específica de consulta

Quando a conta administrativa enumera sessões e a conta de serviço não consegue, `permitir-consulta-sessoes.ps1` prepara uma ACE direta `AccessAllowed`, máscara `0x1` (WINSTATION_QUERY), para a conta informada no listener RDP-Tcp. Não usa presets de usuário RDP, não adiciona grupos e não concede Logon/Shadow/Logoff/Reset. Preserva as demais ACEs e a SACL; a chamada de escrita não seleciona proprietário ou grupo para alteração.

Copie para fora do checkout e assine com `Sign-File`. Execute da estação administrativa com `-ComputerName facilitador.tjpb.jus.br`; sem `-Apply`, apenas apresenta o plano. Com `-Apply`, salva os descritores anteriores em `C:\ProgramData\Magbel\SessionQueryBackups\<id>\permissions-before.clixml` no destino antes da primeira alteração, verifica concorrência e relê DACL/SACL pela API após gravar. A operação é idempotente para a ACE direta já presente. Negações não são removidas; uma negação de grupo ainda pode impedir a consulta. Uma falha após a chamada nativa de escrita exige conferir a ACL atual e o backup; não implica ausência de alteração.

Execute novamente o diagnóstico WTS e depois a consulta pelo painel. Permissão no listener não comprova atualização das ACLs de todas as sessões preexistentes. Não reinicie TermService nem encerre sessões automaticamente. A execução nativa deste ajuste precisa ser validada no Windows.

A gravação usa WTSSetListenerSecurityW; Set-CimInstance retornou HRESULT 0x8004100c (Not supported) no ambiente real. WTSGetListenerSecurityW lê DACL e SACL (flags 12), compara com a prévia e salva também `listener-before.bin`. O ajuste altera somente a DACL acrescentando consulta; envia a SACL nativa sem alterações. SeSecurityPrivilege é habilitado temporariamente no processo remoto administrativo e seu estado anterior é restaurado após cada chamada. Se o privilégio não estiver disponível, a operação falha sem tentar removê-lo como requisito. Console não é alterado: não é tratado como listener RDP. Não há garantia de alteração de ACLs em sessões já abertas.

Para reversão, use a mesma API de listener com os bytes de `listener-before.bin`, após conferir que não houve alterações posteriores de ACL. Não use Set-CimInstance neste destino nem RestoreDefaults. O CLIXML guarda também o descritor anterior para inspeção. Os backups não contêm credenciais. A ferramenta não faz rollback automático sobre mudanças concorrentes.

Referências: https://learn.microsoft.com/en-us/windows/win32/api/wtsapi32/nf-wtsapi32-wtsgetlistenersecurityw e https://learn.microsoft.com/en-us/windows/win32/api/wtsapi32/nf-wtsapi32-wtssetlistenersecurityw .
