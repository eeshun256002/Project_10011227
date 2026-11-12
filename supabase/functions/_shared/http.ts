export class ApiError extends Error {
  constructor(public code: string, public status = 400) { super(code); }
}
export const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
export function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {status, headers: {...cors, 'Content-Type':'application/json', 'Cache-Control':'no-store'}});
}
export async function body(req: Request): Promise<Record<string, unknown>> {
  if (!req.headers.get('content-type')?.startsWith('application/json')) throw new ApiError('JSON_REQUIRED',415);
  const reader=req.body?.getReader(); if(!reader) throw new ApiError('INVALID_BODY');
  const chunks: Uint8Array[]=[]; let size=0;
  while(true) {const {done,value}=await reader.read();if(done)break;size+=value.length;
    if(size>16384){await reader.cancel();throw new ApiError('BODY_TOO_LARGE',413);}chunks.push(value);}
  const bytes=new Uint8Array(size);let offset=0;for(const c of chunks){bytes.set(c,offset);offset+=c.length;}
  try {const data=JSON.parse(new TextDecoder().decode(bytes));
    if(!data||typeof data!=='object'||Array.isArray(data))throw new Error();return data;
  } catch {throw new ApiError('INVALID_BODY');}
}
export function endpoint(handler:(req:Request)=>Promise<unknown>) {
  return async(req:Request):Promise<Response>=>{
    if(req.method==='OPTIONS')return new Response(null,{status:204,headers:cors});
    if(req.method!=='POST')return json({error:'METHOD_NOT_ALLOWED'},405);
    try{return json(await handler(req));}catch(e){
      return json({error:e instanceof ApiError?e.code:'INTERNAL_ERROR'},e instanceof ApiError?e.status:500);
    }
  };
}
export function uuid(value:unknown):string {
  if(typeof value!=='string'||! /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value))throw new ApiError('INVALID_ID');
  return value;
}
