# Atualizações de Python e dependências

Referência pública revisada em 21/10/2026: Python 3.15.1 (candidato à migração, ainda sem aceite nos APPs).
A produção não é atualizada por estes workflows.

## Alertas no GitHub

- Dependabot consulta manifests pip diariamente e GitHub Actions/imagens Docker semanalmente, abrindo PRs quando há alteração aplicável. Requirements sem versões fixas não representam um inventário de produção e podem não gerar PR de nova versão.
- O workflow Auditoria diaria de dependencias roda diariamente às 08:23 de Fortaleza (horário aproximado do GitHub), em PRs/alterações dos manifests e manualmente. Executa pip-audit com dependências transitivas e publica JSON por 30 dias; vulnerabilidade ou erro na consulta não é tratado como sucesso.
- A auditoria resolve o requirements no runner: não consulta o ambiente atualmente instalado no DietPi ou nos APPs. Para auditar produção, exportar também um inventário pip freeze do ambiente exato e auditá-lo separadamente.
- No rdgen, a mesma rotina verifica a página oficial de releases estáveis. Falha com aviso quando encontra Python posterior à referência revisada. A referência não é uma declaração de versão instalada nem de compatibilidade.
- Habilitar notificações de Actions e Dependabot em https://github.com/settings/notifications e conferir Security and quality / Dependabot nos repositórios. Criar o YAML não habilita por si só todas as opções de segurança da conta/repositório.
- Sem auto-merge, pip-audit --fix ou atualização automática dos agentes. CI falhando é um alerta de investigação, não prova de exploração.

## Migração dos agentes

1. Testar agente, instalador e pacote em Windows com Python 3.15; o EXE continua sendo compilado em 3.12 até validação própria do PyInstaller.
2. Instalar Python x64 para todos os usuários em Program Files, lado a lado, verificando assinatura e hash publicados.
3. Começar por APP2: drenar, aguardar nenhum trabalho, preservar identity.json/configuração e ambiente anterior, recriar venv e registrar tarefa com conta de serviço.
4. Validar contato, login/MFA, UNC, WinRM e concorrência antes de reativar. Depois APP1 (publicador) e APP4.
5. Instalar um interpretador não muda o Python de um venv existente. Não remover o Python anterior enquanto algum ambiente depender dele.
6. Tratar 3010 como reinicialização pendente, não prova de runtime utilizável: confirmar executável e logs antes de trocar a tarefa.

Credenciais permanecem fora do Git; CLIXML/DPAPI fica somente na estação e conta que o criou. Arquivos assinados são regenerados em novo pacote após mudanças.
