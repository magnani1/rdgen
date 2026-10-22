# Atualizar somente o agente 2.0.2 para 2.0.3

Todos os APPs já configurados com Python 3.15.1 podem manter seus ambientes. Esta manutenção troca somente facilitador-agent.py. Não instala pacotes, muda a conta da tarefa, modifica launcher/configuração ou renova inscrição.

1. Começar APP4. No painel drenar, conferir zero trabalhos e solicitar encerramento.
2. Conferir a tarefa Ready. Se o encerramento remoto não for obedecido, somente após conferir drenagem e zero trabalhos parar especificamente a tarefa pelo Agendador/Stop-ScheduledTask; não matar todos os processos Python.
3. No painel selecionar Drenar novamente para retirar a ordem persistente de saída. Se o cartão já estiver drenando, o botão fica oculto e a ordem já é drain.
4. Atualizar Git na SEDE153729, copiar atualizar-codigo-agente.ps1 para fora do checkout e assinar essa cópia com Sign-File. O próprio script verifica a assinatura antes de conectar.
5. Executar com ComputerName, AgentSourcePath apontando ao facilitador-agent.py do checkout e ConfirmarDrenadoSemTrabalhos. Usa WinRM padrão Microsoft.PowerShell/Kerberos, sem pedir senha da conta de serviço nem copiá-la. A identidade administrativa da estação precisa ter autorização no destino.

O hash SHA256 do código 2.0.3 está fixado dentro do atualizador assinado. Para suportar checkout Windows, a comparação canonicaliza CRLF para LF, remove BOM ao ler e usa uma quebra final. Não aceita outro código com o mesmo texto VERSION. O destino reconfere bytes, tarefa Ready e ausência de processos cujo comando aponta ao arquivo do agente; compila pelo Python configurado sem executar o agente, reconfere config/inscrição/tarefa e troca o arquivo com File.Replace. O backup fica em ProgramData\Magbel\AgentCodeBackups, restrito a administradores/SYSTEM. A configuração e a inscrição não são copiadas para outro lugar.

Depois de iniciar a tarefa, esperar novo heartbeat com agente 2.0.3, Python 3.15.1 e requests. Conferir prontidão e ação real antes de ativar. O script não ativa nem confirma saúde pelo backend. Se a tarefa falhar ao iniciar ou não enviar prontidão, manter drenado e conferir o log; não repetir cegamente. O backup do código permite retorno manual com tarefa parada, preservando configuração/inscrição e o Python em uso. Não há rollback automático após teste funcional nesta entrega.

Após aceite do APP4, seguir um por vez: APP1, APP2 e APP3. Antes do APP3, transferir o catálogo para um agente atualizado e pronto, conferir itens e horário, e só então drená-lo. Cada execução recebe uma única máquina para permitir o aceite entre elas.

Isso é uma atualização administrativa por WinRM. O painel ainda não executa instalações: a futura execução por botão precisa de transporte de comando autorizado, executor privilegiado e controle de manutenção/rollback.
