#!/usr/bin/env bash
# Exclusivo CI: projeto, banco e rede internos descartáveis. Nenhuma porta pública.
set -euo pipefail
PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -m unittest discover -s "$PACKAGE_DIR/tests" -p 'test_*.py' -v
sudo python3 "$PACKAGE_DIR/tests/upgrade-integration.py"
