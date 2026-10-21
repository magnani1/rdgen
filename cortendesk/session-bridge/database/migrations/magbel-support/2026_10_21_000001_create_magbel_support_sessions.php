<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void
    {
        Schema::create('magbel_support_sessions', function (Blueprint $table): void {
            $table->uuid('id')->primary();
            $table->unsignedBigInteger('token_id')->index();
            $table->string('peer_id', 64);
            $table->string('hostname', 128);
            $table->string('device_group', 255);
            $table->string('launch_hash', 64)->nullable();
            $table->timestamp('expires_at')->index();
            $table->unsignedBigInteger('operator_id')->nullable();
            $table->timestamp('redeemed_at')->nullable();
            $table->timestamp('disconnect_requested_at')->nullable();
            $table->timestamp('closed_reported_at')->nullable();
            $table->timestamps();
        });
    }

    public function down(): void
    {
        // Dados de auditoria não são descartados no rollback do pacote.
    }
};
