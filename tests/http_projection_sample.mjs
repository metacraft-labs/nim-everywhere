// Native fault/turn controls shared by Node and real Chromium. Real native
// Promise/Response/Headers perform projection. Ready fetch substitutions isolate
// queue turns; throwing fetch/Object.prototype setter isolate executor rejection.
// The foreign throwing byte is deliberately outside ordinary Nim string values:
// it isolates cstring coercion after compiler closure copying, which otherwise
// makes a request-field-getter inverse nondiscriminating. This is a bounded
// conversion fault injection, never substitute transport/codec acceptance.
// Genuine delayed HTTP and browser failure/abort controls live in the harnesses.
import assert from "node:assert/strict";
export async function sample(call, mode) {
  const trace = [], calls = [];
  let reads = 0, completions = 0;
  const token = Error('native token');
  globalThis.fetch = (url, init) => {
    calls.push({url, method:init.method, keys: Object.keys(init), headers: Object.entries(init.headers), body: init.body ?? null});
    trace.push('fetch');
    if (mode === 'throw') throw token;
    if (mode === 'head-error') return Promise.reject(token);
    if (mode === 'head-primitive') return Promise.reject(0);
    const response = new Response(mode === 'body-error' ? new ReadableStream({start(c) { c.error(token); }}) : 'ready', {status:207, headers: [['x-z','z'],['x-a','a']]});
    if(mode === 'projection-error') response.headers.forEach = () => {throw token;};
    const text = response.text;
    response.text = function() {
      reads++; trace.push('text');
      if(mode === 'text-throw')throw token;
      const body = text.call(this);
      const witness = () => {
        trace.push('body-ready');
        const sentinel = n => queueMicrotask(() => {
          trace.push('body-turn'+n); if(n<6)sentinel(n+1);
        });
        sentinel(1);
      };
      body.then(witness,witness);
      return body;
    };
    return Promise.resolve(response);
  };
  if (mode === 'init-throw') Object.defineProperty(Object.prototype, 'x-z', {configurable:true, set() {throw token;}});
  let pending;
  try { pending = call('http://example.invalid/', mode === 'body' ? 'payload' : ''); trace.push('returned'); }
  catch(e) { trace.push('threw'); assert.equal(e,token); }
  finally { if(mode === 'init-throw') delete Object.prototype['x-z']; }
  assert(pending instanceof Promise, "throwable init/fetch must reject inside existing Promise executor");
  let outcome;
  if (pending) pending.then(v => {completions++; trace.push('fulfilled'); outcome = {status:v.status, body:String.fromCharCode(...v.body), headers:v.headers.map(h=>[String.fromCharCode(...h.name),String.fromCharCode(...h.value)])};}, e=>{completions++;trace.push('rejected');outcome={same:e===token};});
  for(let i=1;i<=14;i++) {await Promise.resolve();trace.push('turn'+i);}
  if (!outcome) { await pending.catch(()=>{}); trace.push('native-body-ready-after-sentinels'); }
  for(let i=0;i<8;i++) await Promise.resolve();
  assert(outcome, 'native completion must settle');
  return {trace,calls,reads,completions,outcome};
}

export function conversionBoundary(call) {
  const token = Error('conversion token');
  let caught, returned = false;
  // A foreign byte with throwing coercion isolates cstring conversion after
  // ordinary Nim closure copying; a request-field getter would throw during
  // the mutant's closure capture too, and therefore cannot discriminate it.
  const byte = {valueOf() {throw token;}};
  try { call({url:[byte],httpMethod:0,body:[],headers:[]}); returned = true; }
  catch(error) {caught = error;}
  assert.equal(returned,false,'Nim conversions must throw before Promise executor');
  assert.equal(caught,token,'original conversion throw identity');
}
