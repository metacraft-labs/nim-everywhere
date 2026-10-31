// Compile real source inverses, then execute unchanged native outcome/turn
// oracle. No fake compiler/Promise/Response or arbitrary compilation failure
// qualifies rejection. Temporary inputs/logs are retained for failure review.
import {mkdtemp,cp,readFile,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
const work=await mkdtemp(join(tmpdir(),'ne-http-inverses-'));
const inside=`      result = newPromise proc(resolve: proc(response: HttpResponse)) =
        let init = buildHttpRequestInitRaw(access, parts)
        let pending = fetchBrowserResponseRaw(access, parts.url, init)
        projectHttpResponseRaw(access, pending, resolve)`;
const mutations=[['conversion-inside-executor',`      let parts = prepareHttpRequestRaw(access, request)
      result = newPromise proc(resolve: proc(response: HttpResponse)) =`, `      result = newPromise proc(resolve: proc(response: HttpResponse)) =
        let parts = prepareHttpRequestRaw(access, request)`, 'Nim conversions must throw before Promise executor'],['outside-executor',inside,`      let init = buildHttpRequestInitRaw(access, parts)
      let pending = fetchBrowserResponseRaw(access, parts.url, init)
      result = newPromise proc(resolve: proc(response: HttpResponse)) =
        projectHttpResponseRaw(access, pending, resolve)`,'throwable init/fetch must reject inside existing Promise executor'],
['extra-projection-then','        projectHttpResponseRaw(access, pending, resolve)',`        let projected = newPromise proc(complete: proc(response: HttpResponse)) =
          projectHttpResponseRaw(access, pending, complete)
        {.emit: "`+'`projected`'+`.then(function(value) { `+'`resolve`'+`(value); });".}`,'immutable pre-extraction outcome and Promise-turn oracle']];
for(const [name,old,replacement,diagnostic] of mutations) {
 const dir=join(work,name);await cp('src',dir,{recursive:true});
 const file=join(dir,'nim_everywhere/http.nim');const source=await readFile(file,'utf8');
 assert.equal(source.split(old).length-1,1);await writeFile(file,source.replace(old,replacement));
 const output=join(dir,'fixture.js');
 let run=spawnSync('nim',['js','--path:'+dir,'--out:'+output,resolve('tests/http_projection_fixture.nim')],{encoding:'utf8'});
 await writeFile(join(dir,'compile.log'),run.stdout+run.stderr);
 assert.equal(run.status,0,run.stdout+run.stderr);
 const browser=process.argv.includes('--browser');
 const runner=browser?'tests/test_ne_http_projection_browser.mjs':'tests/test_http_projection.mjs';
 run=spawnSync(process.execPath,[runner],{cwd:browser?'../isonim':'.',env:{...process.env,HTTP_PROJECTION_FIXTURE:output},encoding:'utf8',timeout:30000});
 await writeFile(join(dir,'result.log'),run.stdout+run.stderr);
 assert.equal(run.signal,null,'inverse must fail assertion, not timeout');assert.notEqual(run.status,0,'inverse passed '+name);
 const expected=browser&&name==='extra-projection-then'?'immutable Chromium80d4 outcome and Promise-turn oracle':diagnostic;
 assert((run.stdout+run.stderr).includes(expected),run.stdout+run.stderr);
 console.log('rejected '+name+': '+diagnostic);
}
console.log('retained inverse inputs/logs '+work);
