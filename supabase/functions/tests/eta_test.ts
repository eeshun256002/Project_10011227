import {calculateEta,EtaContext} from '../_shared/eta.ts';
import {ApiError} from '../_shared/http.ts';
const context:EtaContext={order_id:'test',version:2,origin:{latitude:5.64,longitude:-0.16},
  destination:{latitude:5.65,longitude:-0.15},location_measured_at:'2026-09-15T10:00:00Z'};
function assert(ok:unknown){if(!ok)throw new Error('Assertion failed');}
Deno.test('ETA keeps measured and calculated timestamps distinct and preserves provider duration',async()=>{
 const result=await calculateEta(async()=>context,async()=>({distance_m:1000,duration_s:125}));
 assert(result.duration_s===125&&result.estimated===true&&result.source==='google_routes');
 assert(result.location_measured_at===context.location_measured_at);
 assert(Number.isFinite(Date.parse(result.calculated_at)));
});
Deno.test('ETA authorizes before paid route call and rechecks after it',async()=>{
 let called=false;
 try {await calculateEta(async()=>{throw new ApiError('NOT_FOUND');},async()=>{called=true;return {distance_m:1,duration_s:1};});
   throw new Error('Expected denial');}catch(e){assert(e instanceof ApiError&&e.code==='NOT_FOUND');}
 assert(!called);
 let reads=0;
 try {await calculateEta(async()=>({...context,version:++reads}),async()=>({distance_m:1,duration_s:1}));
   throw new Error('Expected conflict');}catch(e){assert(e instanceof ApiError&&e.code==='VERSION_CONFLICT');}
});
Deno.test('ETA propagates provider failure without inventing a fallback',async()=>{
 try {await calculateEta(async()=>context,async()=>{throw new ApiError('ROUTING_NOT_CONFIGURED',503);});
   throw new Error('Expected unavailable');}catch(e){assert(e instanceof ApiError&&e.code==='ROUTING_NOT_CONFIGURED');}
});
