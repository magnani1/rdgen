# Exclusão por destino e logs exclusivos — complemento do agente 2.0.8

## Comportamento

A fila do Facilitador já reserva o mesmo destino para scripts e WinGet, inclusive entre APPs e entre nome curto/FQDN do mesmo hostname. O agente é executor; o bloqueio pertence ao destino. Outro computador pode continuar recebendo ações. Resultado desconhecido mantém a reserva até a conferência humana, sem repetir a instalação.

O worker agora inicia `Executar-Guardado.ps1` no cliente, como SYSTEM. O guard segura um handle exclusivo em `C:\ProgramData\Magbel\ExecutionGate\execution.lock` enquanto a tarefa e seus filhos observados não terminam. Outra tarefa protegida aguarda, sem encerrar a anterior. Tarefas Facilitador antigas ainda abertas também impedem início, assim como sinais observáveis de instalação MSI em andamento. Não é uma substituição para o controle interno do Windows Installer.

O guard grava `active.json` antes de iniciar o script. Se ele morrer ou perder a confirmação do encerramento, o marcador permanece: novas tarefas protegidas ficam bloqueadas para conferência manual. Não apague o marcador apenas porque o painel perdeu contato. O timeout do watcher não encerra o guard ou o instalador. A tarefa protegida não tem limite de execução automático; uma instalação travada exige conferência no Windows, não liberação por idade. Sem retomada automática após crash/reboot.

Cada execução mantém a pasta `C:\Windows\Temp\Facilitador_<id>` com `params.json`, `guard.json`, `gate.log`, `processo.log`, `stderr.log` e, quando disponíveis, `script.log`, `legacy-script.log` e `legacy-before.log`. O worker não lê mais o log global diretamente e preserva os arquivos após terminar. Não há retenção automática nesta entrega: use política de limpeza após o aceite, preservando trabalhos desconhecidos. Logs não devem conter senhas ou tokens.

Scripts novos devem usar `$env:FACILITADOR_LOG_PATH` e `$env:FACILITADOR_WORK_DIR`. Para scripts antigos, o guard faz backup/limpa o log declarado somente depois de adquirir a exclusão, copiando seu conteúdo para o snapshot privado da execução enquanto a possui. Linhas incompletas aguardam a próxima leitura; a última linha é liberada no encerramento confirmado.

## Limites explícitos

O bloqueio local protege tarefas iniciadas pelo worker novo. O adapter nativo WinGet mantém a exclusão da fila do servidor e seus próprios logs por job; ele não participa deste handle local. Não libere manualmente uma reserva enquanto houver processo remoto em andamento. Comandos manuais, outro sistema RMM e tarefas antigas não aderem ao handle, portanto não podem receber garantia de exclusão global. Os sinais MSI são conservadores e não detectam todos os tipos de instalador EXE.

Esta entrega não altera os scripts dos fabricantes nem neutraliza seus `Stop-Process`/`taskkill`. O Kodak exibiu mensagem de encerramento de setups pendentes: revisar esse trecho do script institucional antes de garantir que não encerre instalações iniciadas fora do Facilitador. Não altera o arquivo legado de parâmetros nem troca Python, conta ou inscrição.

## Publicação

Aguarde as instalações atuais terminarem, confira os resultados, drene os agentes e confirme zero trabalhos/tarefas remotas abertas. Atualize o checkout rdgen pelo Git. Na estação de assinatura, copie `publicar-worker-serial.ps1` para uma pasta fora do checkout, assine com `Sign-File` e execute:

```powershell
& $Script -Repo '\\facilitadorapp1\c$\Magbel\rdgen' `
    -CertificateThumbprint '828D73E9B099D50DE42443ACEF7E224EE8D52A5D' `
    -ConfirmarSemTrabalhos
```

O publicador valida parser/assinatura/hash, publica primeiro o guard e depois o worker, verifica transporte e guarda versões anteriores em `C:\ProgramData\Magbel\Pacotes\worker-serial-<data-id>`. Uma falha pode deixar publicação parcial; confira os dois destinos e backups antes de repetir. O preparador de monitoramento 208 também passa a publicar os dois arquivos. Não copie só o worker para o compartilhamento.

O agente continua 2.0.8; esta correção é no worker institucional lido a cada nova execução. Não precisa reiniciar os executores nem cadastrar serviço. Nenhuma instalação em andamento é alterada retroativamente. Para rollback, drene, confira ausência de trabalhos e restaure a cópia anterior assinada do worker; preserve logs e guard até conferir tarefas pendentes.

## Aceite no Windows

1. Dois scripts inofensivos no mesmo destino: um inicia, o outro aguarda; em destinos distintos podem executar em paralelo.
2. Cada script escreve identificação e algumas linhas, inclusive uma linha em duas partes. Cada acompanhamento deve mostrar apenas seu próprio conteúdo, sem fragmentos duplicados.
3. Confira código final, tarefas e processos antes de liberar recursos.
4. Em homologação descartável, interromper apenas o watcher deve manter a tarefa/gate; não testar crash ou reboot durante uma instalação real.
5. Conferir perda de contato e marcador persistente com um script inofensivo: não pode iniciar nova instalação sem conferência.

Testes de fila executados em Python; PowerShell inclui parser, leitura incremental e exclusão de handles. Aceite real de WinRM/ScheduledTask/assinatura/instaladores continua necessário.
