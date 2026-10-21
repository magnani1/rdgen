<?php

namespace App\Providers;

use App\Models\MagbelSupportSession;
use Illuminate\Console\Scheduling\Schedule;
use Illuminate\Support\ServiceProvider;
use Illuminate\Support\Facades\Artisan;

class MagbelSessionProvider extends ServiceProvider
{
    public function boot(): void
    {
        $this->loadMigrationsFrom(database_path('migrations/magbel-support'));
        $this->loadRoutesFrom(base_path('routes/magbel-support.php'));
        if ($this->app->runningInConsole()) {
            Artisan::command('magbel:sessions:sweep', function (): void {
                $this->info('Sessões verificadas: '.MagbelSupportSession::sweep());
            })->purpose('Solicita desconexão das sessões gerenciadas cujo prazo terminou');
        }
        $this->app->afterResolving(Schedule::class, function (Schedule $schedule): void {
            $schedule->command('magbel:sessions:sweep')
                ->name('magbel-support-expiry')->everyMinute()->withoutOverlapping(2);
        });
    }
}
