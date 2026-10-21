#!/usr/bin/env bash
set -euo pipefail
CORTEN_CONTAINER="${CORTEN_CONTAINER:-suporte_remoto}"
CORTEN_ROOT="${CORTEN_ROOT:-/opt/cortendesk}"
python3 - "$CORTEN_ROOT/session-bridge-1.0.0/MAGBEL-SESSION-MANIFEST.json" <<'PY' | docker exec -i -u www-data -w /app "$CORTEN_CONTAINER" php -r '
$expected=json_decode(stream_get_contents(STDIN),true);
if(!$expected){exit(1);}
foreach($expected as $path=>$hash){if(!is_file($path)||hash_file("sha256",$path)!==$hash){fwrite(STDERR,"Ponte divergente: ".$path."\n");exit(1);}}
echo "Arquivos da ponte ativos e conferidos.\n";
'
import json,sys
manifest=json.load(open(sys.argv[1]))['sha256']
print(json.dumps({'/app/'+path:value for path,value in manifest.items()}))
PY
# Migração exclusivamente aditiva da extensão. Não remove dados nem altera chaves.
docker exec -u www-data -w /app "$CORTEN_CONTAINER" php artisan migrate --force --no-ansi
docker exec -u www-data -w /app "$CORTEN_CONTAINER" php artisan optimize:clear --no-ansi
docker exec -u www-data -w /app "$CORTEN_CONTAINER" php artisan view:cache --no-ansi
docker exec -u www-data -w /app "$CORTEN_CONTAINER" php artisan route:list --path=facilitador --except-vendor --no-ansi
docker exec -u www-data -w /app "$CORTEN_CONTAINER" php artisan schedule:list --no-ansi
docker exec -u www-data -w /app "$CORTEN_CONTAINER" php -r '
require "vendor/autoload.php"; $app=require "bootstrap/app.php"; $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
if(!Illuminate\Support\Facades\Schema::hasTable("magbel_support_sessions")){exit(1);}
if(config("magbel-support.token_groups")!==["facilitador-tjpb-sessoes"=>"TJPB"]){fwrite(STDERR,"Confira MAGBEL_SESSION_TOKEN_GROUPS: mapeamento diferente do piloto TJPB.\n");exit(1);}
echo "Tabela e mapeamento TJPB da ponte: OK\n";
'
printf 'Confirme que o scheduler do contêiner está executando; a lista deve incluir magbel-support-expiry / magbel:sessions:sweep.\n'
