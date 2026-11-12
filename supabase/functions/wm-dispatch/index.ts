import {body,endpoint,uuid} from '../_shared/http.ts';
import {userBackend} from '../_shared/backend.ts';
import {dispatch} from '../_shared/dispatch.ts';
import {mapsKey} from '../_shared/routes.ts';
Deno.serve(endpoint(async req=>{
  const db=await userBackend(req);const p=await body(req);
  return dispatch(db,uuid(p.order_id),mapsKey);
}));
