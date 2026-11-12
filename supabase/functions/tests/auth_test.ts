import {Backend,userBackend,verifyWorker} from '../_shared/backend.ts';
import {ApiError} from '../_shared/http.ts';
import {dispatch} from '../_shared/dispatch.ts';
function assert(value:unknown){if(!value)throw new Error('Assertion failed');}
async function rejects(fn:()=>Promise<unknown>,code:string){try{await fn();}catch(e){assert(e instanceof ApiError&&e.code===code);return;}throw new Error('Expected rejection: '+code);}
Deno.test('missing user Authorization is rejected before configuration or network',async()=>{
 await rejects(()=>userBackend(new Request('https://example.test')),'AUTHENTICATION_REQUIRED');
 await rejects(()=>userBackend(new Request('https://example.test',{headers:{authorization:'Basic test'}})),'AUTHENTICATION_REQUIRED');
});
Deno.test('user token is validated by Auth; identity is never trusted from decoded claims alone',async()=>{
 const original=globalThis.fetch;
 try{
   globalThis.fetch=async(url,options)=>{
     assert(url==='https://project.test/auth/v1/user');
     assert((options?.headers as Record<string,string>).Authorization==='Bearer forged-token');
     return Response.json({message:'invalid JWT'},{status:401});
   };
   await rejects(()=>new Backend('public-test-key','forged-token','https://project.test').verifyUser(),'AUTHENTICATION_REQUIRED');
   globalThis.fetch=async()=>Response.json({});
   await rejects(()=>new Backend('public-test-key','token','https://project.test').verifyUser(),'AUTHENTICATION_REQUIRED');
   globalThis.fetch=async()=>Response.json({id:'verified-test-user'});
   await new Backend('public-test-key','token','https://project.test').verifyUser();
 }finally{globalThis.fetch=original;}
});
Deno.test('worker rejects missing credentials and non-Bearer input before reading secrets',async()=>{
 for(const authorization of ['', 'Basic test', 'x'.repeat(64),'Bearer small']){
   await rejects(()=>verifyWorker(new Request('https://example.test',{headers:{authorization}})),'FORBIDDEN');
 }
});
Deno.test('worker accepts only its configured secret and fails closed without configuration',async()=>{
 const secret='a'.repeat(64);
 await verifyWorker(new Request('https://example.test',{headers:{authorization:'Bearer '+secret}}),secret);
 await rejects(()=>verifyWorker(new Request('https://example.test',{headers:{authorization:'Bearer '+'b'.repeat(64)}}),secret),'FORBIDDEN');
 await rejects(()=>verifyWorker(new Request('https://example.test',{headers:{authorization:'Bearer '+secret}}),''),'WORKER_NOT_CONFIGURED');
});
Deno.test('dispatch authorization runs before Google configuration or route work',async()=>{
 let keyRead=false;
 const fake={rpc:()=>{throw new ApiError('FORBIDDEN',403);}} as unknown as Backend;
 await rejects(()=>dispatch(fake,crypto.randomUUID(),()=>{keyRead=true;return 'test';}),'FORBIDDEN');
 assert(!keyRead);
});
