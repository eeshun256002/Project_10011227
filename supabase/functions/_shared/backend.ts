import {ApiError} from './http.ts';
function envKey(legacy:string,modern:string):string {
  const legacyKey=Deno.env.get(legacy);if(legacyKey)return legacyKey;
  try{const keys=JSON.parse(Deno.env.get(modern)||'{}');if(typeof keys.default==='string')return keys.default;}catch{/* fail closed */}
  throw new ApiError('SERVER_NOT_CONFIGURED',503);
}
export class Backend {
  constructor(private key:string,private token?:string,private url=Deno.env.get('SUPABASE_URL')||'') {
    if(!url.startsWith('https://')&&!url.startsWith('http://127.0.0.1')&&!url.startsWith('http://kong:'))throw new ApiError('SERVER_NOT_CONFIGURED',503);
  }
  private headers() {return {'apikey':this.key,'Authorization':`Bearer ${this.token||this.key}`,'Content-Type':'application/json'};}
  async request(path:string,init:RequestInit):Promise<unknown>{
    let r:Response;
    try{r=await fetch(this.url+path,{...init,headers:this.headers(),signal:AbortSignal.timeout(15000)});}catch{throw new ApiError('BACKEND_UNAVAILABLE',503);}
    const data=await r.json().catch(()=>null);
    if(!r.ok){
      const message=typeof data?.message==='string'&&/^[A-Z][A-Z0-9_]{2,100}$/.test(data.message)?data.message:
        data?.code==='23505'?'RESOURCE_CONFLICT':data?.code==='42501'?'FORBIDDEN':data?.code?.startsWith('22')||data?.code?.startsWith('23')?'INVALID_INPUT':'BACKEND_REQUEST_FAILED';
      const status=message==='AUTHENTICATION_REQUIRED'||r.status===401?401:
        ['FORBIDDEN','SELF_REVIEW_FORBIDDEN'].includes(message)||r.status===403?403:
        ['RESOURCE_CONFLICT','VERSION_CONFLICT','OFFER_ALREADY_OPEN','ORDER_NOT_SEARCHING'].includes(message)?409:400;
      throw new ApiError(message,status);
    }
    return data;
  }
  async rpc<T=Record<string,unknown>>(name:string,args:Record<string,unknown>={}):Promise<T>{
    return await this.request('/rest/v1/rpc/'+encodeURIComponent(name),{method:'POST',body:JSON.stringify(args)}) as T;
  }
  async verifyUser() {
    let data:unknown;
    try{data=await this.request('/auth/v1/user',{method:'GET'});}catch(e){
      if(e instanceof ApiError&&e.status===503)throw e;
      throw new ApiError('AUTHENTICATION_REQUIRED',401);
    }
    if(!data||typeof (data as {id?:unknown}).id!=='string')throw new ApiError('AUTHENTICATION_REQUIRED',401);
  }
}
export async function userBackend(req:Request) {
  const match=/^Bearer ([^\s]+)$/i.exec(req.headers.get('authorization')||'');
  if(!match)throw new ApiError('AUTHENTICATION_REQUIRED',401);
  const db=new Backend(envKey('SUPABASE_ANON_KEY','SUPABASE_PUBLISHABLE_KEYS'),match[1]);
  await db.verifyUser();return db;
}
export function serviceBackend(){return new Backend(envKey('SUPABASE_SERVICE_ROLE_KEY','SUPABASE_SECRET_KEYS'));}
export async function verifyWorker(req:Request,expectedSecret?:string) {
  const match=/^Bearer ([^\s]{32,256})$/i.exec(req.headers.get('authorization')||'');
  if(!match)throw new ApiError('FORBIDDEN',403);
  const expected=expectedSecret??Deno.env.get('WM_WORKER_SECRET');if(!expected||expected.length<32)throw new ApiError('WORKER_NOT_CONFIGURED',503);
  const given=match[1];
  const digest=async(v:string)=>new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(v)));
  const [a,b]=await Promise.all([digest(expected),digest(given)]);let diff=0;for(let i=0;i<a.length;i++)diff|=a[i]^b[i];
  if(diff!==0)throw new ApiError('FORBIDDEN',403);
}
