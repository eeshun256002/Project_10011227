import {Backend} from './backend.ts';
import {ApiError} from './http.ts';
import {Point,route} from './routes.ts';
interface Candidate extends Point {driver_id:string}
export async function dispatch(db:Backend,orderId:string,key:string|(()=>string),worker=false) {
  const data=await db.rpc<{candidates:Candidate[];destination:Point}>('wm_dispatch_candidates',{p_order_id:orderId});
  if(!data.candidates.length)throw new ApiError('NO_AVAILABLE_DRIVER',409);
  const routeKey=typeof key==='function'?key():key;
  const results=await Promise.allSettled(data.candidates.map(async c=>({driver_id:c.driver_id,...await route(c,data.destination,routeKey)})));
  // Never assign a farther truck just because the closest route lookup failed.
  const failure=results.find(r=>r.status==='rejected');if(failure?.status==='rejected')throw failure.reason;
  const routes=results.flatMap(r=>r.status==='fulfilled'?[r.value]:[]).sort((a,b)=>a.duration_s-b.duration_s||a.distance_m-b.distance_m||a.driver_id.localeCompare(b.driver_id));
  const winner=routes[0];
  const offer=worker?await db.rpc('wm_worker_offer',{p_order_id:orderId,p_driver_id:winner.driver_id}):
    await db.rpc('wm_command',{p_action:'dispatch.offer',p_payload:{order_id:orderId,driver_id:winner.driver_id},p_command_key:crypto.randomUUID()});
  return {...offer,estimated_approach_seconds:winner.duration_s,estimate_at:new Date().toISOString()};
}
