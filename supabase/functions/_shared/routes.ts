import {ApiError} from './http.ts';
export interface Point {latitude:number;longitude:number}
export interface Route {distance_m:number;duration_s:number}
export function point(value:unknown):Point {
  const p=value as Point;
  if(!p||typeof p.latitude!=='number'||typeof p.longitude!=='number'||!Number.isFinite(p.latitude)||!Number.isFinite(p.longitude)||Math.abs(p.latitude)>90||Math.abs(p.longitude)>180)throw new ApiError('INVALID_LOCATION');
  return {latitude:p.latitude,longitude:p.longitude};
}
export function mapsKey() {const key=Deno.env.get('GOOGLE_MAPS_SERVER_KEY');if(!key)throw new ApiError('ROUTING_NOT_CONFIGURED',503);return key;}
export async function route(origin:Point,destination:Point,key:string,transport:typeof fetch=fetch):Promise<Route> {
  point(origin);point(destination);if(!key)throw new ApiError('ROUTING_NOT_CONFIGURED',503);
  let response:Response;
  try{response=await transport('https://routes.googleapis.com/directions/v2:computeRoutes',{
    method:'POST',headers:{'Content-Type':'application/json','X-Goog-Api-Key':key,'X-Goog-FieldMask':'routes.distanceMeters,routes.duration'},
    body:JSON.stringify({origin:{location:{latLng:origin}},destination:{location:{latLng:destination}},travelMode:'DRIVE',routingPreference:'TRAFFIC_AWARE',computeAlternativeRoutes:false}),
    signal:AbortSignal.timeout(8000),
  });}catch{throw new ApiError('ROUTING_UNAVAILABLE',503);}
  if(!response.ok)throw new ApiError(response.status===429?'ROUTING_RATE_LIMITED':'ROUTING_UNAVAILABLE',503);
  const data=await response.json().catch(()=>null);const first=data?.routes?.[0];
  if(!first)throw new ApiError('NO_DRIVABLE_ROUTE',422);
  const duration=typeof first.duration==='string'&&/^\d+(\.\d+)?s$/.test(first.duration)?Number(first.duration.slice(0,-1)):NaN;
  if(!Number.isInteger(first.distanceMeters)||first.distanceMeters<1||first.distanceMeters>1000000||!Number.isFinite(duration)||duration<=0||duration>172800)throw new ApiError('INVALID_ROUTE_RESULT',502);
  return {distance_m:first.distanceMeters,duration_s:Math.ceil(duration)};
}
