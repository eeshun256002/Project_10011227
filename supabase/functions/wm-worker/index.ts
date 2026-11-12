import {ApiError,endpoint} from '../_shared/http.ts';
import {serviceBackend,verifyWorker} from '../_shared/backend.ts';
import {dispatch} from '../_shared/dispatch.ts';
import {mapsKey} from '../_shared/routes.ts';
interface Event {id:number;order_id:string;lease_token:string}
Deno.serve(endpoint(async req=>{
  await verifyWorker(req);const key=mapsKey();const db=serviceBackend();
  await db.rpc('wm_worker_sweep');
  const events=await db.rpc<Event[]>('wm_claim_dispatch',{p_limit:5});let completed=0;let deferred=0;
  for(const event of events){
    let success=false;let error:string|null=null;
    try{await dispatch(db,event.order_id,key,true);success=true;}
    catch(e){error=e instanceof ApiError?e.code:'DISPATCH_ERROR';
      // Duplicate events are harmless when an offer already exists or the visit ended.
      success=['ORDER_NOT_SEARCHING','OFFER_ALREADY_OPEN'].includes(error);
    }
    await db.rpc('wm_finish_outbox',{p_id:event.id,p_lease_token:event.lease_token,p_success:success,p_error:error});
    if(success)completed++;else deferred++;
  }
  return {completed,deferred};
}));
