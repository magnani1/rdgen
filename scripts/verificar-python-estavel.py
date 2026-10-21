"""Consulta releases estáveis publicadas; não instala nem altera os agentes."""
import argparse
import gzip
from html.parser import HTMLParser
import re
import sys
import urllib.request

class Releases(HTMLParser):
    def __init__(self):
        super().__init__()
        self.versions = set()
    def handle_data(self, data):
        match = re.fullmatch(r"Python (\d+)\.(\d+)\.(\d+)", data.strip())
        if match:
            self.versions.add(tuple(map(int, match.groups())))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reviewed", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+", args.reviewed):
        parser.error("--reviewed deve ser X.Y.Z")
    request = urllib.request.Request(
        "https://www.python.org/downloads/",
        headers={"User-Agent": "Magbel-release-check/1.0", "Accept-Encoding": "identity"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read(4_000_001)
        if len(data) > 4_000_000:
            raise ValueError("Página maior que o limite esperado")
        if data.startswith(b"\x1f\x8b"):
            data = gzip.decompress(data)
        content = data.decode("utf-8")
    releases = Releases()
    releases.feed(content)
    versions = [v for v in releases.versions if v[0] == 3]
    if not versions:
        raise ValueError("Não foi possível identificar releases estáveis no site oficial")
    latest = max(versions)
    reviewed = tuple(map(int, args.reviewed.split(".")))
    print("Última estável publicada:", ".".join(map(str, latest)))
    print("Última estável revisada pelo projeto:", args.reviewed)
    print("Esta referência não representa a versão instalada nos agentes.")
    if latest > reviewed:
        print("Nova release: revisar notas de segurança, testar e preparar migração.")
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
