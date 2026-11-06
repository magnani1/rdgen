# Uma aplicação: backend, conector e agentes

Depois de mesclar as entregas do rdgen e facilitador-core, executar na estação
Windows institucional, em PowerShell 7 elevado, pelo checkout local rdgen:

~~~powershell
.\facilitador-agent\aplicar-atualizacao.ps1 -CertificateThumbprint 'THUMBPRINT_DO_CERTIFICADO' -BackendSSH 'dietpi@lenovo'
~~~

BackendSSH precisa ser um destino SSH alcançável a partir dessa estação.
BackendDir é /dados_servidor/facilitador-core por padrão. Os destinos são
facilitadorapp1, facilitadorapp2, facilitadorapp3 e facilitadorapp4; para mudar,
informar -Agents com os IDs explícitos. O conector permanente permanece no APP4.

Pré-requisitos já instalados na estação: Git, SSH, Python com requests, PowerShell 7,
certificado institucional válido com chave privada e acesso Kerberos administrativo
ao APP4. Não executar pelo SMB. O script atualiza somente master por ff-only e
preserva alterações locais, recusando o deploy se houver arquivos rastreados alterados.

Uma sessão MFA no Facilitador atende a sequência completa:
1. Conferir cadastro, prontidão, contato e ausência de operações desconhecidas/abertas.
2. Atualizar e aplicar o backend por SSH, via API do Portainer da stack existente.
3. Assinar uma cópia privada do preparador, preparar o pacote e atualizar o conector.
4. Esperar o conector anunciar a versão compatível.
5. Agendar e aguardar cada agente pela API de manutenção já existente, com drenagem,
   backup, rollback e verificação de novo processo/prontidão.
6. Encerrar a sessão web, inclusive quando a sequência falhar.

O Portainer solicita sua origem HTTPS e chave API no terminal SSH se não houver
PORTAINER_URL e PORTAINER_API_KEY_FILE configurados no DietPi. O arquivo de chave
deve ter permissão 600. A chave não é copiada para o Windows. O certificado não é
exportado para o DietPi nem para os APPs.

-CheckOnly confere o checkout, certificado e a frota por leitura, sem Git pull,
assinatura, SSH, alteração de conector ou agendamento. A conferência específica
do Portainer pode ser feita no DietPi com preparar-deploy-dietpi.sh --conferir.

Se backend/conector já estiverem preparados, pode atualizar somente os agentes:
~~~powershell
python facilitador-agent/atualizar-frota.py --agents facilitadorapp1 facilitadorapp2 facilitadorapp3 facilitadorapp4
~~~
Não repetir uma operação que tenha terminado desconhecida; o aplicador bloqueia a
sequência nesse caso. Agentes já prontos na versão esperada são ignorados.

Testes: Portainer/Docker e frota simulados, wrapper analisado/exercitado em CI
Windows. Acesso SSH, chave Portainer, certificado e ações no ambiente real ainda
precisam de validação pelo administrador.
