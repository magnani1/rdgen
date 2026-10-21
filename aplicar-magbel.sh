#!/usr/bin/env bash
set -euo pipefail

BASE="/dados_servidor/imagem/rdgen"
VIEWS="$BASE/rdgenerator/views.py"
BACKUP="$BASE/.backup-magbel"

echo "=== RDGen Magbel - aplicação de defaults ==="

if [[ ! -f "$VIEWS" ]]; then
    echo "ERRO: não encontrei $VIEWS"
    exit 1
fi

mkdir -p "$BACKUP"

# Backup apenas na primeira execução
if [[ ! -f "$BACKUP/views.py.original" ]]; then
    cp -a "$VIEWS" "$BACKUP/views.py.original"
    echo "Backup criado: $BACKUP/views.py.original"
else
    echo "Backup original já existe."
fi

# Descobrir como o formulário está sendo criado
echo
echo "Ocorrências atuais de GenerateForm:"
grep -n 'GenerateForm' "$VIEWS" || true

# Garantir import os
if ! grep -Eq '^import os$' "$VIEWS"; then
    sed -i '1i import os' "$VIEWS"
    echo "Adicionado: import os"
fi

# Criar helper para defaults somente uma vez
MARKER="# MAGBEL_RDGEN_DEFAULTS"

if ! grep -qF "$MARKER" "$VIEWS"; then

    TMP=$(mktemp)

    cat > "$TMP" <<'PY'
# MAGBEL_RDGEN_DEFAULTS
def magbel_form_defaults():
    """
    Defaults configuráveis através de variáveis de ambiente.
    Nenhum segredo precisa ficar gravado no código-fonte.
    """
    return {
        'serverIP': os.getenv(
            'DEFAULT_SERVER',
            'rustdesk.magbel.com.br'
        ),
        'serverPort': os.getenv(
            'DEFAULT_PORT',
            '21116'
        ),
        'apiServer': os.getenv(
            'DEFAULT_API_SERVER',
            'https://suporte.magbel.com.br'
        ),
        'key': os.getenv(
            'DEFAULT_KEY',
            ''
        ),
        'exename': os.getenv(
            'DEFAULT_EXENAME',
            'MagbelRemote'
        ),
        'appname': os.getenv(
            'DEFAULT_APPNAME',
            'Magbel Remote'
        ),
        'compname': os.getenv(
            'DEFAULT_COMPANY',
            'Magbel'
        ),
    }

PY

    # Insere helper antes da primeira função/classe do arquivo
    FIRST_DEF=$(grep -nE '^(def |class )' "$VIEWS" | head -1 | cut -d: -f1 || true)

    if [[ -n "${FIRST_DEF:-}" ]]; then
        {
            head -n $((FIRST_DEF - 1)) "$VIEWS"
            cat "$TMP"
            tail -n +"$FIRST_DEF" "$VIEWS"
        } > "$VIEWS.new"

        mv "$VIEWS.new" "$VIEWS"
    else
        cat "$TMP" >> "$VIEWS"
    fi

    rm -f "$TMP"

    echo "Helper magbel_form_defaults() adicionado."
else
    echo "Helper Magbel já existente."
fi

# Substitui somente instanciações vazias:
# GenerateForm()
# por:
# GenerateForm(initial=magbel_form_defaults())
#
# Não toca em GenerateForm(request.POST...), GenerateForm(data=...), etc.
python3 - "$VIEWS" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

old = "GenerateForm()"
new = "GenerateForm(initial=magbel_form_defaults())"

count = s.count(old)

if count:
    s = s.replace(old, new)
    p.write_text(s)
    print(f"Alteradas {count} instanciação(ões) vazias de GenerateForm().")
else:
    print("Nenhum GenerateForm() vazio encontrado ou patch já aplicado.")
PY

echo
echo "=== Verificação ==="

python3 -m py_compile "$VIEWS"

echo "Python OK."
echo
grep -nE \
'MAGBEL_RDGEN_DEFAULTS|magbel_form_defaults|GenerateForm\(initial' \
"$VIEWS" || true

echo
echo "=== Patch concluído ==="
echo
echo "Defaults disponíveis:"
echo "  DEFAULT_SERVER"
echo "  DEFAULT_PORT"
echo "  DEFAULT_API_SERVER"
echo "  DEFAULT_KEY"
echo "  DEFAULT_EXENAME"
echo "  DEFAULT_APPNAME"
echo "  DEFAULT_COMPANY"
echo
echo "Backup:"
echo "  $BACKUP/views.py.original"
