(() => {
    const status=document.getElementById('status'),storageKey='magbel-support-launch';
    const key=location.hash.slice(1)||sessionStorage.getItem(storageKey)||'';
    if(!/^[a-f0-9-]{36}\.[a-zA-Z0-9]{64}$/i.test(key)){status.textContent='Link inválido. Abra um novo atendimento pelo Facilitador.';return;}
    sessionStorage.setItem(storageKey,key);history.replaceState(null,'',location.pathname);
    const [id,secret]=key.split('.');
    fetch('/magbel/redeem',{method:'POST',headers:{'Accept':'application/json','Content-Type':'application/json','X-CSRF-TOKEN':document.querySelector('meta[name="csrf-token"]').content},body:JSON.stringify({id,key:secret}),redirect:'error',cache:'no-store'})
        .then(async response=>{if(response.status===401){location.replace('/login');return;}if(!response.ok)throw Error('Este acesso expirou, já foi utilizado ou não está autorizado. Abra outro atendimento.');const data=await response.json();const url=new URL(data.url,location.origin);if(url.origin!==location.origin||!/^\/magbel\/webclient\/[a-f0-9-]{36}$/i.test(url.pathname))throw Error('Destino inválido.');sessionStorage.removeItem(storageKey);location.replace(url.href);})
        .catch(error=>{status.textContent=error.message;});
})();
