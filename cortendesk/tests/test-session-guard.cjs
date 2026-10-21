const fs=require('fs'),vm=require('vm'),assert=require('assert');
const source=fs.readFileSync(require('path').join(__dirname,'../session-bridge/public/magbel-support/guard.js'),'utf8');
async function run(data,expired=false,failed=false){
    let clicked=0,redirect='',interval;
    const context={document:{getElementById:id=>id==='magbel-session-guard'?{dataset:{session:'12345678-1234-1234-1234-123456789abc',expires:String(Date.now()/1000+(expired?-1:60))}}:id==='rd-btn-disconnect'?{click:()=>clicked++}:null,addEventListener:()=>{},hidden:false},
        location:{replace:path=>redirect=path},setTimeout:(fn,ms)=>{if(expired&&ms===0)queueMicrotask(fn);return 1;},clearTimeout:()=>{},setInterval:fn=>{interval=fn;return 2;},clearInterval:()=>{},AbortController,
        fetch:async()=>{if(failed)throw Error('offline');return {ok:true,json:async()=>data};},Date,Number,encodeURIComponent};
    vm.runInNewContext(source,context);await new Promise(r=>setImmediate(r));return {clicked,redirect};
}
(async()=>{
    const active=await run({expires:Date.now()/1000+60});assert.equal(active.clicked,0);assert.equal(active.redirect,'');
    for(const result of [await run({disconnect_requested:true}),await run({closed_reported:true}),await run({},true),await run({},false,true)]){assert.equal(result.clicked,1);assert.equal(result.redirect,'/magbel/closed');}
    console.log('Session guard: expiry, disconnect, closed and fail-closed network: OK');
})().catch(e=>{console.error(e);process.exit(1);});
