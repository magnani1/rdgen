(() => {
    const config=document.getElementById('magbel-session-guard');if(!config)return;
    const id=config.dataset.session,expires=Number(config.dataset.expires)*1000;
    if(!/^[a-f0-9-]{36}$/i.test(id)||!Number.isFinite(expires))return;
    let stopped=false,busy=false;
    function stop(){if(stopped)return;stopped=true;clearInterval(timer);clearTimeout(deadline);document.getElementById('rd-btn-disconnect')?.click();location.replace('/magbel/closed');}
    const deadline=setTimeout(stop,Math.max(0,expires-Date.now()));
    async function check(){
        if(stopped||busy)return;busy=true;
        const controller=new AbortController(),timeout=setTimeout(()=>controller.abort(),5000);
        try{const response=await fetch('/magbel/status/'+encodeURIComponent(id),{headers:{'Accept':'application/json'},cache:'no-store',redirect:'error',signal:controller.signal});if(!response.ok)throw Error('Validação indisponível');const data=await response.json();if(data.disconnect_requested||data.closed_reported||Date.now()>=data.expires*1000)stop();}
        catch{stop();}finally{clearTimeout(timeout);busy=false;}
    }
    const timer=setInterval(check,5000);check();
    document.addEventListener('visibilitychange',()=>{if(!document.hidden)check();});
    const peer=document.getElementById('rd-peer-id');if(peer)peer.readOnly=true;
})();
