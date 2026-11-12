import {test} from 'node:test';
import assert from 'node:assert/strict';
import {database} from './harness.mjs';
test('migrations apply cleanly with real PostGIS; unsafe defaults remain disabled',async()=>{
 const db=await database();
 assert.equal((await db.query('select bookings_enabled from wm.settings')).rows[0].bookings_enabled,false);
 assert.equal((await db.query('select count(*)::int as n from wm.tariffs')).rows[0].n,0);
 assert.equal((await db.query("select warehouse_id from wm.categories where code='biodegradable'")).rows[0].warehouse_id,null);
 assert.equal((await db.query('select routing_point from wm.warehouses')).rows[0].routing_point,null);
 await db.close();
});
