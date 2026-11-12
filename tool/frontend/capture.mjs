import { chromium } from 'playwright';
import { mkdir, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
const output=fileURLToPath(new URL('../../build/ui-review/',import.meta.url));
await mkdir(output,{recursive:true});
const browser=await chromium.launch({channel:'chrome',headless:true});
const page=await browser.newPage({viewport:{width:390,height:844},deviceScaleFactor:2});
const errors=[];
page.on('pageerror',error=>errors.push(error.message));
try{
 await page.goto(process.env.PREVIEW_URL||'http://127.0.0.1:8765',{waitUntil:'networkidle'});
 await page.locator('flt-semantics-placeholder').evaluate(el=>el.click(),{timeout:30000});
 await page.getByRole('button',{name:'Explore prototype',exact:true}).waitFor({timeout:30000});
 await page.screenshot({path:output+'client-welcome.png'});
 await page.getByRole('button',{name:'Explore prototype',exact:true}).click();
 await page.getByRole('button',{name:'Request a collection',exact:true}).waitFor();
 await page.screenshot({path:output+'client-home.png'});
 await page.getByRole('button',{name:'Request a collection',exact:true}).click();
 await page.getByRole('button',{name:'Confirm pickup point',exact:true}).click();
 await page.getByRole('button',{name:'See price',exact:true}).click();
 await page.getByRole('button',{name:'Request collection',exact:true}).waitFor();
 await page.screenshot({path:output+'client-quote.png'});
 await page.getByRole('button',{name:'Request collection',exact:true}).click();
 await page.getByRole('button',{name:'Cancel request',exact:true}).waitFor();
 await page.screenshot({path:output+'client-searching.png'});
 if(errors.length)throw new Error(errors.join('\n'));
 await writeFile(output+'browser-review.json',JSON.stringify({viewport:'390x844',prototype:true,errors,checks:['welcome','home','quote','request/searching']},null,2));
 console.log('Prototype browser journey passed. Screenshots: '+output);
}finally{await browser.close();}
