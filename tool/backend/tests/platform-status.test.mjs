import {test} from 'node:test';
import assert from 'node:assert/strict';
import {platformStatus} from '../platform-status.mjs';
test('unavailable provider status is unknown, not incident-free',async()=>{
 for(const fetcher of [async()=>{throw new Error('offline');},async()=>new Response('error',{status:503}),async()=>Response.json({})]){
  const status=await platformStatus(fetcher);assert.equal(status.check,'unavailable');assert.equal(status.active_incidents,null);
 }
});
test('provider incidents and component degradation are surfaced independently',async()=>{
 const status=await platformStatus(async()=>Response.json({page:{updated_at:'2026-09-14T00:00:00Z'},incidents:[{id:'test',name:'JWT failures',status:'identified'}],components:[{name:'API Gateway',status:'degraded_performance'}]}));
 assert.equal(status.check,'available');assert.equal(status.active_incidents.length,1);assert.equal(status.degraded_components.length,1);
});
