import {point,route} from '../_shared/routes.ts';
import {ApiError,body,endpoint} from '../_shared/http.ts';
function assert(ok:unknown){if(!ok)throw new Error('Assertion failed');}
async function fails(fn:()=>Promise<unknown>,code:string){try{await fn();}catch(e){assert(e instanceof ApiError&&e.code===code);return;}throw new Error('Expected '+code);}
const origin={latitude:5.64,longitude:-0.16},destination={latitude:5.60601,longitude:-0.24717};
Deno.test('Google contract: traffic-aware driving, minimal fields, integer duration',async()=>{
 const fake:typeof fetch=async(url,init)=>{
  assert(url==='https://routes.googleapis.com/directions/v2:computeRoutes');
  const p=JSON.parse(init?.body as string);assert(p.routingPreference==='TRAFFIC_AWARE');assert(p.travelMode==='DRIVE');assert(p.origin.location.latLng.latitude===5.64);
  assert((init?.headers as Record<string,string>)['X-Goog-FieldMask']==='routes.distanceMeters,routes.duration');
  return Response.json({routes:[{distanceMeters:10000,duration:'1200.1s'}]});
 };
 const r=await route(origin,destination,'TEST',fake);assert(r.distance_m===10000&&r.duration_s===1201);
});
Deno.test('route failures never become fabricated distance or fare',async()=>{
 await fails(()=>route(origin,destination,''),'ROUTING_NOT_CONFIGURED');
 await fails(()=>route(origin,destination,'TEST',async()=>Response.json({routes:[]})),'NO_DRIVABLE_ROUTE');
 await fails(()=>route(origin,destination,'TEST',async()=>Response.json({routes:[{distanceMeters:1,duration:'NaNs'}]})),'INVALID_ROUTE_RESULT');
 await fails(()=>route(origin,destination,'TEST',async()=>new Response('quota',{status:429})),'ROUTING_RATE_LIMITED');
 await fails(()=>route(origin,destination,'TEST',async()=>{throw new Error('timeout with secret');}),'ROUTING_UNAVAILABLE');
 await fails(async()=>point({latitude:NaN,longitude:0}),'INVALID_LOCATION');
});
Deno.test('HTTP contract: methods, bounded JSON and sanitized failures',async()=>{
 const handler=endpoint(async()=>{throw new Error('secret credential');});
 assert((await handler(new Request('http://test',{method:'GET'}))).status===405);
 const response=await handler(new Request('http://test',{method:'POST'}));assert(response.status===500);assert(!(await response.text()).includes('credential'));
 await fails(()=>body(new Request('http://test',{method:'POST',headers:{'Content-Type':'application/json'},body:'x'.repeat(16385)})),'BODY_TOO_LARGE');
 await fails(()=>body(new Request('http://test',{method:'POST',headers:{'Content-Type':'application/json'},body:'[]'})),'INVALID_BODY');
});
