<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Facades\Cache;

class MagbelSupportSession extends Model
{
    public $incrementing = false;
    protected $keyType = 'string';
    protected $guarded = [];
    protected $hidden = ['launch_hash'];

    protected function casts(): array
    {
        return ['expires_at'=>'datetime', 'redeemed_at'=>'datetime',
            'disconnect_requested_at'=>'datetime', 'closed_reported_at'=>'datetime'];
    }

    public function marker(): string
    {
        return 'facilitador:'.$this->id;
    }

    public static function integrationGroup(ApiToken $token): ?string
    {
        $groups = config('magbel-support.token_groups', []);
        $group = is_array($groups) ? ($groups[$token->name] ?? null) : null;
        return $token->isValid() && $token->allows('audit', 'rw') && $token->allows('device', 'r')
            && is_string($group) && $group !== '' ? $group : null;
    }

    public function device(): ?Device
    {
        return Device::query()->approved()->where('rustdesk_id', $this->peer_id)
            ->whereRaw('LOWER(hostname) = ?', [strtolower($this->hostname)])
            ->whereHas('group', fn (Builder $q) => is_numeric($this->device_group)
                ? $q->where('id', (int) $this->device_group)
                : $q->where('name', $this->device_group))->first();
    }

    public function connections(): Builder
    {
        $q = AuditConnection::query()->where('rustdesk_id', $this->peer_id)
            ->where('from_name', $this->marker());
        if ($this->operator_id === null || $this->redeemed_at === null) {
            return $q->whereRaw('1 = 0');
        }
        return $q->where('from_peer', 'web-'.$this->operator_id)
            ->where('created_at', '>=', $this->redeemed_at->copy()->subSeconds(5));
    }

    public function requestDisconnect(): void
    {
        static::query()->whereKey($this->id)->whereNull('disconnect_requested_at')
            ->update(['disconnect_requested_at'=>now(), 'launch_hash'=>null]);
        $this->refresh();
        $this->synchronize();
    }

    public function synchronize(): array
    {
        // O estado é persistido na VPS; não depende da aba nem do DietPi.
        $token = ApiToken::find($this->token_id);
        $allowed = $token && self::integrationGroup($token) === $this->device_group;
        if ((!$allowed || $this->expires_at->isPast()) && $this->disconnect_requested_at === null) {
            static::query()->whereKey($this->id)->whereNull('disconnect_requested_at')
                ->update(['disconnect_requested_at'=>now(), 'launch_hash'=>null]);
            $this->refresh();
        }
        if ($this->disconnect_requested_at !== null) {
            $this->connections()->whereNull('closed_at')->whereNull('disconnect_requested_at')
                ->update(['disconnect_requested_at'=>now()]);
        }
        $observed = $this->connections()->count();
        $active = $this->connections()->whereNull('closed_at')->count();
        if ($observed > 0 && $active === 0 && $this->closed_reported_at === null) {
            $this->forceFill(['closed_reported_at'=>now(), 'launch_hash'=>null])->save();
        }
        $state = $active > 0 ? 'active' : ($observed > 0 ? 'closed_reported' : 'not_observed');
        if ($this->disconnect_requested_at && $active > 0) $state = 'disconnect_pending';
        return ['id'=>$this->id, 'state'=>$state, 'observed'=>$observed, 'active'=>$active,
            'disconnect_requested'=>$this->disconnect_requested_at !== null,
            'expires'=>$this->expires_at->timestamp,
            'closed_reported'=>$observed > 0 && $active === 0];
    }

    public static function sweep(): int
    {
        $count = 0;
        // Inclui a janela anterior para capturar auditorias que chegaram atrasadas.
        static::query()->where(fn (Builder $q) => $q->where('expires_at', '>=', now()->subDay())
            ->orWhere(fn (Builder $open) => $open->whereNotNull('redeemed_at')->whereNull('closed_reported_at')))->orderBy('id')
            ->chunkById(100, function ($rows) use (&$count): void {
                foreach ($rows as $row) { $row->synchronize(); $count++; }
            });
        Cache::forever('magbel-support-last-sweep', time());
        return $count;
    }
}
