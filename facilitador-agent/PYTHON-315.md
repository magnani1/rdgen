# Preparar Python 3.15 sem trocar o agente

Executar preparar-python-remoto.ps1 na estação administrativa Windows com PowerShell 7, sob conta autorizada para WinRM/Kerberos. Assinar uma cópia fora do checkout com Sign-File conforme política institucional. Nenhuma chave privada é copiada para o APP.

Exemplo na SEDE153729, depois de atualizar o Git do APP1:

```powershell
$Fonte = '\\facilitadorapp1\c$\Magbel\rdgen\facilitador-agent\preparar-python-remoto.ps1'
$Script = Join-Path $env:TEMP 'magbel-preparar-python-remoto.ps1'
Copy-Item -LiteralPath $Fonte -Destination $Script -Force
Sign-File $Script
& $Script -ComputerName facilitadorapp2.tjpb.jus.br
```

Instala apenas Python 3.15.1 x64, com hash oficial e Authenticode válidos, em C:\Program Files\Python315. Refere-se ao instalador clássico oficial, disponível nesta versão. Não altera PATH, launcher, tarefas, venv, inscrição, contas de serviço, WinRM ou Python 3.14. Não reinicia o servidor.

Recusa Python 3.15 registrado em outra pasta ou versão diferente no destino, para evitar reaproveitar instalação pessoal silenciosamente. Confere hostname, versão, caminho e arquitetura após instalar; 3010 sem executável utilizável é falha e o log fica no destino.

Caso real APP2: a tentativa anterior de instalar 3.14.9 com TargetDir=Program Files reaproveitou a pasta da série 3.14 dentro do perfil, atualizou a instalação 3.14.7 e pediu reboot. Não considerar a instalação anterior intacta. Conferir serviço/agente e agendar reinicialização somente após drenar a máquina, conforme janela operacional.

Preparar o interpretador não migra o agente. Próxima etapa: preservar configuração/identity.json, ambiente anterior e tarefa, drenar e zerar jobs, recriar venv, aplicar conta de serviço/ACL/logon de lote, validar UNC/WinRM e reativar. Começar APP2, depois APP1 (publicador), por último APP4.
