import {body,endpoint} from '../_shared/http.ts';
import {serviceBackend,userBackend} from '../_shared/backend.ts';
import {mapsKey,point,Point,route} from '../_shared/routes.ts';
Deno.serve(endpoint(async req=>{
  const db=await userBackend(req);const p=await body(req);const loc=point(p);
  const intent=await db.rpc<{intent_id:string;origin:Point;destination:Point}>('wm_prepare_quote',{p_category:p.category,p_latitude:loc.latitude,p_longitude:loc.longitude});
  const result=await route(intent.origin,intent.destination,mapsKey());
  return serviceBackend().rpc('wm_finish_quote',{p_intent_id:intent.intent_id,p_distance_m:result.distance_m,p_duration_s:result.duration_s});
}));
