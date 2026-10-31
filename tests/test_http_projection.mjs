// Actual Nim facade/composition and native Promise/Response/Headers/fetch.
// Native-throw and ready-response substitutions are narrowly scoped fault/turn
// controls: real HTTP cases below separately prove delayed head/body and I/O.
// Object.prototype setter injection exposes throwable ordinary init assignment.
// Immutable outcomes were captured from compiled http.nim at 80d4b7d; changing
// the production implementation cannot regenerate that oracle implicitly.
import { readFile, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const fixture = process.env.HTTP_PROJECTION_FIXTURE ?? 'tests/http_projection_fixture.js';
vm.runInThisContext(await readFile(fixture, 'utf8'));
const originalFetch = globalThis.fetch;
const results = {};
import { sample, conversionBoundary } from './http_projection_sample.mjs';

try {
  conversionBoundary(httpRawRequest);
  for(const mode of ['ready','body','throw','init-throw','head-error','body-error','projection-error','text-throw','head-primitive']) results[mode] = await sample(httpFacade,mode);
  if(globalThis.httpComposition) for(const mode of Object.keys(results)) assert.deepEqual(await sample(httpComposition,mode),results[mode], 'extracted composition parity '+mode);
  const oraclePath = new URL('./oracles/http_projection_80d4.json',import.meta.url);
  if(process.env.CAPTURE_HTTP_PROJECTION_ORACLE) await writeFile(process.env.CAPTURE_HTTP_PROJECTION_ORACLE,JSON.stringify(results,null,2)+'\n');
  else assert.deepEqual(results,JSON.parse(await readFile(oraclePath,'utf8')), 'immutable pre-extraction outcome and Promise-turn oracle');
} finally {globalThis.fetch = originalFetch;}
const slots = new Map(), requests=[];
const server=createServer((req,res)=>{requests.push({url:req.url,method:req.method,headers:[req.headers['x-z'],req.headers['x-a']]}); slots.set(req.url,res); if(req.url==='/body'){res.writeHead(207,{'x-a':'a'});res.flushHeaders();res.write('first-');}});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
try {
  for(const path of ['/head','/body']) {
    let done=false;
    const pending=httpFacade('http://127.0.0.1:'+server.address().port+path,'');
    pending.then(()=>done=true);
    for(let i=0;i<200&&!slots.has(path);i++) await new Promise(r=>setTimeout(r,5));
    assert(slots.has(path),'real request arrived');
    await new Promise(r=>setImmediate(r));
    assert.equal(done,false,'buffered facade waits for real delayed '+path);
    if(path==='/head') slots.get(path).writeHead(207,{'x-a':'a'});
    slots.get(path).end('last');
    const response=await pending;
    assert.equal(response.status,207);
    assert.equal(String.fromCharCode(...response.body),path==='/body'?'first-last':'last');
  }
  assert.deepEqual(requests,['/head','/body'].map(url=>({url,method:'POST',headers:['last','middle']})),'one native request with original method/headers per facade call');
} finally {server.closeAllConnections();await new Promise(r=>server.close(r));}
console.log('http projection: PASS immutable native outcomes/turns and real delayed HTTP');
