<?php

use App\Http\Controllers\MagbelSupportController as Bridge;
use Illuminate\Support\Facades\Route;

Route::prefix('api/v1/facilitador')->middleware(['api', 'auth:api-token', 'api-token-can:audit,rw', 'api-token-can:device,r', 'throttle:600,1,magbel-bridge'])->group(function () {
    Route::get('/capabilities', [Bridge::class, 'capabilities']);
    Route::post('/sessions', [Bridge::class, 'register']);
    Route::post('/statuses', [Bridge::class, 'statuses']);
    Route::get('/sessions/{id}', [Bridge::class, 'status'])->whereUuid('id');
    Route::post('/sessions/{id}/disconnect', [Bridge::class, 'disconnect'])->whereUuid('id');
});
Route::middleware(['web', 'throttle:6000,1,magbel-browser'])->group(function () {
    Route::get('/magbel/connect', [Bridge::class, 'landing']);
    Route::view('/magbel/closed', 'magbel-support.closed');
    Route::middleware(['auth', 'console-can:device,r'])->group(function () {
        Route::post('/magbel/redeem', [Bridge::class, 'redeem']);
        Route::get('/magbel/webclient/{id}', [Bridge::class, 'webclient'])->whereUuid('id');
        Route::get('/magbel/status/{id}', [Bridge::class, 'browserStatus'])->whereUuid('id');
    });
});
