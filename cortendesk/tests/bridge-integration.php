<?php
// Executado somente em contêiner de CI com /data temporário, nunca na VPS real.
require '/app/vendor/autoload.php';
$app = require '/app/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

use App\Models\ApiToken;
use App\Models\AuditConnection;
use App\Models\Device;
use App\Models\DeviceGroup;
use App\Models\MagbelSupportSession;
use App\Models\User;
use Illuminate\Http\Request;
use Illuminate\Support\Str;

function check($ok, string $message): void { if (!$ok) throw new RuntimeException($message); }
function api(string $method, string $path, ?string $token, array $body = []): array {
    global $app;
    $server=['CONTENT_TYPE'=>'application/json', 'HTTP_ACCEPT'=>'application/json'];
    if ($token !== null) $server['HTTP_AUTHORIZATION']='Bearer '.$token;
    $request=Request::create('/api/v1/facilitador'.$path, $method, [], [], [], $server, json_encode($body));
    $kernel=$app->make(Illuminate\Contracts\Http\Kernel::class);
    $response=$kernel->handle($request);$kernel->terminate($request,$response);
    return [$response->getStatusCode(), json_decode($response->getContent(),true)];
}

$user=User::create(['username'=>'bridge-admin', 'name'=>'Fixture', 'email'=>'fixture@example.test', 'password'=>'only-in-ci', 'is_admin'=>true]);
[$token,$plain]=ApiToken::issue($user,'facilitador-tjpb-sessoes',['device'=>'r','audit'=>'rw']);
[$readonly,$readplain]=ApiToken::issue($user,'readonly',['device'=>'r']);
[$other,$otherplain]=ApiToken::issue($user,'other',['device'=>'r','audit'=>'rw']);
config(['magbel-support.token_groups'=>['facilitador-tjpb-sessoes'=>'TJPB','other'=>'TJPB']]);
$group=DeviceGroup::create(['name'=>'TJPB']);
$peer='BRIDGE-PC';$host='pc-fixture';
Device::create(['rustdesk_id'=>$peer,'hostname'=>$host,'device_group_id'=>$group->id,'status'=>'active','uuid'=>'fixture-uuid']);
MagbelSupportSession::sweep();
check(api('GET','/capabilities',null)[0]===401,'Anonymous token accepted');
check(api('GET','/capabilities',$readplain)[0]===403,'Read-only token can control sessions');
check(api('GET','/capabilities',$plain)[1]['data']['protocol']===1,'Capabilities missing');
$id=(string)Str::uuid();$body=['id'=>$id,'peer_id'=>$peer,'hostname'=>$host,'device_group'=>'TJPB','expires'=>time()+900];
check(api('POST','/sessions',$plain,array_merge($body,['device_group'=>'TJPE']))[0]===403,'Cross-group registration accepted');
[$code,$registration]=api('POST','/sessions',$plain,$body);check($code===200,'Registration failed');
$secret=explode('.',explode('#',$registration['data']['launch_url'])[1])[1];
check(MagbelSupportSession::find($id)->launch_hash===hash('sha256',$secret),'Launch not hashed');
check(api('GET','/sessions/'.$id,$otherplain)[0]===404,'Other token sees lease');
check(api('POST','/sessions/'.$id.'/disconnect',$otherplain)[0]===404,'Other token disconnects lease');

$request=Request::create('/magbel/redeem','POST',['id'=>$id,'key'=>$secret]);$request->setUserResolver(fn ()=>$user);
$controller=new App\Http\Controllers\MagbelSupportController;
$controller->redeem($request);
try { $controller->redeem($request); throw new RuntimeException('Launch replay accepted'); }
catch (Symfony\Component\HttpKernel\Exception\HttpException $e) { check($e->getStatusCode()===410,'Replay wrong status'); }
$lease=MagbelSupportSession::find($id);
check((int)$lease->operator_id===(int)$user->id,'Browser user not bound');
$resumed=api('POST','/sessions',$plain,$body);check($resumed[0]===200 && str_contains($resumed[1]['data']['launch_url'],'/magbel/webclient/'),'Resume failed');

$related=AuditConnection::create(['action'=>'new','conn_id'=>12345,'rustdesk_id'=>$peer,'from_peer'=>'web-'.$user->id,'from_name'=>$lease->marker(),'conn_type'=>0]);
$transfer=AuditConnection::create(['action'=>'new','conn_id'=>12346,'rustdesk_id'=>$peer,'from_peer'=>'web-'.$user->id,'from_name'=>$lease->marker(),'conn_type'=>1]);
$unrelated=AuditConnection::create(['action'=>'new','conn_id'=>99999,'rustdesk_id'=>$peer,'from_peer'=>'web-'.$user->id,'from_name'=>'unmanaged-session','conn_type'=>0]);
check(api('GET','/sessions/'.$id,$plain)[1]['data']['active']===2,'Related channels not identified');
$closed=api('POST','/sessions/'.$id.'/disconnect',$plain);check($closed[0]===200 && !$closed[1]['data']['closed_reported'],'Disconnect claimed closed before evidence');
check(AuditConnection::find($related->id)->disconnect_requested_at!==null,'Primary not queued');
check(AuditConnection::find($transfer->id)->disconnect_requested_at!==null,'Transfer not queued');
check(AuditConnection::find($unrelated->id)->disconnect_requested_at===null,'Unrelated session affected');
$pending=AuditConnection::pendingDisconnectsFor($peer);sort($pending);check($pending===[12345,12346],'Native heartbeat queue incorrect');
$related->forceFill(['action'=>'close','closed_at'=>now()])->save();$transfer->forceFill(['action'=>'close','closed_at'=>now()])->save();
check(api('GET','/sessions/'.$id,$plain)[1]['data']['closed_reported']===true,'Audit closure not reflected');

$expired=MagbelSupportSession::create(['id'=>(string)Str::uuid(),'token_id'=>$token->id,'peer_id'=>$peer,'hostname'=>$host,'device_group'=>'TJPB','expires_at'=>now()->subMinute(),'operator_id'=>$user->id,'redeemed_at'=>now()->subMinutes(2)]);
$expiredConn=AuditConnection::create(['action'=>'new','conn_id'=>12347,'rustdesk_id'=>$peer,'from_peer'=>'web-'.$user->id,'from_name'=>$expired->marker(),'conn_type'=>0]);
MagbelSupportSession::sweep();check(AuditConnection::find($expiredConn->id)->disconnect_requested_at!==null,'Expired lease not disconnected by server');
$token->forceFill(['is_active'=>false])->save();
check(api('GET','/capabilities',$plain)[0]===401,'Revoked token accepted');
echo "Bridge: auth, scopes, group isolation, launch replay, owner, exact session channels, native disconnect queue, expiry and audit closure: OK\n";
