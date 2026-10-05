#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/dados_servidor/imagem/rdgen"
IMAGE="rdgen-magbel:test"
CONTAINER="rdgen"
CLOUDFLARED="cloudflared-tunnel-app"
NETWORK="portainer_network"
PUBLIC_URL="https://rdgen.magbel.com.br/"

cd "$BASE"

log() {
    printf '\n=== %s ===\n' "$*"
}

fail() {
    echo "ERRO: $*" >&2
    exit 1
}

ensure_gitignore() {
    touch .gitignore

    for item in \
        ".backup-magbel/" \
        "exe/" \
        "temp_zips/" \
        "*.bak-*" \
        "__pycache__/" \
        "*.pyc"
    do
        grep -qxF "$item" .gitignore || echo "$item" >> .gitignore
    done
}

validate() {
    log "VALIDANDO PYTHON"

    python3 -m py_compile \
        rdgenerator/forms.py \
        rdgenerator/api_views.py \
        rdgenerator/views.py

    log "VALIDANDO MAGBEL"

    grep -q "https://suporte.magbel.com.br" \
        rdgenerator/views.py \
        || fail "DEFAULT_API_SERVER Magbel nao encontrado"

    grep -q '"1.5.0", "1.5.0"' \
        rdgenerator/forms.py \
        || fail "RustDesk 1.5.0 nao encontrado"

    if grep -Eqi "master.*nightly|nightly.*master" \
        rdgenerator/forms.py
    then
        fail "Nightly/master ainda aparece no formulario"
    fi

    grep -q "'version': (VERSION_CHOICES, '1.5.0')" \
        rdgenerator/api_views.py \
        || fail "1.5.0 nao e o default da API"

    grep -q "params.get('version', '1.5.0')" \
        rdgenerator/views.py \
        || fail "1.5.0 nao e o default das views"

    echo "Validacao OK."
}

status() {
    ensure_gitignore

    log "REMOTES"
    git remote -v

    log "BRANCH"
    git branch --show-current

    log "STATUS"
    git status --short

    log "UPSTREAM"
    git fetch upstream --prune

    echo "Local:    $(git rev-parse --short HEAD)"
    echo "Upstream: $(git rev-parse --short upstream/master)"
    echo "Atras:    $(git rev-list --count HEAD..upstream/master)"
    echo "A frente: $(git rev-list --count upstream/master..HEAD)"
}

deploy() {
    ensure_gitignore
    validate

    log "SALVANDO CONFIGURACAO ATUAL"

    ENVFILE="$(mktemp /tmp/rdgen-env.XXXXXX)"
    chmod 600 "$ENVFILE"

    cleanup() {
        rm -f "$ENVFILE"
    }

    trap cleanup EXIT

    docker inspect "$CONTAINER" \
        --format '{{range .Config.Env}}{{println .}}{{end}}' \
        > "$ENVFILE"

    log "BUILD"

    docker build \
        -t "$IMAGE" \
        .

    log "RECRIANDO RDGEN"

    docker rm -f "$CONTAINER"

    docker run -d \
        --name "$CONTAINER" \
        --restart unless-stopped \
        --network "$NETWORK" \
        --env-file "$ENVFILE" \
        -v "$BASE/exe:/opt/rdgen/exe" \
        -v "$BASE/png:/opt/rdgen/png" \
        -v "$BASE/temp_zips:/opt/rdgen/temp_zips" \
        "$IMAGE"

    log "AGUARDANDO HEALTHCHECK"

    HEALTH="starting"

    for i in $(seq 1 18)
    do
        HEALTH="$(
            docker inspect \
                -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
                "$CONTAINER"
        )"

        echo "Tentativa $i/18: health=$HEALTH"

        if [ "$HEALTH" = "healthy" ]; then
            break
        fi

        if [ "$HEALTH" = "unhealthy" ]; then
            docker logs --tail 50 "$CONTAINER"
            fail "RDGen ficou unhealthy"
        fi

        sleep 5
    done

    [ "$HEALTH" = "healthy" ] \
        || fail "Timeout aguardando RDGen"

    log "TESTE INTERNO"

    docker run --rm \
        --network "$NETWORK" \
        curlimages/curl:latest \
        -fsS \
        http://rdgen:8000/ \
        >/dev/null

    echo "Teste interno OK."

    log "REINICIANDO CLOUDFLARED"

    docker restart "$CLOUDFLARED" >/dev/null
    sleep 10

    log "TESTE PUBLICO"

    CODE="$(
        curl -4 \
            -sS \
            -o /dev/null \
            -w '%{http_code}' \
            "$PUBLIC_URL"
    )"

    echo "HTTP=$CODE"

    [ "$CODE" = "200" ] \
        || fail "Teste publico retornou HTTP $CODE"

    log "DEPLOY CONCLUIDO"

    docker ps \
        --filter "name=$CONTAINER" \
        --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Networks}}'
}

upstream() {
    ensure_gitignore
    validate

    log "BUSCANDO UPSTREAM"

    git fetch upstream --prune

    BEHIND="$(
        git rev-list \
            --count \
            HEAD..upstream/master
    )"

    echo "Commits novos no upstream: $BEHIND"

    if [ "$BEHIND" -eq 0 ]; then
        echo "Nenhuma atualizacao do RDGen oficial."
        exit 0
    fi

    if ! git diff --quiet ||
       ! git diff --cached --quiet
    then
        fail "Existem alteracoes versionadas locais. Faca commit antes."
    fi

    BACKUP_BRANCH="backup-magbel-$(date +%Y%m%d-%H%M%S)"

    git branch "$BACKUP_BRANCH"

    echo "Backup criado: $BACKUP_BRANCH"

    log "INTEGRANDO UPSTREAM"

    if ! git merge \
        --no-commit \
        --no-ff \
        upstream/master
    then
        echo "Conflito detectado."
        git merge --abort || true
        fail "Merge abortado. Nenhuma atualizacao aplicada."
    fi

    if ! validate
    then
        echo "A nova versao quebrou as validacoes Magbel."
        git merge --abort || true
        fail "Merge abortado."
    fi

    log "ATUALIZACAO PRONTA PARA REVISAO"

    git status --short

    echo
    echo "O upstream foi integrado e validado."
    echo "Ainda NAO foi feito commit nem deploy."
    echo
    echo "Revise antes de aprovar:"
    echo "  git diff HEAD"
}

case "${1:-}" in
    status)
        status
        ;;

    validate)
        validate
        ;;

    deploy)
        deploy
        ;;

    upstream)
        upstream
        ;;

    *)
        echo "Suporte Magbel - RDGen"
        echo
        echo "Uso:"
        echo "  $0 status"
        echo "  $0 validate"
        echo "  $0 deploy"
        echo "  $0 upstream"
        exit 1
        ;;
esac
