#!/usr/bin/env bash
set -euo pipefail
PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORTEN_CONTAINER="${CORTEN_CONTAINER:-suporte_remoto}"
CORTEN_ROOT="${CORTEN_ROOT:-/opt/cortendesk}"
python3 - "$PACKAGE_DIR/manifest.json" "$CORTEN_ROOT/branding-1.14.0/MAGBEL-MANIFEST.json" "$CORTEN_ROOT/session-bridge-1.0.0/MAGBEL-SESSION-MANIFEST.json" <<'PY' | docker exec -i -u www-data -w /app "$CORTEN_CONTAINER" php -r '
$expected=json_decode(stream_get_contents(STDIN), true);
if (!is_array($expected) || !$expected) {fwrite(STDERR,"Manifesto inválido\n");exit(1);}
foreach($expected as $path=>$hash) {
    if (!is_file($path) || hash_file("sha256",$path)!==$hash) {
        fwrite(STDERR,"Arquivo divergente: ".$path."\n");exit(1);
    }
}
echo "Arquivos ativos coincidem com a preparação: ".count($expected)." destinos.\n";
'
import json,sys
from pathlib import Path
manifest=json.load(open(sys.argv[1]));prepared=json.load(open(sys.argv[2]))['sha256']
expected={'/app/'+i['upstream']:prepared[i['local']] for i in manifest['files']}
for local,targets in {
    'cortendesk-logo-light.svg':['public/assets/images/cortendesk-logo-light.svg'],
    'cortendesk-logo-dark.svg':['public/assets/images/cortendesk-logo-dark.svg'],
    'cortendesk-sm.svg':['public/assets/images/cortendesk-sm.svg'],
    'icons/favicon.ico':['public/favicon.ico','public/assets/images/favicon.ico'],
    'icons/magbel-remote-256.png':['public/rdclient/logo.png'],
}.items():
    for target in targets:expected['/app/'+target]=prepared[local]
if Path(sys.argv[3]).is_file():
    expected.update({'/app/'+name:value for name,value in json.load(open(sys.argv[3]))['sha256'].items()})
print(json.dumps(expected))
PY
docker exec -u www-data -w /app "$CORTEN_CONTAINER" php -r '
require "vendor/autoload.php"; $app=require "bootstrap/app.php";
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
if(config("cortendesk.api_version")!=="1.14.0") {fwrite(STDERR,"Versão da aplicação inesperada\n");exit(1);}
foreach([[App\Support\TwoFactor::class,"consumeTotp"],[App\Services\AppriseNotifications::class,"retryDue"],[App\Services\AppriseNotifications::class,"forScheduler"]] as [$class,$method]) {
    if(!method_exists($class,$method)){fwrite(STDERR,"Método novo ausente\n");exit(1);}
}
echo "CortenDesk 1.14.0 com métodos novos: OK\n";
'
docker exec "$CORTEN_CONTAINER" sh -c 'wget -q -O - http://127.0.0.1:8080/health/ready'
printf '\n'
docker exec -u www-data -w /app "$CORTEN_CONTAINER" php artisan view:cache --no-ansi
docker exec -u www-data -w /app "$CORTEN_CONTAINER" php artisan route:list --path=api/v1 --except-vendor --no-ansi
