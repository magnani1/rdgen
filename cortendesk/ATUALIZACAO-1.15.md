# Atualização emergencial Magbel Remote / CortenDesk 1.15.0

A release oficial v1.15.0, publicada em 21/10/2026, informa correções críticas de PHP e nenhuma migração nova de banco. A imagem oficial muda para PHP 8.5.12 ou posterior. Não basta trocar a tag: a Magbel monta AppriseNotifications.php e settings-page.blade.php, ambos alterados nesta release. Esses arquivos são regenerados a partir de fontes 1.15.0 verificadas por hash, preservando os deltas da marca e as correções novas.

Na VPS, como ubuntu, com o checkout existente e autorização Docker/sudo:

```bash
cd /home/ubuntu/rdgen-magbel &&
git pull --ff-only &&
sudo bash cortendesk/scripts/update-vps-1.15.sh
```

O procedimento é para Compose standalone já ativo, contêiner suporte_remoto, SQLite e /opt/cortendesk/data. Aceita variáveis CORTEN_CONTAINER e CORTEN_ROOT ou argumentos --container e --root para uma instância de teste. Exige Docker Compose v2, Python 3.9+ e tar no host; não usa PHP instalado no host. A VPS pode ser arm64: usa a imagem oficial para a arquitetura nativa e confere o PHP antes de parar o serviço. A CI desta entrega executa a integração em amd64; a arquitetura da VPS é validada no pull local.

## O que faz

- Identifica o projeto/serviço Compose pelo contêiner. Localiza o arquivo real do Portainer pelo volume /data, ou usa a fonte já acessível no Dockge/host. Mantém o mesmo projeto e recria somente o serviço CortenDesk; não cria stack paralela.
- Resolve as variáveis com o ambiente já configurado no contêiner, incluindo CORTENDESK_RDGEN_URL e MAGBEL_SESSION_TOKEN_GROUPS. Não imprime valores nem exige reenviar senhas/tokens. Preserva as referências ${...} no Compose original.
- Recusa drift de mounts, portas, redes, imagem, ambiente ou código local diferente do manifesto. Recusa Compose dentro de checkout Git para não criar alteração local em arquivo versionado. Esse caso exige apontar a stack para uma cópia institucional fora do checkout. Recusa bancos externos, Swarm e código adicional em /app sem revisão.
- Baixa a imagem oficial, fixa seu digest na fonte ativa, confere PHP_VERSION_ID >= 80512 e reconstrói branding/ponte em diretórios novos. O código 1.14 não é copiado para cima do 1.15. O pacote estático compose-session-bridge-1.15.yml é referência para inspeção; o script modifica a fonte da stack existente, preservando as opções locais.
- Salva inspect privado, Compose original e imagem anterior em /opt/cortendesk/backups/security-1.15.0-*. Para copiar /data e overlays consistentemente, para o serviço por uma janela curta: atendimentos/relay podem desconectar nesse intervalo.
- Recria o serviço e confere versão/PHP, hashes dos destinos montados, saúde, tabela/rotas da ponte, agendamento e processo schedule:work. Chaves persistentes da aplicação/RustDesk já existentes são comparadas sem exibir conteúdo.
- Se a implantação/validação falhar, restaura a fonte Compose e a imagem anteriores e aguarda saúde. O banco não é sobrescrito automaticamente. O snapshot consistente completo permite recuperação de dados com conferência administrativa. Se o rollback voltar a 1.14, a correção de segurança ainda estará pendente; não considerar a manutenção concluída.

Os snapshots contêm segredos operacionais e ficam restritos a root. Não publicar backups, inspect ou logs privados no Git, chat ou tickets. Não apaga nenhum arquivo anterior nem troca chaves, tokens API, instaladores, conta de cliente ou URL do RDGen. O cliente RustDesk não é recompilado por este procedimento.

## Conferir depois

```bash
sudo bash cortendesk/scripts/verify-vps-1.15.sh
```

Acessar https://suporte.magbel.com.br, abrir /webclient e validar uma sessão de teste criada pelo Facilitador, incluindo encerramento. A validação automática não comprova navegação pelo Cloudflare nem conexão real ao computador do cliente.

Reexecutar update-vps-1.15.sh depois de sucesso apenas confere a instalação e não recria o contêiner. Se houve falha, ler o motivo antes de repetir: preparação anterior divergente ou código local não versionado são preservados, nunca substituídos silenciosamente.

Rollback manual de código, apenas se necessário, usando o caminho de backup informado:

```bash
sudo bash cortendesk/scripts/update-vps-1.15.sh --rollback /opt/cortendesk/backups/security-1.15.0-DATA-ID
```

Não restaura /data automaticamente: isso descartaria operações posteriores ao snapshot. Não remove os backups ou diretórios antigos nesta manutenção.
