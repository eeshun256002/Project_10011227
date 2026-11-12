import {ApiError} from './http.ts';
import {Point,Route} from './routes.ts';

export interface EtaContext {
  order_id:string; version:number; origin:Point; destination:Point;
  location_measured_at:string;
}

// Recheck access/state after the provider call; a cancelled/reassigned visit
// must not receive an ETA calculated against its old assignment.
export async function calculateEta(
  read:()=>Promise<EtaContext>,
  route:(origin:Point,destination:Point)=>Promise<Route>,
) {
  const before=await read();
  const result=await route(before.origin,before.destination);
  const after=await read();
  if(before.order_id!==after.order_id||before.version!==after.version)
    throw new ApiError('VERSION_CONFLICT',409);
  return {order_id:before.order_id,version:before.version,...result,
    location_measured_at:before.location_measured_at,
    calculated_at:new Date().toISOString(),source:'google_routes',estimated:true};
}
