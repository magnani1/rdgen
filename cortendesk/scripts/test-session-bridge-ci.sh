#!/usr/bin/env bash
# Somente CI: imagem e SQLite descartáveis, sem volumes/portas de produção.
set -euo pipefail
PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_TMP="$(mktemp -d)"
BRIDGE_SOURCE_CONTAINER=''
cleanup(){ if [ -n "$BRIDGE_SOURCE_CONTAINER" ]; then docker rm -v "$BRIDGE_SOURCE_CONTAINER" >/dev/null 2>&1 || true; fi; rm -rf "$BRIDGE_TMP"; }
trap cleanup EXIT
docker pull ghcr.io/marcpope/cortendesk:1.14.0
BRIDGE_SOURCE_CONTAINER="$(docker create --entrypoint /bin/true ghcr.io/marcpope/cortendesk:1.14.0)"
docker cp "$BRIDGE_SOURCE_CONTAINER:/app/bootstrap/providers.php" "$BRIDGE_TMP/providers.php"
docker cp "$BRIDGE_SOURCE_CONTAINER:/app/resources/views/webclient.blade.php" "$BRIDGE_TMP/webclient.blade.php"
python3 "$PACKAGE_DIR/scripts/build-session-bridge.py" --providers "$BRIDGE_TMP/providers.php" --webclient "$BRIDGE_TMP/webclient.blade.php" --destination "$BRIDGE_TMP/prepared"
cp "$PACKAGE_DIR/tests/bridge-integration.php" "$BRIDGE_TMP/bridge-integration.php"
cat > "$BRIDGE_TMP/Dockerfile" <<'DOCKER'
FROM ghcr.io/marcpope/cortendesk:1.14.0
USER root
COPY prepared/ /app/
COPY bridge-integration.php /bridge-integration.php
ENV APP_ENV=testing APP_URL=https://support.example.test DB_CONNECTION=sqlite DB_DATABASE=/data/test.sqlite CACHE_STORE=file SESSION_DRIVER=file APP_KEY=base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
RUN mkdir -p /data/storage/framework/cache/data /data/storage/framework/sessions /data/storage/framework/views /data/storage/logs /app/bootstrap/cache && touch /data/test.sqlite && chown -R www-data:www-data /data /app/bootstrap/cache
DOCKER
docker build -t magbel-session-bridge:ci "$BRIDGE_TMP"
docker run --rm --network none --entrypoint sh magbel-session-bridge:ci -c 'php artisan optimize:clear && php artisan migrate --force && php /bridge-integration.php'
node "$PACKAGE_DIR/tests/test-session-guard.cjs"
