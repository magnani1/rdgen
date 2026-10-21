<?php

namespace App\Http\Controllers;

use App\Models\ConsoleAudit;
use App\Models\Device;
use App\Models\MagbelSupportSession;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

class MagbelSupportController extends Controller
{
    public function capabilities(Request $request)
    {
        $group = MagbelSupportSession::integrationGroup($request->attributes->get('api_token'));
        abort_unless($group, 403, 'Token not assigned to a support group.');
        $last = (int) \Illuminate\Support\Facades\Cache::get('magbel-support-last-sweep', 0);
        return response()->json(['code'=>0, 'data'=>['protocol'=>1, 'heartbeat_disconnect'=>true, 'device_group'=>$group,
            'last_sweep'=>$last, 'scheduler_fresh'=>$last > time()-180]]);
    }

    private function owned(Request $request, string $id): MagbelSupportSession
    {
        return MagbelSupportSession::whereKey($id)
            ->where('token_id', $request->attributes->get('api_token')->id)->firstOrFail();
    }

    public function register(Request $request)
    {
        $data = $request->validate(['id'=>'required|uuid', 'peer_id'=>'required|regex:/^[a-zA-Z0-9_-]{1,64}$/',
            'hostname'=>'required|regex:/^[a-zA-Z0-9_.-]{1,128}$/', 'device_group'=>'required|string|max:255',
            'expires'=>'required|integer|min:1']);
        abort_unless(MagbelSupportSession::integrationGroup($request->attributes->get('api_token')) === $data['device_group'], 403, 'Token not assigned to this support group.');
        abort_unless((int) \Illuminate\Support\Facades\Cache::get('magbel-support-last-sweep', 0) > time()-180, 503, 'Managed-session scheduler is not healthy.');
        abort_unless($data['expires'] > time() && $data['expires'] <= time()+3600, 422);
        $plain = Str::random(64);
        $row = DB::transaction(function () use ($data, $request, $plain) {
            $existing = MagbelSupportSession::whereKey($data['id'])->lockForUpdate()->first();
            if ($existing) {
                abort_unless((int)$existing->token_id === (int)$request->attributes->get('api_token')->id, 404);
                abort_unless($existing->peer_id === $data['peer_id'] && $existing->hostname === $data['hostname']
                    && $existing->device_group === $data['device_group'] && $existing->expires_at->timestamp === $data['expires'], 409);
                abort_if($existing->disconnect_requested_at || $existing->closed_reported_at || $existing->expires_at->isPast(), 410);
                if (!$existing->redeemed_at) $existing->forceFill(['launch_hash'=>hash('sha256', $plain)])->save();
                return $existing;
            }
            $row = new MagbelSupportSession(['id'=>$data['id'], 'token_id'=>$request->attributes->get('api_token')->id,
                'peer_id'=>$data['peer_id'], 'hostname'=>$data['hostname'], 'device_group'=>$data['device_group'],
                'expires_at'=>\Illuminate\Support\Carbon::createFromTimestampUTC($data['expires']), 'launch_hash'=>hash('sha256', $plain)]);
            abort_unless($row->device(), 404, 'Device not active in the selected group.');
            $row->save();
            return $row;
        });
        ConsoleAudit::record('magbel.session.register', 'Registered managed support session '.$row->id, 'device', $row->peer_id);
        return response()->json(['code'=>0, 'data'=>['id'=>$row->id,
            'launch_url'=>$row->redeemed_at ? url('/magbel/webclient/'.$row->id) : url('/magbel/connect').'#'.$row->id.'.'.$plain]]);
    }

    public function status(Request $request, string $id)
    {
        return response()->json(['code'=>0, 'data'=>$this->owned($request, $id)->synchronize()]);
    }

    public function statuses(Request $request)
    {
        $ids = $request->validate(['ids'=>'required|array|max:50', 'ids.*'=>'uuid'])['ids'];
        $rows = MagbelSupportSession::whereIn('id', $ids)->where('token_id', $request->attributes->get('api_token')->id)->get();
        return response()->json(['code'=>0, 'data'=>$rows->map(fn ($row) => $row->synchronize())->values()]);
    }

    public function disconnect(Request $request, string $id)
    {
        $row = $this->owned($request, $id);
        $row->requestDisconnect();
        ConsoleAudit::record('magbel.session.disconnect', 'Requested managed-session disconnect '.$row->id, 'device', $row->peer_id);
        return response()->json(['code'=>0, 'data'=>$row->synchronize()]);
    }

    public function landing(Request $request)
    {
        if (!$request->user()) $request->session()->put('url.intended', url('/magbel/connect'));
        return response()->view('magbel-support.launch')->header('Cache-Control', 'no-store')->header('Referrer-Policy', 'no-referrer');
    }

    public function redeem(Request $request)
    {
        $data = $request->validate(['id'=>'required|uuid', 'key'=>'required|string|size:64']);
        DB::transaction(function () use ($data, $request) {
            $row = MagbelSupportSession::whereKey($data['id'])->lockForUpdate()->firstOrFail();
            $token = \App\Models\ApiToken::find($row->token_id);
            abort_unless($token && MagbelSupportSession::integrationGroup($token) === $row->device_group, 410);
            abort_if($row->redeemed_at || $row->disconnect_requested_at || $row->expires_at->isPast(), 410);
            abort_unless($row->launch_hash && hash_equals($row->launch_hash, hash('sha256', $data['key'])), 403);
            $device = $row->device();
            abort_unless($device && Device::visibleTo($request->user())->whereKey($device->id)->exists(), 404);
            $row->forceFill(['operator_id'=>$request->user()->id, 'redeemed_at'=>now(), 'launch_hash'=>null])->save();
        });
        return response()->json(['url'=>url('/magbel/webclient/'.$data['id'])]);
    }

    private function browserSession(Request $request, string $id): MagbelSupportSession
    {
        return MagbelSupportSession::whereKey($id)->where('operator_id', $request->user()->id)->firstOrFail();
    }

    public function webclient(Request $request, string $id)
    {
        $row = $this->browserSession($request, $id);
        $row->synchronize();
        abort_if($row->disconnect_requested_at || $row->closed_reported_at || $row->expires_at->isPast(), 410);
        $device = $row->device();
        abort_unless($device && Device::visibleTo($request->user())->whereKey($device->id)->exists(), 404);
        $request->query->set('id', $row->peer_id);
        return app(WebClientPageController::class)->show($request)->with([
            'myName'=>$row->marker(), 'magbelLease'=>['id'=>$row->id, 'expires'=>$row->expires_at->timestamp],
        ]);
    }

    public function browserStatus(Request $request, string $id)
    {
        $row = $this->browserSession($request, $id);
        if (!$row->device()) $row->requestDisconnect();
        return response()->json($row->synchronize())->header('Cache-Control', 'no-store');
    }
}
