const assert=require('node:assert/strict');
const ts=require('typescript'),fs=require('fs'),vm=require('vm');
const source=fs.readFileSync('src/lib/meta-connection.ts','utf8');
const exports_={};
vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,{exports:exports_,crypto:globalThis.crypto,AbortSignal,fetch});
(async()=>{
 let calls=0;
 const rejected=await exports_.checkMetaCandidate('123456789012','invalid-token','','https://puffle-iota.vercel.app',async(url,req)=>{
  calls++;assert.match(url,/v27.0\/123456789012\/events$/);assert.equal(req.method,'POST');
  assert.equal(JSON.parse(req.body).data[0].event_name,'MetaConfigurationTest');
  return {ok:false,status:400,json:async()=>({error:{message:'Invalid OAuth access token invalid-token'}})};
 });
 assert.equal(rejected.status,'rejected');assert.match(rejected.message,/Invalid OAuth/);assert.ok(!rejected.message.includes('invalid-token'));
 const accepted=await exports_.checkMetaCandidate('123456789012','candidate','TEST1','https://puffle-iota.vercel.app',async(_,req)=>{
  assert.equal(JSON.parse(req.body).test_event_code,'TEST1');return {ok:true,status:200,json:async()=>({events_received:1,fbtrace_id:'trace'})};
 });assert.equal(accepted.status,'accepted');
 const timeout=await exports_.checkMetaCandidate('123456789012','candidate','','https://puffle-iota.vercel.app',async()=>{const e=new Error('timeout');e.name='TimeoutError';throw e;});assert.equal(timeout.status,'timeout');
 const zero=await exports_.checkMetaCandidate('123456789012','candidate','','https://puffle-iota.vercel.app',async()=>({ok:true,status:200,json:async()=>({events_received:0})}));assert.equal(zero.status,'rejected');
 const invalid=await exports_.checkMetaCandidate('bad','token','','https://puffle-iota.vercel.app',async()=>{throw Error('must not call');});assert.equal(invalid.status,'rejected');assert.equal(calls,1);
 console.log('PASS: rejected token, redaction, actual POST, accepted acknowledgement, test code, timeout, zero acknowledgement and invalid ID');
})().catch(e=>{console.error(e);process.exitCode=1;});
