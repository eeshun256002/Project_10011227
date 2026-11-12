import {readFile} from 'node:fs/promises';
const env=Object.fromEntries((await readFile(new URL('../../.env',import.meta.url),'utf8')).split(/\r?\n/).filter(l=>/^[A-Z_]+=/.test(l)).map(l=>{
 const i=l.indexOf('=');return [l.slice(0,i),l.slice(i+1).trim().replace(/^(['"])(.*)\1$/,'$2')];
}));
const r=await fetch(env.SUPABASE_URL+'/auth/v1/settings',{headers:{apikey:env.SUPABASE_PUBLISHABLE_KEY},signal:AbortSignal.timeout(15000)});
if(!r.ok)throw new Error('Auth settings HTTP '+r.status);
const data=await r.json();
console.log(JSON.stringify({email_enabled:data.external?.email,phone_enabled:data.external?.phone,
email_auto_confirm:data.mailer_autoconfirm,phone_auto_confirm:data.phone_autoconfirm,signup_disabled:data.disable_signup},null,2));
