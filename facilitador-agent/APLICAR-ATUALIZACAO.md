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


## Estações com política AllSigned

Não assinar o arquivo dentro do checkout: a assinatura conta como alteração local
e impede a atualização Git. Executar uma cópia assinada fora do repositório, passando
-Repo com o caminho real do checkout. As fontes são copiadas desse repositório,
independentemente da pasta onde está a cópia assinada.

Se -CertificateThumbprint for omitido, o aplicador obtém o thumbprint da própria
assinatura válida e procura a chave privada correspondente nos certificados My.
Assim, usa o certificado realmente escolhido por Sign-File, e não o certificado
de outro instalador. O certificado precisa continuar válido e com chave privada.

Para backend já aplicado, usar -SomenteAgentes. Esse modo prepara o conector e
atualiza os executores, sem SSH nem novo deploy do backend. -BackendSSH vazio também
continua suportado, sem encaminhar argumento vazio ao Python.

Antes de restaurar um aplicador assinado no checkout, preservar uma cópia privada
dele e conferir sua assinatura. Restaurar somente esse arquivo no Git, atualizar
o checkout e assinar a nova cópia privada. Os demais arquivos locais são preservados.

Exemplo após preparar a cópia assinada:
~~~powershell
& "$env:LOCALAPPDATA/Magbel/FacilitadorAtualizacao/aplicar-atualizacao.ps1" -Repo "$env:USERPROFILE/Projetos/rdgen" -SomenteAgentes
~~~

### Continuar após assinar o aplicador dentro do Git

No PowerShell 7 elevado, este preparo preserva o arquivo assinado antes de restaurar
somente a versão rastreada dele. O certificado é identificado pela assinatura válida
já feita; não reutiliza o thumbprint de outro executável.

~~~powershell
$ErrorActionPreference = 'Stop'
$Repo = Join-Path $env:USERPROFILE 'Projetos\rdgen'
$Origem = Join-Path $Repo 'facilitador-agent\aplicar-atualizacao.ps1'
$Assinatura = Get-AuthenticodeSignature -LiteralPath $Origem
if ($Assinatura.Status -ne 'Valid') { throw 'Confira a assinatura do aplicador antes de continuar.' }
$Thumb = $Assinatura.SignerCertificate.Thumbprint
$Cert = Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $Thumb -and $_.HasPrivateKey } | Select-Object -First 1
if (-not $Cert) { throw 'Chave privada do certificado usado pelo Sign-File não encontrada.' }

$Pasta = Join-Path $env:LOCALAPPDATA 'Magbel\FacilitadorAtualizacao'
New-Item -ItemType Directory -Path $Pasta -Force | Out-Null
$Backup = Join-Path $Pasta ('aplicador-assinado-anterior-' + (Get-Date -Format yyyyMMddHHmmss) + '.ps1')
Copy-Item -LiteralPath $Origem -Destination $Backup

git -C $Repo restore -- facilitador-agent/aplicar-atualizacao.ps1
if ($LASTEXITCODE -ne 0) { throw 'Restauração do arquivo rastreado falhou; cópia assinada preservada.' }
git -C $Repo pull --ff-only
if ($LASTEXITCODE -ne 0) { throw 'Atualização Git falhou; cópia assinada preservada.' }

$Entrada = Join-Path $Pasta 'aplicar-atualizacao.ps1'
Copy-Item -LiteralPath $Origem -Destination $Entrada -Force
$NovaAssinatura = Set-AuthenticodeSignature -FilePath $Entrada -Certificate $Cert -HashAlgorithm SHA256
if ($NovaAssinatura.Status -ne 'Valid') { throw 'A nova cópia privada não foi validada.' }

& $Entrada -Repo $Repo -SomenteAgentes
~~~

A estação precisa de Python com as dependências de facilitador-agent/requirements.txt.
O aplicador não altera a política de execução nem exporta a chave privada.
