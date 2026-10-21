#!/usr/bin/env bash
set -euo pipefail
PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORTEN_ROOT="${CORTEN_ROOT:-/opt/cortendesk}"
CORTEN_CONTAINER="${CORTEN_CONTAINER:-suporte_remoto}"
CORTEN_DEST="$CORTEN_ROOT/session-bridge-1.0.0"
[ ! -e "$CORTEN_DEST" ] || { echo 'Extensão já preparada; confira seu manifesto e a stack antes de repetir.' >&2; exit 1; }
bash "$PACKAGE_DIR/scripts/verify-vps.sh"
CORTEN_STAGE="$(mktemp -d)"
trap 'rm -rf "$CORTEN_STAGE"' EXIT
docker cp "$CORTEN_CONTAINER:/app/bootstrap/providers.php" "$CORTEN_STAGE/providers.php"
docker cp "$CORTEN_CONTAINER:/app/resources/views/webclient.blade.php" "$CORTEN_STAGE/webclient.blade.php"
python3 - "$CORTEN_ROOT/branding-1.14.0/MAGBEL-MANIFEST.json" "$CORTEN_STAGE/webclient.blade.php" <<'PY'
import json,hashlib,sys
from pathlib import Path
expected=json.loads(Path(sys.argv[1]).read_text())['sha256']['views/webclient.blade.php']
assert hashlib.sha256(Path(sys.argv[2]).read_bytes()).hexdigest()==expected, 'View ativa difere da marca verificada'
PY
python3 "$PACKAGE_DIR/scripts/build-session-bridge.py" --providers "$CORTEN_STAGE/providers.php" --webclient "$CORTEN_STAGE/webclient.blade.php" --destination "$CORTEN_STAGE/prepared"
docker run --rm --network none --entrypoint sh -v "$CORTEN_STAGE/prepared:/bridge:ro" ghcr.io/marcpope/cortendesk:1.14.0 -c 'find /bridge -name "*.php" -exec php -l {} \; > /tmp/lint.log; cat /tmp/lint.log; ! grep -q "Errors parsing\|Parse error\|Fatal error" /tmp/lint.log'
CORTEN_DB="$(docker exec -u www-data -w /app "$CORTEN_CONTAINER" php -r 'require "vendor/autoload.php"; $app=require "bootstrap/app.php"; $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap(); if(config("database.default")!=="sqlite"){exit(2);} echo config("database.connections.sqlite.database");')"
CORTEN_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
CORTEN_BACKUP="$CORTEN_ROOT/backups/session-bridge-$CORTEN_STAMP"
umask 077
mkdir -p "$CORTEN_BACKUP"
docker inspect "$CORTEN_CONTAINER" > "$CORTEN_BACKUP/container-before.json"
cp "$CORTEN_STAGE/providers.php" "$CORTEN_BACKUP/providers-before.php"
cp "$CORTEN_STAGE/webclient.blade.php" "$CORTEN_BACKUP/webclient-before.blade.php"
python3 - "$CORTEN_ROOT" "$CORTEN_DB" "$CORTEN_BACKUP" <<'PY'
import sqlite3,sys
from pathlib import Path
root=Path(sys.argv[1]); relative=Path(sys.argv[2]).relative_to('/data')
data=(root/'data').resolve(); database=(data/relative).resolve()
assert database.is_relative_to(data) and database.is_file(), 'Banco persistente não localizado'
source=sqlite3.connect(str(database));target=sqlite3.connect(str(Path(sys.argv[3])/'database-before.sqlite'))
try: source.backup(target)
finally: target.close();source.close()
PY
mv "$CORTEN_STAGE/prepared" "$CORTEN_DEST"
find "$CORTEN_DEST" -type d -exec chmod 755 {} \;
find "$CORTEN_DEST" -type f -exec chmod 644 {} \;
printf 'Ponte preparada: %s\nBackup privado: %s\n' "$CORTEN_DEST" "$CORTEN_BACKUP"
printf 'Aplique compose-session-bridge.yml na stack existente, preservando RDGEN_URL e ambiente local. Depois execute verify-session-bridge.sh.\n'
