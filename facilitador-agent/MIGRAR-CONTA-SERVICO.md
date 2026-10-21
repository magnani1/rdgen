# Migrar agente existente para conta de serviço e Python 3.15

Pré-requisitos: Python 3.15.1 x64 já validado em C:\Program Files\Python315; PowerShell 7 na estação administrativa, WinRM padrão/Kerberos e credencial autorizada. Começar APP2; APP1 mantém o catálogo. Não migrar os agentes simultaneamente.

1. No painel: Drenar, aguardar zero trabalhos e Encerrar agente. A tarefa precisa ficar Ready. Depois, clicar **Drenar novamente**, mantendo a tarefa parada: isso substitui a ordem persistente de encerramento antes que o script reinicie o agente. O script não para processos nem drena/ativa no backend; o administrador confirma que drenou e zerou os trabalhos.
2. Atualizar Git, copiar migrar-conta-agente.ps1 para fora do checkout e assinar com Sign-File na SEDE153729.
3. Importar o PSCredential CLIXML/DPAPI salvo na SEDE153729 pelo mesmo usuário. Não copiar esse arquivo aos APPs nem ao Git.
4. Executar para uma máquina:

```powershell
& $Script -ComputerName facilitadorapp2.tjpb.jus.br -Credential $CredServico -RequirementsPath "$Repo\facilitador-agent\requirements.txt" -ConfirmarDrenadoSemTrabalhos
```

O script usa Invoke-Command com PSCredential pela sessão Kerberos, sem senha em argumentos de processos ou arquivos. Cria outro venv, instala o manifest revisado e testa importações/pip check antes de alterar a tarefa. Mantém o runtime, launcher assinado, inscrição, configuração extra, slots e venv anterior. A nova conta recebe leitura/execução no runtime e escrita apenas em Logs, Uploads e agent.log. Concede logon de lote preservando a lista anterior; não remove negações. GPO pode sobrescrever direitos e uma negação por grupo prevalece.

Backups de configuração, XML da tarefa, ACL e direitos ficam em ProgramData\Magbel\AgentMigrationBackups, restritos a SYSTEM/administradores. identity.json é comparado por hash e não é copiado para outro lugar. Grants da conta anterior permanecem durante o aceite; remover somente os grants antigos identificados após validar a nova conta. Isso também permite recuperação com a conta anterior.

A tarefa inicia, mas a ativação no painel é manual depois de contato recente, prontidão, leitura UNC e execução WinRM em destino de teste. Retorno de instalação não comprova essas permissões.

Em falha, manter drenado e não repetir cegamente. Não há rollback automático da identidade da tarefa: o XML não contém sua senha; para voltar à conta anterior é necessária a credencial correspondente. O venv e config anteriores ficam preservados, sem remover Python antigo. Se o cadastro já aponta ao novo venv/conta, a repetição é recusada.

A senha DPAPI salva é reutilizável apenas na estação/conta que a exportou. Quando mudar no AD, atualizar o CLIXML e a credencial das tarefas. Não usar S4U para esse agente de rede.

## Agente reinicia e recebe novamente ordem de saída

Se o log mostrar “saída solicitada pelo painel” logo após iniciar, a ordem de encerramento continua registrada no backend. No painel, clicar **Drenar** e então iniciar a tarefa existente pela SEDE153729:

```powershell
Invoke-Command -ComputerName facilitadorapp2.tjpb.jus.br -Authentication Kerberos -ScriptBlock {
    Start-ScheduledTask -TaskName 'Magbel-Facilitador-facilitadorapp2'
}
```

O comando reutiliza a conta já registrada na tarefa. Não repetir a migração, criar outro venv nem renovar a inscrição por esse motivo. A mesma orientação vale após retomar-config-agente.ps1. Conferir contato e prontidão recentes; ativar somente depois de validar UNC e WinRM. Mensagens antigas no arquivo de log não demonstram uma falha atual.
