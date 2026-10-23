# Atualizar o executor APP4 2.0.4 para 2.0.6

O conector permanente e o executor são processos separados. Pacote do conector em 2.0.6 não comprova que o executor APP4 saiu de 2.0.4. O fluxo do painel 2.0.6 continua aceitando origem 2.0.5; esta recuperação usa o atualizador administrativo assinado para origem 2.0.4 ou 2.0.5, sem alterar o helper do conector.

No painel, drenar APP4, conferir zero trabalhos e solicitar Encerrar agente. Após a tarefa Windows ficar Ready, selecionar Drenar novamente caso o estado desejado seja encerramento solicitado: isso permite que o novo processo permaneça em execução sem entregar trabalhos. Não parar nem reinscrever o serviço de manutenção.

Na SEDE153729, atualizar o Git, copiar atualizar-codigo-agente.ps1 para TEMP, assinar essa cópia e invocar com -ComputerName facilitadorapp4.tjpb.jus.br -AgentSourcePath apontando ao facilitador-agent.py 2.0.6 do checkout e -ConfirmarDrenadoSemTrabalhos. A ferramenta verifica assinatura, hash fixo de destino 2.0.6, tarefa Ready, ausência de processo executor e preservação de configuração/inscrição/tarefa. Salva o código anterior e informa PreviousVersion.

Depois conferir no heartbeat Agente 2.0.6, Python, prontidão e teste WinRM; só então ativar APP4. Não trocar identity.json, recriar venv ou executar Nova inscrição. A atualização preserva a identidade do catálogo, que pode ser assumido por outro agente durante a drenagem.

Testes nativos exercitam as duas origens em runtimes descartáveis no Windows e verificam backup, integridade e preservação de identidade/configuração. Execução Windows pendente no ambiente institucional; não houve acesso remoto aos APPs pelo desenvolvimento.
