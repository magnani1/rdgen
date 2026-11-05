# Consultas DHCP/IoT somente leitura — canário 2.0.10

O agente recebe `interactive_inspect` exclusivamente do backend autenticado. Não
executa os PS1 legados nem lê o JSON global de parâmetros. Usa um adaptador fixo
embutido no Python aprovado e dados JSON codificados, com timeout de 60 segundos.
Nenhuma senha é recebida; a identidade Windows do processo tem que corresponder
à conta configurada pelo administrador no backend.

Comandos de domínio: `Get-DhcpServerv4Scope`, `Get-DhcpServerv4Reservation`,
`Get-ADUser` e `Get-ADGroup`. Falhas de acesso não viram listas vazias. DHCP fica
restrito a um escopo e no máximo 4.096 reservas lidas; IoT limita a 100 MACs e 32
perfis. Busca IoT usa sAMAccountName exato e SearchBase configurada. A associação
retornada é direta, apenas aos perfis permitidos; não é auditoria de grupos
transitivos. Não consulta leases, não calcula IP livre e não confirma direitos
para operações de escrita. Resultado não libera execução.

## Pré-requisitos no APP de homologação

- Agente 2.0.9 existente, inscrito, com configuração/identidade preservadas.
- Conta de execução `TJ-PB\facilitador-servico` (ou outra explicitamente aprovada)
  com leitura DHCP/AD. Conta administrativa do navegador não é a executora.
- Windows PowerShell 5.1 e módulos RSAT ActiveDirectory/DhcpServer instalados.
- Conectividade até o AD/DHCP. As consultas usam os módulos locais do APP; não
  dependem de uma sessão WinRM de segundo salto até os servidores de domínio.
- Backend com o PR de consultas aplicado. O backend 2.0.9 anterior não sabe
  despachar este tipo; atualize o painel antes do canário.

## Atualizar apenas um APP

Não altere Python, inscrição, senha, grupos nem tarefa. Drene o APP no painel,
confira zero trabalhos e pare sua tarefa específica. O atualizador recusa tarefa
em execução/processo existente e não mata nada automaticamente.

Na estação administrativa com chave privada disponível, depois de revisar e
atualizar o checkout local do rdgen, copie `atualizar-consultas-210.ps1` para fora
do checkout e assine a cópia com o certificado atual. Exemplo de execução da cópia
assinada (o preparador exige assinatura válida e hash do agente revisado):

```powershell
& $AtualizadorAssinado -ComputerName 'facilitadorapp3.tjpb.jus.br' `
    -AgentSourcePath (Join-Path $Repo 'facilitador-agent\facilitador-agent.py') `
    -ConfirmarDrenadoSemTrabalhos
```

`$Repo` deve ser o checkout atualizado; `$AtualizadorAssinado` é a cópia assinada
fora dele. O atualizador só aceita 2.0.9 -> 2.0.10, mantém backup protegido,
configuração e identidade, compila o Python e inicia a tarefa existente.
Confirme heartbeat 2.0.10, conta e prontidão antes de ativar o APP no painel.

O preparador `preparar-consultas-210.ps1` gera e assina o pacote permanente
2.0.10 preservando a inscrição. Atualize o checkout **localmente** antes; o
preparador não executa Git por SMB. O painel atualizado oferece 2.0.9 -> 2.0.10,
um executor por vez. Use o preparador 210; os preparadores 208/209 anteriores são
entregas históricas e seus hashes não aceitam o código novo. A ampliação da frota
e AGENT_APPROVED_VERSION=2.0.10 aguardam aceite do canário.

## Aceite pelo painel

Configurar servidores/conta/OU/escopos/perfis no backend conforme o procedimento
do core. Preparar o resumo e então clicar **Consultar estado real — somente
leitura**. Conferir agente, horário e identidade exibidos. Comparar uma reserva e
um dispositivo conhecidos usando consulta administrativa independente. Testar
MAC ausente, perfil inexistente, escopo não permitido e falha controlada de
acesso; nunca interpretar falha/timeout como ausência de objeto.

O teste nativo da CI usa cmdlets simulados; ainda exige aceite real no Windows.
IA e alterações de DHCP/AD permanecem fora desta etapa.
