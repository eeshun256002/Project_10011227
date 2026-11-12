import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';
import {platformStatus} from './platform-status.mjs';
const root=fileURLToPath(new URL('../../',import.meta.url));
const env=Object.fromEntries((await readFile(root+'.env','utf8')).split(/\r?\n/).filter(l=>/^[A-Z_]+=/.test(l)).map(l=>{
 const i=l.indexOf('=');return [l.slice(0,i),l.slice(i+1).trim().replace(/^(['"])(.*)\1$/,'$2')];
}));
const url=env.SUPABASE_URL,key=env.SUPABASE_PUBLISHABLE_KEY;
assert.ok(url?.startsWith('https://')&&key&&!key.startsWith('sb_secret_'),'Public app configuration required');
async function request(path,p={},token){
 const headers={'apikey':key,'Content-Type':'application/json'};if(token)headers.Authorization='Bearer '+token;
 const r=await fetch(url+path,{method:'POST',headers,body:JSON.stringify(p),signal:AbortSignal.timeout(20000)});
 return {status:r.status,data:await r.json()};
}
const catalog=await request('/rest/v1/rpc/wm_catalog');assert.equal(catalog.status,200);
assert.equal(catalog.data.booking_minor,100);assert.equal(catalog.data.waiting_rate_minor,90);
assert.equal(catalog.data.mobile_money_ready,false);
assert.equal(catalog.data.categories.find(c=>c.code==='biodegradable').enabled,false);
for(const rpc of ['wm_command','wm_worker_sweep','wm_operator_overview']){
 const args=rpc==='wm_command'?{p_action:'profile.update',p_payload:{display_name:'Must not write'},p_command_key:crypto.randomUUID()}:{};
 const r=await request('/rest/v1/rpc/'+rpc,args);assert.ok([401,403].includes(r.status),rpc+' must deny anonymous access');
}
for(const [rpc,args] of [
 ['wm_driver_status',{}],['wm_staff_access',{}],['wm_updates',{}],
 ['wm_active_orders',{p_app:'client'}],
 ['wm_order_presentation',{p_order_id:crypto.randomUUID()}],
 ['wm_eta_context',{p_order_id:crypto.randomUUID()}],
]){
 const r=await request('/rest/v1/rpc/'+rpc,args);assert.ok([401,403].includes(r.status),rpc+' must deny anonymous access');
}
for(const fn of ['wm-quote','wm-dispatch','wm-eta']){
 for(const token of [undefined,'invalid-token']){
   const r=await request('/functions/v1/'+fn,{},token);assert.equal(r.status,401);
 }
}
const worker=await request('/functions/v1/wm-worker');assert.equal(worker.status,403);
const privateRest=await fetch(url+'/rest/v1/orders?limit=0',{headers:{apikey:key,'Accept-Profile':'wm'},signal:AbortSignal.timeout(20000)});
assert.ok([401,403,406].includes(privateRest.status),'Private wm tables must not become public');
const platform=await platformStatus();
const platformDegraded=platform.check!=='available'||platform.active_incidents.length>0||platform.degraded_components.length>0;
console.log(JSON.stringify({backend_check:'passed',overall:platformDegraded?'warning':'passed',catalog:'reachable',bookings_enabled:catalog.data.bookings_enabled,
 protected_rpcs:'anonymous access denied',edge_functions:'unauthenticated and invalid tokens rejected',
 worker:'unauthorized invocation rejected',private_table_rest:'restricted as intended (HTTP '+privateRest.status+')',
 platform,mobile_money:'not configured'},null,2));
// Distinguish a provider warning/unknown state from a backend assertion failure.
if(platformDegraded)process.exitCode=2;
