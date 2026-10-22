# Diagnóstico da consulta de sessões Windows

`diagnosticar-sessoes-windows.ps1` separa duas conferências somente leitura:

- `AgentPath`: acesso TCP 5985 do APP selecionado ao destino, usando a identidade administrativa atual para entrar no APP. Não atesta autenticação da conta de serviço nesse caminho.
- `Wts`: autenticação direta desta estação ao destino com a credencial informada e consulta WTS usando o wrapper revisado do agente 2.0.5. Retorna quantidade de sessões, sem listar usuários.

Copie o diagnóstico para fora do checkout, assine essa cópia na estação de assinatura e execute com PowerShell 7. Informe `-Target`, `-AgentComputer` e `-AgentSourcePath` apontando para o arquivo `facilitador-agent.py` 2.0.5 atualizado pelo Git. O hash canônico do código é conferido antes de extrair o wrapper. A instrumentação de erros existe somente na memória; nenhum agente é alterado.

O JSON distingue falha de acesso ao APP, porta inacessível, autenticação WinRM, compilação e leitura WTS. `NativeCode` é o código Windows quando disponível. Código 5 indica acesso negado na etapa informada; não implica concessão automática de privilégios administrativos. Uma consulta WTS bem-sucedida desta estação ainda exige conferir a execução real pelo agente.

O diagnóstico não altera permissões, firewall, tarefas, inscrição ou configuração. Não registra a senha nem os nomes das contas das sessões. Sem PowerShell/Windows no ambiente de desenvolvimento, a execução nativa deve ser validada na estação institucional.
