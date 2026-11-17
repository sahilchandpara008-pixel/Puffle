const assert=require('node:assert/strict'),ts=require('typescript'),fs=require('fs'),vm=require('vm');
const rules={};vm.runInNewContext(ts.transpileModule(fs.readFileSync('src/lib/download-attribution.ts','utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,{exports:rules});
async function scenario(query,{consent=true,pixel='123456789012'}={}){
 const memory=new Map(),requests=[],exports_={};
 const window={};
 const location={search:query,origin:'https://puffle-iota.vercel.app',pathname:'/get'};
 const context={exports:exports_,window,location,crypto:globalThis.crypto,URLSearchParams,Set,Date,
  sessionStorage:{getItem:k=>memory.get(k)??null,setItem:(k,v)=>memory.set(k,v)},
  document:{cookie:'_fbp=fb.1.123.browser; _fbc=fb.1.123.click',createElement:()=>({}),head:{appendChild(){}}},
  fetch:async(url,options)=>{requests.push({url,options,body:JSON.parse(options.body)});return {ok:true};},
  process:{env:{}},
  require:n=>n==='react'?{useEffect(){}}:n==='next/navigation'?{usePathname:()=>'/get'}:n.includes('download-attribution')?rules:n.includes('PrivacyChoices')?{hasAdvertisingConsent:()=>consent}:{supabaseBrowser:()=>({rpc:async()=>({data:{pixel_id:pixel}})})}
 };
 vm.runInNewContext(ts.transpileModule(fs.readFileSync('src/components/MetaPixel.tsx','utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,context);
 return {api:exports_,requests,window,location,memory};
}
(async()=>{
 const paid=await scenario('?utm_source=meta&utm_medium=paid_social&utm_campaign=test');assert.equal(paid.api.fromAd(),true);
 paid.location.search='';assert.equal(paid.api.fromAd(),true,'campaign survives navigation');
 const organic=await scenario('?utm_source=facebook&utm_medium=social');assert.equal(organic.api.fromAd(),false);
 const direct=await scenario('');assert.equal(direct.api.fromAd(),false);
 const google=await scenario('?gclid=example');assert.equal(google.api.fromAd(),true);
 const s=await scenario('?utm_source=meta&utm_medium=paid_social&utm_campaign=test&search=private');
 const id='01234567-1234-4234-8234-012345678901';await s.api.trackWebEvent('Lead',id);
 const pixel=s.window.fbq.queue.find(row=>row[0]==='trackSingle'&&row[2]==='Lead');
 assert.equal(pixel[4].eventID,'web-'+s.requests[0].body.event_id);assert.equal(s.requests[0].url,'/api/meta-event');
 assert.equal(s.requests[0].options.keepalive,true);assert.match(s.requests[0].body.referrer,/utm_campaign=test/);
 assert.ok(!JSON.stringify(s.requests[0].body).includes('private'));
 const noConsent=await scenario('',{consent:false});await noConsent.api.trackWebEvent('Lead',id);assert.equal(noConsent.requests.length,0);assert.equal(noConsent.window.fbq,undefined);
 const disabled=await scenario('',{pixel:''});await disabled.api.trackWebEvent('Lead',id);assert.equal(disabled.requests.length,0);
 console.log('PASS: Ads/Organic routing, campaign persistence, shared Pixel/server event ID, bounded metadata, consent and disabled tracking');
})().catch(e=>{console.error(e);process.exitCode=1;});

