import {test} from 'node:test';
import assert from 'node:assert/strict';
import {database,asUser} from './harness.mjs';
test('health hardening preserves authorization and covers relational indexes',async t=>{
 const db=await database();t.after(()=>db.close());
 const publicRpc=(await db.query(`select p.proname,has_function_privilege('anon',p.oid,'execute') anonymous,
 p.prosecdef, p.proconfig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'wm_%'`)).rows;
 assert.deepEqual(publicRpc.filter(p=>p.anonymous).map(p=>p.proname),['wm_catalog']);
 for(const p of publicRpc)if(p.prosecdef)assert.ok(p.proconfig.includes('search_path=""'));
 assert.equal(publicRpc.some(p=>p.proname.includes('before_onboarding')),false);
 assert.equal((await db.query(`select c.oid from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='wm' and c.relkind='r' and not c.relrowsecurity`)).rows.length,0);
 assert.equal((await db.query(`select conname from pg_constraint c join pg_namespace n on n.oid=c.connamespace where n.nspname='wm' and c.contype='f'
 and not exists(select 1 from pg_index i where i.indrelid=c.conrelid and i.indisvalid and i.indpred is null and c.conkey <@ (i.indkey::smallint[])[0:cardinality(c.conkey)-1])`)).rows.length,0);
 const u=crypto.randomUUID();await db.query('insert into auth.users values($1,now(),null)',[u]);
 // A plan must not evaluate an error helper in a branch no actual row takes.
 await db.query("select case when id is not null then null::void else wm.fail('UNREACHABLE_GUARD') end from wm.profiles");
 const r=await asUser(db,u,'explain select * from wm.profiles');assert.ok(r.rows.some(r=>r['QUERY PLAN'].includes('InitPlan')));
 await db.query('update wm.profiles set active=false where id=$1',[u]);
 assert.equal((await asUser(db,u,'select * from wm.profiles')).rows.length,0);
 await db.exec('create function public.health_test_new_function() returns int language sql as $$ select 1 $$');
 assert.equal((await db.query("select has_function_privilege('anon','public.health_test_new_function()','execute') allowed")).rows[0].allowed,false);
});
