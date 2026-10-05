#!/usr/bin/env python3

import argparse
import pathlib
import re
import sys

p = argparse.ArgumentParser()
p.add_argument("--root", required=True)
p.add_argument("--product", required=True)
p.add_argument("--company", required=True)
p.add_argument("--server", required=True)
p.add_argument("--port", required=True, type=int)
p.add_argument("--key", required=True)
p.add_argument("--api", required=True)
p.add_argument("--website", required=True)
a = p.parse_args()

root = pathlib.Path(a.root)

def replace(path, pattern, replacement, required=False):
    f = root / path

    if not f.exists():
        if required:
            raise RuntimeError(f"Arquivo obrigatorio ausente: {f}")
        return False

    data = f.read_text(encoding="utf-8")
    new, count = re.subn(pattern, replacement, data)

    if required and count == 0:
        raise RuntimeError(
            f"Padrao obrigatorio nao encontrado em {path}: {pattern}"
        )

    if count:
        f.write_text(new, encoding="utf-8")

    return count > 0

config = "libs/hbb_common/src/config.rs"

replace(
    config,
    r"rs-ny\.rustdesk\.com",
    a.server,
    required=True,
)

replace(
    config,
    r"pub const RENDEZVOUS_PORT: i32 = \d+;",
    f"pub const RENDEZVOUS_PORT: i32 = {a.port};",
    required=True,
)

replace(
    config,
    r"pub const RELAY_PORT: i32 = \d+;",
    f"pub const RELAY_PORT: i32 = {a.port + 1};",
)

replace(
    config,
    r"pub const WS_RENDEZVOUS_PORT: i32 = \d+;",
    f"pub const WS_RENDEZVOUS_PORT: i32 = {a.port + 2};",
)

replace(
    config,
    r"pub const WS_RELAY_PORT: i32 = \d+;",
    f"pub const WS_RELAY_PORT: i32 = {a.port + 3};",
)

# A chave padrao pode mudar entre versoes.
# Procuramos a constante/valor usado no arquivo em vez de inserir segredos.
cf = root / config
text = cf.read_text(encoding="utf-8")

old_key = "OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw="
if old_key in text:
    text = text.replace(old_key, a.key)
    cf.write_text(text, encoding="utf-8")

replace(
    "src/common.rs",
    r"https://admin\.rustdesk\.com",
    a.api,
)

# Branding textual. Sao substituicoes deliberadamente conservadoras.
for candidate in [
    "Cargo.toml",
    "flutter/pubspec.yaml",
    "flutter/lib/desktop/pages/desktop_setting_page.dart",
]:
    f = root / candidate
    if f.exists():
        s = f.read_text(encoding="utf-8")
        s = s.replace("Purslane Tech Pte. Ltd.", a.company)
        s = s.replace("Purslane Ltd.", a.company)
        f.write_text(s, encoding="utf-8")

print("=== Magbel patch ===")
print(f"Produto : {a.product}")
print(f"Empresa : {a.company}")
print(f"Servidor: {a.server}:{a.port}")
print(f"Relay   : {a.server}:{a.port + 1}")
print(f"API     : {a.api}")
print("OK")
