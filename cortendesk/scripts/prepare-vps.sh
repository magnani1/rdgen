#!/usr/bin/env bash
# Executar NA VPS. Prepara arquivos e backup; a troca da stack ocorre no gerenciador.
set -euo pipefail
PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORTEN_CONTAINER="${CORTEN_CONTAINER:-suporte_remoto}"
CORTEN_ROOT="${CORTEN_ROOT:-/opt/cortendesk}"
CORTEN_DEST="$CORTEN_ROOT/branding-1.14.0"
CORTEN_IMAGE='ghcr.io/marcpope/cortendesk:1.14.0'
command -v docker >/dev/null
command -v python3 >/dev/null
[ ! -e "$CORTEN_DEST" ] || { echo "Destino já existe: $CORTEN_DEST. Preserve-o e use a verificação do manifesto antes de repetir." >&2; exit 1; }
CORTEN_STAGE="$(mktemp -d)"
CORTEN_TEMP_CONTAINER=''
CORTEN_RESTART_REQUIRED=0
cleanup() {
    if [ "$CORTEN_RESTART_REQUIRED" = 1 ]; then docker start "$CORTEN_CONTAINER" >/dev/null || true; fi
    if [ -n "$CORTEN_TEMP_CONTAINER" ]; then docker rm -v "$CORTEN_TEMP_CONTAINER" >/dev/null 2>&1 || true; fi
    rm -rf "$CORTEN_STAGE"
}
trap cleanup EXIT
# Não imprimir o ambiente: ele pode conter credenciais.
docker inspect "$CORTEN_CONTAINER" >/dev/null
CORTEN_DB="$(docker exec -u www-data -w /app "$CORTEN_CONTAINER" php -r '
require "vendor/autoload.php"; $app = require "bootstrap/app.php";
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
$driver=config("database.default");
echo json_encode(["driver"=>$driver,"path"=>$driver==="sqlite"?config("database.connections.sqlite.database"):null]);
')"
python3 - "$CORTEN_DB" <<'PY'
import json,sys
info=json.loads(sys.argv[1])
if info['driver']!='sqlite' or not str(info.get('path','')).startswith('/data/'):
    raise SystemExit('Banco externo ou fora de /data: é necessário preparar seu backup específico antes da troca. A stack não foi parada.')
print('SQLite persistente em /data confirmado.')
PY
CORTEN_DATA_SOURCE="$(docker inspect "$CORTEN_CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}')"
[ "$CORTEN_DATA_SOURCE" = "$CORTEN_ROOT/data" ] || { echo 'O volume /data não corresponde ao diretório esperado; preparação interrompida.' >&2; exit 1; }
docker pull "$CORTEN_IMAGE"
CORTEN_TEMP_CONTAINER="$(docker create --entrypoint /bin/true "$CORTEN_IMAGE")"
mkdir -p "$CORTEN_STAGE/upstream"
python3 - "$PACKAGE_DIR/manifest.json" <<'PY' > "$CORTEN_STAGE/paths.tsv"
import json,sys
for item in json.load(open(sys.argv[1]))['files']:
    print(item['upstream'])
PY
while IFS= read -r CORTEN_PATH; do
    mkdir -p "$CORTEN_STAGE/upstream/$(dirname "$CORTEN_PATH")"
    docker cp "$CORTEN_TEMP_CONTAINER:/app/$CORTEN_PATH" "$CORTEN_STAGE/upstream/$CORTEN_PATH"
done < "$CORTEN_STAGE/paths.tsv"
python3 "$PACKAGE_DIR/scripts/brand_v114.py" --source "$CORTEN_STAGE/upstream" --destination "$CORTEN_STAGE/prepared"
# Usa o PHP da imagem nova sem iniciar entrypoint, migrações ou apontar /data real.
docker run --rm --entrypoint sh -v "$CORTEN_STAGE/prepared:/branding:ro" "$CORTEN_IMAGE" -c 'find /branding/app /branding/config -type f -name "*.php" -exec php -l {} \; > /tmp/lint.log; cat /tmp/lint.log; ! grep -q "Errors parsing\|Parse error\|Fatal error" /tmp/lint.log'
CORTEN_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
CORTEN_BACKUP="$CORTEN_ROOT/backups/update-$CORTEN_STAMP"
mkdir -p "$CORTEN_BACKUP"
chmod 700 "$CORTEN_BACKUP"
umask 077
docker inspect "$CORTEN_CONTAINER" > "$CORTEN_BACKUP/container-inspect.json"
CORTEN_OLD_IMAGE="$(docker inspect "$CORTEN_CONTAINER" --format '{{.Image}}')"
# Exige imagem anterior recuperável antes de anunciar rollback disponível.
docker image inspect "$CORTEN_OLD_IMAGE" >/dev/null
CORTEN_ROLLBACK="magbel-cortendesk:rollback-$CORTEN_STAMP"
docker image tag "$CORTEN_OLD_IMAGE" "$CORTEN_ROLLBACK"
docker image save "$CORTEN_ROLLBACK" > "$CORTEN_BACKUP/image-before.tar"
echo 'Preparando snapshot consistente: o suporte ficará indisponível durante a cópia de /data.'
CORTEN_RESTART_REQUIRED=1
docker stop -t 60 "$CORTEN_CONTAINER" >/dev/null
tar -C "$CORTEN_ROOT" -czf "$CORTEN_BACKUP/data-branding-before.tar.gz" data branding
docker start "$CORTEN_CONTAINER" >/dev/null
CORTEN_RESTART_REQUIRED=0
mv "$CORTEN_STAGE/prepared" "$CORTEN_DEST"
# Cópias docker cp podem ser de root; os arquivos de código/asset precisam ser legíveis por www-data.
find "$CORTEN_DEST" -type d -exec chmod 755 {} \;
find "$CORTEN_DEST" -type f -exec chmod 644 {} \;
printf '%s\n' "$CORTEN_ROLLBACK" > "$CORTEN_BACKUP/rollback-image.txt"
printf '\nPreparação concluída. A stack antiga foi reiniciada na versão anterior.\n'
printf 'Branding novo: %s\nBackup privado: %s\nImagem anterior: %s\n' "$CORTEN_DEST" "$CORTEN_BACKUP" "$CORTEN_ROLLBACK"
printf 'Atualize a stack existente com cortendesk/compose-1.14.yml, preservando CORTENDESK_RDGEN_URL.\n'
