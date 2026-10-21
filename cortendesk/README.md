# Magbel Remote — CortenDesk 1.14.0

Pacote de migração dos ajustes enviados de `/opt/cortendesk/branding`. O RDGen continua com o mesmo código, configuração e pipeline de geração; esta pasta versiona a personalização da console relacionada a ele.

## O que foi preservado

Nome Magbel Remote, palavra/marca das telas de autenticação e downloads, nomes nos diagnósticos/notificações, emissor TOTP, logos, favicons, identidade do webclient e renovação de cache dos assets montados.

Os 23 arquivos de código/interface são extraídos da imagem **1.14.0**, verificados por SHA256 normalizado e só então personalizados. Nenhum arquivo PHP/Blade/JS antigo é copiado sobre a aplicação nova. A mudança de tema/Bootstrap, MFA do cliente, anti-replay TOTP, notificações, retentativas, backups, detecção de duplicados e links novos vêm da imagem upstream.

Os cinco assets versionados foram copiados, sem alteração, do pacote enviado. Backups antigos, arquivos `.bak`, dados, ambiente e chaves privadas não foram incluídos. A chave RustDesk no Compose é pública. O `manifest.json` registra as fontes e checksums. Não há senha nem token privado no pacote.

## Preparação na VPS

Após integrar esta alteração no Git:

```bash
git clone https://github.com/magnani1/rdgen.git /home/ubuntu/rdgen-magbel
cd /home/ubuntu/rdgen-magbel
sudo bash cortendesk/scripts/prepare-vps.sh
```

Se o checkout já existir, use `git -C /home/ubuntu/rdgen-magbel pull --ff-only` em vez de clonar. Não clone sobre um diretório que já contenha arquivos.

O preparador:

1. Confirma SQLite dentro de `/data` e bind mount `/opt/cortendesk/data`. Banco externo ou layout diferente interrompe a preparação antes de parar o serviço: nesse caso é necessário adaptar o backup ao banco real.
2. Baixa a imagem 1.14.0 e extrai arquivos de um contêiner que **não é iniciado**. Portanto essa etapa não executa migrações nem aponta a imagem nova para os dados reais.
3. Valida as fontes e gera `/opt/cortendesk/branding-1.14.0` em staging, mantendo o diretório de branding antigo.
4. Executa `php -l` das classes/configuração com o PHP da imagem nova, sem montar o banco real.
5. Preserva a imagem anterior em tag/arquivo e os metadados do contêiner em diretório privado. Se a imagem antiga não estiver disponível no Docker, interrompe antes da parada; deve-se resolver a recuperação dessa imagem primeiro.
6. Para brevemente `suporte_remoto`, arquiva `data` e `branding` com o processo parado e reinicia a versão antiga. Essa etapa causa indisponibilidade durante a cópia. Um trap tenta religar a versão antiga se houver erro. O script não troca a stack.
7. Publica os arquivos preparados e informa o caminho do backup privado.

Execute uma vez por preparação. Se o destino versionado já existir, não o sobrescreve. Confira o manifesto e o estado antes de repetir; não apague diretórios usados por uma stack ativa.

## Troca da stack existente

No mesmo gerenciador que controla a stack atual, compare o Compose ativo com `cortendesk/compose-1.14.yml` e aplique o novo conteúdo **na stack existente**. Preserve quaisquer variáveis adicionais existentes e o valor de `CORTENDESK_RDGEN_URL` no gerenciador. O modelo foi construído a partir do Compose fornecido pelo operador; configurações extras locais não vistas precisam ser mantidas.

Mudanças principais: imagem `ghcr.io/marcpope/cortendesk:1.14.0` e fontes dos bind mounts em `/opt/cortendesk/branding-1.14.0`. Mantém `/opt/cortendesk/data`, nome `suporte_remoto`, redes, aliases, domínios, ID/relay e chave pública. Remove o override de metadado `CORTENDESK_SERVER_VERSION=1.1.0`; a imagem nova declara 1.1.1.

Não altere as chaves RustDesk/APP_KEY. Não crie uma segunda stack concorrendo pelas portas 21115–21119 ou pelo mesmo volume de banco. Os ports foram preservados como informados, sem reconfigurar o fluxo de rede nesta atualização.

## Verificação

```bash
cd /home/ubuntu/rdgen-magbel
sudo bash cortendesk/scripts/verify-vps.sh
```

A verificação compara os arquivos ativos a todos os checksums da preparação, confirma 1.14.0 e os métodos novos, consulta `/health/ready`, compila as views e lista as rotas de automação. Se falhar, envie a mensagem antes de fazer outros ajustes.

Depois validar no navegador: login, MFA/SSO, menus e backups novos, logos claro/escuro, downloads de instaladores, abertura do cliente RDGen pelo protocolo realmente registrado, webclient com aprovação por clique, sessão remota, transferência de arquivo e auditoria. Mudança de nome de protocolo não é inferida do nome comercial: configure `CORTENDESK_CLIENT_URL_SCHEME` somente após confirmar o registro do cliente.

Os tokens de clientes já autenticados são mantidos pelo upstream. O novo MFA se aplica no próximo login por senha. O cliente 1.5.0 já gerado não precisa ser reconstruído apenas por esta atualização da console.

## Rollback

O salto desde 1.10.1 executa três migrações, apesar de 1.14 isoladamente não acrescentar migração. Não presumir que trocar a tag reverta o banco.

O backup é `/opt/cortendesk/backups/update-<UTC>/`, com permissões privadas. Contém `data-branding-before.tar.gz`, imagem anterior e metadados com valores de ambiente. **Não publicar nem anexar esse diretório**: contém credenciais/chaves e dados reais.

Para rollback completo, interromper a stack, preservar também os dados atuais para evitar perda acidental de eventos e restaurar `/data` e branding do snapshot numa janela sem gravação, junto com a imagem anterior e o Compose original. A restauração de dados perde alterações feitas após o snapshot; a autorização para essa perda deve ser específica ao incidente. Não executar extração sobre um banco em uso.

## Validação realizada e limites

- Comparação confirmou que a função de marca reproduz exatamente 22/22 deltas dos arquivos antigos, desconsiderando apenas novas linhas finais; `Asset.php` mantém filemtime e acrescenta a versão do release intencionalmente.
- Seis testes Python aprovados contra os arquivos upstream reais obtidos do tag 1.14.0, incluindo divergência de fonte e preservação dos métodos novos.
- `node --check` no webclient gerado e `bash -n` nos scripts.
- Nenhuma atualização da VPS foi realizada neste ambiente: SSH direto retorna `Network is unreachable`. Docker e PHP nativo não estão disponíveis aqui. O preparador executa o lint PHP real na VPS, e a verificação posterior compila Blade e testa a aplicação.
- A migração da console não implementa, por si, licenças, cobrança nem acesso temporário revogável. Esses itens permanecem no plano do Facilitador.

Fontes: https://github.com/marcpope/cortendesk/releases/tag/v1.14.0 e comparação https://github.com/marcpope/cortendesk/compare/v1.10.1...v1.14.0 .
