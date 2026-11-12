export async function platformStatus(transport=fetch){
 const checked_at=new Date().toISOString();
 try{
  const r=await transport('https://status.supabase.com/api/v2/summary.json',{signal:AbortSignal.timeout(10000)});
  if(!r.ok)throw new Error('Unavailable');
  const data=await r.json();
  if(!Array.isArray(data.incidents)||!Array.isArray(data.components)||!data.page?.updated_at)throw new Error('Invalid status response');
  return {check:'available',checked_at,provider_updated_at:data.page.updated_at,
   active_incidents:data.incidents.filter(i=>!['resolved','postmortem'].includes(i.status)).map(i=>({name:i.name,status:i.status,url:'https://status.supabase.com/incidents/'+i.id})),
   degraded_components:data.components.filter(c=>c.status!=='operational').map(c=>({name:c.name,status:c.status}))};
 }catch{
  // A failed status request is unknown, never an empty incident list or a green result.
  return {check:'unavailable',checked_at,active_incidents:null,degraded_components:null};
 }
}
