import {body,endpoint,ApiError} from '../_shared/http.ts';
import {userBackend} from '../_shared/backend.ts';
import {mapsKey,route} from '../_shared/routes.ts';
import {calculateEta,EtaContext} from '../_shared/eta.ts';

Deno.serve(endpoint(async req=>{
  const db=await userBackend(req);
  const p=await body(req);
  if(typeof p.order_id!=='string'||!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(p.order_id))
    throw new ApiError('INVALID_ORDER_ID');
  return calculateEta(
    ()=>db.rpc<EtaContext>('wm_eta_context',{p_order_id:p.order_id}),
    (origin,destination)=>route(origin,destination,mapsKey()),
  );
}));
