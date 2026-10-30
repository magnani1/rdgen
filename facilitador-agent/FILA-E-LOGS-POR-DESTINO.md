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

## Ferramentas de aceite e auditoria

`testar-fila-guardada.ps1` prepara duas ações inofensivas assinadas (`homologacao/Teste-Fila-A.ps1` e B), solicita ambas ao worker e confere intervalos sem sobreposição e logs isolados. Executar uma cópia assinada fora do checkout, na estação com chave privada:

```powershell
& $Script -ComputerName 'CLIENTE-HOMOLOGACAO.tjpb.jus.br' `
    -Repo '\\facilitadorapp1\c$\Magbel\rdgen' `
    -CertificateThumbprint '828D73E9B099D50DE42443ACEF7E224EE8D52A5D' `
    -ConfirmarDestinoSemInstalacoes
```

Substitua CLIENTE-HOMOLOGACAO por um cliente livre, com WinRM previamente validado a partir da estação de assinatura. Não usar a própria SEDE153729 enquanto a consulta WinRM de loopback continuar falhando. Esta ferramenta não cadastra ações no painel nem instala scanners. Ela testa o guard real via WinRM; a fila da API tem testes próprios. Se expirar, preserva evidências e não mata processos. Conferir Get-Job e tarefas no cliente antes de repetir.

`auditar-script-instalacao.ps1 -Path <arquivo.ps1>` analisa AST sem executar o instalador. Relata hash e linhas/comandos que exigem revisão, sem imprimir argumentos ou credenciais. Não modifica o Kodak, não detecta todas as formas de execução e não prova ausência de risco. Assinar a cópia se a política da estação exigir.

## Diagnóstico de falhas no aceite

O teste imprime a pasta de evidências ao iniciar e os estados dos jobs a cada 15 segundos. Antes de lançar a exceção, grava `job-status.json` e `<id>-job.txt` com os estados, motivos e streams dos jobs. Isso é necessário quando o teste é iniciado com `pwsh arquivo.ps1`: ao terminar o processo filho, Get-Job na janela pai não recupera seus jobs. Erros não terminantes em jobs Completed também impedem declarar aceite.

Uma falha não encerra tarefas remotas nem apaga o gate. Não repetir o aceite antes de conferir A.log/B.log, job-status.json e a pasta da tarefa no cliente. Logs da tentativa anterior a essa correção podem não conter os streams dos jobs, mas A.log/B.log e logs remotos devem ser preservados. A correção é somente no diagnóstico; não resolve por si só falhas de WinRM, assinatura, runner ou gate.

## Leitura de logs em uso — live-log-sharing-r2

O teste real confirmou a exclusão e os logs privados no APP3, mas o watcher falhava ao abrir guard-process.log mantido pela redireção do cmd. O worker passa a abrir logs com FileShare.ReadWrite/Delete e a adiar somente erros de compartilhamento/bloqueio (Win32 32/33), sem avançar o cursor nem simular arquivo vazio. Arquivo ainda ausente também pode aparecer na próxima consulta. Erros reais, como acesso negado, continuam visíveis. O arquivo guard-process.log é coletado apenas quando a tarefa termina. O guard usa a mesma política para o snapshot legado.

Novos testes exercitam leitura com gravador aberto, bloqueio exclusivo, retomada, linhas parciais, arquivo ausente e propagação de erro real. Como não há PowerShell neste ambiente de desenvolvimento, precisam ser executados no Windows; não considerar o aceite completo só pelo código revisado.

Com um novo certificado de assinatura, testar primeiro numa cópia isolada da pasta facilitador-agent fora do checkout: copiar o runner institucional assinado para worker/Executar-TarefaLocal.ps1; assinar worker, guard, tests/test_worker_logs.ps1 e testar-fila-guardada.ps1 com o novo certificado; rodar o teste de logs e depois o aceite com -Worker apontando à cópia local. O novo editor precisa ser confiável na estação e no cliente de homologação.

Não substituir o worker compartilhado com um novo editor até validar a distribuição da confiança aos executores e clientes que o utilizarão. Não desabilitar revogação, apagar gate, matar instaladores ou reinscrever agentes para corrigir um erro de leitura do watcher. Agente continua 2.0.8, sem mudanças no backend ou no Docker.
