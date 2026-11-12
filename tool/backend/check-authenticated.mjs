// Controlled live authorization test. Creates a confirmed synthetic Auth user,
// sends no email/SMS, and removes the user/profile in finally. No keys are logged.
import {execFileSync} from 'node:child_process';
import {readFile,writeFile,unlink} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
const root=fileURLToPath(new URL('../../',import.meta.url));
const cli=fileURLToPath(new URL('./node_modules/supabase/dist/supabase.js',import.meta.url));
function run(args){
 try{return execFileSync(process.execPath,[cli,...args],{cwd:root,encoding:'utf8',stdio:['ignore','pipe','pipe'],timeout:60000});}
 catch(e){throw new Error('Supabase management command failed ('+(e.code==='ETIMEDOUT'?'timeout':'nonzero exit')+'; output suppressed to protect credentials)');}
}
const env=Object.fromEntries((await readFile(root+'.env','utf8')).split(/\r?\n/).filter(l=>/^[A-Z_]+=/.test(l)).map(l=>{
 const i=l.indexOf('=');return [l.slice(0,i),l.slice(i+1).trim().replace(/^(['"])(.*)\1$/,'$2')];
}));
const url=env.SUPABASE_URL,publicKey=env.SUPABASE_PUBLISHABLE_KEY;
const ref=new URL(url).hostname.split('.')[0];
assert.equal(ref,'wjjabfihijpilgimdhzp','This test is scoped to the development project');
assert.equal((await readFile(root+'supabase/.temp/project-ref','utf8')).trim(),ref);
const keys=JSON.parse(run(['projects','api-keys','--project-ref',ref,'--output','json']));
const adminKey=keys.find(k=>k.name==='service_role')?.api_key;
if(!adminKey)throw new Error('Legacy server key unavailable; authenticated live test not run');
async function request(path,{key=publicKey,token,method='POST',body}={}){
 const headers={apikey:key,'Content-Type':'application/json'};if(token)headers.Authorization='Bearer '+token;
 const r=await fetch(url+path,{method,headers,body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(20000)});
 return {status:r.status,data:await r.json().catch(()=>null)};
}
const tag=crypto.randomUUID();const email='wm-health-'+tag+'@example.invalid';const password=crypto.randomUUID()+'aA1!';
let userId;let token;let cleaned=false;const recovery=root+'supabase/.temp/health-test-user.json';
let testTag=tag;
const cleanupOnly=process.argv.includes('--cleanup');
if(!cleanupOnly){
 try{await readFile(recovery);throw new Error('Existing test recovery file: run with --cleanup first');}
 catch(e){if(e.code!=='ENOENT')throw e;}
}
try{
 if(cleanupOnly){const saved=JSON.parse(await readFile(recovery,'utf8'));userId=saved.user_id;testTag=saved.test_tag;}
 else{
 const created=await request('/auth/v1/admin/users',{key:adminKey,token:adminKey,body:{email,password,email_confirm:true}});
 if(![200,201].includes(created.status)||!created.data?.id)throw new Error('Test account creation failed: HTTP '+created.status);
 userId=created.data.id;await writeFile(recovery,JSON.stringify({user_id:userId,test_tag:tag}));
 const login=await request('/auth/v1/token?grant_type=password',{body:{email,password}});
 if(login.status!==200||!login.data?.access_token)throw new Error('Test login failed: HTTP '+login.status);
 token=login.data.access_token;
 const access=await request('/rest/v1/rpc/wm_account_access',{token,body:{}});
 assert.equal(access.status,200);assert.equal(access.data.driver_can_take_jobs,false);
 const staff=await request('/rest/v1/rpc/wm_staff_access',{token,body:{}});
 assert.equal(staff.status,200);assert.deepEqual(staff.data,{operator:false,warehouses:[]});
 for(const [rpc,body] of [['wm_active_orders',{p_app:'client'}],['wm_updates',{}]]){
  const r=await request('/rest/v1/rpc/'+rpc,{token,body});assert.equal(r.status,200);assert.deepEqual(r.data,[]);
 }
 const driverStatus=await request('/rest/v1/rpc/wm_driver_status',{token,body:{}});
 assert.notEqual(driverStatus.status,200);assert.equal(driverStatus.data.message,'FORBIDDEN');
 const eta=await request('/functions/v1/wm-eta',{token,body:{order_id:crypto.randomUUID()}});
 assert.equal(eta.status,400);assert.equal(eta.data.error,'NOT_FOUND');
 const quote=await request('/functions/v1/wm-quote',{token,body:{category:'non_biodegradable',latitude:5.64,longitude:-0.16}});
 assert.equal(quote.status,400);assert.equal(quote.data.error,'CLIENT_REGISTRATION_REQUIRED');
 const dispatch=await request('/functions/v1/wm-dispatch',{token,body:{order_id:crypto.randomUUID()}});
 assert.equal(dispatch.status,403);assert.equal(dispatch.data.error,'FORBIDDEN');
 const worker=await request('/functions/v1/wm-worker',{token,body:{}});assert.equal(worker.status,403);
 for(const [name,body] of [['wm_bootstrap_operator',{p_user_id:userId}],['wm_claim_dispatch',{}],['wm_worker_sweep',{}]]){
  const r=await request('/rest/v1/rpc/'+name,{token,body});assert.ok([401,403].includes(r.status),name+' must reject a regular user');
 }
 const forged=token.split('.');forged[1]=Buffer.from(JSON.stringify({sub:userId,role:'service_role',exp:9999999999})).toString('base64url');
 for(const fn of ['wm-quote','wm-dispatch','wm-eta']){
  const r=await request('/functions/v1/'+fn,{token:forged.join('.'),body:{}});assert.equal(r.status,401);
 }
 console.log('Authenticated checks passed: valid JWT reaches business checks; client cannot dispatch, invoke worker, bootstrap staff, or forge service role.');
 }
}finally{
 if(userId){
  assert.match(userId,/^[a-f0-9-]{36}$/);
  assert.match(testTag,/^[a-f0-9-]{36}$/);
  const identity=await request('/auth/v1/admin/users/'+userId,{key:adminKey,token:adminKey,method:'GET'});
  assert.equal(identity.status,200,'Synthetic account must be verified before cleanup');
  assert.equal(identity.data.email,'wm-health-'+testTag+'@example.invalid','Refuse to clean a non-test account');
  // The test never enrolls or creates domain records; unexpected references stop deletion.
  const cleanup=root+'supabase/.temp/health-test-cleanup.sql';
  try{
   await writeFile(cleanup,`delete from wm.profiles where id='${userId}'::uuid and display_name=''; select true as profile_cleaned;`);
   run(['db','query','--linked','--file',cleanup]);
   const deleted=await request('/auth/v1/admin/users/'+userId,{key:adminKey,token:adminKey,method:'DELETE'});
   if(![200,204].includes(deleted.status))throw new Error('Synthetic Auth user cleanup failed');
   cleaned=true;await unlink(recovery);
  }finally{await unlink(cleanup).catch(()=>{});}
  if(cleaned)console.log('Synthetic Auth account and profile removed.');
 }
}
